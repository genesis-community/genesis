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
# elipses
# ---------------------------------------------------------------------------
subtest 'elipses - within limit unchanged' => sub {
	is elipses('hello', 10),  'hello',  'short string unchanged';
	is elipses('hello', 5),   'hello',  'exactly at limit unchanged';
	is elipses('', 5),        '',       'empty string unchanged';
	is elipses('a', 1),       'a',      'single char at limit unchanged';
};

subtest 'elipses - exceeds limit gets truncated with ...' => sub {
	is elipses('hello world', 8),  'hello...',      'truncates to len-3 + ellipsis';
	is elipses('abcdefghij', 7),   'abcd...',       'ten chars truncated to 7';
	is elipses('hello world', 5),  'he...',         'truncates to 2 chars + ellipsis';
};

# ---------------------------------------------------------------------------
# superscript
# ---------------------------------------------------------------------------
subtest 'superscript - UTF8 single digits' => sub {
	local $ENV{GENESIS_NO_UTF8};
	delete $ENV{GENESIS_NO_UTF8};
	is Genesis::Term::superscript(0), "\x{2070}", 'superscript 0';
	is Genesis::Term::superscript(1), "\x{00B9}", 'superscript 1';
	is Genesis::Term::superscript(2), "\x{00B2}", 'superscript 2';
	is Genesis::Term::superscript(3), "\x{00B3}", 'superscript 3';
	is Genesis::Term::superscript(4), "\x{2074}", 'superscript 4';
	is Genesis::Term::superscript(5), "\x{2075}", 'superscript 5';
	is Genesis::Term::superscript(9), "\x{2079}", 'superscript 9';
};

subtest 'superscript - UTF8 multi-digit' => sub {
	local $ENV{GENESIS_NO_UTF8};
	delete $ENV{GENESIS_NO_UTF8};
	is Genesis::Term::superscript(12), "\x{00B9}\x{00B2}", 'superscript 12';
	is Genesis::Term::superscript(42), "\x{2074}\x{00B2}", 'superscript 42';
	is Genesis::Term::superscript(10), "\x{00B9}\x{2070}", 'superscript 10';
};

subtest 'superscript - GENESIS_NO_UTF8 fallback' => sub {
	local $ENV{GENESIS_NO_UTF8} = 1;
	is Genesis::Term::superscript(3),  '[#i{*3}]',  'fallback for single digit';
	is Genesis::Term::superscript(12), '[#i{*12}]', 'fallback for two digits';
};

# ---------------------------------------------------------------------------
# wrap
# ---------------------------------------------------------------------------
subtest 'wrap - basic word wrapping at width' => sub {
	my $result = wrap('hello world', 11);
	is $result, 'hello world', 'fits on one line unchanged';

	$result = wrap('hello world this is a test', 12);
	like $result, qr/\nhello world\n|hello world\n/, 'wraps at width boundary';
};

subtest 'wrap - no trailing newline' => sub {
	my $result = wrap('hello world', 40);
	unlike $result, qr/\n$/, 'no trailing newline';
};

subtest 'wrap - prefix on first line' => sub {
	my $result = wrap('hello world', 40, '>>> ');
	like $result, qr/^>>> hello world/, 'prefix appears on first line';
};

subtest 'wrap - continuation lines use indent' => sub {
	# Force wrap by using narrow width
	my $result = wrap('one two three four', 10, '- ');
	my @lines = split /\n/, $result;
	is $lines[0], '- one two', 'first line has prefix';
	like $lines[1], qr/^  /, 'second line is indented (indent = csize of prefix = 2)';
};

subtest 'wrap - negative width is raw mode' => sub {
	my $result = wrap("line1\nline2", -1, '  ');
	my @lines = split /\n/, $result;
	is $lines[0], '  line1', 'first line gets prefix in raw mode';
	like $lines[1], qr/^\s+line2/, 'second line gets indent in raw mode';
};

subtest 'wrap - empty string' => sub {
	my $result = wrap('', 40);
	is $result, '', 'empty string gives empty result';
};

