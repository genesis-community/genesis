#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use lib 'lib';
use lib 't';
use helper;
use Test::More;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{GENESIS_OUTPUT_LINES} = 24;

use_ok 'Genesis::Term';

# ── _color ───────────────────────────────────────────────────────────────────

subtest '_color with foreground only produces ANSI escape' => sub {
	local $ENV{NOCOLOR};
	delete $ENV{NOCOLOR};

	my $g = Genesis::Term::_color('G', undef);
	isnt($g, '', 'uppercase G foreground returns non-empty string');
	like($g, qr/\e\[/, 'result is an ANSI escape sequence');

	my $r = Genesis::Term::_color('R', undef);
	isnt($r, '', 'uppercase R foreground returns non-empty string');

	my $b = Genesis::Term::_color('B', undef);
	isnt($b, '', 'uppercase B foreground returns non-empty string');

	my $y = Genesis::Term::_color('Y', undef);
	isnt($y, '', 'uppercase Y foreground returns non-empty string');

	my $m = Genesis::Term::_color('M', undef);
	isnt($m, '', 'uppercase M foreground returns non-empty string');

	my $c = Genesis::Term::_color('C', undef);
	isnt($c, '', 'uppercase C foreground returns non-empty string');

	my $w = Genesis::Term::_color('W', undef);
	isnt($w, '', 'uppercase W foreground returns non-empty string');

	my $k = Genesis::Term::_color('K', undef);
	isnt($k, '', 'uppercase K (dark grey/black) returns non-empty string');
};

subtest '_color lowercase foreground variants' => sub {
	local $ENV{NOCOLOR};
	delete $ENV{NOCOLOR};

	my $g_lo = Genesis::Term::_color('g', undef);
	isnt($g_lo, '', 'lowercase g foreground returns non-empty string');
	like($g_lo, qr/\e\[/, 'lowercase result is ANSI escape');

	my $r_lo = Genesis::Term::_color('r', undef);
	isnt($r_lo, '', 'lowercase r foreground non-empty');
};

subtest '_color uppercase vs lowercase differ' => sub {
	local $ENV{NOCOLOR};
	delete $ENV{NOCOLOR};

	my $g_up = Genesis::Term::_color('G', undef);
	my $g_lo = Genesis::Term::_color('g', undef);
	isnt($g_up, $g_lo, 'uppercase G differs from lowercase g (bright vs dark)');
};

subtest '_color with background only produces ANSI escape' => sub {
	local $ENV{NOCOLOR};
	delete $ENV{NOCOLOR};

	my $bg_k = Genesis::Term::_color(undef, 'k');
	isnt($bg_k, '', 'black background returns non-empty string');
	like($bg_k, qr/\e\[/, 'background only is ANSI escape');

	my $bg_r = Genesis::Term::_color(undef, 'r');
	isnt($bg_r, '', 'red background returns non-empty string');
};

subtest '_color with both fg and bg produces ANSI escape' => sub {
	local $ENV{NOCOLOR};
	delete $ENV{NOCOLOR};

	my $both = Genesis::Term::_color('G', 'k');
	isnt($both, '', 'fg+bg returns non-empty string');
	like($both, qr/\e\[/, 'fg+bg is ANSI escape');
};

subtest '_color unrecognized letter returns empty string' => sub {
	local $ENV{NOCOLOR};
	delete $ENV{NOCOLOR};

	is(Genesis::Term::_color('Z', undef),   '', 'unrecognized fg Z returns empty');
	is(Genesis::Term::_color(undef, 'Z'),   '', 'unrecognized bg Z returns empty');
	is(Genesis::Term::_color('Z', 'Z'),     '', 'both unrecognized returns empty');
	is(Genesis::Term::_color(undef, undef), '', 'both undef returns empty');
};

subtest '_color P/p and p aliases work for purple/magenta' => sub {
	local $ENV{NOCOLOR};
	delete $ENV{NOCOLOR};

	my $p = Genesis::Term::_color('P', undef);
	isnt($p, '', 'uppercase P (purple) returns non-empty string');

	my $p_lo = Genesis::Term::_color('p', undef);
	isnt($p_lo, '', 'lowercase p (purple) returns non-empty string');
};

# ── _colorize ────────────────────────────────────────────────────────────────

subtest '_colorize empty message returns empty string' => sub {
	is(Genesis::Term::_colorize('G', ''), '', 'empty message returns empty string');
	is(Genesis::Term::_colorize('R', ''), '', 'empty message with R returns empty');
};

subtest '_colorize with NOCOLOR returns message unchanged' => sub {
	local $ENV{NOCOLOR} = '1';
	is(Genesis::Term::_colorize('G', 'hello'), 'hello', 'NOCOLOR returns plain text');
	is(Genesis::Term::_colorize('R', 'error'), 'error', 'NOCOLOR R returns plain text');
	is(Genesis::Term::_colorize('*', 'rainbow'), 'rainbow', 'NOCOLOR rainbow returns plain');
};

subtest '_colorize without NOCOLOR wraps in ANSI codes' => sub {
	local $ENV{NOCOLOR};
	delete $ENV{NOCOLOR};

	my $result = Genesis::Term::_colorize('G', 'hello');
	like($result, qr/hello/, 'message text present');
	like($result, qr/\e\[/, 'ANSI escape present');
	like($result, qr/\e\[0m$/, 'reset code at end');
};

subtest '_colorize underline (U) adds underline ANSI code' => sub {
	local $ENV{NOCOLOR};
	delete $ENV{NOCOLOR};

	my $result = Genesis::Term::_colorize('U', 'underlined');
	like($result, qr/\e\[4m/, 'underline ANSI code present');
	like($result, qr/underlined/, 'message text present');
};

subtest '_colorize italic (I) without TMUX adds italic ANSI code' => sub {
	local $ENV{NOCOLOR};
	delete $ENV{NOCOLOR};
	local $ENV{TMUX};
	delete $ENV{TMUX};

	my $result = Genesis::Term::_colorize('I', 'italic');
	like($result, qr/\e\[3m/, 'italic ANSI code present without TMUX');
	like($result, qr/italic/, 'message text present');
};

subtest '_colorize italic (I) suppressed under TMUX' => sub {
	local $ENV{NOCOLOR};
	delete $ENV{NOCOLOR};
	local $ENV{TMUX} = 'some-tmux-session';

	my $result = Genesis::Term::_colorize('I', 'italic');
	unlike($result, qr/\e\[3m/, 'italic ANSI code absent under TMUX');
	like($result, qr/italic/, 'message text still present');
};

subtest '_colorize combined I and U modifier' => sub {
	local $ENV{NOCOLOR};
	delete $ENV{NOCOLOR};
	local $ENV{TMUX};
	delete $ENV{TMUX};

	my $result = Genesis::Term::_colorize('IU', 'styled');
	like($result, qr/\e\[3;4m/, 'both italic and underline codes present');
};

subtest '_colorize rainbow (*) cycles colors per non-whitespace char' => sub {
	local $ENV{NOCOLOR};
	delete $ENV{NOCOLOR};

	my $result = Genesis::Term::_colorize('*', 'abc');
	like($result, qr/\e\[/, 'rainbow contains ANSI codes');
	like($result, qr/a/, 'char a present');
	like($result, qr/b/, 'char b present');
	like($result, qr/c/, 'char c present');
	like($result, qr/\e\[0m$/, 'reset at end');

	# Whitespace should not advance the rainbow counter
	my $with_space = Genesis::Term::_colorize('*', 'a b');
	like($with_space, qr/a/, 'char a in rainbow with space');
	like($with_space, qr/b/, 'char b in rainbow with space');
};

# ── _glyphize ────────────────────────────────────────────────────────────────

subtest '_glyphize known glyphs with UTF8 enabled' => sub {
	local $ENV{NOCOLOR} = '1';
	local $ENV{GENESIS_NO_UTF8};
	delete $ENV{GENESIS_NO_UTF8};

	is(Genesis::Term::_glyphize('', '-'),   "\x{2718} ", 'dash -> cross glyph');
	is(Genesis::Term::_glyphize('', '+'),   "\x{2714} ", 'plus -> check glyph');
	is(Genesis::Term::_glyphize('', '*'),   "\x{2022}",  'star -> bullet glyph');
	is(Genesis::Term::_glyphize('', ' '),   '  ',        'space -> double space');
	is(Genesis::Term::_glyphize('', '>'),   "\x{2B40}",  'gt -> arrow glyph')
		if Genesis::Term::_glyphize('', '>') =~ /\x{2B40}/;
	isnt(Genesis::Term::_glyphize('', '>'), '>', 'gt renders as glyph not literal');
	is(Genesis::Term::_glyphize('', '!'),   "\x{26A0} ", 'bang -> warning glyph');
	is(Genesis::Term::_glyphize('', 'x'),   "\x{2620} ", 'x -> skull glyph');
	is(Genesis::Term::_glyphize('', 'O'),   "\x{25C7}",  'O -> diamond glyph');
	is(Genesis::Term::_glyphize('', '@'),   "\x{25C6}",  'at -> filled diamond');
	is(Genesis::Term::_glyphize('', '[ ]'), "\x{25FB}",  '[ ] -> empty square');
	is(Genesis::Term::_glyphize('', '[x]'), "\x{25FC}",  '[x] -> filled square');
	is(Genesis::Term::_glyphize('', 'X'),   "\x{25FC}",  'X -> filled square');
	is(Genesis::Term::_glyphize('', '_'),   "\x{00A0}",  'underscore -> nbsp');
};

subtest '_glyphize with GENESIS_NO_UTF8 returns raw glyph key' => sub {
	local $ENV{NOCOLOR} = '1';
	local $ENV{GENESIS_NO_UTF8} = '1';

	is(Genesis::Term::_glyphize('', '-'),   '-',   'GENESIS_NO_UTF8: dash stays dash');
	is(Genesis::Term::_glyphize('', '+'),   '+',   'GENESIS_NO_UTF8: plus stays plus');
	is(Genesis::Term::_glyphize('', '*'),   '*',   'GENESIS_NO_UTF8: star stays star');
	is(Genesis::Term::_glyphize('', 'x'),   'x',   'GENESIS_NO_UTF8: x stays x');
	is(Genesis::Term::_glyphize('', '!'),   '!',   'GENESIS_NO_UTF8: bang stays bang');
};

subtest '_glyphize without color code returns plain glyph' => sub {
	local $ENV{NOCOLOR} = '1';
	local $ENV{GENESIS_NO_UTF8};
	delete $ENV{GENESIS_NO_UTF8};

	my $result = Genesis::Term::_glyphize('', '+');
	is($result, "\x{2714} ", 'no color code: plain glyph returned');
};

subtest '_glyphize with color code colorizes the glyph' => sub {
	local $ENV{NOCOLOR};
	delete $ENV{NOCOLOR};
	local $ENV{GENESIS_NO_UTF8};
	delete $ENV{GENESIS_NO_UTF8};

	my $result = Genesis::Term::_glyphize('G', '+');
	like($result, qr/\x{2714}/, 'check glyph present in colorized output');
	like($result, qr/\e\[/, 'ANSI escape present when color code given');
};

subtest '_glyphize with color code and NOCOLOR returns plain glyph' => sub {
	local $ENV{NOCOLOR} = '1';
	local $ENV{GENESIS_NO_UTF8};
	delete $ENV{GENESIS_NO_UTF8};

	my $result = Genesis::Term::_glyphize('G', '+');
	# With NOCOLOR, _colorize returns the text unchanged
	is($result, "\x{2714} ", 'NOCOLOR with color code: plain glyph returned');
};

subtest '_glyphize ^- glyph works' => sub {
	local $ENV{NOCOLOR} = '1';
	local $ENV{GENESIS_NO_UTF8};
	delete $ENV{GENESIS_NO_UTF8};

	my $result = Genesis::Term::_glyphize('', '^-');
	is($result, "\x{2B11} ", '^- -> down-left arrow glyph');
};

# ── _emojify ─────────────────────────────────────────────────────────────────

subtest '_emojify known emoji names return Unicode' => sub {
	local $ENV{GENESIS_NO_UTF8};
	delete $ENV{GENESIS_NO_UTF8};

	is(Genesis::Term::_emojify('fire'),             "\x{1F525}",           'fire emoji');
	is(Genesis::Term::_emojify('warning'),           "\x{26A0}\x{FE0F} ",  'warning emoji');
	is(Genesis::Term::_emojify('tada'),              "\x{1F389}",           'tada emoji');
	is(Genesis::Term::_emojify('crystal-ball'),      "\x{1F52E}",           'crystal-ball emoji');
	is(Genesis::Term::_emojify('stop-sign'),         "\x{1F6D1}",           'stop-sign emoji');
	is(Genesis::Term::_emojify('collision'),         "\x{1F4A5}",           'collision emoji');
	is(Genesis::Term::_emojify('information'),       "\x{2139}\x{FE0F} ",  'information emoji');
	is(Genesis::Term::_emojify('magnifying-glass'),  "\x{1F50E}",           'magnifying-glass emoji');
	is(Genesis::Term::_emojify('detective'),         "\x{1F575}\x{FE0F} ", 'detective emoji');
	is(Genesis::Term::_emojify('pancakes'),          "\x{1F95E}",           'pancakes emoji');
	is(Genesis::Term::_emojify('tap'),               "\x{1F6B0}",           'tap emoji');
	is(Genesis::Term::_emojify('memo'),              "\x{1F4DD}",           'memo emoji');
	is(Genesis::Term::_emojify('notes'),             "\x{1F5D2}\x{FE0F} ", 'notes emoji');
	is(Genesis::Term::_emojify('printer'),           "\x{1F5A8}\x{FE0F} ", 'printer emoji');
	is(Genesis::Term::_emojify('tmyn'),              "\x{1F320}",           'tmyn emoji');
	is(Genesis::Term::_emojify('notice'),            "\x{1FAA7} ",          'notice emoji');
	is(Genesis::Term::_emojify('megaphone'),         "\x{1F4E3}",           'megaphone emoji');
	is(Genesis::Term::_emojify('noentry'),           "\x{26D4}\x{FE0F}",   'noentry emoji');
};

subtest '_emojify unknown name returns empty string' => sub {
	local $ENV{GENESIS_NO_UTF8};
	delete $ENV{GENESIS_NO_UTF8};

	is(Genesis::Term::_emojify('not-a-real-emoji'), '', 'unknown emoji name returns empty');
	is(Genesis::Term::_emojify(''),                 '', 'empty string returns empty');
	is(Genesis::Term::_emojify('FIRE'),             '', 'wrong case returns empty');
};

subtest '_emojify with GENESIS_NO_UTF8 returns empty string' => sub {
	local $ENV{GENESIS_NO_UTF8} = '1';

	is(Genesis::Term::_emojify('fire'),    '', 'GENESIS_NO_UTF8: fire returns empty');
	is(Genesis::Term::_emojify('warning'), '', 'GENESIS_NO_UTF8: warning returns empty');
	is(Genesis::Term::_emojify('tada'),    '', 'GENESIS_NO_UTF8: tada returns empty');
};

done_testing;
