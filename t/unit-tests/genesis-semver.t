#!/usr/bin/env perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;

use Test::More;

use_ok 'Genesis';

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

	ok !new_enough('latest',     '1.0.0'), "non-semver versions are never good enough";
	ok  new_enough('1.0.0',      '1.0.0'), "1.0.0 is new enough to satisfy 1.0.0+";
	ok  new_enough('1.0',        '1.0.0'), "1.0 is new enough to satisfy 1.0.0+";
	ok  new_enough('1.1',        '1.0.0'), "1.1 is new enough to satisfy 1.0.0+";
	ok !new_enough('0.1',        '1.0.0'), "0.1 is not new enough to satisfy 1.0.0+";
	ok !new_enough('1.0.0-rc.1', '1.0.0'), '1.0.0-rc.1 is not new enough to satisfy 1.0.0+ (RCs come before point releases)';
	ok !new_enough('1.0.0-rc.0', '1.0.0'), '1.0.0-rc.0 is not new enough to satisfy 1.0.0+';
	ok  new_enough('1.0.0-rc.5', '1.0.0-rc.3'), '1.0.0-rc.5 is new enough to satisfy 1.0.0-rc.3+';
	ok !new_enough('1.0.0-rc.2', '1.0.0-rc.3'), '1.0.0-rc.2 is not new enough to satisfy 1.0.0-rc.3+';
	ok  new_enough('2.8.12',     '2.8.6'), '2.8.12 is new enough to satisfy 2.8.6+';
	ok !new_enough('2.8.12',     '2.11.1'), '2.8.12 is not new enough to satisfy 2.11.1+';
};

subtest 'by_semver sorting' => sub {
	my @versions = qw(2.0.0 1.0.0 1.2.3 1.2.2 1.0.0-rc.1 0.9.0);
	my @sorted = sort by_semver @versions;

	is $sorted[0], '0.9.0', 'smallest version first';
	is $sorted[1], '1.0.0-rc.1', 'RC before release';
	is $sorted[2], '1.0.0', 'major.minor.patch';
	is $sorted[3], '1.2.2', 'patch increments';
	is $sorted[4], '1.2.3', 'higher patch';
	is $sorted[5], '2.0.0', 'largest version last';
};

subtest 'semver comparison edge cases' => sub {
	ok by_semver('1.0.0', '1.0.0') == 0, 'equal versions compare equal';
	ok by_semver('2.0.0', '1.0.0') > 0, 'higher major version is greater';
	ok by_semver('1.0.0', '2.0.0') < 0, 'lower major version is less';
	ok by_semver('1.2.0', '1.1.0') > 0, 'higher minor version is greater';
	ok by_semver('1.0.2', '1.0.1') > 0, 'higher patch version is greater';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
