#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::Deep;

# Test Genesis::Secret::UUID class
# UUID secrets generate Universally Unique Identifiers in various versions
#
# Key characteristics of UUID secrets:
# - Supports v1 (time-based), v3 (MD5 hash), v4 (random), v5 (SHA1 hash)
# - v3 and v5 are deterministic - same name+namespace always produces same UUID
# - v1 and v4 are random - regeneration produces different UUIDs
# - Can use UUID::Tiny namespace constants (NS_DNS, NS_URL, NS_OID, NS_X500)

use_ok 'Genesis::Secret::UUID';

# ------------------------------------------------------------------------------
# Constructor validation tests verify _validate_constructor_opts correctly
# handles the version-specific requirements: v3/v5 need 'name', v1/v4 don't.
# Also tests that invalid versions and unknown options are rejected.
# ------------------------------------------------------------------------------

subtest 'constructor validation - v4 (random, default)' => sub {
	# v4 is the default when no version specified
	my $default = Genesis::Secret->build('uuid', 'kit', 'path:key');
	isa_ok($default, 'Genesis::Secret::UUID');
	is($default->get('version'), 'v4', "default version is v4");

	# Explicit v4
	my $explicit_v4 = Genesis::Secret->build('uuid', 'kit', 'path:key', version => 'v4');
	isa_ok($explicit_v4, 'Genesis::Secret::UUID');
	is($explicit_v4->get('version'), 'v4', "explicit v4 stored");

	# Alternate name 'random'
	my $random = Genesis::Secret->build('uuid', 'kit', 'path:key', version => 'random');
	isa_ok($random, 'Genesis::Secret::UUID');
	is($random->get('version'), 'random', "version 'random' accepted");
};

subtest 'constructor validation - v1 (time-based)' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $v1 = Genesis::Secret::UUID->new('path:key', version => 'v1');
	isa_ok($v1, 'Genesis::Secret::UUID');
	is($v1->get('version'), 'v1', "v1 stored");

	# Alternate name 'time'
	my $time = Genesis::Secret::UUID->new('path:key', version => 'time');
	isa_ok($time, 'Genesis::Secret::UUID');
	is($time->get('version'), 'time', "version 'time' accepted");
};

subtest 'constructor validation - v3 (MD5 hash)' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# v3 requires 'name' argument
	my $v3 = Genesis::Secret::UUID->new('path:key',
		version => 'v3',
		name => 'my-identifier'
	);
	isa_ok($v3, 'Genesis::Secret::UUID');
	is($v3->get('version'), 'v3', "v3 stored");
	is($v3->get('name'), 'my-identifier', "name stored");

	# With namespace
	my $v3_ns = Genesis::Secret::UUID->new('path:key',
		version => 'v3',
		name => 'example.com',
		namespace => 'NS_DNS'
	);
	isa_ok($v3_ns, 'Genesis::Secret::UUID');
	is($v3_ns->get('namespace'), 'NS_DNS', "namespace stored");

	# Alternate name 'md5'
	my $md5 = Genesis::Secret::UUID->new('path:key',
		version => 'md5',
		name => 'test'
	);
	isa_ok($md5, 'Genesis::Secret::UUID');
	is($md5->get('version'), 'md5', "version 'md5' accepted");
};

subtest 'constructor validation - v5 (SHA1 hash)' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# v5 requires 'name' argument
	my $v5 = Genesis::Secret::UUID->new('path:key',
		version => 'v5',
		name => 'my-identifier'
	);
	isa_ok($v5, 'Genesis::Secret::UUID');
	is($v5->get('version'), 'v5', "v5 stored");
	is($v5->get('name'), 'my-identifier', "name stored");

	# Alternate name 'sha1'
	my $sha1 = Genesis::Secret::UUID->new('path:key',
		version => 'sha1',
		name => 'test'
	);
	isa_ok($sha1, 'Genesis::Secret::UUID');
	is($sha1->get('version'), 'sha1', "version 'sha1' accepted");
};

