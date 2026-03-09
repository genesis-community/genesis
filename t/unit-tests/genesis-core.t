#!/usr/bin/env perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper; # IF this dies, its because genesis ping is failing
use Test::Exception;
use Test::Exit;
use Test::Differences;
use Test::Output;

use_ok 'Genesis';
use_ok 'Genesis::State';
use_ok 'Genesis::Log';

use Genesis::Log; # use_ok fails to import $Logger;

subtest 'bug reporting utilities' => sub {
	local $Genesis::VERSION = '3.0.0';
	quietly {
		throws_ok { bug("an example bug"); } qr{
		an \s+ example \s+ bug.*
		a \s+ bug \s+ in \s+ Genesis.*
		}six, "bug() reports all the necessary details";
	};

	local $ENV{GENESIS_IGNORE_EVAL}=1;
	my ($stdout, $stderr) = output_from {
		exits_nonzero {
			bug("an example bug");
		}, "Bug exits with a non-zero status"
	};

	matches($stdout, "", "bug() does not print to stdout");
	matches($stderr, qr{
		an \s+ example \s+ bug.*
		a \s+ bug \s+ in \s+ Genesis.*
		}six, "bug() reports all the necessary details"
	);
};

subtest 'terminal control' => sub {
	use_ok 'Genesis::Term';
	local $ENV{GENESIS_OUTPUT_COLUMNS}=120;
	is Genesis::Term::terminal_width, 120, "can set arbitrary terminal width";
};

subtest 'bailing' => sub {
	local $Genesis::VERSION = '2.8.11';
	local $ENV{NOCOLOR}=1;
	local $ENV{GENESIS_LOG_STYLE}='plain';
	throws_ok {
		stderr_is(sub { bail("borked!"); }, qr/borked/, "bail() prints its message");
	} qr/borked/;

	local $ENV{GENESIS_IGNORE_EVAL}=1;
	my ($stdout, $stderr) = output_from {
		exits_nonzero {
			bail("borked");
		}, "Bail exits with a non-zero status"
	};

	matches($stdout, "", "bail() does not print to stdout");
	matches($stderr, qr{\[FATAL\] borked},  "bail() prints its message");
};

subtest 'environment variable utilities' => sub {
	delete $ENV{DO_THING};
	ok !envset("DO_THING"), "when unset, DO_THING should not be marked as 'set'";

	for my $yes (qw(yes y YES YeS 1 true TRUE tRuE)) {
		local $ENV{DO_THING} = $yes;
		ok envset("DO_THING"), "DO_THING=$yes should be marked as 'set'";
	}
	for my $no (qw(no nope no-way nuh-uh NOPE noada whatever maybe)) {
		local $ENV{DO_THING} = $no;
		ok !envset("DO_THING"), "DO_THING=$no should not be marked as 'set'";
	}

	delete $ENV{VARIABLE};
	is envdefault(VARIABLE => "unset"), "unset",
	   "envdefault() should return default if variable isn't set";

	for my $x (0, "") {
		local $ENV{VARIABLE} = $x;
		isnt envdefault(VARIABLE => "unset"), "unset",
		     "envdefault() doesn't return default if variable is set but not 'truthy'";
	}

	{
		local $ENV{VARIABLE} = "value";
		is envdefault(VARIABLE => "unset"), "value",
		   "envdefault() returns set value instead of default";

		local $ENV{VARIABLE} = undef;
		is envdefault(VARIABLE => "unset"), "unset",
		   "envdefault() returns default if env var is undef";
	}
};

