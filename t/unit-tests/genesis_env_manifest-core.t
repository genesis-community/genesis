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

use_ok 'Genesis::Env::Manifest';
use_ok 'Genesis::Env::Manifest::Unredacted';
use_ok 'Genesis::Env::Manifest::Redacted';
use_ok 'Genesis::Env::Manifest::Entombed';
use_ok 'Genesis::Env::Manifest::VaultifiedEntombed';
use_ok 'Genesis::Env::Manifest::PartialEnvironment';
use_ok 'Genesis::Env::Manifest::Vaultified';

$ENV{GENESIS_OUTPUT_COLUMNS}=80;

# ============================================================================
# Helper: build standard mocks
# ============================================================================

sub _make_mocks {
	my $wdir = workdir('manifests');
	my $mock_env = Mock->new(
		name      => 'test-env',
		signature => 'abc123',
		workpath  => sub { workdir('manifests') },
		path      => sub { workdir() },
		notify    => sub {},
	);
	my $mock_builder = Mock->new(
		env         => $mock_env,
		vault_paths => sub { {} },
	);
	return ($mock_env, $mock_builder);
}

# ============================================================================
# Section 1: Construction and Validation
# ============================================================================

subtest 'new() creates a Manifest object with correct class' => sub {
	my (undef, $mock_builder) = _make_mocks();
	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);
	ok(defined $manifest, 'manifest object was created');
	isa_ok($manifest, 'Genesis::Env::Manifest::Unredacted');
	isa_ok($manifest, 'Genesis::Env::Manifest');
};

subtest 'constructor stores builder, subset, and initializes file/data to undef' => sub {
	my (undef, $mock_builder) = _make_mocks();
	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);

	is($manifest->{builder}, $mock_builder, 'builder is stored');
	ok(!defined $manifest->{file},   'file is undef initially');
	ok(!defined $manifest->{data},   'data is undef initially');
	ok(!defined $manifest->{subset}, 'subset is undef when passed undef');
};

subtest 'new() loads cached file if one exists at _generate_file_name path' => sub {
	my ($mock_env, $mock_builder) = _make_mocks();
	my $wdir = workdir('manifests');

	# Determine the expected file name by hand (type=unredacted, no subset)
	my $cached = sprintf(
		"%s/manifest-%s-%s-%s.yml",
		$wdir,
		$mock_env->name,
		$mock_env->signature,
		'unredacted'
	);
	put_file($cached, "---\nfoo: bar\n");

	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);
	ok($manifest->has_file, 'cached file detected on construction');
	is($manifest->{file}, $cached, 'stored file path matches cached file');

	unlink $cached;
};

# ============================================================================
# Section 2: Accessor Methods
# ============================================================================

subtest 'builder() returns the stored builder mock' => sub {
	my (undef, $mock_builder) = _make_mocks();
	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);
	is($manifest->builder, $mock_builder, 'builder() returns mock builder');
};

subtest 'env() delegates to builder->env' => sub {
	my ($mock_env, $mock_builder) = _make_mocks();
	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);
	is($manifest->env, $mock_env, 'env() returns mock env via builder');
};

subtest 'type() derives snake_case type from class name' => sub {
	my (undef, $mock_builder) = _make_mocks();

	my $u = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);
	is($u->type, 'unredacted', 'Unredacted -> unredacted');

	# Class method form
	is(Genesis::Env::Manifest::Unredacted->type, 'unredacted',
		'type() works as class method on Unredacted');

	# VaultifiedEntombed -> vaultified_entombed
	is(Genesis::Env::Manifest::VaultifiedEntombed->type, 'vaultified_entombed',
		'VaultifiedEntombed -> vaultified_entombed');

	# PartialEnvironment -> partial_environment
	is(Genesis::Env::Manifest::PartialEnvironment->type, 'partial_environment',
		'PartialEnvironment -> partial_environment');

	# Redacted -> redacted
	is(Genesis::Env::Manifest::Redacted->type, 'redacted',
		'Redacted -> redacted');

	# Entombed -> entombed
	is(Genesis::Env::Manifest::Entombed->type, 'entombed',
		'Entombed -> entombed');
};

subtest 'label() converts type to space-separated words' => sub {
	my (undef, $mock_builder) = _make_mocks();

	my $u = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);
	is($u->label, 'unredacted', "'unredacted' label unchanged");

	is(Genesis::Env::Manifest::VaultifiedEntombed->label, 'vaultified entombed',
		"'vaultified_entombed' -> 'vaultified entombed'");

	is(Genesis::Env::Manifest::PartialEnvironment->label, 'partial environment',
		"'partial_environment' -> 'partial environment'");
};

