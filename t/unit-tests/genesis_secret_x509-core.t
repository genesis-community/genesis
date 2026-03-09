#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::Deep;

# Test Genesis::Secret::X509 class
# X509 secrets represent X.509 certificates with public/private keys
#
# Key characteristics of X509 secrets:
# - Most complex secret type with CA signing chains, SANs, and key usage
# - Required 'names' array for non-CA certs (Subject Alternative Names)
# - Optional 'is_ca' flag for Certificate Authority certificates
# - Optional 'signed_by' for specifying signing CA path
# - Optional 'valid_for' with format like '3y', '90d', '24h'
# - Optional 'usage' array for key usage specifications
# - Stores certificate, key, combined (plus crl, serial for CAs)

use_ok 'Genesis::Secret::X509';

# ------------------------------------------------------------------------------
# Constructor validation tests verify _validate_constructor_opts correctly
# handles X509-specific requirements: names validation, valid_for format,
# usage arrays, is_ca flags, and signed_by path validation.
# ------------------------------------------------------------------------------

subtest 'constructor validation - basic non-CA certificate' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# Minimal valid non-CA certificate - needs at least one name
	my $simple = Genesis::Secret::X509->new('path/cert',
		names => ['example.com']
	);
	isa_ok($simple, 'Genesis::Secret::X509');
	cmp_deeply($simple->get('names'), ['example.com'], "names stored");

	# Multiple SANs
	my $multi_san = Genesis::Secret::X509->new('path/cert',
		names => ['example.com', 'www.example.com', '10.0.0.1']
	);
	isa_ok($multi_san, 'Genesis::Secret::X509');
	cmp_deeply($multi_san->get('names'), ['example.com', 'www.example.com', '10.0.0.1'],
		"multiple names stored");

	# With explicit subject CN
	my $with_cn = Genesis::Secret::X509->new('path/cert',
		names => ['example.com'],
		subject_cn => 'My Certificate'
	);
	isa_ok($with_cn, 'Genesis::Secret::X509');
	is($with_cn->get('subject_cn'), 'My Certificate', "subject_cn stored");
};

subtest 'constructor validation - CA certificate' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# CA certificate - doesn't require names (will auto-generate)
	my $ca = Genesis::Secret::X509->new('path/ca',
		is_ca => 1,
		base_path => 'my-env/'
	);
	isa_ok($ca, 'Genesis::Secret::X509');
	is($ca->get('is_ca'), 1, "is_ca flag stored");
	is($ca->get('base_path'), 'my-env/', "base_path stored");

	# CA with explicit names
	my $ca_named = Genesis::Secret::X509->new('path/ca',
		is_ca => 1,
		names => ['My CA'],
		base_path => 'env/'
	);
	isa_ok($ca_named, 'Genesis::Secret::X509');
	cmp_deeply($ca_named->get('names'), ['My CA'], "CA names stored");
};

subtest 'constructor validation - signed_by' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# Signed by relative path
	my $signed = Genesis::Secret::X509->new('path/cert',
		names => ['example.com'],
		signed_by => 'path/ca'
	);
	isa_ok($signed, 'Genesis::Secret::X509');
	is($signed->get('signed_by'), 'path/ca', "signed_by relative path stored");

	# Signed by absolute path (starts with /)
	my $signed_abs = Genesis::Secret::X509->new('path/cert',
		names => ['example.com'],
		signed_by => '/absolute/path/ca'
	);
	isa_ok($signed_abs, 'Genesis::Secret::X509');
	is($signed_abs->get('signed_by'), '/absolute/path/ca', "signed_by absolute path stored");
};

subtest 'constructor validation - valid_for formats' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# Years
	my $years = Genesis::Secret::X509->new('path/cert',
		names => ['example.com'],
		valid_for => '10y'
	);
	isa_ok($years, 'Genesis::Secret::X509');
	is($years->get('valid_for'), '10y', "valid_for years accepted");

	# Months
	my $months = Genesis::Secret::X509->new('path/cert',
		names => ['example.com'],
		valid_for => '6m'
	);
	is($months->get('valid_for'), '6m', "valid_for months accepted");

	# Days
	my $days = Genesis::Secret::X509->new('path/cert',
		names => ['example.com'],
		valid_for => '90d'
	);
	is($days->get('valid_for'), '90d', "valid_for days accepted");

	# Hours
	my $hours = Genesis::Secret::X509->new('path/cert',
		names => ['example.com'],
		valid_for => '24h'
	);
	is($hours->get('valid_for'), '24h', "valid_for hours accepted");

	# Test valid_for through build() to exercise validation success path
	# Must unset skip flag to actually run validation
	delete local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION};
	my $validated = Genesis::Secret->build('x509', 'kit', 'path/cert',
		names => ['example.com'],
		valid_for => '1y'
	);
	isa_ok($validated, 'Genesis::Secret::X509', "valid_for passes build() validation");
	is($validated->get('valid_for'), '1y', "valid_for stored after validation");
};