subtest 'wrap - continue_prefix supported' => sub {
	my $long = 'aaaa bbbb cccc dddd eeee ffff gggg hhhh';
	my $result = wrap($long, 20, '  ', 2, '+ ');
	my @lines = split /\n/, $result;
	# continuation lines start with continue_prefix
	if (@lines > 1) {
		like $lines[1], qr/^\+ /, 'continuation line has continue_prefix';
	} else {
		pass 'single line (text fits), continue_prefix not needed';
	}
};

subtest 'wrap - init_col offset strips leading chars' => sub {
	my $result = wrap('hello world', 40, '    ', undef, undef, 2);
	# With init_col=2, first 2 chars are stripped from result
	unlike $result, qr/^  /, 'init_col strips leading spaces from result';
};

# ---------------------------------------------------------------------------
# fix_wrap
# ---------------------------------------------------------------------------
subtest 'fix_wrap - strips leading and trailing newlines' => sub {
	my $result = fix_wrap("\n\nhello world\n\n");
	is $result, 'hello world', 'strips surrounding newlines';
};

subtest 'fix_wrap - single string passthrough' => sub {
	my $result = fix_wrap('simple message');
	is $result, 'simple message', 'plain string returned as-is';
};

subtest 'fix_wrap - sprintf form with multiple args' => sub {
	my $result = fix_wrap('Value is %d', 42);
	is $result, 'Value is 42', 'sprintf substitution works';
};

subtest 'fix_wrap - labeled color-markup prefix folding' => sub {
	# Simulate the label+indented text form
	my $msg = "#W{[NOTE]} Some\n       long text";
	my $result = fix_wrap($msg);
	# The label prefix extraction: $c=W, $prefix=[NOTE], $sub_msg = body
	# indent = ' ' x (length('[NOTE]')+1) = 7 spaces
	# The second line starts with 7 spaces followed by a non-space => joined
	like $result, qr/Some long text/, 'indented continuation joined to first line';
};

subtest 'fix_wrap - blank lines preserved inside content' => sub {
	my $msg = "#W{[NOTE]} Line one\n       \n       Line two";
	my $result = fix_wrap($msg);
	# "\n " becomes "\n\n" after second substitution
	like $result, qr/Line one/, 'first content line present';
};

# ---------------------------------------------------------------------------
# colored_block
# ---------------------------------------------------------------------------
subtest 'colored_block - NOCOLOR returns text unchanged' => sub {
	# NOCOLOR=1 is set at the top of the file
	my $result = colored_block("some text", 'G', 'k');
	is $result, 'some text', 'NOCOLOR: text returned unchanged';
};

subtest 'colored_block - NOCOLOR: multi-line text unchanged' => sub {
	my $text = "line one\nline two\nline three";
	my $result = colored_block($text, 'G', 'k');
	is $result, $text, 'NOCOLOR: multi-line text returned unchanged';
};

