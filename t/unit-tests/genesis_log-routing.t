#!/usr/bin/env perl
use strict;
use warnings;
use lib 't';
use helper;
use File::Temp qw/tempdir/;

use_ok 'Genesis::Log';

# ---------------------------------------------------------------------------
# configure_log() — terminal target (no path argument)
# ---------------------------------------------------------------------------

subtest 'configure_log() with no args configures terminal target and returns $self' => sub {
    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();

    my $ret;
    lives_ok { $ret = $logger->configure_log() } 'configure_log() does not die';
    is $ret, $logger, 'configure_log() returns $self for chaining';
};

subtest 'configure_log() creates <terminal> entry in logs hash' => sub {
    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();
    $logger->configure_log();

    ok exists($logger->{logs}{'<terminal>'}),
        'logs hash contains <terminal> key after configure_log()';
    is ref($logger->{logs}{'<terminal>'}), 'HASH',
        '<terminal> value is a hashref';
};

subtest 'terminal target has expected default keys' => sub {
    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();
    $logger->configure_log();

    my $t = $logger->{logs}{'<terminal>'};

    ok exists($t->{level}),      'terminal config has level key';
    ok exists($t->{level_ord}),  'terminal config has level_ord key';
    ok exists($t->{show_stack}), 'terminal config has show_stack key';
    ok exists($t->{timestamp}),  'terminal config has timestamp key';
    ok exists($t->{next_entry}), 'terminal config has next_entry key';
    ok exists($t->{style}),      'terminal config has style key';
};

subtest 'terminal target defaults: timestamp => 0, show_stack => none, next_entry => 0' => sub {
    no warnings 'once';
    $Genesis::Log::Logger = undef;
    local $ENV{QUIET}         = undef;
    local $ENV{GENESIS_TRACE} = undef;
    local $ENV{GENESIS_DEBUG} = undef;
    my $logger = Genesis::Log->new();
    $logger->configure_log();

    my $t = $logger->{logs}{'<terminal>'};

    is $t->{timestamp},  0,      'terminal timestamp defaults to 0';
    is $t->{show_stack}, 'none', 'terminal show_stack defaults to none';
    is $t->{next_entry}, 0,      'terminal next_entry defaults to 0';
};

subtest 'configure_log(level => DEBUG) sets terminal level to DEBUG' => sub {
    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();
    $logger->configure_log(level => 'DEBUG');

    my $t = $logger->{logs}{'<terminal>'};

    is $t->{level},     'DEBUG', 'level is DEBUG';
    is $t->{level_ord}, Genesis::Log::level_ord('DEBUG'),
        'level_ord matches DEBUG ordinal';
};

subtest 'configure_log chaining: configure_log()->configure_log() works' => sub {
    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();

    my $ret;
    lives_ok {
        $ret = $logger->configure_log(level => 'DEBUG')
                      ->configure_log(level => 'TRACE');
    } 'chained configure_log calls do not die';

    is $ret, $logger, 'chain returns $self';
    is $logger->{logs}{'<terminal>'}{level}, 'TRACE',
        'second configure_log call overrides level to TRACE';
};

# ---------------------------------------------------------------------------
# configure_log() — file target
# ---------------------------------------------------------------------------

subtest 'configure_log($path) creates a file target entry' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $path = "$dir/test.log";

    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();

    lives_ok { $logger->configure_log($path) }
        'configure_log(path) does not die';

    ok exists($logger->{logs}{$path}),
        "logs hash contains the file path key '$path'";
};

subtest 'file target has timestamp => 1 by default (unlike terminal)' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $path = "$dir/test-ts.log";

    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();
    $logger->configure_log($path);

    is $logger->{logs}{$path}{timestamp}, 1,
        'file target timestamp defaults to 1';
};

subtest 'configure_log($path, level => DEBUG) sets file target level' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $path = "$dir/test-level.log";

    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();
    $logger->configure_log($path, level => 'DEBUG');

    is $logger->{logs}{$path}{level}, 'DEBUG',
        'file target level set to DEBUG';
};

subtest 'configure_log returns $self for file target too' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $path = "$dir/test-chain.log";

    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();

    my $ret;
    lives_ok { $ret = $logger->configure_log($path, level => 'INFO') }
        'configure_log with file path does not die';

    is $ret, $logger, 'configure_log(path) returns $self';
};

# ---------------------------------------------------------------------------
# is_logging()
# ---------------------------------------------------------------------------

