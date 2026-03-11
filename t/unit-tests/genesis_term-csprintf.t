#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Exception;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{GENESIS_OUTPUT_LINES} = 24;

use_ok 'Genesis::Term';

# ── csprintf ────────────────────────────────────────────────────────────────

subtest 'csprintf returns empty string for false input' => sub {
	is(csprintf(''),    '', 'empty string returns empty string');
	is(csprintf(undef), '', 'undef returns empty string');
	is(csprintf(0),     '', 'zero returns empty string');
};

subtest 'csprintf basic sprintf formatting' => sub {
	is(csprintf('hello'),           'hello',        'plain string passthrough');
	is(csprintf('%s', 'world'),     'world',        'string substitution');
	is(csprintf('%d', 42),          '42',           'integer substitution');
	is(csprintf('%.2f', 3.14159),  '3.14',         'float formatting');
	is(csprintf('%05d', 7),        '00007',         'zero-padded integer');
	is(csprintf('%s and %s', 'foo', 'bar'), 'foo and bar', 'two substitutions');
};

subtest 'csprintf with NOCOLOR strips markup to plain text' => sub {
	local $ENV{NOCOLOR} = 1;
	is(csprintf('#G{hello}'),     'hello',     'green markup stripped to plain');
	is(csprintf('#R{error}'),     'error',     'red markup stripped to plain');
	is(csprintf('#B{info}'),      'info',      'blue markup stripped to plain');
	is(csprintf('#Y{warning}'),   'warning',   'yellow markup stripped to plain');
	is(csprintf('#W{text}'),      'text',      'white markup stripped to plain');
	is(csprintf('#C{text}'),      'text',      'cyan markup stripped to plain');
	is(csprintf('#M{text}'),      'text',      'magenta markup stripped to plain');
	is(csprintf('#K{text}'),      'text',      'black markup stripped to plain');
};

subtest 'csprintf color markup with format strings' => sub {
	local $ENV{NOCOLOR} = 1;
	is(csprintf('#G{%s}', 'hello'), 'hello', 'color + sprintf arg');
	is(csprintf('prefix #R{%s} suffix', 'err'), 'prefix err suffix',
		'color in middle of string');
	is(csprintf('#Y{count: %d}', 5), 'count: 5', 'color with integer arg');
};

subtest 'csprintf glyph markup @{} syntax' => sub {
	local $ENV{NOCOLOR} = 1;
	local $ENV{GENESIS_NO_UTF8};
	delete $ENV{GENESIS_NO_UTF8};

	my $result = csprintf('#R@{-}');
	like($result, qr/\x{2718}/, 'red cross glyph rendered');

	$result = csprintf('#G@{+}');
	like($result, qr/\x{2714}/, 'green check glyph rendered');

	$result = csprintf('#@{-}');
	like($result, qr/\x{2718}/, 'plain glyph without color rendered');

	$result = csprintf('#@{*}');
	is($result, "\x{2022}", 'bullet glyph rendered');
};

subtest 'csprintf glyph with GENESIS_NO_UTF8' => sub {
	local $ENV{NOCOLOR} = 1;
	local $ENV{GENESIS_NO_UTF8} = '1';

	my $result = csprintf('#@{-}');
	is($result, '-', 'GENESIS_NO_UTF8 returns raw glyph key');

	$result = csprintf('#@{+}');
	is($result, '+', 'GENESIS_NO_UTF8 returns raw plus key');
};

subtest 'csprintf emoji markup #E{} syntax' => sub {
	local $ENV{NOCOLOR} = 1;
	local $ENV{GENESIS_NO_UTF8};
	delete $ENV{GENESIS_NO_UTF8};

	my $result = csprintf('#E{fire}');
	is($result, "\x{1F525}", 'fire emoji rendered');

	$result = csprintf('#E{tada}');
	is($result, "\x{1F389}", 'tada emoji rendered');

	$result = csprintf('#E{warning}');
	is($result, "\x{26A0}\x{FE0F} ", 'warning emoji rendered');
};

subtest 'csprintf emoji with GENESIS_NO_UTF8' => sub {
	local $ENV{NOCOLOR} = 1;
	local $ENV{GENESIS_NO_UTF8} = '1';

	my $result = csprintf('#E{fire}');
	is($result, '', 'GENESIS_NO_UTF8 suppresses emoji to empty string');
};

