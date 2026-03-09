#!/usr/bin/env perl
use strict;
use warnings;

use lib 'lib';
use Test::More;
use Test::Deep;

plan tests => 18;

use_ok 'Boolean';

subtest 'basic object creation' => sub {
	plan tests => 5;

	my $true  = Boolean->true;
	my $false = Boolean->false;

	isa_ok $true,  'Boolean', 'true() returns Boolean object';
	isa_ok $false, 'Boolean', 'false() returns Boolean object';

	# Test singleton behavior
	is Boolean->true,  $true,  'true() returns same singleton';
	is Boolean->false, $false, 'false() returns same singleton';

	# Test that they are different objects
	isnt $true, $false, 'true and false are different objects';
};

subtest 'boolean context overloading' => sub {
	plan tests => 4;

	my $true  = Boolean->true;
	my $false = Boolean->false;

	ok $true,  'true object is truthy in boolean context';
	ok !$false, 'false object is falsy in boolean context';

	# Test in conditional expressions
	my $result;
	$result = $true  ? 'yes' : 'no';
	is $result, 'yes', 'true object works in ternary operator';

	$result = $false ? 'yes' : 'no';
	is $result, 'no', 'false object works in ternary operator';
};

subtest 'equality and negation operator overloading' => sub {
	plan tests => 17;

	my $true  = Boolean->true;
	my $false = Boolean->false;

	my $not_true  = !$true;
	my $not_false = !$false;

	isa_ok $not_true,  'Boolean', '!true returns Boolean object';
	isa_ok $not_false, 'Boolean', '!false returns Boolean object';

	is $not_true,  $false, '!true equals false';
	is $not_false, $true,  '!false equals true';

	# Test double negation
	is !!$true,  $true,  '!!true equals true';
	is !!$false, $false, '!!false equals false';

	ok $not_true == $false, 'negation of true is false';
	ok $not_true != $true, 'negation of true is not true';

	ok $false eq 'false', 'false object equals "false" string';
	ok $true eq 'true', 'true object equals "true" string';
	ok $true ne 'false', 'true object does not equal "false" string';
	ok $false ne 'true', 'false object does not equal "true" string';
	ok $true == 1, 'true object equals 1 in numeric context';
	ok $false == 0, 'false object equals 0 in numeric context';
	ok $true == 47, 'true object does equal 47 in numeric context';
	ok $true != 0, 'true object does not equal 0 in numeric context';
	ok $false != 47, 'false object does not equal 47 in numeric context';

};

subtest 'string and numeric context overloading' => sub {
	plan tests => 10;

	my $true  = Boolean->true;
	my $false = Boolean->false;

	is "$true",  'true',  'true object stringifies to "true"';
	is "$false", 'false', 'false object stringifies to "false"';
	is sprintf('%d',$true),  1, 'true object converts to 1 in numeric context';
	is sprintf('%d',$false), 0, 'false object converts to 0 in numeric context';

	# Test string concatenation
	is $true . ' value',  'true value',  'true object concatenates correctly';
	is $false . ' value', 'false value', 'false object concatenates correctly';

	# Test numeric operations
	is $true + 5,  6, 'true object works in addition';
	is $false + 5, 5, 'false object works in addition';
	is $true * 10, 10, 'true object works in multiplication';
	is $false * 10, 0, 'false object works in multiplication';
};

subtest 'to_str method' => sub {
	plan tests => 14;

	my $true  = Boolean->true;
	my $false = Boolean->false;

	# Default string conversion
	is $true->to_str(),  'true',  'true->to_str() returns "true"';
	is $false->to_str(), 'false', 'false->to_str() returns "false"';

	# Custom string conversion
	is $true->to_str('YES', 'NO'),  'YES', 'true->to_str with custom values';
	is $false->to_str('YES', 'NO'), 'NO',  'false->to_str with custom values';

	# Test auto-derivation with single argument
	is $true->to_str('yes'),   'yes', 'true->to_str auto-derives from registered pairs';
	is $false->to_str('yes'),  'no',  'false->to_str uses auto-derived counterpart';

	is $true->to_str('on'),    'on',  'true->to_str with "on"';
	is $false->to_str('on'),   'off', 'false->to_str auto-derives "off"';

	# Test case preservation
	is $true->to_str('YES'),   'YES', 'true->to_str preserves uppercase';
	is $false->to_str('YES'),  'NO',  'false->to_str preserves uppercase in counterpart';

	is $true->to_str('On'),    'On',  'true->to_str preserves mixed case';
	is $false->to_str('On'),   'Off', 'false->to_str preserves mixed case in counterpart';

	# Test fallback for unknown values
	is $true->to_str('unknown'),  'unknown', 'true->to_str with unknown value';
	is $false->to_str('unknown'), 'false',   'false->to_str falls back to "false" for unknown';
};

