#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 't';
use helper;
use Test::More;
use Test::Deep;
use Test::Exception;
use Test::Output;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;

use_ok 'Genesis::UI';

# ---------------------------------------------------------------------------
# prompt_for_list - line mode basic collection
# ---------------------------------------------------------------------------
subtest 'prompt_for_list line mode - collects entries, ends on blank' => sub {
	set_stdin("item1\nitem2\n\n");
	my $result;
	combined_from { $result = prompt_for_list('line', 'Enter items', 'item') };
	reset_stdin();
	isa_ok($result, 'ARRAY', 'returns arrayref');
	is(scalar(@$result), 2, 'collected two items');
	is($result->[0], 'item1', 'first entry is item1');
	is($result->[1], 'item2', 'second entry is item2');
};

# ---------------------------------------------------------------------------
# prompt_for_list - line mode single entry
# ---------------------------------------------------------------------------
subtest 'prompt_for_list line mode - single entry collection' => sub {
	set_stdin("only\n\n");
	my $result;
	combined_from { $result = prompt_for_list('line', 'Enter items', 'item') };
	reset_stdin();
	is(scalar(@$result), 1, 'collected one item');
	is($result->[0], 'only', 'entry is "only"');
};

# ---------------------------------------------------------------------------
# prompt_for_list - line mode empty collection (no min)
# ---------------------------------------------------------------------------
subtest 'prompt_for_list line mode - empty collection when min is 0' => sub {
	set_stdin("\n");
	my $result;
	combined_from { $result = prompt_for_list('line', 'Enter items', 'item') };
	reset_stdin();
	isa_ok($result, 'ARRAY', 'returns arrayref');
	is(scalar(@$result), 0, 'empty list when blank entered immediately');
};

# ---------------------------------------------------------------------------
# prompt_for_list - line mode max enforcement
# ---------------------------------------------------------------------------
subtest 'prompt_for_list line mode - ends automatically at max' => sub {
	# Provide exactly 2 entries - loop exits at max without needing blank
	set_stdin("alpha\nbeta\n");
	my $result;
	combined_from { $result = prompt_for_list('line', 'Enter items', 'item', undef, 2) };
	reset_stdin();
	is(scalar(@$result), 2, 'stops at max=2');
	is($result->[0], 'alpha', 'first item is alpha');
	is($result->[1], 'beta', 'second item is beta');
};

# ---------------------------------------------------------------------------
# prompt_for_list - line mode max=1
# ---------------------------------------------------------------------------
subtest 'prompt_for_list line mode - max=1 collects exactly one item' => sub {
	set_stdin("single\n");
	my $result;
	combined_from { $result = prompt_for_list('line', 'Enter items', 'item', undef, 1) };
	reset_stdin();
	is(scalar(@$result), 1, 'exactly one item collected');
	is($result->[0], 'single', 'item is "single"');
};

# ---------------------------------------------------------------------------
# prompt_for_list - line mode min enforcement
# ---------------------------------------------------------------------------
subtest 'prompt_for_list line mode - min enforcement requires minimum items' => sub {
	# Enter one item, then blank (triggers min=2 error), then second item, then blank
	set_stdin("first\n\nsecond\n\n");
	my $result;
	my $output;
	$output = combined_from { $result = prompt_for_list('line', 'Enter items', 'item', 2) };
	reset_stdin();
	is(scalar(@$result), 2, 'collected 2 items after min enforcement');
	is($result->[0], 'first', 'first item is "first"');
	is($result->[1], 'second', 'second item is "second"');
	like($output, qr/Insufficient items provided/, 'error shown for insufficient items');
};

# ---------------------------------------------------------------------------
# prompt_for_list - line mode min=3 enforcement
# ---------------------------------------------------------------------------
subtest 'prompt_for_list line mode - min=3 shows error until threshold met' => sub {
	# Blank on empty (0 items < 3), provide a, b, blank (2 < 3), provide c, blank (3 >= 3)
	set_stdin("\na\nb\n\nc\n\n");
	my $result;
	my $output;
	$output = combined_from { $result = prompt_for_list('line', 'Enter things', 'thing', 3) };
	reset_stdin();
	is(scalar(@$result), 3, 'collected 3 items after min=3 enforcement');
	like($output, qr/Insufficient items provided/, 'error shown when below min');
};

