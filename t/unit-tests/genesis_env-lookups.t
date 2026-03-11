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

$ENV{GENESIS_OUTPUT_COLUMNS}=80;
$ENV{NOCOLOR}=1;

# ============================================================================
# Shared fixture builder
# ============================================================================

sub build_env {
	my $top = make_top(name => 'thing', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path('test-env.yml'),
		"---\n" .
		"kit:\n" .
		"  name:    dev\n" .
		"  version: latest\n" .
		"  features: []\n" .
		"\n" .
		"genesis:\n" .
		"  env: test-env\n" .
		"\n" .
		"params:\n" .
		"  color: blue\n" .
		"  count: 42\n" .
		"  nested:\n" .
		"    deep:\n" .
		"      value: found-it\n" .
		"  empty_list: []\n"
	);
	return $top->load_env('test-env');
}

# ============================================================================
# lookup() - basic key retrieval
# ============================================================================

subtest 'lookup() - simple top-level param' => sub {
	plan tests => 1;
	my $env = build_env();
	is($env->lookup('params.color'), 'blue',
		'lookup returns value for simple dot-notation key');
};

subtest 'lookup() - numeric value' => sub {
	plan tests => 1;
	my $env = build_env();
	is($env->lookup('params.count'), 42,
		'lookup returns numeric value correctly');
};

subtest 'lookup() - deeply nested dot-notation' => sub {
	plan tests => 1;
	my $env = build_env();
	is($env->lookup('params.nested.deep.value'), 'found-it',
		'lookup follows deep dot-notation path');
};

subtest 'lookup() - kit section accessible' => sub {
	plan tests => 2;
	my $env = build_env();
	is($env->lookup('kit.name'), 'dev',
		'lookup can reach kit.name');
	is($env->lookup('kit.version'), 'latest',
		'lookup can reach kit.version');
};

subtest 'lookup() - missing key returns undef' => sub {
	plan tests => 1;
	my $env = build_env();
	is($env->lookup('params.no_such_key'), undef,
		'lookup returns undef for missing key');
};

subtest 'lookup() - missing key returns provided scalar default' => sub {
	plan tests => 1;
	my $env = build_env();
	is($env->lookup('params.no_such_key', 'fallback'), 'fallback',
		'lookup returns scalar default when key not found');
};

subtest 'lookup() - coderef default not called when key exists' => sub {
	plan tests => 2;
	my $env = build_env();
	my $called = 0;
	my $val = $env->lookup('params.color', sub { $called++; 'computed' });
	is($val, 'blue', 'coderef default not used when key exists');
	is($called, 0, 'coderef not invoked when key found');
};

subtest 'lookup() - coderef default invoked when key missing' => sub {
	plan tests => 2;
	my $env = build_env();
	my $called = 0;
	my $val = $env->lookup('params.missing', sub { $called++; 'computed' });
	is($val, 'computed', 'coderef default returns computed value');
	is($called, 1, 'coderef invoked exactly once');
};

subtest 'lookup() - empty string key returns whole structure' => sub {
	plan tests => 2;
	my $env = build_env();
	my $all = $env->lookup('');
	ok(ref($all) eq 'HASH', 'empty key returns a hash reference');
	ok(exists $all->{params}, 'returned structure contains params key');
};

subtest 'lookup() - arrayref of keys tries each in order' => sub {
	plan tests => 2;
	my $env = build_env();
	my $val = $env->lookup(['params.no_such', 'params.color']);
	is($val, 'blue', 'arrayref of keys falls through to second key');

	$val = $env->lookup(['params.color', 'params.count']);
	is($val, 'blue', 'arrayref returns first matching key');
};

subtest 'lookup() - arrayref all missing returns default' => sub {
	plan tests => 1;
	my $env = build_env();
	my $val = $env->lookup(['params.gone', 'params.missing'], 'safe_default');
	is($val, 'safe_default',
		'arrayref returns default when all keys missing');
};

subtest 'lookup() - list context returns (value, matched_key)' => sub {
	plan tests => 2;
	my $env = build_env();
	my ($val, $key) = $env->lookup('params.color');
	is($val, 'blue', 'list context: value is correct');
	is($key, 'params.color', 'list context: matched key is returned');
};

subtest 'lookup() - list context arrayref returns first matched key' => sub {
	plan tests => 2;
	my $env = build_env();
	my ($val, $key) = $env->lookup(['params.gone', 'params.color']);
	is($val, 'blue', 'list context arrayref: value from matching key');
	is($key, 'params.color', 'list context arrayref: matched key reported');
};

subtest 'lookup() - list context no match returns (default, undef)' => sub {
	plan tests => 2;
	my $env = build_env();
	my ($val, $key) = $env->lookup('params.missing', 'default_val');
	is($val, 'default_val', 'list context no match: default returned');
	is($key, undef, 'list context no match: key is undef');
};

# ============================================================================
# lookup_unevaled() - raw unevaluated environment data
# ============================================================================

subtest 'lookup_unevaled() - returns value for existing key' => sub {
	plan tests => 1;
	my $env = build_env();
	is($env->lookup_unevaled('params.color'), 'blue',
		'lookup_unevaled returns value for existing key');
};

subtest 'lookup_unevaled() - returns default when key missing' => sub {
	plan tests => 1;
	my $env = build_env();
	is($env->lookup_unevaled('params.nonexistent', 'raw_default'), 'raw_default',
		'lookup_unevaled returns default for missing key');
};

subtest 'lookup_unevaled() - returns undef when no key and no default' => sub {
	plan tests => 1;
	my $env = build_env();
	is($env->lookup_unevaled('params.nonexistent'), undef,
		'lookup_unevaled returns undef with no default');
};

subtest 'lookup_unevaled() - deeply nested key' => sub {
	plan tests => 1;
	my $env = build_env();
	is($env->lookup_unevaled('params.nested.deep.value'), 'found-it',
		'lookup_unevaled follows deep dot-notation path');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
