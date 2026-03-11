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

# ----------------------------------------------------------------------------
# Shared helper: create an env with genesis.* settings, type=bosh
# ----------------------------------------------------------------------------
sub make_bosh_env {
	my (%genesis_opts) = @_;
	my $top = make_top(name => 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	my $env_name = delete $genesis_opts{env} // 'us-west-1-preprod';
	my $genesis_block = "  env: $env_name\n";
	for my $key (sort keys %genesis_opts) {
		$genesis_block .= "  $key: $genesis_opts{$key}\n";
	}

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

# Helper: create env with params.* block as well
sub make_bosh_env_with_params {
	my (%opts) = @_;
	my $top = make_top(name => 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	my $env_name = delete $opts{env} // 'us-west-1-preprod';
	my $genesis_block = "  env: $env_name\n";
	my $params_block  = "";

	for my $key (sort keys %opts) {
		if ($key =~ /^params\.(.+)$/) {
			$params_block .= "  $1: $opts{$key}\n";
		} else {
			$genesis_block .= "  $key: $opts{$key}\n";
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

# ============================================================================
# secrets_mount
# ============================================================================

subtest 'secrets_mount - default value' => sub {
	plan tests => 2;

	my $env = make_bosh_env();
	is($env->secrets_mount, '/secret/',
		'secrets_mount returns /secret/ by default');
	is($env->secrets_mount, $env->default_secrets_mount,
		'secrets_mount equals default_secrets_mount when not configured');
};

subtest 'secrets_mount - custom genesis.secrets_mount' => sub {
	plan tests => 3;

	my $env1 = make_bosh_env(secrets_mount => '/vault/');
	is($env1->secrets_mount, '/vault/',
		'secrets_mount returns configured value');

	my $env2 = make_bosh_env(secrets_mount => 'custom');
	is($env2->secrets_mount, '/custom/',
		'secrets_mount normalizes bare name with leading+trailing slashes');

	my $env3 = make_bosh_env(secrets_mount => 'custom/nested');
	is($env3->secrets_mount, '/custom/nested/',
		'secrets_mount normalizes multi-segment path');
};

subtest 'secrets_mount - memoization' => sub {
	plan tests => 1;

	my $env = make_bosh_env();
	my $first  = $env->secrets_mount;
	my $second = $env->secrets_mount;
	is($first, $second, 'secrets_mount returns same value on repeated calls');
};

# ============================================================================
# secrets_slug
# ============================================================================

subtest 'secrets_slug - default derived from env name and type' => sub {
	plan tests => 2;

	my $env = make_bosh_env(env => 'us-west-1-preprod');
	is($env->secrets_slug, 'us/west/1/preprod/bosh',
		'secrets_slug converts hyphens to slashes and appends deployment type');

	my $env2 = make_bosh_env(env => 'prod');
	is($env2->secrets_slug, 'prod/bosh',
		'secrets_slug works for single-segment env name');
};

subtest 'secrets_slug - explicit genesis.secrets_path' => sub {
	plan tests => 2;

	my $env = make_bosh_env(secrets_path => 'my/custom/path');
	is($env->secrets_slug, 'my/custom/path',
		'secrets_slug returns genesis.secrets_path when set');

	my $env2 = make_bosh_env(secrets_path => '/leading/slash/');
	is($env2->secrets_slug, 'leading/slash',
		'secrets_slug strips leading and trailing slashes from secrets_path');
};

subtest 'secrets_slug - memoization' => sub {
	plan tests => 1;

	my $env = make_bosh_env(env => 'us-west-1-preprod');
	my $first  = $env->secrets_slug;
	my $second = $env->secrets_slug;
	is($first, $second, 'secrets_slug returns same value on repeated calls');
};

# ============================================================================
# secrets_base
# ============================================================================

subtest 'secrets_base - default full path' => sub {
	plan tests => 1;

	my $env = make_bosh_env(env => 'us-west-1-preprod');
	is($env->secrets_base, '/secret/us/west/1/preprod/bosh/',
		'secrets_base is mount + slug + trailing slash');
};

subtest 'secrets_base - custom mount and slug' => sub {
	plan tests => 1;

	my $env = make_bosh_env(
		env           => 'us-west-1-preprod',
		secrets_mount => '/vault/',
		secrets_path  => 'ops/bosh',
	);
	is($env->secrets_base, '/vault/ops/bosh/',
		'secrets_base combines custom mount and custom slug');
};

subtest 'secrets_base - memoization' => sub {
	plan tests => 1;

	my $env = make_bosh_env(env => 'us-west-1-preprod');
	my $first  = $env->secrets_base;
	my $second = $env->secrets_base;
	is($first, $second, 'secrets_base returns same value on repeated calls');
};

# ============================================================================
# exodus_mount
# ============================================================================

subtest 'exodus_mount - default derived from secrets_mount' => sub {
	plan tests => 2;

	my $env = make_bosh_env();
	is($env->exodus_mount, '/secret/exodus/',
		'exodus_mount defaults to secrets_mount + exodus/');

	my $env2 = make_bosh_env(secrets_mount => '/vault/');
	is($env2->exodus_mount, '/vault/exodus/',
		'exodus_mount follows custom secrets_mount');
};

subtest 'exodus_mount - explicit genesis.exodus_mount' => sub {
	plan tests => 2;

	my $env = make_bosh_env(exodus_mount => '/custom/exodus/');
	is($env->exodus_mount, '/custom/exodus/',
		'exodus_mount returns explicit value when configured');

	my $env2 = make_bosh_env(exodus_mount => 'myexodus');
	is($env2->exodus_mount, '/myexodus/',
		'exodus_mount normalizes bare name with leading+trailing slashes');
};

subtest 'exodus_mount - memoization' => sub {
	plan tests => 1;

	my $env = make_bosh_env();
	my $first  = $env->exodus_mount;
	my $second = $env->exodus_mount;
	is($first, $second, 'exodus_mount returns same value on repeated calls');
};

# ============================================================================
# exodus_slug
# ============================================================================

subtest 'exodus_slug - name/type format preserving hyphens' => sub {
	plan tests => 3;

	my $env1 = make_bosh_env(env => 'us-west-1-preprod');
	is($env1->exodus_slug, 'us-west-1-preprod/bosh',
		'exodus_slug is name/type with hyphens preserved');

	my $env2 = make_bosh_env(env => 'prod');
	is($env2->exodus_slug, 'prod/bosh',
		'exodus_slug works for single-segment name');

	my $env3 = make_bosh_env(env => 'a-b-c-d');
	is($env3->exodus_slug, 'a-b-c-d/bosh',
		'exodus_slug preserves all hyphens in env name');
};

subtest 'exodus_slug - distinct from secrets_slug' => sub {
	plan tests => 1;

	my $env = make_bosh_env(env => 'us-west-1-preprod');
	# secrets_slug uses slashes; exodus_slug uses original hyphenated name
	isnt($env->exodus_slug, $env->secrets_slug,
		'exodus_slug differs from secrets_slug for hyphenated name');
};

# ============================================================================
# exodus_base
# ============================================================================

subtest 'exodus_base - default full path' => sub {
	plan tests => 1;

	my $env = make_bosh_env(env => 'us-west-1-preprod');
	is($env->exodus_base, '/secret/exodus/us-west-1-preprod/bosh',
		'exodus_base is exodus_mount + exodus_slug (no trailing slash)');
};

subtest 'exodus_base - custom exodus_mount' => sub {
	plan tests => 1;

	my $env = make_bosh_env(
		env          => 'us-west-1-preprod',
		exodus_mount => '/ops/exodus/',
	);
	is($env->exodus_base, '/ops/exodus/us-west-1-preprod/bosh',
		'exodus_base uses custom exodus_mount');
};

subtest 'exodus_base - no trailing slash' => sub {
	plan tests => 1;

	my $env = make_bosh_env(env => 'us-west-1-preprod');
	unlike($env->exodus_base, qr/\/$/, 'exodus_base has no trailing slash');
};

subtest 'exodus_base - memoization' => sub {
	plan tests => 1;

	my $env = make_bosh_env(env => 'us-west-1-preprod');
	my $first  = $env->exodus_base;
	my $second = $env->exodus_base;
	is($first, $second, 'exodus_base returns same value on repeated calls');
};

# ============================================================================
# ci_mount
# ============================================================================

subtest 'ci_mount - default derived from secrets_mount' => sub {
	plan tests => 2;

	my $env = make_bosh_env();
	is($env->ci_mount, '/secret/ci/',
		'ci_mount defaults to secrets_mount + ci/');

	my $env2 = make_bosh_env(secrets_mount => '/vault/');
	is($env2->ci_mount, '/vault/ci/',
		'ci_mount follows custom secrets_mount');
};

subtest 'ci_mount - explicit genesis.ci_mount' => sub {
	plan tests => 2;

	my $env = make_bosh_env(ci_mount => '/pipeline/');
	is($env->ci_mount, '/pipeline/',
		'ci_mount returns explicit value when configured');

	my $env2 = make_bosh_env(ci_mount => 'concourse');
	is($env2->ci_mount, '/concourse/',
		'ci_mount normalizes bare name with leading+trailing slashes');
};

# ============================================================================
# ci_base
# ============================================================================

subtest 'ci_base - default full path' => sub {
	plan tests => 1;

	my $env = make_bosh_env(env => 'us-west-1-preprod');
	is($env->ci_base, '/secret/ci/bosh/us-west-1-preprod/',
		'ci_base is ci_mount + type + / + name + trailing slash');
};

subtest 'ci_base - custom ci_mount' => sub {
	plan tests => 1;

	my $env = make_bosh_env(
		env      => 'us-west-1-preprod',
		ci_mount => '/pipeline/',
	);
	is($env->ci_base, '/pipeline/bosh/us-west-1-preprod/',
		'ci_base uses custom ci_mount');
};

subtest 'ci_base - explicit genesis.ci_base overrides computed value' => sub {
	plan tests => 1;

	my $env = make_bosh_env(
		env     => 'us-west-1-preprod',
		ci_base => '/custom/ci/path',
	);
	is($env->ci_base, '/custom/ci/path/',
		'explicit genesis.ci_base overrides computed value (normalized)');
};

subtest 'ci_base - memoization' => sub {
	plan tests => 1;

	my $env = make_bosh_env(env => 'us-west-1-preprod');
	my $first  = $env->ci_base;
	my $second = $env->ci_base;
	is($first, $second, 'ci_base returns same value on repeated calls');
};

# ============================================================================
# ocfp_config_mount
# ============================================================================

subtest 'ocfp_config_mount - default derived from secrets_mount' => sub {
	plan tests => 2;

	my $env = make_bosh_env();
	is($env->ocfp_config_mount, '/secret/config/',
		'ocfp_config_mount defaults to secrets_mount + config/');

	my $env2 = make_bosh_env(secrets_mount => '/vault/');
	is($env2->ocfp_config_mount, '/vault/config/',
		'ocfp_config_mount follows custom secrets_mount');
};

subtest 'ocfp_config_mount - custom params.ocfp_vault_config_prefix' => sub {
	plan tests => 1;

	my $env = make_bosh_env_with_params(
		'params.ocfp_vault_config_prefix' => 'cfg',
	);
	is($env->ocfp_config_mount, '/secret/cfg/',
		'ocfp_config_mount uses params.ocfp_vault_config_prefix as suffix');
};

subtest 'ocfp_config_mount - explicit genesis.ocfp_config_mount' => sub {
	plan tests => 2;

	my $env = make_bosh_env(ocfp_config_mount => '/ops/config/');
	is($env->ocfp_config_mount, '/ops/config/',
		'ocfp_config_mount returns explicit value when configured');

	my $env2 = make_bosh_env(ocfp_config_mount => 'myconfig');
	is($env2->ocfp_config_mount, '/myconfig/',
		'ocfp_config_mount normalizes bare name with leading+trailing slashes');
};

subtest 'ocfp_config_mount - memoization' => sub {
	plan tests => 1;

	my $env = make_bosh_env();
	my $first  = $env->ocfp_config_mount;
	my $second = $env->ocfp_config_mount;
	is($first, $second, 'ocfp_config_mount returns same value on repeated calls');
};

# ============================================================================
# ocfp_config_slug
# ============================================================================

subtest 'ocfp_config_slug - fallback derived from env name (non-ocfp)' => sub {
	plan tests => 2;

	my $env = make_bosh_env(env => 'us-east-1-mgmt');
	# Without params.ocfp_vault_config_slug or ocfp.bloc, falls back to ocfp_env
	my $slug = $env->ocfp_config_slug;
	is($slug, 'us-east-1/mgmt',
		'ocfp_config_slug falls back to ocfp_env derived from env name');

	my $env2 = make_bosh_env(env => 'us-west-1-preprod');
	is($env2->ocfp_config_slug, 'us-west-1-preprod/ocf',
		'ocfp_config_slug appends /ocf for non-mgmt env names');
};

subtest 'ocfp_config_slug - explicit params.ocfp_vault_config_slug' => sub {
	plan tests => 1;

	my $env = make_bosh_env_with_params(
		env                           => 'us-east-1-mgmt',
		'params.ocfp_vault_config_slug' => 'us-east-1/mgmt',
	);
	is($env->ocfp_config_slug, 'us-east-1/mgmt',
		'ocfp_config_slug returns params.ocfp_vault_config_slug when set');
};

# ============================================================================
# ocfp_config_base
# ============================================================================

subtest 'ocfp_config_base - full path from mount and slug' => sub {
	plan tests => 1;

	my $env = make_bosh_env(env => 'us-east-1-mgmt');
	is($env->ocfp_config_base,
		$env->ocfp_config_mount . $env->ocfp_config_slug,
		'ocfp_config_base = ocfp_config_mount + ocfp_config_slug');
};

subtest 'ocfp_config_base - default path example from POD' => sub {
	plan tests => 1;

	my $env = make_bosh_env_with_params(
		env                           => 'us-east-1-mgmt',
		'params.ocfp_vault_config_slug' => 'us-east-1/mgmt',
	);
	is($env->ocfp_config_base, '/secret/config/us-east-1/mgmt',
		'ocfp_config_base matches POD example /secret/config/us-east-1/mgmt');
};

subtest 'ocfp_config_base - custom mount' => sub {
	plan tests => 1;

	my $env = make_bosh_env(
		env                => 'us-east-1-mgmt',
		ocfp_config_mount  => '/ops/config/',
	);
	like($env->ocfp_config_base, qr{^/ops/config/},
		'ocfp_config_base uses custom ocfp_config_mount');
};

subtest 'ocfp_config_base - memoization' => sub {
	plan tests => 1;

	my $env = make_bosh_env(env => 'us-east-1-mgmt');
	my $first  = $env->ocfp_config_base;
	my $second = $env->ocfp_config_base;
	is($first, $second, 'ocfp_config_base returns same value on repeated calls');
};

# ============================================================================
# Cross-cutting: custom secrets_mount propagates to all derived mounts
# ============================================================================

subtest 'custom secrets_mount propagates to exodus, ci, and ocfp_config' => sub {
	plan tests => 3;

	my $env = make_bosh_env(
		env           => 'us-west-1-preprod',
		secrets_mount => '/vault/',
	);

	like($env->exodus_mount, qr{^/vault/},
		'exodus_mount inherits custom secrets_mount');
	like($env->ci_mount, qr{^/vault/},
		'ci_mount inherits custom secrets_mount');
	like($env->ocfp_config_mount, qr{^/vault/},
		'ocfp_config_mount inherits custom secrets_mount');
};

# ============================================================================
# Cross-cutting: different env names produce different paths
# ============================================================================

subtest 'different env names produce different exodus slugs' => sub {
	plan tests => 2;

	my $env1 = make_bosh_env(env => 'us-west-1-preprod');
	my $env2 = make_bosh_env(env => 'us-east-1-prod');

	isnt($env1->exodus_slug, $env2->exodus_slug,
		'different env names produce different exodus slugs');
	isnt($env1->exodus_base, $env2->exodus_base,
		'different env names produce different exodus base paths');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