subtest 'to_i method' => sub {
	plan tests => 4;

	my $true  = Boolean->true;
	my $false = Boolean->false;

	is $true->to_i(),  1, 'true->to_i() returns 1';
	is $false->to_i(), 0, 'false->to_i() returns 0';

	# Test that return values are numeric
	ok $true->to_i() == 1,  'true->to_i() is numerically equal to 1';
	ok $false->to_i() == 0, 'false->to_i() is numerically equal to 0';
};

subtest 'to_json method' => sub {
	plan tests => 8;

	my $true  = Boolean->true;
	my $false = Boolean->false;

	# Test that to_json returns JSON::PP::Boolean objects
	my $json_true  = $true->to_json();
	my $json_false = $false->to_json();

	isa_ok $json_true,  'JSON::PP::Boolean', 'true->to_json() returns JSON::PP::Boolean';
	isa_ok $json_false, 'JSON::PP::Boolean', 'false->to_json() returns JSON::PP::Boolean';

	# Test that they have correct boolean values
	ok $json_true,  'JSON true value is truthy';
	ok !$json_false, 'JSON false value is falsy';

	# Test that they stringify correctly for JSON
	is "$json_true",  1,  'JSON true value stringifies to 1 outside encoding context';
	is "$json_false", 0, 'JSON false value stringifies to 0 outside encoding context';

	# Test JSON serialization if JSON::PP is available
	eval {
		require JSON::PP;
		my $json = JSON::PP->new;
		my $data = {
			success => $json_true,
			failure => $json_false,
		};
		my $serialized = $json->encode($data);
		like $serialized, qr/"success":true/, 'JSON serialization produces true boolean';
		like $serialized, qr/"failure":false/, 'JSON serialization produces false boolean';
	};
	if ($@) {
		skip "JSON::PP not available for serialization test", 2;
	}
};

subtest 'parse method - boolean objects' => sub {
	plan tests => 2;

	my $true  = Boolean->true;
	my $false = Boolean->false;

	# Parsing existing Boolean objects should return same object
	is Boolean->parse($true),  $true,  'parse(true_obj) returns same object';
	is Boolean->parse($false), $false, 'parse(false_obj) returns same object';
};

subtest 'parse method - truthy string values' => sub {
	plan tests => 60; # 20 values * 3 tests each (original + case insensitive)

	my @true_values = qw(y yes on true t 1 ok good pass up hi high start open enable enabled active show shown verbose);

	for my $value (@true_values) {
		my $parsed = Boolean->parse($value);
		isa_ok $parsed, 'Boolean', "parse('$value') returns Boolean object";
		is $parsed, Boolean->true, "parse('$value') returns true object";

		# Test case insensitive
		my $upper_parsed = Boolean->parse(uc($value));
		is $upper_parsed, Boolean->true, "parse('" . uc($value) . "') returns true object";
	}
};

subtest 'parse method - falsy string values' => sub {
	plan tests => 42; # 20 false values * 2 tests each + 2 tests for undef

	my @false_values = qw(n no off false f 0 error bad fail down lo low stop closed disable disabled inactive hide hidden quiet);

	for my $value (@false_values) {
		my $parsed = Boolean->parse($value);
		isa_ok $parsed, 'Boolean', "parse('$value') returns Boolean object";
		is $parsed, Boolean->false, "parse('$value') returns false object";
	}

	# Test undefined value
	my $parsed = Boolean->parse(undef);
	isa_ok $parsed, 'Boolean', 'parse(undef) returns Boolean object';
	is $parsed, Boolean->false, 'parse(undef) returns false object';
};

