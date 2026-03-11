#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';

use Test::More;
use Test::Exception;
use JSON::PP ();

BEGIN {
	use_ok 'Service::Github';
	use_ok 'Genesis::Kit::Provider::Github';
}

# ============================================================
# Mock Infrastructure
# ============================================================
#
# All curl calls made by Service::Github (which the provider
# delegates to via its remote object) are intercepted below.
# Responses are queued FIFO via queue_curl_response().
#
# Additionally, output functions (info, error, trace, debug,
# warning) are suppressed in both namespaces.  bail() and bug()
# are NOT overridden — they die under eval ($^S), which
# throws_ok / lives_ok catch naturally.
#
# File I/O functions used by fetch_kit_version and
# fetch_kit_version_src are also stubbed to avoid filesystem
# side effects.
# ============================================================

# -- Curl mock (shared with Service::Github) --
my @curl_calls;
my @curl_responses;
{
	no warnings 'redefine';
	*Service::Github::curl = sub {
		push @curl_calls, [@_];
		my $resp = shift @curl_responses;
		unless ($resp) {
			return (500, 'No mock response queued', '', '');
		}
		return @$resp;
	};
}

sub queue_curl_response { push @curl_responses, [@_] }
sub reset_mocks {
	@curl_calls     = ();
	@curl_responses = ();
}

# -- Output suppression --
{
	no warnings 'redefine';
	for my $ns (qw(Service::Github Genesis::Kit::Provider::Github)) {
		no strict 'refs';
		*{"${ns}::info"}    = sub {};
		*{"${ns}::error"}   = sub {};
		*{"${ns}::trace"}   = sub {};
		*{"${ns}::debug"}   = sub {};
		*{"${ns}::warning"} = sub {};
	}
}

# -- File I/O stubs (Provider::Github namespace) --
{
	no warnings 'redefine';
	*Genesis::Kit::Provider::Github::mkfile_or_fail   = sub { return 1 };
	*Genesis::Kit::Provider::Github::slurp            = sub { return '' };
	*Genesis::Kit::Provider::Github::chmod_or_fail    = sub { return 1 };
	*Genesis::Kit::Provider::Github::humanize_path    = sub { return $_[0] };
}

# -- Curl mock for the Provider namespace (used by fetch_kit_version) --
{
	no warnings 'redefine';
	*Genesis::Kit::Provider::Github::curl = sub {
		push @curl_calls, [@_];
		my $resp = shift @curl_responses;
		unless ($resp) {
			return (500, 'No mock response queued', '', '');
		}
		return @$resp;
	};
}

# -- Clear credentials to avoid env var interference --
local $ENV{GITHUB_USER};
local $ENV{GITHUB_AUTH_TOKEN};

# ============================================================
# Helpers
# ============================================================

sub encode_json_simple {
	return JSON::PP->new->encode(shift);
}

sub make_repo { { name => $_[0] } }

sub make_release {
	my (%opts) = @_;
	my $ver  = $opts{version} // '1.0.0';
	my $vtag = $opts{tag}     // "v$ver";
	return {
		tag_name     => $vtag,
		name         => $vtag,
		body         => $opts{body} // "Release notes for $vtag",
		draft        => $opts{draft}      ? JSON::PP::true : JSON::PP::false,
		prerelease   => $opts{prerelease} ? JSON::PP::true : JSON::PP::false,
		published_at => $opts{published_at} // "2024-01-01T00:00:00Z",
		created_at   => $opts{created_at}   // "2024-01-01T00:00:00Z",
		tarball_url  => $opts{tarball_url}  // "https://api.github.com/repos/test-org/$opts{kit_name}-genesis-kit/tarball/$vtag",
		assets       => $opts{assets}       // [],
	};
}

sub make_asset {
	my (%opts) = @_;
	return {
		name                 => $opts{name} // 'release.tar.gz',
		browser_download_url => $opts{url}  // 'https://example.com/release.tar.gz',
	};
}

# Build a provider with sensible defaults and pre-populated caches
# when needed for tests that skip the HTTP layer.
sub build_provider {
	my (%opts) = @_;
	return Genesis::Kit::Provider::Github->new(
		organization => $opts{organization} // 'test-org',
		label        => $opts{label}        // undef,
		domain       => $opts{domain}       // undef,
		tls          => $opts{tls}          // undef,
	);
}

# ============================================================
# 1. Constants
# ============================================================
subtest 'constants' => sub {
	is(Genesis::Kit::Provider::Github::DEFAULT_DOMAIN, 'github.com',
		'DEFAULT_DOMAIN is github.com');
	is(Genesis::Kit::Provider::Github::DEFAULT_LABEL,
		'Custom Github-based Kit Provider',
		'DEFAULT_LABEL is correct');
	is(Genesis::Kit::Provider::Github::DEFAULT_TLS, 'yes',
		'DEFAULT_TLS is yes');
};

