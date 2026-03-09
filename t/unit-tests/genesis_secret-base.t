#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::Deep;

# Test Genesis::Secret base class and factory
# Note: Cannot instantiate Genesis::Secret directly, must use build() or subclasses

use_ok 'Genesis::Secret';
use_ok 'Genesis::Secret::Invalid';

# ------------------------------------------------------------------------------
# Minimal derived class for testing base class methods directly.
# This class inherits everything from Genesis::Secret without overriding,
# so all method calls go to the base class implementation.
# ------------------------------------------------------------------------------
{
	package Genesis::Secret::Malformed;
	use base 'Genesis::Secret';
	# No methods defined - purely inherits from base class.
	# Must use GENESIS_SKIP_SECRET_DEFINITION_VALIDATION=1 to instantiate
	# since base class abstract methods (_required_constructor_opts, etc.) will bug().
}

{
	package Genesis::Secret::SimpleValidation;
	use base 'Genesis::Secret';
	# Provides _required/_optional_constructor_opts but NOT _validate_constructor_opts.
	# This tests the fallback validation path in validate_definition().

	sub _required_constructor_opts { qw/required_opt/ }
	sub _optional_constructor_opts { qw/optional_opt fixed/ }
}

subtest 'class_of() helper maps types correctly' => sub {
	# Standard types - ucfirst() works for these
	is(Genesis::Secret::class_of('random'), 'Genesis::Secret::Random', "random -> Random");
	is(Genesis::Secret::class_of('invalid'), 'Genesis::Secret::Invalid', "invalid -> Invalid");
	is(Genesis::Secret::class_of('x509'), 'Genesis::Secret::X509', "x509 -> X509");

	# Exception types - require explicit mapping in class_of()
	is(Genesis::Secret::class_of('dhparams'), 'Genesis::Secret::DHParams', "dhparams -> DHParams");
	is(Genesis::Secret::class_of('ssh'), 'Genesis::Secret::SSH', "ssh -> SSH");
	is(Genesis::Secret::class_of('rsa'), 'Genesis::Secret::RSA', "rsa -> RSA");
	is(Genesis::Secret::class_of('uuid'), 'Genesis::Secret::UUID', "uuid -> UUID");
	is(Genesis::Secret::class_of('userprovided'), 'Genesis::Secret::UserProvided', "userprovided -> UserProvided");
	is(Genesis::Secret::class_of('user-provided'), 'Genesis::Secret::UserProvided', "user-provided -> UserProvided (alias)");
};

subtest 'build() factory creates correct subclass instances' => sub {
	# Skip validation to allow testing without full environment
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $random = Genesis::Secret->build('random', 'kit', 'test/path:key', size => 32);
	isa_ok($random, 'Genesis::Secret::Random', "build('random') creates Random instance");
	is($random->path, 'test/path:key', "path is set correctly");
	is($random->get('size'), 32, "size definition is preserved");

	my $invalid = Genesis::Secret->build('invalid', 'kit', 'another/path:key',
		data => {foo => 'bar'},
		subject => 'test',
		errors => ['error1']
	);
	isa_ok($invalid, 'Genesis::Secret::Invalid', "build('invalid') creates Invalid instance");
	is($invalid->valid, 0, "Invalid secret reports valid=0");
};

subtest 'build() returns Invalid for unknown types' => sub {
	my $bad = Genesis::Secret->build('nonexistent_type', 'kit', 'some/path:key');
	isa_ok($bad, 'Genesis::Secret::Invalid', "Unknown type returns Invalid");
	is($bad->valid, 0, "Invalid secret reports valid=0");

	# Check that error message mentions the type
	my $desc = $bad->describe;
	like($desc, qr/nonexistent_type/i, "describe() mentions the unknown type");
};

