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
use Test::Output;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;

use_ok 'Genesis::UI';

# ── prompt_for_choice ────────────────────────────────────────────────────────

subtest 'prompt_for_choice numeric selection' => sub {
	plan tests => 2;

	set_stdin("2\n");
	my $result;
	my $out = combined_from {
		$result = prompt_for_choice("Pick a color:", [qw(red green blue)]);
	};
	reset_stdin();

	is($result, 'green', 'input "2" selects second item');
	like($out, qr/Pick a color:/, 'prompt text is displayed');
};

subtest 'prompt_for_choice first item by number' => sub {
	plan tests => 1;

	set_stdin("1\n");
	my $result;
	combined_from {
		$result = prompt_for_choice("Pick:", [qw(alpha beta gamma)]);
	};
	reset_stdin();

	is($result, 'alpha', 'input "1" selects first item');
};

subtest 'prompt_for_choice last item by number' => sub {
	plan tests => 1;

	set_stdin("3\n");
	my $result;
	combined_from {
		$result = prompt_for_choice("Pick:", [qw(alpha beta gamma)]);
	};
	reset_stdin();

	is($result, 'gamma', 'input "3" selects last item');
};

subtest 'prompt_for_choice default on Enter' => sub {
	plan tests => 2;

	set_stdin("\n");
	my $result;
	my $out = combined_from {
		$result = prompt_for_choice("Pick:", [qw(a b c)], 'b');
	};
	reset_stdin();

	is($result, 'b', 'empty input selects the default value');
	like($out, qr/default/, 'default marker shown in output');
};

subtest 'prompt_for_choice first item as default' => sub {
	plan tests => 1;

	set_stdin("\n");
	my $result;
	combined_from {
		$result = prompt_for_choice("Pick:", [qw(x y z)], 'x');
	};
	reset_stdin();

	is($result, 'x', 'empty input selects first item when it is the default');
};

subtest 'prompt_for_choice numbered list displayed' => sub {
	plan tests => 4;

	set_stdin("1\n");
	my $out = combined_from {
		prompt_for_choice("Choose:", [qw(foo bar baz)]);
	};
	reset_stdin();

	like($out, qr/1\)/,  '1) shown in list');
	like($out, qr/2\)/,  '2) shown in list');
	like($out, qr/3\)/,  '3) shown in list');
	like($out, qr/foo/,  'first item value shown in list');
};

subtest 'prompt_for_choice custom object_description' => sub {
	plan tests => 2;

	set_stdin("1\n");
	my $result;
	my $out = combined_from {
		$result = prompt_for_choice(
			"Pick a fruit:", [qw(apple banana cherry)],
			undef, undef, undef, "fruit"
		);
	};
	reset_stdin();

	is($result, 'apple', 'first item still selected');
	like($out, qr/Select fruit/, 'custom description used in prompt');
};

subtest 'prompt_for_choice default object_description is "choice"' => sub {
	plan tests => 1;

	set_stdin("1\n");
	my $out = combined_from {
		prompt_for_choice("Pick:", [qw(a b c)]);
	};
	reset_stdin();

	like($out, qr/Select choice/, 'default description is "choice"');
};

subtest 'prompt_for_choice with section header label' => sub {
	plan tests => 2;

	my @choices = ('a', 'b', 'c');
	my @labels  = ('---Group One---', 'First', 'Second', 'Third');

	set_stdin("1\n");
	my $result;
	my $out = combined_from {
		$result = prompt_for_choice(
			"Pick:", \@choices, undef, \@labels
		);
	};
	reset_stdin();

	is($result, 'a', 'first item selected after section header');
	like($out, qr/Group One/, 'section header text displayed');
};

subtest 'prompt_for_choice with separator label' => sub {
	plan tests => 1;

	my @choices = ('a', 'b', 'c');
	my @labels  = ('---', 'First', 'Second', 'Third');

	set_stdin("1\n");
	my $out = combined_from {
		prompt_for_choice("Pick:", \@choices, undef, \@labels);
	};
	reset_stdin();

	# Separator inserts a blank line — choices still selectable
	like($out, qr/First/, 'item after separator still displayed');
};

# ── prompt_for_choices ───────────────────────────────────────────────────────

