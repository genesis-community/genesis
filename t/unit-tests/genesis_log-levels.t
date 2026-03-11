#!/usr/bin/env perl
use strict;
use warnings;
use lib 't';
use helper;

use_ok 'Genesis::Log';

# level_ord is not in @EXPORT so we alias it for readability
*level_ord = \&Genesis::Log::level_ord;

# ── log_levels() ────────────────────────────────────────────────────────────

subtest 'log_levels returns the seven user-facing level names' => sub {
	my @levels = log_levels();

	is scalar(@levels), 7, 'log_levels() returns exactly 7 names';

	is_deeply \@levels,
		[qw/NONE OUTPUT ERROR WARNING INFO DEBUG TRACE/],
		'level names are in the correct order';
};

# ── level_ord() ─────────────────────────────────────────────────────────────

subtest 'level_ord returns correct ordinals for every known level' => sub {
	is level_ord('NONE'),    0, 'NONE    => 0';
	is level_ord('OUTPUT'),  1, 'OUTPUT  => 1';
	is level_ord('FATAL'),   2, 'FATAL   => 2';
	is level_ord('ERROR'),   2, 'ERROR   => 2';
	is level_ord('WARNING'), 3, 'WARNING => 3';
	is level_ord('NOTICE'),  3, 'NOTICE  => 3';
	is level_ord('INFO'),    4, 'INFO    => 4';
	is level_ord('DEBUG'),   5, 'DEBUG   => 5';
	is level_ord('VALUE'),   6, 'VALUE   => 6';
	is level_ord('TRACE'),   6, 'TRACE   => 6';
	is level_ord('STACK'),   6, 'STACK   => 6';
};

subtest 'level_ord returns undef for unknown level names' => sub {
	is level_ord('BOGUS'),   undef, 'BOGUS returns undef';
	is level_ord(''),        undef, 'empty string returns undef';
	is level_ord('verbose'), undef, 'lowercase unknown returns undef';
};

subtest 'level_ord applies uc() to its argument' => sub {
	# level_ord calls uc() internally, so lower-case known names resolve
	is level_ord('debug'),   5, 'debug (lowercase) => 5';
	is level_ord('trace'),   6, 'trace (lowercase) => 6';
	is level_ord('warning'), 3, 'warning (lowercase) => 3';
};

# ── find_log_level() ─────────────────────────────────────────────────────────

subtest 'find_log_level - full name lookup (uppercase)' => sub {
	is find_log_level('DEBUG'),   'DEBUG',   'DEBUG   => DEBUG';
	is find_log_level('ERROR'),   'ERROR',   'ERROR   => ERROR';
	is find_log_level('INFO'),    'INFO',    'INFO    => INFO';
	is find_log_level('TRACE'),   'TRACE',   'TRACE   => TRACE';
	is find_log_level('OUTPUT'),  'OUTPUT',  'OUTPUT  => OUTPUT';
	is find_log_level('WARNING'), 'WARNING', 'WARNING => WARNING';
};

subtest 'find_log_level - case-insensitive full name lookup' => sub {
	is find_log_level('debug'),   'DEBUG',   'debug   => DEBUG';
	is find_log_level('trace'),   'TRACE',   'trace   => TRACE';
	is find_log_level('info'),    'INFO',    'info    => INFO';
	is find_log_level('error'),   'ERROR',   'error   => ERROR';
	is find_log_level('warning'), 'WARNING', 'warning => WARNING';
	is find_log_level('output'),  'OUTPUT',  'output  => OUTPUT';
};

subtest 'find_log_level - NONE is handled via prefix matching (level_ord 0 is falsy)' => sub {
	# level_ord('NONE') == 0, which is falsy, so find_log_level falls through
	# to prefix matching. 'NONE' matches only 'NONE', so it resolves correctly.
	is find_log_level('NONE'), 'NONE', 'NONE resolves to NONE via prefix path';
	is find_log_level('none'), 'NONE', 'none resolves to NONE (case-insensitive prefix)';
};

subtest 'find_log_level - unambiguous prefix lookup' => sub {
	is find_log_level('TRAC'),  'TRACE',   'TRAC   => TRACE';
	is find_log_level('DEB'),   'DEBUG',   'DEB    => DEBUG';
	is find_log_level('WAR'),   'WARNING', 'WAR    => WARNING';
	is find_log_level('OUT'),   'OUTPUT',  'OUT    => OUTPUT';
	is find_log_level('trac'),  'TRACE',   'trac   => TRACE (prefix, lowercase)';
	is find_log_level('deb'),   'DEBUG',   'deb    => DEBUG (prefix, lowercase)';
};