subtest 'subset() returns empty string when subset is undef in constructor' => sub {
	my (undef, $mock_builder) = _make_mocks();
	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);
	is($manifest->subset, '', 'subset() returns empty string when undef');
};

subtest 'subset() returns the subset string when provided' => sub {
	my (undef, $mock_builder) = _make_mocks();
	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, 'mysubset');
	is($manifest->subset, 'mysubset', 'subset() returns provided string');
};

subtest 'deployable() returns 0 for base class, 1 for Unredacted' => sub {
	my (undef, $mock_builder) = _make_mocks();

	# Base class manifest (use Redacted which doesn't override deployable)
	my $r = Genesis::Env::Manifest::Redacted->new($mock_builder, undef);
	is($r->deployable, 0, 'Redacted->deployable returns 0');

	# Unredacted overrides deployable to return 1
	my $u = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);
	is($u->deployable, 1, 'Unredacted->deployable returns 1');
};

subtest 'has_data() returns false initially, true after set_data()' => sub {
	my (undef, $mock_builder) = _make_mocks();
	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);

	ok(!$manifest->has_data, 'has_data() is false initially');
	$manifest->set_data({foo => 'bar'});
	ok($manifest->has_data, 'has_data() is true after set_data()');
};

subtest 'has_file() returns false initially, true after set_file()' => sub {
	my (undef, $mock_builder) = _make_mocks();
	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);

	ok(!$manifest->has_file, 'has_file() is false initially');
	$manifest->set_file('/some/path.yml');
	ok($manifest->has_file, 'has_file() is true after set_file()');
};

subtest 'set_data() stores data and set_file() stores file path' => sub {
	my (undef, $mock_builder) = _make_mocks();
	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);

	my $data = {key => 'value'};
	$manifest->set_data($data);
	is($manifest->{data}, $data, 'set_data() stores the data ref');

	$manifest->set_file('/tmp/manifest.yml');
	is($manifest->{file}, '/tmp/manifest.yml', 'set_file() stores the path');
};

subtest 'is_subset() returns true when subset defined, false when undef' => sub {
	my (undef, $mock_builder) = _make_mocks();

	my $no_subset = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);
	ok(!$no_subset->is_subset, 'is_subset() is false when subset is undef');

	my $with_subset = Genesis::Env::Manifest::Unredacted->new($mock_builder, 'partial');
	ok($with_subset->is_subset, 'is_subset() is true when subset is defined');

	# Even empty string counts as a defined subset
	my $empty_subset = Genesis::Env::Manifest::Unredacted->new($mock_builder, '');
	ok($empty_subset->is_subset, 'is_subset() is true when subset is empty string');
};

subtest 'manifest_lookup_target() returns $self for Unredacted' => sub {
	my (undef, $mock_builder) = _make_mocks();
	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);
	is($manifest->manifest_lookup_target, $manifest,
		'manifest_lookup_target() returns self');
};

# ============================================================================
# Section 3: Notification System
# ============================================================================

subtest 'has_notice() returns false initially' => sub {
	my (undef, $mock_builder) = _make_mocks();
	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);
	ok(!$manifest->has_notice, 'has_notice() is false before any notify()');
};

subtest 'notify() with no arg generates default notice containing label' => sub {
	my (undef, $mock_builder) = _make_mocks();
	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);

	$manifest->notify;
	ok($manifest->has_notice, 'has_notice() true after notify()');
	like($manifest->get_build_notice, qr/unredacted/,
		'default notice contains type label');
};

subtest 'notify() with custom message stores that message' => sub {
	my (undef, $mock_builder) = _make_mocks();
	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);

	$manifest->notify('my custom notice');
	is($manifest->get_build_notice, 'my custom notice',
		'get_build_notice() returns the custom message');
};

subtest 'has_notice() returns true after notify(), get_build_notice() returns notice' => sub {
	my (undef, $mock_builder) = _make_mocks();
	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);

	$manifest->notify('test notice');
	ok($manifest->has_notice, 'has_notice() true after notify()');
	is($manifest->get_build_notice, 'test notice',
		'get_build_notice() returns stored notice');
};

# ============================================================================
# Section 4: Reset
# ============================================================================

subtest 'reset() clears data and file, returns $self for chaining' => sub {
	my (undef, $mock_builder) = _make_mocks();
	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);

	$manifest->set_data({foo => 1});
	$manifest->set_file('/tmp/test.yml');
	ok($manifest->has_data, 'has_data() true before reset');
	ok($manifest->has_file, 'has_file() true before reset');

	my $ret = $manifest->reset;

	ok(!$manifest->has_data, 'has_data() false after reset()');
	ok(!$manifest->has_file, 'has_file() false after reset()');
	is($ret, $manifest, 'reset() returns $self for chaining');
};