subtest 'constructor validation - error cases' => sub {
	# v3 without name - should return Invalid
	my $v3_no_name = Genesis::Secret->build('uuid', 'kit', 'path:key',
		version => 'v3'
	);
	isa_ok($v3_no_name, 'Genesis::Secret::Invalid', "v3 without name returns Invalid");

	# v5 without name - should return Invalid
	my $v5_no_name = Genesis::Secret->build('uuid', 'kit', 'path:key',
		version => 'v5'
	);
	isa_ok($v5_no_name, 'Genesis::Secret::Invalid', "v5 without name returns Invalid");

	# Invalid version
	my $bad_version = Genesis::Secret->build('uuid', 'kit', 'path:key',
		version => 'v99'
	);
	isa_ok($bad_version, 'Genesis::Secret::Invalid', "invalid version returns Invalid");

	# namespace without v3/v5 - should return Invalid (unknown option for v4)
	my $ns_wrong_version = Genesis::Secret->build('uuid', 'kit', 'path:key',
		version => 'v4',
		namespace => 'NS_DNS'
	);
	isa_ok($ns_wrong_version, 'Genesis::Secret::Invalid', "namespace with v4 returns Invalid");

	# Unknown option
	my $bad_opt = Genesis::Secret->build('uuid', 'kit', 'path:key',
		unknown_option => 'value'
	);
	isa_ok($bad_opt, 'Genesis::Secret::Invalid', "unknown option returns Invalid");
};

# ------------------------------------------------------------------------------
# Type and label tests ensure the class correctly identifies itself.
# ------------------------------------------------------------------------------

subtest 'type and label' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::UUID->new('path:key');
	is($secret->type, 'uuid', "type() returns 'uuid'");
	is($secret->label, 'UUID', "label() returns 'UUID'");
};

# ------------------------------------------------------------------------------
# describe() is used by `genesis check` and other commands to show users
# human-readable information about their UUID configuration, including
# version-specific details like name and namespace for hash-based UUIDs.
# ------------------------------------------------------------------------------

subtest 'describe() for v1 (time-based)' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::UUID->new('path:key', version => 'v1');

	my $desc = $secret->describe;
	like($desc, qr/UUID/i, "describe includes UUID");
	like($desc, qr/time.*based|v1/i, "describe mentions time-based or v1");
};

subtest 'describe() for v3 (MD5 hash)' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::UUID->new('path:key',
		version => 'v3',
		name => 'my-service',
		namespace => 'NS_DNS'
	);

	my $desc = $secret->describe;
	like($desc, qr/UUID/i, "describe includes UUID");
	like($desc, qr/md5|v3/i, "describe mentions md5 or v3");
	like($desc, qr/my-service/, "describe includes name");
	like($desc, qr/DNS/i, "describe includes namespace reference");
};

subtest 'describe() for v4 (random)' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::UUID->new('path:key', version => 'v4');

	my $desc = $secret->describe;
	like($desc, qr/UUID/i, "describe includes UUID");
	like($desc, qr/random|RNG|v4/i, "describe mentions random or v4");
};

subtest 'describe() for v5 (SHA1 hash)' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::UUID->new('path:key',
		version => 'v5',
		name => 'example.com',
		namespace => 'NS_URL'
	);

	my $desc = $secret->describe;
	like($desc, qr/UUID/i, "describe includes UUID");
	like($desc, qr/sha1|v5/i, "describe mentions sha1 or v5");
	like($desc, qr/example\.com/, "describe includes name");
};

subtest 'describe() with fixed flag' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::UUID->new('path:key',
		version => 'v4',
		fixed => 1
	);

	my $desc = $secret->describe;
	like($desc, qr/fixed/i, "describe includes fixed flag");
};

# ------------------------------------------------------------------------------
# generate_value() creates UUIDs using UUID::Tiny. For v3/v5 the output is
# deterministic based on name+namespace. For v1/v4 each call produces a new
# random UUID.
# ------------------------------------------------------------------------------

subtest 'generate_value() produces valid UUID format' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# UUID format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
	my $uuid_re = qr/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;

	my $v4 = Genesis::Secret::UUID->new('path:key', version => 'v4');
	like($v4->generate_value, $uuid_re, "v4 generates valid UUID format");

	my $v1 = Genesis::Secret::UUID->new('path:key', version => 'v1');
	like($v1->generate_value, $uuid_re, "v1 generates valid UUID format");

	my $v3 = Genesis::Secret::UUID->new('path:key',
		version => 'v3',
		name => 'test',
		namespace => 'NS_DNS'
	);
	like($v3->generate_value, $uuid_re, "v3 generates valid UUID format");

	my $v5 = Genesis::Secret::UUID->new('path:key',
		version => 'v5',
		name => 'test',
		namespace => 'NS_DNS'
	);
	like($v5->generate_value, $uuid_re, "v5 generates valid UUID format");
};