subtest 'is_logging returns false for unconfigured target' => sub {
    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();

    # No configure_log called — terminal is not set up
    my $result = $logger->is_logging('DEBUG');
    is $result, 0, 'is_logging on unconfigured target returns 0';
};

subtest 'is_logging with terminal at DEBUG: DEBUG and INFO true, TRACE false' => sub {
    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();
    $logger->configure_log(level => 'DEBUG');

    ok  $logger->is_logging('DEBUG'),   'is_logging(DEBUG) true when level=DEBUG';
    ok  $logger->is_logging('INFO'),    'is_logging(INFO) true when level=DEBUG';
    ok  $logger->is_logging('WARNING'), 'is_logging(WARNING) true when level=DEBUG';
    ok  $logger->is_logging('ERROR'),   'is_logging(ERROR) true when level=DEBUG';
    ok !$logger->is_logging('TRACE'),   'is_logging(TRACE) false when level=DEBUG';
};

subtest 'is_logging for a specific file target' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $path = "$dir/specific.log";

    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();
    $logger->configure_log($path, level => 'DEBUG');

    ok  $logger->is_logging('DEBUG', $path),
        'is_logging(DEBUG, path) true when file level=DEBUG';
    ok  $logger->is_logging('INFO', $path),
        'is_logging(INFO, path) true when file level=DEBUG';
    ok !$logger->is_logging('TRACE', $path),
        'is_logging(TRACE, path) false when file level=DEBUG';
};

subtest 'is_logging returns 0 for unconfigured named target' => sub {
    my $nonexistent = '/tmp/nonexistent-genesis-log-test.log';

    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();

    my $result = $logger->is_logging('INFO', $nonexistent);
    is $result, 0, 'is_logging returns 0 for unconfigured named path';
};

# ---------------------------------------------------------------------------
# set_level()
# ---------------------------------------------------------------------------

subtest 'set_level returns $self for chaining' => sub {
    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();
    $logger->configure_log(level => 'INFO');

    my $ret;
    lives_ok { $ret = $logger->set_level('WARNING') }
        'set_level does not die on configured terminal';

    is $ret, $logger, 'set_level returns $self';
};

subtest 'set_level changes the terminal threshold' => sub {
    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();
    $logger->configure_log(level => 'INFO');

    $logger->set_level('WARNING');

    is $logger->{logs}{'<terminal>'}{level}, 'WARNING',
        'level updated to WARNING after set_level';
    is $logger->{logs}{'<terminal>'}{level_ord},
        Genesis::Log::level_ord('WARNING'),
        'level_ord updated to WARNING ordinal after set_level';
};

subtest 'set_level to WARNING: ERROR is logged, INFO is not' => sub {
    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();
    $logger->configure_log(level => 'INFO');
    $logger->set_level('WARNING');

    ok  $logger->is_logging('ERROR'),   'ERROR is logged at WARNING threshold';
    ok  $logger->is_logging('WARNING'), 'WARNING is logged at WARNING threshold';
    ok !$logger->is_logging('INFO'),    'INFO is not logged at WARNING threshold';
    ok !$logger->is_logging('DEBUG'),   'DEBUG is not logged at WARNING threshold';
};

subtest 'set_level dies with "invalid log" for unconfigured target' => sub {
    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();

    # Terminal is not configured — set_level must die
    throws_ok { $logger->set_level('WARNING') }
        qr/invalid log/,
        'set_level dies with "invalid log" on unconfigured terminal';
};

subtest 'set_level dies with "invalid log" for unconfigured named path' => sub {
    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();

    throws_ok { $logger->set_level('DEBUG', '/tmp/no-such-log.log') }
        qr/invalid log/,
        'set_level dies with "invalid log" for unknown file target';
};

# ---------------------------------------------------------------------------
# style()
# ---------------------------------------------------------------------------

subtest 'style() returns configured style string for terminal' => sub {
    no warnings 'once';
    $Genesis::Log::Logger = undef;
    local $ENV{GENESIS_LOG_STYLE} = undef;
    my $logger = Genesis::Log->new();
    $logger->configure_log();

    my $s;
    lives_ok { $s = $logger->style() } 'style() does not die on configured terminal';
    ok defined($s), 'style() returns a defined value';
    ok length($s) > 0, 'style() returns a non-empty string';
};

subtest 'style() returns explicitly set style' => sub {
    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();
    $logger->configure_log(style => 'fun');

    is $logger->style(), 'fun', 'style() returns explicitly configured style';
};

subtest 'style() dies with "invalid log" for unconfigured target' => sub {
    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();

    throws_ok { $logger->style() }
        qr/invalid log/,
        'style() dies with "invalid log" on unconfigured terminal';
};