subtest 'constructor validation - usage array' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# Standard server certificate usage
	my $server = Genesis::Secret::X509->new('path/cert',
		names => ['example.com'],
		usage => ['server_auth', 'client_auth']
	);
	isa_ok($server, 'Genesis::Secret::X509');
	cmp_deeply($server->get('usage'), ['server_auth', 'client_auth'], "usage array stored");

	# CA usage
	my $ca_usage = Genesis::Secret::X509->new('path/ca',
		is_ca => 1,
		usage => ['key_cert_sign', 'crl_sign'],
		base_path => 'env/'
	);
	cmp_deeply($ca_usage->get('usage'), ['key_cert_sign', 'crl_sign'], "CA usage stored");

	# Code signing usage
	my $code = Genesis::Secret::X509->new('path/cert',
		names => ['signer'],
		usage => ['code_signing', 'digital_signature']
	);
	cmp_deeply($code->get('usage'), ['code_signing', 'digital_signature'], "code signing usage stored");
};

subtest 'constructor validation - fixed flag' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $fixed = Genesis::Secret::X509->new('path/cert',
		names => ['example.com'],
		fixed => 1
	);
	isa_ok($fixed, 'Genesis::Secret::X509');
	is($fixed->get('fixed'), 1, "fixed flag stored");
};

subtest 'constructor validation - error cases' => sub {
	# These tests verify _validate_constructor_opts rejects invalid configs

	# Missing names for non-CA cert
	my $no_names = Genesis::Secret->build('x509', 'kit', 'path/cert');
	isa_ok($no_names, 'Genesis::Secret::Invalid', "non-CA without names returns Invalid");

	# Empty names array for non-CA
	my $empty_names = Genesis::Secret->build('x509', 'kit', 'path/cert',
		names => []
	);
	isa_ok($empty_names, 'Genesis::Secret::Invalid', "empty names array returns Invalid");

	# Names as string instead of array
	my $string_names = Genesis::Secret->build('x509', 'kit', 'path/cert',
		names => 'example.com'
	);
	isa_ok($string_names, 'Genesis::Secret::Invalid', "names as string returns Invalid");

	# Names as hash instead of array
	my $hash_names = Genesis::Secret->build('x509', 'kit', 'path/cert',
		names => {host => 'example.com'}
	);
	isa_ok($hash_names, 'Genesis::Secret::Invalid', "names as hash returns Invalid");

	# Empty name in array
	my $empty_entry = Genesis::Secret->build('x509', 'kit', 'path/cert',
		names => ['example.com', '', 'other.com']
	);
	isa_ok($empty_entry, 'Genesis::Secret::Invalid', "empty name entry returns Invalid");

	# Non-string entry in names array (catches accidentally nested YAML structures)
	my $ref_entry = Genesis::Secret->build('x509', 'kit', 'path/cert',
		names => ['example.com', ['nested', 'array']]
	);
	isa_ok($ref_entry, 'Genesis::Secret::Invalid', "reference in names array returns Invalid");

	# Invalid valid_for format
	my $bad_valid = Genesis::Secret->build('x509', 'kit', 'path/cert',
		names => ['example.com'],
		valid_for => '3 years'
	);
	isa_ok($bad_valid, 'Genesis::Secret::Invalid', "invalid valid_for format returns Invalid");

	# Invalid valid_for - zero value
	my $zero_valid = Genesis::Secret->build('x509', 'kit', 'path/cert',
		names => ['example.com'],
		valid_for => '0d'
	);
	isa_ok($zero_valid, 'Genesis::Secret::Invalid', "zero valid_for returns Invalid");

	# Invalid usage type
	my $bad_usage = Genesis::Secret->build('x509', 'kit', 'path/cert',
		names => ['example.com'],
		usage => ['invalid_usage_type']
	);
	isa_ok($bad_usage, 'Genesis::Secret::Invalid', "invalid usage type returns Invalid");

	# Usage as string instead of array
	my $string_usage = Genesis::Secret->build('x509', 'kit', 'path/cert',
		names => ['example.com'],
		usage => 'server_auth'
	);
	isa_ok($string_usage, 'Genesis::Secret::Invalid', "usage as string returns Invalid");

	# Invalid is_ca value
	my $bad_is_ca = Genesis::Secret->build('x509', 'kit', 'path/cert',
		names => ['example.com'],
		is_ca => 'yes'
	);
	isa_ok($bad_is_ca, 'Genesis::Secret::Invalid', "non-boolean is_ca returns Invalid");

	# Invalid signed_by path (contains invalid characters)
	my $bad_signed = Genesis::Secret->build('x509', 'kit', 'path/cert',
		names => ['example.com'],
		signed_by => 'path with spaces/ca'
	);
	isa_ok($bad_signed, 'Genesis::Secret::Invalid', "invalid signed_by path returns Invalid");

	# Unknown option
	my $bad_opt = Genesis::Secret->build('x509', 'kit', 'path/cert',
		names => ['example.com'],
		unknown_option => 'value'
	);
	isa_ok($bad_opt, 'Genesis::Secret::Invalid', "unknown option returns Invalid");
};