subtest 'parse method - other string values' => sub {
	plan tests => 9; # 4 unknown strings + 5 numeric values

	my @other_values = qw(maybe perhaps sometimes random_string);

	for my $value (@other_values) {
		my $parsed = Boolean->parse($value);
		is $parsed, undef, "parse('$value') returns undef (unknown strings return undef)";
	}

	# Test numeric values
	is Boolean->parse(123), Boolean->true, 'parse(123) returns true';
	is Boolean->parse(-1), Boolean->true, 'parse(-1) returns true';
	is Boolean->parse(0), Boolean->false, 'parse(0) returns false';
	is Boolean->parse(3.14), Boolean->true, 'parse(3.14) returns true';
	is Boolean->parse(0.0), Boolean->false, 'parse(0.0) returns false';
};

subtest 'parse method - array and hash references' => sub {
	plan tests => 10;

	my $populated_array_ref = [1, 2, 3];
	my $empty_array_ref     = [];

	is Boolean->parse($populated_array_ref), Boolean->true, 'parse(populated_array_ref) returns true';
	is Boolean->parse($empty_array_ref),     Boolean->false, 'parse(empty_array_ref) returns false';

	# Test edge cases
	is Boolean->parse([undef]), Boolean->true, 'parse(array_ref_with_undef) returns true';

	my $populated_hash_ref = { key => 'value' };
	my $empty_hash_ref     = {};

	is Boolean->parse($populated_hash_ref), Boolean->true, 'parse(populated_hash_ref) returns true';
	is Boolean->parse($empty_hash_ref),     Boolean->false, 'parse(empty_hash_ref) returns false';

	# Test edge cases
	is Boolean->parse({ key => undef }), Boolean->true, 'parse(hash_ref_with_undef_value) returns true';

	my $mixed_array_ref = [undef, 0, ''];
	my $mixed_hash_ref  = { key1 => undef, key2 => 0 };

	is Boolean->parse($mixed_array_ref), Boolean->true, 'parse(mixed_array_ref) returns true';
	is Boolean->parse($mixed_hash_ref),  Boolean->true, 'parse(mixed_hash_ref) returns true';

	# Test completely empty references
	is Boolean->parse([]), Boolean->false, 'parse(completely_empty_array_ref) returns false';
	is Boolean->parse({}), Boolean->false, 'parse(completely_empty_hash_ref) returns false';
};

# Define custom packages for testing
{
	package CustomArray;
	use v5.20;
	use warnings;
	sub new { my ($class, @elements) = @_; return bless \@elements, $class; }
	sub size { return scalar @{$_[0]}; }
}

{
	package CustomHash;
	use v5.20;
	use warnings;
	sub new { my ($class, %elements) = @_; return bless \%elements, $class; }
	sub empty { return !keys %{$_[0]}; }
}

{
	package CustomObject;
	use v5.20;
	use warnings;
	sub new { my ($class, $value) = @_; return bless {value => $value}, $class; }
	sub is_true { return $_[0]->{value} ? 1 : 0; }
	sub is_false { return $_[0]->{value} ? 0 : 1; }
}

# Test instances of custom packages with parse
subtest 'parse method - custom object values' => sub {
	plan tests => 6;

	my $custom_array = CustomArray->new(1, 2, 3);
	my $custom_hash  = CustomHash->new(key => 'value');
	my $custom_object = CustomObject->new(1);

	is Boolean->parse($custom_array), Boolean->true, 'parse(custom_array) returns true';
	is Boolean->parse($custom_hash),  Boolean->true, 'parse(custom_hash) returns true';
	is Boolean->parse($custom_object), Boolean->true, 'parse(custom_object) returns true';

	my $empty_array = CustomArray->new();
	my $empty_hash  = CustomHash->new();
	my $empty_object = CustomObject->new(0);

	is Boolean->parse($empty_array), Boolean->false, 'parse(empty_array) returns false';
	is Boolean->parse($empty_hash),  Boolean->false, 'parse(empty_hash) returns false';
	is Boolean->parse($empty_object), Boolean->false, 'parse(empty_object) returns false';
};

