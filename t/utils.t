#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::Output;

use_ok 'Genesis::Utils';
use Cwd ();

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
	{
		local *STDERR; open STDERR, ">", "/dev/null";
		stdout_is(sub {
			explain("this is an explanation");
			  debug("this is debugging");
			  trace("this is trace (debugging's debugging)");
			  error("this is an error");
		}, "this is an explanation\n", "only explain()s go to standard output");
	}

	{
		local $ENV{QUIET} = 'yes';
		stdout_is(sub {
			explain("this is an explanation");
		}, "", "QUIET can shut up explain()");
	}

	{
		stderr_is(sub {
			explain("this is an explanation");
			  debug("this is debugging");
			  trace("this is trace (debugging's debugging)");
			  error("this is an error");
			}, "this is an error\n", "by default, only errors() are printed to standard error");
	}

	{
		local $ENV{GENESIS_DEBUG} = 'y';
		stderr_is(sub {
			explain("this is an explanation");
			  debug("this is debugging");
			  trace("this is trace (debugging's debugging)");
			  error("this is an error");
			}, "DEBUG> this is debugging\n".
			   "this is an error\n", "with GENESIS_DEBUG, debugging also goes to standard error");
	}

	{
		local $ENV{GENESIS_TRACE} = 'y';
		stderr_is(sub {
			explain("this is an explanation");
			  debug("this is debugging");
			  trace("this is trace (debugging's debugging)");
			  error("this is an error");
			}, "DEBUG> this is debugging\n".
			   "TRACE> this is trace (debugging's debugging)\n".
			   "this is an error\n", "with GENESIS_TRACE, you get trace to standard error");
	}
};

subtest 'bailing' => sub {
	throws_ok {
		stderr_is(sub { bail("borked!"); }, qr/borked/, "bail() prints its message");
	} qr/borked/;
};

subtest 'uri parsing' => sub {
	for my $ok (qw(
		http://genesisproject.io
		https://genesisproject.io

		http://genesisproject.io:80
		https://genesisproject.io:443

		http://genesisproject.io/
		https://genesisproject.io/

		http://genesisproject.io/with/a/path
		https://genesisproject.io/with/a/path

		http://genesisproject.io:80/
		https://genesisproject.io:443////

		http://genesisproject.io:80/with/a/path
		https://genesisproject.io:443/with/a/path
		http://genesisproject.io:80/with/a/path/

		http://genesisproject.io/with/a/path?and=a&query=string
		https://genesisproject.io:443/with/a/path?and=a&query=string

		http://user:pass@genesisproject.io
	)) {
		ok is_valid_uri($ok), "'$ok' should be a valid URL";
	}
};

subtest 'ordify' => sub {
	my %cases = (
		'0' => '0th',
		'1' => '1st',
		'2' => '2nd',
		'3' => '3rd',
		'4' => '4th',
		'5' => '5th',
		'6' => '6th',
		'7' => '7th',
		'8' => '8th',
		'9' => '9th',

		'10' => '10th',
		'11' => '11th',
		'12' => '12th',
		'13' => '13th',

		'20' => '20th',
		'21' => '21st',
		'22' => '22nd',
		'23' => '23rd',

		'100' => '100th',
		'101' => '101st',
		'102' => '102nd',
		'103' => '103rd',

		'110' => '110th',
		'111' => '111th',
		'112' => '112th',
		'113' => '113th',

		'120' => '120th',
		'121' => '121st',
		'122' => '122nd',
		'123' => '123rd',
	);

	for my $num (keys %cases) {
		# there's a trailing space for some reason.
		is ordify($num), "$cases{$num} ", "$num should ordify as $cases{$num}";
	}
};

subtest 'fs utilities' => sub {
	my $tmp = workdir;

	lives_ok { mkfile_or_fail("$tmp/file", "stuff!") };
	lives_ok { mkdir_or_fail("$tmp/dir") };

	ok -f "$tmp/file", "mkfile_or_fail should make a file if it didn't fail";
	ok -d "$tmp/dir",  "mkdir_or_fail should make a dir if it didn't fail";

	dies_ok { mkfile_or_fail("$tmp/file/not/a/dir/file", "whatevs") };
	dies_ok { mkdir_or_fail("$tmp/file/not/a/dir") };

	lives_ok { symlink_or_fail("$tmp/file", "$tmp/link"); }
	sleep 0.1; # symlink() seems to have a race condition?
	ok -l "$tmp/link", "symlink_or_fail should make a symbolic link if it didn't fail";

	dies_ok { symlink_or_fail("$tmp/e/no/ent", "$tmp/void") };

	my $here = Cwd::getcwd;
	chdir $here; lives_ok { chdir_or_fail("$tmp/dir"); }
	chdir $here; dies_ok  { chdir_or_fail("$tmp/file"); }
	chdir $here;
};

done_testing;
