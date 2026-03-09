#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use helper;
use Test::More;
use Test::Deep;
use Test::Exception;

use Genesis;
$Genesis::VERSION = '999.999.999'; # force dev mode for testing
use Genesis::Config;
$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");

use Genesis::Top;
use Genesis::Env;

# Disable color output for cleaner test output
local $ENV{NOCOLOR} = 1;

# Setup common test fixtures
my $top = make_top(name => 'cf', no_vault => 1);
$top->link_dev_kit('t/src/simple');

subtest 'no defaults for iaas and scale' => sub {
	put_file $top->path('no-metadata.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
genesis:
  env: no-metadata
EOF

	my $env = $top->load_env('no-metadata');
	# Prepopulate a dummy director exodus cache to avoid unrelated errors
	$env->{__director_exodus_cache}{''} = {};
	is($env->iaas, '', 'iaas() returns empty string when not set');
	is($env->scale, '', 'scale() returns empty string when not set');
};

subtest 'scale() - retrieves scale from kit.scale' => sub {
	# Test with kit.scale present
	put_file $top->path('scale-kit.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  scale: medium
genesis:
  env: scale-kit
EOF

	my $env = $top->load_env('scale-kit');
	is($env->scale, 'medium', 'scale() returns kit.scale value');
};

subtest 'iaas() - retrieves iaas from kit.iaas' => sub {
	# Test with kit.iaas present
	put_file $top->path('iaas-kit.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  iaas: aws
genesis:
  env: iaas-kit
EOF

	my $env = $top->load_env('iaas-kit');
	is($env->iaas, 'aws', 'iaas() returns kit.iaas value');

	# Note: iaas() returns lowercase
	put_file $top->path('iaas-upper.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  iaas: AWS
genesis:
  env: iaas-upper
EOF

	$env = $top->load_env('iaas-upper');
	is($env->iaas, 'aws', 'iaas() returns lowercase value');
};

subtest 'features() - retrieves features list from kit.features' => sub {
	plan tests => 11;

	# Test with empty features list
	put_file $top->path('features-empty.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features: []
genesis:
  env: features-empty
EOF

	my $env = $top->load_env('features-empty');
	my @features = $env->features;
	is(scalar(@features), 0, 'features() returns empty array when kit.features is empty');

	# Test with single feature
	put_file $top->path('features-single.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features:
    - feature1
genesis:
  env: features-single
EOF

	$env = $top->load_env('features-single');
	@features = $env->features;
	is(scalar(@features), 1, 'features() returns array with one element');
	is($features[0], 'feature1', 'feature is correctly returned');

	# Test with multiple features
	put_file $top->path('features-multiple.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features:
    - feature1
    - feature2
    - feature3
genesis:
  env: features-multiple
EOF

	$env = $top->load_env('features-multiple');
	@features = $env->features;
	is(scalar(@features), 3, 'features() returns all features');
	is_deeply(\@features, ['feature1', 'feature2', 'feature3'],
		'features are returned in order');

	# Test with no kit.features key (defaults to empty array)
	put_file $top->path('features-none.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
genesis:
  env: features-none
EOF

	$env = $top->load_env('features-none');
	@features = $env->features;
	is(scalar(@features), 0, 'features() returns empty array when kit.features not specified');

	# Test memoization
	my @features1 = $env->features;
	my @features2 = $env->features;
	is_deeply(\@features1, \@features2, 'features() returns consistent memoized value');

	# Test validation: must be an array (not a string)
	put_file $top->path('features-string.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features: "not-an-array"
genesis:
  env: features-string
EOF

	throws_ok {
		$top->load_env('features-string')->features;
	} qr/kit\.features.*must be an array.*got a.*string/is,
		'features() dies when kit.features is a string';

	# Test validation: must be an array (not a hash)
	put_file $top->path('features-hash.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features:
    key: value
genesis:
  env: features-hash
EOF

	throws_ok {
		$top->load_env('features-hash')->features;
	} qr/kit\.features.*must be an array.*got a.*hash/is,
		'features() dies when kit.features is a hash';

	# Test validation: cannot contain derived features (starting with +)
	put_file $top->path('features-derived.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features:
    - feature1
    - +derived
    - feature2
genesis:
  env: features-derived
EOF

	throws_ok {
		$top->load_env('features-derived')->features;
	} qr/cannot explicitly specify derived features.*\+derived/is,
		'features() dies when kit.features contains derived features';

	# Test multiple derived features in error message
	put_file $top->path('features-multi-derived.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features:
    - +derived1
    - feature1
    - +derived2
genesis:
  env: features-multi-derived
EOF

	throws_ok {
		$top->load_env('features-multi-derived')->features;
	} qr/cannot\s+explicitly\s+specify\s+derived[\s\S]*features[\s\S]*\+derived1[\s\S]*\+derived2/i,
		'features() lists all derived features in error message';
};

subtest 'features() - hierarchical inheritance with spruce operations' => sub {
	plan tests => 9;

	# Test 1: Base environment with features, child appends more
	put_file $top->path('feat-base.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features:
    - base1
    - base2
genesis:
  env: feat-base
EOF

	put_file $top->path('feat-base-child.yml'), <<EOF;
---
genesis:
  env: feat-base-child
kit:
  features:
    - (( append ))
    - child1
    - child2
EOF

	my $env = $top->load_env('feat-base-child');
	my @features = $env->features;
	is(scalar(@features), 4, 'child environment appends features to base');
	is_deeply(\@features, ['base1', 'base2', 'child1', 'child2'],
		'appended features are in correct order');

	# Test 2: Base environment with features, child overrides (removes some)
	put_file $top->path('feat-override-base.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features:
    - feature1
    - feature2
    - feature3
genesis:
  env: feat-override-base
EOF

	put_file $top->path('feat-override-base-child.yml'), <<EOF;
---
genesis:
  env: feat-override-base-child
kit:
  features:
    - (( replace ))
    - feature1
    - feature3
EOF

	$env = $top->load_env('feat-override-base-child');
	@features = $env->features;
	is(scalar(@features), 2, 'child environment overrides features list');
	is_deeply(\@features, ['feature1', 'feature3'],
		'overridden features exclude feature2');

	# Test 3: Base environment with features, child uses prepend
	put_file $top->path('feat-prepend-base.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features:
    - base1
    - base2
genesis:
  env: feat-prepend-base
EOF

	put_file $top->path('feat-prepend-base-child.yml'), <<EOF;
---
genesis:
  env: feat-prepend-base-child
kit:
  features:
    - (( prepend ))
    - child1
    - child2
EOF

	$env = $top->load_env('feat-prepend-base-child');
	@features = $env->features;
	is(scalar(@features), 4, 'child environment can prepend features');
	is_deeply(\@features, ['child1', 'child2', 'base1', 'base2'],
		'prepended features come before base features');

	# Test 4: Explicit inheritance with features
	put_file $top->path('feat-explicit-parent.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features:
    - parent1
    - parent2
genesis:
  env: feat-explicit-parent
EOF

	put_file $top->path('feat-explicit-child.yml'), <<EOF;
---
genesis:
  env: feat-explicit-child
  inherits:
    - feat-explicit-parent
kit:
  features:
    - (( append ))
    - child1
EOF

	$env = $top->load_env('feat-explicit-child');
	@features = $env->features;
	is(scalar(@features), 3, 'explicit inheritance merges features');
	is_deeply(\@features, ['parent1', 'parent2', 'child1'],
		'features from explicit parent are inherited');

	# Test 5: Multi-level hierarchy with features
	put_file $top->path('feat-multi-1.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features:
    - level1
genesis:
  env: feat-multi-1
EOF

	put_file $top->path('feat-multi-1-2.yml'), <<EOF;
---
genesis:
  env: feat-multi-1-2
kit:
  features:
    - (( append ))
    - level2
EOF

	put_file $top->path('feat-multi-1-2-3.yml'), <<EOF;
---
genesis:
  env: feat-multi-1-2-3
kit:
  features:
    - (( append ))
    - level3
EOF

	$env = $top->load_env('feat-multi-1-2-3');
	@features = $env->features;
	is_deeply(\@features, ['level1', 'level2', 'level3'],
		'multi-level hierarchy merges features from all levels');
};

subtest 'has_feature() - checks for feature presence' => sub {
	plan tests => 7;

	# Setup environment with some features
	put_file $top->path('has-feature-test.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features:
    - aws
    - s3
    - lb
genesis:
  env: has-feature-test
EOF

	my $env = $top->load_env('has-feature-test');

	# Test feature that exists
	ok($env->has_feature('aws'), 'has_feature() returns true for existing feature');
	ok($env->has_feature('s3'), 'has_feature() returns true for another existing feature');
	ok($env->has_feature('lb'), 'has_feature() returns true for third existing feature');

	# Test feature that doesn't exist
	ok(!$env->has_feature('azure'), 'has_feature() returns false for non-existent feature');

	# Test case sensitivity
	ok(!$env->has_feature('AWS'), 'has_feature() is case-sensitive');

	# Test with hierarchical features
	put_file $top->path('has-hier-base.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features:
    - base-feat
genesis:
  env: has-hier-base
EOF

	put_file $top->path('has-hier-base-child.yml'), <<EOF;
---
genesis:
  env: has-hier-base-child
kit:
  features:
    - (( append ))
    - child-feat
EOF

	$env = $top->load_env('has-hier-base-child');
	ok($env->has_feature('base-feat'), 'has_feature() finds inherited feature');
	ok($env->has_feature('child-feat'), 'has_feature() finds appended feature');
};

# ============================================================================
# can_be_entombed tests
# ============================================================================

subtest 'can_be_entombed - requires genesis.min_version 3.0.0-rc.1+' => sub {
	plan tests => 2;

	# Env with genesis.min_version < 3.0.0-rc.1 cannot be entombed
	my $env_old = make_env_with_kit('t/src/simple', 'test-env', min_version => '2.8.0');
	ok(!$env_old->can_be_entombed, 'env with min_version < 3.0.0-rc.1 cannot be entombed');

	# Env with genesis.min_version >= 3.0.0-rc.1 can be entombed
	my $env_new = make_env_with_kit('t/src/simple-3.0.0', 'test-env', min_version => '3.0.0');
	ok($env_new->can_be_entombed, 'env with min_version >= 3.0.0-rc.1 can be entombed');
};

subtest 'can_be_entombed - false when use_create_env' => sub {
	plan tests => 1;

	# Create-env kit deployment cannot be entombed even with compatible min_version
	my $env = make_env_with_kit('t/src/bosh-3.0.0-create-env', 'proto-bosh',
		name => 'bosh', min_version => '3.0.0');
	ok(!$env->can_be_entombed, 'create-env deployments cannot be entombed');
};

subtest 'can_be_entombed - respects genesis.entomb setting' => sub {
	plan tests => 2;

	# Default should allow entombment for env with compatible min_version
	my $env_default = make_env_with_kit('t/src/simple-3.0.0', 'test-env', min_version => '3.0.0');
	ok($env_default->can_be_entombed, 'entomb defaults to true for compatible env');

	# Explicit entomb: false disables entombment
	my $env_disabled = make_env_with_kit('t/src/simple-3.0.0', 'test-env', min_version => '3.0.0', entomb => 'false');
	ok(!$env_disabled->can_be_entombed, 'genesis.entomb: false disables entombment');
};

# NOTE: Policy methods (deployment_change_reason_required_size_policy and
# user_provided_bosh_creds_policy) attempt to read from OCFP config in vault first,
# which requires vault integration and cannot be tested with no_vault => 1.
# These methods are better tested in integration tests where vault is available.

# NOTE: The following methods require more complex setup and are better suited
# for integration tests:
#
# - dereferenced_kit_metadata() - requires kit metadata and partial manifest evaluation
# - vault_paths() - requires manifest provider and vault integration
# - params() - requires manifest provider for parameter evaluation
# - defines() - requires manifest provider to check parameter existence
# - iaas and scale from parent bosh exodus data when not set in env.yml file.  Also, is this only applicable to OCFP? Need to test kit->requires_scale for kits that need scale defined.
#
# These will be tested in integration-level tests where full manifest
# generation and vault operations are available.

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
