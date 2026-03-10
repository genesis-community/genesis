#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::Deep;

# Test Genesis::Secret::DHParams class
# DHParams secrets generate Diffie-Hellman key exchange parameters

use_ok 'Genesis::Secret::DHParams';

subtest 'constructor validation - valid definitions' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# Minimal valid definition
	my $simple = Genesis::Secret::DHParams->new('path:key', size => 2048);
	isa_ok($simple, 'Genesis::Secret::DHParams');
	is($simple->get('size'), 2048, "size is stored");

	# With fixed flag
	my $fixed = Genesis::Secret::DHParams->new('path:key',
		size => 4096,
		fixed => 1
	);
	isa_ok($fixed, 'Genesis::Secret::DHParams');
	is($fixed->get('fixed'), 1, "fixed stored");
};

subtest 'constructor validation - error cases' => sub {
	# Missing size - should return Invalid
	my $no_size = Genesis::Secret->build('dhparams', 'kit', 'path:key');
	isa_ok($no_size, 'Genesis::Secret::Invalid', "missing size returns Invalid");

	# Invalid option - should return Invalid
	my $bad_opt = Genesis::Secret->build('dhparams', 'kit', 'path:key',
		size => 2048, unknown_option => 'value'
	);
	isa_ok($bad_opt, 'Genesis::Secret::Invalid', "unknown option returns Invalid");
};

subtest 'type and label' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::DHParams->new('path:key', size => 2048);
	is($secret->type, 'dhparams', "type() returns 'dhparams'");
	is($secret->label, 'Diffie-Hellman parameters', "label() returns 'Diffie-Hellman parameters'");
};

subtest 'describe()' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::DHParams->new('path:key',
		size => 2048, fixed => 1
	);

	my $desc = $secret->describe;
	like($desc, qr/Diffie-Hellman/i, "describe includes Diffie-Hellman");
	like($desc, qr/2048.*bits/i, "describe includes size in bits");
	like($desc, qr/fixed/i, "describe includes fixed flag");

	# List context
	my @parts = $secret->describe;
	is($parts[0], 'path:key', "list context: first is path");
	like($parts[1], qr/Diffie-Hellman/i, "list context: second is description");
};

subtest 'describe() without fixed' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::DHParams->new('path:key', size => 4096);

	my $desc = $secret->describe;
	like($desc, qr/4096.*bits/i, "describe includes size");
	unlike($desc, qr/fixed/i, "describe does not include fixed when not set");
};

subtest '_required_value_keys' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::DHParams->new('path:key', size => 2048);
	my @keys = $secret->_required_value_keys;
	cmp_deeply(\@keys, ['dhparam-pem'], "_required_value_keys returns dhparam-pem");
};

subtest 'check_value for missing value' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::DHParams->new('path:key', size => 2048);

	# No value set
	my ($status) = $secret->check_value;
	is($status, 'missing', "check_value returns 'missing' for empty secret");

	# Value set but missing required key
	$secret->set_value({other_key => 'value'}, in_sync => 1);
	($status, my $msg) = $secret->check_value;
	is($status, 'missing', "check_value returns 'missing' when dhparam-pem is missing");
	like($msg, qr/dhparam-pem/, "message mentions missing key");
};

subtest 'check_value with required key present' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::DHParams->new('path:key', size => 2048);

	# Set value with required key
	$secret->set_value({'dhparam-pem' => 'fake-pem-data'}, in_sync => 1);
	my ($status) = $secret->check_value;
	is($status, 'ok', "check_value returns 'ok' when dhparam-pem is present");
};

subtest 'process_command_output for add' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::DHParams->new('path:key', size => 2048);

	# Normal DH generation output should be suppressed
	my $dh_output = "Generating DH parameters, 2048 bit long safe prime, generator 2\nThis is going to take a long time\n......+.......++*++*";
	my ($out, $rc, $err) = $secret->process_command_output('add', $dh_output, 0, '');
	is($out, '', "DH generation progress output suppressed for add");
	is($rc, 0, "return code preserved");

	# Non-matching output should be preserved
	my $other_output = "Some other output";
	($out, $rc, $err) = $secret->process_command_output('add', $other_output, 0, '');
	is($out, $other_output, "non-DH output preserved");
};

subtest 'process_command_output for non-add actions' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::DHParams->new('path:key', size => 2048);

	# For rotate, output should not be suppressed
	my $dh_output = "Generating DH parameters, 2048 bit long safe prime, generator 2\n++*++*";
	my ($out, $rc, $err) = $secret->process_command_output('rotate', $dh_output, 0, '');
	is($out, $dh_output, "output not suppressed for rotate");
};

subtest 'inherits base class functionality' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::DHParams->new('test/path:key',
		size => 2048,
		_feature => 'dh-feature'
	);

	# Path accessor
	is($secret->path, 'test/path:key', "path() works");

	# Source tracking
	is($secret->source, 'kit', "source() works");
	ok($secret->from_kit, "from_kit() works");
	is($secret->feature, 'dh-feature', "feature() works");

	# Definition accessors
	ok($secret->has('size'), "has() works");
	is($secret->get('size'), 2048, "get() works");
};

done_testing;
