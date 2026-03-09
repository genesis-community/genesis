#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::Deep;

# Test Genesis::Secret::Invalid class
# Invalid secrets are created when secret definitions fail validation

use_ok 'Genesis::Secret::Invalid';

subtest 'valid() always returns 0' => sub {
	my $invalid = Genesis::Secret::Invalid->new('test/path:key',
		data => {foo => 'bar'},
		subject => 'Test',
		errors => ['Some error']
	);
	is($invalid->valid, 0, "valid() returns 0");
	ok(!$invalid->valid, "valid() is falsy");
};

subtest 'constructor accepts any options' => sub {
	# Invalid secrets don't validate their definition - they store whatever was passed
	my $invalid = Genesis::Secret::Invalid->new('path:key',
		arbitrary => 'value',
		random_stuff => [1, 2, 3],
		nested => {a => {b => 'c'}}
	);
	isa_ok($invalid, 'Genesis::Secret::Invalid');
	is($invalid->get('arbitrary'), 'value', "arbitrary option stored");
	cmp_deeply($invalid->get('random_stuff'), [1, 2, 3], "array option stored");
	cmp_deeply($invalid->get('nested'), {a => {b => 'c'}}, "nested option stored");
};

subtest 'type and label' => sub {
	my $invalid = Genesis::Secret::Invalid->new('path:key', subject => 'Test');
	is($invalid->type, 'invalid', "type() returns 'invalid'");
	is($invalid->label, 'Invalid', "label() returns 'Invalid'");
};

subtest 'describe() with hash data' => sub {
	my $invalid = Genesis::Secret::Invalid->new('secret/path:key',
		data => {size => 32, format => 'base64'},
		subject => 'Random',
		errors => ['Missing required field']
	);

	my $desc = $invalid->describe;
	like($desc, qr/Invalid definition/i, "describe() mentions invalid definition");
	like($desc, qr/Random/i, "describe() includes subject");
	like($desc, qr/Missing required field/, "describe() includes error message");
	like($desc, qr/secret\/path/, "describe() includes path");
};

subtest 'describe() with multiple errors' => sub {
	my $invalid = Genesis::Secret::Invalid->new('path:key',
		data => {},
		subject => 'X509',
		errors => ['Error one', 'Error two', 'Error three']
	);

	my $desc = $invalid->describe;
	like($desc, qr/Error one/, "describe() includes first error");
	like($desc, qr/Error two/, "describe() includes second error");
	like($desc, qr/Error three/, "describe() includes third error");
};

subtest 'describe() with undefined data' => sub {
	my $invalid = Genesis::Secret::Invalid->new('path:key',
		subject => 'Unknown',
		errors => ['No data provided']
	);

	my $desc = $invalid->describe;
	like($desc, qr/undefined/i, "describe() shows undefined for missing data");
};

subtest 'describe() list context' => sub {
	my $invalid = Genesis::Secret::Invalid->new('my/path:key',
		data => {test => 1},
		subject => 'Test Subject',
		errors => ['Test error']
	);

	my @parts = $invalid->describe;
	is($parts[0], 'my/path:key', "first element is path");
	is($parts[1], 'Invalid', "second element is label");
	ok(defined($parts[2]), "third element is message");
};

subtest 'describe() with kit source' => sub {
	my $invalid = Genesis::Secret::Invalid->new('path:key',
		data => {},
		subject => 'Test',
		errors => ['Error'],
		_feature => 'my-feature'
	);

	my $desc = $invalid->describe;
	like($desc, qr/my-feature/, "describe() includes feature name");
	like($desc, qr/kit\.yml/i, "describe() mentions kit.yml");
};

subtest 'describe() with manifest source' => sub {
	my $invalid = Genesis::Secret::Invalid->new('path:key',
		data => {},
		subject => 'Test',
		errors => ['Error'],
		_ch_name => 'my.variable'
	);

	my $desc = $invalid->describe;
	like($desc, qr/my\.variable/, "describe() includes variable name");
	like($desc, qr/manifest/i, "describe() mentions manifest");
};

subtest 'inherits base class accessors' => sub {
	my $invalid = Genesis::Secret::Invalid->new('test/path:value',
		data => {key => 'val'},
		subject => 'Test',
		errors => ['err']
	);

	is($invalid->path, 'test/path:value', "path() works");
	ok($invalid->has('data'), "has() works");
	is($invalid->get('subject'), 'Test', "get() works");
};

subtest 'default values for subject and errors' => sub {
	# When subject or errors are not provided, describe() should use defaults
	my $invalid = Genesis::Secret::Invalid->new('path:key', data => {});

	my $desc = $invalid->describe;
	like($desc, qr/Unknown/i, "describe() uses 'Unknown' as default subject");
	like($desc, qr/Invalid secret definition/i, "describe() uses default error message");
};

done_testing;
