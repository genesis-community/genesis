#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Test::Differences;
use Time::Seconds;
use Time::Piece;
use POSIX;

use_ok 'Genesis';

subtest 'fuzzy time' => sub {
	sub make_timestring {
		my $delta = shift;
		my $t = Time::Piece->new() + Time::Seconds->new($delta);
		return $t->strftime("%Y-%m-%d %H:%M:%S %z");
	}
	for (
		[               -4, "a few moments ago"                     ],
		[               32, "in half a minute"                      ],
		[               45, "in less than a minute"                 ],
		[              -75, "about a minute ago"                    ],
		[ ONE_MINUTE *  18, "in about 18 minutes"                   ],
		[ ONE_MINUTE * -43, "about 43 minutes ago"                  ],
		[ ONE_MINUTE *  72, "in about an hour"                      ],
		[           -55000, "about 15 hours ago"                    ],
		[ ONE_HOUR *   -26, "about a day ago"                       ],
		[ ONE_DAY *     -1, "about a day ago"                       ],
		[ ONE_DAY *    4.7, "in about 5 days"                       ],
		[ ONE_DAY *   -3.2, "about 3 days ago"                      ],
		[ ONE_DAY *      9, "in about a week"                       ],
		[ ONE_DAY *     11, "in about a week and a half"            ],
		[ ONE_DAY *    -19, "about 2 and a half weeks ago"          ],
		[ ONE_DAY *     29, "in about 4 weeks"                      ],
		[ ONE_DAY *    -40, "more than a month ago"                 ],
		[ ONE_DAY *     88, "in almost 3 months"                    ],
		[ ONE_DAY *   -130, "just over 4 months ago"                ],
		[ ONE_MONTH * 15.3, "in just over 15 months"                ],
		[ ONE_MONTH *  -25, "about 2 years ago"                     ],
		[ ONE_YEAR * -17.6, "more than 17 and a half years ago"     ]
	) {
		eq_or_diff strfuzzytime(make_timestring($_->[0])), $_->[1], $_->[1];
	}

	my $ts = Time::Piece->new() + Time::Seconds->new(-2 * NON_LEAP_YEAR );
	my $infmt = "%A, %B %d, %Y (%z) \@ %H:%M:%S";
	my $in = $ts->strftime($infmt);
	my @lt = localtime($ts->epoch); # Convert to localtime
	my $out = POSIX::strftime("%I:%M%p on %b %d, %Y %Z", @lt);

	eq_or_diff
		strfuzzytime($in, "Was deployed %~ (%I:%M%p on %b %d, %Y %Z)", $infmt),
		"Was deployed about 2 years ago ($out)",
		"can change input and output format of strfuzzytime.";

};

subtest 'strfuzzytime with seconds' => sub {
	my $seconds = 3600; # 1 hour
	my $result = strfuzzytime(Time::Seconds->new($seconds));
	like $result, qr/about an hour/, 'Time::Seconds object handled correctly';

	$seconds = 86400; # 1 day
	$result = strfuzzytime(Time::Seconds->new($seconds));
	like $result, qr/about a day/, 'day duration formatted correctly';
};

subtest 'pretty_duration' => sub {
	$ENV{GENESIS_SHOW_DURATION} = 1;
	$ENV{NOCOLOR} = 1;
	matches_utf8 encode_utf8(pretty_duration(0)), ' (0 µs)', 'microsecond duration';
	is pretty_duration(1), ' (1000 ms)', 'millisecond duration';
	is pretty_duration(30), ' (30 s)', 'seconds duration';
	is pretty_duration(60), ' (1 m 0 s)', 'one minute';
	is pretty_duration(90), ' (1 m 30 s)', 'minute and seconds';
	is pretty_duration(3600), ' (1 h 0 m)', 'one hour';
	is pretty_duration(3661), ' (1 h 1 m)', 'hour and minute';
	is pretty_duration(86400), ' (24 h 0 m)', 'one day';
};

subtest 'time_exec' => sub {
	my $counter = 0;
	my $duration = time_exec(sub { $counter++; select(undef, undef, undef, 0.1); }, {});

	is $counter, 1, 'callback executed once';
	ok $duration >= 0.1, 'duration measured correctly (at least 0.1s)';
	ok $duration < 0.5, 'duration is reasonable (less than 0.5s)';

	# Test with 2 second sleep
	my $duration2 = time_exec(sub { sleep 2; }, {});
	ok $duration2 >= 2.0, 'duration for 2s sleep is at least 2.0s';
	ok $duration2 <= 2.5, 'duration for 2s sleep is no greater than 2.5s';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