# ============================================================
# 2. new() constructor
# ============================================================
subtest 'new() constructor' => sub {

	subtest 'minimal config (org only)' => sub {
		my $p = Genesis::Kit::Provider::Github->new(
			organization => 'my-org',
		);
		isa_ok $p, 'Genesis::Kit::Provider::Github';
		is $p->label, 'Custom Github-based Kit Provider',
			'label defaults to DEFAULT_LABEL';
		is $p->domain, 'github.com',
			'domain defaults to DEFAULT_DOMAIN';
		is $p->tls, 'yes',
			'tls defaults to DEFAULT_TLS';
		is $p->organization, 'my-org',
			'organization stored correctly';
		isa_ok $p->remote, 'Service::Github',
			'remote is a Service::Github instance';
	};

	subtest 'full config' => sub {
		my $p = Genesis::Kit::Provider::Github->new(
			label        => 'My Custom Provider',
			domain       => 'ghe.example.com',
			organization => 'custom-org',
			tls          => 'skip',
		);
		is $p->label, 'My Custom Provider', 'custom label stored';
		is $p->domain, 'ghe.example.com',   'custom domain stored';
		is $p->organization, 'custom-org',  'custom org stored';
		is $p->tls, 'skip',                 'custom tls stored';
	};

	subtest 'TLS insecure converts to skip' => sub {
		my $p = Genesis::Kit::Provider::Github->new(
			organization => 'my-org',
			tls          => 'insecure',
		);
		is $p->tls, 'skip',
			'insecure TLS value converted to skip';
	};

	subtest 'creates Service::Github remote object with correct params' => sub {
		my $p = Genesis::Kit::Provider::Github->new(
			label        => 'Test Provider',
			domain       => 'custom.github.com',
			organization => 'the-org',
			tls          => 'no',
		);
		my $remote = $p->remote;
		isa_ok $remote, 'Service::Github';
		is $remote->{domain}, 'custom.github.com',
			'remote domain matches';
		is $remote->{org}, 'the-org',
			'remote org matches';
		is $remote->{tls}, 'no',
			'remote tls matches';
		is $remote->{label}, 'Test Provider',
			'remote label matches';
	};
};

# ============================================================
# 3. init() class method
# ============================================================
subtest 'init() class method' => sub {

	subtest 'requires kit-provider-org' => sub {
		throws_ok {
			Genesis::Kit::Provider::Github->init();
		} qr/requires specifying.*organization/s,
			'bails without kit-provider-org';
	};

	subtest 'custom label in bail message when org missing' => sub {
		throws_ok {
			Genesis::Kit::Provider::Github->init(
				'kit-provider-name' => 'My Github',
			);
		} qr/My Github kit provider requires/,
			'bail message uses custom label';
	};

	subtest 'minimal: just org' => sub {
		my $p = Genesis::Kit::Provider::Github->init(
			'kit-provider-org' => 'init-org',
		);
		isa_ok $p, 'Genesis::Kit::Provider::Github';
		is $p->organization, 'init-org',
			'org from init option';
		is $p->label, 'Custom Github-based Kit Provider',
			'label defaults';
		is $p->domain, 'github.com',
			'domain defaults';
		is $p->tls, 'yes',
			'tls defaults to yes';
	};

	subtest 'full options' => sub {
		my $p = Genesis::Kit::Provider::Github->init(
			'kit-provider-name'   => 'Enterprise Github',
			'kit-provider-domain' => 'ghe.corp.com',
			'kit-provider-org'    => 'corp-org',
			'kit-provider-tls'    => 'skip',
		);
		is $p->label, 'Enterprise Github',
			'custom label from init';
		is $p->domain, 'ghe.corp.com',
			'custom domain from init';
		is $p->organization, 'corp-org',
			'custom org from init';
		is $p->tls, 'skip',
			'custom tls from init';
	};

	subtest 'invalid tls bails' => sub {
		throws_ok {
			Genesis::Kit::Provider::Github->init(
				'kit-provider-org' => 'x',
				'kit-provider-tls' => 'invalid',
			);
		} qr/--kit-provider-tls only accepts/,
			'invalid tls value raises fatal error';
	};

	subtest 'valid tls values accepted' => sub {
		for my $tls_val (qw(no yes skip)) {
			lives_ok {
				Genesis::Kit::Provider::Github->init(
					'kit-provider-org' => 'x',
					'kit-provider-tls' => $tls_val,
				);
			} "tls value '$tls_val' accepted";
		}
	};
};

# ============================================================
# 4. opts() class method
# ============================================================
subtest 'opts() class method' => sub {
	my @opts = Genesis::Kit::Provider::Github->opts();
	is scalar(@opts), 5, 'returns 5 option specs';
	ok((grep { $_ eq 'kit-provider-name=s' }         @opts), 'includes kit-provider-name');
	ok((grep { $_ eq 'kit-provider-domain=s' }       @opts), 'includes kit-provider-domain');
	ok((grep { $_ eq 'kit-provider-org=s' }          @opts), 'includes kit-provider-org');
	ok((grep { $_ eq 'kit-provider-tls=s' }          @opts), 'includes kit-provider-tls');
	ok((grep { $_ eq 'kit-provider-access-token=s' } @opts), 'includes kit-provider-access-token');
};

# ============================================================
# 5. opts_help()
# ============================================================
subtest 'opts_help()' => sub {

	subtest 'returns help when github in valid_types' => sub {
		my $help = Genesis::Kit::Provider::Github->opts_help(
			valid_types => [qw(genesis-community github)],
		);
		ok length($help) > 0, 'help text is non-empty';
		like $help, qr/Kit Provider `github`/,
			'contains github provider header';
		like $help, qr/--kit-provider-org/,
			'mentions --kit-provider-org option';
		like $help, qr/--kit-provider-domain/,
			'mentions --kit-provider-domain option';
		like $help, qr/--kit-provider-tls/,
			'mentions --kit-provider-tls option';
	};

	subtest 'returns empty when github not in valid_types' => sub {
		my $help = Genesis::Kit::Provider::Github->opts_help(
			valid_types => [qw(genesis-community)],
		);
		is $help, '', 'returns empty string when github not listed';
	};

	subtest 'returns empty when valid_types is empty' => sub {
		my $help = Genesis::Kit::Provider::Github->opts_help(
			valid_types => [],
		);
		is $help, '', 'returns empty string for empty valid_types';
	};
};

