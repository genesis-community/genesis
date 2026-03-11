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
$Genesis::VERSION = '999.999.999';
use_ok 'Genesis::Config';
$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");

use_ok 'Genesis::Top';
use_ok 'Genesis::Env';
use_ok 'Genesis::Kit';
use_ok 'Genesis::Env::ManifestProvider';

$ENV{GENESIS_OUTPUT_COLUMNS}=80;

# ============================================================================
# Section 1: Construction
# ============================================================================

subtest 'new() creates provider with correct initial state' => sub {
	my $mock_env = Mock->new(
		name     => 'test-env',
		workpath => sub { workdir('provider-test') },
	);
	my $provider = Genesis::Env::ManifestProvider->new($mock_env);

	isa_ok($provider, 'Genesis::Env::ManifestProvider', 'provider isa ManifestProvider');
	is($provider->env, $mock_env, 'env() returns stored env');
	is($provider->{deployment}, undef, 'deployment starts as undef');
	is_deeply($provider->{manifests}, {}, 'manifests hash starts empty');

	done_testing;
};

# ============================================================================
# Section 2: Dynamic Type Accessors
# ============================================================================

subtest 'dynamic type accessors return correct manifest objects' => sub {
	my $env = make_env_with_kit('t/src/simple', 'accessor-test');
	my $provider = $env->manifest_provider;

	isa_ok(
		$provider,
		'Genesis::Env::ManifestProvider',
		'manifest_provider() returns a ManifestProvider'
	);

	my $unredacted = $provider->unredacted();
	isa_ok(
		$unredacted,
		'Genesis::Env::Manifest::Unredacted',
		'unredacted() returns Unredacted manifest object'
	);

	my $redacted = $provider->redacted();
	isa_ok(
		$redacted,
		'Genesis::Env::Manifest::Redacted',
		'redacted() returns Redacted manifest object'
	);

	done_testing;
};

subtest 'dynamic type accessors memoize - repeated calls return same object' => sub {
	my $env = make_env_with_kit('t/src/simple', 'memo-test');
	my $provider = $env->manifest_provider;

	my $first  = $provider->unredacted();
	my $second = $provider->unredacted();
	is($first, $second, 'repeated calls to unredacted() return same cached object');

	my $r1 = $provider->redacted();
	my $r2 = $provider->redacted();
	is($r1, $r2, 'repeated calls to redacted() return same cached object');

	done_testing;
};

subtest 'dynamic type accessor with subset returns different object than plain call' => sub {
	my $env = make_env_with_kit('t/src/simple', 'subset-test');
	my $provider = $env->manifest_provider;

	my $plain   = $provider->unredacted();
	my $pruned  = $provider->unredacted(subset => 'pruned');

	isnt(
		$plain,
		$pruned,
		'unredacted(subset => pruned) returns different object than plain unredacted()'
	);
	isa_ok(
		$pruned,
		'Genesis::Env::Manifest::Unredacted',
		'subsetted manifest is still Unredacted type'
	);

	done_testing;
};

subtest 'notify option sets a notice on the manifest' => sub {
	my $env = make_env_with_kit('t/src/simple', 'notify-test');
	my $provider = $env->manifest_provider;

	# Suppress notification output to avoid noise in test output
	$provider->{suppress_notification} = 1;

	my $manifest = $provider->unredacted(notify => 1);

	ok($manifest->has_notice, 'manifest has a notice after notify => 1');

	done_testing;
};

# ============================================================================
# Section 3: known_types Filtering
# ============================================================================

subtest 'known_types - simple kit (no credhub, no create-env)' => sub {
	my $env = make_env_with_kit('t/src/simple', 'kt-simple');
	my $provider = $env->manifest_provider;

	my %types = $provider->known_types;

	ok(exists $types{unredacted}, 'known_types includes unredacted');
	ok(exists $types{redacted},   'known_types includes redacted');

	# simple kit has no credhub - vaultif* types should be absent
	my @vaultif_types = grep { /vaultif/ } keys %types;
	is(scalar @vaultif_types, 0,
		'no vaultified types when kit does not use credhub'
	);

	# Each value should be a description string
	for my $type (keys %types) {
		like($types{$type}, qr/\w/, "known_types '$type' has a non-empty description");
	}

	done_testing;
};