# Note: No ambiguous prefix test — the 7 user-facing levels (NONE, OUTPUT,
# ERROR, WARNING, INFO, DEBUG, TRACE) each have distinct first letters, so
# no prefix can match more than one level.  The ambiguous code path in
# find_log_level() is unreachable with the current level set.

subtest 'find_log_level - invalid level name dies' => sub {
	quietly {
		throws_ok { find_log_level('BOGUS') }
			qr/Not a valid log level 'BOGUS'/,
			'BOGUS dies with "Not a valid log level" message';

		throws_ok { find_log_level('XYZ') }
			qr/Not a valid log level 'XYZ'/,
			'XYZ dies with "Not a valid log level" message';

		throws_ok { find_log_level('verbose') }
			qr/Not a valid log level 'VERBOSE'/,
			'verbose (mapped to VERBOSE) dies with "Not a valid log level" message';
	};
};

subtest 'find_log_level - invalid level error lists valid levels' => sub {
	my $err;
	quietly {
		eval { find_log_level('BOGUS') };
		$err = $@;
	};
	like $err, qr/NONE/,    'error message mentions NONE';
	like $err, qr/OUTPUT/,  'error message mentions OUTPUT';
	like $err, qr/ERROR/,   'error message mentions ERROR';
	like $err, qr/WARNING/, 'error message mentions WARNING';
	like $err, qr/INFO/,    'error message mentions INFO';
	like $err, qr/DEBUG/,   'error message mentions DEBUG';
	like $err, qr/TRACE/,   'error message mentions TRACE';
};

# ── meets_level() ────────────────────────────────────────────────────────────

subtest 'meets_level - current level exceeds target (passes)' => sub {
	ok  meets_level('DEBUG', 'INFO'),  'DEBUG(5) >= INFO(4)  => true';
	ok  meets_level('TRACE', 'ERROR'), 'TRACE(6) >= ERROR(2) => true';
	ok  meets_level('TRACE', 'NONE'),  'TRACE(6) >= NONE(0)  => true';
	ok  meets_level('INFO',  'NONE'),  'INFO(4)  >= NONE(0)  => true';
	ok  meets_level('DEBUG', 'OUTPUT'),'DEBUG(5) >= OUTPUT(1)=> true';
};

subtest 'meets_level - current level equals target (passes)' => sub {
	ok  meets_level('INFO',    'INFO'),    'INFO(4)    >= INFO(4)    => true';
	ok  meets_level('DEBUG',   'DEBUG'),   'DEBUG(5)   >= DEBUG(5)   => true';
	ok  meets_level('TRACE',   'TRACE'),   'TRACE(6)   >= TRACE(6)   => true';
	ok  meets_level('ERROR',   'ERROR'),   'ERROR(2)   >= ERROR(2)   => true';
	ok  meets_level('WARNING', 'WARNING'), 'WARNING(3) >= WARNING(3) => true';
	ok  meets_level('NONE',    'NONE'),    'NONE(0)    >= NONE(0)    => true';
};

subtest 'meets_level - current level below target (fails)' => sub {
	ok !meets_level('INFO',  'DEBUG'),  'INFO(4)  >= DEBUG(5)  => false';
	ok !meets_level('ERROR', 'TRACE'),  'ERROR(2) >= TRACE(6)  => false';
	ok !meets_level('NONE',  'TRACE'),  'NONE(0)  >= TRACE(6)  => false';
	ok !meets_level('NONE',  'INFO'),   'NONE(0)  >= INFO(4)   => false';
	ok !meets_level('OUTPUT','WARNING'),'OUTPUT(1)>= WARNING(3)=> false';
};

subtest 'meets_level - accepts raw numeric ordinal values' => sub {
	# meets_level checks values of _log_item_level_map(); numerics that appear
	# as map values (0-6) skip the level_ord() conversion step.
	ok  meets_level(5, 4), 'numeric 5 >= numeric 4 => true';
	ok  meets_level(6, 0), 'numeric 6 >= numeric 0 => true';
	ok  meets_level(4, 4), 'numeric 4 >= numeric 4 => true';
	ok !meets_level(2, 6), 'numeric 2 >= numeric 6 => false';
	ok !meets_level(0, 6), 'numeric 0 >= numeric 6 => false';
};

done_testing;
