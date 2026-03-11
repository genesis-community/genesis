#!/usr/bin/env perl
use strict;
use warnings;
use lib 't';
use helper;

use_ok 'Genesis::Log';

# ---------------------------------------------------------------------------
# get_stack() tests
# ---------------------------------------------------------------------------

subtest 'get_stack(0) returns a non-empty list' => sub {
	my @stack;
	lives_ok { @stack = get_stack(0) } 'get_stack(0) does not die';
	ok scalar(@stack) > 0, 'get_stack(0) returns at least one frame';
};

subtest 'each frame is a hashref' => sub {
	my @stack = get_stack(0);
	for my $i (0 .. $#stack) {
		is ref($stack[$i]), 'HASH', "frame $i is a hashref";
	}
};

subtest 'each frame has a file key' => sub {
	my @stack = get_stack(0);
	for my $i (0 .. $#stack) {
		ok exists($stack[$i]{file}), "frame $i has a 'file' key";
		ok defined($stack[$i]{file}), "frame $i 'file' is defined";
		is ref(\$stack[$i]{file}), 'SCALAR', "frame $i 'file' is a plain string";
	}
};

subtest 'each frame has a line key with a positive integer' => sub {
	my @stack = get_stack(0);
	for my $i (0 .. $#stack) {
		ok exists($stack[$i]{line}), "frame $i has a 'line' key";
		ok defined($stack[$i]{line}), "frame $i 'line' is defined";
		like $stack[$i]{line}, qr/^\d+$/, "frame $i 'line' is numeric";
		ok $stack[$i]{line} > 0, "frame $i 'line' is a positive integer";
	}
};

subtest 'frames may have a sub key; outermost frame need not' => sub {
	my @stack = get_stack(0);

	# At least some frames may carry a sub key — just check those that exist
	# are non-empty strings (the outermost frame legally omits it).
	my $had_sub = 0;
	for my $i (0 .. $#stack) {
		if (exists $stack[$i]{sub}) {
			is ref(\$stack[$i]{sub}), 'SCALAR',
				"frame $i 'sub', when present, is a plain string";
			$had_sub = 1;
		}
	}

	# The outermost frame (last element) should not have a sub key because
	# get_stack() pushes the final frame without one.
	ok !exists($stack[-1]{sub}),
		'outermost (last) frame does not carry a sub key';

	# Suppress "no tests run" if the stack happened to be depth-1 and no sub
	# key appeared — just note it rather than failing.
	note "Inner frames with sub keys found: $had_sub" unless $had_sub;
};

subtest 'higher scope offset returns fewer frames' => sub {
	my @stack0 = get_stack(0);
	my @stack5 = get_stack(5);
	ok scalar(@stack0) > scalar(@stack5),
		'get_stack(0) returns more frames than get_stack(5)';
};

subtest 'frames returned from within a subtest include caller info' => sub {
	# Call get_stack() from inside a nested subtest to confirm the call site
	# appears in the returned frames.
	my @stack;
	my $call_line;
	subtest 'inner subtest for stack capture' => sub {
		$call_line = __LINE__ + 1;
		@stack = get_stack(0);
		ok scalar(@stack) > 0, 'stack is non-empty inside nested subtest';
	};

	# Match on both filename (substring — get_stack humanizes paths) and
	# exact line number to avoid false positives from unrelated frames.
	my $found_call_site = grep {
		$_->{file} =~ /genesis_log-stack\.t/ && $_->{line} == $call_line
	} @stack;
	ok $found_call_site > 0,
		'stack includes a frame for the get_stack() call site in this file';
};

# ---------------------------------------------------------------------------
# get_scope() tests
#
# NOTE: FWT-701 #1 documented a bug where get_scope() called a non-existent
# _get_stack() helper.  The code in this worktree has been corrected to call
# get_stack() instead (Log.pm line 587).  The tests below therefore test the
# corrected, working behaviour.  If the bug is somehow still present the
# lives_ok assertion will catch it.
# ---------------------------------------------------------------------------

subtest 'get_scope(0) returns a defined string' => sub {
	my $scope;
	lives_ok { $scope = get_scope(0) } 'get_scope(0) does not die';
	ok defined($scope), 'get_scope(0) returns a defined value';
	is ref(\$scope), 'SCALAR', 'get_scope(0) returns a plain string';
};

subtest 'get_scope return value contains the caller filename' => sub {
	my $scope = get_scope(0);
	like $scope, qr/genesis_log-stack\.t/,
		'scope string contains the name of this test file';
};

subtest 'get_scope return value contains a line number marker' => sub {
	my $scope = get_scope(0);
	like $scope, qr/L\d+/,
		'scope string contains a line-number marker matching /L\d+/';
};

subtest 'get_scope returns a non-empty string' => sub {
	my $scope = get_scope(0);
	ok length($scope) > 0, 'get_scope(0) returns a non-empty string';
};

subtest 'get_scope without GENESIS_STACK_TRACE emits a single frame' => sub {
	# Each rendered frame occupies exactly 2 segments when split on "\n"
	# (the ANSI-coloured file:line run, then the ANSI-reset suffix).
	# Without GENESIS_STACK_TRACE only the innermost frame is emitted.
	local $ENV{GENESIS_STACK_TRACE};
	delete $ENV{GENESIS_STACK_TRACE};

	my $scope_from_depth = sub { get_scope(0) };
	my $scope = $scope_from_depth->();
	my @segs = split /\n/, $scope;
	is scalar(@segs), 2,
		'without GENESIS_STACK_TRACE get_scope emits exactly one frame (2 ANSI segments)';
};

subtest 'get_scope with GENESIS_STACK_TRACE emits multiple frames' => sub {
	# With GENESIS_STACK_TRACE every frame in the call stack is appended.
	# Calling through a helper sub guarantees at least 2 frames, giving >= 4 segments.
	local $ENV{GENESIS_STACK_TRACE} = '1';

	my $scope_from_depth_trace = sub { get_scope(0) };
	my $scope = $scope_from_depth_trace->();
	my @segs = split /\n/, $scope;
	ok scalar(@segs) > 2,
		'with GENESIS_STACK_TRACE get_scope emits more than one frame (> 2 ANSI segments)';
};

done_testing;