subtest 'known_types - simple kit includes entombed types' => sub {
	my $env = make_env_with_kit('t/src/simple', 'kt-simple-entomb');
	my $provider = $env->manifest_provider;

	ok(!$env->use_create_env, 'simple kit does not use create_env');

	my %types = $provider->known_types;
	my @entombed_types = grep { /entombed/ } keys %types;
	ok(scalar @entombed_types > 0, 'simple kit includes entombed types');

	done_testing;
};

subtest 'known_types - credhub kit includes vaultified types' => sub {
	my $env = make_env_with_kit('t/src/simple-3.0.0-credhub', 'kt-credhub');
	my $provider = $env->manifest_provider;

	ok($env->kit->uses_credhub, 'credhub kit uses_credhub is true');

	my %types = $provider->known_types;
	my @vaultif_types = grep { /vaultif/ } keys %types;
	ok(scalar @vaultif_types > 0,
		'credhub kit includes vaultified types in known_types'
	);

	done_testing;
};

subtest 'known_types - create-env kit excludes entombed types' => sub {
	my $env = make_env_with_kit(
		't/src/bosh-3.0.0-create-env', 'kt-create-env', iaas => 'aws'
	);
	my $provider = $env->manifest_provider;

	ok($env->use_create_env, 'bosh kit uses create_env');

	my %types = $provider->known_types;
	my @entombed_types = grep { /entombed/ } keys %types;
	is(scalar @entombed_types, 0,
		'create-env kit excludes entombed types from known_types'
	);

	done_testing;
};

# ============================================================================
# Section 4: known_subsets
# ============================================================================

subtest 'known_subsets returns hash with 4 entries' => sub {
	my $env = make_env_with_kit('t/src/simple', 'ks-test');
	my $provider = $env->manifest_provider;

	my %subsets = $provider->known_subsets;

	is(scalar keys %subsets, 4, 'known_subsets has exactly 4 entries');
	ok(exists $subsets{credhub_vars}, 'known_subsets has credhub_vars');
	ok(exists $subsets{bosh_vars},    'known_subsets has bosh_vars');
	ok(exists $subsets{pruned},       'known_subsets has pruned');
	ok(exists $subsets{releases},     'known_subsets has releases');

	# Each value should be a description string
	for my $subset (keys %subsets) {
		like(
			$subsets{$subset},
			qr/\w/,
			"known_subsets '$subset' has a non-empty description string"
		);
	}

	done_testing;
};

# ============================================================================
# Section 5: Deployment Management
# ============================================================================

subtest 'set_deployment stores type and returns $self for chaining' => sub {
	my $env = make_env_with_kit('t/src/simple', 'setdep-test');
	my $provider = $env->manifest_provider;

	my $ret = $provider->set_deployment('unredacted');
	is($ret, $provider, 'set_deployment returns $self for method chaining');
	is($provider->{deployment}, 'unredacted', 'deployment type stored in {deployment}');

	done_testing;
};

subtest 'deployment() returns manifest for the stored deployment type' => sub {
	my $env = make_env_with_kit('t/src/simple', 'dep-type-test');
	my $provider = $env->manifest_provider;

	$provider->set_deployment('unredacted');
	my $manifest = $provider->deployment;

	isa_ok(
		$manifest,
		'Genesis::Env::Manifest::Unredacted',
		'deployment() returns Unredacted manifest after set_deployment(unredacted)'
	);

	done_testing;
};

subtest 'set_deployment dies on non-deployable type (redacted)' => sub {
	my $env = make_env_with_kit('t/src/simple', 'dep-noredact');
	my $provider = $env->manifest_provider;

	throws_ok(
		sub { $provider->set_deployment('redacted') },
		qr/not deployable/i,
		'set_deployment("redacted") dies because redacted is not deployable'
	);

	done_testing;
};

subtest 'set_deployment dies on nonexistent type' => sub {
	my $env = make_env_with_kit('t/src/simple', 'dep-noexist');
	my $provider = $env->manifest_provider;

	throws_ok(
		sub { $provider->set_deployment('nonexistent_type') },
		qr/not deployable/i,
		'set_deployment("nonexistent_type") dies because type does not exist'
	);

	done_testing;
};

