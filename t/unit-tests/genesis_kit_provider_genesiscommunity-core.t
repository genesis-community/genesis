#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';

use Test::More;
use Test::Exception;

BEGIN {
	use_ok 'Service::Github';
	use_ok 'Genesis::Kit::Provider';
	use_ok 'Genesis::Kit::Provider::Github';
	use_ok 'Genesis::Kit::Provider::GenesisCommunity';
}

# Suppress non-fatal output functions so test output stays clean.
# Do NOT override bail() or bug() — they die under eval ($^S),
# so throws_ok catches them without any special handling.
{
	no warnings 'redefine';
	for my $ns (qw(
		Service::Github
		Genesis::Kit::Provider::Github
		Genesis::Kit::Provider::GenesisCommunity
	)) {
		no strict 'refs';
		*{"${ns}::info"}            = sub {};
		*{"${ns}::error"}           = sub {};
		*{"${ns}::trace"}           = sub {};
		*{"${ns}::debug"}           = sub {};
		*{"${ns}::warning"}         = sub {};
		*{"${ns}::pretty_duration"} = sub { '' };
	}
}

# ============================================================
# Curl mock infrastructure
# ============================================================
my @curl_calls;
my @curl_responses;

{
	no warnings 'redefine';
	*Service::Github::curl = sub {
		push @curl_calls, [@_];
		my $resp = shift @curl_responses;
		return $resp ? @$resp : (500, 'No mock response queued', '', '');
	};
}

sub queue_curl_response { push @curl_responses, [@_] }

sub reset_mocks {
	@curl_calls     = ();
	@curl_responses = ();
}

# ===========================================================================
# 1. init() class method
# ===========================================================================
subtest 'init() class method' => sub {
	local $ENV{GITHUB_USER};
	local $ENV{GITHUB_AUTH_TOKEN};

	subtest 'returns GenesisCommunity instance with no args' => sub {
		my $p = Genesis::Kit::Provider::GenesisCommunity->init();
		isa_ok $p, 'Genesis::Kit::Provider::GenesisCommunity',
			'init() returns GenesisCommunity';
	};

	subtest 'isa Genesis::Kit::Provider::Github' => sub {
		my $p = Genesis::Kit::Provider::GenesisCommunity->init();
		isa_ok $p, 'Genesis::Kit::Provider::Github',
			'inherits from Github';
	};

	subtest 'isa Genesis::Kit::Provider' => sub {
		my $p = Genesis::Kit::Provider::GenesisCommunity->init();
		isa_ok $p, 'Genesis::Kit::Provider',
			'inherits from base Provider';
	};
};

# ===========================================================================
# 2. new() constructor
# ===========================================================================
subtest 'new() constructor' => sub {
	local $ENV{GITHUB_USER};
	local $ENV{GITHUB_AUTH_TOKEN};

	subtest 'no args needed, returns blessed instance' => sub {
		my $p = Genesis::Kit::Provider::GenesisCommunity->new();
		isa_ok $p, 'Genesis::Kit::Provider::GenesisCommunity',
			'new() returns GenesisCommunity';
	};

	subtest 'hard-coded label' => sub {
		my $p = Genesis::Kit::Provider::GenesisCommunity->new();
		is $p->label, 'Genesis Community organization on Github',
			'label is the expected hard-coded string';
	};

	subtest 'hard-coded domain' => sub {
		my $p = Genesis::Kit::Provider::GenesisCommunity->new();
		is $p->domain, 'github.com',
			'domain is github.com';
	};

	subtest 'hard-coded organization' => sub {
		my $p = Genesis::Kit::Provider::GenesisCommunity->new();
		is $p->organization, 'genesis-community',
			'organization is genesis-community';
	};

	subtest 'hard-coded tls' => sub {
		my $p = Genesis::Kit::Provider::GenesisCommunity->new();
		is $p->tls, 'yes',
			'tls is yes';
	};

	subtest 'creates a Service::Github remote object' => sub {
		my $p = Genesis::Kit::Provider::GenesisCommunity->new();
		isa_ok $p->remote, 'Service::Github',
			'remote is a Service::Github instance';
	};
};

# ===========================================================================
# 3. opts()
# ===========================================================================
subtest 'opts() returns empty list' => sub {
	my @opts = Genesis::Kit::Provider::GenesisCommunity->opts();
	is_deeply \@opts, [],
		'opts() returns no elements';
};

# ===========================================================================
# 4. opts_help()
# ===========================================================================
subtest 'opts_help()' => sub {

	subtest 'returns non-empty when genesis-community in valid_types' => sub {
		my $help = Genesis::Kit::Provider::GenesisCommunity->opts_help(
			valid_types => ['genesis-community', 'github'],
		);
		ok length($help) > 0,
			'help text is non-empty';
	};

	subtest 'contains genesis-community text' => sub {
		my $help = Genesis::Kit::Provider::GenesisCommunity->opts_help(
			valid_types => ['genesis-community'],
		);
		like $help, qr/genesis-community/,
			'help mentions genesis-community';
	};

	subtest 'contains singleton description' => sub {
		my $help = Genesis::Kit::Provider::GenesisCommunity->opts_help(
			valid_types => ['genesis-community'],
		);
		like $help, qr/singleton kit provider/,
			'help describes it as a singleton provider';
	};

	subtest 'returns empty when genesis-community NOT in valid_types' => sub {
		my $help = Genesis::Kit::Provider::GenesisCommunity->opts_help(
			valid_types => ['github'],
		);
		is $help, '',
			'help is empty when type not in valid_types';
	};
};