subtest 'common accessors work correctly' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret->build('random', 'kit', 'my/path:value', size => 16, fixed => 1);
	isa_ok($secret, 'Genesis::Secret::Random');

	# path accessor
	is($secret->path, 'my/path:value', "path() returns the secret path");

	# type accessor
	is($secret->type, 'random', "type() returns the type string");

	# label accessor
	is($secret->label, 'Random', "label() returns capitalized type");

	# definition accessor
	my $def = $secret->definition;
	is(ref($def), 'HASH', "definition() returns a hash");
	is($def->{size}, 16, "definition contains size");

	# get() accessor
	is($secret->get('size'), 16, "get('size') returns size");
	is($secret->get('fixed'), 1, "get('fixed') returns fixed flag");
	is($secret->get('nonexistent'), undef, "get() returns undef for missing key");
	is($secret->get('nonexistent', 'default'), 'default', "get() returns default for missing key");

	# has() accessor
	ok($secret->has('size'), "has('size') returns true");
	ok($secret->has('fixed'), "has('fixed') returns true");
	ok(!$secret->has('nonexistent'), "has('nonexistent') returns false");

	# has() with falsy value - should still return true if key exists
	my $unfixed = Genesis::Secret->build('random', 'kit', 'other/path:key', size => 8, fixed => 0);
	ok($unfixed->has('fixed'), "has('fixed') returns true even when fixed => 0");
	is($unfixed->get('fixed'), 0, "get('fixed') returns 0 (falsy value)");

	# set() accessor
	$secret->set('custom_prop', 'custom_value');
	is($secret->get('custom_prop'), 'custom_value', "set() stores new value");
	ok($secret->has('custom_prop'), "has() returns true after set()");

	# set() to change existing definition value
	is($secret->get('size'), 16, "size is initially 16");
	$secret->set('size', 32);
	is($secret->get('size'), 32, "set() changes existing definition value");
};

subtest 'source tracking' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# Test with kit source
	my $kit_secret = Genesis::Secret->build('random', 'kit', 'path:key',
		size => 8, _feature => 'some-feature'
	);
	is($kit_secret->source, 'kit', "source() returns 'kit' for kit secrets");
	ok($kit_secret->from_kit, "from_kit() returns true for kit secrets");
	ok(!$kit_secret->from_manifest, "from_manifest() returns false for kit secrets");
	is($kit_secret->feature, 'some-feature', "feature() returns the feature name");

	# Test with manifest source
	my $manifest_secret = Genesis::Secret->build('random', 'manifest', 'path:key',
		size => 8, _ch_name => 'my.var'
	);
	is($manifest_secret->source, 'manifest', "source() returns 'manifest' for manifest secrets");
	ok(!$manifest_secret->from_kit, "from_kit() returns false for manifest secrets");
	ok($manifest_secret->from_manifest, "from_manifest() returns true for manifest secrets");
	is($manifest_secret->var_name, 'my.var', "var_name() returns the variable name");
};

subtest 'all_paths() method' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# Base case - single path
	my $simple = Genesis::Secret->build('random', 'kit', 'simple/path:key', size => 8);
	my @paths = $simple->all_paths;
	cmp_deeply(\@paths, ['simple/path:key'], "all_paths() returns single path for simple secret");

	# Random with format - should include format_path
	my $formatted = Genesis::Secret->build('random', 'kit', 'fmt/path:value',
		size => 8, format => 'base64'
	);
	@paths = $formatted->all_paths;
	cmp_deeply(\@paths, ['fmt/path:value', 'fmt/path:value-base64'],
		"all_paths() includes format_path for formatted random secret");
};

subtest 'loaded and reset state' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret->build('random', 'kit', 'path:key', size => 8);
	is($secret->loaded, 0, "loaded() is 0 initially");

	# Simulate loading a value
	$secret->set_value('test_value', in_sync => 1, loaded => 1);
	is($secret->loaded, 1, "loaded() is 1 after set_value with loaded flag");
	is($secret->has_value, 1, "has_value() is 1 after set_value");

	# Reset
	$secret->reset;
	is($secret->loaded, 0, "loaded() is 0 after reset");
	ok(!$secret->has_value, "has_value() is false after reset");
};

subtest 'set_value and value accessors' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret->build('random', 'kit', 'path:key', size => 8);

	# Set pending value
	$secret->set_value('pending_val');
	is($secret->{value}, 'pending_val', "set_value stores in {value}");
	is($secret->value, 'pending_val', "value() returns pending value");

	# Set value as in_sync (stored)
	$secret->set_value('stored_val', in_sync => 1);
	ok(!exists $secret->{value}, "in_sync moves value out of {value}");
	is($secret->{stored_value}, 'stored_val', "in_sync stores in {stored_value}");
	is($secret->value, 'stored_val', "value() returns stored value");

	# Pending value takes precedence
	$secret->set_value('new_pending');
	is($secret->value, 'new_pending', "pending value takes precedence over stored");
};

