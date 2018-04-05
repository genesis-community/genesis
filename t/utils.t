#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;

use_ok 'Genesis::Utils';

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

done_testing;