# ============================================================================
# Section 5: File Generation (_generate_file_name)
# ============================================================================

subtest '_generate_file_name produces correct format' => sub {
	my ($mock_env, $mock_builder) = _make_mocks();
	my $wdir = workdir('manifests');

	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);
	my $expected = "$wdir/manifest-test-env-abc123-unredacted.yml";
	is($manifest->_generate_file_name, $expected,
		'_generate_file_name produces expected path');
};

subtest '_generate_file_name with transient flag' => sub {
	my ($mock_env, $mock_builder) = _make_mocks();
	my $wdir = workdir('manifests');

	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);
	my $expected = "$wdir/transient-manifest-test-env-abc123-unredacted.yml";
	is($manifest->_generate_file_name(1), $expected,
		'_generate_file_name with transient flag prefixes "transient-"');
};

subtest '_generate_file_name with subset' => sub {
	my ($mock_env, $mock_builder) = _make_mocks();
	my $wdir = workdir('manifests');

	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, 'mysub');
	my $expected = "$wdir/manifest-test-env-abc123-unredacted-mysub.yml";
	is($manifest->_generate_file_name, $expected,
		'_generate_file_name appends subset suffix');
};

# ============================================================================
# Section 6: Validate
# ============================================================================

subtest 'validate() returns 1 on successful data build' => sub {
	my ($mock_env, undef) = _make_mocks();

	my $mock_data_manifest = Mock->new(
		data => sub { {name => 'test'} },
	);
	my $mock_builder = Mock->new(
		env         => $mock_env,
		vault_paths => sub { {} },
		unredacted  => $mock_data_manifest,
	);

	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);
	my $result = $manifest->validate;
	is($result, 1, 'validate() returns 1 when builder type accessor succeeds');
};

subtest 'validate() returns 0 and does not die on failure' => sub {
	my ($mock_env, undef) = _make_mocks();

	my $mock_builder = Mock->new(
		env         => $mock_env,
		vault_paths => sub { {} },
		unredacted  => sub { die "merge failed\n" },
	);

	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);
	my $result;
	lives_ok { $result = $manifest->validate } 'validate() does not propagate exception';
	is($result, 0, 'validate() returns 0 on failure');
};

# ============================================================================
# Section 7: Utility - dewrap
# ============================================================================

subtest 'dewrap() returns unchanged string when no ANSI label found' => sub {
	my $msg = "simple error message without label";
	is(Genesis::Env::Manifest::dewrap($msg), $msg,
		'dewrap() returns input unchanged when no ANSI label present');
};

subtest 'dewrap() strips ANSI label and normalizes indentation' => sub {
	# Build a string that matches the pattern: ANSI-code [LABEL] ANSI-reset message
	# Pattern: \s*\[[0-9;]+m(\[[A-Z]+\])\[0m
	my $label   = '[ERROR]';
	my $ansi_on = "\e[31m";
	my $ansi_off = "\e[0m";
	my $indent  = ' ' x (length($label) + 1);  # 8 spaces

	my $msg = "${ansi_on}${label}${ansi_off} first line\n${indent}continuation line\n${indent}";
	my $result = Genesis::Env::Manifest::dewrap($msg);

	unlike($result, qr/\Q$label\E/, 'label is stripped from result');
	like($result, qr/first line/, 'first line content preserved');
};

# ============================================================================
# Section 8: Abstract _merge
# ============================================================================

subtest '_merge() on base class dies with bug error' => sub {
	my (undef, $mock_builder) = _make_mocks();

	# Bless directly as the base class to test its _merge
	my $manifest = bless({
		builder => $mock_builder,
		subset  => undef,
		file    => undef,
		data    => undef,
	}, 'Genesis::Env::Manifest');

	dies_ok { $manifest->_merge } '_merge() on base Genesis::Env::Manifest dies';
};

# ============================================================================
# Section 9: redacted (base class and Entombed)
# ============================================================================

subtest 'redacted() on base class dies with Not implemented error' => sub {
	my (undef, $mock_builder) = _make_mocks();

	# Bless directly as the base class
	my $manifest = bless({
		builder => $mock_builder,
		subset  => undef,
		file    => undef,
		data    => undef,
	}, 'Genesis::Env::Manifest');

	dies_ok { $manifest->redacted } 'redacted() on base class dies';
};

subtest 'redacted() on Entombed returns $self' => sub {
	my (undef, $mock_builder) = _make_mocks();
	my $manifest = Genesis::Env::Manifest::Entombed->new($mock_builder, undef);
	my $result = $manifest->redacted;
	is($result, $manifest, 'Entombed->redacted() returns $self');
};

# ============================================================================
# Section 10: get_vault_paths
# ============================================================================

