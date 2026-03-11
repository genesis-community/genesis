#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;

use_ok 'Service::Vault';
use_ok 'Service::Vault::Remote';
use Genesis;

### Vault startup {{{
my $vault_target = vault_ok();
is($vault_target, 'genesis-ci-unit-tests',
	'vault_ok() returns expected target name');
# }}}

### Initialize vault for Service::Vault->initialized() {{{
# connect_and_validate() requires initialized() == true, which checks for
# /secret/handshake. Write the handshake via safe CLI before constructing
# the Service::Vault object.
system("SAFE_TARGET=$vault_target safe set /secret/handshake knock=knock >/dev/null 2>&1");
is($? >> 8, 0, 'wrote handshake secret for vault initialization');
# }}}

### Construct vault object {{{
Service::Vault->clear_all();
my $vault = Service::Vault::Remote->target($vault_target);
isa_ok($vault, 'Service::Vault::Remote',
	'target() returns a Service::Vault::Remote object');
is($vault, Service::Vault->current,
	'vault is set as current vault after target()');
# }}}

### Write and read round-trip via safe CLI then get() {{{
subtest 'write via safe CLI, read via get()' => sub {
	plan tests => 2;

	my ($out, $rc) = $vault->query('safe', 'set',
		'secret/test/roundtrip', 'key=hello-world');
	is($rc, 0, 'safe set command succeeds');

	my $value = $vault->get('secret/test/roundtrip', 'key');
	is($value, 'hello-world',
		'get() with key reads back what safe set wrote');
};
# }}}

### has() {{{
subtest 'has() detects presence and absence of paths' => sub {
	plan tests => 2;

	ok($vault->has('secret/test/roundtrip'),
		'has() returns true for a written path');

	ok(!$vault->has('secret/test/nonexistent-path-xyz'),
		'has() returns false for a non-existent path');
};
# }}}

### get() with key {{{
subtest 'get() with key retrieves single value' => sub {
	plan tests => 1;

	# Data was already written in round-trip subtest above
	my $value = $vault->get('secret/test/roundtrip', 'key');
	is($value, 'hello-world',
		'get() with explicit key returns the correct value');
};
# }}}

### get() without key returns all keys as hash ref {{{
subtest 'get() without key returns all key/value pairs' => sub {
	plan tests => 3;

	# Write an additional key to the same path
	$vault->query('safe', 'set',
		'secret/test/roundtrip', 'second=another-value');

	my $data = $vault->get('secret/test/roundtrip');
	is(ref($data), 'HASH',
		'get() without key returns a hash reference');
	is($data->{key}, 'hello-world',
		'returned hash contains expected first key');
	is($data->{second}, 'another-value',
		'returned hash contains expected second key');
};
# }}}

### set() and get() full method round-trip {{{
subtest 'set() and get() full method round-trip' => sub {
	plan tests => 3;

	my $returned = $vault->set('secret/test/method-roundtrip',
		'mykey', 'myvalue');
	is($returned, 'myvalue',
		'set() returns the stored value');

	my $read_back = $vault->get('secret/test/method-roundtrip', 'mykey');
	is($read_back, 'myvalue',
		'get() reads back the value written by set()');

	# Verify via has() as well
	ok($vault->has('secret/test/method-roundtrip'),
		'has() confirms path exists after set()');
};
# }}}

### clear() non-recursive {{{
subtest 'clear() non-recursive removes a single path' => sub {
	plan tests => 3;

	$vault->set('secret/test/to-clear', 'val', 'should-disappear');
	ok($vault->has('secret/test/to-clear'),
		'path exists before clear()');

	$vault->clear('secret/test/to-clear');
	ok(!$vault->has('secret/test/to-clear'),
		'has() returns false after non-recursive clear()');

	# Sibling path should be unaffected
	ok($vault->has('secret/test/roundtrip'),
		'sibling path is unaffected by non-recursive clear()');
};
# }}}

### clear() recursive {{{
subtest 'clear() recursive removes path tree' => sub {
	plan tests => 4;

	$vault->set('secret/test/subtree/alpha', 'k', 'v1');
	$vault->set('secret/test/subtree/beta',  'k', 'v2');
	$vault->set('secret/test/subtree/gamma', 'k', 'v3');

	ok($vault->has('secret/test/subtree/alpha'), 'alpha exists before clear');
	ok($vault->has('secret/test/subtree/beta'),  'beta exists before clear');

	$vault->clear('secret/test/subtree', 1);

	ok(!$vault->has('secret/test/subtree/alpha'),
		'alpha is gone after recursive clear()');
	ok(!$vault->has('secret/test/subtree/beta'),
		'beta is gone after recursive clear()');
};
# }}}

### paths() enumeration {{{
subtest 'paths() returns all written paths' => sub {
	plan tests => 2;

	# Write several distinct paths under a fresh prefix
	$vault->set('secret/test/paths-test/one',   'x', '1');
	$vault->set('secret/test/paths-test/two',   'x', '2');
	$vault->set('secret/test/paths-test/three', 'x', '3');

	my @paths = $vault->paths('secret/test/paths-test');
	my %path_set = map { $_ => 1 } @paths;

	ok($path_set{'secret/test/paths-test/one'},
		'paths() includes first written path');
	ok($path_set{'secret/test/paths-test/two'},
		'paths() includes second written path');
};
# }}}

### paths() with prefix filtering {{{
subtest 'paths() with prefix returns only matching paths' => sub {
	plan tests => 2;

	# Write under two separate prefixes
	$vault->set('secret/test/prefix-a/item', 'k', 'va');
	$vault->set('secret/test/prefix-b/item', 'k', 'vb');

	my @a_paths = $vault->paths('secret/test/prefix-a');
	my @b_paths = $vault->paths('secret/test/prefix-b');

	ok((grep { $_ eq 'secret/test/prefix-a/item' } @a_paths),
		'paths() with prefix-a returns only prefix-a paths');
	ok(!(grep { $_ eq 'secret/test/prefix-b/item' } @a_paths),
		'paths() with prefix-a does not include prefix-b paths');
};
# }}}

### keys() enumeration in path:key format {{{
subtest 'keys() returns path:key pairs' => sub {
	plan tests => 2;

	$vault->set('secret/test/keys-test', 'alpha', 'aval');
	$vault->set('secret/test/keys-test', 'beta',  'bval');

	my @key_pairs = $vault->keys('secret/test/keys-test');
	my %kp_set = map { $_ => 1 } @key_pairs;

	ok($kp_set{'secret/test/keys-test:alpha'},
		'keys() includes the alpha key in path:key format');
	ok($kp_set{'secret/test/keys-test:beta'},
		'keys() includes the beta key in path:key format');
};
# }}}

### status() returns 'ok' for a running, authenticated vault {{{
subtest 'status() returns ok for a healthy vault' => sub {
	plan tests => 1;

	my $status = $vault->status();
	is($status, 'ok',
		'status() returns "ok" for a running, authenticated vault');
};
# }}}

END { teardown_vault() }
done_testing;