# ------------------------------------------------------------------------------
# Type and label tests ensure the class correctly identifies itself for
# logging, error messages, and the describe() output shown to users.
# ------------------------------------------------------------------------------

subtest 'type and label' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::X509->new('path/cert', names => ['example.com']);
	is($secret->type, 'x509', "type() returns 'x509'");
	is($secret->label, 'X.509 certificate', "label() returns 'X.509 certificate'");
};

# ------------------------------------------------------------------------------
# describe() is used by `genesis check` and other commands to show users
# human-readable information about their certificate configuration including
# CA status, signing chain, and self-signed indicators.
# ------------------------------------------------------------------------------

subtest 'describe() for regular certificate' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::X509->new('path/cert',
		names => ['example.com'],
		signed_by => 'path/ca'
	);

	my $desc = $secret->describe;
	like($desc, qr/X\.509/i, "describe includes X.509");
	like($desc, qr/signed by.*path\/ca/i, "describe mentions signing CA");

	# List context
	my @parts = $secret->describe;
	is($parts[0], 'path/cert', "list context: first is path");
	like($parts[1], qr/X\.509/i, "list context: second is label");
};

subtest 'describe() for CA certificate' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $ca = Genesis::Secret::X509->new('path/ca',
		is_ca => 1,
		base_path => 'env/'
	);

	my $desc = $ca->describe;
	like($desc, qr/X\.509/i, "describe includes X.509");
	like($desc, qr/CA/i, "describe includes CA indicator");
};

subtest 'describe() for self-signed certificate' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $self_signed = Genesis::Secret::X509->new('path/cert',
		names => ['example.com'],
		self_signed => 1  # This is set by processing, not kit definition
	);

	my $desc = $self_signed->describe;
	like($desc, qr/self-signed/i, "describe includes self-signed");
};

subtest 'describe() for explicitly self-signed' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# self_signed = 2 means explicitly requested self-signed (not just missing CA)
	my $explicit = Genesis::Secret::X509->new('path/cert',
		names => ['example.com'],
		self_signed => 2
	);

	my $desc = $explicit->describe;
	like($desc, qr/explicitly.*self-signed/i, "describe shows explicitly self-signed");
};

# ------------------------------------------------------------------------------
# vault_operator() generates the (( vault ... )) spruce operator strings.
# X509 certificates have three components: certificate, private key, and CA.
# ------------------------------------------------------------------------------

subtest 'vault_operator with specific keys' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::X509->new('my/secret',
		names => ['example.com'],
		self_signed => 1  # Avoids needing a CA lookup
	);

	# Certificate
	my $cert_op = $secret->vault_operator('certificate');
	like($cert_op, qr/vault/, "certificate vault_operator contains 'vault'");
	like($cert_op, qr/my\/secret:certificate/, "certificate vault_operator has :certificate");

	# Private key - accepts 'private_key' or 'key' aliases
	my $key_op = $secret->vault_operator('private_key');
	like($key_op, qr/my\/secret:key/, "private_key vault_operator has :key");

	my $key_alias = $secret->vault_operator('key');
	like($key_alias, qr/my\/secret:key/, "key alias vault_operator has :key");

	# CA for self-signed returns certificate
	my $ca_op = $secret->vault_operator('ca');
	like($ca_op, qr/my\/secret:certificate/, "self-signed ca vault_operator returns certificate");
};