subtest 'generate_value() v3/v5 are deterministic' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# v3 (MD5) - same inputs always produce same output
	my $v3 = Genesis::Secret::UUID->new('path:key',
		version => 'v3',
		name => 'deterministic-test',
		namespace => 'NS_DNS'
	);
	my $v3_uuid1 = $v3->generate_value;
	my $v3_uuid2 = $v3->generate_value;
	is($v3_uuid1, $v3_uuid2, "v3 generates same UUID for same inputs");

	# v5 (SHA1) - same inputs always produce same output
	my $v5 = Genesis::Secret::UUID->new('path:key',
		version => 'v5',
		name => 'deterministic-test',
		namespace => 'NS_URL'
	);
	my $v5_uuid1 = $v5->generate_value;
	my $v5_uuid2 = $v5->generate_value;
	is($v5_uuid1, $v5_uuid2, "v5 generates same UUID for same inputs");

	# Different names produce different UUIDs
	my $v5_other = Genesis::Secret::UUID->new('path:key',
		version => 'v5',
		name => 'different-name',
		namespace => 'NS_URL'
	);
	isnt($v5->generate_value, $v5_other->generate_value,
		"different names produce different UUIDs");
};

subtest 'generate_value() v4 is random' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# v4 should generate different UUIDs each time (with extremely high probability)
	my $v4 = Genesis::Secret::UUID->new('path:key', version => 'v4');
	my $uuid1 = $v4->generate_value;
	my $uuid2 = $v4->generate_value;
	isnt($uuid1, $uuid2, "v4 generates different UUIDs on successive calls");
};

# ------------------------------------------------------------------------------
# _validate_value() checks that stored values are valid UUID strings, and for
# v3/v5 verifies they match the expected hash for the given name+namespace.
# ------------------------------------------------------------------------------

subtest '_validate_value - valid UUID string' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::UUID->new('path:key', version => 'v4');
	$secret->set_value('550e8400-e29b-41d4-a716-446655440000', in_sync => 1);

	my ($results) = $secret->_validate_value;
	is($results->{valid}[0], 'ok', "valid UUID string passes");
};

subtest '_validate_value - invalid UUID string' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::UUID->new('path:key', version => 'v4');
	$secret->set_value('not-a-valid-uuid', in_sync => 1);

	my ($results) = $secret->_validate_value;
	is($results->{valid}[0], 'error', "invalid UUID string fails");
	like($results->{valid}[1], qr/expecting/, "error message explains expected format");
};

subtest '_validate_value - v5 hash verification' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::UUID->new('path:key',
		version => 'v5',
		name => 'test-name',
		namespace => 'NS_DNS'
	);

	# Set the correct UUID for this name+namespace
	my $correct_uuid = $secret->generate_value;
	$secret->set_value($correct_uuid, in_sync => 1);

	my ($results) = $secret->_validate_value;
	is($results->{valid}[0], 'ok', "valid UUID passes");
	ok($results->{hash}[0], "correct hash for name+namespace passes");

	# Now set a wrong UUID
	$secret->set_value('550e8400-e29b-41d4-a716-446655440000', in_sync => 1);
	($results) = $secret->_validate_value;
	ok(!$results->{hash}[0], "wrong hash for name+namespace fails");
	like($results->{hash}[1], qr/expected/, "error shows expected vs got");
};

# ------------------------------------------------------------------------------
# process_command_output() filters the output from safe commands to suppress
# the UUID value echo during 'add' operations.
# ------------------------------------------------------------------------------

subtest 'process_command_output filters add output' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::UUID->new('some/path:mykey', version => 'v4');

	# Simulated output from safe set that includes the UUID
	my $output = "mykey: 550e8400-e29b-41d4-a716-446655440000";
	my ($filtered, $rc, $err) = $secret->process_command_output('add', $output, 0, '');

	is($filtered, '', "UUID output line filtered for add action");
	is($rc, 0, "return code preserved");
};

subtest 'process_command_output preserves non-add output' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::UUID->new('some/path:mykey', version => 'v4');

	my $output = "mykey: 550e8400-e29b-41d4-a716-446655440000";
	my ($filtered, $rc, $err) = $secret->process_command_output('rotate', $output, 0, '');

	is($filtered, $output, "output preserved for non-add actions");
};

# ------------------------------------------------------------------------------
# Verify UUID properly inherits base class functionality.
# ------------------------------------------------------------------------------

subtest 'inherits base class functionality' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::UUID->new('test/path:key',
		version => 'v5',
		name => 'test',
		_feature => 'uuid-feature'
	);

	# Path accessor
	is($secret->path, 'test/path:key', "path() works");

	# Source tracking
	is($secret->source, 'kit', "source() works");
	ok($secret->from_kit, "from_kit() works");
	is($secret->feature, 'uuid-feature', "feature() works");

	# Definition accessors
	ok($secret->has('version'), "has() works");
	is($secret->get('version'), 'v5', "get() works");
	is($secret->get('name'), 'test', "get('name') works");
};

done_testing;
