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
$Genesis::VERSION = '999.999.999'; # force dev mode for testing
use_ok 'Genesis::Config';
$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");

use_ok 'Genesis::Top';
use_ok 'Genesis::Env';

$ENV{GENESIS_OUTPUT_COLUMNS}=999;
$ENV{NOCOLOR}=1;

# Helper to create an env with specific genesis settings
sub make_env_with_genesis {
	my (%genesis_opts) = @_;
	my $top = make_top(name => 'thing', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	my $genesis_block = "  env: " . ($genesis_opts{env} // 'test-env') . "\n";
	for my $key (grep { $_ ne 'env' } keys %genesis_opts) {
		$genesis_block .= "  $key: $genesis_opts{$key}\n";
	}

	my $env_name = $genesis_opts{env} // 'test-env';
	put_file($top->path("$env_name.yml"), <<"EOF");
---
kit:
  name:    dev
  version: latest
  features: []

genesis:
$genesis_block
EOF

	return $top->load_env($env_name);
}

# Helper for multi-hyphen environment names
sub make_env_named {
	my ($name, %genesis_opts) = @_;
	return make_env_with_genesis(env => $name, %genesis_opts);
}

# ============================================================================
# root_ca_path tests
# ============================================================================

subtest 'root_ca_path - default (empty string)' => sub {
	plan tests => 2;

	my $env = make_env_with_genesis();
	is($env->root_ca_path, '', 'root_ca_path defaults to empty string');
	is($env->root_ca_path, '', 'repeated calls return same value (memoized)');
};

subtest 'root_ca_path - explicit value' => sub {
	plan tests => 1;

	my $env = make_env_with_genesis(root_ca_path => '/secret/root-ca');
	is($env->root_ca_path, '/secret/root-ca', 'explicit root_ca_path is returned');
};

subtest 'root_ca_path - trailing slash removal' => sub {
	plan tests => 2;

	my $env1 = make_env_with_genesis(root_ca_path => '/secret/root-ca/');
	is($env1->root_ca_path, '/secret/root-ca', 'trailing slash is removed');

	my $env2 = make_env_with_genesis(root_ca_path => '/a/b/c/');
	is($env2->root_ca_path, '/a/b/c', 'trailing slash removed from deeper path');
};

subtest 'root_ca_path - memoization' => sub {
	plan tests => 1;

	my $env = make_env_with_genesis(root_ca_path => '/secret/ca');
	my $first = $env->root_ca_path;
	# Manually modify internal state to verify memoization
	$env->{__root_ca_path} = '/modified';
	my $second = $env->root_ca_path;
	is($second, '/modified', 'memoization uses cached value');
};

# ============================================================================
# env_vault_slug tests
# ============================================================================

subtest 'env_vault_slug - simple name' => sub {
	plan tests => 1;

	my $env = make_env_named('myenv');
	is($env->env_vault_slug, 'myenv', 'simple name unchanged');
};

subtest 'env_vault_slug - hyphenated name converts to slashes' => sub {
	plan tests => 3;

	my $env1 = make_env_named('us-west-1-prod');
	is($env1->env_vault_slug, 'us/west/1/prod', 'hyphens converted to slashes');

	my $env2 = make_env_named('a-b-c');
	is($env2->env_vault_slug, 'a/b/c', 'each hyphen becomes slash');

	my $env3 = make_env_named('single');
	is($env3->env_vault_slug, 'single', 'no hyphens means no slashes');
};

# ============================================================================
# secrets_mount tests
# ============================================================================

subtest 'default_secrets_mount' => sub {
	plan tests => 1;

	my $env = make_env_with_genesis();
	is($env->default_secrets_mount, '/secret/', 'default secrets mount is /secret/');
};

subtest 'secrets_mount - default value' => sub {
	plan tests => 1;

	my $env = make_env_with_genesis();
	is($env->secrets_mount, '/secret/', 'secrets_mount defaults to /secret/');
};

subtest 'secrets_mount - explicit value with normalization' => sub {
	plan tests => 4;

	my $env1 = make_env_with_genesis(secrets_mount => 'custom');
	is($env1->secrets_mount, '/custom/', 'adds leading and trailing slashes');

	my $env2 = make_env_with_genesis(secrets_mount => '/custom');
	is($env2->secrets_mount, '/custom/', 'adds trailing slash');

	my $env3 = make_env_with_genesis(secrets_mount => 'custom/');
	is($env3->secrets_mount, '/custom/', 'adds leading slash');

	my $env4 = make_env_with_genesis(secrets_mount => '/custom/');
	is($env4->secrets_mount, '/custom/', 'already normalized unchanged');
};

subtest 'secrets_mount - memoization' => sub {
	plan tests => 1;

	my $env = make_env_with_genesis(secrets_mount => '/test/');
	my $first = $env->secrets_mount;
	my $second = $env->secrets_mount;
	is($first, $second, 'repeated calls return same value');
};

# ============================================================================
# secrets_slug tests
# ============================================================================

subtest 'default_secrets_slug' => sub {
	plan tests => 2;

	my $env1 = make_env_named('test-env');
	is($env1->default_secrets_slug, 'test/env/thing', 'default slug is env_vault_slug/type');

	my $env2 = make_env_named('us-west-prod');
	is($env2->default_secrets_slug, 'us/west/prod/thing', 'hyphenated env name converted');
};

subtest 'secrets_slug - default value' => sub {
	plan tests => 1;

	my $env = make_env_named('my-env');
	is($env->secrets_slug, 'my/env/thing', 'secrets_slug defaults to default_secrets_slug');
};

subtest 'secrets_slug - explicit genesis.secrets_path' => sub {
	plan tests => 1;

	my $env = make_env_with_genesis(secrets_path => 'custom/path');
	is($env->secrets_slug, 'custom/path', 'explicit secrets_path overrides default');
};

subtest 'secrets_slug - normalization (strips leading/trailing slashes)' => sub {
	plan tests => 3;

	my $env1 = make_env_with_genesis(secrets_path => '/custom/path');
	is($env1->secrets_slug, 'custom/path', 'leading slash stripped');

	my $env2 = make_env_with_genesis(secrets_path => 'custom/path/');
	is($env2->secrets_slug, 'custom/path', 'trailing slash stripped');

	my $env3 = make_env_with_genesis(secrets_path => '/custom/path/');
	is($env3->secrets_slug, 'custom/path', 'both slashes stripped');
};

# Helper to create env with params.* settings (legacy fallbacks)
sub make_env_with_params {
	my (%opts) = @_;
	my $top = make_top(name => 'thing', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	my $env_name = delete $opts{env} // 'test-env';
	my $genesis_block = "  env: $env_name\n";
	my $params_block = "";

	for my $key (keys %opts) {
		if ($key =~ /^genesis\.(.+)$/) {
			$genesis_block .= "  $1: $opts{$key}\n";
		} else {
			$params_block .= "  $key: $opts{$key}\n";
		}
	}

	put_file($top->path("$env_name.yml"), <<"EOF");
---
kit:
  name:    dev
  version: latest
  features: []

genesis:
$genesis_block
params:
$params_block
EOF

	return $top->load_env($env_name);
}

subtest 'secrets_slug - params.vault_prefix legacy fallback' => sub {
	plan tests => 1;

	my $env = make_env_with_params(vault_prefix => 'legacy/prefix/path');
	is($env->secrets_slug, 'legacy/prefix/path', 'params.vault_prefix used when genesis.secrets_path not set');
};

subtest 'secrets_slug - params.vault legacy fallback' => sub {
	plan tests => 1;

	my $env = make_env_with_params(vault => 'oldest/vault/path');
	is($env->secrets_slug, 'oldest/vault/path', 'params.vault used when neither secrets_path nor vault_prefix set');
};

subtest 'secrets_slug - priority order (genesis.secrets_path > params.vault_prefix > params.vault)' => sub {
	plan tests => 3;

	# genesis.secrets_path takes priority over both params.*
	my $env1 = make_env_with_params(
		'genesis.secrets_path' => 'genesis/path',
		vault_prefix => 'prefix/path',
		vault => 'vault/path'
	);
	is($env1->secrets_slug, 'genesis/path', 'genesis.secrets_path takes highest priority');

	# params.vault_prefix takes priority over params.vault
	my $env2 = make_env_with_params(
		vault_prefix => 'prefix/path',
		vault => 'vault/path'
	);
	is($env2->secrets_slug, 'prefix/path', 'params.vault_prefix takes priority over params.vault');

	# params.vault used only when nothing else is set
	my $env3 = make_env_with_params(vault => 'vault/path');
	is($env3->secrets_slug, 'vault/path', 'params.vault used as last resort');
};

# ============================================================================
# secrets_base tests
# ============================================================================

subtest 'secrets_base - combines mount and slug' => sub {
	plan tests => 2;

	my $env1 = make_env_named('test-env');
	is($env1->secrets_base, '/secret/test/env/thing/', 'default secrets_base');

	my $env2 = make_env_with_genesis(
		secrets_mount => '/vault/',
		secrets_path  => 'my/secrets'
	);
	is($env2->secrets_base, '/vault/my/secrets/', 'custom mount and path combined');
};

subtest 'secrets_base - memoization' => sub {
	plan tests => 1;

	my $env = make_env_with_genesis();
	my $first = $env->secrets_base;
	my $second = $env->secrets_base;
	is($first, $second, 'repeated calls return same value');
};

# ============================================================================
# exodus_mount tests
# ============================================================================

subtest 'default_exodus_mount' => sub {
	plan tests => 2;

	my $env1 = make_env_with_genesis();
	is($env1->default_exodus_mount, '/secret/exodus/', 'default exodus mount is secrets_mount + exodus/');

	my $env2 = make_env_with_genesis(secrets_mount => '/vault/');
	is($env2->default_exodus_mount, '/vault/exodus/', 'exodus mount follows secrets_mount');
};

subtest 'exodus_mount - default value' => sub {
	plan tests => 1;

	my $env = make_env_with_genesis();
	is($env->exodus_mount, '/secret/exodus/', 'exodus_mount defaults to default_exodus_mount');
};

subtest 'exodus_mount - explicit value with normalization' => sub {
	plan tests => 4;

	my $env1 = make_env_with_genesis(exodus_mount => 'exodus');
	is($env1->exodus_mount, '/exodus/', 'adds leading and trailing slashes');

	my $env2 = make_env_with_genesis(exodus_mount => '/exodus');
	is($env2->exodus_mount, '/exodus/', 'adds trailing slash');

	my $env3 = make_env_with_genesis(exodus_mount => 'exodus/');
	is($env3->exodus_mount, '/exodus/', 'adds leading slash');

	my $env4 = make_env_with_genesis(exodus_mount => '/custom/exodus/');
	is($env4->exodus_mount, '/custom/exodus/', 'already normalized unchanged');
};

# ============================================================================
# exodus_slug tests
# ============================================================================

subtest 'exodus_slug - uses name (not env_vault_slug) and type' => sub {
	plan tests => 2;

	my $env1 = make_env_named('test-env');
	is($env1->exodus_slug, 'test-env/thing', 'exodus_slug is name/type (preserves hyphens)');

	my $env2 = make_env_named('us-west-prod');
	is($env2->exodus_slug, 'us-west-prod/thing', 'hyphens preserved in exodus_slug');
};

# ============================================================================
# exodus_base tests
# ============================================================================

subtest 'exodus_base - combines mount and slug' => sub {
	plan tests => 2;

	my $env1 = make_env_named('test-env');
	is($env1->exodus_base, '/secret/exodus/test-env/thing', 'default exodus_base');

	my $env2 = make_env_with_genesis(exodus_mount => '/vault/exodus/');
	is($env2->exodus_base, '/vault/exodus/test-env/thing', 'custom exodus_mount used');
};

subtest 'exodus_base - no trailing slash' => sub {
	plan tests => 1;

	my $env = make_env_with_genesis();
	unlike($env->exodus_base, qr/\/$/, 'exodus_base has no trailing slash');
};

subtest 'exodus_base - memoization' => sub {
	plan tests => 1;

	my $env = make_env_with_genesis();
	my $first = $env->exodus_base;
	my $second = $env->exodus_base;
	is($first, $second, 'repeated calls return same value');
};

# ============================================================================
# ci_mount tests
# ============================================================================

subtest 'default_ci_mount' => sub {
	plan tests => 2;

	my $env1 = make_env_with_genesis();
	is($env1->default_ci_mount, '/secret/ci/', 'default ci mount is secrets_mount + ci/');

	my $env2 = make_env_with_genesis(secrets_mount => '/vault/');
	is($env2->default_ci_mount, '/vault/ci/', 'ci mount follows secrets_mount');
};

subtest 'ci_mount - default value' => sub {
	plan tests => 1;

	my $env = make_env_with_genesis();
	is($env->ci_mount, '/secret/ci/', 'ci_mount defaults to default_ci_mount');
};

subtest 'ci_mount - explicit value with normalization' => sub {
	plan tests => 2;

	my $env1 = make_env_with_genesis(ci_mount => 'pipeline');
	is($env1->ci_mount, '/pipeline/', 'adds leading and trailing slashes');

	my $env2 = make_env_with_genesis(ci_mount => '/custom/ci/');
	is($env2->ci_mount, '/custom/ci/', 'already normalized unchanged');
};

# ============================================================================
# ci_base tests
# ============================================================================

subtest 'ci_base - default value' => sub {
	plan tests => 1;

	my $env = make_env_named('test-env');
	is($env->ci_base, '/secret/ci/thing/test-env/', 'default ci_base is ci_mount + type + / + name + /');
};

subtest 'ci_base - explicit value with normalization' => sub {
	plan tests => 2;

	my $env1 = make_env_with_genesis(ci_base => 'my/ci/path');
	is($env1->ci_base, '/my/ci/path/', 'adds leading and trailing slashes');

	my $env2 = make_env_with_genesis(ci_base => '/pipeline/secrets/');
	is($env2->ci_base, '/pipeline/secrets/', 'already normalized unchanged');
};

subtest 'ci_base - memoization' => sub {
	plan tests => 1;

	my $env = make_env_with_genesis();
	my $first = $env->ci_base;
	my $second = $env->ci_base;
	is($first, $second, 'repeated calls return same value');
};

# ============================================================================
# Integration: verify vault path consistency
# ============================================================================

subtest 'vault paths - consistency across related methods' => sub {
	plan tests => 4;

	my $env = make_env_named('us-west-prod', secrets_mount => '/vault/');

	# Verify secrets paths are consistent
	my $secrets_base = $env->secrets_base;
	is($secrets_base, $env->secrets_mount . $env->secrets_slug . '/',
		'secrets_base = secrets_mount + secrets_slug + /');

	# Verify exodus paths are consistent
	my $exodus_base = $env->exodus_base;
	is($exodus_base, $env->exodus_mount . $env->exodus_slug,
		'exodus_base = exodus_mount + exodus_slug');

	# Verify exodus_mount derives from secrets_mount (when default)
	my $env2 = make_env_with_genesis(secrets_mount => '/custom/');
	like($env2->exodus_mount, qr/^\/custom\//, 'exodus_mount follows custom secrets_mount');

	# Verify ci_mount derives from secrets_mount (when default)
	like($env2->ci_mount, qr/^\/custom\//, 'ci_mount follows custom secrets_mount');
};

subtest 'vault paths - slug vs name handling' => sub {
	plan tests => 2;

	my $env = make_env_named('a-b-c');

	# env_vault_slug converts hyphens to slashes
	is($env->env_vault_slug, 'a/b/c', 'env_vault_slug converts hyphens to slashes');

	# exodus_slug preserves the original name
	is($env->exodus_slug, 'a-b-c/thing', 'exodus_slug preserves hyphens in name');
};

done_testing;
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