# ---------------------------------------------------------------------------
# prompt_for_list - max < 1 dies
# ---------------------------------------------------------------------------
subtest 'prompt_for_list - max < 1 dies with expected message' => sub {
	throws_ok {
		prompt_for_list('line', 'Enter items', 'item', undef, 0)
	} qr/Illegal list maximum count specified/, 'max=0 dies with expected message';

	throws_ok {
		prompt_for_list('line', 'Enter items', 'item', undef, -1)
	} qr/Illegal list maximum count specified/, 'max=-1 dies with expected message';
};

# ---------------------------------------------------------------------------
# prompt_for_list - line mode default label
# ---------------------------------------------------------------------------
subtest 'prompt_for_list line mode - default label is "value"' => sub {
	set_stdin("x\n\n");
	my $result;
	my $output;
	$output = combined_from { $result = prompt_for_list('line', 'Enter values') };
	reset_stdin();
	is(scalar(@$result), 1, 'collected one item with default label');
	like($output, qr/value empty to end/, 'default label "value" appears in end prompt');
};

# ---------------------------------------------------------------------------
# prompt_for_list - line mode with ip validation
# ---------------------------------------------------------------------------
subtest 'prompt_for_list line mode - ip validation rejects bad, accepts good' => sub {
	# bad IP then good IP then blank to end
	set_stdin("not-an-ip\n10.0.0.1\n\n");
	my $result;
	combined_from { $result = prompt_for_list('line', 'Enter IPs', 'ip', 0, undef, 'ip') };
	reset_stdin();
	is(scalar(@$result), 1, 'collected one valid IP');
	is($result->[0], '10.0.0.1', 'valid IP accepted after bad one rejected');
};

# ---------------------------------------------------------------------------
# prompt_for_list - line mode with validation, multiple entries
# ---------------------------------------------------------------------------
subtest 'prompt_for_list line mode - validation applies to each entry' => sub {
	# Collect two valid IPs then blank
	set_stdin("192.168.1.1\n10.0.0.2\n\n");
	my $result;
	combined_from { $result = prompt_for_list('line', 'Enter IPs', 'ip', 0, undef, 'ip') };
	reset_stdin();
	is(scalar(@$result), 2, 'collected two valid IPs');
	is($result->[0], '192.168.1.1', 'first IP correct');
	is($result->[1], '10.0.0.2', 'second IP correct');
};

# ---------------------------------------------------------------------------
# prompt_for_list - block mode basic
# ---------------------------------------------------------------------------
subtest 'prompt_for_list block mode - collects multi-line entry' => sub {
	# In block mode each iteration reads all of STDIN until EOF as one block.
	# After reading first block (all stdin), EOF causes __prompt_for_block to
	# return the content.  Then the loop calls __prompt_for_block again on
	# exhausted STDIN, returning "". Since "" eq "", and min=0, loop exits.
	set_stdin("line one\nline two\n");
	my $result;
	combined_from { $result = prompt_for_list('block', 'Enter blocks', 'block') };
	reset_stdin();
	isa_ok($result, 'ARRAY', 'returns arrayref');
	is(scalar(@$result), 1, 'collected one block entry');
	like($result->[0], qr/line one/, 'block content includes first line');
	like($result->[0], qr/line two/, 'block content includes second line');
};

# ---------------------------------------------------------------------------
# code ref validation via prompt_for_line
# ---------------------------------------------------------------------------
subtest 'code ref validation - custom sub returning empty string passes' => sub {
	my $lowercase_only = sub {
		$_[0] =~ /^[a-z]+$/ ? "" : "must be all lowercase letters"
	};

	# Invalid first (uppercase), then valid lowercase
	set_stdin("Hello\nhello\n");
	my $result;
	stderr_from { $result = prompt_for_line(undef, 'Value', undef, $lowercase_only) };
	reset_stdin();
	is($result, 'hello', 'custom validator rejects invalid, accepts valid');
};

