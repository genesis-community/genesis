#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::Deep;

# Test Genesis::Secret::Random class
# Random secrets generate random strings with configurable size and character sets

use_ok 'Genesis::Secret::Random';

subtest 'constructor validation - valid definitions' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# Minimal valid definition
	my $simple = Genesis::Secret::Random->new('path:key', size => 32);
	isa_ok($simple, 'Genesis::Secret::Random');
	is($simple->get('size'), 32, "size is stored");

	# With all optional fields
	my $full = Genesis::Secret::Random->new('path:key',
		size => 16,
		valid_chars => 'abc123',
		format => 'base64',
		destination => 'formatted-key',
		fixed => 1
	);
	isa_ok($full, 'Genesis::Secret::Random');
	is($full->get('valid_chars'), 'abc123', "valid_chars stored");
	is($full->get('format'), 'base64', "format stored");
	is($full->get('destination'), 'formatted-key', "destination stored");
	is($full->get('fixed'), 1, "fixed stored as true");
};

subtest 'constructor validation - error cases' => sub {
	# Missing size - should return Invalid
	my $no_size = Genesis::Secret->build('random', 'kit', 'path:key');
	isa_ok($no_size, 'Genesis::Secret::Invalid', "missing size returns Invalid");

	# Size of 0 - should return Invalid
	my $zero_size = Genesis::Secret->build('random', 'kit', 'path:key', size => 0);
	isa_ok($zero_size, 'Genesis::Secret::Invalid', "size=0 returns Invalid");

	# Invalid option - should return Invalid
	my $bad_opt = Genesis::Secret->build('random', 'kit', 'path:key',
		size => 32, unknown_option => 'value'
	);
	isa_ok($bad_opt, 'Genesis::Secret::Invalid', "unknown option returns Invalid");
};

subtest 'fixed flag normalization' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# fixed => 1 stays truthy
	my $fixed_true = Genesis::Secret::Random->new('path:key', size => 8, fixed => 1);
	ok($fixed_true->get('fixed'), "fixed => 1 is truthy");

	# fixed => 0 stays falsy
	my $fixed_false = Genesis::Secret::Random->new('path:key', size => 8, fixed => 0);
	ok(!$fixed_false->get('fixed'), "fixed => 0 is falsy");

	# Absent fixed defaults to falsy
	my $no_fixed = Genesis::Secret::Random->new('path:key', size => 8);
	ok(!$no_fixed->get('fixed'), "absent fixed is falsy");
};

subtest 'type and label' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::Random->new('path:key', size => 8);
	is($secret->type, 'random', "type() returns 'random'");
	is($secret->label, 'Random', "label() returns 'Random'");
};

subtest 'default_key' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::Random->new('path:key', size => 8);
	is($secret->default_key, 'value', "default_key() returns 'value'");
};

subtest 'format_key and format_path' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# No format - no format_key/format_path
	my $no_format = Genesis::Secret::Random->new('secret/path:mykey', size => 8);
	is($no_format->format_key, undef, "format_key is undef without format");
	is($no_format->format_path, undef, "format_path is undef without format");

	# With format, default destination
	my $with_format = Genesis::Secret::Random->new('secret/path:mykey',
		size => 8, format => 'base64'
	);
	is($with_format->format_key, 'mykey-base64', "format_key uses key-format pattern");
	is($with_format->format_path, 'secret/path:mykey-base64', "format_path combines path and format_key");

	# With format and custom destination
	my $custom_dest = Genesis::Secret::Random->new('secret/path:mykey',
		size => 8, format => 'bcrypt', destination => 'hashed'
	);
	is($custom_dest->format_key, 'hashed', "format_key uses custom destination");
	is($custom_dest->format_path, 'secret/path:hashed', "format_path uses custom destination");
};

subtest 'all_paths includes format_path' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# Without format
	my $simple = Genesis::Secret::Random->new('path:key', size => 8);
	my @paths = $simple->all_paths;
	cmp_deeply(\@paths, ['path:key'], "all_paths returns single path without format");

	# With format
	my $formatted = Genesis::Secret::Random->new('path:key',
		size => 8, format => 'base64'
	);
	@paths = $formatted->all_paths;
	cmp_deeply(\@paths, ['path:key', 'path:key-base64'],
		"all_paths includes format_path when format specified");
};

subtest 'format_value accessors' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::Random->new('path:key', size => 8, format => 'base64');

	# Initially no format value
	ok(!$secret->has_format_value, "has_format_value false initially");
	is($secret->format_value, undef, "format_value undef initially");

	# Set format value (pending)
	$secret->set_format_value('encoded_value');
	ok($secret->has_format_value, "has_format_value true after set");
	is($secret->format_value, 'encoded_value', "format_value returns pending value");

	# Set format value in_sync (stored)
	$secret->set_format_value('stored_encoded', in_sync => 1);
	ok($secret->has_format_value, "has_format_value true for stored");
	is($secret->format_value, 'stored_encoded', "format_value returns stored value");

	# Pending takes precedence
	$secret->set_format_value('new_pending');
	is($secret->format_value, 'new_pending', "pending format_value takes precedence");
};

subtest 'reset clears format_value' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::Random->new('path:key', size => 8, format => 'base64');
	$secret->set_value('test_value', in_sync => 1, loaded => 1);
	$secret->set_format_value('encoded', in_sync => 1);

	ok($secret->has_value, "has_value before reset");
	ok($secret->has_format_value, "has_format_value before reset");
	is($secret->loaded, 1, "loaded before reset");

	$secret->reset;

	ok(!$secret->has_value, "has_value false after reset");
	ok(!$secret->has_format_value, "has_format_value false after reset");
	is($secret->loaded, 0, "loaded is 0 after reset");
};