# ============================================================
# 6. Accessor delegation
# ============================================================
subtest 'accessor delegation' => sub {
	my $p = Genesis::Kit::Provider::Github->new(
		label        => 'Accessor Test',
		domain       => 'accessor.example.com',
		organization => 'accessor-org',
		tls          => 'skip',
	);

	is $p->label, 'Accessor Test',
		'label returns stored label';
	isa_ok $p->remote, 'Service::Github',
		'remote returns Service::Github object';
	is $p->domain, 'accessor.example.com',
		'domain delegates to remote->{domain}';
	is $p->organization, 'accessor-org',
		'organization delegates to remote->{org}';
	is $p->tls, 'skip',
		'tls delegates to remote->{tls}';
	ok !defined($p->credentials),
		'credentials are undef when no env vars set';

	subtest 'base_url delegates to remote' => sub {
		is $p->base_url, 'https://api.accessor.example.com',
			'base_url computed from remote';

		my $p2 = Genesis::Kit::Provider::Github->new(
			organization => 'x',
			tls          => 'no',
		);
		is $p2->base_url, 'http://api.github.com',
			'base_url uses http when tls is no';
	};
};

# ============================================================
# 7. config()
# ============================================================
subtest 'config()' => sub {

	subtest 'always includes type and organization' => sub {
		my $p = build_provider(organization => 'conf-org');
		my %cfg = $p->config;
		is $cfg{type}, 'github',
			'type is always github';
		is $cfg{organization}, 'conf-org',
			'organization is always included';
	};

	subtest 'omits label, domain, tls when equal to defaults' => sub {
		my $p = Genesis::Kit::Provider::Github->new(
			organization => 'default-org',
		);
		my %cfg = $p->config;
		ok !exists($cfg{label}),
			'label omitted when it equals DEFAULT_LABEL';
		ok !exists($cfg{domain}),
			'domain omitted when it equals DEFAULT_DOMAIN';
		ok !exists($cfg{tls}),
			'tls omitted when it equals DEFAULT_TLS';
	};

	subtest 'includes label when non-default' => sub {
		my $p = Genesis::Kit::Provider::Github->new(
			organization => 'x',
			label        => 'My Label',
		);
		my %cfg = $p->config;
		is $cfg{label}, 'My Label',
			'label included when non-default';
	};

	subtest 'includes domain when non-default' => sub {
		my $p = Genesis::Kit::Provider::Github->new(
			organization => 'x',
			domain       => 'ghe.corp.com',
		);
		my %cfg = $p->config;
		is $cfg{domain}, 'ghe.corp.com',
			'domain included when non-default';
	};

	subtest 'includes tls when non-default' => sub {
		my $p = Genesis::Kit::Provider::Github->new(
			organization => 'x',
			tls          => 'no',
		);
		my %cfg = $p->config;
		is $cfg{tls}, 'no',
			'tls included when non-default';
	};

	subtest 'all non-default values included together' => sub {
		my $p = Genesis::Kit::Provider::Github->new(
			label        => 'Full Config',
			domain       => 'custom.gh.com',
			organization => 'full-org',
			tls          => 'skip',
		);
		my %cfg = $p->config;
		is $cfg{type},         'github',        'type is github';
		is $cfg{organization}, 'full-org',      'org included';
		is $cfg{label},        'Full Config',   'label included';
		is $cfg{domain},       'custom.gh.com', 'domain included';
		is $cfg{tls},          'skip',          'tls included';
	};
};

# ============================================================
# 8. kit_names()
# ============================================================
subtest 'kit_names()' => sub {
	reset_mocks();

	subtest 'fetches and strips -genesis-kit suffix' => sub {
		reset_mocks();
		my $p = build_provider();

		# 1st curl: HEAD for Provider::Github->check() => 200 OK
		queue_curl_response(200, 'OK', '');

		# 2nd curl: HEAD for Service::Github->repos() internal check => 200
		queue_curl_response(200, 'OK', '');

		# 3rd curl: GET repos page 1 => repo list
		my $repos = [
			make_repo('cf-genesis-kit'),
			make_repo('bosh-genesis-kit'),
			make_repo('vault-genesis-kit'),
			make_repo('not-a-kit'),
		];
		queue_curl_response(200, 'OK', encode_json_simple($repos), '');

		# 4th curl: GET repos page 2 => empty (terminates pagination)
		queue_curl_response(200, 'OK', encode_json_simple([]), '');

		my @names = $p->kit_names;
		my @sorted = sort @names;
		is_deeply \@sorted, [qw(bosh cf vault)],
			'strips -genesis-kit suffix and filters non-kit repos';
	};

	subtest 'caches results on second call' => sub {
		reset_mocks();
		my $p = build_provider();

		# Pre-populate the cache
		$p->{_kits} = [qw(cached-kit another-kit)];

		# No curl responses queued — if it tries to call curl, it fails
		my @names = $p->kit_names;
		is_deeply [sort @names], [qw(another-kit cached-kit)],
			'returns cached kit names without network call';
		is scalar(@curl_calls), 0,
			'no curl calls made when cache is populated';
	};

	subtest 'filter parameter works' => sub {
		reset_mocks();
		my $p = build_provider();
		$p->{_kits} = [qw(cf bosh vault shield concourse)];

		my @names = $p->kit_names('^sh');
		is_deeply [sort @names], [qw(shield)],
			'filter narrows results to matching names';
	};

	subtest 'filter matching multiple kits' => sub {
		reset_mocks();
		my $p = build_provider();
		$p->{_kits} = [qw(cf bosh vault shield concourse)];

		my @names = $p->kit_names('^[cv]');
		is_deeply [sort @names], [qw(cf concourse vault)],
			'regex filter matches multiple kits';
	};

	subtest 'check failure bails' => sub {
		reset_mocks();
		my $p = build_provider();

		# HEAD check returns 404 (Provider check returns status string)
		queue_curl_response(404, 'Not Found', '');

		throws_ok {
			$p->kit_names;
		} qr/Could not find/,
			'bails when check returns error status';
	};

	subtest 'no matching kits bails' => sub {
		reset_mocks();
		my $p = build_provider();
		$p->{_kits} = [qw(cf bosh vault)];

		throws_ok {
			$p->kit_names('nonexistent-pattern-xyz');
		} qr/No genesis kit repositories found/,
			'bails when filter matches no kits';
	};
};

