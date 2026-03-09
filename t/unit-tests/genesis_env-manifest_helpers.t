#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

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

# ============================================================================
# _init_yaml_file tests
# ============================================================================
# The _init_yaml_file method generates an init.yml file used as the first
# merge input for manifest generation. It has two formats:
# - Modern format (kit genesis_version_min >= 2.6.13): Simple structure
# - Legacy format (kit genesis_version_min < 2.6.13): Includes spruce operators

subtest '_init_yaml_file - modern kit format (>= 2.6.13)' => sub {
	# simple kit has genesis_version_min: 2.8.0 (>= 2.6.13)
	my $env = make_env_with_kit('t/src/simple', 'test-env');

	my $init_file = $env->_init_yaml_file;
	ok(-f $init_file, 'init.yml file was created');
	like($init_file, qr/init\.yml$/, 'file is named init.yml');

	my $data = load_yaml_file($init_file);

	# Verify vault path from secrets_base (default is secret/<type>/<env>)
	my $vault_path = $env->secrets_base =~ s#/?$##r;

	cmp_deeply($data, {
		meta => { vault => $vault_path },
		kit => { features => [] },
		exodus => {},
		genesis => {},
		params => {},
	}, 'modern format has correct structure');
};

subtest '_init_yaml_file - legacy kit format (< 2.6.13)' => sub {
	# legacy kit has genesis_version_min: 2.6.0 (< 2.6.13)
	my $env = make_env_with_kit('t/src/legacy', 'legacy-env');

	my $init_file = $env->_init_yaml_file;
	ok(-f $init_file, 'init.yml file was created');

	my $data = load_yaml_file($init_file);

	my $vault_path = $env->secrets_base =~ s#/?$##r;
	my $type = $env->type;

	cmp_deeply($data, {
		meta => { vault => $vault_path },
		kit => { features => [] },
		exodus => {},
		genesis => {},
		params => {
			env => '(( grab genesis.env ))',
			name => "(( concat genesis.env || params.env \"-$type\" ))",
		},
	}, 'legacy format has spruce operators in params');
};

subtest '_init_yaml_file - vault path normalization' => sub {
	# Test with custom secrets_path (trailing slash should be stripped)
	my $env = make_env_with_kit('t/src/simple', 'path-env', secrets_path => 'custom/path/');

	my $init_file = $env->_init_yaml_file;
	my $data = load_yaml_file($init_file);

	# Verify vault path has trailing slash stripped (backwards compatibility)
	is($data->{meta}{vault}, '/secret/custom/path', 'trailing slash stripped from vault path');
};

subtest '_init_yaml_file - uses workpath' => sub {
	my $env = make_env_with_kit('t/src/simple', 'workpath-env');

	my $init_file = $env->_init_yaml_file;

	# File should be in workpath directory
	my $workpath = $env->workpath;
	like($init_file, qr/^\Q$workpath\E/, 'init.yml is in workpath');
};

# ============================================================================
# _cap_yaml_file tests
# ============================================================================
# The _cap_yaml_file method generates a fin.yml file used as the final merge
# input. It sets deployment name, genesis metadata, and exodus data.
# For create-env deployments, BOSH-related fields are set to ~.

subtest '_cap_yaml_file - create-env deployment' => sub {
	# bosh-3.0.0-create-env kit has use_create_env: yes
	# name => 'bosh' sets the repo type to 'bosh' so deployment name is correct
	my $env = make_env_with_kit('t/src/bosh-3.0.0-create-env', 'my-bosh-env', name => 'bosh', iaas => 'aws');

	my $cap_file = $env->_cap_yaml_file;
	ok(-f $cap_file, 'fin.yml file was created');
	like($cap_file, qr/fin\.yml$/, 'file is named fin.yml');

	my $data = load_yaml_file($cap_file);

	# Deployment name uses spruce concat with repo type
	is($data->{name}, '(( concat genesis.env "-bosh" ))', 'deployment name uses spruce concat');

	# Genesis block - verify structure (vault paths have leading /)
	cmp_deeply($data->{genesis}, superhashof({
		env => 'my-bosh-env',
		type => 'bosh',
		vault_env => re(qr/^my\/bosh\/env$/),
		secrets_mount => re(qr{^/secret/?$}),
		secrets_path => re(qr/.+/),
		secrets_base => re(qr/.+/),
		exodus_mount => re(qr{^/secret/exodus/?$}),
		exodus_path => re(qr/.+/),
		exodus_base => re(qr/.+/),
		ci_mount => re(qr{^/secret/ci/?$}),
	}), 'genesis block has required fields');

	# For create-env, bosh_env should NOT be present
	ok(!exists $data->{genesis}{bosh_env}, 'create-env does not have bosh_env in genesis block');

	# Exodus block - verify structure
	cmp_deeply($data->{exodus}, superhashof({
		version => re(qr/^\d+\.\d+\.\d+/),
		dated => re(qr/^\d{4}-\d{2}-\d{2}/),
		deployer => re(qr/.*/),
		kit_name => re(qr/.+/),
		kit_version => re(qr/.+/),
		kit_is_dev => bool(1),
		vault_base => '(( grab meta.vault ))',
		bosh => undef, # ~ in YAML
		is_director => bool(1),
		use_create_env => bool(1),
		features => '(( join "," kit.features ))',
	}), 'exodus block has required fields for create-env');
};

