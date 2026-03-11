#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::Output;

use_ok 'Service::Vault';
use_ok 'Service::Vault::Remote';
use Genesis;

# -------------------------------------------------------------------------
# Helper: build a raw Service::Vault::Remote object without external tools
# -------------------------------------------------------------------------
sub make_remote {
	my (%args) = @_;
	my $url       = $args{url}       // 'https://vault.example.com:8200';
	my $name      = $args{name}      // 'test-vault';
	my $verify    = $args{verify}    // 1;
	my $namespace = $args{namespace} // '';
	my $strongbox = $args{strongbox};   # undef means use default (true)
	my $mount     = $args{mount}     // '/secret/';
	return Service::Vault::Remote->new($url, $name, $verify, $namespace, $strongbox, $mount);
}

# -------------------------------------------------------------------------
# Module loading
# -------------------------------------------------------------------------
subtest 'module loading' => sub {
	plan tests => 3;

	ok(Service::Vault::Remote->isa('Service::Vault'),
		'Service::Vault::Remote ISA Service::Vault');

	my $v = make_remote();
	is(ref($v), 'Service::Vault::Remote',
		'make_remote() produces a Service::Vault::Remote object');

	ok($v->can('connect_and_validate'),
		'Service::Vault::Remote provides connect_and_validate()');
};

# -------------------------------------------------------------------------
# connect_and_validate() - already current
# -------------------------------------------------------------------------
subtest 'connect_and_validate() - already current' => sub {
	plan tests => 2;

	Service::Vault->clear_all();
	my $v = make_remote(name => 'current-vault');
	$v->set_as_current();

	# When already current, status() must not be called; override it to die
	# so the test would fail if it were reached.
	no warnings 'redefine';
	local *Service::Vault::Remote::status = sub { die 'status() must not be called when already current' };
	use warnings 'redefine';

	my $ret;
	lives_ok { $ret = $v->connect_and_validate() }
		'connect_and_validate() does not die when vault is already current';
	is($ret, $v, 'connect_and_validate() returns self when already current');

	Service::Vault->clear_all();
};

# -------------------------------------------------------------------------
# connect_and_validate() - status ok
# -------------------------------------------------------------------------
subtest 'connect_and_validate() - status ok' => sub {
	plan tests => 3;

	Service::Vault->clear_all();
	my $v = make_remote(name => 'ok-vault');

	no warnings 'redefine';
	local *Service::Vault::Remote::status = sub { 'ok' };
	use warnings 'redefine';

	my $ret;
	lives_ok { $ret = $v->connect_and_validate() }
		'connect_and_validate() does not die when status is ok';
	is(ref($ret), 'Service::Vault::Remote',
		'connect_and_validate() returns a Service::Vault::Remote');
	ok($v->is_current,
		'vault is set as current after connect_and_validate()');

	Service::Vault->clear_all();
};

# -------------------------------------------------------------------------
# connect_and_validate() - status unauthenticated then ok after authenticate
# -------------------------------------------------------------------------
subtest 'connect_and_validate() - unauthenticated triggers authenticate' => sub {
	plan tests => 3;

	Service::Vault->clear_all();
	my $v = make_remote(name => 'unauth-vault');

	my $authenticate_called = 0;
	no warnings 'redefine';
	local *Service::Vault::Remote::status = sub { 'unauthenticated' };
	local *Service::Vault::Remote::authenticate = sub {
		$authenticate_called = 1;
		return $_[0];
	};
	# After authenticate(), initialized() is called to determine new status.
	# Return true so the derived status becomes 'ok'.
	local *Service::Vault::Remote::initialized = sub { 1 };
	use warnings 'redefine';

	my $ret;
	lives_ok { $ret = $v->connect_and_validate() }
		'connect_and_validate() does not die when vault authenticates successfully';
	ok($authenticate_called,
		'authenticate() was called when status was unauthenticated');
	ok($v->is_current,
		'vault is set as current after successful authentication');

	Service::Vault->clear_all();
};