subtest 'update_value merges hashes' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret->build('random', 'kit', 'path:key', size => 8);

	# Set initial hash value
	$secret->set_value({key1 => 'val1', key2 => 'val2'}, in_sync => 1);

	# Update with partial hash
	$secret->update_value({key2 => 'updated', key3 => 'new'});

	my $val = $secret->value;
	is(ref($val), 'HASH', "value is still a hash");
	is($val->{key1}, 'val1', "unchanged key preserved");
	is($val->{key2}, 'updated', "updated key has new value");
	is($val->{key3}, 'new', "new key added");

	# Non-hash update replaces value entirely
	$secret->update_value('scalar_value');
	is($secret->value, 'scalar_value', "non-hash update replaces value");

	# Updating scalar with hash replaces
	$secret->update_value({new => 'hash'});
	is(ref($secret->value), 'HASH', "hash replaces scalar");
	is($secret->value->{new}, 'hash', "new hash value set");
};

subtest 'promote_value_to_stored' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret->build('random', 'kit', 'path:key', size => 8);
	$secret->set_value('pending');
	is($secret->{value}, 'pending', "value in pending state");
	is($secret->loaded, 0, "not loaded yet");

	$secret->promote_value_to_stored;
	ok(!exists $secret->{value}, "pending value cleared");
	is($secret->{stored_value}, 'pending', "value moved to stored");
	is($secret->loaded, 1, "marked as loaded");
};

subtest 'check_value for missing values' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret->build('random', 'kit', 'path:key', size => 8);

	# No value set
	my ($status, $msg) = $secret->check_value;
	is($status, 'missing', "check_value returns 'missing' for empty secret");
};

subtest 'check_value with _required_value_keys' => sub {
	# Test the hash value validation path using SSH which has _required_value_keys
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $ssh = Genesis::Secret->build('ssh', 'kit', 'path:key', size => 2048);

	# Set incomplete hash - missing required keys
	$ssh->set_value({private => 'privkey'}, in_sync => 1);
	my ($status, $msg) = $ssh->check_value;
	is($status, 'missing', "check_value returns 'missing' when required keys missing");
	like($msg, qr/public/, "message mentions missing 'public' key");
	like($msg, qr/fingerprint/, "message mentions missing 'fingerprint' key");

	# Set scalar instead of hash when hash expected
	$ssh->set_value('not_a_hash', in_sync => 1);
	($status, $msg) = $ssh->check_value;
	is($status, 'missing', "check_value returns 'missing' when value is not a hash");

	# Set complete hash
	$ssh->set_value({
		private => 'privkey',
		public => 'pubkey',
		fingerprint => 'fp:xx:yy'
	}, in_sync => 1);
	($status, $msg) = $ssh->check_value;
	is($status, 'ok', "check_value returns 'ok' when all required keys present");
};

subtest 'describe() method' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret->build('random', 'kit', 'path:key', size => 16, fixed => 1);

	# Scalar context
	my $desc = $secret->describe;
	like($desc, qr/Random/i, "describe() includes label");
	like($desc, qr/16/, "describe() includes size");
	like($desc, qr/fixed/i, "describe() includes fixed flag");

	# List context
	my @parts = $secret->describe;
	is($parts[0], 'path:key', "describe() list: first element is path");
	like($parts[1], qr/Random/i, "describe() list: second element is label");
};

subtest 'reject() creates Invalid instance' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $rejected = Genesis::Secret->reject(
		'Test Subject',
		['Error 1', 'Error 2'],
		'test/path:key',
		{foo => 'bar'}
	);

	isa_ok($rejected, 'Genesis::Secret::Invalid', "reject() returns Invalid instance");
	is($rejected->valid, 0, "rejected secret is not valid");
	is($rejected->get('subject'), 'Test Subject', "subject is stored");
	cmp_deeply($rejected->get('errors'), ['Error 1', 'Error 2'], "errors are stored");
};

subtest 'reject() on instance inherits path and definition' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# Create an existing secret
	my $original = Genesis::Secret->build('random', 'kit', 'original/path:key',
		size => 16, _feature => 'my-feature'
	);

	# Call reject on the instance - should inherit path and definition
	my $rejected = $original->reject('Validation Failed', 'Some error');

	isa_ok($rejected, 'Genesis::Secret::Invalid', "reject on instance returns Invalid");
	is($rejected->path, 'original/path:key', "inherits path from original");
	is($rejected->get('data')->{size}, 16, "inherits definition from original");
	is($rejected->get('data')->{_feature}, 'my-feature', "inherits feature from original");
	is($rejected->get('subject'), 'Validation Failed', "subject is stored");
};

