#!/usr/bin/env perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Test::Deep;

use_ok 'Genesis';

subtest 'ordify' => sub {
	my %cases = (
		'0' => '0th',
		'1' => '1st',
		'2' => '2nd',
		'3' => '3rd',
		'4' => '4th',
		'5' => '5th',
		'6' => '6th',
		'7' => '7th',
		'8' => '8th',
		'9' => '9th',

		'10' => '10th',
		'11' => '11th',
		'12' => '12th',
		'13' => '13th',

		'20' => '20th',
		'21' => '21st',
		'22' => '22nd',
		'23' => '23rd',

		'100' => '100th',
		'101' => '101st',
		'102' => '102nd',
		'103' => '103rd',

		'110' => '110th',
		'111' => '111th',
		'112' => '112th',
		'113' => '113th',

		'120' => '120th',
		'121' => '121st',
		'122' => '122nd',
		'123' => '123rd',
	);

	for my $num (keys %cases) {
		# there's a trailing space for some reason.
		is ordify($num), "$cases{$num} ", "numeric $num should ordify as $cases{$num}";
	}
};

subtest 'count_nouns' => sub {
	is count_nouns(0, 'file'), '0 files', 'zero files pluralized';
	is count_nouns(1, 'file'), '1 file', 'one file singular';
	is count_nouns(2, 'file'), '2 files', 'two files pluralized';
	is count_nouns(42, 'error'), '42 errors', 'multiple errors pluralized';
};

subtest 'sentence_join' => sub {
	is sentence_join(), '', 'empty list returns empty string';
	is sentence_join('one'), 'one', 'single item no comma';
	is sentence_join('one', 'two'), 'one and two', 'two items with and';
	is sentence_join('one', 'two', 'three'), 'one, two and three', 'three items with comma and and';
	is sentence_join('a', 'b', 'c', 'd'), 'a, b, c and d', 'four items with commas and and';
};

# Test parse_fixed_width_table() - Parse BOSH-style fixed width tables
subtest 'parse_fixed_width_table() - basic hashref output' => sub {
	my $header = "Name      Version  Status";
	my @rows = (
		"webapp    1.2.3    running",
		"api       2.0.1    stopped",
		"worker    1.0.0    running"
	);

	my @results = parse_fixed_width_table($header, @rows);

	is scalar(@results), 3, 'parsed 3 rows';
	is ref($results[0]), 'HASH', 'first row is hashref';
	is $results[0]->{Name}, 'webapp', 'first row name correct';
	is $results[0]->{Version}, '1.2.3', 'first row version correct';
	is $results[0]->{Status}, 'running', 'first row status correct';

	is $results[1]->{Name}, 'api', 'second row name correct';
	is $results[2]->{Name}, 'worker', 'third row name correct';
};

subtest 'parse_fixed_width_table() - array_rows option' => sub {
	my $header = "Name      Version  Status";
	my @rows = (
		"webapp    1.2.3    running",
		"api       2.0.1    stopped"
	);

	my @results = parse_fixed_width_table({array_rows => 1}, $header, @rows);

	is scalar(@results), 3, 'returns 3 items (header + 2 rows)';
	is ref($results[0]), 'ARRAY', 'first item is arrayref (header)';
	cmp_deeply $results[0], ['Name', 'Version', 'Status'], 'header columns correct';

	is ref($results[1]), 'ARRAY', 'second item is arrayref (first data row)';
	cmp_deeply $results[1], ['webapp', '1.2.3', 'running'], 'first data row correct';
	cmp_deeply $results[2], ['api', '2.0.1', 'stopped'], 'second data row correct';
};

subtest 'parse_fixed_width_table() - whitespace trimming' => sub {
	my $header = "Name        Status  ";
	my @rows = (
		"  webapp    running   ",
		"api         stopped"
	);

	my @results = parse_fixed_width_table($header, @rows);

	is $results[0]->{Name}, 'webapp', 'leading whitespace trimmed';
	is $results[0]->{Status}, 'running', 'trailing whitespace trimmed';
	is $results[1]->{Name}, 'api', 'minimal spacing handled';
};

subtest 'parse_fixed_width_table() - varying column widths' => sub {
	my $header = "ID  Description           Count";
	my @rows = (
		"1   Short text            5",
		"2   Much longer text here 10",
		"3   X                     999"
	);

	my @results = parse_fixed_width_table($header, @rows);

	is $results[0]->{Description}, 'Short text', 'short text correct';
	is $results[1]->{Description}, 'Much longer text here', 'long text correct';
	is $results[2]->{Description}, 'X', 'single char correct';
	is $results[2]->{Count}, '999', 'last column correct';
};

subtest 'parse_fixed_width_table() - empty input' => sub {
	my @results = parse_fixed_width_table(undef);
	is scalar(@results), 0, 'undef header returns empty array';

	@results = parse_fixed_width_table('');
	is scalar(@results), 0, 'empty header returns empty array';

	@results = parse_fixed_width_table("Name  Status");
	is scalar(@results), 0, 'no rows returns empty array';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
