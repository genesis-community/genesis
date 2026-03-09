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
use_ok 'Genesis::Kit';

$ENV{GENESIS_OUTPUT_COLUMNS}=80;

subtest 'basic accessors' => sub {
	plan tests => 9;

	my $top = make_top(name => 'thing', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path('test-env.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
  features: []

genesis:
  env: test-env
EOF

	my $env = $top->load_env('test-env');

	# Test name accessor
	is($env->name, 'test-env', 'name() returns environment name');

	# Test file accessor
	is($env->file, 'test-env.yml', 'file() returns environment file name');

	# Test top accessor
	isa_ok($env->top, 'Genesis::Top', 'top() returns Genesis::Top object');
	is($env->top, $top, 'top() returns the same Top object used to create env');

	# Test type accessor (delegation to top)
	is($env->type, 'thing', 'type() returns deployment type from Top');

	# Test path accessor (delegation to top)
	is($env->path, $top->path, 'path() with no args returns top path');
	is($env->path('subdir/file.yml'), $top->path('subdir/file.yml'),
		'path() delegates to top->path()');

	# Test kit accessor
	isa_ok($env->kit, 'Genesis::Kit', 'kit() returns Genesis::Kit object');
	is($env->kit->name, 'dev', 'kit has correct name');
};

subtest 'signature generation' => sub {
	plan tests => 4;

	my $top = make_top(name => 'thing', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path('env-a.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: env-a
EOF

	put_file($top->path('env-b.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: env-b
EOF

	my $env_a = $top->load_env('env-a');
	my $env_b = $top->load_env('env-b');

	# Test signature format
	my $sig_a = $env_a->signature;
	like($sig_a, qr/^[a-f0-9]{12}$/, 'signature is 12 hex characters');

	# Test signature uniqueness
	my $sig_b = $env_b->signature;
	isnt($sig_a, $sig_b, 'different environments have different signatures');

	# Test signature stability
	is($env_a->signature, $sig_a, 'signature is stable across multiple calls');

	# Test signature changes with file changes
	my $top2 = make_top(name => 'other-type', no_vault => 1);
	$top2->link_dev_kit('t/src/simple');
	put_file($top2->path('env-a.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: env-a
EOF

	my $env_a2 = $top2->load_env('env-a');
	isnt($env_a->signature, $env_a2->signature,
		'same env name in different types has different signature');
};

subtest 'deployment_name' => sub {
	plan tests => 2;

	my $top = make_top(name => 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path('prod.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: prod
EOF

	my $env = $top->load_env('prod');
	is($env->deployment_name, 'prod-bosh',
		'deployment_name combines env name and type');

	# Test with hyphenated environment name
	put_file($top->path('us-west-1-prod.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: us-west-1-prod
EOF

	my $env2 = $top->load_env('us-west-1-prod');
	is($env2->deployment_name, 'us-west-1-prod-bosh',
		'deployment_name handles hyphenated env names');
};

subtest 'manifest_store' => sub {
	plan tests => 2;

	my $top = make_top(name => 'thing', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	# Test default manifest store (from config)
	put_file($top->path('default.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: default
EOF

	my $env = $top->load_env('default');
	# Default is set in config, test that it returns a valid value
	ok(defined($env->manifest_store), 'manifest_store returns a defined value');
	ok($env->manifest_store =~ /^(exodus|hybrid|repository)$/,
		'manifest_store returns valid type');
};

subtest 'is_bosh_director' => sub {
	plan tests => 2;

	# Test with non-director kit
	my $top = make_top(name => 'cf', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path('regular.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: regular
EOF

	my $env = $top->load_env('regular');
	ok(!$env->is_bosh_director, 'environment with non-director kit is not a BOSH director');

	# Test with director kit (custom-bosh has is_bosh_director: true in kit.yml)
	my $top2 = make_top(name => 'bosh', no_vault => 1);
	$top2->link_dev_kit('t/src/custom-bosh');

	put_file($top2->path('director.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: director
EOF

	my $director = $top2->load_env('director');
	ok($director->is_bosh_director, 'environment with director kit (is_bosh_director metadata) is a BOSH director');
};

subtest 'use_create_env - basic behavior' => sub {
	plan tests => 7;

	# Basic tests with simple kit (no metadata) to verify accessor works
	my $top = make_top(name => 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	# Test 1: Explicit genesis.use_create_env: true
	put_file($top->path('explicit-true.yml'), <<EOF);
---
kit:
  name:     dev
  version:  latest
genesis:
  env:            explicit-true
  use_create_env: true
EOF

	my $env = $top->load_env('explicit-true');
	ok($env->use_create_env, 'environment with genesis.use_create_env: true uses create-env');

	# Test 2: Explicit genesis.use_create_env: false
	put_file($top->path('explicit-false.yml'), <<EOF);
---
kit:
  name:     dev
  version:  latest
genesis:
  env:            explicit-false
  use_create_env: false
  bosh_env:       parent-bosh
EOF

	$env = $top->load_env('explicit-false');
	ok(!$env->use_create_env, 'environment with genesis.use_create_env: false does not use create-env');

	# Test 3: Environment with bosh_env specified (no explicit use_create_env)
	put_file($top->path('with-bosh-env.yml'), <<EOF);
---
kit:
  name:     dev
  version:  latest
genesis:
  env:      with-bosh-env
  bosh_env: parent-bosh
EOF

	$env = $top->load_env('with-bosh-env');
	ok(!$env->use_create_env, 'environment with bosh_env does not use create-env by default');

	# Test 4: Environment with 'proto' feature
	put_file($top->path('proto-feature.yml'), <<EOF);
---
kit:
  name:     dev
  version:  latest
  features:
    - proto
genesis:
  env: proto-feature
EOF

	$env = $top->load_env('proto-feature');
	ok($env->use_create_env, 'environment with proto feature uses create-env');

	# Test 5: BOSH director without bosh_env and without use_create_env
	# Should default to false with simple kit
	put_file($top->path('no-explicit.yml'), <<EOF);
---
kit:
  name:     dev
  version:  latest
genesis:
  env: no-explicit
EOF

	$env = $top->load_env('no-explicit');
	ok(!$env->use_create_env, 'environment without explicit use_create_env or proto defaults to false');

	# Test 6: Boolean-like strings for use_create_env
	put_file($top->path('string-true.yml'), <<EOF);
---
kit:
  name:     dev
  version:  latest
genesis:
  env:            string-true
  use_create_env: 'yes'
EOF

	$env = $top->load_env('string-true');
	ok($env->use_create_env, 'environment with genesis.use_create_env: "yes" uses create-env');

	# Test 7: YAML boolean no (unquoted)
	put_file($top->path('yaml-false.yml'), <<EOF);
---
kit:
  name:     dev
  version:  latest
genesis:
  env:            yaml-false
  use_create_env: no
  bosh_env:       parent-bosh
EOF

	$env = $top->load_env('yaml-false');
	ok(!$env->use_create_env, 'environment with genesis.use_create_env: no (YAML boolean false) does not use create-env');
};

subtest 'accessor error handling' => sub {
	plan tests => 4;

	# Test that accessors fail appropriately with incomplete objects

	# Create incomplete env object (bypassing normal constructors)
	my $incomplete = bless({name => 'test'}, 'Genesis::Env');

	is($incomplete->name, 'test', 'name() works with minimal object');
	is($incomplete->file, undef, 'file() returns undef when not set');

	throws_ok { $incomplete->kit }
		qr/Incompletely initialized environment.*no kit specified/,
		'kit() throws error on incomplete object';

	throws_ok { $incomplete->top }
		qr/Incompletely initialized environment.*no top specified/,
		'top() throws error on incomplete object';
};

subtest 'accessor immutability' => sub {
	plan tests => 3;

	my $top = make_top(name => 'thing', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path('test.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: test
EOF

	my $env = $top->load_env('test');

	# Verify accessors return consistent values
	my $name1 = $env->name;
	my $name2 = $env->name;
	is($name1, $name2, 'name() returns consistent value');

	my $file1 = $env->file;
	my $file2 = $env->file;
	is($file1, $file2, 'file() returns consistent value');

	my $type1 = $env->type;
	my $type2 = $env->type;
	is($type1, $type2, 'type() returns consistent value');
};

subtest 'deployment_change_reason_required_size_policy' => sub {
	plan tests => 3;

	my $top = make_top(name => 'thing', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path('policy-test.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: policy-test
EOF

	my $env = $top->load_env('policy-test');

	# Test default value (no config set)
	is($env->deployment_change_reason_required_size_policy, 0,
		'deployment_change_reason_required_size_policy defaults to 0');

	# Modify top config and test updated value
	$top->config->set('deployment_change_reason_required_size', 50);
	# Clear memoization cache to pick up new config value
	$env->_clear_memo("__$_") for qw(deployment_change_reason_required_size_policy ocfp_config);

	is($env->deployment_change_reason_required_size_policy, 50,
		'deployment_change_reason_required_size_policy reads from top config');

	# Test different value
	$top->config->set('deployment_change_reason_required_size', 100);
	$env->_clear_memo("__$_") for qw(deployment_change_reason_required_size_policy ocfp_config);

	is($env->deployment_change_reason_required_size_policy, 100,
		'policy can be set to custom values via top config');
};

subtest 'user_provided_bosh_creds_policy' => sub {
	plan tests => 5;

	my $top = make_top(name => 'thing', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path('creds-test.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: creds-test
EOF

	my $env = $top->load_env('creds-test');

	# Test default value (no config set)
	is($env->user_provided_bosh_creds_policy, 'ignore',
		'user_provided_bosh_creds_policy defaults to "ignore"');

	# Test 'allow' value
	$top->config->set('user_provided_bosh_creds', 'allow');
	$env->_clear_memo("__$_") for qw(user_provided_bosh_creds_policy ocfp_config);

	is($env->user_provided_bosh_creds_policy, 'allow',
		'user_provided_bosh_creds_policy reads "allow" from top config');

	# Test 'require' value
	$top->config->set('user_provided_bosh_creds', 'require');
	$env->_clear_memo("__$_") for qw(user_provided_bosh_creds_policy ocfp_config);

	is($env->user_provided_bosh_creds_policy, 'require',
		'user_provided_bosh_creds_policy reads "require" from top config');

	# Test invalid value validation
	$top->config->set('user_provided_bosh_creds', 'invalid');
	$env->_clear_memo("__$_") for qw(user_provided_bosh_creds_policy ocfp_config);

	throws_ok {
		$env->user_provided_bosh_creds_policy;
	} qr/Invalid\s+value.*user_provided_bosh_creds.*policy.*invalid.*Valid\s+values.*ignore.*allow.*require/is,
		'user_provided_bosh_creds_policy validates values';

	# Test explicit 'ignore' value
	$top->config->set('user_provided_bosh_creds', 'ignore');
	$env->_clear_memo("__$_") for qw(user_provided_bosh_creds_policy ocfp_config);

	is($env->user_provided_bosh_creds_policy, 'ignore',
		'user_provided_bosh_creds_policy accepts explicit "ignore" from top config');
};

subtest 'minimum_genesis_version' => sub {
	plan tests => 9;

	# Test 1: No minimum specified (default)
	my $top1 = make_top(name => 'thing', minimum_version => undef, no_vault => 1);
	$top1->link_dev_kit('t/src/simple');

	put_file($top1->path('no-min.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: no-min
EOF

	my $env = $top1->load_env('no-min');
	is($env->minimum_genesis_version, '0.0.0',
		'minimum_genesis_version returns 0.0.0 when no minimum specified');

	# Test 2: Minimum from repository config only
	my $top2 = make_top(name => 'repo-min', minimum_version => '2.8.0', no_vault => 1);
	$top2->link_dev_kit('t/src/simple');

	put_file($top2->path('no-env-min.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: no-env-min
EOF

	$env = $top2->load_env('no-env-min');
	is($env->minimum_genesis_version, '2.8.0',
		'minimum_genesis_version reads from repository config');

	# Test 3: Minimum from environment file only (genesis.min_version)
	my $top3 = make_top(name => 'env-min', minimum_version => undef, no_vault => 1);
	$top3->link_dev_kit('t/src/simple');

	put_file($top3->path('env-min.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: env-min
  min_version: 2.9.0
EOF

	$env = $top3->load_env('env-min');
	is($env->minimum_genesis_version, '2.9.0',
		'minimum_genesis_version reads from genesis.min_version in env file');

	# Test 4: Minimum from environment file (genesis.minimum_version - alternate key)
	my $top4 = make_top(name => 'env-min-alt', minimum_version => undef, no_vault => 1);
	$top4->link_dev_kit('t/src/simple');

	put_file($top4->path('env-min-alt.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: env-min-alt
  minimum_version: 3.0.0
EOF

	$env = $top4->load_env('env-min-alt');
	is($env->minimum_genesis_version, '3.0.0',
		'minimum_genesis_version reads from genesis.minimum_version in env file');

	# Test 5: Both specified - environment takes precedence
	my $top5 = make_top(name => 'both-min', minimum_version => '2.8.0', no_vault => 1);
	$top5->link_dev_kit('t/src/simple');

	put_file($top5->path('both-min.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: both-min
  min_version: 3.0.0
EOF

	$env = $top5->load_env('both-min');
	is($env->minimum_genesis_version, '3.0.0',
		'environment minimum takes precedence over repository minimum');

	# Test 6: Version with 'v' prefix is stripped
	my $top6 = make_top(name => 'v-prefix', minimum_version => undef, no_vault => 1);
	$top6->link_dev_kit('t/src/simple');

	put_file($top6->path('v-prefix.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: v-prefix
  min_version: v2.7.5
EOF

	$env = $top6->load_env('v-prefix');
	is($env->minimum_genesis_version, '2.7.5',
		'minimum_genesis_version strips leading v from version string');

	# Test 7: Repository version with 'v' prefix is stripped
	my $top7 = make_top(name => 'repo-v', minimum_version => 'v2.6.0', no_vault => 1);
	$top7->link_dev_kit('t/src/simple');

	put_file($top7->path('repo-v-test.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: repo-v-test
EOF

	$env = $top7->load_env('repo-v-test');
	is($env->minimum_genesis_version, '2.6.0',
		'minimum_genesis_version strips leading v from repository config');

	# Test 8: Memoization works
	my $version1 = $env->minimum_genesis_version;
	my $version2 = $env->minimum_genesis_version;
	is($version1, $version2,
		'minimum_genesis_version returns consistent memoized value');

	# Test 9: Empty string treated as no minimum
	my $top8 = make_top(name => 'empty-min', minimum_version => undef, no_vault => 1);
	$top8->link_dev_kit('t/src/simple');

	put_file($top8->path('empty-min.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: empty-min
  min_version: ''
EOF

	$env = $top8->load_env('empty-min');
	is($env->minimum_genesis_version, '0.0.0',
		'minimum_genesis_version treats empty string as no minimum');
};

subtest 'feature_compatibility' => sub {
	plan tests => 4;

	my $top = make_top(name => 'feat-compat', minimum_version => undef, no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	# Test 1: Environment version meets requirement
	put_file($top->path('meets-req.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: meets-req
  min_version: 2.8.0
EOF

	my $env = $top->load_env('meets-req');
	ok($env->feature_compatibility('2.7.0'),
		'feature_compatibility returns true when env minimum exceeds requirement');

	# Test 2: Environment version exactly meets requirement
	ok($env->feature_compatibility('2.8.0'),
		'feature_compatibility returns true when env minimum equals requirement');

	# Test 3: Environment version doesn't meet requirement
	ok(!$env->feature_compatibility('2.9.0'),
		'feature_compatibility returns false when env minimum is less than requirement');

	# Test 4: No minimum specified (0.0.0 allows any 0.0.0 feature)
	my $top2 = make_top(name => 'no-min-feat', minimum_version => undef, no_vault => 1);
	$top2->link_dev_kit('t/src/simple');

	put_file($top2->path('no-min-feat.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: no-min-feat
EOF

	$env = $top2->load_env('no-min-feat');
	ok($env->feature_compatibility('0.0.0'),
		'feature_compatibility returns true with no minimum specified (0.0.0)');
};

subtest 'validate_genesis_version_requirements' => sub {
	plan tests => 10;

	# Test 1: Development version (skip checks)
	local $Genesis::VERSION = '(development)';
	my $top1 = make_top(name => 'dev-mode', minimum_version => undef, no_vault => 1);
	$top1->link_dev_kit('t/src/simple');

	put_file($top1->path('dev-mode.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: dev-mode
  min_version: 999.0.0
EOF

	my $env = $top1->load_env('dev-mode');
	my $result = $env->validate_genesis_version_requirements();

	is(scalar(@{$result->{errors}}), 0,
		'development mode has no errors despite high minimum');
	is(scalar(@{$result->{warnings}}), 1,
		'development mode generates warning');
	like($result->{warnings}[0], qr/development mode/i,
		'warning mentions development mode');

	# Test 2: Running version meets minimum
	local $Genesis::VERSION = '2.8.5';
	my $top2 = make_top(name => 'meets-min', minimum_version => undef, no_vault => 1);
	$top2->link_dev_kit('t/src/simple');

	put_file($top2->path('meets-min.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: meets-min
  min_version: 2.8.0
EOF

	$env = $top2->load_env('meets-min');
	$result = $env->validate_genesis_version_requirements();

	is(scalar(@{$result->{errors}}), 0,
		'no errors when running version meets minimum');
	is($result->{effective_minimum}, '2.8.0',
		'effective_minimum is correctly set');
	is($result->{source}, 'environment file',
		'source correctly identifies environment file');

	# Test 3: Running version doesn't meet minimum
	# Load with compatible version first, then test with lower version
	my $top3 = make_top(name => 'below-min', minimum_version => undef, no_vault => 1);
	$top3->link_dev_kit('t/src/simple');

	put_file($top3->path('below-min.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: below-min
  min_version: 2.8.0
EOF

	local $Genesis::VERSION = '2.8.5';  # Load with compatible version
	$env = $top3->load_env('below-min');

	local $Genesis::VERSION = '2.7.0';  # Test with incompatible version
	$result = $env->validate_genesis_version_requirements();

	is(scalar(@{$result->{errors}}), 1,
		'error generated when running version below minimum');
	like($result->{errors}[0], qr/does not meet.*minimum required version/i,
		'error message describes version requirement failure');

	# Test 4: Environment requires newer than repository (warning)
	local $Genesis::VERSION = '3.0.0';
	my $top4 = make_top(name => 'env-newer', minimum_version => '2.7.0', no_vault => 1);
	$top4->link_dev_kit('t/src/simple');

	put_file($top4->path('env-newer.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: env-newer
  min_version: 2.9.0
EOF

	$env = $top4->load_env('env-newer');
	$result = $env->validate_genesis_version_requirements();

	is(scalar(@{$result->{warnings}}), 1,
		'warning generated when env minimum newer than repo minimum');

	# Test 5: Environment allows older than repository requires (error)
	# Load without conflict first, then set repo minimum to trigger error
	my $top5 = make_top(name => 'env-older', minimum_version => undef, no_vault => 1);
	$top5->link_dev_kit('t/src/simple');

	put_file($top5->path('env-older.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: env-older
  min_version: 2.6.0
EOF

	$env = $top5->load_env('env-older');

	# Now set repo minimum higher to trigger conflict
	$top5->config->set('minimum_version', '2.7.0');
	$result = $env->validate_genesis_version_requirements();

	is(scalar(@{$result->{errors}}), 1,
		'error generated when env minimum older than repo minimum');
};

subtest 'path' => sub {
	plan tests => 3;

	my $top = make_top(name => 'thing', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path('path-test.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: path-test
EOF

	my $env = $top->load_env('path-test');

	# Test delegation to top->path()
	is($env->path(), $top->path(),
		'path() with no arguments returns top path');

	is($env->path('test-file.yml'), $top->path('test-file.yml'),
		'path() with filename argument delegates to top->path()');

	is($env->path('dir', 'subdir', 'file.txt'), $top->path('dir', 'subdir', 'file.txt'),
		'path() with multiple arguments delegates to top->path()');
};

subtest 'workpath' => sub {
	plan tests => 5;

	my $top = make_top(name => 'thing', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path('workpath-test.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: workpath-test
EOF

	my $env = $top->load_env('workpath-test');

	# Test workpath() returns a path
	my $work1 = $env->workpath();
	ok(defined($work1), 'workpath() returns a defined value');
	ok(length($work1) > 0, 'workpath() returns a non-empty string');

	# Test workpath() with arguments
	my $work2 = $env->workpath('subdir');
	ok(defined($work2), 'workpath() with argument returns a defined value');
	like($work2, qr/subdir$/, 'workpath() with argument appends to base path');

	# Test workpath() is memoized
	my $work3 = $env->workpath();
	is($work1, $work3, 'workpath() returns consistent memoized base path');

	# NOTE: Testing automatic cleanup on script exit would require process-level
	# testing and belongs in integration or E2E tests
};

subtest 'relate - environment file relationships' => sub {
	plan tests => 8;

	# Test relate() logic using blessed objects (no file I/O needed)
	my $a = bless({ name => "us-west-1-preprod-a" }, 'Genesis::Env');
	my $b = bless({ name => "us-west-1-prod"      }, 'Genesis::Env');

	cmp_deeply([$a->relate($b)], [qw[
			./us.yml
			./us-west.yml
			./us-west-1.yml
			./us-west-1-preprod.yml
			./us-west-1-preprod-a.yml
		]], "(us-west-1-preprod-a)->relate(us-west-1-prod) returns correct hierarchy");

	cmp_deeply([$a->relate($b, ".cache")], [qw[
			.cache/us.yml
			.cache/us-west.yml
			.cache/us-west-1.yml
			./us-west-1-preprod.yml
			./us-west-1-preprod-a.yml
		]], "relate() handles cache prefix for common files");

	cmp_deeply([$a->relate($b, ".cache", "TOP/LEVEL")], [qw[
			.cache/us.yml
			.cache/us-west.yml
			.cache/us-west-1.yml
			TOP/LEVEL/us-west-1-preprod.yml
			TOP/LEVEL/us-west-1-preprod-a.yml
		]], "relate() handles both cache and top prefixes");

	cmp_deeply([$a->relate("us-east-sandbox", ".cache", "TOP/LEVEL")], [qw[
			.cache/us.yml
			TOP/LEVEL/us-west.yml
			TOP/LEVEL/us-west-1.yml
			TOP/LEVEL/us-west-1-preprod.yml
			TOP/LEVEL/us-west-1-preprod-a.yml
		]], "relate() accepts environment name string instead of object");

	cmp_deeply([$a->relate($a, ".cache", "TOP/LEVEL")], [qw[
			.cache/us.yml
			.cache/us-west.yml
			.cache/us-west-1.yml
			.cache/us-west-1-preprod.yml
			.cache/us-west-1-preprod-a.yml
		]], "relate() to self returns all files as common");

	cmp_deeply([$a->relate(undef, ".cache", "TOP/LEVEL")], [qw[
			TOP/LEVEL/us.yml
			TOP/LEVEL/us-west.yml
			TOP/LEVEL/us-west-1.yml
			TOP/LEVEL/us-west-1-preprod.yml
			TOP/LEVEL/us-west-1-preprod-a.yml
		]], "relate() to undef treats all files as unique");

	cmp_deeply(scalar $a->relate($b, ".cache", "TOP/LEVEL"), {
			common => [qw[
				.cache/us.yml
				.cache/us-west.yml
				.cache/us-west-1.yml
			]],
			unique => [qw[
				TOP/LEVEL/us-west-1-preprod.yml
				TOP/LEVEL/us-west-1-preprod-a.yml
			]],
		}, "relate() in scalar context returns hashref with common/unique");

	# Test potential_environment_files() integration with PREVIOUS_ENV cache
	{
		local $ENV{PREVIOUS_ENV} = 'us-west-1-sandbox';
		cmp_deeply([$a->potential_environment_files()], [qw[
				.genesis/cached/us-west-1-sandbox/us.yml
				.genesis/cached/us-west-1-sandbox/us-west.yml
				.genesis/cached/us-west-1-sandbox/us-west-1.yml
				./us-west-1-preprod.yml
				./us-west-1-preprod-a.yml
			]], "potential_environment_files() with PREVIOUS_ENV uses Genesis cache");
	}
};

subtest 'manifest_store - manifest storage strategy with version compatibility' => sub {
	plan tests => 9;

	# Test 1: Default value with modern Genesis version (>= 3.1.0)
	my $top1 = make_top(name => 'modern', manifest_store => undef, minimum_version => undef, creator_version => '3.1.0', no_vault => 1);
	$top1->link_dev_kit('t/src/simple');

	put_file($top1->path('modern-env.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: modern-env
  min_version: 3.1.0
EOF

	my $env = $top1->load_env('modern-env');
	is($env->manifest_store, 'hybrid',
		'manifest_store defaults to "hybrid" for Genesis 3.1.0+');

	# Test 2: Config value 'exodus' with modern Genesis version
	my $top2 = make_top(name => 'modern2', manifest_store => 'exodus', minimum_version => undef, creator_version => '3.1.0', no_vault => 1);
	$top2->link_dev_kit('t/src/simple');

	put_file($top2->path('exodus-env.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: exodus-env
  min_version: 3.1.0
EOF

	$env = $top2->load_env('exodus-env');
	is($env->manifest_store, 'exodus',
		'manifest_store reads "exodus" from top config for Genesis 3.1.0+');

	# Test 3: Config value 'repository' with modern Genesis version
	my $top3 = make_top(name => 'modern3', manifest_store => 'repository', minimum_version => undef, creator_version => '3.1.0', no_vault => 1);
	$top3->link_dev_kit('t/src/simple');

	put_file($top3->path('repo-env.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: repo-env
  min_version: 3.1.0
EOF

	$env = $top3->load_env('repo-env');
	is($env->manifest_store, 'repository',
		'manifest_store reads "repository" from top config for Genesis 3.1.0+');

	# Test 4: Legacy Genesis version (< 3.1.0) always returns 'repository'
	my $top4 = make_top(name => 'legacy', manifest_store => undef, minimum_version => undef, creator_version => '3.0.0', no_vault => 1);
	$top4->link_dev_kit('t/src/simple');

	put_file($top4->path('legacy-env.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: legacy-env
  min_version: 3.0.0
EOF

	$env = $top4->load_env('legacy-env');
	is($env->manifest_store, 'repository',
		'manifest_store returns "repository" for Genesis < 3.1.0');

	# Test 5: Legacy version ignores config setting
	my $top5 = make_top(name => 'legacy2', manifest_store => 'exodus', minimum_version => undef, creator_version => '3.0.0', no_vault => 1);
	$top5->link_dev_kit('t/src/simple');

	put_file($top5->path('legacy-exodus.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: legacy-exodus
  min_version: 3.0.0
EOF

	$env = $top5->load_env('legacy-exodus');
	is($env->manifest_store, 'repository',
		'manifest_store returns "repository" for Genesis < 3.1.0 even when config is "exodus"');

	# Test 6: No minimum version specified (defaults to 0.0.0, legacy behavior)
	my $top6 = make_top(name => 'no-min', manifest_store => undef, minimum_version => undef, creator_version => '3.0.0', no_vault => 1);
	$top6->link_dev_kit('t/src/simple');

	put_file($top6->path('no-min-env.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: no-min-env
EOF

	$env = $top6->load_env('no-min-env');
	is($env->manifest_store, 'repository',
		'manifest_store returns "repository" when no minimum version specified');

	# Test 7: Config setting honored when repo minimum_version >= 3.1.0
	my $top7 = make_top(name => 'repo-min', minimum_version => '3.1.0', manifest_store => undef, creator_version => '3.1.0', no_vault => 1);
	$top7->link_dev_kit('t/src/simple');

	put_file($top7->path('repo-min-env.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: repo-min-env
EOF

	$env = $top7->load_env('repo-min-env');
	is($env->manifest_store, 'hybrid',
		'manifest_store defaults to "hybrid" when repo minimum_version >= 3.1.0');

	# Test 8: Config changes are reflected immediately
	my $top8 = make_top(name => 'memo-test', minimum_version => '3.1.0', manifest_store => 'exodus', creator_version => '3.1.0', no_vault => 1);
	$top8->link_dev_kit('t/src/simple');

	put_file($top8->path('memo-env.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: memo-env
EOF

	$env = $top8->load_env('memo-env');
	my $result1 = $env->manifest_store;
	is($result1, 'exodus', 'manifest_store reads initial config value');

	# Change config value after loading - should reflect the new value
	$top8->config->set('manifest_store', 'repository');
	my $result2 = $env->manifest_store;

	is($result2, 'repository',
		'manifest_store() reflects config changes (not memoized)');
};

done_testing;  # 21 subtests + 4 use_ok calls = 25 tests total

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