subtest 'validate_definition delegation' => sub {
	# When GENESIS_SKIP_SECRET_DEFINITION_VALIDATION is not set,
	# validate_definition should delegate to _validate_constructor_opts or use defaults

	# Test with valid Random definition
	my $secret = Genesis::Secret->build('random', 'kit', 'path:key', size => 32);
	isa_ok($secret, 'Genesis::Secret::Random', "valid definition creates correct class");
	is($secret->valid, 1, "valid definition produces valid secret");

	# Test with invalid Random definition (missing size)
	my $invalid = Genesis::Secret->build('random', 'kit', 'path:key');
	isa_ok($invalid, 'Genesis::Secret::Invalid', "invalid definition returns Invalid");
	is($invalid->valid, 0, "invalid definition produces invalid secret");
};

subtest 'validate_definition fallback path' => sub {
	# Test the fallback validation when class has _required/_optional_constructor_opts
	# but NOT _validate_constructor_opts. Uses SimpleValidation test class.

	# Valid: has required_opt
	my ($opts, $path) = Genesis::Secret::SimpleValidation->validate_definition(
		'test/path:key', required_opt => 'value', optional_opt => 'extra'
	);
	is(ref($opts), 'HASH', "valid definition returns opts hash");
	is($path, 'test/path:key', "path returned correctly");
	is($opts->{required_opt}, 'value', "required option preserved");
	is($opts->{optional_opt}, 'extra', "optional option preserved");

	# Invalid: missing required_opt
	my ($opts2, $errors, $path2) = Genesis::Secret::SimpleValidation->validate_definition(
		'test/path:key', optional_opt => 'value'
	);
	is(ref($errors), 'ARRAY', "invalid definition returns errors array");
	like($errors->[0], qr/required_opt/, "error mentions missing required option");

	# Invalid: unknown option
	my ($opts3, $errors2, $path3) = Genesis::Secret::SimpleValidation->validate_definition(
		'test/path:key', required_opt => 'ok', unknown_opt => 'bad'
	);
	is(ref($errors2), 'ARRAY', "unknown option returns errors array");
	like($errors2->[0], qr/unknown_opt/, "error mentions unknown option");
};

subtest 'cannot instantiate Genesis::Secret directly' => sub {
	# Attempting to call new() directly on Genesis::Secret should fail
	# This is enforced by a bug() call in new()
	# bug() calls die() when inside eval (checks $^S), so we can catch it

	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $error;
	eval {
		Genesis::Secret->new('some/path:key', size => 8);
	};
	$error = $@;

	ok($error, "Genesis::Secret->new() dies when called directly");
	like($error, qr/Cannot directly instantiate.*Genesis::Secret/i,
		"error message mentions cannot directly instantiate");
};

subtest 'abstract methods bug() when not overridden' => sub {
	# The base class defines _required_constructor_opts and _optional_constructor_opts
	# as abstract methods that bug() if a derived class doesn't override them.
	# Test this using Malformed class which deliberately doesn't implement them.

	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# First verify Malformed can be instantiated (it provides the opts methods)
	my $secret = Genesis::Secret::Malformed->new('test/path:key');
	isa_ok($secret, 'Genesis::Secret::Malformed');

	# Now test calling abstract methods directly on base class bugs out
	my $error;
	eval {
		Genesis::Secret->_required_constructor_opts();
	};
	$error = $@;
	ok($error, "_required_constructor_opts() bugs on base class");
	like($error, qr/did not define/i, "error mentions missing definition");

	eval {
		Genesis::Secret->_optional_constructor_opts();
	};
	$error = $@;
	ok($error, "_optional_constructor_opts() bugs on base class");
	like($error, qr/did not define/i, "error mentions missing definition");
};

subtest 'base class methods via Malformed' => sub {
	# Use Malformed to test base class methods that derived classes often override.
	# This ensures the base implementations get coverage.

	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::Malformed->new('base/path:key', fixed => 1);

	# valid() - base class returns 1 (overridden to 0 in Invalid)
	is($secret->valid, 1, "valid() returns 1 in base class");

	# type() - extracts from class name
	is($secret->type, 'malformed', "type() extracts 'malformed' from class name");

	# label() - ucfirst of type
	is($secret->label, 'Malformed', "label() returns ucfirst of type");

	# all_paths() - base class just returns (path), not overridden by Malformed
	my @paths = $secret->all_paths;
	cmp_deeply(\@paths, ['base/path:key'], "all_paths() returns single path in base");

	# default_key() - base class returns undef
	is($secret->default_key, undef, "default_key() returns undef in base");

	# missing() - opposite of has_value
	ok($secret->missing, "missing() returns true when no value");
	$secret->set_value('test', in_sync => 1);
	ok(!$secret->missing, "missing() returns false when has value");

	# is_command_interactive() - base class returns 0
	is($secret->is_command_interactive('add'), 0, "is_command_interactive() returns 0 in base");

	# _required_value_keys() - base class returns undef
	is($secret->_required_value_keys, undef, "_required_value_keys() returns undef in base");
};

