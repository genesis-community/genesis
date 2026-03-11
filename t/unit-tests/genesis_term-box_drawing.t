#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;
use Test::Exception;

$ENV{NOCOLOR}                = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{GENESIS_OUTPUT_LINES}   = 24;

use_ok 'Genesis::Term';

# ---------------------------------------------------------------------------
# boxify - UTF8 box drawing characters
# ---------------------------------------------------------------------------
subtest 'boxify - UTF8 mode: top row' => sub {
	local $ENV{GENESIS_NO_UTF8};
	delete $ENV{GENESIS_NO_UTF8};
	local $ENV{GENESIS_NO_BOXES};
	delete $ENV{GENESIS_NO_BOXES};
	is boxify('top', 'left'),  "\x{250F}", 'top-left is heavy top-left corner';
	is boxify('top', 'right'), "\x{2513}", 'top-right is heavy top-right corner';
	is boxify('top', 'span'),  "\x{2501}", 'top-span is heavy horizontal';
	is boxify('top', 'div'),   "\x{2533}", 'top-div is heavy down and horizontal';
};

subtest 'boxify - UTF8 mode: line row' => sub {
	local $ENV{GENESIS_NO_UTF8};
	delete $ENV{GENESIS_NO_UTF8};
	local $ENV{GENESIS_NO_BOXES};
	delete $ENV{GENESIS_NO_BOXES};
	is boxify('line', 'left'),  "\x{2503}", 'line-left is heavy vertical';
	is boxify('line', 'right'), "\x{2503}", 'line-right is heavy vertical';
	is boxify('line', 'span'),  " ",        'line-span is a space';
	is boxify('line', 'div'),   "\x{2503}", 'line-div is heavy vertical';
};

subtest 'boxify - UTF8 mode: mid row' => sub {
	local $ENV{GENESIS_NO_UTF8};
	delete $ENV{GENESIS_NO_UTF8};
	local $ENV{GENESIS_NO_BOXES};
	delete $ENV{GENESIS_NO_BOXES};
	is boxify('mid', 'left'),  "\x{2523}", 'mid-left is heavy vertical and right';
	is boxify('mid', 'right'), "\x{252B}", 'mid-right is heavy vertical and left';
	is boxify('mid', 'span'),  "\x{2501}", 'mid-span is heavy horizontal';
	is boxify('mid', 'div'),   "\x{254B}", 'mid-div is heavy vertical horizontal';
};

subtest 'boxify - UTF8 mode: bot row' => sub {
	local $ENV{GENESIS_NO_UTF8};
	delete $ENV{GENESIS_NO_UTF8};
	local $ENV{GENESIS_NO_BOXES};
	delete $ENV{GENESIS_NO_BOXES};
	is boxify('bot', 'left'),  "\x{2517}", 'bot-left is heavy bottom-left corner';
	is boxify('bot', 'right'), "\x{251B}", 'bot-right is heavy bottom-right corner';
	is boxify('bot', 'span'),  "\x{2501}", 'bot-span is heavy horizontal';
	is boxify('bot', 'div'),   "\x{253B}", 'bot-div is heavy up and horizontal';
};

# ---------------------------------------------------------------------------
# boxify - ASCII fallback (GENESIS_NO_UTF8)
# ---------------------------------------------------------------------------
subtest 'boxify - GENESIS_NO_UTF8: top row uses ASCII' => sub {
	local $ENV{GENESIS_NO_UTF8} = 1;
	is boxify('top', 'left'),  '+', 'top-left is +';
	is boxify('top', 'right'), '+', 'top-right is +';
	is boxify('top', 'span'),  '-', 'top-span is -';
	is boxify('top', 'div'),   '+', 'top-div is +';
};

subtest 'boxify - GENESIS_NO_UTF8: line row uses ASCII' => sub {
	local $ENV{GENESIS_NO_UTF8} = 1;
	is boxify('line', 'left'),  '|', 'line-left is |';
	is boxify('line', 'right'), '|', 'line-right is |';
	is boxify('line', 'span'),  ' ', 'line-span is space';
	is boxify('line', 'div'),   '|', 'line-div is |';
};

subtest 'boxify - GENESIS_NO_UTF8: mid and bot rows use ASCII' => sub {
	local $ENV{GENESIS_NO_UTF8} = 1;
	is boxify('mid', 'left'),  '+', 'mid-left is +';
	is boxify('mid', 'right'), '+', 'mid-right is +';
	is boxify('mid', 'span'),  '-', 'mid-span is -';
	is boxify('mid', 'div'),   '+', 'mid-div is +';
	is boxify('bot', 'left'),  '+', 'bot-left is +';
	is boxify('bot', 'right'), '+', 'bot-right is +';
	is boxify('bot', 'span'),  '-', 'bot-span is -';
	is boxify('bot', 'div'),   '+', 'bot-div is +';
};

# ---------------------------------------------------------------------------
# boxify - ASCII fallback (GENESIS_NO_BOXES)
# ---------------------------------------------------------------------------
subtest 'boxify - GENESIS_NO_BOXES: all positions use ASCII' => sub {
	local $ENV{GENESIS_NO_UTF8};
	delete $ENV{GENESIS_NO_UTF8};
	local $ENV{GENESIS_NO_BOXES} = 1;
	is boxify('top', 'left'),  '+', 'top-left is + under NO_BOXES';
	is boxify('top', 'span'),  '-', 'top-span is - under NO_BOXES';
	is boxify('line', 'left'), '|', 'line-left is | under NO_BOXES';
	is boxify('bot', 'right'), '+', 'bot-right is + under NO_BOXES';
};