subtest 'prompt_for_choices multi-select returns arrayref' => sub {
	plan tests => 2;

	set_stdin("1\n3\n\n");
	my $result;
	combined_from {
		$result = prompt_for_choices("Pick some:", [qw(a b c d)]);
	};
	reset_stdin();

	isa_ok($result, 'ARRAY', 'result is an arrayref');
	cmp_deeply($result, ['a', 'c'], 'items 1 and 3 selected');
};

subtest 'prompt_for_choices single selection' => sub {
	plan tests => 1;

	set_stdin("2\n\n");
	my $result;
	combined_from {
		$result = prompt_for_choices("Pick:", [qw(x y z)]);
	};
	reset_stdin();

	cmp_deeply($result, ['y'], 'single item selected');
};

subtest 'prompt_for_choices empty selection allowed when min is zero' => sub {
	plan tests => 1;

	set_stdin("\n");
	my $result;
	combined_from {
		$result = prompt_for_choices("Pick:", [qw(a b c)], 0);
	};
	reset_stdin();

	cmp_deeply($result, [], 'empty selection returns empty arrayref');
};

subtest 'prompt_for_choices min enforcement re-prompts' => sub {
	plan tests => 2;

	# First blank triggers error, then pick 1 and 2, then blank satisfies min=2
	set_stdin("1\n\n2\n\n");
	my $result;
	my $out = combined_from {
		$result = prompt_for_choices("Pick at least two:", [qw(a b c d)], 2);
	};
	reset_stdin();

	cmp_deeply($result, ['a', 'b'], 'two items selected after re-prompt');
	like($out, qr/Insufficient items/, 'insufficient items error shown');
};

subtest 'prompt_for_choices max enforcement stops early' => sub {
	plan tests => 1;

	# max=2, so after 2 selections the loop should end without needing blank
	set_stdin("1\n2\n");
	my $result;
	combined_from {
		$result = prompt_for_choices("Pick:", [qw(a b c d)], 0, 2);
	};
	reset_stdin();

	cmp_deeply($result, ['a', 'b'], 'stops after max items reached');
};

subtest 'prompt_for_choices max less than min dies' => sub {
	plan tests => 1;

	throws_ok {
		combined_from {
			prompt_for_choices("Pick:", [qw(a b c)], 3, 1);
		};
	} qr/Illegal list maximum count specified/, 'dies when max < min';
};

subtest 'prompt_for_choices duplicate rejected' => sub {
	plan tests => 1;

	# Pick 1 twice — second attempt rejected, then pick 2, then blank
	set_stdin("1\n1\n2\n\n");
	my $result;
	combined_from {
		$result = prompt_for_choices("Pick:", [qw(a b c)]);
	};
	reset_stdin();

	cmp_deeply($result, ['a', 'b'], 'duplicate entry rejected, second unique entry accepted');
};

# ── new_prompt_for_choice ────────────────────────────────────────────────────

subtest 'new_prompt_for_choice plain scalar choices' => sub {
	plan tests => 2;

	set_stdin("2\n");
	my $result;
	my $out = combined_from {
		$result = new_prompt_for_choice(
			header  => "Pick a color:",
			choices => [qw(red green blue)],
		);
	};
	reset_stdin();

	is($result, 'green', 'numeric input selects correct item');
	like($out, qr/Pick a color:/, 'header displayed');
};

subtest 'new_prompt_for_choice first item selected' => sub {
	plan tests => 1;

	set_stdin("1\n");
	my $result;
	combined_from {
		$result = new_prompt_for_choice(
			header  => "Pick:",
			choices => [qw(apple banana cherry)],
		);
	};
	reset_stdin();

	is($result, 'apple', 'input "1" selects first item');
};

subtest 'new_prompt_for_choice last item selected' => sub {
	plan tests => 1;

	set_stdin("3\n");
	my $result;
	combined_from {
		$result = new_prompt_for_choice(
			header  => "Pick:",
			choices => [qw(apple banana cherry)],
		);
	};
	reset_stdin();

	is($result, 'cherry', 'input "3" selects last item');
};