# ---------------------------------------------------------------------------
# code ref validation - immediately valid
# ---------------------------------------------------------------------------
subtest 'code ref validation - immediately valid input accepted' => sub {
	my $non_empty_alpha = sub {
		$_[0] =~ /^[a-zA-Z]+$/ ? "" : "letters only"
	};

	set_stdin("world\n");
	my $result;
	stderr_from { $result = prompt_for_line(undef, 'Value', undef, $non_empty_alpha) };
	reset_stdin();
	is($result, 'world', 'valid input accepted immediately by code ref validator');
};

# ---------------------------------------------------------------------------
# code ref validation - custom error message
# ---------------------------------------------------------------------------
subtest 'code ref validation - custom error message surfaced' => sub {
	my $digits_only = sub {
		$_[0] =~ /^\d+$/ ? "" : "digits only please"
	};

	set_stdin("abc\n123\n");
	my $result;
	my $output;
	$output = stderr_from { $result = prompt_for_line(undef, 'Number', undef, $digits_only) };
	reset_stdin();
	is($result, 123, 'digits-only validator accepts numeric string, returned as number');
	like($output, qr/digits only please/, 'custom error message shown for rejection');
};

# ---------------------------------------------------------------------------
# url validation via prompt_for_line
# ---------------------------------------------------------------------------
subtest 'url validation - valid URL accepted' => sub {
	set_stdin("https://example.com\n");
	my $result;
	stderr_from { $result = prompt_for_line(undef, 'URL', undef, 'url') };
	reset_stdin();
	is($result, 'https://example.com', 'valid https URL accepted');
};

# ---------------------------------------------------------------------------
# url validation - http also valid
# ---------------------------------------------------------------------------
subtest 'url validation - http URL accepted' => sub {
	set_stdin("http://example.org/path\n");
	my $result;
	stderr_from { $result = prompt_for_line(undef, 'URL', undef, 'url') };
	reset_stdin();
	is($result, 'http://example.org/path', 'valid http URL with path accepted');
};

# ---------------------------------------------------------------------------
# url validation - invalid then valid
# ---------------------------------------------------------------------------
subtest 'url validation - invalid URL rejected, valid URL accepted' => sub {
	set_stdin("not-a-url\nhttps://valid.example.com\n");
	my $result;
	my $output;
	$output = stderr_from { $result = prompt_for_line(undef, 'URL', undef, 'url') };
	reset_stdin();
	is($result, 'https://valid.example.com', 'invalid URL rejected, valid URL accepted');
	like($output, qr/not a valid URL/i, 'error message shown for invalid URL');
};

# ---------------------------------------------------------------------------
# port validation via prompt_for_line
# ---------------------------------------------------------------------------
subtest 'port validation - valid port 80 accepted as number' => sub {
	set_stdin("80\n");
	my $result;
	stderr_from { $result = prompt_for_line(undef, 'Port', undef, 'port') };
	reset_stdin();
	is($result, 80, 'port 80 accepted');
	ok($result == 80, 'returned as numeric value');
};

# ---------------------------------------------------------------------------
# port validation - boundary: port 0
# ---------------------------------------------------------------------------
subtest 'port validation - port 0 is valid' => sub {
	set_stdin("0\n");
	my $result;
	stderr_from { $result = prompt_for_line(undef, 'Port', undef, 'port') };
	reset_stdin();
	is($result, 0, 'port 0 is accepted');
};

# ---------------------------------------------------------------------------
# port validation - boundary: port 65535
# ---------------------------------------------------------------------------
subtest 'port validation - port 65535 is valid' => sub {
	set_stdin("65535\n");
	my $result;
	stderr_from { $result = prompt_for_line(undef, 'Port', undef, 'port') };
	reset_stdin();
	is($result, 65535, 'port 65535 is accepted');
};

# ---------------------------------------------------------------------------
# port validation - out of range rejected
# ---------------------------------------------------------------------------
subtest 'port validation - out-of-range port rejected' => sub {
	set_stdin("99999\n443\n");
	my $result;
	my $output;
	$output = stderr_from { $result = prompt_for_line(undef, 'Port', undef, 'port') };
	reset_stdin();
	is($result, 443, 'out-of-range 99999 rejected, 443 accepted');
	like($output, qr/not a valid port/, 'error message shown for out-of-range port');
};