# -------------------------------------------------------------------------
# connect_and_validate() - sealed vault throws
# -------------------------------------------------------------------------
subtest 'connect_and_validate() - sealed vault throws' => sub {
	plan tests => 1;

	Service::Vault->clear_all();
	my $v = make_remote(name => 'sealed-vault');

	no warnings 'redefine';
	local *Service::Vault::Remote::status = sub { 'sealed' };
	use warnings 'redefine';

	quietly {
		throws_ok { $v->connect_and_validate() }
			qr/Could not connect to vault/i,
			'connect_and_validate() throws when vault is sealed';
	};

	Service::Vault->clear_all();
};

# -------------------------------------------------------------------------
# authenticate() - already authenticated
# -------------------------------------------------------------------------
subtest 'authenticate() - already authenticated returns self' => sub {
	plan tests => 2;

	my $v = make_remote(name => 'authed-vault');

	my $query_called = 0;
	no warnings 'redefine';
	local *Service::Vault::Remote::authenticated = sub { 1 };
	local *Service::Vault::Remote::query = sub { $query_called = 1; return ('', 0) };
	use warnings 'redefine';

	my $ret = $v->authenticate();
	is($ret, $v, 'authenticate() returns self when already authenticated');
	ok(!$query_called, 'query() is not called when already authenticated');
};

# -------------------------------------------------------------------------
# authenticate() - approle auth
# -------------------------------------------------------------------------
subtest 'authenticate() - approle via VAULT_ROLE_ID / VAULT_SECRET_ID' => sub {
	plan tests => 2;

	my $v = make_remote(name => 'approle-vault');

	my @query_args;
	local $ENV{VAULT_ROLE_ID}    = 'my-role-id';
	local $ENV{VAULT_SECRET_ID}  = 'my-secret-id';
	delete local $ENV{VAULT_AUTH_TOKEN};
	delete local $ENV{VAULT_USERNAME};
	delete local $ENV{VAULT_PASSWORD};
	delete local $ENV{VAULT_GITHUB_TOKEN};

	my $auth_count = 0;
	no warnings 'redefine';
	local *Service::Vault::Remote::authenticated = sub {
		# First call (guard at top) returns false; subsequent calls return true
		return ($auth_count++ > 0) ? 1 : 0;
	};
	local *Service::Vault::Remote::query = sub {
		my ($self, @args) = @_;
		push @query_args, @args;
		return ('', 0);
	};
	use warnings 'redefine';

	my $ret = $v->authenticate();
	is($ret, $v, 'authenticate() returns self after approle auth');
	ok((grep { /approle/i } @query_args),
		'authenticate() issued a query containing "approle"');
};

# -------------------------------------------------------------------------
# authenticate() - token auth
# -------------------------------------------------------------------------
subtest 'authenticate() - token via VAULT_AUTH_TOKEN' => sub {
	plan tests => 2;

	my $v = make_remote(name => 'token-vault');

	my @query_args;
	delete local $ENV{VAULT_ROLE_ID};
	delete local $ENV{VAULT_SECRET_ID};
	local $ENV{VAULT_AUTH_TOKEN} = 'hvs.EXAMPLE_TOKEN';
	delete local $ENV{VAULT_USERNAME};
	delete local $ENV{VAULT_PASSWORD};
	delete local $ENV{VAULT_GITHUB_TOKEN};

	my $auth_count = 0;
	no warnings 'redefine';
	local *Service::Vault::Remote::authenticated = sub {
		return ($auth_count++ > 0) ? 1 : 0;
	};
	local *Service::Vault::Remote::query = sub {
		my ($self, @args) = @_;
		push @query_args, @args;
		return ('', 0);
	};
	use warnings 'redefine';

	my $ret = $v->authenticate();
	is($ret, $v, 'authenticate() returns self after token auth');
	ok((grep { /token/i } @query_args),
		'authenticate() issued a query containing "token"');
};

