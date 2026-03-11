#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use helper;
use Test::More;
use Test::Exception;
use Test::Deep;
use Cwd qw(abs_path);

$ENV{GENESIS_CALLBACK_BIN} ||= abs_path('bin/genesis');
$ENV{GENESIS_LIB} ||= abs_path('lib');
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

use_ok 'Genesis::Hook::CloudConfig::Helpers';

subtest 'megabytes - returns value unchanged' => sub {
	plan tests => 4;

	is megabytes(4096), 4096, 'megabytes(4096) returns 4096 unchanged';
	is megabytes(0),    0,    'megabytes(0) returns 0 (edge case: zero)';
	is megabytes(1),    1,    'megabytes(1) returns 1 (edge case: one)';
	is megabytes(1_000_000), 1_000_000, 'megabytes(1_000_000) returns 1_000_000 (large number)';
};

subtest 'gigabytes - converts to megabytes by multiplying by 1024' => sub {
	plan tests => 5;

	is gigabytes(1),   1024,  'gigabytes(1) returns 1024';
	is gigabytes(50),  51200, 'gigabytes(50) returns 51200';
	is gigabytes(0),   0,     'gigabytes(0) returns 0 (edge case: zero)';
	is gigabytes(2),   2048,  'gigabytes(2) returns 2048';
	is gigabytes(128), 131072, 'gigabytes(128) returns 131072';
};

subtest 'gigabytes - multiplication is correct' => sub {
	plan tests => 3;

	is gigabytes(64),  64  * 1024, 'gigabytes(64) equals 64 * 1024';
	is gigabytes(96),  96  * 1024, 'gigabytes(96) equals 96 * 1024';
	is gigabytes(512), 512 * 1024, 'gigabytes(512) equals 512 * 1024';
};

subtest 'exports - functions available without explicit import list' => sub {
	plan tests => 2;

	ok defined(&megabytes), 'megabytes() is exported into calling namespace';
	ok defined(&gigabytes), 'gigabytes() is exported into calling namespace';
};

done_testing;
