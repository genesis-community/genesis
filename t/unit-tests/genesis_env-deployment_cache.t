#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 't';
use helper;

use Test::More;
use Test::Deep;
use Test::Exception;
use File::Path qw/rmtree/;

use Genesis;
$Genesis::VERSION = '999.999.999';
use_ok 'Genesis::Config';
$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");

use_ok 'Genesis::Top';
use_ok 'Genesis::Env';

# ===========================================================================
# deployment_cache_setup - sets up deployment cache directory and file paths
# ===========================================================================
subtest 'deployment_cache_setup' => sub {
	local $ENV{GENESIS_TESTING} = 1;

	my $env = make_env_with_kit('t/src/simple', 'test-env');
	my $top = $env->top;

	# Cache should not be set up initially
	is($env->{__deployment_cache_path}, undef, "cache path not set before setup");
	is($env->{__deployment_cache_files}, undef, "cache files not set before setup");

	# Run setup
	$env->deployment_cache_setup();

	# Verify cache directory was created
	my $expected_cache_dir = $top->path('.genesis/deploy-cache/test-env');
	ok(-d $expected_cache_dir, "cache directory created");

	# Verify cache path is set
	is($env->{__deployment_cache_path}, $expected_cache_dir, "cache path set correctly");

	# Verify cache files map is set with all expected keys
	my $files = $env->{__deployment_cache_files};
	is(ref($files), 'HASH', "cache files is a hash");

	# Check all expected file paths
	is($files->{manifest}, "$expected_cache_dir/test-env.yml", "manifest path correct");
	is($files->{unpruned_manifest}, "$expected_cache_dir/test-env-unpruned.yml", "unpruned_manifest path correct");
	is($files->{redacted_manifest}, "$expected_cache_dir/test-env-redacted.yml", "redacted_manifest path correct");
	is($files->{vars}, "$expected_cache_dir/test-env.vars", "vars path correct");
	is($files->{redacted_vars}, "$expected_cache_dir/test-env-redacted.vars", "redacted_vars path correct");
	is($files->{state}, "$expected_cache_dir/test-env-state.json", "state path correct");
	is($files->{store}, "$expected_cache_dir/test-env-store.yml", "store path correct");
	is($files->{deploy_log}, "$expected_cache_dir/test-env-output.log", "deploy_log path correct");

	done_testing;
};

# ===========================================================================
# deployment_cache_setup - idempotent (can run multiple times)
# ===========================================================================
subtest 'deployment_cache_setup - idempotent' => sub {
	local $ENV{GENESIS_TESTING} = 1;

	my $env = make_env_with_kit('t/src/simple', 'test-env');

	# Run setup twice - should not error
	lives_ok { $env->deployment_cache_setup() } "first setup succeeds";
	lives_ok { $env->deployment_cache_setup() } "second setup succeeds (idempotent)";

	# Cache should still be properly configured
	ok(-d $env->{__deployment_cache_path}, "cache directory still exists");
	is(scalar(keys %{$env->{__deployment_cache_files}}), 8, "all 8 cache file paths defined");

	done_testing;
};

# ===========================================================================
# deployment_cache_path_lookup - retrieves paths from the cache
# ===========================================================================
subtest 'deployment_cache_path_lookup' => sub {
	local $ENV{GENESIS_TESTING} = 1;

	my $env = make_env_with_kit('t/src/simple', 'test-env');

	# Before setup, returns empty hash for any lookup
	is_deeply($env->deployment_cache_path_lookup(), {}, "returns empty hash before setup");
	is_deeply($env->deployment_cache_path_lookup('manifest'), {}, "returns empty hash for specific key before setup");

	# Setup the cache
	$env->deployment_cache_setup();

	# No descriptor - returns cache directory
	is($env->deployment_cache_path_lookup(), $env->{__deployment_cache_path}, "no descriptor returns cache path");

	# Specific descriptor - returns that file path
	like($env->deployment_cache_path_lookup('manifest'), qr/test-env\.yml$/, "manifest descriptor returns manifest path");
	like($env->deployment_cache_path_lookup('vars'), qr/test-env\.vars$/, "vars descriptor returns vars path");
	like($env->deployment_cache_path_lookup('state'), qr/test-env-state\.json$/, "state descriptor returns state path");

	# 'all' descriptor - returns all file paths
	my $all = $env->deployment_cache_path_lookup('all');
	is(ref($all), 'HASH', "'all' returns hashref");
	is(scalar(keys %$all), 8, "'all' returns all 8 file paths");
	ok(exists $all->{manifest}, "'all' includes manifest");
	ok(exists $all->{deploy_log}, "'all' includes deploy_log");

	# 'existing' descriptor - returns only files that exist
	my $existing = $env->deployment_cache_path_lookup('existing');
	is(ref($existing), 'HASH', "'existing' returns hashref");
	is(scalar(keys %$existing), 0, "'existing' returns empty when no files exist");

	# Create a file and check again
	put_file($env->{__deployment_cache_files}{manifest}, "test manifest");
	$existing = $env->deployment_cache_path_lookup('existing');
	is(scalar(keys %$existing), 1, "'existing' returns 1 when one file exists");
	ok(exists $existing->{manifest}, "'existing' includes the manifest file");

	# Invalid descriptor - should die
	throws_ok { $env->deployment_cache_path_lookup('invalid_key') }
		qr/Invalid deployment cache path/,
		"invalid descriptor dies with error";

	done_testing;
};

# ===========================================================================
# deployment_cache_cleanup - removes the deployment cache directory
# ===========================================================================
subtest 'deployment_cache_cleanup' => sub {
	local $ENV{GENESIS_TESTING} = 1;

	my $env = make_env_with_kit('t/src/simple', 'test-env');

	# Setup the cache and create some files
	$env->deployment_cache_setup();
	my $cache_dir = $env->{__deployment_cache_path};
	put_file("$cache_dir/test-env.yml", "test manifest");
	put_file("$cache_dir/test-env.vars", "test vars");

	ok(-d $cache_dir, "cache directory exists before cleanup");
	ok(-f "$cache_dir/test-env.yml", "manifest file exists before cleanup");

	# Run cleanup
	$env->deployment_cache_cleanup();

	# Directory should be removed
	ok(!-d $cache_dir, "cache directory removed after cleanup");

	done_testing;
};

# ===========================================================================
# deployment_cache_cleanup - safe when cache not set up
# ===========================================================================
subtest 'deployment_cache_cleanup - safe when not set up' => sub {
	local $ENV{GENESIS_TESTING} = 1;

	my $env = make_env_with_kit('t/src/simple', 'test-env');

	# Cleanup without setup - should not error
	lives_ok { $env->deployment_cache_cleanup() } "cleanup without setup does not error";

	done_testing;
};

# ===========================================================================
# deployment_cache_setup - hyphenated environment names
# ===========================================================================
subtest 'deployment_cache_setup - hyphenated env name' => sub {
	local $ENV{GENESIS_TESTING} = 1;

	my $env = make_env_with_kit('t/src/simple', 'us-west-1-prod');
	my $top = $env->top;
	$env->deployment_cache_setup();

	my $expected_cache_dir = $top->path('.genesis/deploy-cache/us-west-1-prod');
	ok(-d $expected_cache_dir, "cache directory created for hyphenated name");
	is($env->{__deployment_cache_path}, $expected_cache_dir, "cache path set for hyphenated name");

	# File paths should use the hyphenated name
	is($env->{__deployment_cache_files}{manifest}, "$expected_cache_dir/us-west-1-prod.yml",
		"manifest path uses hyphenated name");

	done_testing;
};

done_testing;
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
