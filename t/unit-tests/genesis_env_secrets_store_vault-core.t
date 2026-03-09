#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;

# Test Genesis::Env::Secrets::Store::Vault
# Regression tests for code defects found during FWT-729 POD review

use_ok 'Genesis::Env::Secrets::Store::Vault';

# Minimal mock environment — provides name, type, lookup
{
	package MockEnv;
	sub new {
		bless {
			name         => 'my-org-my-env',
			type         => 'bosh',
			lookup_value => undef,
			@_[1..$#_],
		}, $_[0];
	}
	sub name   { $_[0]{name} }
	sub type   { $_[0]{type} }
	sub lookup { $_[0]{lookup_value} }
}

# Helper: build a store with mock env and service
sub make_store {
	my (%overrides) = @_;
	my $env     = delete $overrides{env}     || MockEnv->new();
	my $service = delete $overrides{service} || Mock->new(
		get   => sub { 'mock-value' },
		has   => sub { 1 },
		paths => sub { () },
		keys  => sub { () },
		query => sub { ('{}', 0, '') },
		set   => sub { 1 },
	);
	return Genesis::Env::Secrets::Store::Vault->new(
		$env,
		service => $service,
		%overrides,
	);
}

subtest 'Defect 1: check() uses read(), not get()' => sub {
	# check() should call $self->read($secret) to populate the secret,
	# then return $secret->check_value — NOT $self->get($secret)
	my $read_called = 0;

	my $secret = Mock->new(
		has_value              => 0,
		value                  => undef,
		path                   => 'certs/server',
		default_key            => 'certificate',
		full_path              => 'certs/server:certificate',
		check_value            => 'ok',
		set_value              => sub { },
		promote_value_to_stored => sub { },
		can                    => sub { 0 },
	);

	my $service = Mock->new(
		get   => sub { 'mock-value' },
		has   => sub { 1 },
		paths => sub { () },
		keys  => sub { () },
		query => sub { ('{}', 0, '') },
		set   => sub { 1 },
	);

	my $store = make_store(service => $service);

	# Monkey-patch read to track calls
	no warnings 'redefine';
	my $orig_read = \&Genesis::Env::Secrets::Store::Vault::read;
	local *Genesis::Env::Secrets::Store::Vault::read = sub {
		$read_called = 1;
		return $orig_read->(@_);
	};
	use warnings 'redefine';

	my @result = $store->check($secret);
	ok($read_called, "check() calls read() to populate the secret");
	is($result[0], 'ok', "check() returns result of secret->check_value");
};

subtest 'Defect 1b: validate() uses read(), not get()' => sub {
	# validate() should call $self->read($secret) to populate the secret,
	# then return $secret->validate_value — NOT $secret->validate()
	my $read_called = 0;

	my $secret = Mock->new(
		has_value              => 0,
		value                  => 'some-cert-value',
		path                   => 'certs/server',
		default_key            => 'certificate',
		full_path              => 'certs/server:certificate',
		validate_value         => 'ok',
		# The buggy code calls $secret->validate() instead of
		# $secret->validate_value — provide it so the test doesn't crash,
		# but return a sentinel value to detect the wrong call path
		validate               => 'WRONG_METHOD_CALLED',
		set_value              => sub { },
		promote_value_to_stored => sub { },
		can                    => sub { 0 },
	);

	my $service = Mock->new(
		get   => sub { 'mock-value' },
		has   => sub { 1 },
		paths => sub { () },
		keys  => sub { () },
		query => sub { ('{}', 0, '') },
		set   => sub { 1 },
	);

	my $store = make_store(service => $service);

	# Monkey-patch read to track calls
	no warnings 'redefine';
	my $orig_read = \&Genesis::Env::Secrets::Store::Vault::read;
	local *Genesis::Env::Secrets::Store::Vault::read = sub {
		$read_called = 1;
		return $orig_read->(@_);
	};
	use warnings 'redefine';

	my @result = $store->validate($secret);
	ok($read_called, "validate() calls read() to populate the secret");
	isnt($result[0], 'WRONG_METHOD_CALLED',
		"validate() calls validate_value, not validate()");
	is($result[0], 'ok', "validate() returns result of secret->validate_value");
};

subtest 'Defect 2: keys() cache regex matches paths correctly' => sub {
	# When cache is populated, keys() should match paths under base()
	# base() returns '/secret/my/org/my/env/bosh/' (with trailing slash)
	# Bug: the old regex /^\Q$base\E\// demands a double-slash '//' that
	# never appears in paths. The fix strips trailing slash from base and
	# uses (\/|$) alternation.

	my $store = make_store();

	# Verify base() has trailing slash (this is what causes the bug)
	like($store->base, qr/\/$/, "base() ends with trailing slash");

	# Pre-populate cache — keys() with no args calls paths() which returns
	# all CORE::keys of __data, then keys() checks each against the base regex
	$store->{__data} = {
		$store->base . 'certs/server' => {
			certificate => 'cert-data',
			key         => 'key-data',
		},
		$store->base . 'certs/ca' => {
			certificate => 'ca-cert-data',
		},
	};

	# Call keys() with no arguments — paths() returns all cache keys,
	# then keys() must match them against base to look up their values
	my @keys = $store->keys();
	ok(scalar(@keys) > 0, "keys() returns keys from cache (not empty)");
	is(scalar(@keys), 3, "keys() returns all 3 keys across 2 paths");

	# Verify we got the right keys
	my %key_set = map { $_ => 1 } @keys;
	ok($key_set{certificate}, "keys() includes 'certificate'");
	ok($key_set{key}, "keys() includes 'key'");
};

subtest 'Defect 3: stubs accept $self correctly' => sub {
	# regenerate, remove, remove_all should accept $self
	# and die with the expected error message
	my $store = make_store();

	throws_ok { $store->regenerate } qr/Regenerate not implemented/,
		"regenerate() dies with expected message when called as method";

	throws_ok { $store->remove } qr/Remove not implemented/,
		"remove() dies with expected message when called as method";

	throws_ok { $store->remove_all } qr/Remove_all not implemented/,
		"remove_all() dies with expected message when called as method";
};

subtest 'Defect 4: store_data() handles undef export safely' => sub {
	my $read_json_calls = 0;

	my $store = make_store();

	# Monkey-patch read_json_from in the Vault package namespace to simulate
	# vault export decoding to undef (the function is imported, so we must
	# override it in the consuming package's symbol table)
	no warnings 'redefine';
	local *Genesis::Env::Secrets::Store::Vault::read_json_from = sub {
		$read_json_calls++;
		return undef;
	};
	use warnings 'redefine';

	# (1) undef JSON → returns {} without caching
	my $data = $store->store_data();
	is_deeply($data, {}, "store_data() returns {} when export decodes to undef");

	# (2) cache must remain unset so paths/keys delegate to service
	ok(!exists $store->{__data}, "cache not populated after undef export");

	# (3) subsequent call retries (read_json_from called again)
	$store->store_data();
	is($read_json_calls, 2, "store_data() retries export after undef result");
};

subtest 'Defect 5: new() validates options without CORE::keys' => sub {
	# new() should detect unknown options — this exercises the keys() call
	my $env = MockEnv->new();
	throws_ok {
		Genesis::Env::Secrets::Store::Vault->new(
			$env,
			service      => Mock->new(),
			bogus_option => 'bad',
		);
	} qr/Unknown.*bogus_option/,
		"new() detects unknown options";
};

subtest 'check() skips read when secret already has value' => sub {
	my $read_called = 0;

	my $secret = Mock->new(
		has_value   => 1,
		check_value => 'ok',
	);

	my $store = make_store();

	no warnings 'redefine';
	my $orig_read = \&Genesis::Env::Secrets::Store::Vault::read;
	local *Genesis::Env::Secrets::Store::Vault::read = sub {
		$read_called = 1;
		return $orig_read->(@_);
	};
	use warnings 'redefine';

	# The fixed code should return check_value even when skipping read.
	# The buggy code returns undef ($ok is never set when has_value is true).
	my @result = $store->check($secret);
	ok(!$read_called, "check() skips read() when secret has_value");
	is($result[0], 'ok', "check() returns check_value result even when skipping read");
};

subtest 'validate() skips read when secret already has value' => sub {
	my $read_called = 0;

	my $secret = Mock->new(
		has_value      => 1,
		validate_value => 'ok',
		# Provide validate to prevent crash with buggy code
		validate       => 'WRONG_METHOD_CALLED',
	);

	my $store = make_store();

	no warnings 'redefine';
	my $orig_read = \&Genesis::Env::Secrets::Store::Vault::read;
	local *Genesis::Env::Secrets::Store::Vault::read = sub {
		$read_called = 1;
		return $orig_read->(@_);
	};
	use warnings 'redefine';

	my @result = $store->validate($secret);
	ok(!$read_called, "validate() skips read() when secret has_value");
	isnt($result[0], 'WRONG_METHOD_CALLED',
		"validate() calls validate_value, not validate()");
	is($result[0], 'ok', "validate() returns validate_value result");
};

done_testing;