subtest 'singleton protection' => sub {
	plan tests => 4;

	my $true  = Boolean->true;
	my $false = Boolean->false;

	# Test that we cannot modify the underlying scalar values
	# This should not crash or change the boolean value
	eval { ${$true} = 0; };
	ok $@, 'attempting to modify true singleton throws error';

	eval { ${$false} = 1; };
	ok $@, 'attempting to modify false singleton throws error';

	# Verify the values are still correct
	ok $true,  'true object still true after modification attempt';
	ok !$false, 'false object still false after modification attempt';
};

subtest 'complex usage scenarios' => sub {
	plan tests => 8;

	# Test JSON-style output
	my $config = {
		debug   => Boolean->parse('yes'),
		verbose => Boolean->parse('no'),
		enabled => Boolean->parse(1),
	};

	is $config->{debug}->to_str('true', 'false'),   'true',  'JSON-style true output';
	is $config->{verbose}->to_str('true', 'false'), 'false', 'JSON-style false output';
	is $config->{enabled}->to_str('true', 'false'), 'true',  'JSON-style enabled output';

	# Test configuration-style output
	my $settings = join(', ', map {
		sprintf('%s=%s', $_, $config->{$_}->to_str('ON', 'OFF'))
	} sort keys %$config);

	is $settings, 'debug=ON, enabled=ON, verbose=OFF', 'configuration-style output';

	# Test arithmetic operations
	my $count = $config->{debug} + $config->{verbose} + $config->{enabled};
	is $count, 2, 'arithmetic operations work correctly';

	# Test with mixed parsing and output
	Boolean->register_pair('connected', 'disconnected');

	my @test_values = qw(yes connected disconnected active error disabled);
	my @results;

	for my $value (@test_values) {
		my $bool = Boolean->parse($value);
		push @results, $bool->to_str('ON', 'OFF');
	}

	is_deeply \@results, [qw/ON ON OFF ON OFF OFF/], 'complex parsing and output scenario';

	# Test case preservation in custom pairs
	my $bool = Boolean->true;
	is $bool->to_str('Connected'), 'Connected', 'case preserved in custom true value';

	$bool = Boolean->false;
	is $bool->to_str('Connected'), 'Disconnected', 'case preserved in auto-derived false value';
};

subtest 'edge cases and error conditions' => sub {
	plan tests => 7;

	# Test with various edge case values
	is Boolean->parse(''),     Boolean->false, 'parse(empty_string) returns false';
	is Boolean->parse('0.0'),  Boolean->false, 'parse(0.0) returns false (numeric zero)';
	is Boolean->parse(' yes '), undef, 'parse with whitespace returns undef (exact match required)';

	# Test case sensitivity works correctly for known values
	is Boolean->parse('True'),  Boolean->true,  'parse(True) returns true (mixed case)';
	is Boolean->parse('False'), Boolean->false, 'parse(False) returns false (mixed case)';
	is Boolean->parse('YES'),   Boolean->true,  'parse(YES) returns true (uppercase)';
	is Boolean->parse('no'),    Boolean->false, 'parse(no) returns false (lowercase)';
};

subtest 'register_pair functionality' => sub {
	plan tests => 10;

	# Register custom pairs
	Boolean->register_pair('online', 'offline');
	Boolean->register_pair('valid', 'invalid');

	# Test parsing works with custom pairs
	is Boolean->parse('online'),  Boolean->true,  'parse custom true value';
	is Boolean->parse('offline'), Boolean->false, 'parse custom false value';
	is Boolean->parse('valid'),   Boolean->true,  'parse custom true value';
	is Boolean->parse('invalid'), Boolean->false, 'parse custom false value';

	# Test case insensitive
	is Boolean->parse('ONLINE'),  Boolean->true,  'parse custom true value (uppercase)';
	is Boolean->parse('Invalid'), Boolean->false, 'parse custom false value (mixed case)';

	# Test auto-derivation in to_str
	my $bool = Boolean->true;
	is $bool->to_str('online'), 'online', 'custom pair auto-derives in to_str';

	$bool = Boolean->false;
	is $bool->to_str('online'), 'offline', 'custom pair auto-derives false value';

	# Test case preservation in custom pairs
	$bool = Boolean->true;
	is $bool->to_str('Online'), 'Online', 'case preserved in custom true value';

	$bool = Boolean->false;
	is $bool->to_str('Online'), 'Offline', 'case preserved in auto-derived false value';
};

done_testing;
