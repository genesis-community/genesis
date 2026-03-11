#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';

use Test::More;
use Test::Exception;

BEGIN {
	use_ok 'Genesis::Kit::Provider';
	use_ok 'Genesis::Kit::Provider::Github';
	use_ok 'Genesis::Kit::Provider::GenesisCommunity';
}

# Suppress output functions in relevant namespaces so bail/bug messages
# do not pollute test output. bail() and bug() die under eval ($^S), so
# throws_ok catches them without any special override.
{
	no warnings 'redefine';
	for my $ns (qw(
		Genesis::Kit::Provider
		Genesis::Kit::Provider::Github
		Genesis::Kit::Provider::GenesisCommunity
	)) {
		no strict 'refs';
		*{"${ns}::info"}    = sub {};
		*{"${ns}::error"}   = sub {};
		*{"${ns}::trace"}   = sub {};
		*{"${ns}::debug"}   = sub {};
		*{"${ns}::warning"} = sub {};
	}
}

# ---------------------------------------------------------------------------
# TestProvider — concrete subclass for testing instance methods that
# delegate to kit_versions() without hitting a real provider.
# ---------------------------------------------------------------------------
{
	package TestProvider;
	use parent -norequire, 'Genesis::Kit::Provider';

	my @_kit_versions_return;

	sub set_kit_versions_return {
		my ($class_or_self, $list) = @_;
		@_kit_versions_return = @$list;
	}

	sub kit_versions { shift; return @_kit_versions_return }

	sub new {
		my ($class, %args) = @_;
		bless { label => $args{label} || 'Test Provider' }, $class;
	}
}

# ===========================================================================
# 1. new() factory constructor
# ===========================================================================
subtest 'new() factory constructor' => sub {

	subtest 'no config returns GenesisCommunity instance' => sub {
		my $p = Genesis::Kit::Provider->new();
		isa_ok $p, 'Genesis::Kit::Provider::GenesisCommunity',
			'no config yields GenesisCommunity';
	};

	subtest 'type => genesis_community returns GenesisCommunity instance' => sub {
		my $p = Genesis::Kit::Provider->new(type => 'genesis_community');
		isa_ok $p, 'Genesis::Kit::Provider::GenesisCommunity',
			'explicit genesis_community type';
	};

	subtest 'type => github returns Github instance' => sub {
		my $p = Genesis::Kit::Provider->new(
			type         => 'github',
			organization => 'test-org',
		);
		isa_ok $p, 'Genesis::Kit::Provider::Github',
			'github type yields Github';
	};

	subtest 'unknown type bails' => sub {
		throws_ok {
			Genesis::Kit::Provider->new(type => 'bogus');
		} qr/Unknown kit provider type 'bogus'/,
			'unknown type raises fatal error';
	};
};

# ===========================================================================
# 2. init() factory constructor
# ===========================================================================
subtest 'init() factory constructor' => sub {

	subtest 'no opts returns GenesisCommunity' => sub {
		my $p = Genesis::Kit::Provider->init();
		isa_ok $p, 'Genesis::Kit::Provider::GenesisCommunity',
			'init() with no opts defaults to GenesisCommunity';
	};

	subtest 'kit-provider => genesis-community returns GenesisCommunity' => sub {
		my $p = Genesis::Kit::Provider->init('kit-provider' => 'genesis-community');
		isa_ok $p, 'Genesis::Kit::Provider::GenesisCommunity',
			'explicit genesis-community provider';
	};

	subtest 'kit-provider => github returns Github' => sub {
		my $p = Genesis::Kit::Provider->init(
			'kit-provider'     => 'github',
			'kit-provider-org' => 'test-org',
		);
		isa_ok $p, 'Genesis::Kit::Provider::Github',
			'github provider via init';
	};

	subtest 'unknown type bails' => sub {
		throws_ok {
			Genesis::Kit::Provider->init('kit-provider' => 'bogus');
		} qr/Unknown kit provider type 'bogus'/,
			'unknown provider type raises fatal error';
	};

	subtest 'kit-provider-config with nonexistent path bails' => sub {
		throws_ok {
			Genesis::Kit::Provider->init(
				'kit-provider-config' => '/nonexistent/path/to/nowhere',
			);
		} qr/Unable to read kit-provider config/,
			'bad config path raises fatal error';
	};
};

# ===========================================================================
# 3. default_provider()
# ===========================================================================
subtest 'default_provider() returns GenesisCommunity' => sub {
	my $p = Genesis::Kit::Provider->default_provider();
	isa_ok $p, 'Genesis::Kit::Provider::GenesisCommunity',
		'default_provider yields GenesisCommunity';
};

# ===========================================================================
# 4. opts()
# ===========================================================================
subtest 'opts() base class returns empty list' => sub {
	my @opts = Genesis::Kit::Provider->opts();
	is scalar(@opts), 0, 'base opts() returns no elements';
};

# ===========================================================================
# 5. opts_help()
# ===========================================================================
subtest 'opts_help() returns formatted help' => sub {
	my $help = Genesis::Kit::Provider->opts_help();
	like $help, qr/KIT PROVIDERS/,   'help contains KIT PROVIDERS header';
	like $help, qr/--kit-provider/,   'help contains --kit-provider option';
	like $help, qr/--kit-provider-config/, 'help contains --kit-provider-config option';
};