# ============================================================
# 9. kit_releases()
# ============================================================
subtest 'kit_releases()' => sub {

	subtest 'missing name bails' => sub {
		reset_mocks();
		my $p = build_provider();

		throws_ok {
			$p->kit_releases(undef);
		} qr/Missing name for retrieving kit releases/,
			'bails on undef name';

		throws_ok {
			$p->kit_releases('');
		} qr/Missing name for retrieving kit releases/,
			'bails on empty string name';
	};

	subtest 'success path with pre-populated cache' => sub {
		reset_mocks();
		my $p = build_provider();

		# Pre-populate the releases cache
		my @releases = (
			make_release(version => '2.0.0', kit_name => 'cf'),
			make_release(version => '1.5.0', kit_name => 'cf'),
		);
		$p->{_releases} = { cf => \@releases };

		my @result = $p->kit_releases('cf');
		is scalar(@result), 2, 'returns 2 releases from cache';
		is $result[0]->{tag_name}, 'v2.0.0', 'first release tag correct';
		is $result[1]->{tag_name}, 'v1.5.0', 'second release tag correct';
	};

	subtest 'caches results after first fetch' => sub {
		reset_mocks();
		my $p = build_provider();

		my @releases = (
			make_release(version => '1.0.0', kit_name => 'bosh'),
		);
		$p->{_releases} = { bosh => \@releases };

		# First call reads from cache
		my @r1 = $p->kit_releases('bosh');
		# Second call also reads from cache, no extra curl calls
		my @r2 = $p->kit_releases('bosh');
		is scalar(@curl_calls), 0,
			'no curl calls when releases are cached';
		is_deeply \@r1, \@r2,
			'both calls return the same data';
	};
};

# ============================================================
# 10. kit_versions()
# ============================================================
subtest 'kit_versions()' => sub {

	subtest 'delegates to remote->versions with correct repo name' => sub {
		reset_mocks();
		my $p = build_provider();

		# Pre-populate the releases cache on the remote so versions()
		# does not need to fetch anything.
		my $release = make_release(
			version  => '1.0.0',
			kit_name => 'cf',
			assets   => [
				make_asset(
					name => 'cf-1.0.0.tar.gz',
					url  => 'https://example.com/cf-1.0.0.tar.gz',
				),
			],
		);
		$p->remote->{_releases} = { 'cf-genesis-kit' => [$release] };

		my @versions = $p->kit_versions('cf');
		is scalar(@versions), 1, 'returns 1 version';
		is $versions[0]->{version}, '1.0.0', 'version is correct';
		is $versions[0]->{url}, 'https://example.com/cf-1.0.0.tar.gz',
			'asset URL extracted via asset_filter';
	};

	subtest 'asset_filter matches kit tarball naming convention' => sub {
		reset_mocks();
		my $p = build_provider();

		my $release = make_release(
			version  => '2.5.3',
			kit_name => 'bosh',
			assets   => [
				make_asset(
					name => 'bosh-2.5.3.tgz',
					url  => 'https://example.com/bosh-2.5.3.tgz',
				),
				make_asset(
					name => 'checksums.txt',
					url  => 'https://example.com/checksums.txt',
				),
			],
		);
		$p->remote->{_releases} = { 'bosh-genesis-kit' => [$release] };

		my @versions = $p->kit_versions('bosh');
		is scalar(@versions), 1, 'returns 1 version';
		is $versions[0]->{url}, 'https://example.com/bosh-2.5.3.tgz',
			'asset_filter selects the tgz file';
	};

	subtest 'asset_filter matches tar.gz variant' => sub {
		reset_mocks();
		my $p = build_provider();

		my $release = make_release(
			version  => '3.0.0',
			kit_name => 'vault',
			assets   => [
				make_asset(
					name => 'vault-3.0.0.tar.gz',
					url  => 'https://example.com/vault-3.0.0.tar.gz',
				),
			],
		);
		$p->remote->{_releases} = { 'vault-genesis-kit' => [$release] };

		my @versions = $p->kit_versions('vault');
		is scalar(@versions), 1, 'returns 1 version';
		is $versions[0]->{url}, 'https://example.com/vault-3.0.0.tar.gz',
			'asset_filter matches .tar.gz naming';
	};
};