# -------------------------------------------------------------------------
# authenticate() - all methods fail, throws
# -------------------------------------------------------------------------
subtest 'authenticate() - all methods fail throws' => sub {
	plan tests => 1;

	my $v = make_remote(name => 'fail-vault');

	delete local $ENV{VAULT_ROLE_ID};
	delete local $ENV{VAULT_SECRET_ID};
	delete local $ENV{VAULT_AUTH_TOKEN};
	delete local $ENV{VAULT_USERNAME};
	delete local $ENV{VAULT_PASSWORD};
	delete local $ENV{VAULT_GITHUB_TOKEN};

	no warnings 'redefine';
	local *Service::Vault::Remote::authenticated = sub { 0 };
	use warnings 'redefine';

	quietly {
		throws_ok { $v->authenticate() }
			qr/Could not successfully authenticate/i,
			'authenticate() throws when no credentials available and vault not authenticated';
	};
};

# -------------------------------------------------------------------------
# rebind() - missing env var throws
# -------------------------------------------------------------------------
subtest 'rebind() - missing GENESIS_TARGET_VAULT throws' => sub {
	plan tests => 1;

	delete local $ENV{GENESIS_TARGET_VAULT};

	quietly {
		throws_ok { Service::Vault::Remote->rebind() }
			qr/Cannot rebind to vault in callback due to missing environment variables/i,
			'rebind() throws when GENESIS_TARGET_VAULT is not set';
	};
};

# -------------------------------------------------------------------------
# rebind() - URL lookup: vault found
# -------------------------------------------------------------------------
subtest 'rebind() - GENESIS_TARGET_VAULT is a URL, vault found' => sub {
	plan tests => 2;

	Service::Vault->clear_all();
	my $v = make_remote(
		url  => 'https://vault.example.com:8200',
		name => 'my-vault',
	);

	local $ENV{GENESIS_TARGET_VAULT} = 'https://vault.example.com:8200';

	no warnings 'redefine';
	local *Service::Vault::Remote::find = sub {
		my ($class, %filter) = @_;
		return ($filter{url} && $filter{url} eq 'https://vault.example.com:8200') ? ($v) : ();
	};
	use warnings 'redefine';

	my $ret = Service::Vault::Remote->rebind();
	ok(defined($ret), 'rebind() returns a vault when URL is found');
	is($ret, $v, 'rebind() returns the matching vault object');

	Service::Vault->clear_all();
};

# -------------------------------------------------------------------------
# rebind() - URL lookup: vault not found throws
# -------------------------------------------------------------------------
subtest 'rebind() - GENESIS_TARGET_VAULT is a URL, vault not found throws' => sub {
	plan tests => 1;

	local $ENV{GENESIS_TARGET_VAULT} = 'https://missing.example.com:8200';

	no warnings 'redefine';
	local *Service::Vault::Remote::find = sub { () };
	use warnings 'redefine';

	quietly {
		throws_ok { Service::Vault::Remote->rebind() }
			qr/Cannot rebind to vault at address/i,
			'rebind() throws when URL-based vault is not found';
	};
};

# -------------------------------------------------------------------------
# rebind() - legacy name lookup: matches default
# -------------------------------------------------------------------------
subtest 'rebind() - legacy name lookup matches default vault' => sub {
	plan tests => 2;

	Service::Vault->clear_all();
	my $v = make_remote(name => 'legacy-vault');

	local $ENV{GENESIS_TARGET_VAULT} = 'legacy-vault';  # not a valid URI

	no warnings 'redefine';
	local *Service::Vault::Remote::default = sub {
		return $v;
	};
	use warnings 'redefine';

	my $ret = Service::Vault::Remote->rebind();
	ok(defined($ret), 'rebind() returns a vault for legacy name matching default');
	is($ret->{name}, 'legacy-vault', 'rebind() returns the default vault in legacy mode');

	Service::Vault->clear_all();
};

