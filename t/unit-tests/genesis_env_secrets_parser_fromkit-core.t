#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;

# Test Genesis::Env::Secrets::Parser::FromKit
# Validates parsing of kit metadata into Genesis::Secret objects

use_ok 'Genesis::Env::Secrets::Parser::FromKit';
use_ok 'Genesis::Secret::Invalid';

# Minimal mock environment — provides features() and dereferenced_kit_metadata()
{
	package MockEnv;
	sub new {
		my ($class, %opts) = @_;
		bless {
			features => $opts{features} || [],
			metadata => $opts{metadata} || {},
		}, $class;
	}
	sub features { @{$_[0]{features}} }
	sub dereferenced_kit_metadata { $_[0]{metadata} }
}

# Helper: parse metadata with features, return list of secrets
sub parse_metadata {
	my ($metadata, @features) = @_;
	my $parser = Genesis::Env::Secrets::Parser::FromKit->new(undef);
	return $parser->parse(
		kit_metadata => $metadata,
		features     => \@features,
	);
}

# Helper: parse and return only Invalid secrets
sub parse_invalid {
	my ($metadata, @features) = @_;
	return grep { $_->isa('Genesis::Secret::Invalid') } parse_metadata($metadata, @features);
}

subtest 'FWT-687: features defaulting does not have dead code' => sub {
	# This is a code-review regression test — verify parse() works
	# with a mock environment that returns an empty features list
	my $env = MockEnv->new(
		features => [],
		metadata => {
			credentials => {
				base => {
					'test/path' => 'ssh 2048',
				},
			},
		},
	);
	my $parser = Genesis::Env::Secrets::Parser::FromKit->new($env);
	my @secrets = $parser->parse();
	is(scalar @secrets, 1, "parse() works with empty features list from env");
	ok($secrets[0]->valid, "produced secret is valid");
};

subtest 'FWT-685: unrecognized credential key uses correct subject label' => sub {
	my @secrets = parse_metadata({
		credentials => {
			base => {
				'test/path' => {
					mykey => 'bogus_value',
				},
			},
		},
	});

	is(scalar @secrets, 1, "one secret returned");
	isa_ok($secrets[0], 'Genesis::Secret::Invalid');
	is($secrets[0]->get('subject'), 'Credential',
		"subject is 'Credential', not 'Random'");

	my $desc = $secrets[0]->describe;
	like($desc, qr/Unrecognized credential format/i,
		"error message says 'Unrecognized credential format'");
	unlike($desc, qr/Bad generate-password/,
		"error message does NOT say 'Bad generate-password'");
};

subtest 'FWT-682: parse_provided does not mutate caller metadata' => sub {
	my $metadata = {
		provided => {
			base => {
				'test/path' => {
					keys => {
						username => { prompt => 'Enter username' },
					},
				},
			},
		},
	};

	# Capture state before parse
	ok(!exists $metadata->{provided}{base}{'test/path'}{type},
		"type key does not exist before parse");

	my @secrets = parse_metadata($metadata);

	# After parse, the original metadata should be unmodified
	ok(!exists $metadata->{provided}{base}{'test/path'}{type},
		"type key still does not exist after parse — no mutation");

	# The parse should still work correctly
	is(scalar @secrets, 1, "one secret produced");
	ok($secrets[0]->valid, "secret is valid");
	isa_ok($secrets[0], 'Genesis::Secret::UserProvided');
};

subtest 'FWT-684: path-level random/uuid produce specific error messages' => sub {
	my @secrets = parse_metadata({
		credentials => {
			base => {
				'test/random-path' => 'random 32',
				'test/uuid-path'   => 'uuid v4',
			},
		},
	});

	is(scalar @secrets, 2, "two invalid secrets returned");

	# Find the random one
	my ($random_inv) = grep { $_->path =~ /random-path/ } @secrets;
	isa_ok($random_inv, 'Genesis::Secret::Invalid');
	my $rdesc = $random_inv->describe;
	like($rdesc, qr/per key in a hashmap/i,
		"random path-level error gives specific guidance");
	unlike($rdesc, qr/Unrecognized request/,
		"random path-level error does NOT give generic message");

	# Find the uuid one
	my ($uuid_inv) = grep { $_->path =~ /uuid-path/ } @secrets;
	isa_ok($uuid_inv, 'Genesis::Secret::Invalid');
	my $udesc = $uuid_inv->describe;
	like($udesc, qr/per key in a hashmap/i,
		"uuid path-level error gives specific guidance");
	unlike($udesc, qr/Unrecognized request/,
		"uuid path-level error does NOT give generic message");
};