# ============================================================
# 11. fetch_kit_version()
# ============================================================
subtest 'fetch_kit_version()' => sub {

	subtest 'strips v prefix from version' => sub {
		reset_mocks();
		my $p = build_provider();

		# Pre-populate caches to skip HTTP for kit_versions
		my $release = make_release(
			version  => '1.2.0',
			kit_name => 'cf',
			assets   => [
				make_asset(
					name => 'cf-1.2.0.tar.gz',
					url  => 'https://example.com/cf-1.2.0.tar.gz',
				),
			],
		);
		$p->remote->{_releases} = { 'cf-genesis-kit' => [$release] };

		# Gzip magic bytes for valid tarball
		my $gzip_data = "\x1f\x8b" . ("x" x 100);

		# Queue curl for the download
		queue_curl_response(200, 'OK', $gzip_data, '');

		my ($name, $version, $file) = $p->fetch_kit_version('cf', 'v1.2.0', '/tmp', 1);
		is $name, 'cf', 'name returned';
		is $version, '1.2.0', 'v prefix stripped';
		is $file, '/tmp/cf-1.2.0.tar.gz', 'file path correct';
	};

	subtest 'resolves latest when version is undef' => sub {
		reset_mocks();
		my $p = build_provider();

		my $release = make_release(
			version  => '3.0.0',
			kit_name => 'cf',
			assets   => [
				make_asset(
					name => 'cf-3.0.0.tar.gz',
					url  => 'https://example.com/cf-3.0.0.tar.gz',
				),
			],
		);
		$p->remote->{_releases} = { 'cf-genesis-kit' => [$release] };

		my $gzip_data = "\x1f\x8b" . ("x" x 100);
		queue_curl_response(200, 'OK', $gzip_data, '');

		my ($name, $version, $file) = $p->fetch_kit_version('cf', undef, '/tmp', 1);
		is $version, '3.0.0', 'resolved to latest version';
	};

	subtest 'resolves latest when version is "latest"' => sub {
		reset_mocks();
		my $p = build_provider();

		my $release = make_release(
			version  => '2.0.0',
			kit_name => 'cf',
			assets   => [
				make_asset(
					name => 'cf-2.0.0.tar.gz',
					url  => 'https://example.com/cf-2.0.0.tar.gz',
				),
			],
		);
		$p->remote->{_releases} = { 'cf-genesis-kit' => [$release] };

		my $gzip_data = "\x1f\x8b" . ("x" x 100);
		queue_curl_response(200, 'OK', $gzip_data, '');

		my ($name, $version, $file) = $p->fetch_kit_version('cf', 'latest', '/tmp', 1);
		is $version, '2.0.0', 'resolved "latest" to actual version';
	};

	subtest 'bails when latest version not found' => sub {
		reset_mocks();
		my $p = build_provider();

		# Empty releases — no latest version
		$p->remote->{_releases} = { 'cf-genesis-kit' => [] };

		throws_ok {
			$p->fetch_kit_version('cf', undef, '/tmp', 1);
		} qr/No latest version of cf kit found/,
			'bails when no latest version available';
	};

	subtest 'version not found bails' => sub {
		reset_mocks();
		my $p = build_provider();

		my $release = make_release(
			version  => '1.0.0',
			kit_name => 'cf',
			assets   => [
				make_asset(
					name => 'cf-1.0.0.tar.gz',
					url  => 'https://example.com/cf-1.0.0.tar.gz',
				),
			],
		);
		$p->remote->{_releases} = { 'cf-genesis-kit' => [$release] };

		throws_ok {
			$p->fetch_kit_version('cf', '99.99.99', '/tmp', 1);
		} qr/was not found/,
			'bails when requested version does not exist';
	};

	subtest 'missing download URL bails' => sub {
		reset_mocks();
		my $p = build_provider();

		# Release exists but asset has no download URL
		my $release = make_release(
			version  => '1.0.0',
			kit_name => 'cf',
			assets   => [
				make_asset(
					name => 'cf-1.0.0.tar.gz',
					url  => '',
				),
			],
		);
		$p->remote->{_releases} = { 'cf-genesis-kit' => [$release] };

		throws_ok {
			$p->fetch_kit_version('cf', '1.0.0', '/tmp', 1);
		} qr/missing its resource url/,
			'bails when version has no download URL';
	};

	subtest 'non-200 download bails' => sub {
		reset_mocks();
		my $p = build_provider();

		my $release = make_release(
			version  => '1.0.0',
			kit_name => 'cf',
			assets   => [
				make_asset(
					name => 'cf-1.0.0.tar.gz',
					url  => 'https://example.com/cf-1.0.0.tar.gz',
				),
			],
		);
		$p->remote->{_releases} = { 'cf-genesis-kit' => [$release] };

		queue_curl_response(500, 'Internal Server Error', '', '');

		throws_ok {
			$p->fetch_kit_version('cf', '1.0.0', '/tmp', 1);
		} qr/Failed to download.*returned a 500 status code/s,
			'bails on non-200 download response';
	};

	subtest 'empty response bails' => sub {
		reset_mocks();
		my $p = build_provider();

		my $release = make_release(
			version  => '1.0.0',
			kit_name => 'cf',
			assets   => [
				make_asset(
					name => 'cf-1.0.0.tar.gz',
					url  => 'https://example.com/cf-1.0.0.tar.gz',
				),
			],
		);
		$p->remote->{_releases} = { 'cf-genesis-kit' => [$release] };

		queue_curl_response(200, 'OK', '', '');

		throws_ok {
			$p->fetch_kit_version('cf', '1.0.0', '/tmp', 1);
		} qr/received empty response/,
			'bails on empty response body';
	};

	subtest 'HTML response bails' => sub {
		reset_mocks();
		my $p = build_provider();

		my $release = make_release(
			version  => '1.0.0',
			kit_name => 'cf',
			assets   => [
				make_asset(
					name => 'cf-1.0.0.tar.gz',
					url  => 'https://example.com/cf-1.0.0.tar.gz',
				),
			],
		);
		$p->remote->{_releases} = { 'cf-genesis-kit' => [$release] };

		queue_curl_response(200, 'OK', '<html><body>Login Required</body></html>', '');

		throws_ok {
			$p->fetch_kit_version('cf', '1.0.0', '/tmp', 1);
		} qr/received an HTML page/,
			'bails when response is HTML (captive portal)';
	};

	subtest 'non-gzip data warns but does not bail' => sub {
		reset_mocks();
		my $p = build_provider();

		my $release = make_release(
			version  => '1.0.0',
			kit_name => 'cf',
			assets   => [
				make_asset(
					name => 'cf-1.0.0.tar.gz',
					url  => 'https://example.com/cf-1.0.0.tar.gz',
				),
			],
		);
		$p->remote->{_releases} = { 'cf-genesis-kit' => [$release] };

		# Data that is not gzip (does not start with \x1f\x8b)
		# but is not empty and not HTML
		my $non_gzip_data = "PK" . ("x" x 100);
		queue_curl_response(200, 'OK', $non_gzip_data, '');

		my ($name, $version, $file);
		lives_ok {
			($name, $version, $file) = $p->fetch_kit_version('cf', '1.0.0', '/tmp', 1);
		} 'non-gzip data warns but completes successfully';
		is $name, 'cf', 'name returned despite non-gzip data';
		is $version, '1.0.0', 'version returned';
	};

	subtest 'success returns (name, version, file)' => sub {
		reset_mocks();
		my $p = build_provider();

		my $release = make_release(
			version  => '2.1.0',
			kit_name => 'bosh',
			assets   => [
				make_asset(
					name => 'bosh-2.1.0.tar.gz',
					url  => 'https://example.com/bosh-2.1.0.tar.gz',
				),
			],
		);
		$p->remote->{_releases} = { 'bosh-genesis-kit' => [$release] };

		my $gzip_data = "\x1f\x8b" . ("x" x 200);
		queue_curl_response(200, 'OK', $gzip_data, '');

		my ($name, $version, $file) = $p->fetch_kit_version('bosh', '2.1.0', '/tmp/kits', 1);
		is $name, 'bosh',                        'name matches';
		is $version, '2.1.0',                    'version matches';
		is $file, '/tmp/kits/bosh-2.1.0.tar.gz', 'file path matches expected pattern';
	};
};

