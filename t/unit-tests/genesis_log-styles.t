#!/usr/bin/env perl
use strict;
use warnings;
use lib 't';
use helper;

use Test::Deep;

use_ok 'Genesis::Log';

# ---------------------------------------------------------------------------
# All 11 named styles exist and return hashrefs
# ---------------------------------------------------------------------------
subtest 'all named styles return hashrefs' => sub {
	my @names = qw(
		output info debug warning notice
		error fatal trace qtrace dumpvar dumpstack
	);

	for my $name (@names) {
		my $style = log_styles($name);
		ok defined($style), "log_styles('$name') returns a defined value";
		is ref($style), 'HASH', "log_styles('$name') returns a hashref";
	}
};

# ---------------------------------------------------------------------------
# Every style has at minimum a 'colors' key
# ---------------------------------------------------------------------------
subtest 'every style has a colors key' => sub {
	for my $name (qw(
		output info debug warning notice
		error fatal trace qtrace dumpvar dumpstack
	)) {
		my $style = log_styles($name);
		ok exists($style->{colors}), "log_styles('$name') has a 'colors' key";
		ok defined($style->{colors}), "log_styles('$name') colors value is defined";
		ok length($style->{colors}) > 0, "log_styles('$name') colors value is non-empty";
	}
};

# ---------------------------------------------------------------------------
# Every style has an 'emoji' key
# ---------------------------------------------------------------------------
subtest 'every style has an emoji key' => sub {
	for my $name (qw(
		output info debug warning notice
		error fatal trace qtrace dumpvar dumpstack
	)) {
		my $style = log_styles($name);
		ok exists($style->{emoji}), "log_styles('$name') has an 'emoji' key";
		ok defined($style->{emoji}), "log_styles('$name') emoji value is defined";
	}
};

# ---------------------------------------------------------------------------
# Unknown style name returns undef
# ---------------------------------------------------------------------------
subtest 'unknown style name returns undef' => sub {
	my $result = log_styles('bogus');
	ok !defined($result), "log_styles('bogus') returns undef";

	ok !defined(log_styles('')),      "log_styles('') returns undef";
	ok !defined(log_styles('OUTPUT')), "log_styles('OUTPUT') (wrong case) returns undef";
};

# ---------------------------------------------------------------------------
# Specific style properties: output
# ---------------------------------------------------------------------------
subtest "style 'output' has correct properties" => sub {
	my $style = log_styles('output');
	is $style->{colors}, 'Ck',      "output: colors => 'Ck'";
	is $style->{pri},    6,          "output: pri => 6";
	is $style->{emoji},  'printer',  "output: emoji => 'printer'";
};

# ---------------------------------------------------------------------------
# Specific style properties: info
# ---------------------------------------------------------------------------
subtest "style 'info' has correct properties" => sub {
	my $style = log_styles('info');
	is $style->{colors}, 'cW',           "info: colors => 'cW'";
	is $style->{pri},    6,               "info: pri => 6";
	is $style->{emoji},  'information',   "info: emoji => 'information'";
};

# ---------------------------------------------------------------------------
# Specific style properties: debug (no pri key)
# ---------------------------------------------------------------------------
subtest "style 'debug' has correct properties and no pri key" => sub {
	my $style = log_styles('debug');
	is  $style->{colors}, 'mW',           "debug: colors => 'mW'";
	is  $style->{emoji},  'crystal-ball', "debug: emoji => 'crystal-ball'";
	ok !exists($style->{pri}),            "debug: no 'pri' key";
};

# ---------------------------------------------------------------------------
# Specific style properties: warning
# ---------------------------------------------------------------------------
subtest "style 'warning' has correct properties" => sub {
	my $style = log_styles('warning');
	is $style->{colors}, 'ky',       "warning: colors => 'ky'";
	is $style->{pri},    4,           "warning: pri => 4";
	is $style->{emoji},  'warning',   "warning: emoji => 'warning'";
};

