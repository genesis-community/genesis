#!/usr/bin/env perl
use strict;
use warnings;
use lib 't';
use helper;
use File::Temp qw/tempfile/;

use_ok 'Genesis::Log';

# ---------------------------------------------------------------------------
# Helper: create a fresh logger isolated to a single temp file.
# Resetting the singleton ensures each subtest starts from a clean state.
# ---------------------------------------------------------------------------
sub make_logger_with_file {
	my (%opts) = @_;
	$Genesis::Log::Logger = undef;
	my $logger = Genesis::Log->new();
	my ($fh, $filename) = tempfile(UNLINK => 1, SUFFIX => '.log');
	close $fh;
	$logger->configure_log($filename, %opts);
	return ($logger, $filename);
}

# ---------------------------------------------------------------------------
# AC2: All 9 convenience methods can be called without dying
# ---------------------------------------------------------------------------
subtest 'all 9 convenience methods live_ok on a configured logger' => sub {
	my ($logger, $file) = make_logger_with_file(level => 'TRACE');

	quietly {
		lives_ok { $logger->output("output message") }  'output() does not die';
		lives_ok { $logger->info("info message") }      'info() does not die';
		lives_ok { $logger->debug("debug message") }    'debug() does not die';
		lives_ok { $logger->notice("notice message") }  'notice() does not die';
		lives_ok { $logger->warning("warning message") }'warning() does not die';
		lives_ok { $logger->error("error message") }    'error() does not die';
		lives_ok { $logger->fatal("fatal message") }    'fatal() does not die';
		lives_ok { $logger->trace("trace message") }    'trace() does not die';
		lives_ok { $logger->qtrace("qtrace message") }  'qtrace() does not die';
	};
};

# ---------------------------------------------------------------------------
# AC2 + AC3: fatal does NOT terminate the process
# ---------------------------------------------------------------------------
subtest 'fatal() does not terminate the process' => sub {
	my ($logger, $file) = make_logger_with_file(level => 'TRACE');

	quietly {
		lives_ok { $logger->fatal("this should not die") }
			'fatal() logs without calling exit or die';
	};

	# Process is still running — confirm we can read back the log file
	my $contents = get_file($file);
	ok defined($contents), 'process still alive: log file is readable after fatal()';
};

# ---------------------------------------------------------------------------
# AC3: Output routing — file receives content at the correct level
# ---------------------------------------------------------------------------
subtest 'file target at TRACE level captures all convenience method output' => sub {
	my ($logger, $file) = make_logger_with_file(
		level     => 'TRACE',
		style     => 'plain',
		no_color  => 1,
		no_utf8   => 1,
		timestamp => 0,
	);

	quietly {
		$logger->output("output-payload");
		$logger->info("info-payload");
		$logger->debug("debug-payload");
		$logger->notice("notice-payload");
		$logger->warning("warning-payload");
		$logger->error("error-payload");
		$logger->fatal("fatal-payload");
		$logger->trace("trace-payload");
		$logger->qtrace("qtrace-payload");
	};

	my $contents = get_file($file);

	like $contents, qr/output-payload/,  'output() written to file';
	like $contents, qr/info-payload/,    'info() written to file';
	like $contents, qr/debug-payload/,   'debug() written to file';
	like $contents, qr/notice-payload/,  'notice() written to file';
	like $contents, qr/warning-payload/, 'warning() written to file';
	like $contents, qr/error-payload/,   'error() written to file';
	like $contents, qr/fatal-payload/,   'fatal() written to file';
	like $contents, qr/trace-payload/,   'trace() written to file';
	like $contents, qr/qtrace-payload/,  'qtrace() written to file';
};

