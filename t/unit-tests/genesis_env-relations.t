#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Test::Deep;
use Test::Exception;

use Genesis;
$Genesis::VERSION = '999.999.999';
use_ok 'Genesis::Config';
$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");

use_ok 'Genesis::Top';
use_ok 'Genesis::Env';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# Helper: create a top with the simple dev kit and one or more env files.
# Returns (top, %envs) where %envs maps name => Genesis::Env object.
sub make_envs {
	my @names = @_;
	my $top = make_top(name => 'thing', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	my %envs;
	for my $n (@names) {
		put_file($top->path("$n.yml"), <<"YAML");
---
kit:
  name:    dev
  version: latest
  features: []
genesis:
  env: $n
YAML
		$envs{$n} = $top->load_env($n);
	}
	return ($top, %envs);
}

# ---------------------------------------------------------------------------
subtest 'relate_by_name - list context, default bases' => sub {
	plan tests => 2;

	my @files = Genesis::Env::relate_by_name(
		'us-west-1-preprod', 'us-west-1-prod'
	);

	is(scalar @files, 4,
		'relate_by_name returns 4 files for preprod vs prod');

	cmp_deeply(
		\@files,
		[
			'./us.yml',
			'./us-west.yml',
			'./us-west-1.yml',
			'./us-west-1-preprod.yml',
		],
		'relate_by_name list context: common files first, then unique'
	);
};

# ---------------------------------------------------------------------------
subtest 'relate_by_name - scalar context returns hashref' => sub {
	plan tests => 3;

	my $struct = Genesis::Env::relate_by_name(
		'us-west-1-preprod', 'us-west-1-prod'
	);

	is(ref $struct, 'HASH',
		'relate_by_name scalar context returns hashref');

	cmp_deeply(
		$struct->{common},
		[ './us.yml', './us-west.yml', './us-west-1.yml' ],
		'relate_by_name scalar context: common arrayref correct'
	);

	cmp_deeply(
		$struct->{unique},
		[ './us-west-1-preprod.yml' ],
		'relate_by_name scalar context: unique arrayref correct'
	);
};

# ---------------------------------------------------------------------------
subtest 'relate_by_name - custom common_base' => sub {
	plan tests => 1;

	my @files = Genesis::Env::relate_by_name(
		'us-west-1-preprod', 'us-west-1-prod', '.cache'
	);

	cmp_deeply(
		\@files,
		[
			'.cache/us.yml',
			'.cache/us-west.yml',
			'.cache/us-west-1.yml',
			'./us-west-1-preprod.yml',
		],
		'relate_by_name applies custom common_base to shared files'
	);
};

# ---------------------------------------------------------------------------
subtest 'relate_by_name - custom common_base and unique_base' => sub {
	plan tests => 2;

	my $struct = Genesis::Env::relate_by_name(
		'us-west-1-preprod', 'us-west-1-prod', '.cache', 'NEW'
	);

	cmp_deeply(
		$struct->{common},
		[ '.cache/us.yml', '.cache/us-west.yml', '.cache/us-west-1.yml' ],
		'custom common_base applied to common files in scalar context'
	);

	cmp_deeply(
		$struct->{unique},
		[ 'NEW/us-west-1-preprod.yml' ],
		'custom unique_base applied to unique files in scalar context'
	);
};

# ---------------------------------------------------------------------------
subtest 'relate_by_name - completely different environments' => sub {
	plan tests => 3;

	my $struct = Genesis::Env::relate_by_name('eu-central-1-staging', 'us-west-1-prod');

	is(scalar @{ $struct->{common} }, 0,
		'no common files when env names share no prefixes');

	cmp_deeply(
		$struct->{unique},
		[
			'./eu.yml',
			'./eu-central.yml',
			'./eu-central-1.yml',
			'./eu-central-1-staging.yml',
		],
		'all files are unique when env names share no prefixes'
	);

	my @flat = Genesis::Env::relate_by_name('eu-central-1-staging', 'us-west-1-prod');
	is(scalar @flat, 4,
		'flat list has all 4 files when no common prefix exists'
	);
};

# ---------------------------------------------------------------------------
subtest 'relate_by_name - single-segment names, one common token' => sub {
	plan tests => 2;

	my $struct = Genesis::Env::relate_by_name('us-east', 'us-west');

	cmp_deeply(
		$struct->{common},
		[ './us.yml' ],
		'single shared leading token produces one common file'
	);

	cmp_deeply(
		$struct->{unique},
		[ './us-east.yml' ],
		'diverging token produces one unique file'
	);
};

# ---------------------------------------------------------------------------
subtest 'relate_by_name - identical environment names' => sub {
	plan tests => 2;

	my $struct = Genesis::Env::relate_by_name('us-west-1-preprod', 'us-west-1-preprod');

	cmp_deeply(
		$struct->{common},
		[ './us.yml', './us-west.yml', './us-west-1.yml', './us-west-1-preprod.yml' ],
		'all files are common when comparing env to itself'
	);

	cmp_deeply(
		$struct->{unique},
		[],
		'no unique files when comparing env to itself'
	);
};

# ---------------------------------------------------------------------------
subtest 'relate - list context with Env object argument' => sub {
	plan tests => 2;

	my ($top, %envs) = make_envs('us-west-1-preprod', 'us-west-1-prod');
	my $preprod = $envs{'us-west-1-preprod'};
	my $prod    = $envs{'us-west-1-prod'};

	my @files = $preprod->relate($prod);

	is(scalar @files, 4,
		'relate() with Env object returns 4 files');

	cmp_deeply(
		\@files,
		[
			'./us.yml',
			'./us-west.yml',
			'./us-west-1.yml',
			'./us-west-1-preprod.yml',
		],
		'relate() with Env object: correct file list in list context'
	);
};

# ---------------------------------------------------------------------------
subtest 'relate - list context with name string argument' => sub {
	plan tests => 1;

	my ($top, %envs) = make_envs('us-west-1-preprod', 'us-west-1-prod');
	my $preprod = $envs{'us-west-1-preprod'};

	my @files = $preprod->relate('us-west-1-prod');

	cmp_deeply(
		\@files,
		[
			'./us.yml',
			'./us-west.yml',
			'./us-west-1.yml',
			'./us-west-1-preprod.yml',
		],
		'relate() with name string: same result as with Env object'
	);
};

# ---------------------------------------------------------------------------
subtest 'relate - scalar context with Env object argument' => sub {
	plan tests => 3;

	my ($top, %envs) = make_envs('us-west-1-preprod', 'us-west-1-prod');
	my $preprod = $envs{'us-west-1-preprod'};
	my $prod    = $envs{'us-west-1-prod'};

	my $struct = $preprod->relate($prod);

	is(ref $struct, 'HASH',
		'relate() scalar context returns hashref');

	cmp_deeply(
		$struct->{common},
		[ './us.yml', './us-west.yml', './us-west-1.yml' ],
		'relate() scalar context: common arrayref correct'
	);

	cmp_deeply(
		$struct->{unique},
		[ './us-west-1-preprod.yml' ],
		'relate() scalar context: unique arrayref correct'
	);
};

# ---------------------------------------------------------------------------
subtest 'relate - custom common_base with Env object' => sub {
	plan tests => 1;

	my ($top, %envs) = make_envs('us-west-1-preprod', 'us-west-1-prod');
	my $preprod = $envs{'us-west-1-preprod'};
	my $prod    = $envs{'us-west-1-prod'};

	my @files = $preprod->relate($prod, '.cache');

	cmp_deeply(
		\@files,
		[
			'.cache/us.yml',
			'.cache/us-west.yml',
			'.cache/us-west-1.yml',
			'./us-west-1-preprod.yml',
		],
		'relate() with custom common_base prefixes shared files correctly'
	);
};

# ---------------------------------------------------------------------------
subtest 'relate - custom common_base and unique_base with Env object' => sub {
	plan tests => 2;

	my ($top, %envs) = make_envs('us-west-1-preprod', 'us-west-1-prod');
	my $preprod = $envs{'us-west-1-preprod'};
	my $prod    = $envs{'us-west-1-prod'};

	my $struct = $preprod->relate($prod, '.cache', 'NEW');

	cmp_deeply(
		$struct->{common},
		[ '.cache/us.yml', '.cache/us-west.yml', '.cache/us-west-1.yml' ],
		'relate() custom bases: common files use common_base'
	);

	cmp_deeply(
		$struct->{unique},
		[ 'NEW/us-west-1-preprod.yml' ],
		'relate() custom bases: unique files use unique_base'
	);
};

done_testing;