# ===========================================================================
# 5. config()
# ===========================================================================
subtest 'config()' => sub {
	local $ENV{GITHUB_USER};
	local $ENV{GITHUB_AUTH_TOKEN};

	subtest 'returns hash with type genesis-community' => sub {
		my $p = Genesis::Kit::Provider::GenesisCommunity->new();
		is_deeply { $p->config() }, { type => 'genesis-community' },
			'config contains only type => genesis-community';
	};
};

# ===========================================================================
# 6. status()
# ===========================================================================
subtest 'status()' => sub {
	local $ENV{GITHUB_USER};
	local $ENV{GITHUB_AUTH_TOKEN};

	subtest 'returns expected hash with pre-populated kit cache' => sub {
		reset_mocks();
		my $p = Genesis::Kit::Provider::GenesisCommunity->new();

		# Pre-populate internal kit cache to avoid network calls in kit_names()
		$p->{_kits} = ['bosh', 'cf', 'concourse'];

		# The status() -> SUPER::status() -> check() -> remote->check()
		# chain issues a HEAD curl call.  Queue a 200 success.
		queue_curl_response(200, '200 OK', '');

		my %status = $p->status();

		is $status{type}, 'genesis-community',
			'type is genesis-community';
		is_deeply $status{extras}, ['Source'],
			'extras contains only Source';
		is $status{Source}, 'Genesis Community organization on Github',
			'Source matches the provider label';
		is $status{status}, 'ok',
			'status is ok on successful check';
		is_deeply $status{kits}, ['bosh', 'cf', 'concourse'],
			'kits list comes from cache';
	};

	subtest 'curl HEAD call is issued for status check' => sub {
		reset_mocks();
		my $p = Genesis::Kit::Provider::GenesisCommunity->new();
		$p->{_kits} = ['shield'];

		queue_curl_response(200, '200 OK', '');

		$p->status();

		is scalar(@curl_calls), 1,
			'exactly one curl call made';
		is $curl_calls[0][0], 'HEAD',
			'curl call uses HEAD method';
	};

	reset_mocks();
};

# ===========================================================================
# 7. Inherited methods from Github
# ===========================================================================
subtest 'inherited methods' => sub {
	local $ENV{GITHUB_USER};
	local $ENV{GITHUB_AUTH_TOKEN};

	my $p = Genesis::Kit::Provider::GenesisCommunity->new();

	subtest 'label returns expected value' => sub {
		is $p->label, 'Genesis Community organization on Github',
			'label accessor works';
	};

	subtest 'domain returns github.com' => sub {
		is $p->domain, 'github.com',
			'domain delegates to remote';
	};

	subtest 'organization returns genesis-community' => sub {
		is $p->organization, 'genesis-community',
			'organization delegates to remote';
	};

	subtest 'tls returns yes' => sub {
		is $p->tls, 'yes',
			'tls delegates to remote';
	};

	subtest 'base_url returns https://api.github.com' => sub {
		is $p->base_url, 'https://api.github.com',
			'base_url builds correct API URL';
	};

	subtest 'remote returns Service::Github instance' => sub {
		isa_ok $p->remote, 'Service::Github',
			'remote accessor returns Service::Github';
	};

	subtest 'credentials are undef without env vars' => sub {
		ok !defined($p->credentials),
			'credentials are undef when no GITHUB env vars set';
	};
};

# ===========================================================================
# 8. Factory integration (Provider->new, ->init, ->default_provider)
# ===========================================================================
subtest 'factory integration' => sub {
	local $ENV{GITHUB_USER};
	local $ENV{GITHUB_AUTH_TOKEN};

	subtest 'Provider->new() returns GenesisCommunity' => sub {
		my $p = Genesis::Kit::Provider->new();
		isa_ok $p, 'Genesis::Kit::Provider::GenesisCommunity',
			'no-arg new() yields GenesisCommunity';
	};

	subtest 'Provider->new(type => genesis_community) returns GenesisCommunity' => sub {
		my $p = Genesis::Kit::Provider->new(type => 'genesis_community');
		isa_ok $p, 'Genesis::Kit::Provider::GenesisCommunity',
			'explicit type yields GenesisCommunity';
	};

	subtest 'Provider->default_provider() returns GenesisCommunity' => sub {
		my $p = Genesis::Kit::Provider->default_provider();
		isa_ok $p, 'Genesis::Kit::Provider::GenesisCommunity',
			'default_provider yields GenesisCommunity';
	};

	subtest 'Provider->init() returns GenesisCommunity' => sub {
		my $p = Genesis::Kit::Provider->init();
		isa_ok $p, 'Genesis::Kit::Provider::GenesisCommunity',
			'init() with no opts yields GenesisCommunity';
	};
};

done_testing;