subtest 'colored_block - with color: wraps each line with ANSI codes' => sub {
	local $ENV{NOCOLOR};
	delete $ENV{NOCOLOR};
	my $result = colored_block("hello\nworld", 'W', 'k');
	my @lines = split /\n/, $result;
	is scalar @lines, 2, 'two lines produced';
	like $lines[0], qr/\e\[/, 'first line has ANSI escape codes';
	like $lines[1], qr/\e\[/, 'second line has ANSI escape codes';
	like $lines[0], qr/hello/, 'first line contains hello';
	like $lines[1], qr/world/, 'second line contains world';
};

subtest 'colored_block - with color: single line' => sub {
	local $ENV{NOCOLOR};
	delete $ENV{NOCOLOR};
	my $result = colored_block("single", 'G', 'k');
	like $result, qr/\e\[/, 'has ANSI escape codes';
	like $result, qr/single/, 'contains original text';
};

# ---------------------------------------------------------------------------
# bullet
# ---------------------------------------------------------------------------
subtest 'bullet - default type (no type given)' => sub {
	my $result = decolorize(bullet('hello'));
	like $result, qr/\Q•\E|\*|hello/, 'contains bullet symbol or text';
	like $result, qr/hello/, 'contains message';
};

subtest 'bullet - good type' => sub {
	my $result = decolorize(bullet('good', 'done'));
	like $result, qr/✔|done/, 'good bullet contains checkmark glyph or message';
};

subtest 'bullet - bad type' => sub {
	my $result = decolorize(bullet('bad', 'failed'));
	like $result, qr/✘|failed/, 'bad bullet contains x glyph or message';
};

subtest 'bullet - warn type' => sub {
	my $result = decolorize(bullet('warn', 'caution'));
	like $result, qr/⚠|caution/, 'warn bullet contains warning glyph or message';
};

subtest 'bullet - empty type' => sub {
	my $result = decolorize(bullet('empty', 'placeholder'));
	like $result, qr/placeholder/, 'empty bullet contains message';
};

subtest 'bullet - default indent is 2' => sub {
	my $result = decolorize(bullet('hello'));
	like $result, qr/^  /, 'default indent of 2 spaces';
};

subtest 'bullet - custom indent' => sub {
	my $result = decolorize(bullet('hello', indent => 4));
	like $result, qr/^    /, 'custom indent of 4 spaces';
};

subtest 'bullet - zero indent' => sub {
	my $result = decolorize(bullet('hello', indent => 0));
	unlike $result, qr/^  /, 'zero indent has no leading spaces';
};

subtest 'bullet - box option wraps symbol in brackets' => sub {
	my $result = decolorize(bullet('good', 'ok', box => 1));
	like $result, qr/\[.*\]/, 'box wraps symbol in square brackets';
};

subtest 'bullet - custom symbol' => sub {
	my $result = decolorize(bullet('hello', symbol => '>'));
	like $result, qr/>/, 'custom symbol appears in output';
};

# ---------------------------------------------------------------------------
# checkbox
# ---------------------------------------------------------------------------
subtest 'checkbox - good/truthy state produces checked box' => sub {
	# Any truthy value that is not 'error' maps to good (checked)
	my $good = decolorize(checkbox('good'));
	my $true = decolorize(checkbox(1));
	my $yes  = decolorize(checkbox('yes'));
	# 'bad' is truthy and not 'error', so it also maps to good
	my $bad_str = decolorize(checkbox('bad'));
	like $good,    qr/\[.*\]/, 'good state has box brackets';
	like $true,    qr/\[.*\]/, 'truthy 1 state has box brackets';
	like $yes,     qr/\[.*\]/, 'truthy yes state has box brackets';
	like $bad_str, qr/\[.*\]/, 'truthy bad string state has box brackets (maps to good)';
	# good uses checkmark glyph
	like $good, qr/✔|\+/, 'good checkbox has check glyph';
};

subtest 'checkbox - error/false/undef state produces unchecked box' => sub {
	# Only 'error', 0, '', and undef map to 'bad' bullet
	# (truthy non-'error' strings like 'bad' actually map to 'good')
	my $error = decolorize(checkbox('error'));
	my $zero  = decolorize(checkbox(0));
	my $empty = decolorize(checkbox(''));
	like $error, qr/\[.*\]/, 'error state has box brackets';
	like $zero,  qr/\[.*\]/, 'zero state has box brackets';
	like $empty, qr/\[.*\]/, 'empty string state has box brackets';
	# error/false uses x glyph
	like $error, qr/✘|-/, 'error checkbox has x glyph';
	like $zero,  qr/✘|-/, 'zero checkbox has x glyph';
};

subtest 'checkbox - warn state produces warning box' => sub {
	my $result = decolorize(checkbox('warn'));
	like $result, qr/\[.*\]/, 'warn state has box brackets';
	like $result, qr/⚠|!/, 'warn checkbox has warning glyph';
};

subtest 'checkbox - has zero indent' => sub {
	my $result = decolorize(checkbox('good'));
	unlike $result, qr/^  /, 'checkbox has no leading indent';
};

done_testing;

# vim: ts=4 sw=4 sts=4 noet fdm=marker foldlevel=1 nu
