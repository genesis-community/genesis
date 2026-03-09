#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::Deep;

# Test Genesis::Secret::SSH class
# SSH secrets generate SSH public/private key pairs with fingerprint
#
# Key characteristics of SSH secrets:
# - Required 'size' parameter with strict range validation (1024-16384 bits)
# - Stores three values: private key, public key, and fingerprint
# - vault_operator supports multiple key aliases (public, public_key, etc.)

use_ok 'Genesis::Secret::SSH';

# ------------------------------------------------------------------------------
# Constructor validation tests verify that _validate_constructor_opts correctly
# enforces the SSH-specific size constraints (1024-16384 bits) and rejects
# invalid configurations before they cause problems downstream.
# ------------------------------------------------------------------------------

subtest 'constructor validation - valid definitions' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# Minimal valid definition - just size is required
	my $simple = Genesis::Secret::SSH->new('path:key', size => 2048);
	isa_ok($simple, 'Genesis::Secret::SSH');
	is($simple->get('size'), 2048, "size is stored");

	# With fixed flag - prevents rotation
	my $fixed = Genesis::Secret::SSH->new('path:key',
		size => 4096,
		fixed => 1
	);
	isa_ok($fixed, 'Genesis::Secret::SSH');
	is($fixed->get('fixed'), 1, "fixed stored");

	# Boundary sizes - SSH enforces 1024-16384 range unlike RSA/DHParams
	my $min_size = Genesis::Secret::SSH->new('path:key', size => 1024);
	isa_ok($min_size, 'Genesis::Secret::SSH');
	is($min_size->get('size'), 1024, "minimum size 1024 accepted");

	my $max_size = Genesis::Secret::SSH->new('path:key', size => 16384);
	isa_ok($max_size, 'Genesis::Secret::SSH');
	is($max_size->get('size'), 16384, "maximum size 16384 accepted");
};

subtest 'constructor validation - error cases' => sub {
	# These tests verify the custom _validate_constructor_opts in SSH.pm
	# which has stricter size validation than other key types

	# Missing size - should return Invalid
	my $no_size = Genesis::Secret->build('ssh', 'kit', 'path:key');
	isa_ok($no_size, 'Genesis::Secret::Invalid', "missing size returns Invalid");

	# Size too small - SSH minimum is 1024 bits for security
	my $too_small = Genesis::Secret->build('ssh', 'kit', 'path:key', size => 512);
	isa_ok($too_small, 'Genesis::Secret::Invalid', "size < 1024 returns Invalid");

	# Size too large - SSH maximum is 16384 bits
	my $too_large = Genesis::Secret->build('ssh', 'kit', 'path:key', size => 32768);
	isa_ok($too_large, 'Genesis::Secret::Invalid', "size > 16384 returns Invalid");

	# Non-numeric size - caught by regex validation in _validate_constructor_opts
	my $bad_size = Genesis::Secret->build('ssh', 'kit', 'path:key', size => 'large');
	isa_ok($bad_size, 'Genesis::Secret::Invalid', "non-numeric size returns Invalid");

	# Unknown options rejected to catch typos in kit definitions
	my $bad_opt = Genesis::Secret->build('ssh', 'kit', 'path:key',
		size => 2048, unknown_option => 'value'
	);
	isa_ok($bad_opt, 'Genesis::Secret::Invalid', "unknown option returns Invalid");
};

# ------------------------------------------------------------------------------
# Type and label tests ensure the class correctly identifies itself for
# logging, error messages, and the describe() output shown to users.
# ------------------------------------------------------------------------------

subtest 'type and label' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::SSH->new('path:key', size => 2048);
	is($secret->type, 'ssh', "type() returns 'ssh'");
	is($secret->label, 'SSH key pair', "label() returns 'SSH key pair'");
};

# ------------------------------------------------------------------------------
# describe() is used by `genesis check` and other commands to show users
# human-readable information about their secret definitions.
# ------------------------------------------------------------------------------

subtest 'describe()' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::SSH->new('path:key',
		size => 2048, fixed => 1
	);

	# Scalar context - full description string
	my $desc = $secret->describe;
	like($desc, qr/SSH.*keypair/i, "describe includes SSH keypair");
	like($desc, qr/2048.*bits/i, "describe includes size in bits");
	like($desc, qr/fixed/i, "describe includes fixed flag");

	# List context - returns (path, label, features) for tabular display
	my @parts = $secret->describe;
	is($parts[0], 'path:key', "list context: first is path");
	like($parts[1], qr/SSH/i, "list context: second is description");
};

subtest 'describe() without fixed' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# Verify 'fixed' only appears when explicitly set
	my $secret = Genesis::Secret::SSH->new('path:key', size => 4096);

	my $desc = $secret->describe;
	like($desc, qr/4096.*bits/i, "describe includes size");
	unlike($desc, qr/fixed/i, "describe does not include fixed when not set");
};

# ------------------------------------------------------------------------------
# vault_operator() generates the (( vault ... )) spruce operator strings used
# in manifests. SSH keys have three components (public, private, fingerprint)
# and support multiple aliases for each (e.g., 'public' and 'public_key').
# ------------------------------------------------------------------------------