subtest 'output utilities' => sub {
	local $ENV{NOCOLOR}=1;
	local $ENV{GENESIS_NO_UTF8}=1;
	local $ENV{GENESIS_LOG_STYLE}='plain';
	{
		my ($out, $err) = output_from {
			 output("this is from 'output'");
			  fatal({show_stack => 'none'}, "this is from 'fatal'");
			  error("this is from 'error'");
			warning("this is from 'warning'");
			   info("this is from 'info'");
			  debug("this is from 'debug'");
			  trace("this is from 'trace'");
		};
		matches $out, "this is from 'output'\n", "only output()s go to standard output";
		matches $err, "[FATAL] this is from 'fatal'\n[ERROR] this is from 'error'\n[WARNING] this is from 'warning'\nthis is from 'info'\n", "by default, only fatal to info are printed to standard error";
	}

	{
		local $ENV{QUIET} = 'yes';
		$Genesis::Log::Logger = undef;
		my $err = stderr_from {
			info("this is info");
		};
		matches "$err", "", "QUIET can shut up info()";
	}

	{
		local $ENV{GENESIS_DEBUG} = 'y';
		$Genesis::Log::Logger = undef;
		my ($out, $err) = output_from {
				fatal({show_stack => 'none'}, "this is from 'fatal'");
				error("this is from 'error'");
			warning("this is from 'warning'");
				 info("this is from 'info'");
				debug("this is from 'debug'");
				trace("this is from 'trace'");
		};
		matches $out, "", "nothing to standard output without output()s";
		matches $err, "[FATAL] this is from 'fatal'\n[ERROR] this is from 'error'\n[WARNING] this is from 'warning'\nthis is from 'info'\n[DEBUG] this is from 'debug'\n", "with GENESIS_DEBUG, debugging also goes to standard error";
	}

	{
		local $ENV{GENESIS_TRACE} = 'y';
		local $ENV{GENESIS_DEBUG} = 'y';
		local $ENV{NOCOLOR} = 1;
		$Genesis::Log::Logger = undef;
		my ($out, $err) = output_from {
			 output("this is from first 'output'");
				fatal({show_stack => 'none'}, "this is from 'fatal'");
				error("this is from 'error'");
			warning("this is from 'warning'");
				 info("this is from 'info'");
				debug("this is from 'debug'");
			 output("this is from last 'output'");
				trace("this is from 'trace'");
		};
		matches $out, "this is from first 'output'\nthis is from last 'output'\n", "output()s go to standard output in the right order";
		$err =~ s#t/unit-tests/genesis-core.t:L[0-9]* #t/unit-tests/genesis-core.t:Lxxx #;
		matches $err, "[FATAL] this is from 'fatal'\n[ERROR] this is from 'error'\n[WARNING] this is from 'warning'\nthis is from 'info'\n[DEBUG] this is from 'debug'\n[TRACE] this is from 'trace'\n        ^- t/unit-tests/genesis-core.t:Lxxx (in main::__ANON__)\n\n", "with GENESIS_TRACE, you get trace to standard error";
	}
	$Genesis::Log::Logger = undef;
};

subtest 'logger singleton and special logging functions' => sub {
	# Test logger() returns a Genesis::Log instance
	$Genesis::Log::Logger = undef;
	my $logger1 = logger();
	isa_ok $logger1, 'Genesis::Log', 'logger() returns Genesis::Log instance';

	# Test logger() returns the same instance (singleton pattern)
	my $logger2 = logger();
	is $logger1, $logger2, 'logger() returns same instance on repeated calls';

	# Test success() function
	local $ENV{NOCOLOR}=1;
	local $ENV{GENESIS_NO_UTF8}=1;
	local $ENV{GENESIS_LOG_STYLE}='plain';
	$Genesis::Log::Logger = undef;
	{
		my ($out, $err) = output_from {
			success("deployment completed");
		};
		matches $out, "", "success() doesn't output to stdout";
		like $err, qr/\[DONE\] deployment completed/, "success() outputs to stderr with DONE label";
	}

	# Test dryrun() function
	$Genesis::Log::Logger = undef;
	{
		my ($out, $err) = output_from {
			dryrun("would deploy manifest");
		};
		matches $out, "", "dryrun() doesn't output to stdout";
		like $err, qr/\[DRYRUN\] would deploy manifest/, "dryrun() outputs to stderr with DRYRUN label";
	}

	# Test notice() function
	$Genesis::Log::Logger = undef;
	{
		my ($out, $err) = output_from {
			notice("this is a notice");
		};
		matches $out, "", "notice() doesn't output to stdout";
		like $err, qr/this is a notice/, "notice() outputs to stderr";
	}

	$Genesis::Log::Logger = undef;
};

subtest 'global config schema and validation' => sub {
	use_ok 'Genesis::Config';

	# Test schema structure
	my $schema = global_config_schema();
	is ref($schema), 'HASH', 'schema is a hashref';
	ok scalar(keys %$schema) > 0, 'schema has entries';

	# Check for key config options
	my @required_keys = qw(
		default_bosh_target
		embedded_genesis
		output_style
		show_duration
		deployment_roots
	);

	for my $key (@required_keys) {
		ok exists($schema->{$key}), "schema has '$key' entry" or diag "Missing key: $key";
	}

	# Test empty config validates (uses defaults)
	my $empty_config = Genesis::Config->new(undef, 0, {});
	lives_ok { validate_global_config($empty_config) } 'empty config validates with defaults';

	# Test typical config validates
	my $typical_config = Genesis::Config->new(undef, 0, {
		embedded_genesis => 'ignore',
		output_style => 'fun',
		show_duration => 1,
		spec_cache_dir => '~/.genesis/spec_cache/'
	});
	lives_ok { validate_global_config($typical_config) } 'typical config validates';

	# Test enum values
	my $enum_config = Genesis::Config->new(undef, 0, {
		output_style => 'plain'
	});
	lives_ok { validate_global_config($enum_config) } 'valid enum value validates';

	# Test boolean values
	my $bool_config = Genesis::Config->new(undef, 0, {
		show_duration => 1,
		legacy_repo_suffix => 0
	});
	lives_ok { validate_global_config($bool_config) } 'boolean values validate';

	# Test deployment_roots array
	my $roots_config = Genesis::Config->new(undef, 0, {
		deployment_roots => [
			{ 'lab-ops' => '/path/to/lab-ops' }
		]
	});
	lives_ok { validate_global_config($roots_config) } 'deployment_roots validates';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