# ---------------------------------------------------------------------------
# Specific style properties: notice
# ---------------------------------------------------------------------------
subtest "style 'notice' has correct properties" => sub {
	my $style = log_styles('notice');
	is $style->{colors}, 'bw',        "notice: colors => 'bw'";
	is $style->{pri},    4,            "notice: pri => 4";
	is $style->{emoji},  'megaphone',  "notice: emoji => 'megaphone'";
};

# ---------------------------------------------------------------------------
# Specific style properties: error
# ---------------------------------------------------------------------------
subtest "style 'error' has correct properties" => sub {
	my $style = log_styles('error');
	is $style->{colors}, 'RW',         "error: colors => 'RW'";
	is $style->{pri},    3,             "error: pri => 3";
	is $style->{emoji},  'collision',   "error: emoji => 'collision'";
};

# ---------------------------------------------------------------------------
# Specific style properties: fatal
# ---------------------------------------------------------------------------
subtest "style 'fatal' has correct properties" => sub {
	my $style = log_styles('fatal');
	is $style->{colors}, 'rY',        "fatal: colors => 'rY'";
	is $style->{pri},    0,            "fatal: pri => 0";
	is $style->{emoji},  'stop-sign',  "fatal: emoji => 'stop-sign'";
};

# ---------------------------------------------------------------------------
# Specific style properties: trace (has show_stack)
# ---------------------------------------------------------------------------
subtest "style 'trace' has correct properties including show_stack" => sub {
	my $style = log_styles('trace');
	is $style->{colors},     'GW',        "trace: colors => 'GW'";
	is $style->{emoji},      'detective', "trace: emoji => 'detective'";
	ok exists($style->{show_stack}),      "trace: has 'show_stack' key";
	is $style->{show_stack}, 'current',   "trace: show_stack => 'current'";
};

# ---------------------------------------------------------------------------
# Specific style properties: qtrace (no show_stack key)
# ---------------------------------------------------------------------------
subtest "style 'qtrace' has correct properties and no show_stack key" => sub {
	my $style = log_styles('qtrace');
	is  $style->{colors}, 'gW',        "qtrace: colors => 'gW'";
	is  $style->{emoji},  'detective', "qtrace: emoji => 'detective'";
	ok !exists($style->{show_stack}),  "qtrace: no 'show_stack' key";
};

# ---------------------------------------------------------------------------
# Specific style properties: dumpvar (has raw and show_scope)
# ---------------------------------------------------------------------------
subtest "style 'dumpvar' has correct properties" => sub {
	my $style = log_styles('dumpvar');
	is $style->{colors},     'BW',                "dumpvar: colors => 'BW'";
	is $style->{emoji},      'magnifying-glass',  "dumpvar: emoji => 'magnifying-glass'";
	ok exists($style->{show_scope}),              "dumpvar: has 'show_scope' key";
	is $style->{show_scope}, 'current',           "dumpvar: show_scope => 'current'";
	ok exists($style->{raw}),                     "dumpvar: has 'raw' key";
	is $style->{raw},        1,                   "dumpvar: raw => 1";
};

# ---------------------------------------------------------------------------
# Specific style properties: dumpstack (has raw)
# ---------------------------------------------------------------------------
subtest "style 'dumpstack' has correct properties" => sub {
	my $style = log_styles('dumpstack');
	is $style->{colors}, 'Yk',       "dumpstack: colors => 'Yk'";
	is $style->{emoji},  'pancakes', "dumpstack: emoji => 'pancakes'";
	ok exists($style->{raw}),        "dumpstack: has 'raw' key";
	is $style->{raw},    1,          "dumpstack: raw => 1";
};

# ---------------------------------------------------------------------------
# Cross-style distinctions: trace vs qtrace show_stack asymmetry
# ---------------------------------------------------------------------------
subtest 'trace has show_stack but qtrace does not' => sub {
	my $trace  = log_styles('trace');
	my $qtrace = log_styles('qtrace');

	ok  exists($trace->{show_stack}),   "trace has 'show_stack'";
	ok !exists($qtrace->{show_stack}),  "qtrace does not have 'show_stack'";
	is $trace->{show_stack}, 'current', "trace show_stack is 'current'";
};