subtest 'check_value base class behavior' => sub {
	# Test the base class check_value() logic using Malformed.
	# Base class check_value returns 'missing' if no value, 'ok' if value exists.

	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::Malformed->new('path:key');

	# No value set - should return 'missing'
	my ($status, $msg) = $secret->check_value;
	is($status, 'missing', "check_value returns 'missing' when no value");

	# Set a scalar value
	$secret->set_value('some_value', in_sync => 1);
	($status, $msg) = $secret->check_value;
	is($status, 'ok', "check_value returns 'ok' when scalar value exists");

	# Test with hash value (no required keys in base class)
	$secret->reset;
	$secret->set_value({key1 => 'val1'}, in_sync => 1);
	($status, $msg) = $secret->check_value;
	is($status, 'ok', "check_value returns 'ok' for hash value with no required keys");
};

subtest 'process_command_output base class behavior' => sub {
	# Test the base class process_command_output() which just trims whitespace.

	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::Malformed->new('path:key');

	# Test basic passthrough with leading whitespace trimming (trailing preserved)
	my ($out, $rc, $err) = $secret->process_command_output('add', '  output text', 0, '');
	is($out, 'output text', "process_command_output trims leading whitespace");
	is($rc, 0, "return code preserved");
	is($err, '', "error preserved");

	# Verify trailing whitespace is preserved (not trimmed)
	($out, $rc, $err) = $secret->process_command_output('add', '  text with trailing  ', 0, '');
	is($out, 'text with trailing  ', "trailing whitespace is preserved");

	# Test with error output
	($out, $rc, $err) = $secret->process_command_output('rotate', 'result', 1, 'error msg');
	is($out, 'result', "output preserved");
	is($rc, 1, "non-zero return code preserved");
	is($err, 'error msg', "error message preserved");
};

subtest '_assemble_vault_operator string generation' => sub {
	# Test the base class _assemble_vault_operator() which generates vault operator strings.

	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::Malformed->new('path:key');

	# Relative path - should include meta.vault prefix
	my $op = $secret->_assemble_vault_operator('my/secret:key');
	like($op, qr/\(\( vault/, "operator starts with (( vault");
	like($op, qr/meta\.vault/, "relative path includes meta.vault prefix");
	like($op, qr/\/my\/secret:key/, "path is included with leading /");
	like($op, qr/\)\)$/, "operator ends with ))");

	# Absolute path (starts with /) - should NOT include meta.vault
	$op = $secret->_assemble_vault_operator('/absolute/path:key');
	like($op, qr/\(\( vault/, "operator starts with (( vault");
	unlike($op, qr/meta\.vault/, "absolute path does NOT include meta.vault");
	like($op, qr/"\/absolute\/path:key"/, "absolute path preserved");
};

subtest 'validate_value orchestrates _validate_value' => sub {
	# Test the base class validate_value() which calls check_value() first,
	# then delegates to _validate_value() if the class implements it.
	# Using Random since it has _validate_value implemented.

	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret->build('random', 'kit', 'path:key', size => 8);

	# No value set - should return 'missing' from check_value
	my ($status, $msg) = $secret->validate_value(undef);
	is($status, 'missing', "validate_value returns 'missing' when no value");

	# Set a value with correct length
	$secret->set_value('12345678', in_sync => 1);
	($status, $msg) = $secret->validate_value(undef);
	is($status, 'ok', "validate_value returns 'ok' for valid value");
	like($msg, qr/8 characters/, "message mentions expected size");

	# Set a value with wrong length - should warn
	$secret->set_value('short', in_sync => 1);
	($status, $msg) = $secret->validate_value(undef);
	is($status, 'warn', "validate_value returns 'warn' for wrong size");
	like($msg, qr/got 5/, "message shows actual size");

	# Test with Malformed (no _validate_value) - should just return check_value result
	my $malformed = Genesis::Secret::Malformed->new('path:key');
	$malformed->set_value('anything', in_sync => 1);
	($status, $msg) = $malformed->validate_value(undef);
	is($status, 'ok', "validate_value returns 'ok' when no _validate_value method");
};

done_testing;