subtest '_cap_yaml_file - exodus metadata fields' => sub {
	my $env = make_env_with_kit('t/src/bosh-3.0.0-create-env', 'exodus-test', iaas => 'aws');

	my $cap_file = $env->_cap_yaml_file;
	my $data = load_yaml_file($cap_file);

	# Check that iaas and scale are included
	ok(exists $data->{exodus}{iaas}, 'exodus.iaas exists');
	ok(exists $data->{exodus}{scale}, 'exodus.scale exists');
};

subtest '_cap_yaml_file - vault paths from env' => sub {
	my $env = make_env_with_kit('t/src/bosh-3.0.0-create-env', 'vault-cap-test',
		name => 'bosh',
		iaas => 'aws',
		secrets_mount => 'custom/mount/',
		secrets_path => 'custom/path',
		exodus_mount => 'exodus/mount/',
		ci_mount => 'ci/mount/'
	);

	my $cap_file = $env->_cap_yaml_file;
	my $data = load_yaml_file($cap_file);

	# Verify custom mounts are used (normalized - leading / added, trailing slash stripped)
	is($data->{genesis}{secrets_mount}, '/custom/mount/', 'custom secrets_mount is used');
	is($data->{genesis}{secrets_path}, 'custom/path', 'custom secrets_path is used');
	is($data->{genesis}{exodus_mount}, '/exodus/mount/', 'custom exodus_mount is used');
	is($data->{genesis}{ci_mount}, '/ci/mount/', 'custom ci_mount is used');
};

# ============================================================================
# deployment_manifest_type tests
# ============================================================================
# This method returns one of: unredacted, entombed, vaultified, vaultified_entombed
# Based on can_be_entombed and is_vaultified status.
#
# Note: Full testing of v3.0.0+ entombed/vaultified paths requires integration
# tests with vault access. The tests here cover the basic paths that don't
# require external service access.
#
# TODO: Refactor Genesis::Env to separate external service interaction (vault,
# BOSH) from runtime data access to improve testability. Consider patterns like
# Repository pattern or Service Locator to inject mock services during testing.

subtest 'deployment_manifest_type - not entombable returns unredacted' => sub {
	# simple kit with genesis_version_min: 2.8.0 (< 3.0.0-rc.1)
	# can_be_entombed returns false for this kit
	my $env = make_env_with_kit('t/src/simple', 'unredacted-env');

	# Verify precondition
	ok(!$env->can_be_entombed, 'env cannot be entombed (kit too old)');

	# is_vaultified requires feature_compatibility('3.0.0-rc.1')
	# which simple kit (2.8.0) doesn't have, so it returns false
	ok(!$env->is_vaultified, 'env is not vaultified (kit too old)');

	# deployment_manifest_type should return 'unredacted'
	is($env->deployment_manifest_type, 'unredacted', 'returns unredacted for non-entombable env');
};

subtest 'deployment_manifest_type - create-env returns unredacted' => sub {
	# bosh-3.0.0-create-env has genesis_version_min: 3.0.0 but use_create_env: yes
	# can_be_entombed returns false for create-env
	my $env = make_env_with_kit('t/src/bosh-3.0.0-create-env', 'create-env-type', iaas => 'aws');

	ok($env->use_create_env, 'env uses create_env');
	ok(!$env->can_be_entombed, 'create-env cannot be entombed');

	is($env->deployment_manifest_type, 'unredacted', 'create-env returns unredacted');
};

subtest 'deployment_manifest_type - create-env cannot be vaultified' => sub {
	# Verify that is_vaultified is always false for create-env
	# (code explicitly checks: && ! $self->use_create_env)
	my $env = make_env_with_kit('t/src/bosh-3.0.0-create-env', 'create-env-vaultify', iaas => 'aws');

	ok($env->use_create_env, 'env uses create_env');
	ok(!$env->is_vaultified, 'create-env is never vaultified (code constraint)');
	ok(!$env->can_be_entombed, 'create-env cannot be entombed');

	# Always returns unredacted for create-env
	is($env->deployment_manifest_type, 'unredacted', 'create-env always returns unredacted');
};

# ============================================================================
# v3.0.0+ entombed/vaultified precondition tests
# ============================================================================
# These tests verify the preconditions (can_be_entombed, is_vaultified) that
# determine deployment_manifest_type for v3.0.0+ kits. Full deployment_manifest_type
# testing requires integration tests with vault access.

subtest 'can_be_entombed - requires env min_version >= 3.0.0-rc.1' => sub {
	# simple-3.0.0 kit with min_version set in env file
	my $env = make_env_with_kit('t/src/simple-3.0.0', 'entombed-env', min_version => '3.0.0');

	ok(!$env->use_create_env, 'env does not use create_env');
	ok($env->can_be_entombed, 'env can be entombed (env min_version >= 3.0.0)');
};

subtest 'is_vaultified - credhub kit short-circuits' => sub {
	# simple-3.0.0-credhub kit has secrets_store: credhub
	my $env = make_env_with_kit('t/src/simple-3.0.0-credhub', 'vaultified-env', min_version => '3.0.0');

	ok(!$env->use_create_env, 'env does not use create_env');
	ok($env->kit->uses_credhub, 'kit uses credhub secrets_store');
	ok($env->is_vaultified, 'env is vaultified (credhub kit)');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