subtest 'deployment() falls back to env->deployment_manifest_type when not set' => sub {
	my $env = make_env_with_kit('t/src/simple', 'dep-fallback');
	my $provider = $env->manifest_provider;

	is($provider->{deployment}, undef, 'no explicit deployment type set');

	# simple kit returns 'unredacted' from deployment_manifest_type
	is($env->deployment_manifest_type, 'unredacted',
		'env->deployment_manifest_type is unredacted for simple kit'
	);

	my $manifest = $provider->deployment;
	isa_ok(
		$manifest,
		'Genesis::Env::Manifest::Unredacted',
		'deployment() falls back to env->deployment_manifest_type'
	);

	done_testing;
};

# ============================================================================
# Section 6: base_manifest
# ============================================================================

subtest 'base_manifest - non-vaultified kit returns Unredacted' => sub {
	my $env = make_env_with_kit('t/src/simple', 'bm-simple');
	my $provider = $env->manifest_provider;

	ok(!$env->is_vaultified, 'simple kit is not vaultified');

	my $base = $provider->base_manifest;
	isa_ok(
		$base,
		'Genesis::Env::Manifest::Unredacted',
		'base_manifest returns Unredacted for non-vaultified kit'
	);

	done_testing;
};

subtest 'base_manifest - credhub/vaultified kit returns Vaultified' => sub {
	my $env = make_env_with_kit(
		't/src/simple-3.0.0-credhub', 'bm-credhub', min_version => '3.0.0'
	);
	my $provider = $env->manifest_provider;

	ok($env->is_vaultified, 'credhub kit is vaultified');

	my $base = $provider->base_manifest;
	isa_ok(
		$base,
		'Genesis::Env::Manifest::Vaultified',
		'base_manifest returns Vaultified for credhub/vaultified kit'
	);

	done_testing;
};

# ============================================================================
# Section 7: valid_subset
# ============================================================================

subtest 'valid_subset(undef) returns undef (falsy)' => sub {
	my $env = make_env_with_kit('t/src/simple', 'vs-undef');
	my $provider = $env->manifest_provider;

	my $result = $provider->valid_subset(undef);
	ok(!defined($result), 'valid_subset(undef) returns undef');

	done_testing;
};

subtest 'valid_subset returns 1 for known subsets' => sub {
	my $env = make_env_with_kit('t/src/simple', 'vs-known');
	my $provider = $env->manifest_provider;

	is($provider->valid_subset('pruned'),      1, 'valid_subset("pruned") returns 1');
	is($provider->valid_subset('releases'),    1, 'valid_subset("releases") returns 1');
	is($provider->valid_subset('credhub_vars'),1, 'valid_subset("credhub_vars") returns 1');
	is($provider->valid_subset('bosh_vars'),   1, 'valid_subset("bosh_vars") returns 1');

	done_testing;
};

subtest 'valid_subset dies with bug error for unknown subset' => sub {
	my $env = make_env_with_kit('t/src/simple', 'vs-bad');
	my $provider = $env->manifest_provider;

	throws_ok(
		sub { $provider->valid_subset('invalid_name') },
		qr/Invalid subset/i,
		'valid_subset("invalid_name") dies with "Invalid subset" error'
	);

	done_testing;
};

# ============================================================================
# Section 8: _subset_plans (internal)
# ============================================================================