# ---------------------------------------------------------------------------
# port validation - negative port rejected
# ---------------------------------------------------------------------------
subtest 'port validation - negative port rejected' => sub {
	set_stdin("-1\n8080\n");
	my $result;
	stderr_from { $result = prompt_for_line(undef, 'Port', undef, 'port') };
	reset_stdin();
	is($result, 8080, 'negative port rejected, valid port accepted');
};

# ---------------------------------------------------------------------------
# bounded numeric validation - "0-65535" range
# ---------------------------------------------------------------------------
subtest 'bounded numeric - "0-65535" accepts in-range, returns numeric' => sub {
	set_stdin("8080\n");
	my $result;
	stderr_from { $result = prompt_for_line(undef, 'Port', undef, '0-65535') };
	reset_stdin();
	is($result, 8080, '8080 accepted for 0-65535 range');
	ok($result == $result + 0, 'returned value is numeric');
};

# ---------------------------------------------------------------------------
# bounded numeric validation - out of range
# ---------------------------------------------------------------------------
subtest 'bounded numeric - "0-65535" rejects out-of-range' => sub {
	set_stdin("70000\n1024\n");
	my $result;
	my $output;
	$output = stderr_from { $result = prompt_for_line(undef, 'Port', undef, '0-65535') };
	reset_stdin();
	is($result, 1024, 'out-of-range rejected, in-range accepted');
	like($output, qr/expected to be between 0 and 65535/i, 'error message shown');
};

# ---------------------------------------------------------------------------
# bounded numeric validation - "1+" minimum
# ---------------------------------------------------------------------------
subtest 'bounded numeric - "1+" accepts values >= 1' => sub {
	set_stdin("5\n");
	my $result;
	stderr_from { $result = prompt_for_line(undef, 'Count', undef, '1+') };
	reset_stdin();
	is($result, 5, '"1+" accepts 5');
	ok($result == $result + 0, 'returned value is numeric');
};

# ---------------------------------------------------------------------------
# bounded numeric validation - "1+" rejects 0
# ---------------------------------------------------------------------------
subtest 'bounded numeric - "1+" rejects 0, accepts 1' => sub {
	set_stdin("0\n1\n");
	my $result;
	my $output;
	$output = stderr_from { $result = prompt_for_line(undef, 'Count', undef, '1+') };
	reset_stdin();
	is($result, 1, '0 rejected by "1+", 1 accepted');
	like($output, qr/must be at least 1/, 'error message shown for 0 with "1+" validation');
};

# ---------------------------------------------------------------------------
# bounded numeric validation - "1+" accepts large values
# ---------------------------------------------------------------------------
subtest 'bounded numeric - "1+" accepts any value >= 1' => sub {
	set_stdin("1000\n");
	my $result;
	stderr_from { $result = prompt_for_line(undef, 'Count', undef, '1+') };
	reset_stdin();
	is($result, 1000, '"1+" accepts 1000');
};

# ---------------------------------------------------------------------------
# prompt_for_list - custom end_prompt parameter
# ---------------------------------------------------------------------------
subtest 'prompt_for_list - custom end_prompt displayed in header' => sub {
	set_stdin("val\n\n");
	my $result;
	my $output;
	$output = combined_from {
		$result = prompt_for_list('line', 'Enter values', 'value', 0, undef, undef, undef, '(press enter when done)')
	};
	reset_stdin();
	like($output, qr/press enter when done/, 'custom end_prompt shown in output');
	is(scalar(@$result), 1, 'still collects items correctly');
};

# ---------------------------------------------------------------------------
# prompt_for_list - ordinal labels (1st, 2nd, 3rd)
# ---------------------------------------------------------------------------
subtest 'prompt_for_list - ordinal labels in prompts' => sub {
	set_stdin("a\nb\nc\n\n");
	my $result;
	my $output;
	$output = combined_from {
		$result = prompt_for_list('line', 'Enter items', 'item')
	};
	reset_stdin();
	is(scalar(@$result), 3, 'collected three items');
	like($output, qr/1st item/, '1st ordinal label shown');
	like($output, qr/2nd item/, '2nd ordinal label shown');
	like($output, qr/3rd item/, '3rd ordinal label shown');
};

done_testing;