subtest 'vault_operator without key returns hash' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::X509->new('my/secret',
		names => ['example.com'],
		self_signed => 1
	);

	my $ops = $secret->vault_operator;
	is(ref($ops), 'HASH', "vault_operator() without key returns hash");
	ok(exists $ops->{certificate}, "hash has certificate");
	ok(exists $ops->{private_key}, "hash has private_key");
	ok(exists $ops->{ca}, "hash has ca");
	like($ops->{certificate}, qr/:certificate/, "certificate operator correct");
	like($ops->{private_key}, qr/:key/, "private_key operator correct");
};

subtest 'vault_operator with invalid key dies' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::X509->new('my/secret',
		names => ['example.com'],
		self_signed => 1
	);

	my $error;
	eval {
		$secret->vault_operator('invalid_key');
	};
	$error = $@;

	ok($error, "vault_operator with invalid key dies");
	like($error, qr/Invalid key/i, "error mentions invalid key");
};

subtest 'vault_operator ca with absolute signed_by path' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# When signed_by is an absolute path, vault_operator can resolve it
	# without needing Plan (no $self->ca call needed)
	my $secret = Genesis::Secret::X509->new('my/secret',
		names => ['example.com'],
		signed_by => '/absolute/ca/path'
	);

	my $ca_op = $secret->vault_operator('ca');
	like($ca_op, qr/vault/, "ca vault_operator contains 'vault'");
	like($ca_op, qr/\/absolute\/ca\/path:certificate/, "ca vault_operator uses absolute path");
};

# ------------------------------------------------------------------------------
# _required_value_keys defines what vault keys must be present. Regular certs
# need certificate, combined, key. CAs additionally need crl and serial.
# ------------------------------------------------------------------------------

subtest '_required_value_keys for regular cert' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::X509->new('path/cert', names => ['example.com']);
	my @keys = $secret->_required_value_keys;
	cmp_deeply([sort @keys], [sort qw/certificate combined key/],
		"regular cert requires certificate, combined, key");
};

subtest '_required_value_keys for CA cert' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $ca = Genesis::Secret::X509->new('path/ca',
		is_ca => 1,
		base_path => 'env/'
	);
	my @keys = $ca->_required_value_keys;
	cmp_deeply([sort @keys], [sort qw/certificate combined key crl serial/],
		"CA cert additionally requires crl and serial");
};

# ------------------------------------------------------------------------------
# check_value() verifies all required keys are present in the stored value.
# Uses _required_value_keys to determine what must exist.
# ------------------------------------------------------------------------------

subtest 'check_value for missing value' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::X509->new('path/cert', names => ['example.com']);

	# No value set
	my ($status) = $secret->check_value;
	is($status, 'missing', "check_value returns 'missing' for empty secret");

	# Partial value - missing key
	$secret->set_value({certificate => 'cert', combined => 'combined'}, in_sync => 1);
	($status, my $msg) = $secret->check_value;
	is($status, 'missing', "check_value returns 'missing' when key is missing");
	like($msg, qr/:key/, "message mentions missing key");
};

subtest 'check_value with all required keys' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::X509->new('path/cert', names => ['example.com']);

	$secret->set_value({
		certificate => 'cert-data',
		key => 'key-data',
		combined => 'cert+key'
	}, in_sync => 1);
	my ($status) = $secret->check_value;
	is($status, 'ok', "check_value returns 'ok' when all keys present");
};

subtest 'check_value for CA with all required keys' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $ca = Genesis::Secret::X509->new('path/ca',
		is_ca => 1,
		base_path => 'env/'
	);

	# CA needs crl and serial too
	$ca->set_value({
		certificate => 'cert-data',
		key => 'key-data',
		combined => 'cert+key',
		crl => 'crl-data',
		serial => 'serial-data'
	}, in_sync => 1);
	my ($status) = $ca->check_value;
	is($status, 'ok', "check_value returns 'ok' for CA with all keys");

	# CA missing crl
	$ca->set_value({
		certificate => 'cert-data',
		key => 'key-data',
		combined => 'cert+key',
		serial => 'serial-data'
	}, in_sync => 1);
	($status, my $msg) = $ca->check_value;
	is($status, 'missing', "CA check_value returns 'missing' when crl is missing");
	like($msg, qr/:crl/, "message mentions missing crl key");
};

# ------------------------------------------------------------------------------
# ordered() tracks whether the secret has been properly ordered in the
# processing queue (X509 certs must be processed after their signing CAs).
# ------------------------------------------------------------------------------

subtest 'ordered() method' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::X509->new('path/cert', names => ['example.com']);

	# Initially not ordered
	is($secret->ordered, 0, "initially not ordered");

	# Set ordered
	$secret->ordered(1);
	is($secret->ordered, 1, "ordered set to 1");

	# Any truthy value becomes 1
	$secret->ordered("yes");
	is($secret->ordered, 1, "truthy value becomes 1");

	# Falsy value becomes 0
	$secret->ordered(0);
	is($secret->ordered, 0, "falsy value becomes 0");

	$secret->ordered('');
	is($secret->ordered, 0, "empty string becomes 0");
};