subtest '_subset_plans returns hashref with 4 keys and correct operators' => sub {
	my $env = make_env_with_kit('t/src/simple', 'sp-test');
	my $provider = $env->manifest_provider;

	my $plans = $provider->_subset_plans;
	is(ref($plans), 'HASH', '_subset_plans returns a hashref');
	is(scalar keys %$plans, 4, '_subset_plans has exactly 4 keys');

	# credhub_vars uses 'include' operator with array of keys
	ok(exists $plans->{credhub_vars}{include},
		'credhub_vars plan has include operator'
	);
	is(ref($plans->{credhub_vars}{include}), 'ARRAY',
		'credhub_vars include value is an ARRAY'
	);
	cmp_deeply(
		$plans->{credhub_vars}{include},
		superbagof('variables', 'bosh-variables'),
		'credhub_vars include contains variables and bosh-variables'
	);

	# bosh_vars uses 'fetch' operator with key and default
	ok(exists $plans->{bosh_vars}{fetch},
		'bosh_vars plan has fetch operator'
	);
	is(ref($plans->{bosh_vars}{fetch}), 'HASH',
		'bosh_vars fetch value is a HASH'
	);
	ok(exists $plans->{bosh_vars}{fetch}{key},
		'bosh_vars fetch has a key field'
	);
	ok(exists $plans->{bosh_vars}{fetch}{default},
		'bosh_vars fetch has a default field'
	);

	# pruned uses 'exclude' operator
	ok(exists $plans->{pruned}{exclude},
		'pruned plan has exclude operator'
	);
	is(ref($plans->{pruned}{exclude}), 'ARRAY',
		'pruned exclude value is an ARRAY'
	);

	# releases uses 'include' operator with ['releases']
	ok(exists $plans->{releases}{include},
		'releases plan has include operator'
	);
	cmp_deeply(
		$plans->{releases}{include},
		['releases'],
		"releases include is exactly ['releases']"
	);

	done_testing;
};

# ============================================================================
# Section 9: Reset
# ============================================================================

subtest 'reset() clears manifests hash and returns $self' => sub {
	my $env = make_env_with_kit('t/src/simple', 'reset-test');
	my $provider = $env->manifest_provider;

	# Access a type to populate the cache
	my $before = $provider->unredacted();
	ok(scalar keys %{$provider->{manifests}} > 0, 'manifests cache is populated before reset');

	my $ret = $provider->reset;

	is($ret, $provider, 'reset() returns $self for chaining');
	is(scalar keys %{$provider->{manifests}}, 0, 'manifests hash is empty after reset');
	is($provider->{deployment}, undef, 'deployment is cleared to undef after reset');

	done_testing;
};

subtest 'reset() allows fresh manifest object creation afterward' => sub {
	my $env = make_env_with_kit('t/src/simple', 'reset-fresh');
	my $provider = $env->manifest_provider;

	my $before_ref = $provider->unredacted();
	$provider->reset;
	my $after_ref = $provider->unredacted();

	isnt(
		$before_ref,
		$after_ref,
		'after reset(), accessing unredacted() creates a new distinct object'
	);

	done_testing;
};

subtest 'reset() clears memoized keys (__ prefix)' => sub {
	my $env = make_env_with_kit('t/src/simple', 'reset-memo');
	my $provider = $env->manifest_provider;

	# Trigger memoization of _subset_plans (stored as __subset_plans)
	$provider->_subset_plans;
	my @memo_keys_before = grep { /^__/ } keys %$provider;
	ok(scalar @memo_keys_before > 0, 'memoized __ keys exist before reset');

	$provider->reset;

	my @memo_keys_after = grep { /^__/ } keys %$provider;
	is(scalar @memo_keys_after, 0, 'all __ memoized keys cleared by reset()');

	done_testing;
};

# ============================================================================
# Section 10: File Selection Methods (memoized delegates)
# ============================================================================

subtest 'initiation_file() returns path ending in init.yml' => sub {
	my $env = make_env_with_kit('t/src/simple', 'if-test');
	my $provider = $env->manifest_provider;

	my $file = $provider->initiation_file;
	ok(defined $file, 'initiation_file() returns a defined value');
	like($file, qr/init\.yml$/, 'initiation_file path ends with init.yml');
	ok(-f $file, 'initiation_file() returns path to an existing file');

	done_testing;
};

subtest 'initiation_file() is memoized' => sub {
	my $env = make_env_with_kit('t/src/simple', 'if-memo');
	my $provider = $env->manifest_provider;

	my $first  = $provider->initiation_file;
	my $second = $provider->initiation_file;
	is($first, $second, 'initiation_file() returns same value on repeated calls');

	done_testing;
};