# ===========================================================================
# 6. parse_opts()
# ===========================================================================
subtest 'parse_opts()' => sub {

	subtest 'extracts --kit-provider from args' => sub {
		my @args = ('--kit-provider', 'genesis-community', 'leftover');
		my %kit_opts;
		Genesis::Kit::Provider->parse_opts(\@args, \%kit_opts);
		is $kit_opts{'kit-provider'}, 'genesis-community',
			'--kit-provider value captured';
		is_deeply \@args, ['leftover'],
			'non-option args remain';
	};

	subtest 'defaults to genesis-community when no --kit-provider given' => sub {
		my @args = ('leftover-arg');
		my %kit_opts;
		Genesis::Kit::Provider->parse_opts(\@args, \%kit_opts);
		ok !defined($kit_opts{'kit-provider'}),
			'kit-provider not defined when not specified';
		is_deeply \@args, ['leftover-arg'],
			'args unchanged';
	};

	subtest 'stops processing at --' => sub {
		my @args = ('--kit-provider', 'genesis-community', '--', '--extra');
		my %kit_opts;
		Genesis::Kit::Provider->parse_opts(\@args, \%kit_opts);
		is $kit_opts{'kit-provider'}, 'genesis-community',
			'--kit-provider captured before --';
		is_deeply \@args, ['--', '--extra'],
			'-- and trailing args preserved';
	};

	subtest 'unknown type bails' => sub {
		my @args = ('--kit-provider', 'bogus');
		my %kit_opts;
		throws_ok {
			Genesis::Kit::Provider->parse_opts(\@args, \%kit_opts);
		} qr/Unknown kit provider type 'bogus'/,
			'unknown type in parse_opts raises fatal error';
	};

	subtest 'parses github-specific options' => sub {
		my @args = (
			'--kit-provider', 'github',
			'--kit-provider-org', 'my-org',
			'--kit-provider-domain', 'github.example.com',
		);
		my %kit_opts;
		Genesis::Kit::Provider->parse_opts(\@args, \%kit_opts);
		is $kit_opts{'kit-provider'},        'github',             'provider type captured';
		is $kit_opts{'kit-provider-org'},     'my-org',             'org option captured';
		is $kit_opts{'kit-provider-domain'},  'github.example.com', 'domain option captured';
	};
};

# ===========================================================================
# 7. label() accessor
# ===========================================================================
subtest 'label() accessor' => sub {

	subtest 'returns label when set' => sub {
		my $p = TestProvider->new(label => 'My Label');
		is $p->label, 'My Label', 'label returned';
	};

	subtest 'returns undef when not set' => sub {
		my $p = bless {}, 'Genesis::Kit::Provider';
		ok !defined($p->label), 'label is undef when not set';
	};
};

# ===========================================================================
# 8. Abstract methods throw bug()
# ===========================================================================
subtest 'abstract methods throw bug()' => sub {
	# Create a bare Provider-blessed instance (bypasses the factory new)
	my $base = bless { label => 'test-abstract' }, 'Genesis::Kit::Provider';

	my @abstract_methods = qw(
		config
		check
		kit_names
		kit_releases
		kit_versions
		fetch_kit_version
		fetch_kit_version_src
	);

	for my $method (@abstract_methods) {
		throws_ok {
			$base->$method();
		} qr/Abstract Method/,
			"$method() throws bug for abstract base class";
	}
};

# ===========================================================================
# 9. latest_version_of()
# ===========================================================================
subtest 'latest_version_of()' => sub {

	subtest 'missing name bails' => sub {
		my $p = TestProvider->new();
		throws_ok {
			$p->latest_version_of(undef);
		} qr/Missing name for retrieving kit releases/,
			'undef name raises fatal error';

		throws_ok {
			$p->latest_version_of('');
		} qr/Missing name for retrieving kit releases/,
			'empty string name raises fatal error';
	};

	subtest 'returns version string when kit_versions returns results' => sub {
		my $p = TestProvider->new();
		TestProvider->set_kit_versions_return([
			{ version => '2.1.0', body => 'latest' },
			{ version => '2.0.0', body => 'older' },
		]);
		my $ver = $p->latest_version_of('mykit');
		is $ver, '2.1.0', 'returns first version from kit_versions result';
	};

	subtest 'returns undef when kit_versions returns empty list' => sub {
		my $p = TestProvider->new();
		TestProvider->set_kit_versions_return([]);
		my $ver = $p->latest_version_of('nokit');
		ok !defined($ver), 'undef when no versions available';
	};
};

# ===========================================================================
# 10. kit_version_info()
# ===========================================================================
subtest 'kit_version_info()' => sub {

	subtest 'missing name bails' => sub {
		my $p = TestProvider->new();
		throws_ok {
			$p->kit_version_info(undef, '1.0.0');
		} qr/Missing name for retrieving kit releases/,
			'undef name raises fatal error';

		throws_ok {
			$p->kit_version_info('', '1.0.0');
		} qr/Missing name for retrieving kit releases/,
			'empty string name raises fatal error';
	};

	subtest 'returns version info hashref' => sub {
		my $p = TestProvider->new();
		TestProvider->set_kit_versions_return([
			{ version => '1.5.0', body => 'release notes', date => '2025-01-01' },
		]);
		my $info = $p->kit_version_info('mykit', '1.5.0');
		is ref($info), 'HASH', 'returns a hashref';
		is $info->{version}, '1.5.0',          'version matches';
		is $info->{body},    'release notes',   'body matches';
	};

	subtest 'returns undef when kit_versions returns empty list' => sub {
		my $p = TestProvider->new();
		TestProvider->set_kit_versions_return([]);
		my $info = $p->kit_version_info('mykit', '99.99.99');
		ok !defined($info), 'undef when version not found';
	};
};

done_testing;