subtest 'get_vault_paths delegates to builder->vault_paths' => sub {
	my ($mock_env, undef) = _make_mocks();

	my $expected_paths = {
		'secret/test/env/key' => 'value',
	};
	my $mock_builder = Mock->new(
		env         => $mock_env,
		vault_paths => sub { $expected_paths },
	);

	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);
	my $result = $manifest->get_vault_paths;
	is($result, $expected_paths, 'get_vault_paths() returns builder->vault_paths result');
};

# ============================================================================
# Section 11: data() and file() Memoized Accessors
# ============================================================================

subtest 'data() returns pre-set data via memoization' => sub {
	my (undef, $mock_builder) = _make_mocks();
	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);

	my $data = {name => 'test-deployment', instance_groups => []};
	$manifest->set_data($data);
	is($manifest->data, $data, 'data() returns pre-set data without triggering merge');
};

subtest 'data() is memoized - second call returns same reference' => sub {
	my (undef, $mock_builder) = _make_mocks();
	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);

	my $data = {name => 'memoize-test'};
	$manifest->set_data($data);

	my $first  = $manifest->data;
	my $second = $manifest->data;
	is($first, $second, 'data() returns same reference on repeated calls');
};

subtest 'file() returns pre-set file via memoization' => sub {
	my (undef, $mock_builder) = _make_mocks();
	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);

	my $path = workdir('manifests') . '/test-manifest.yml';
	$manifest->set_file($path);
	is($manifest->file, $path, 'file() returns pre-set file path without triggering merge');
};

subtest 'file() is memoized - second call returns same value' => sub {
	my (undef, $mock_builder) = _make_mocks();
	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);

	my $path = '/tmp/memo-file-test.yml';
	$manifest->set_file($path);

	my $first  = $manifest->file;
	my $second = $manifest->file;
	is($first, $second, 'file() returns same value on repeated calls');
};

subtest 'data() for subset manifest delegates to builder->get_subset' => sub {
	my ($mock_env, undef) = _make_mocks();

	my $subset_data = {releases => [{name => 'test-release', version => '1.0'}]};
	# Use Mock::ReferencedValue for list returns (coderef returns are scalar context in Mock)
	my $mock_builder = Mock->new(
		env         => $mock_env,
		vault_paths => sub { {} },
		get_subset  => Mock::ReferencedValue->new([$subset_data, undef]),
	);

	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, 'releases');
	ok($manifest->is_subset, 'manifest is a subset');

	my $result = $manifest->data;
	is_deeply($result, $subset_data, 'data() for subset delegates to builder->get_subset');
};

subtest 'file() for subset manifest delegates to builder->get_subset' => sub {
	my ($mock_env, undef) = _make_mocks();

	my $fake_file = workdir('manifests') . '/subset-output.yml';
	# Use Mock::ReferencedValue for list returns (coderef returns are scalar context in Mock)
	my $mock_builder = Mock->new(
		env         => $mock_env,
		vault_paths => sub { {} },
		get_subset  => Mock::ReferencedValue->new([undef, $fake_file]),
	);

	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, 'pruned');
	my $result = $manifest->file;
	is($result, $fake_file, 'file() for subset delegates to builder->get_subset');
};

# ============================================================================
# Section 12: write_to()
# ============================================================================

subtest 'write_to() copies manifest file to destination' => sub {
	my (undef, $mock_builder) = _make_mocks();
	my $manifest = Genesis::Env::Manifest::Unredacted->new($mock_builder, undef);

	my $src  = workdir('manifests') . '/write-to-src.yml';
	my $dest = workdir('manifests') . '/write-to-dest.yml';
	put_file($src, "---\nfoo: bar\n");
	$manifest->set_file($src);

	$manifest->write_to($dest);
	ok(-f $dest, 'destination file exists after write_to()');
	is(get_file($dest), "---\nfoo: bar\n", 'destination file has correct content');

	unlink $src, $dest;
};

# ============================================================================
# Section 13: deployable() on Additional Subclasses
# ============================================================================

subtest 'deployable() returns 1 for all deployable subclasses' => sub {
	my (undef, $mock_builder) = _make_mocks();

	my $entombed = Genesis::Env::Manifest::Entombed->new($mock_builder, undef);
	is($entombed->deployable, 1, 'Entombed->deployable returns 1');

	my $vaultified = Genesis::Env::Manifest::Vaultified->new($mock_builder, undef);
	is($vaultified->deployable, 1, 'Vaultified->deployable returns 1');

	my $ve = Genesis::Env::Manifest::VaultifiedEntombed->new($mock_builder, undef);
	is($ve->deployable, 1, 'VaultifiedEntombed->deployable returns 1');
};

done_testing;