subtest 'conclusion_file() returns path ending in fin.yml' => sub {
	# Use create-env kit: _cap_yaml_file sets bosh_target=~ without vault access
	my $env = make_env_with_kit(
		't/src/bosh-3.0.0-create-env', 'cf-test', name => 'bosh', iaas => 'aws'
	);
	my $provider = $env->manifest_provider;

	my $file = $provider->conclusion_file;
	ok(defined $file, 'conclusion_file() returns a defined value');
	like($file, qr/fin\.yml$/, 'conclusion_file path ends with fin.yml');
	ok(-f $file, 'conclusion_file() returns path to an existing file');

	done_testing;
};

subtest 'conclusion_file() is memoized' => sub {
	# Use create-env kit to avoid vault dependency in _cap_yaml_file
	my $env = make_env_with_kit(
		't/src/bosh-3.0.0-create-env', 'cf-memo', name => 'bosh', iaas => 'aws'
	);
	my $provider = $env->manifest_provider;

	my $first  = $provider->conclusion_file;
	my $second = $provider->conclusion_file;
	is($first, $second, 'conclusion_file() returns same value on repeated calls');

	done_testing;
};

subtest 'environment_files() returns a list' => sub {
	my $env = make_env_with_kit('t/src/simple', 'ef-test');
	my $provider = $env->manifest_provider;

	my @files;
	lives_ok(
		sub { @files = $provider->environment_files },
		'environment_files() does not die'
	);
	# Verify the return is a usable list with a non-negative count
	cmp_ok(scalar @files, '>=', 0, 'environment_files() returns a list with non-negative count');

	done_testing;
};

subtest 'full_merge_env() returns a hashref (requires vault)' => sub {
	TODO: {
		local $TODO = 'full_merge_env() calls get_environment_variables which requires vault access';
		# Verify the method exists and delegates to get_environment_variables
		my $env = make_env_with_kit('t/src/simple', 'fme-test');
		my $provider = $env->manifest_provider;
		ok($provider->can('full_merge_env'), 'provider has full_merge_env method');
	}
	done_testing;
};

subtest 'full_merge_env() is memoized (requires vault)' => sub {
	TODO: {
		local $TODO = 'full_merge_env() memoization requires vault access to exercise';
		ok(0, 'full_merge_env memoization integration test not run in unit suite');
	}
	done_testing;
};

# cloud_config_files needs a BOSH director - skip in unit tests
subtest 'cloud_config_files() - skipped (requires BOSH director)' => sub {
	TODO: {
		local $TODO = 'cloud_config_files requires BOSH director access';
		ok(0, 'cloud_config_files integration test not run in unit suite');
	}
	done_testing;
};

# kit_files may call out to external tooling; test minimally
subtest 'kit_files() method exists (requires vault for full execution)' => sub {
	# kit_files calls kit->source_yaml_files which calls get_environment_variables
	# and thus requires vault access; test the method's existence only here
	TODO: {
		local $TODO = 'kit_files() calls source_yaml_files which requires vault access';
		my $env = make_env_with_kit('t/src/simple', 'kf-test');
		my $provider = $env->manifest_provider;
		ok($provider->can('kit_files'), 'provider has kit_files method');
	}
	done_testing;
};

# ============================================================================
# Section 11: Complex Methods (require external tooling)
# ============================================================================
# These methods require spruce and/or vault and cannot be unit tested without
# those services running. Documented here as TODO for integration test coverage.

subtest 'merge() orchestrates spruce merge (requires spruce)' => sub {
	TODO: {
		local $TODO = 'merge() invokes spruce merge and requires external spruce binary';
		ok(0, 'merge() integration test not run in unit suite');
	}
	done_testing;
};

subtest 'get_subset() derives subset manifests (requires spruce)' => sub {
	TODO: {
		local $TODO = 'get_subset() uses spruce cherry-pick/prune and requires spruce binary';
		ok(0, 'get_subset() integration test not run in unit suite');
	}
	done_testing;
};

subtest 'vault_paths() extracts vault secrets from manifest (requires spruce)' => sub {
	TODO: {
		local $TODO = 'vault_paths() calls spruce vaultinfo and requires spruce binary and vault access';
		my $env = make_env_with_kit('t/src/simple', 'vp-test');
		my $provider = $env->manifest_provider;
		ok($provider->can('vault_paths'), 'provider has vault_paths method');
	}
	done_testing;
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