# -------------------------------------------------------------------------
# rebind() - legacy name: name does not match default returns undef
# -------------------------------------------------------------------------
subtest 'rebind() - legacy name not matching default returns undef' => sub {
	plan tests => 1;

	my $other = make_remote(name => 'other-vault');

	local $ENV{GENESIS_TARGET_VAULT} = 'some-other-name';

	no warnings 'redefine';
	local *Service::Vault::Remote::default = sub { $other };
	use warnings 'redefine';

	my $ret = Service::Vault::Remote->rebind();
	ok(!defined($ret), 'rebind() returns undef when legacy name does not match default');
};

# -------------------------------------------------------------------------
# attach() - no url specified throws
# -------------------------------------------------------------------------
subtest 'attach() - no url throws' => sub {
	plan tests => 1;

	quietly {
		throws_ok { Service::Vault::Remote->attach(verify => 1) }
			qr/No vault target specified/i,
			'attach() throws when url is not provided';
	};
};

# -------------------------------------------------------------------------
# attach() - url not a valid URL throws
# -------------------------------------------------------------------------
subtest 'attach() - url not valid throws' => sub {
	plan tests => 1;

	quietly {
		throws_ok { Service::Vault::Remote->attach(url => 'not-a-url') }
			qr/Expecting vault target.*to be a url/i,
			'attach() throws when url is not a valid URL';
	};
};

# -------------------------------------------------------------------------
# attach() - env var resolution ($VAR)
# -------------------------------------------------------------------------
subtest 'attach() - env var resolution for url' => sub {
	plan tests => 1;

	local $ENV{VAULT_ADDR} = 'https://vault.example.com:8200';

	my $v = make_remote(url => 'https://vault.example.com:8200', name => 'env-vault');

	no warnings 'redefine';
	local *Service::Vault::find = sub {
		my ($class, %filter) = @_;
		return ($filter{url} && $filter{url} eq 'https://vault.example.com:8200') ? ($v) : ();
	};
	local *Service::Vault::Remote::connect_and_validate = sub { $_[0] };
	use warnings 'redefine';

	my $ret = Service::Vault::Remote->attach(url => '$VAULT_ADDR');
	is(ref($ret), 'Service::Vault::Remote',
		'attach() resolves $ENV_VAR references in url option');
};

# -------------------------------------------------------------------------
# attach() - exact URL match, single result
# -------------------------------------------------------------------------
subtest 'attach() - exact URL match returns vault' => sub {
	plan tests => 2;

	my $v = make_remote(
		url    => 'https://vault.example.com:8200',
		name   => 'matched-vault',
		verify => 1,
	);

	no warnings 'redefine';
	local *Service::Vault::find = sub {
		my ($class, %filter) = @_;
		return ($v);
	};
	local *Service::Vault::Remote::connect_and_validate = sub { $_[0] };
	use warnings 'redefine';

	my $ret = Service::Vault::Remote->attach(
		url    => 'https://vault.example.com:8200',
		verify => 1,
	);
	ok(defined($ret), 'attach() returns vault when exact match found');
	is($ret->{name}, 'matched-vault', 'attach() returns the matched vault');
};

# -------------------------------------------------------------------------
# attach() - no match, no_vault returns undef
# -------------------------------------------------------------------------
subtest 'attach() - no match with no_vault returns undef' => sub {
	plan tests => 1;

	no warnings 'redefine';
	local *Service::Vault::find = sub { () };
	use warnings 'redefine';

	my $ret = Service::Vault::Remote->attach(
		url      => 'https://missing.example.com:8200',
		no_vault => 1,
	);
	ok(!defined($ret), 'attach() returns undef when no match and no_vault is true');
};

# -------------------------------------------------------------------------
# attach() - no match, no no_vault throws
# -------------------------------------------------------------------------
subtest 'attach() - no match without no_vault throws' => sub {
	plan tests => 1;

	no warnings 'redefine';
	local *Service::Vault::find = sub { () };
	use warnings 'redefine';

	quietly {
		throws_ok {
			Service::Vault::Remote->attach(url => 'https://missing.example.com:8200')
		} qr/Safe target for.*not found/i,
			'attach() throws when no match found and no_vault not set';
	};
};