subtest 'FWT-683: bare ssh/rsa without size defaults to 2048' => sub {
	my @secrets = parse_metadata({
		credentials => {
			base => {
				'test/ssh-bare' => 'ssh',
				'test/rsa-bare' => 'rsa',
				'test/ssh-sized' => 'ssh 4096',
				'test/rsa-fixed' => 'rsa 1024 fixed',
			},
		},
	});

	is(scalar @secrets, 4, "four secrets returned");

	# Bare ssh → SSH with default size 2048
	my ($ssh_bare) = grep { $_->path eq 'test/ssh-bare' } @secrets;
	ok($ssh_bare->valid, "bare 'ssh' produces a valid secret");
	isa_ok($ssh_bare, 'Genesis::Secret::SSH');
	is($ssh_bare->get('size'), 2048, "bare 'ssh' defaults to size 2048");

	# Bare rsa → RSA with default size 2048
	my ($rsa_bare) = grep { $_->path eq 'test/rsa-bare' } @secrets;
	ok($rsa_bare->valid, "bare 'rsa' produces a valid secret");
	isa_ok($rsa_bare, 'Genesis::Secret::RSA');
	is($rsa_bare->get('size'), 2048, "bare 'rsa' defaults to size 2048");

	# ssh with explicit size still works
	my ($ssh_sized) = grep { $_->path eq 'test/ssh-sized' } @secrets;
	ok($ssh_sized->valid, "'ssh 4096' produces a valid secret");
	is($ssh_sized->get('size'), 4096, "'ssh 4096' has size 4096");

	# rsa with fixed flag still works
	my ($rsa_fixed) = grep { $_->path eq 'test/rsa-fixed' } @secrets;
	ok($rsa_fixed->valid, "'rsa 1024 fixed' produces a valid secret");
	is($rsa_fixed->get('size'), 1024, "'rsa 1024 fixed' has size 1024");
	is($rsa_fixed->get('fixed'), 1, "'rsa 1024 fixed' has fixed=1");
};

subtest 'FWT-681 Cat1: undefined data returns empty list, not bare next' => sub {
	# Test that each parser method returns () when data is undef,
	# rather than using bare next which escapes the subroutine scope

	my $parser = Genesis::Env::Secrets::Parser::FromKit->new(undef);

	# _parse_x509_secret_definition with undef data
	my @x509 = $parser->_parse_x509_secret_definition('test/path', undef, 'base');
	is(scalar @x509, 0, "_parse_x509_secret_definition returns empty list for undef data");

	# _parse_x509_subpaths with undef subdata
	my @subpaths = $parser->_parse_x509_subpaths('test/path', 'ca', undef, 'base');
	is(scalar @subpaths, 0, "_parse_x509_subpaths returns empty list for undef subdata");

	# _parse_provided_secret_definition with undef data
	my @provided = $parser->_parse_provided_secret_definition('test/path', undef, 'base');
	is(scalar @provided, 0, "_parse_provided_secret_definition returns empty list for undef data");

	# _parse_credential_definition with undef data
	my @creds = $parser->_parse_credential_definition('test/path', undef, 'base');
	is(scalar @creds, 0, "_parse_credential_definition returns empty list for undef data");
};

subtest 'FWT-681 Cat2: _validate_feature_block passes complete args to _invalid_secret' => sub {
	# When a feature block exists but is not a hashref, the resulting
	# Invalid secret should have data and _feature populated
	my @secrets = parse_metadata({
		certificates => {
			base => 'not-a-hash',
		},
	});

	is(scalar @secrets, 1, "one invalid secret produced");
	isa_ok($secrets[0], 'Genesis::Secret::Invalid');

	# Verify the data field is populated (not undef)
	ok(defined($secrets[0]->get('data')),
		"Invalid secret has defined data field");
	is($secrets[0]->get('data'), 'not-a-hash',
		"Invalid secret data contains the actual bad value");

	# Verify the _feature field is populated (not undef)
	ok($secrets[0]->from_kit,
		"Invalid secret has from_kit set (feature is populated)");

	my $desc = $secrets[0]->describe;
	like($desc, qr/base/, "describe() mentions the feature name");
};

subtest 'FWT-681 Cat3: _parse_x509_subpaths does not mutate caller hashref' => sub {
	my $subdata = {
		valid_for => '1y',
		names     => ['server.example.com'],
	};

	my $parser = Genesis::Env::Secrets::Parser::FromKit->new(undef);

	# Parse a 'ca' subpath — this should set is_ca but not mutate $subdata
	$parser->_parse_x509_subpaths('test/certs', 'ca', $subdata, 'base');
	ok(!exists $subdata->{is_ca},
		"caller's hashref not mutated: is_ca not injected");

	# Parse with legacy signed_by — should rewrite but not mutate $subdata
	my $legacy_data = {
		signed_by => 'base.application/certs.ca',
		valid_for => '6m',
	};
	$parser->_parse_x509_subpaths('test/certs', 'server', $legacy_data, 'base');
	is($legacy_data->{signed_by}, 'base.application/certs.ca',
		"caller's hashref not mutated: signed_by not rewritten");
};

subtest 'FWT-686: arbitrary X.509 subpath names are accepted' => sub {
	# Kit authors can use any subpath name — no whitelist restriction
	my @secrets = parse_metadata({
		certificates => {
			base => {
				'test/certs' => {
					ca      => { is_ca => 1, valid_for => '10y' },
					server  => { valid_for => '1y', names => ['srv.example.com'] },
					custom  => { valid_for => '6m', names => ['custom.example.com'] },
				},
			},
		},
	});

	is(scalar @secrets, 3, "three X.509 secrets produced");
	ok($_->valid, $_->path . " is valid") for @secrets;

	my ($custom) = grep { $_->path eq 'test/certs/custom' } @secrets;
	isa_ok($custom, 'Genesis::Secret::X509');
	is($custom->get('valid_for'), '6m', "custom subpath passes through correctly");
};

done_testing;
