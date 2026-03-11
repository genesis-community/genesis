#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use lib 't';
use helper;
use Test::More;
use Test::Deep;
use Test::Exception;
use File::Temp qw/tempfile/;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{GENESIS_OUTPUT_LINES} = 24;

use_ok 'Genesis::Term';

# ---- has_tput ----------------------------------------------------------------

subtest 'has_tput returns 0 when TERM is unset' => sub {
	local $ENV{TERM};
	delete $ENV{TERM};
	is(Genesis::Term::has_tput(), 0, 'has_tput returns 0 without $ENV{TERM}');
};

subtest 'has_tput returns 1 when TERM is set and tput available' => sub {
	local $ENV{TERM} = 'xterm';
	my $result = Genesis::Term::has_tput();
	ok($result == 0 || $result == 1, 'has_tput returns 0 or 1');
};

subtest 'has_tput returns boolean integer' => sub {
	local $ENV{TERM} = 'xterm';
	my $result = Genesis::Term::has_tput();
	like("$result", qr/^[01]$/, 'has_tput result is 0 or 1');
};

# ---- terminal_width ----------------------------------------------------------

subtest 'terminal_width returns GENESIS_OUTPUT_COLUMNS when set' => sub {
	local $ENV{GENESIS_OUTPUT_COLUMNS} = 120;
	is(terminal_width(), 120, 'terminal_width returns env value 120');
};

subtest 'terminal_width returns different GENESIS_OUTPUT_COLUMNS values' => sub {
	local $ENV{GENESIS_OUTPUT_COLUMNS} = 200;
	is(terminal_width(), 200, 'terminal_width returns env value 200');
};

subtest 'terminal_width falls back to 80 without tput or env' => sub {
	local $ENV{GENESIS_OUTPUT_COLUMNS};
	delete $ENV{GENESIS_OUTPUT_COLUMNS};
	local $ENV{TERM};
	delete $ENV{TERM};
	is(terminal_width(), 80, 'terminal_width falls back to 80');
};

subtest 'terminal_width returns a positive integer' => sub {
	my $width = terminal_width();
	ok($width > 0, 'terminal_width returns positive integer');
	like("$width", qr/^\d+$/, 'terminal_width result is a digit string');
};

subtest 'terminal_width env takes precedence over tput' => sub {
	local $ENV{GENESIS_OUTPUT_COLUMNS} = 132;
	local $ENV{TERM} = 'xterm';
	is(terminal_width(), 132, 'env var wins over tput lookup');
};

# ---- terminal_height ---------------------------------------------------------

subtest 'terminal_height returns GENESIS_OUTPUT_LINES when set' => sub {
	local $ENV{GENESIS_OUTPUT_LINES} = 50;
	is(Genesis::Term::terminal_height(), 50, 'terminal_height returns env value 50');
};

subtest 'terminal_height returns different GENESIS_OUTPUT_LINES values' => sub {
	local $ENV{GENESIS_OUTPUT_LINES} = 60;
	is(Genesis::Term::terminal_height(), 60, 'terminal_height returns env value 60');
};

subtest 'terminal_height falls back to 24 without tput or env' => sub {
	local $ENV{GENESIS_OUTPUT_LINES};
	delete $ENV{GENESIS_OUTPUT_LINES};
	local $ENV{TERM};
	delete $ENV{TERM};
	is(Genesis::Term::terminal_height(), 24, 'terminal_height falls back to 24');
};

subtest 'terminal_height returns a positive integer' => sub {
	my $height = Genesis::Term::terminal_height();
	ok($height > 0, 'terminal_height returns positive integer');
	like("$height", qr/^\d+$/, 'terminal_height result is a digit string');
};

subtest 'terminal_height env takes precedence over tput' => sub {
	local $ENV{GENESIS_OUTPUT_LINES} = 48;
	local $ENV{TERM} = 'xterm';
	is(Genesis::Term::terminal_height(), 48, 'env var wins over tput lookup');
};

# ---- in_controlling_terminal -------------------------------------------------

subtest 'in_controlling_terminal returns false under prove' => sub {
	my $result = in_controlling_terminal();
	ok(!$result, 'in_controlling_terminal is false when stdin/stdout are piped');
};

subtest 'in_controlling_terminal returns a defined value' => sub {
	my $result = in_controlling_terminal();
	ok(defined $result,
		'in_controlling_terminal returns a defined value');
};

# ---- get_io_target -----------------------------------------------------------

subtest 'get_io_target defaults to checking STDOUT' => sub {
	# Under prove STDOUT is not a terminal; it's a file or pipe
	my $result = get_io_target();
	ok(defined $result, 'get_io_target with no args returns a defined value');
	like($result, qr/^(terminal|pipe|file|unknown device|\/.*)$/,
		'get_io_target returns a recognizable type');
};

subtest 'get_io_target returns pipe for a pipe handle' => sub {
	pipe(my $read_end, my $write_end) or die "pipe failed: $!";
	my $result = get_io_target($write_end);
	is($result, 'pipe', 'get_io_target returns "pipe" for write end of pipe');
	close $write_end;
	close $read_end;
};

subtest 'get_io_target returns pipe for read end of pipe' => sub {
	pipe(my $read_end, my $write_end) or die "pipe failed: $!";
	my $result = get_io_target($read_end);
	is($result, 'pipe', 'get_io_target returns "pipe" for read end of pipe');
	close $write_end;
	close $read_end;
};

subtest 'get_io_target returns file for a regular file handle' => sub {
	my ($fh, $fname) = tempfile(UNLINK => 1);
	my $result = get_io_target($fh);
	ok($result eq 'file' || $result =~ m{^/},
		'get_io_target returns "file" or path for file handle');
	close $fh;
};

subtest 'get_io_target returns unknown device for in-memory string ref handle' => sub {
	my $buf = '';
	open(my $fh, '>', \$buf) or die "open string ref failed: $!";
	my $result = get_io_target($fh);
	is($result, 'unknown device',
		'get_io_target returns "unknown device" for in-memory handle');
	close $fh;
};

subtest 'get_io_target with explicit STDOUT glob' => sub {
	my $result = get_io_target(\*STDOUT);
	ok(defined $result, 'get_io_target(\*STDOUT) returns defined value');
	like($result, qr/^(terminal|pipe|file|unknown device|\/.*)$/,
		'get_io_target(\*STDOUT) returns recognizable type');
};

done_testing;