# -------------------------------------------------------------------------
# attach() - multiple matches, alias disambiguation
# -------------------------------------------------------------------------
subtest 'attach() - multiple matches resolved by alias' => sub {
	plan tests => 2;

	my $v1 = make_remote(url => 'https://vault.example.com:8200', name => 'vault-a');
	my $v2 = make_remote(url => 'https://vault.example.com:8200', name => 'vault-b');

	no warnings 'redefine';
	local *Service::Vault::find = sub { ($v1, $v2) };
	local *Service::Vault::Remote::connect_and_validate = sub { $_[0] };
	use warnings 'redefine';

	my $ret = Service::Vault::Remote->attach(
		url   => 'https://vault.example.com:8200',
		alias => 'vault-b',
	);
	ok(defined($ret), 'attach() returns vault when alias disambiguates multiple matches');
	is($ret->{name}, 'vault-b', 'attach() returns the alias-matched vault');
};

# -------------------------------------------------------------------------
# attach() - multiple matches, no alias match throws
# -------------------------------------------------------------------------
subtest 'attach() - multiple matches without alias match throws' => sub {
	plan tests => 1;

	my $v1 = make_remote(url => 'https://vault.example.com:8200', name => 'vault-a');
	my $v2 = make_remote(url => 'https://vault.example.com:8200', name => 'vault-b');

	no warnings 'redefine';
	local *Service::Vault::find = sub { ($v1, $v2) };
	use warnings 'redefine';

	quietly {
		throws_ok {
			Service::Vault::Remote->attach(
				url   => 'https://vault.example.com:8200',
				alias => 'vault-z',  # no match
			)
		} qr/Multiple safe targets found/i,
			'attach() throws when multiple matches and alias does not match any';
	};
};

# -------------------------------------------------------------------------
# target() - known alias, single result
# -------------------------------------------------------------------------
subtest 'target() - known alias, single result' => sub {
	plan tests => 2;

	Service::Vault->clear_all();
	my $v = make_remote(
		url  => 'https://vault.example.com:8200',
		name => 'prod-vault',
	);

	no warnings 'redefine';
	local *Service::Vault::_get_targets = sub {
		my ($target) = @_;
		return ('https://vault.example.com:8200', 'prod-vault');
	};
	local *Service::Vault::Remote::find = sub {
		my ($class, %filter) = @_;
		return ($v);
	};
	local *Service::Vault::Remote::connect_and_validate = sub { $_[0] };
	use warnings 'redefine';

	my $ret = Service::Vault::Remote->target('prod-vault');
	ok(defined($ret), 'target() returns a vault for a known alias');
	is($ret->{name}, 'prod-vault', 'target() returns the correct vault');

	Service::Vault->clear_all();
};

# -------------------------------------------------------------------------
# target() - alias not found throws
# -------------------------------------------------------------------------
subtest 'target() - alias not found throws' => sub {
	plan tests => 1;

	no warnings 'redefine';
	local *Service::Vault::_get_targets = sub { (undef) };
	use warnings 'redefine';

	quietly {
		throws_ok {
			Service::Vault::Remote->target('no-such-vault')
		} qr/not found/i,
			'target() throws when the alias is not found';
	};
};

# -------------------------------------------------------------------------
# target() - multiple targets for same URL throws
# -------------------------------------------------------------------------
subtest 'target() - multiple targets for same URL throws' => sub {
	plan tests => 1;

	no warnings 'redefine';
	local *Service::Vault::_get_targets = sub {
		return ('https://vault.example.com:8200', 'vault-a', 'vault-b');
	};
	use warnings 'redefine';

	quietly {
		throws_ok {
			Service::Vault::Remote->target('vault-a')
		} qr/Multiple safe targets use url/i,
			'target() throws when multiple aliases share the same URL';
	};
};

done_testing;