subtest 'style() dies with "invalid log" for unknown named path' => sub {
    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();

    throws_ok { $logger->style('/tmp/no-such-log.log') }
        qr/invalid log/,
        'style(path) dies with "invalid log" for unconfigured path';
};

# ---------------------------------------------------------------------------
# expand_log_template()
# ---------------------------------------------------------------------------

subtest 'expand_log_template expands {pid}' => sub {
    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();

    my $result = $logger->expand_log_template('/logs/{pid}/app.log');
    is $result, "/logs/$$/app.log", '{pid} replaced with current process ID ($$)';
};

subtest 'expand_log_template expands {command} from GENESIS_COMMAND' => sub {
    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();

    local $ENV{GENESIS_COMMAND} = 'deploy';
    my $result = $logger->expand_log_template('/logs/{command}/app.log');
    is $result, '/logs/deploy/app.log', '{command} replaced with GENESIS_COMMAND value';
};

subtest 'expand_log_template expands {command} to "unknown" when GENESIS_COMMAND unset' => sub {
    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();

    local $ENV{GENESIS_COMMAND} = undef;
    my $result = $logger->expand_log_template('/logs/{command}/app.log');
    is $result, '/logs/unknown/app.log',
        '{command} replaced with "unknown" when GENESIS_COMMAND not set';
};

subtest 'expand_log_template expands {date} to YYYYMMDD format' => sub {
    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();

    my $result = $logger->expand_log_template('/logs/{date}/app.log');
    like $result, qr|/logs/\d{8}/app\.log|,
        '{date} expands to an 8-digit date string (YYYYMMDD)';
};

subtest 'expand_log_template expands {time} to HHMMSS format' => sub {
    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();

    my $result = $logger->expand_log_template('/logs/{time}/app.log');
    like $result, qr|/logs/\d{6}/app\.log|,
        '{time} expands to a 6-digit time string (HHMMSS)';
};

subtest 'expand_log_template expands {timestamp} to ISO-like format' => sub {
    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();

    my $result = $logger->expand_log_template('/logs/{timestamp}/app.log');
    # Expected pattern: YYYYMMDDTHHMMSSmmm.mmmZ
    like $result, qr|/logs/\d{8}T\d{6}\.\d{3}Z/app\.log|,
        '{timestamp} expands to compact ISO-like timestamp with milliseconds';
};

subtest 'expand_log_template removes {env}/ when GENESIS_ENVIRONMENT not set' => sub {
    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();

    local $ENV{GENESIS_ENVIRONMENT} = undef;
    my $result = $logger->expand_log_template('/logs/{env}/app.log');
    unlike $result, qr/\{env\}/, '{env} token is gone from result';
    unlike $result, qr|//|,       'no double slashes in result';
    is $result, '/logs/app.log',
        '{env}/ removed cleanly when GENESIS_ENVIRONMENT is not set';
};

subtest 'expand_log_template substitutes {env} with GENESIS_ENVIRONMENT when set' => sub {
    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();

    local $ENV{GENESIS_ENVIRONMENT} = 'prod-us-east-1';
    my $result = $logger->expand_log_template('/logs/{env}/app.log');
    is $result, '/logs/prod-us-east-1/app.log',
        '{env} replaced with GENESIS_ENVIRONMENT value';
};

subtest 'expand_log_template collapses double slashes' => sub {
    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();

    local $ENV{GENESIS_ENVIRONMENT} = undef;
    # Template with leading slash + {env}/ which would otherwise produce //
    my $result = $logger->expand_log_template('/base/{env}/sub/app.log');
    unlike $result, qr|//|, 'no double slashes after expansion';
};

# ---------------------------------------------------------------------------
# File output: configure a temp file target, log to it, verify content
# ---------------------------------------------------------------------------

subtest 'log message is written to configured file target' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/output.log";

    no warnings 'once';
    $Genesis::Log::Logger = undef;
    my $logger = Genesis::Log->new();
    $logger->configure_log($path, level => 'INFO', style => 'plain');

    quietly {
        $logger->info('routing test marker message');
    };

    ok -e $path, 'log file was created after info() call';

    open my $fh, '<', $path
        or fail "could not open log file for reading: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    ok length($content) > 0, 'log file has content';
    like $content, qr/routing test marker message/,
        'log file contains the message passed to info()';
};

# Reset singleton after all tests to avoid leaking state to other test files
{ no warnings 'once'; $Genesis::Log::Logger = undef; }

done_testing;