# ============================================================
# 12. fetch_kit_version_src()
# ============================================================
subtest 'fetch_kit_version_src()' => sub {

	subtest 'strips v prefix from version' => sub {
		reset_mocks();
		my $p = build_provider();

		my @releases = (
			make_release(
				version     => '1.0.0',
				kit_name    => 'cf',
				tarball_url => 'https://api.github.com/repos/test-org/cf-genesis-kit/tarball/v1.0.0',
			),
		);
		$p->{_releases} = { cf => \@releases };

		my $gzip_data = "\x1f\x8b" . ("x" x 100);
		queue_curl_response(200, 'OK', $gzip_data, '');

		my ($name, $version, $file) = $p->fetch_kit_version_src('cf', 'v1.0.0', '/tmp', 1);
		is $version, '1.0.0', 'v prefix stripped from version';
		is $file, '/tmp/cf-1.0.0-src.tar.gz', 'src file path correct';
	};

	subtest 'resolves latest when version is undef' => sub {
		reset_mocks();
		my $p = build_provider();

		# For latest_version_of, we need remote releases for kit_versions
		my $release = make_release(
			version  => '4.0.0',
			kit_name => 'cf',
			assets   => [
				make_asset(
					name => 'cf-4.0.0.tar.gz',
					url  => 'https://example.com/cf-4.0.0.tar.gz',
				),
			],
			tarball_url => 'https://api.github.com/repos/test-org/cf-genesis-kit/tarball/v4.0.0',
		);
		$p->remote->{_releases} = { 'cf-genesis-kit' => [$release] };

		# Also populate the provider-level releases cache for kit_releases
		$p->{_releases} = { cf => [$release] };

		my $gzip_data = "\x1f\x8b" . ("x" x 100);
		queue_curl_response(200, 'OK', $gzip_data, '');

		my ($name, $version, $file) = $p->fetch_kit_version_src('cf', undef, '/tmp', 1);
		is $version, '4.0.0', 'resolved to latest version';
	};

	subtest 'bails when latest version not found' => sub {
		reset_mocks();
		my $p = build_provider();

		$p->remote->{_releases} = { 'cf-genesis-kit' => [] };

		throws_ok {
			$p->fetch_kit_version_src('cf', undef, '/tmp', 1);
		} qr/No latest version of cf kit found/,
			'bails when no latest version';
	};

	subtest 'version not found bails' => sub {
		reset_mocks();
		my $p = build_provider();

		my @releases = (
			make_release(version => '1.0.0', kit_name => 'cf'),
		);
		$p->{_releases} = { cf => \@releases };

		throws_ok {
			$p->fetch_kit_version_src('cf', '99.99.99', '/tmp', 1);
		} qr/was not found/,
			'bails when version not found in releases';
	};

	subtest 'missing tarball_url bails' => sub {
		reset_mocks();
		my $p = build_provider();

		my $release = make_release(
			version     => '1.0.0',
			kit_name    => 'cf',
			tarball_url => '',
		);
		$p->{_releases} = { cf => [$release] };

		throws_ok {
			$p->fetch_kit_version_src('cf', '1.0.0', '/tmp', 1);
		} qr/missing its tarball url/,
			'bails when tarball_url is empty';
	};

	subtest 'non-200 download bails' => sub {
		reset_mocks();
		my $p = build_provider();

		my @releases = (
			make_release(
				version     => '1.0.0',
				kit_name    => 'cf',
				tarball_url => 'https://example.com/tarball.tar.gz',
			),
		);
		$p->{_releases} = { cf => \@releases };

		queue_curl_response(403, 'Forbidden', '', '');

		throws_ok {
			$p->fetch_kit_version_src('cf', '1.0.0', '/tmp', 1);
		} qr/Failed to download.*source.*returned a 403 status code/s,
			'bails on non-200 download';
	};

	subtest 'empty response bails' => sub {
		reset_mocks();
		my $p = build_provider();

		my @releases = (
			make_release(
				version     => '1.0.0',
				kit_name    => 'cf',
				tarball_url => 'https://example.com/tarball.tar.gz',
			),
		);
		$p->{_releases} = { cf => \@releases };

		queue_curl_response(200, 'OK', '', '');

		throws_ok {
			$p->fetch_kit_version_src('cf', '1.0.0', '/tmp', 1);
		} qr/received empty response/,
			'bails on empty response body';
	};

	subtest 'HTML response bails' => sub {
		reset_mocks();
		my $p = build_provider();

		my @releases = (
			make_release(
				version     => '1.0.0',
				kit_name    => 'cf',
				tarball_url => 'https://example.com/tarball.tar.gz',
			),
		);
		$p->{_releases} = { cf => \@releases };

		queue_curl_response(200, 'OK', '<!DOCTYPE html><html>Login</html>', '');

		throws_ok {
			$p->fetch_kit_version_src('cf', '1.0.0', '/tmp', 1);
		} qr/received an HTML page/,
			'bails when response is HTML';
	};

	subtest 'non-gzip data warns but does not bail' => sub {
		reset_mocks();
		my $p = build_provider();

		my @releases = (
			make_release(
				version     => '1.0.0',
				kit_name    => 'cf',
				tarball_url => 'https://example.com/tarball.tar.gz',
			),
		);
		$p->{_releases} = { cf => \@releases };

		my $non_gzip_data = "PK" . ("x" x 100);
		queue_curl_response(200, 'OK', $non_gzip_data, '');

		my ($name, $version, $file);
		lives_ok {
			($name, $version, $file) = $p->fetch_kit_version_src('cf', '1.0.0', '/tmp', 1);
		} 'non-gzip data warns but completes';
		is $name, 'cf', 'name returned';
		is $version, '1.0.0', 'version returned';
	};

	subtest 'success returns (name, version, file)' => sub {
		reset_mocks();
		my $p = build_provider();

		my @releases = (
			make_release(
				version     => '2.0.0',
				kit_name    => 'bosh',
				tarball_url => 'https://api.github.com/repos/test-org/bosh-genesis-kit/tarball/v2.0.0',
			),
		);
		$p->{_releases} = { bosh => \@releases };

		my $gzip_data = "\x1f\x8b" . ("x" x 200);
		queue_curl_response(200, 'OK', $gzip_data, '');

		my ($name, $version, $file) = $p->fetch_kit_version_src('bosh', '2.0.0', '/tmp/src', 1);
		is $name, 'bosh',                              'name matches';
		is $version, '2.0.0',                          'version matches';
		is $file, '/tmp/src/bosh-2.0.0-src.tar.gz',   'src file path matches';
	};
};