subtest 'csprintf fatal sprintf warnings become exceptions' => sub {
	throws_ok {
		csprintf('%s %s', 'only-one');
	} qr/Missing argument/, 'missing argument throws exception';

	throws_ok {
		csprintf('%s', 'one', 'extra');
	} qr/Redundant argument/, 'redundant argument throws exception'
		if $^V ge v5.21.0;

	throws_ok {
		my $undef;
		csprintf('%s', $undef);
	} qr/uninitialized/, 'undef argument throws exception';
};

subtest 'csprintf multiple markup types in one string' => sub {
	local $ENV{NOCOLOR} = 1;
	local $ENV{GENESIS_NO_UTF8};
	delete $ENV{GENESIS_NO_UTF8};

	my $result = csprintf('#G{ok} and #R{fail}');
	is($result, 'ok and fail', 'multiple color blocks in one string');

	$result = csprintf('prefix #G{%s} middle #R{%s} suffix', 'a', 'b');
	is($result, 'prefix a middle b suffix', 'multiple colors with format args');
};

# ── decolorize ──────────────────────────────────────────────────────────────

subtest 'decolorize plain text passes through unchanged' => sub {
	is(decolorize('hello'),             'hello',  'plain text unchanged');
	is(decolorize('no markup here'),    'no markup here', 'spaces preserved');
	is(decolorize(''),                  '',       'empty string unchanged');
	is(decolorize('123'),               '123',    'numbers unchanged');
};

subtest 'decolorize strips color markup' => sub {
	is(decolorize('#G{hello}'),     'hello',   'green markup stripped');
	is(decolorize('#R{error}'),     'error',   'red markup stripped');
	is(decolorize('#B{info}'),      'info',    'blue markup stripped');
	is(decolorize('#Y{warn}'),      'warn',    'yellow markup stripped');
	is(decolorize('#W{text}'),      'text',    'white markup stripped');
	is(decolorize('#Iu{styled}'),   'styled',  'italic+underline markup stripped');
};

subtest 'decolorize strips multiple color blocks' => sub {
	is(decolorize('#G{hello} #R{world}'), 'hello world', 'two color blocks stripped');
	is(decolorize('prefix #B{mid} suffix'), 'prefix mid suffix', 'color in middle stripped');
};

subtest 'decolorize strips emoji markup entirely' => sub {
	is(decolorize('#E{fire}'),           '', 'fire emoji stripped');
	is(decolorize('#E{warning}'),        '', 'warning emoji stripped');
	is(decolorize('text #E{fire} more'), 'text  more', 'emoji in middle stripped');
	is(decolorize('#G{hi} #E{tada}'),    'hi ', 'color + emoji stripped');
};

subtest 'decolorize strips raw ANSI escapes' => sub {
	my $ansi_green = "\e[32mhello\e[0m";
	is(decolorize($ansi_green), 'hello', 'raw ANSI green stripped');

	my $ansi_bold = "\e[1mBOLD\e[0m";
	is(decolorize($ansi_bold), 'BOLD', 'raw ANSI bold stripped');

	my $ansi_complex = "\e[1;32mtext\e[0m";
	is(decolorize($ansi_complex), 'text', 'complex ANSI sequence stripped');
};

subtest 'decolorize handles glyph markup @{} via conversion' => sub {
	local $ENV{GENESIS_NO_UTF8};
	delete $ENV{GENESIS_NO_UTF8};

	my $result = decolorize('#G@{+}');
	# After decolorize, glyph becomes plain inside #G{...} which then gets stripped
	is($result, "\x{2714} ", 'glyph markup converted and kept plain');
};

# ── csize ────────────────────────────────────────────────────────────────────

subtest 'csize returns character count for plain text' => sub {
	is(csize('hello'),  5, 'five-char string');
	is(csize('ab'),     2, 'two-char string');
	is(csize('a'),      1, 'single char');
	is(csize(''),       0, 'empty string returns 0');
};

subtest 'csize excludes color markup from count' => sub {
	is(csize('#G{hi}'),        2, 'color markup excluded from count');
	is(csize('#R{hello}'),     5, 'red markup excluded from count');
	is(csize('#G{hello} #R{world}'), 11, 'two color blocks: text + space counted');
};

subtest 'csize counts emoji display width' => sub {
	local $ENV{GENESIS_NO_UTF8};
	delete $ENV{GENESIS_NO_UTF8};

	my $fire_len = length("\x{1F525}");
	my $result = csize('#E{fire}');
	is($result, $fire_len, 'emoji character length counted via csprintf');
};

subtest 'csize handles mixed markup and plain text' => sub {
	# "prefix " = 7 + "hi" = 2 + " suffix" = 7 = 16
	is(csize('prefix #G{hi} suffix'), 16, 'mixed plain + color counted correctly');
};

done_testing;