# ------------------------------------------------------------------------------
# _key_usage_types returns the list of valid key usage strings that can be
# specified in the 'usage' definition option.
# ------------------------------------------------------------------------------

subtest '_key_usage_types' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my @types = Genesis::Secret::X509::_key_usage_types();
	ok(scalar(@types) > 0, "_key_usage_types returns values");

	# Check for expected usage types
	my %types_hash = map {$_ => 1} @types;
	ok($types_hash{server_auth}, "includes server_auth");
	ok($types_hash{client_auth}, "includes client_auth");
	ok($types_hash{key_cert_sign}, "includes key_cert_sign");
	ok($types_hash{crl_sign}, "includes crl_sign");
	ok($types_hash{code_signing}, "includes code_signing");
	ok($types_hash{digital_signature}, "includes digital_signature");
};

# ------------------------------------------------------------------------------
# _expected_usage returns the expected key usage based on definition or
# defaults. CAs have different defaults than regular certificates.
# ------------------------------------------------------------------------------

subtest '_expected_usage for regular cert' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# Without explicit usage, gets defaults
	my $default = Genesis::Secret::X509->new('path/cert', names => ['example.com']);
	my ($usage, $desc, $type) = $default->_expected_usage;
	cmp_deeply($usage, bag(qw/server_auth client_auth/),
		"default usage includes server_auth and client_auth");
	like($desc, qr/Default/i, "description mentions default");

	# With explicit usage
	my $explicit = Genesis::Secret::X509->new('path/cert',
		names => ['example.com'],
		usage => ['code_signing']
	);
	($usage, $desc, $type) = $explicit->_expected_usage;
	cmp_deeply($usage, ['code_signing'], "explicit usage returned");
	like($desc, qr/Specified/i, "description mentions specified");
};

subtest '_expected_usage for CA cert' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $ca = Genesis::Secret::X509->new('path/ca',
		is_ca => 1,
		base_path => 'env/'
	);
	my ($usage, $desc, $type) = $ca->_expected_usage;
	cmp_deeply($usage, bag(qw/server_auth client_auth crl_sign key_cert_sign/),
		"CA default usage includes cert signing capabilities");
	like($desc, qr/Default.*CA/i, "description mentions CA default");
};

subtest '_expected_usage with empty array' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $no_usage = Genesis::Secret::X509->new('path/cert',
		names => ['example.com'],
		usage => []
	);
	my ($usage, $desc, $type) = $no_usage->_expected_usage;
	is_deeply($usage, [], "empty usage array preserved");
	like($desc, qr/No key usage/i, "description mentions no key usage");
};

# ------------------------------------------------------------------------------
# Verify X509 properly inherits base class functionality for path handling,
# source tracking (kit vs manifest), and definition accessors.
# ------------------------------------------------------------------------------

subtest 'inherits base class functionality' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::X509->new('test/path/cert',
		names => ['example.com'],
		_feature => 'tls-feature'
	);

	# Path accessor
	is($secret->path, 'test/path/cert', "path() works");

	# Source tracking
	is($secret->source, 'kit', "source() works");
	ok($secret->from_kit, "from_kit() works");
	is($secret->feature, 'tls-feature', "feature() works");

	# Definition accessors
	ok($secret->has('names'), "has() works");
	cmp_deeply($secret->get('names'), ['example.com'], "get() works");
};

subtest 'value handling' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::X509->new('path/cert', names => ['example.com']);

	# No value initially
	ok(!$secret->has_value, "no value initially");

	# Set value
	$secret->set_value({
		certificate => 'cert',
		key => 'key',
		combined => 'both'
	}, in_sync => 1);
	ok($secret->has_value, "has_value after set");
	is($secret->value->{certificate}, 'cert', "certificate value accessible");

	# Reset
	$secret->reset;
	ok(!$secret->has_value, "no value after reset");
};

# ------------------------------------------------------------------------------
# Test that the class properly initializes the signed and ordered flags
# that are used during secret processing.
# ------------------------------------------------------------------------------

subtest 'initialization of processing flags' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::X509->new('path/cert', names => ['example.com']);

	# These flags are initialized by new() for processing
	is($secret->{signed}, 0, "signed flag initialized to 0");
	is($secret->{ordered}, 0, "ordered flag initialized to 0");
};

done_testing;