# ============================================================
# 13. latest_version_of()
# ============================================================
subtest 'latest_version_of()' => sub {

	subtest 'missing name bails' => sub {
		reset_mocks();
		my $p = build_provider();

		throws_ok {
			$p->latest_version_of(undef);
		} qr/Missing name for retrieving kit releases/,
			'bails on undef name';

		throws_ok {
			$p->latest_version_of('');
		} qr/Missing name for retrieving kit releases/,
			'bails on empty name';
	};

	subtest 'returns version string for latest with URL' => sub {
		reset_mocks();
		my $p = build_provider();

		my @releases = map {
			make_release(
				version  => $_->[0],
				kit_name => 'cf',
				assets   => [
					make_asset(
						name => "cf-$_->[0].tar.gz",
						url  => $_->[1],
					),
				],
			);
		} (
			['2.0.0', 'https://example.com/cf-2.0.0.tar.gz'],
			['1.5.0', 'https://example.com/cf-1.5.0.tar.gz'],
		);
		$p->remote->{_releases} = { 'cf-genesis-kit' => \@releases };

		my $ver = $p->latest_version_of('cf');
		is $ver, '2.0.0', 'returns latest version with a download URL';
	};

	subtest 'returns version with URL when latest has one' => sub {
		reset_mocks();
		my $p = build_provider();

		my $release_with_url = make_release(
			version  => '3.0.0',
			kit_name => 'cf',
			assets   => [
				make_asset(
					name => 'cf-3.0.0.tar.gz',
					url  => 'https://example.com/cf-3.0.0.tar.gz',
				),
			],
		);
		my $release_older = make_release(
			version  => '2.0.0',
			kit_name => 'cf',
			assets   => [
				make_asset(
					name => 'cf-2.0.0.tar.gz',
					url  => 'https://example.com/cf-2.0.0.tar.gz',
				),
			],
		);
		$p->remote->{_releases} = {
			'cf-genesis-kit' => [$release_with_url, $release_older],
		};

		my $ver = $p->latest_version_of('cf');
		is $ver, '3.0.0',
			'returns latest version when it has a download URL';
	};

	subtest 'returns undef when latest version has no URL' => sub {
		reset_mocks();
		my $p = build_provider();

		# The latest semver has no URL; latest=>1 picks only the top one
		my $release_no_url = make_release(
			version  => '3.0.0',
			kit_name => 'cf',
			assets   => [
				make_asset(name => 'cf-3.0.0.tar.gz', url => ''),
			],
		);
		my $release_with_url = make_release(
			version  => '2.0.0',
			kit_name => 'cf',
			assets   => [
				make_asset(
					name => 'cf-2.0.0.tar.gz',
					url  => 'https://example.com/cf-2.0.0.tar.gz',
				),
			],
		);
		$p->remote->{_releases} = {
			'cf-genesis-kit' => [$release_no_url, $release_with_url],
		};

		my $ver = $p->latest_version_of('cf');
		ok !defined($ver),
			'returns undef when latest semver has no download URL (latest=>1 narrows first)';
	};

	subtest 'returns undef when no versions have URLs' => sub {
		reset_mocks();
		my $p = build_provider();

		my $release = make_release(
			version  => '1.0.0',
			kit_name => 'cf',
			assets   => [
				make_asset(name => 'cf-1.0.0.tar.gz', url => ''),
			],
		);
		$p->remote->{_releases} = { 'cf-genesis-kit' => [$release] };

		my $ver = $p->latest_version_of('cf');
		ok !defined($ver), 'returns undef when no versions have download URLs';
	};

	subtest 'returns undef when no releases exist' => sub {
		reset_mocks();
		my $p = build_provider();
		$p->remote->{_releases} = { 'cf-genesis-kit' => [] };

		my $ver = $p->latest_version_of('cf');
		ok !defined($ver), 'returns undef for empty release list';
	};
};