# ---------------------------------------------------------------------------
# Cross-style distinctions: raw flag only on dumpvar and dumpstack
# ---------------------------------------------------------------------------
subtest 'raw key present only on dumpvar and dumpstack' => sub {
	my @with_raw    = qw(dumpvar dumpstack);
	my @without_raw = qw(output info debug warning notice error fatal trace qtrace);

	for my $name (@with_raw) {
		my $style = log_styles($name);
		ok exists($style->{raw}), "log_styles('$name') has 'raw' key";
		is $style->{raw}, 1,      "log_styles('$name') raw => 1";
	}

	for my $name (@without_raw) {
		my $style = log_styles($name);
		ok !exists($style->{raw}), "log_styles('$name') does not have 'raw' key";
	}
};

# ---------------------------------------------------------------------------
# Cross-style distinctions: pri key presence
# ---------------------------------------------------------------------------
subtest 'pri key present only on output, info, warning, notice, error, fatal' => sub {
	my %expected_pri = (
		output  => 6,
		info    => 6,
		warning => 4,
		notice  => 4,
		error   => 3,
		fatal   => 0,
	);
	my @without_pri = qw(debug trace qtrace dumpvar dumpstack);

	for my $name (sort keys %expected_pri) {
		my $style = log_styles($name);
		ok exists($style->{pri}), "log_styles('$name') has 'pri' key";
		is $style->{pri}, $expected_pri{$name},
			"log_styles('$name') pri => $expected_pri{$name}";
	}

	for my $name (@without_pri) {
		my $style = log_styles($name);
		ok !exists($style->{pri}), "log_styles('$name') does not have 'pri' key";
	}
};

# ---------------------------------------------------------------------------
# cmp_deeply: full hashref comparison for each style
# ---------------------------------------------------------------------------
subtest 'full hashref deep comparison for each style' => sub {
	cmp_deeply(
		log_styles('output'),
		{ colors => 'Ck', pri => 6, emoji => 'printer' },
		"output: exact hashref match"
	);
	cmp_deeply(
		log_styles('info'),
		{ colors => 'cW', pri => 6, emoji => 'information' },
		"info: exact hashref match"
	);
	cmp_deeply(
		log_styles('debug'),
		{ colors => 'mW', emoji => 'crystal-ball' },
		"debug: exact hashref match"
	);
	cmp_deeply(
		log_styles('warning'),
		{ colors => 'ky', pri => 4, emoji => 'warning' },
		"warning: exact hashref match"
	);
	cmp_deeply(
		log_styles('notice'),
		{ colors => 'bw', pri => 4, emoji => 'megaphone' },
		"notice: exact hashref match"
	);
	cmp_deeply(
		log_styles('error'),
		{ colors => 'RW', pri => 3, emoji => 'collision' },
		"error: exact hashref match"
	);
	cmp_deeply(
		log_styles('fatal'),
		{ colors => 'rY', pri => 0, emoji => 'stop-sign' },
		"fatal: exact hashref match"
	);
	cmp_deeply(
		log_styles('trace'),
		{ colors => 'GW', emoji => 'detective', show_stack => 'current' },
		"trace: exact hashref match"
	);
	cmp_deeply(
		log_styles('qtrace'),
		{ colors => 'gW', emoji => 'detective' },
		"qtrace: exact hashref match"
	);
	cmp_deeply(
		log_styles('dumpvar'),
		{ colors => 'BW', show_scope => 'current', emoji => 'magnifying-glass', raw => 1 },
		"dumpvar: exact hashref match"
	);
	cmp_deeply(
		log_styles('dumpstack'),
		{ colors => 'Yk', emoji => 'pancakes', raw => 1 },
		"dumpstack: exact hashref match"
	);
};

done_testing;
