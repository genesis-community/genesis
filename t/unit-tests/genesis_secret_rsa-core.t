#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::Deep;

# Test Genesis::Secret::RSA class
# RSA secrets generate RSA public/private key pairs

use_ok 'Genesis::Secret::RSA';

subtest 'constructor validation - valid definitions' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# Minimal valid definition
	my $simple = Genesis::Secret::RSA->new('path:key', size => 2048);
	isa_ok($simple, 'Genesis::Secret::RSA');
	is($simple->get('size'), 2048, "size is stored");

	# With fixed flag
	my $fixed = Genesis::Secret::RSA->new('path:key',
		size => 4096,
		fixed => 1
	);
	isa_ok($fixed, 'Genesis::Secret::RSA');
	is($fixed->get('fixed'), 1, "fixed stored");
};

subtest 'constructor validation - error cases' => sub {
	# Missing size - should return Invalid
	my $no_size = Genesis::Secret->build('rsa', 'kit', 'path:key');
	isa_ok($no_size, 'Genesis::Secret::Invalid', "missing size returns Invalid");

	# Invalid option - should return Invalid
	my $bad_opt = Genesis::Secret->build('rsa', 'kit', 'path:key',
		size => 2048, unknown_option => 'value'
	);
	isa_ok($bad_opt, 'Genesis::Secret::Invalid', "unknown option returns Invalid");
};

subtest 'type and label' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::RSA->new('path:key', size => 2048);
	is($secret->type, 'rsa', "type() returns 'rsa'");
	is($secret->label, 'RSA key pair', "label() returns 'RSA key pair'");
};

subtest 'describe()' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::RSA->new('path:key',
		size => 2048, fixed => 1
	);

	my $desc = $secret->describe;
	like($desc, qr/RSA.*keypair/i, "describe includes RSA keypair");
	like($desc, qr/2048.*bits/i, "describe includes size in bits");
	like($desc, qr/fixed/i, "describe includes fixed flag");

	# List context
	my @parts = $secret->describe;
	is($parts[0], 'path:key', "list context: first is path");
	like($parts[1], qr/RSA/i, "list context: second is description");
};

subtest 'describe() without fixed' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::RSA->new('path:key', size => 4096);

	my $desc = $secret->describe;
	like($desc, qr/4096.*bits/i, "describe includes size");
	unlike($desc, qr/fixed/i, "describe does not include fixed when not set");
};

subtest 'vault_operator with specific keys' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::RSA->new('my/secret', size => 2048);

	# Public key variants
	my $pub_op = $secret->vault_operator('public');
	like($pub_op, qr/vault/, "public vault_operator contains 'vault'");
	like($pub_op, qr/my\/secret:public/, "public vault_operator has :public");

	my $pub_key_op = $secret->vault_operator('public_key');
	like($pub_key_op, qr/my\/secret:public/, "public_key vault_operator has :public");

	# Private key variants
	my $priv_op = $secret->vault_operator('private');
	like($priv_op, qr/my\/secret:private/, "private vault_operator has :private");

	my $priv_key_op = $secret->vault_operator('private_key');
	like($priv_key_op, qr/my\/secret:private/, "private_key vault_operator has :private");
};

subtest 'vault_operator without key returns hash' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::RSA->new('my/secret', size => 2048);

	my $ops = $secret->vault_operator;
	is(ref($ops), 'HASH', "vault_operator() without key returns hash");
	ok(exists $ops->{public_key}, "hash has public_key");
	ok(exists $ops->{private_key}, "hash has private_key");
	like($ops->{public_key}, qr/:public/, "public_key operator correct");
	like($ops->{private_key}, qr/:private/, "private_key operator correct");
};

subtest 'vault_operator with invalid key dies' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::RSA->new('my/secret', size => 2048);

	my $error;
	eval {
		$secret->vault_operator('invalid_key');
	};
	$error = $@;

	ok($error, "vault_operator with invalid key dies");
	like($error, qr/Invalid key/i, "error mentions invalid key");
};

subtest '_required_value_keys' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::RSA->new('path:key', size => 2048);
	my @keys = $secret->_required_value_keys;
	cmp_deeply([sort @keys], [sort qw/private public/], "_required_value_keys returns private and public");
};

subtest 'check_value for missing value' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::RSA->new('path:key', size => 2048);

	# No value set
	my ($status) = $secret->check_value;
	is($status, 'missing', "check_value returns 'missing' for empty secret");

	# Value set but missing required keys
	$secret->set_value({private => 'key'}, in_sync => 1);
	($status, my $msg) = $secret->check_value;
	is($status, 'missing', "check_value returns 'missing' when public is missing");
	like($msg, qr/public/, "message mentions missing public key");
};

subtest 'check_value with all required keys' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::RSA->new('path:key', size => 2048);

	$secret->set_value({private => 'priv-key', public => 'pub-key'}, in_sync => 1);
	my ($status) = $secret->check_value;
	is($status, 'ok', "check_value returns 'ok' when both keys present");
};

subtest 'inherits base class functionality' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::RSA->new('test/path:key',
		size => 2048,
		_feature => 'rsa-feature'
	);

	# Path accessor
	is($secret->path, 'test/path:key', "path() works");

	# Source tracking
	is($secret->source, 'kit', "source() works");
	ok($secret->from_kit, "from_kit() works");
	is($secret->feature, 'rsa-feature', "feature() works");

	# Definition accessors
	ok($secret->has('size'), "has() works");
	is($secret->get('size'), 2048, "get() works");
};

done_testing;