subtest 'vault_operator with specific keys' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::SSH->new('my/secret', size => 2048);

	# Public key - accepts 'public' or 'public_key' aliases
	my $pub_op = $secret->vault_operator('public');
	like($pub_op, qr/vault/, "public vault_operator contains 'vault'");
	like($pub_op, qr/my\/secret:public/, "public vault_operator has :public");

	my $pub_key_op = $secret->vault_operator('public_key');
	like($pub_key_op, qr/my\/secret:public/, "public_key vault_operator has :public");

	# Private key - accepts 'private' or 'private_key' aliases
	my $priv_op = $secret->vault_operator('private');
	like($priv_op, qr/my\/secret:private/, "private vault_operator has :private");

	my $priv_key_op = $secret->vault_operator('private_key');
	like($priv_key_op, qr/my\/secret:private/, "private_key vault_operator has :private");

	# Fingerprint - accepts 'fingerprint' or 'public_key_fingerprint' aliases
	my $fp_op = $secret->vault_operator('fingerprint');
	like($fp_op, qr/my\/secret:fingerprint/, "fingerprint vault_operator has :fingerprint");

	my $pk_fp_op = $secret->vault_operator('public_key_fingerprint');
	like($pk_fp_op, qr/my\/secret:fingerprint/, "public_key_fingerprint vault_operator has :fingerprint");
};

subtest 'vault_operator without key returns hash' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# When called without a key argument, returns hash of all available operators
	# This is used when generating manifest snippets that need all key parts
	my $secret = Genesis::Secret::SSH->new('my/secret', size => 2048);

	my $ops = $secret->vault_operator;
	is(ref($ops), 'HASH', "vault_operator() without key returns hash");
	ok(exists $ops->{public_key}, "hash has public_key");
	ok(exists $ops->{private_key}, "hash has private_key");
	ok(exists $ops->{public_key_fingerprint}, "hash has public_key_fingerprint");
	like($ops->{public_key}, qr/:public/, "public_key operator correct");
	like($ops->{private_key}, qr/:private/, "private_key operator correct");
	like($ops->{public_key_fingerprint}, qr/:fingerprint/, "public_key_fingerprint operator correct");
};

subtest 'vault_operator with invalid key dies' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# Invalid key names should bug() to catch typos in kit code
	my $secret = Genesis::Secret::SSH->new('my/secret', size => 2048);

	my $error;
	eval {
		$secret->vault_operator('invalid_key');
	};
	$error = $@;

	ok($error, "vault_operator with invalid key dies");
	like($error, qr/Invalid key/i, "error mentions invalid key");
};

# ------------------------------------------------------------------------------
# _required_value_keys defines what keys must be present in vault for the
# secret to be considered "present". SSH needs all three: private, public,
# and fingerprint.
# ------------------------------------------------------------------------------

subtest '_required_value_keys' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::SSH->new('path:key', size => 2048);
	my @keys = $secret->_required_value_keys;
	cmp_deeply([sort @keys], [sort qw/private public fingerprint/],
		"_required_value_keys returns private, public, and fingerprint");
};

# ------------------------------------------------------------------------------
# check_value() is called by `genesis check` to verify secrets exist in vault.
# It uses _required_value_keys to determine what must be present.
# ------------------------------------------------------------------------------

subtest 'check_value for missing value' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::SSH->new('path:key', size => 2048);

	# No value set at all
	my ($status) = $secret->check_value;
	is($status, 'missing', "check_value returns 'missing' for empty secret");

	# Partial value - missing fingerprint (common migration issue)
	$secret->set_value({private => 'key', public => 'key'}, in_sync => 1);
	($status, my $msg) = $secret->check_value;
	is($status, 'missing', "check_value returns 'missing' when fingerprint is missing");
	like($msg, qr/fingerprint/, "message mentions missing fingerprint key");
};

subtest 'check_value with all required keys' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::SSH->new('path:key', size => 2048);

	# All three keys present - should pass
	$secret->set_value({
		private => 'priv-key',
		public => 'pub-key',
		fingerprint => 'fp'
	}, in_sync => 1);
	my ($status) = $secret->check_value;
	is($status, 'ok', "check_value returns 'ok' when all keys present");
};

# ------------------------------------------------------------------------------
# Verify SSH properly inherits base class functionality for path handling,
# source tracking (kit vs manifest), and definition accessors.
# ------------------------------------------------------------------------------

subtest 'inherits base class functionality' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::SSH->new('test/path:key',
		size => 2048,
		_feature => 'ssh-feature'
	);

	# Path accessor
	is($secret->path, 'test/path:key', "path() works");

	# Source tracking - _feature indicates this came from kit.yml
	is($secret->source, 'kit', "source() works");
	ok($secret->from_kit, "from_kit() works");
	is($secret->feature, 'ssh-feature', "feature() works");

	# Definition accessors for inspecting configuration
	ok($secret->has('size'), "has() works");
	is($secret->get('size'), 2048, "get() works");
};

done_testing;