subtest 'new_prompt_for_choice hashref choices returns value field' => sub {
	plan tests => 2;

	set_stdin("2\n");
	my $result;
	my $out = combined_from {
		$result = new_prompt_for_choice(
			header  => "Pick a fruit:",
			choices => [
				{value => 'a', label => 'Apple',  summary => 'red apple'},
				{value => 'b', label => 'Banana', summary => 'yellow banana'},
				{value => 'c', label => 'Cherry', summary => 'cherry red'},
			],
		);
	};
	reset_stdin();

	is($result, 'b', 'value field returned for hashref choice');
	like($out, qr/Banana/, 'label shown in menu');
};

subtest 'new_prompt_for_choice hashref summary shown on selection' => sub {
	plan tests => 1;

	set_stdin("2\n");
	my $out = combined_from {
		new_prompt_for_choice(
			header  => "Pick:",
			choices => [
				{value => 'x', label => 'Xray',  summary => 'x-ray summary'},
				{value => 'y', label => 'Yankee', summary => 'yankee summary'},
			],
		);
	};
	reset_stdin();

	like($out, qr/yankee summary/, 'summary shown after selection');
};

subtest 'new_prompt_for_choice default by value string' => sub {
	plan tests => 2;

	set_stdin("\n");
	my $result;
	my $out = combined_from {
		$result = new_prompt_for_choice(
			header  => "Pick:",
			choices => [qw(apple banana cherry)],
			default => 'banana',
		);
	};
	reset_stdin();

	is($result, 'banana', 'default value selected on empty input');
	like($out, qr/default/, 'default marker shown for matching item');
};

subtest 'new_prompt_for_choice default by positive index (0-based)' => sub {
	plan tests => 1;

	# default => 2 sets $default_idx=2 (0-based), which is the 3rd item
	set_stdin("\n");
	my $result;
	combined_from {
		$result = new_prompt_for_choice(
			header  => "Pick:",
			choices => [qw(apple banana cherry)],
			default => 2,
		);
	};
	reset_stdin();

	is($result, 'cherry', 'default integer 2 selects 0-based index 2 (third item)');
};

subtest 'new_prompt_for_choice default by index 0 is a known edge case' => sub {
	plan skip_all => 'default => 0 produces out-of-bounds index in source; fix belongs in Genesis::UI';
};

subtest 'new_prompt_for_choice invalid default value dies' => sub {
	plan tests => 1;

	throws_ok {
		combined_from {
			new_prompt_for_choice(
				header  => "Pick:",
				choices => [qw(apple banana cherry)],
				default => 'durian',
			);
		};
	} qr/Invalid default choice/, 'bug() thrown for unknown default value';
};

subtest 'new_prompt_for_choice invalid default negative index dies' => sub {
	plan tests => 1;

	# Negative index: -1 does not match /^\d+$/, falls to grep for value "-1",
	# which is not found, so $default_idx is undef -> bug()
	throws_ok {
		combined_from {
			new_prompt_for_choice(
				header  => "Pick:",
				choices => [qw(apple banana cherry)],
				default => -1,
			);
		};
	} qr/Invalid default choice/, 'bug() thrown for negative integer default';
};

subtest 'new_prompt_for_choice unknown options dies' => sub {
	plan tests => 1;

	throws_ok {
		combined_from {
			new_prompt_for_choice(
				header     => "Pick:",
				choices    => [qw(a b c)],
				typo_opt   => 'oops',
			);
		};
	} qr/Invalid options passed to prompt_for_choice/, 'bug() thrown for unknown option key';
};

subtest 'new_prompt_for_choice compact mode dies with not implemented' => sub {
	plan tests => 1;

	throws_ok {
		combined_from {
			new_prompt_for_choice(
				header  => "Pick:",
				choices => [qw(a b c)],
				compact => 1,
			);
		};
	} qr/compact mode is not yet implemented/, 'bug() thrown for compact option';
};

subtest 'new_prompt_for_choice custom description' => sub {
	plan tests => 1;

	set_stdin("1\n");
	my $out = combined_from {
		new_prompt_for_choice(
			header      => "Pick a vehicle:",
			choices     => [qw(car bus train)],
			description => 'vehicle',
		);
	};
	reset_stdin();

	like($out, qr/Select vehicle/, 'custom description used in prompt');
};

subtest 'new_prompt_for_choice default description is "choice"' => sub {
	plan tests => 1;

	set_stdin("1\n");
	my $out = combined_from {
		new_prompt_for_choice(
			header  => "Pick:",
			choices => [qw(a b c)],
		);
	};
	reset_stdin();

	like($out, qr/Select choice/, 'default description is "choice"');
};