# ============================================================
# 14. status()
# ============================================================
subtest 'status()' => sub {

	subtest 'success returns correct structure' => sub {
		reset_mocks();
		my $p = build_provider(
			label        => 'Status Test',
			domain       => 'status.example.com',
			organization => 'status-org',
		);

		# Queue check HEAD => 200
		queue_curl_response(200, 'OK', '');

		# Pre-populate kit_names cache for status call
		$p->{_kits} = [qw(cf bosh)];

		my %info = $p->status;
		is $info{type}, 'github',           'type is github';
		is $info{status}, 'ok',             'status is ok on 200';
		is $info{"Name"}, 'Status Test',    'Name matches label';
		is $info{"Domain"}, 'status.example.com', 'Domain matches';
		is $info{"Org"}, 'status-org',      'Org matches organization';
		is_deeply $info{extras}, ["Name", "Domain", "Org", "Use TLS"],
			'extras array has correct keys';
		is ref($info{kits}), 'ARRAY',       'kits is an arrayref for non-verbose';
		is_deeply [sort @{$info{kits}}], [qw(bosh cf)],
			'kits contains sorted kit names';
	};

	subtest '404 on org URL reinterprets to org not found' => sub {
		reset_mocks();
		my $p = build_provider(
			organization => 'ghost-org',
			domain       => 'github.com',
		);

		# First check => 404
		queue_curl_response(404, 'Not Found', '');

		# Second check (base_url) => 200 (API endpoint exists, org does not)
		queue_curl_response(200, 'OK', '');

		# After reinterpretation, code is 200, so kit_names gets called.
		# Pre-populate to avoid extra curl calls.
		$p->{_kits} = [qw(cf)];

		my %info = $p->status;
		like $info{status}, qr/Cannot find organization ghost-org/,
			'status reports org not found when API is reachable';
	};

	subtest '404 on both checks means API endpoint not found' => sub {
		reset_mocks();
		my $p = build_provider(domain => 'nonexistent.example.com');

		# First check => 404
		queue_curl_response(404, 'Not Found', '');

		# Second check (base_url) => also 404
		queue_curl_response(404, 'Not Found', '');

		my %info = $p->status;
		like $info{status}, qr/Cannot find API endpoint/,
			'status reports API endpoint not found';
	};

	subtest '403 without credentials reports throttling' => sub {
		reset_mocks();
		my $p = build_provider();

		# check returns 403
		queue_curl_response(403, 'Forbidden', '');

		my %info = $p->status;
		like $info{status}, qr/Unable to access.*throttling/,
			'403 without creds suggests throttling or permissions';
	};

	subtest 'other HTTP error in status' => sub {
		reset_mocks();
		my $p = build_provider();

		# check returns 500
		queue_curl_response(500, 'Something went wrong: server error', '');

		my %info = $p->status;
		like $info{status}, qr/HTTP Error 500/,
			'non-200/403/404 code is formatted as HTTP Error';
	};

	subtest 'kits is undef when check fails' => sub {
		reset_mocks();
		my $p = build_provider();

		queue_curl_response(500, 'Error', '');

		my %info = $p->status;
		ok !defined($info{kits}), 'kits is undef when check fails';
	};

	subtest 'Use TLS field present' => sub {
		reset_mocks();
		my $p = build_provider(tls => 'skip');

		queue_curl_response(500, 'Error', '');

		my %info = $p->status;
		is $info{"Use TLS"}, 'skip', 'Use TLS reflects tls setting';
	};
};

done_testing;
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1
