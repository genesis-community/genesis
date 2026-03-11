#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Test::Deep;
use Test::Exception;

use Genesis;
$Genesis::VERSION = '999.999.999';
use_ok 'Genesis::Config';
$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");

use_ok 'Genesis::Top';
use_ok 'Genesis::Env';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# ============================================================================
# Shared helpers
# ============================================================================

# Build an env with a genesis.vault value set in the YAML file.
sub make_env_with_vault {
	my (%opts) = @_;
	my $vault_val = delete $opts{vault_val};
	my $env_name  = delete $opts{env_name} // 'us-west-1-preprod';
	my $top = make_top(name => 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	my $vault_line = defined($vault_val) ? "  vault: $vault_val\n" : "";

	put_file($top->path("$env_name.yml"), <<"EOF");
---
kit:
  name:    dev
  version: latest
  features: []

genesis:
  env: $env_name
$vault_line
EOF

	return $top->load_env($env_name);
}

# ============================================================================
# get_ancestral_vault() - reads genesis.vault from env YAML, no Vault needed
# ============================================================================

subtest 'get_ancestral_vault - returns undef when genesis.vault not set' => sub {
	plan tests => 1;

	my $env = make_env_with_vault(env_name => 'prod');
	is($env->get_ancestral_vault, undef,
		'get_ancestral_vault returns undef when genesis.vault is absent');
};

subtest 'get_ancestral_vault - returns URL string from env YAML' => sub {
	plan tests => 2;

	my $env = make_env_with_vault(
		env_name  => 'us-west-1-preprod',
		vault_val => 'https://vault.example.com:8200',
	);
	my $result = $env->get_ancestral_vault;
	is($result, 'https://vault.example.com:8200',
		'get_ancestral_vault returns plain HTTPS vault URL');
	ok(defined($result), 'get_ancestral_vault returns a defined value');
};

subtest 'get_ancestral_vault - returns descriptor with path component' => sub {
	plan tests => 1;

	my $env = make_env_with_vault(
		env_name  => 'staging',
		vault_val => 'https://vault.example.com:8200/secret/env',
	);
	is($env->get_ancestral_vault, 'https://vault.example.com:8200/secret/env',
		'get_ancestral_vault returns URL with path component intact');
};

subtest 'get_ancestral_vault - rejects spruce operator value' => sub {
	plan tests => 1;

	my $env = make_env_with_vault(
		env_name  => 'bad-env',
		vault_val => '((some-operator))',
	);
	throws_ok { $env->get_ancestral_vault }
		qr/Cannot use spruce operator.*genesis\.vault_info/i,
		'get_ancestral_vault dies when genesis.vault starts with (( spruce operator';
};

subtest 'get_ancestral_vault - inherits from ancestor env file' => sub {
	plan tests => 2;

	my $top = make_top(name => 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	# Parent file sets genesis.vault
	put_file($top->path('us.yml'), <<"EOF");
---
kit:
  name:    dev
  version: latest
  features: []

genesis:
  vault: https://shared-vault.example.com:8200
EOF

	# Child file does NOT override genesis.vault
	put_file($top->path('us-west-1-preprod.yml'), <<"EOF");
---
kit:
  name:    dev
  version: latest
  features: []

genesis:
  env: us-west-1-preprod
EOF

	my $env = $top->load_env('us-west-1-preprod');
	my $result = $env->get_ancestral_vault;
	is($result, 'https://shared-vault.example.com:8200',
		'get_ancestral_vault inherits genesis.vault from ancestor env file');
	ok(defined($result), 'inherited vault descriptor is defined');
};

subtest 'get_ancestral_vault - child overrides parent genesis.vault' => sub {
	plan tests => 1;

	my $top = make_top(name => 'cf', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	# Parent file sets one genesis.vault
	put_file($top->path('us.yml'), <<"EOF");
---
kit:
  name:    dev
  version: latest
  features: []

genesis:
  vault: https://parent-vault.example.com:8200
EOF

	# Child file overrides genesis.vault
	put_file($top->path('us-west-1-prod.yml'), <<"EOF");
---
kit:
  name:    dev
  version: latest
  features: []

genesis:
  env: us-west-1-prod
  vault: https://child-vault.example.com:8200
EOF

	my $env = $top->load_env('us-west-1-prod');
	is($env->get_ancestral_vault, 'https://child-vault.example.com:8200',
		'child genesis.vault overrides parent genesis.vault');
};

subtest 'get_ancestral_vault - lightweight env object without YAML file returns undef' => sub {
	plan tests => 1;

	my $top = make_top(name => 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	# Create a minimal env object directly (no YAML file on disk)
	my $env = Genesis::Env->new(name => 'no-file-env', top => $top);
	is($env->get_ancestral_vault, undef,
		'get_ancestral_vault returns undef when no env YAML files exist');
};

subtest 'get_ancestral_vault - rejects reference value (non-scalar)' => sub {
	plan tests => 1;

	# We need lookup_unevaled to return a reference (e.g. a hashref) to
	# trigger the "not a singular string value" bail.  Monkey-patch the
	# Genesis::Env method temporarily using a local override.
	my $top = make_top(name => 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path('ref-test.yml'), <<"EOF");
---
kit:
  name:    dev
  version: latest
  features: []

genesis:
  env: ref-test
EOF

	my $env = $top->load_env('ref-test');

	# Temporarily override lookup_unevaled in Genesis::Env to return a hashref
	no warnings qw(redefine once);
	local *Genesis::Env::lookup_unevaled = sub { return {bad => 'value'} };
	use warnings qw(redefine once);

	throws_ok { $env->get_ancestral_vault }
		qr/Expecting.*genesis\.vault.*singular string value/i,
		'get_ancestral_vault dies when genesis.vault value is a reference';
};

# ============================================================================
# exodus_lookup() - requires live Vault server
# ============================================================================

subtest 'exodus_lookup - SKIP: requires live Vault' => sub {
	plan skip_all => 'exodus_lookup() requires a live Vault server; use integration tests';
};

subtest 'exodus_lookup - SKIP: extended path /path:key format requires live Vault' => sub {
	plan skip_all => 'exodus_lookup() /path:key format requires a live Vault server; use integration tests';
};

subtest 'exodus_lookup - SKIP: custom $for slug requires live Vault' => sub {
	plan skip_all => 'exodus_lookup() custom $for slug requires a live Vault server; use integration tests';
};

# ============================================================================
# vault_paths() - requires spruce manifest build and live Vault
# ============================================================================

subtest 'vault_paths - SKIP: requires spruce manifest build and live Vault' => sub {
	plan skip_all => 'vault_paths() requires manifest_provider->base_manifest which needs spruce and Vault; use integration tests';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
