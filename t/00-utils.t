#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::Exception;
use Test::Output;

use_ok 'Genesis';
use Cwd ();

subtest 'bug reporting utilities' => sub {
	throws_ok { bug("an example bug"); } qr{
			an \s+ example \s+ bug.*
			a \s+ bug \s+ in \s+ genesis.*
			file \s+ an \s+ issue .* https://github\.com/starkandwayne/genesis/issues
		}six, "bug() reports all the necessary details";
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
		is ordify($num), "$cases{$num} ", "numeric $num should ordify as $cases{$num}";
	}
};

subtest 'fs utilities' => sub {
	my $tmp = Cwd::abs_path(workdir);

	lives_ok { mkfile_or_fail("$tmp/file", "stuff!") } "mkfile_or_fail should not fail";
	ok -f "$tmp/file", "mkfile_or_fail should make a file if it didn't fail";
	is slurp("$tmp/file"), "stuff!", "mkfile_or_fail should populate the file";

	lives_ok { copy_or_fail("$tmp/file", "$tmp/copy") } "copy_or_fail should not fail";
	ok -f "$tmp/copy", "copy_or_fail should make a file if it didn't fail";
	is slurp("$tmp/copy"), slurp("$tmp/file"), "copy_or_fail should copy the file";

	lives_ok { mkdir_or_fail("$tmp/dir") } "mkdir_or_fail should not fail";
	ok -d "$tmp/dir",  "mkdir_or_fail should make a dir if it didn't fail";

	dies_ok { mkfile_or_fail("$tmp/file/not/a/dir/file", "whatevs"); }
		"mkfile_or_fail should fail if it cannot succeed";

	dies_ok { copy_or_fail("$tmp/e/no/ent", "$tmp/copy2") }
		"copy_or_fail should fail if it cannot succeed";

	dies_ok { mkdir_or_fail("$tmp/file/not/a/dir"); }
		"mkdir_or_fail should fail if it cannot succeed";

	lives_ok { symlink_or_fail("$tmp/file", "$tmp/link"); } "symlink_or_fail shoud not fail";
	sleep 0.1; # symlink() seems to have a race condition?
	ok -l "$tmp/link", "symlink_or_fail should make a symbolic link if it didn't fail";

	dies_ok { symlink_or_fail("$tmp/e/no/ent", "$tmp/void") }
		"symlink_or_fail should fail if it cannot succeed";

	my $here = Cwd::getcwd;
	chdir $here; lives_ok { chdir_or_fail("$tmp/dir"); }  "chdir_or_fail(dir) should not fail";
	chdir $here; dies_ok  { chdir_or_fail("$tmp/file"); } "chdir_or_fail(file) should fail";
	chdir $here;

	pushd("$tmp/dir"); is Cwd::getcwd, "$tmp/dir", "pushd put us where we wanted to go";
	pushd("$tmp/dir"); is Cwd::getcwd, "$tmp/dir", "pushd put us where we wanted to go (again)";
	popd();            is Cwd::getcwd, "$tmp/dir", "popd put us back in the previous \$tmp/dir...";
	popd();            is Cwd::getcwd, "$here",    "popd put us back in our old cwd";
};

subtest 'semantic versioning' => sub {
	for my $bad (qw(
		foo
		forty-two
		1.2.3.4.5.6.7.8
	)) {
		ok !semver($bad), "'$bad' should not be considered a valid semantic version";
	}

	for my $good (qw(
		1
		1.2
		1.2.3
		1.22.33
		1.2.3.rc4
		1.2.3.rc.4
		1.2.3-rc4
		1.2.3-rc-4
		0.0.0
		0.0.1
		0.999999.1

		1.2.3-RC4
		1.2.3-RC.4

		v1.2.3
		V1.2.3
	)) {
		ok semver($good), "'$good' should be considered a valid semantic version";
	}

	ok  new_enough('1.0.0',      '1.0.0'), "1.0.0 is new enough to satisfy 1.0.0+";
	ok  new_enough('1.0',        '1.0.0'), "1.0 is new enough to satisfy 1.0.0+";
	ok  new_enough('1.1',        '1.0.0'), "1.1 is new enough to satisfy 1.0.0+";
	ok !new_enough('0.1',        '1.0.0'), "0.1 is not new enough to satisfy 1.0.0+";
	ok !new_enough('1.0.0-rc.1', '1.0.0'), '1.0.0-rc.1 is not new enough to satisfy 1.0.0+ (RCs come before point releases)';
	ok !new_enough('1.0.0-rc.0', '1.0.0'), '1.0.0-rc.0 is not new enough to satisfy 1.0.0+';
	ok  new_enough('1.0.0-rc.5', '1.0.0-rc.3'), '1.0.0-rc.5 is new enough to satisfy 1.0.0-rc.3+';
	ok !new_enough('1.0.0-rc.2', '1.0.0-rc.3'), '1.0.0-rc.2 is not new enough to satisfy 1.0.0-rc.3+';
};

done_testing;