subtest 'promote_value_to_stored includes format_value' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::Random->new('path:key', size => 8, format => 'base64');
	$secret->set_value('pending_val');
	$secret->set_format_value('pending_fmt');

	is($secret->{value}, 'pending_val', "value in pending state");
	is($secret->{format_value}, 'pending_fmt', "format_value in pending state");

	$secret->promote_value_to_stored;

	ok(!exists $secret->{value}, "pending value cleared");
	ok(!exists $secret->{format_value}, "pending format_value cleared");
	is($secret->{stored_value}, 'pending_val', "value moved to stored");
	is($secret->{stored_format_value}, 'pending_fmt', "format_value moved to stored");
	is($secret->loaded, 1, "marked as loaded");
};

subtest 'check_value - basic presence' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::Random->new('path:key', size => 8);

	# No value
	my ($status) = $secret->check_value;
	is($status, 'missing', "check_value returns 'missing' without value");

	# With value
	$secret->set_value('test123', in_sync => 1);
	($status) = $secret->check_value;
	is($status, 'ok', "check_value returns 'ok' with value");
};

subtest 'check_value - format_value presence' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::Random->new('path:key', size => 8, format => 'base64');

	# Value but no format_value
	$secret->set_value('test123', in_sync => 1);
	my ($status, $msg) = $secret->check_value;
	is($status, 'missing', "missing format_value returns 'missing'");
	like($msg, qr/base64.*formatted/i, "message mentions format type");

	# Both value and format_value
	$secret->set_format_value('dGVzdDEyMw==', in_sync => 1);
	($status) = $secret->check_value;
	is($status, 'ok', "check_value 'ok' with both values");
};

subtest '_validate_value - length check' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::Random->new('path:key', size => 8);

	# Exact length
	$secret->set_value('12345678', in_sync => 1);
	my ($results) = $secret->_validate_value;
	is($results->{length}[0], 'ok', "exact length is ok");

	# Wrong length
	$secret->set_value('short', in_sync => 1);
	($results) = $secret->_validate_value;
	is($results->{length}[0], 'warn', "wrong length is warn");
	like($results->{length}[1], qr/got 5/, "message shows actual length");
};

subtest '_validate_value - allow_oversized' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::Random->new('path:key', size => 8);

	# Oversized without allow_oversized
	$secret->set_value('1234567890', in_sync => 1);
	my ($results) = $secret->_validate_value;
	is($results->{length}[0], 'warn', "oversized is warn by default");

	# Oversized with allow_oversized
	($results) = $secret->_validate_value(allow_oversized => 1);
	is($results->{length}[0], 'ok', "oversized is ok with allow_oversized");
	like($results->{length}[1], qr/minimum/, "message mentions minimum");
};

subtest '_validate_value - valid_chars check' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::Random->new('path:key',
		size => 4, valid_chars => 'abc'
	);

	# Valid characters
	$secret->set_value('abca', in_sync => 1);
	my ($results) = $secret->_validate_value;
	is($results->{valid_chars}[0], 'ok', "valid chars passes");

	# Invalid characters
	$secret->set_value('abcX', in_sync => 1);
	($results) = $secret->_validate_value;
	is($results->{valid_chars}[0], 'warn', "invalid chars warns");
	like($results->{valid_chars}[1], qr/abcX/, "message shows value with invalid chars");
};

subtest '_validate_value - valid_chars with caret' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# Caret at start needs escaping in character class
	my $secret = Genesis::Secret::Random->new('path:key',
		size => 3, valid_chars => '^ab'
	);

	$secret->set_value('^ab', in_sync => 1);
	my ($results) = $secret->_validate_value;
	is($results->{valid_chars}[0], 'ok', "caret in valid_chars works correctly");
};

subtest '_validate_value - formatted value check' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::Random->new('path:key',
		size => 4, format => 'base64'
	);

	# Value but no format_value
	$secret->set_value('test', in_sync => 1);
	my ($results) = $secret->_validate_value;
	ok(!$results->{formatted}[0], "missing format_value fails check");
	like($results->{formatted}[1], qr/not found/, "message indicates not found");

	# Both values present
	$secret->set_format_value('dGVzdA==', in_sync => 1);
	($results) = $secret->_validate_value;
	ok($results->{formatted}[0], "format_value present passes");
};

subtest 'describe()' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::Random->new('path:key',
		size => 32, fixed => 1
	);

	my $desc = $secret->describe;
	like($desc, qr/Random/i, "describe includes label");
	like($desc, qr/32.*bytes/i, "describe includes size");
	like($desc, qr/fixed/i, "describe includes fixed flag");

	# List context
	my @parts = $secret->describe;
	is($parts[0], 'path:key', "list context: first is path");
	like($parts[1], qr/Random/i, "list context: second is label");
};

subtest 'describe() for format alternative' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::Random->new('path:key',
		size => 8, format => 'base64'
	);

	my $desc = $secret->describe('format');
	like($desc, qr/base64.*formatted/i, "format description mentions format type");
	like($desc, qr/path:key/, "format description references original path");
};

subtest 'vault_operator' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::Random->new('my/secret:password', size => 16);
	my $op = $secret->vault_operator;
	like($op, qr/vault/, "vault_operator contains 'vault'");
	like($op, qr/my\/secret:password/, "vault_operator contains path");
};

done_testing;