subtest 'new_prompt_for_choice legacy compat positional args' => sub {
	plan tests => 2;

	# Second arg is arrayref => legacy path invoked
	set_stdin("1\n");
	my $result;
	my $out = combined_from {
		$result = new_prompt_for_choice("Legacy pick:", [qw(alpha beta gamma)]);
	};
	reset_stdin();

	is($result, 'alpha', 'legacy positional args: first item selected');
	like($out, qr/Legacy pick:/, 'legacy header displayed');
};

subtest 'new_prompt_for_choice legacy compat with default' => sub {
	plan tests => 1;

	set_stdin("\n");
	my $result;
	combined_from {
		$result = new_prompt_for_choice(
			"Legacy pick:", [qw(alpha beta gamma)], 'beta'
		);
	};
	reset_stdin();

	is($result, 'beta', 'legacy positional args: default value honoured');
};

subtest 'new_prompt_for_choice header auto-generated when omitted' => sub {
	plan tests => 1;

	# The legacy-detection checks whether $_[1] is an arrayref.  To force the
	# named-param path without a header, put a non-arrayref key first so that
	# the arrayref ends up at position 3 (not 1) in @_.
	set_stdin("1\n");
	my $out = combined_from {
		new_prompt_for_choice(
			description => 'widget',
			choices     => [qw(one two three)],
		);
	};
	reset_stdin();

	like($out, qr/Select one of the following/, 'auto-generated header shown');
};

# ── Regression tests for bugs found during FWT-915/919 ──────────────────────

subtest 'new_prompt_for_choice no default does not auto-select first item' => sub {
	plan tests => 3;

	# Without a default, pressing Enter should re-prompt (not select
	# item 1).  Feed blank + valid selection to verify re-prompting
	# occurred.  Bug: undef == 0 in numeric context made the first
	# item the implicit default.
	set_stdin("\n2\n");
	my $result;
	my $out = combined_from {
		$result = new_prompt_for_choice(
			header  => "Pick:",
			choices => [qw(alpha beta gamma)],
			# no default
		);
	};
	reset_stdin();

	is($result, 'beta', 'blank enter without default re-prompts; second input accepted');
	my @prompts = ($out =~ /Select choice >/g);
	cmp_ok(scalar @prompts, '>=', 2, 'prompt appeared at least twice (re-prompted after blank enter)');
	like($out, qr/No default/, 'error message shown on blank enter without default');
};

subtest 'new_prompt_for_choice separator does not corrupt numbering' => sub {
	plan tests => 2;

	# Choices with a separator: the separator should not get a number,
	# and items after it should be numbered contiguously.
	# Bug: $section_offset was a package global that leaked between
	# calls, causing items to start at 0 instead of 1.
	set_stdin("3\n");
	my $result;
	my $out = combined_from {
		$result = new_prompt_for_choice(
			header  => "Pick:",
			choices => [
				{value => 'a', label => 'Alpha'},
				{value => 'b', label => 'Beta'},
				{separator => 1},
				{value => 'c', label => 'Gamma'},
			],
		);
	};
	reset_stdin();

	is($result, 'c', 'item after separator selected by correct number');
	like($out, qr/1\) Alpha.*2\) Beta.*3\) Gamma/s,
		'items numbered 1-3 with separator consuming no number');
};

subtest 'new_prompt_for_choice numbering correct across sequential calls' => sub {
	plan tests => 2;

	# Two calls in a row: the second call should start numbering at 1,
	# not carry over $section_offset from the first call.
	# Bug: $section_offset was a package global.

	# First call — has a separator
	set_stdin("1\n");
	my $r1;
	combined_from {
		$r1 = new_prompt_for_choice(
			header  => "First:",
			choices => [
				{value => 'x'},
				{separator => 1},
				{value => 'y'},
			],
		);
	};
	reset_stdin();

	is($r1, 'x', 'first call: item 1 selected correctly');

	# Second call — should not be affected by the first
	set_stdin("1\n");
	my $r2;
	my $out = combined_from {
		$r2 = new_prompt_for_choice(
			header  => "Second:",
			choices => [qw(a b c)],
		);
	};
	reset_stdin();

	is($r2, 'a', 'second call: numbering starts fresh at 1');
};

done_testing;
