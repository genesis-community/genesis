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

# Helper: build a standard non-create-env environment backed by 'simple' kit
sub make_simple_env {
	my ($env_name, %extra_genesis) = @_;
	my $top = make_top(name => 'cf', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	my $genesis_block = "  env: $env_name\n";
	for my $k (keys %extra_genesis) {
		$genesis_block .= "  $k: $extra_genesis{$k}\n";
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

# Helper: build a create-env environment backed by 'bosh-3.0.0-create-env' kit
sub make_create_env {
	my ($env_name) = @_;
	my $top = make_top(name => 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/bosh-3.0.0-create-env');

	put_file($top->path("$env_name.yml"), <<"EOF");
---
kit:
  name:    dev
  version: latest
  features: []
genesis:
  env: $env_name
EOF

	return $top->load_env($env_name);
}

# ======================================================================
# configs()
# ======================================================================

subtest 'configs - empty when nothing registered' => sub {
	plan tests => 3;

	# Isolate from any GENESIS_*_CONFIG vars in the outer environment
	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('no-configs');
	$env->{__configs} = {};

	my @list = $env->configs;
	is(scalar(@list), 0, 'configs() returns empty list when nothing registered');

	my $ref = $env->configs;
	is(ref($ref), 'ARRAY', 'configs() in scalar context returns an arrayref');
	is(scalar(@{$ref}), 0, 'configs() arrayref is empty when nothing registered');
};

subtest 'configs - picks up GENESIS_CLOUD_CONFIG env var' => sub {
	plan tests => 2;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('cloud-env-var');
	$env->{__configs} = {};

	local $ENV{GENESIS_CLOUD_CONFIG} = '/tmp/cloud.yml';

	my @list = $env->configs;
	is(scalar(@list), 1, 'configs() returns one entry when GENESIS_CLOUD_CONFIG set');
	is($list[0], 'cloud', 'configs() returns "cloud" from GENESIS_CLOUD_CONFIG');
};

subtest 'configs - picks up GENESIS_RUNTIME_CONFIG env var' => sub {
	plan tests => 2;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('runtime-env-var');
	$env->{__configs} = {};

	local $ENV{GENESIS_RUNTIME_CONFIG} = '/tmp/runtime.yml';

	my @list = $env->configs;
	is(scalar(@list), 1, 'configs() returns one entry when GENESIS_RUNTIME_CONFIG set');
	is($list[0], 'runtime', 'configs() returns "runtime" from GENESIS_RUNTIME_CONFIG');
};

subtest 'configs - use_config registers in both __configs and returns via configs()' => sub {
	plan tests => 3;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('use-config-test');
	$env->{__configs} = {};

	# use_config sets both __configs and the env var
	$env->use_config('/tmp/cloud.yml', 'cloud');

	my @list = $env->configs;
	is(scalar(@list), 1, 'configs() returns 1 entry after use_config(cloud)');
	is($list[0], 'cloud', 'configs() returns "cloud" after use_config(cloud)');

	$env->use_config('/tmp/runtime.yml', 'runtime');
	my @both = sort $env->configs;
	is(scalar(@both), 2, 'configs() returns 2 entries after use_config(cloud) and use_config(runtime)');
};

subtest 'configs - scalar context returns arrayref' => sub {
	plan tests => 2;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('scalar-context');
	$env->{__configs} = {};
	$env->use_config('/tmp/cloud.yml', 'cloud');

	my $ref = $env->configs;
	is(ref($ref), 'ARRAY', 'configs() scalar context returns arrayref');
	is($ref->[0], 'cloud', 'arrayref contains "cloud"');
};

# ======================================================================
# required_configs()
# ======================================================================

subtest 'required_configs - returns empty list for create-env environments' => sub {
	plan tests => 2;

	my $env = make_create_env('create-env-test');
	ok($env->use_create_env, 'sanity: environment is a create-env');

	my @required = $env->required_configs('blueprint');
	is(scalar(@required), 0, 'required_configs(blueprint) returns empty list for create-env');
};

subtest 'required_configs - blueprint hook requires cloud (default kit behaviour)' => sub {
	plan tests => 2;

	my $env = make_simple_env('req-blueprint');

	my @required = $env->required_configs('blueprint');
	is(scalar(@required), 1, 'required_configs(blueprint) returns 1 config');
	is($required[0], 'cloud', 'required_configs(blueprint) requires cloud config');
};

subtest 'required_configs - manifest hook requires cloud (default kit behaviour)' => sub {
	plan tests => 2;

	my $env = make_simple_env('req-manifest');

	my @required = $env->required_configs('manifest');
	is(scalar(@required), 1, 'required_configs(manifest) returns 1 config');
	is($required[0], 'cloud', 'required_configs(manifest) requires cloud config');
};

subtest 'required_configs - check hook requires cloud unless GENESIS_CONFIG_NO_CHECK' => sub {
	plan tests => 2;

	local %ENV = %ENV;
	delete $ENV{GENESIS_CONFIG_NO_CHECK};

	my $env = make_simple_env('req-check');

	my @required = $env->required_configs('check');
	is(scalar(@required), 1, 'required_configs(check) returns 1 config by default');
	is($required[0], 'cloud', 'required_configs(check) requires cloud');
};

subtest 'required_configs - check hook requires nothing when GENESIS_CONFIG_NO_CHECK set' => sub {
	plan tests => 1;

	local $ENV{GENESIS_CONFIG_NO_CHECK} = '1';

	my $env = make_simple_env('req-check-skip');

	my @required = $env->required_configs('check');
	is(scalar(@required), 0, 'required_configs(check) returns empty when GENESIS_CONFIG_NO_CHECK set');
};

subtest 'required_configs - explicit blueprint hook requires cloud when called directly' => sub {
	plan tests => 2;

	my $env = make_simple_env('req-direct');

	# Calling blueprint directly (without deploy expansion) requires cloud
	my @required = $env->required_configs('blueprint');
	is(scalar(@required), 1, 'required_configs(blueprint) called directly returns 1 config');
	is($required[0], 'cloud', 'required_configs(blueprint) called directly requires cloud');
};

# ======================================================================
# has_config() and config_file()
# ======================================================================

subtest 'has_config - false when config not registered' => sub {
	plan tests => 2;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('has-config-false');
	$env->{__configs} = {};

	ok(!$env->has_config('cloud'),   'has_config(cloud) is false when not registered');
	ok(!$env->has_config('runtime'), 'has_config(runtime) is false when not registered');
};

subtest 'has_config - true after use_config registers it' => sub {
	plan tests => 2;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('has-config-true');
	$env->{__configs} = {};

	$env->use_config('/tmp/cloud.yml', 'cloud');
	ok($env->has_config('cloud'),    'has_config(cloud) is true after use_config(cloud)');
	ok(!$env->has_config('runtime'), 'has_config(runtime) is still false');
};

subtest 'has_config - true when GENESIS_CLOUD_CONFIG env var is set' => sub {
	plan tests => 1;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('has-config-env');
	$env->{__configs} = {};

	local $ENV{GENESIS_CLOUD_CONFIG} = '/tmp/cloud.yml';
	ok($env->has_config('cloud'), 'has_config(cloud) is true when GENESIS_CLOUD_CONFIG env var is set');
};

subtest 'has_config - with named config (type@name)' => sub {
	plan tests => 3;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('has-config-named');
	$env->{__configs} = {};

	$env->use_config('/tmp/cloud-az1.yml', 'cloud', 'az1');

	ok($env->has_config('cloud', 'az1'),
		'has_config(cloud, az1) is true after use_config with name');
	ok(!$env->has_config('cloud'),
		'has_config(cloud) without name is false (different label)');
	ok(!$env->has_config('cloud', 'az2'),
		'has_config(cloud, az2) is false for a different name');
};

# ======================================================================
# missing_required_configs()
# ======================================================================

subtest 'missing_required_configs - all required when none registered' => sub {
	plan tests => 2;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('missing-all');
	$env->{__configs} = {};

	my @missing = $env->missing_required_configs('blueprint');
	is(scalar(@missing), 1, 'missing_required_configs(blueprint) returns 1 when nothing registered');
	is($missing[0], 'cloud', 'missing_required_configs(blueprint) identifies "cloud" as missing');
};

subtest 'missing_required_configs - empty when all required are present' => sub {
	plan tests => 1;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('missing-none');
	$env->{__configs} = {};

	$env->use_config('/tmp/cloud.yml', 'cloud');

	my @missing = $env->missing_required_configs('blueprint');
	is(scalar(@missing), 0, 'missing_required_configs(blueprint) returns empty when cloud is registered');
};

subtest 'missing_required_configs - empty for create-env environments' => sub {
	plan tests => 1;

	my $env = make_create_env('missing-create-env');

	my @missing = $env->missing_required_configs('deploy');
	is(scalar(@missing), 0, 'missing_required_configs() returns empty list for create-env');
};

# ======================================================================
# has_required_configs()
# ======================================================================

subtest 'has_required_configs - false when required configs absent' => sub {
	plan tests => 1;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('hrc-false');
	$env->{__configs} = {};

	ok(!$env->has_required_configs('blueprint'),
		'has_required_configs(blueprint) is false when cloud config not registered');
};

subtest 'has_required_configs - true when all required configs present' => sub {
	plan tests => 1;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('hrc-true');
	$env->{__configs} = {};

	$env->use_config('/tmp/cloud.yml', 'cloud');

	ok($env->has_required_configs('blueprint'),
		'has_required_configs(blueprint) is true when cloud config is registered');
};

subtest 'has_required_configs - always true for create-env environments' => sub {
	plan tests => 1;

	my $env = make_create_env('hrc-create-env');

	ok($env->has_required_configs('deploy'),
		'has_required_configs(deploy) is always true for create-env environments');
};

subtest 'has_required_configs - true when hook requires no configs' => sub {
	plan tests => 1;

	local %ENV = %ENV;
	delete $ENV{$_} for grep { /^GENESIS_[A-Z0-9_]+_CONFIG/ } keys %ENV;

	my $env = make_simple_env('hrc-no-req');
	$env->{__configs} = {};

	# cloud-config hook is special-cased in Kit::required_configs to return ()
	ok($env->has_required_configs('cloud-config'),
		'has_required_configs(cloud-config) is true (no configs required for this hook)');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