# ---------------------------------------------------------------------------
# AC2 + AC3: Level filtering — configured at WARNING
#
# Level ordinals (from _log_item_level_map):
#   NONE=0, OUTPUT=1, FATAL=2, ERROR=2, WARNING=3, NOTICE=3,
#   INFO=4, DEBUG=5, VALUE=6, TRACE=6
#
# meets_level(configured, message) = configured_ord >= message_ord
#   WARNING(3) >= ERROR(2)   => true  — error messages appear
#   WARNING(3) >= WARNING(3) => true  — warning messages appear
#   WARNING(3) >= NOTICE(3)  => true  — notice messages appear
#   WARNING(3) >= INFO(4)    => false — info messages suppressed
#   WARNING(3) >= DEBUG(5)   => false — debug messages suppressed
#   WARNING(3) >= TRACE(6)   => false — trace messages suppressed
# ---------------------------------------------------------------------------
subtest 'level filtering: configured at WARNING filters lower-priority messages' => sub {
	my ($logger, $file) = make_logger_with_file(
		level     => 'WARNING',
		style     => 'plain',
		no_color  => 1,
		no_utf8   => 1,
		timestamp => 0,
	);

	quietly {
		$logger->error("should-appear-error");
		$logger->warning("should-appear-warning");
		$logger->notice("should-appear-notice");
		$logger->info("should-not-appear-info");
		$logger->debug("should-not-appear-debug");
		$logger->trace("should-not-appear-trace");
		$logger->qtrace("should-not-appear-qtrace");
	};

	my $contents = get_file($file);

	# Messages that meet the WARNING threshold
	like   $contents, qr/should-appear-error/,
		'error() appears when configured at WARNING (ERROR ord=2 <= WARNING ord=3)';
	like   $contents, qr/should-appear-warning/,
		'warning() appears when configured at WARNING (exact match)';
	like   $contents, qr/should-appear-notice/,
		'notice() appears when configured at WARNING (NOTICE ord=3 == WARNING ord=3)';

	# Messages below the WARNING threshold
	unlike $contents, qr/should-not-appear-info/,
		'info() suppressed when configured at WARNING (INFO ord=4 > WARNING ord=3)';
	unlike $contents, qr/should-not-appear-debug/,
		'debug() suppressed when configured at WARNING (DEBUG ord=5 > WARNING ord=3)';
	unlike $contents, qr/should-not-appear-trace/,
		'trace() suppressed when configured at WARNING (TRACE ord=6 > WARNING ord=3)';
	unlike $contents, qr/should-not-appear-qtrace/,
		'qtrace() suppressed when configured at WARNING (TRACE ord=6 > WARNING ord=3)';
};

# ---------------------------------------------------------------------------
# AC2: dump_var can be called without dying
# ---------------------------------------------------------------------------
subtest 'dump_var() can be called without dying' => sub {
	my ($logger, $file) = make_logger_with_file(level => 'TRACE');

	quietly {
		lives_ok { $logger->dump_var(foo => 'bar') }
			'dump_var(foo => bar) does not die';

		lives_ok { $logger->dump_var(count => 42, name => 'test') }
			'dump_var with multiple name/value pairs does not die';

		lives_ok { $logger->dump_var(nested => { a => 1, b => [2, 3] }) }
			'dump_var with nested reference does not die';
	};
};

# ---------------------------------------------------------------------------
# AC2 + AC3: dump_var writes Data::Dumper output to the file
# ---------------------------------------------------------------------------
subtest 'dump_var() writes variable dump to file target' => sub {
	my ($logger, $file) = make_logger_with_file(
		level     => 'TRACE',
		style     => 'plain',
		no_color  => 1,
		no_utf8   => 1,
		timestamp => 0,
	);

	quietly {
		$logger->dump_var(myvar => 'hello-dump');
	};

	my $contents = get_file($file);
	like $contents, qr/myvar/, 'dump_var writes the variable name to the log';
	like $contents, qr/hello-dump/, 'dump_var writes the variable value to the log';
};

