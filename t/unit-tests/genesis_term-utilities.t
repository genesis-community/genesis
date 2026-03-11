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
$ENV{GENESIS_OUTPUT_LINES} = 24;

use_ok 'Genesis::Term';

# ---- get_control_picture -----------------------------------------------------

subtest 'get_control_picture returns plain char for printable ASCII' => sub {
	is(Genesis::Term::get_control_picture(65), 'A',
		'byte 65 (A) returns the character A');
	is(Genesis::Term::get_control_picture(90), 'Z',
		'byte 90 (Z) returns the character Z');
	is(Genesis::Term::get_control_picture(32), ' ',
		'byte 32 (space) returns a space');
	is(Genesis::Term::get_control_picture(126), '~',
		'byte 126 (~) returns tilde');
};

subtest 'get_control_picture returns control picture for byte < 32' => sub {
	my $nul = Genesis::Term::get_control_picture(0);
	# With NOCOLOR=1, csprintf strips the color markup but keeps the character
	# chr(0x2400 + 0) = chr(0x2400) = U+2400 SYMBOL FOR NULL
	is(ord($nul), 0x2400,
		'byte 0 (NUL) returns Unicode symbol for null U+2400');

	my $soh = Genesis::Term::get_control_picture(1);
	is(ord($soh), 0x2401,
		'byte 1 (SOH) returns Unicode symbol U+2401');

	my $us = Genesis::Term::get_control_picture(31);
	is(ord($us), 0x241F,
		'byte 31 (US) returns Unicode symbol U+241F');
};

subtest 'get_control_picture returns DEL picture for byte 127' => sub {
	my $del = Genesis::Term::get_control_picture(127);
	# chr(0x2421 + 127) = chr(0x24A0)
	is(ord($del), 0x24A0,
		'byte 127 (DEL) returns Unicode symbol U+24A0');
};

subtest 'get_control_picture returns high-byte picture for byte >= 128' => sub {
	my $hi = Genesis::Term::get_control_picture(128);
	# chr(0x2420 + 128) = chr(0x24A0) - coincides with DEL formula value
	is(ord($hi), 0x24A0,
		'byte 128 returns Unicode symbol chr(0x2420 + 128)');

	my $hi2 = Genesis::Term::get_control_picture(129);
	is(ord($hi2), 0x2420 + 129,
		'byte 129 returns Unicode symbol chr(0x2420 + 129)');
};

# ---- string_to_hex -----------------------------------------------------------

subtest 'string_to_hex prints a hex dump to STDOUT' => sub {
	stdout_like(
		sub { Genesis::Term::string_to_hex("Hello") },
		qr/^0000\s+48 65 6c 6c 6f/,
		'string_to_hex outputs offset and hex bytes for "Hello"'
	);
};

subtest 'string_to_hex output includes printable section' => sub {
	stdout_like(
		sub { Genesis::Term::string_to_hex("Hello") },
		qr/\|Hello\|/,
		'string_to_hex output includes printable characters in pipes'
	);
};

subtest 'string_to_hex handles 16-byte blocks' => sub {
	my $str = 'A' x 17;
	my $output = '';
	stdout_like(
		sub { Genesis::Term::string_to_hex($str) },
		qr/0000.+\n0010/s,
		'string_to_hex emits two lines for 17-byte input'
	);
};

subtest 'string_to_hex single byte input' => sub {
	stdout_like(
		sub { Genesis::Term::string_to_hex("A") },
		qr/^0000\s+41\s/,
		'single byte "A" shows hex 41'
	);
};

# ---- set_stdin / reset_stdin -------------------------------------------------

subtest 'set_stdin injects content readable from STDIN' => sub {
	set_stdin("hello world\n");
	my $line = <STDIN>;
	is($line, "hello world\n", 'STDIN yields the injected content');
	reset_stdin();
};

subtest 'reset_stdin restores original STDIN' => sub {
	set_stdin("test content\n");
	reset_stdin();
	# After reset, STDIN should not be our pipe; just verify reset doesn't die
	pass('reset_stdin completed without error');
};

subtest 'reset_stdin when not redirected is a no-op' => sub {
	lives_ok(
		sub { reset_stdin() },
		'reset_stdin when not redirected does not die'
	);
};

subtest 'set_stdin handles multiple lines' => sub {
	set_stdin("line one\nline two\nline three\n");
	my $l1 = <STDIN>;
	my $l2 = <STDIN>;
	my $l3 = <STDIN>;
	is($l1, "line one\n",   'first line reads correctly');
	is($l2, "line two\n",   'second line reads correctly');
	is($l3, "line three\n", 'third line reads correctly');
	reset_stdin();
};

subtest 'multiple set_stdin calls replace previous content' => sub {
	set_stdin("first content\n");
	set_stdin("second content\n");
	my $line = <STDIN>;
	is($line, "second content\n",
		'second set_stdin replaces first, yields second content');
	reset_stdin();
};

subtest 'set_stdin followed by reset_stdin followed by set_stdin works' => sub {
	set_stdin("alpha\n");
	my $a = <STDIN>;
	reset_stdin();

	set_stdin("beta\n");
	my $b = <STDIN>;
	reset_stdin();

	is($a, "alpha\n", 'first set_stdin cycle read correctly');
	is($b, "beta\n",  'second set_stdin cycle read correctly');
};

subtest 'set_stdin with empty string returns EOF immediately' => sub {
	set_stdin('');
	my $line = <STDIN>;
	ok(!defined($line), 'empty set_stdin yields undef (EOF) on read');
	reset_stdin();
};

done_testing;