# ---------------------------------------------------------------------------
# boxify - invalid inputs
# ---------------------------------------------------------------------------
subtest 'boxify - invalid line type returns empty string' => sub {
	is boxify('invalid', 'left'),  '', 'invalid line type returns empty string';
	is boxify('side', 'left'),     '', 'unknown line type returns empty string';
};

subtest 'boxify - invalid position returns empty string' => sub {
	is boxify('top', 'invalid'),  '', 'invalid position returns empty string';
	is boxify('top', 'center'),   '', 'unknown position returns empty string';
};

subtest 'boxify - both invalid returns empty string' => sub {
	is boxify('bad', 'bad'), '', 'both invalid returns empty string';
	is boxify('', ''),       '', 'both empty returns empty string';
};

# ---------------------------------------------------------------------------
# _align - internal alignment function
# ---------------------------------------------------------------------------
subtest '_align - left alignment pads right' => sub {
	is Genesis::Term::_align('hi', 6, 'l'), 'hi    ', 'left align pads right with spaces';
	is Genesis::Term::_align('hi', 4, 'l'), 'hi  ',   'left align 4 wide';
	is Genesis::Term::_align('a',  3, 'l'), 'a  ',    'left align single char';
};

subtest '_align - right alignment pads left' => sub {
	is Genesis::Term::_align('hi', 6, 'r'), '    hi', 'right align pads left with spaces';
	is Genesis::Term::_align('hi', 4, 'r'), '  hi',   'right align 4 wide';
	is Genesis::Term::_align('a',  3, 'r'), '  a',    'right align single char';
};

subtest '_align - center alignment pads both sides' => sub {
	my $result = Genesis::Term::_align('hi', 6, 'c');
	is $result, '  hi  ', 'center align 6 wide even padding';
	$result = Genesis::Term::_align('hi', 5, 'c');
	# odd padding: int(1.5)=1 left, int(1.5+0.5)=2 right
	is $result, ' hi  ', 'center align 5 wide odd padding (extra right)';
	$result = Genesis::Term::_align('a', 4, 'c');
	is $result, ' a  ', 'center align single char 4 wide';
};

subtest '_align - string at or wider than width returned unchanged' => sub {
	is Genesis::Term::_align('hello', 5, 'l'), 'hello', 'exact width unchanged (left)';
	is Genesis::Term::_align('hello', 5, 'r'), 'hello', 'exact width unchanged (right)';
	is Genesis::Term::_align('hello', 5, 'c'), 'hello', 'exact width unchanged (center)';
	is Genesis::Term::_align('toolong', 4, 'l'), 'toolong', 'wider than limit returned unchanged';
};

subtest '_align - empty string pads entirely with spaces' => sub {
	is Genesis::Term::_align('', 4, 'l'), '    ', 'empty string pads fully (left)';
	is Genesis::Term::_align('', 4, 'r'), '    ', 'empty string pads fully (right)';
};

# ---------------------------------------------------------------------------
# _multiline_row - internal table row renderer
# ---------------------------------------------------------------------------
subtest '_multiline_row - single-line row has box borders' => sub {
	local $ENV{GENESIS_NO_UTF8};
	delete $ENV{GENESIS_NO_UTF8};
	local $ENV{GENESIS_NO_BOXES};
	delete $ENV{GENESIS_NO_BOXES};
	my $row = ['hello', 'world'];
	my $col_widths = [10, 10];
	my $col_align  = ['l', 'l'];
	my $result = Genesis::Term::_multiline_row($row, $col_widths, $col_align);
	like $result, qr/\x{2503}/, 'result contains box vertical border character';
	like $result, qr/hello/,    'result contains first cell content';
	like $result, qr/world/,    'result contains second cell content';
};

subtest '_multiline_row - ASCII mode: single-line row uses | borders' => sub {
	local $ENV{GENESIS_NO_UTF8} = 1;
	my $row = ['foo', 'bar'];
	my $col_widths = [6, 6];
	my $col_align  = ['l', 'r'];
	my $result = Genesis::Term::_multiline_row($row, $col_widths, $col_align);
	like $result, qr/\|/, 'ASCII mode result contains | border';
	like $result, qr/foo/, 'result contains first cell';
	like $result, qr/bar/, 'result contains second cell';
};

subtest '_multiline_row - multi-line cell wrapping produces multiple lines' => sub {
	local $ENV{GENESIS_NO_UTF8} = 1;
	# With a narrow column width, a long word forces wrapping
	my $row = ['short', 'a b c d e f g h'];
	my $col_widths = [6, 5];
	my $col_align  = ['l', 'l'];
	my $result = Genesis::Term::_multiline_row($row, $col_widths, $col_align);
	my @lines = split /\n/, $result;
	cmp_ok scalar(@lines), '>', 1, 'wrapping produces more than one output line';
};

subtest '_multiline_row - empty cells render without crashing' => sub {
	local $ENV{GENESIS_NO_UTF8} = 1;
	my $row = ['', ''];
	my $col_widths = [5, 5];
	my $col_align  = ['l', 'l'];
	my $result;
	lives_ok { $result = Genesis::Term::_multiline_row($row, $col_widths, $col_align) }
		'empty cells do not throw';
	like $result, qr/\|/, 'empty row still has borders';
};

done_testing;

# vim: ts=4 sw=4 sts=4 noet fdm=marker foldlevel=1 nu