# ---------------------------------------------------------------------------
# AC2: trace vs qtrace — style distinction via log_styles
# ---------------------------------------------------------------------------
subtest 'trace and qtrace have distinct log_styles: show_stack present/absent' => sub {
	my $trace_style  = log_styles('trace');
	my $qtrace_style = log_styles('qtrace');

	ok  exists($trace_style->{show_stack}),
		"trace style has 'show_stack' key";
	is  $trace_style->{show_stack}, 'current',
		"trace style show_stack is 'current'";

	ok !exists($qtrace_style->{show_stack}),
		"qtrace style does not have 'show_stack' key";
};

# ---------------------------------------------------------------------------
# AC3: trace writes stack annotation to file; qtrace does not
#
# When show_stack => 'current' is active and the file is at TRACE level,
# flush_logs() appends a "#Ki{...}" stack line.  We verify the behavioural
# difference by examining whether a file/line reference appears after each
# call.  We use separate loggers so the buffer for each is independent.
# ---------------------------------------------------------------------------
subtest 'trace() writes stack annotation to file; qtrace() does not' => sub {
	# --- trace: expect a stack annotation in the file ---
	my ($trace_logger, $trace_file) = make_logger_with_file(
		level     => 'TRACE',
		style     => 'plain',
		no_color  => 1,
		no_utf8   => 1,
		timestamp => 0,
	);

	quietly {
		$trace_logger->trace("trace-stack-test");
	};

	my $trace_contents = get_file($trace_file);
	like $trace_contents, qr/trace-stack-test/,
		'trace() message body appears in file';
	# The stack annotation written by flush_logs looks like " file:Lnnn"
	like $trace_contents, qr/L\d+/,
		'trace() appends a stack annotation (line reference) to file output';

	# --- qtrace: expect NO stack annotation ---
	my ($qtrace_logger, $qtrace_file) = make_logger_with_file(
		level     => 'TRACE',
		style     => 'plain',
		no_color  => 1,
		no_utf8   => 1,
		timestamp => 0,
	);

	quietly {
		$qtrace_logger->qtrace("qtrace-nostack-test");
	};

	my $qtrace_contents = get_file($qtrace_file);
	like $qtrace_contents, qr/qtrace-nostack-test/,
		'qtrace() message body appears in file';
	unlike $qtrace_contents, qr/L\d+/,
		'qtrace() does not append a stack annotation to file output';
};

# ---------------------------------------------------------------------------
# AC3: is_logging reflects configured level correctly
# ---------------------------------------------------------------------------
subtest 'is_logging returns correct results for configured file level' => sub {
	my ($logger, $file) = make_logger_with_file(level => 'WARNING');

	ok  $logger->is_logging('ERROR',   $file), 'is_logging ERROR   at WARNING => true';
	ok  $logger->is_logging('WARNING', $file), 'is_logging WARNING at WARNING => true';
	ok  $logger->is_logging('NOTICE',  $file), 'is_logging NOTICE  at WARNING => true';
	ok !$logger->is_logging('INFO',    $file), 'is_logging INFO    at WARNING => false';
	ok !$logger->is_logging('DEBUG',   $file), 'is_logging DEBUG   at WARNING => false';
	ok !$logger->is_logging('TRACE',   $file), 'is_logging TRACE   at WARNING => false';
};

# ---------------------------------------------------------------------------
# Singleton management: resetting $Genesis::Log::Logger gives fresh object
# ---------------------------------------------------------------------------
subtest 'singleton can be reset for clean test isolation' => sub {
	my $original = Genesis::Log->new();
	$original->configure_log('<terminal>', level => 'INFO');

	$Genesis::Log::Logger = undef;
	my $fresh = Genesis::Log->new();

	isnt $fresh, $original, 'after reset, new() returns a different object';
	is scalar(keys %{$fresh->{logs}}), 0,
		'fresh singleton has no configured logs';

	# Restore a clean singleton for any subsequent tests
	$Genesis::Log::Logger = undef;
	Genesis::Log->new();
};

done_testing;
