#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;

our $TODO;

use_ok 'Service::Vault::Admin';
use_ok 'Service::Vault::Admin::AppRole';
use Genesis;

# ---------------------------------------------------------------------------
# Mock vault class
#
# Service::Vault::Mock provides proper list-returning query() and set()
# methods. A queue of responses drives each successive call.  When the
# queue is exhausted the default response is used.
# ---------------------------------------------------------------------------
{
	package Service::Vault::Mock;

	sub new {
		my ($class, %args) = @_;
		return bless {
			_query_responses => [],   # queue: each element is [output, rc]
			_set_calls       => [],   # recorded set() invocations
			_query_calls     => [],   # recorded query() invocations
			_default_query   => ['', 0],
			_default_rc      => 0,
			%args,
		}, $class;
	}

	# Push one or more [output, rc] pairs onto the query response queue
	sub _push_query { my $self = shift; push @{$self->{_query_responses}}, @_; }

	sub query {
		my ($self, @args) = @_;
		push @{$self->{_query_calls}}, [@args];
		my $resp = scalar(@{$self->{_query_responses}})
			? shift @{$self->{_query_responses}}
			: $self->{_default_query};
		return @$resp;
	}

	sub set {
		my ($self, @args) = @_;
		push @{$self->{_set_calls}}, [@args];
		return 1;
	}

	sub name { $_[0]->{name} // 'mock-vault' }
}

sub make_vault {
	my (%args) = @_;
	return Service::Vault::Mock->new(name => 'mock-vault', %args);
}

sub make_admin {
	my (%args) = @_;
	my $vault = delete $args{vault} // make_vault();
	return Service::Vault::Admin->new($vault);
}

# ---------------------------------------------------------------------------
# 1. Module loading
# ---------------------------------------------------------------------------
# (covered by use_ok above)

# ---------------------------------------------------------------------------
# 2. Admin::new
# ---------------------------------------------------------------------------
subtest 'Admin::new - valid vault succeeds' => sub {
	my $vault = make_vault();
	my $admin = Service::Vault::Admin->new($vault);
	isa_ok($admin, 'Service::Vault::Admin', 'new() returns Admin object');
};

subtest 'Admin::new - undef vault throws' => sub {
	throws_ok {
		Service::Vault::Admin->new(undef);
	} qr/requires a Service::Vault object/,
		'new(undef) throws with expected message';
};

subtest 'Admin::new - non-vault ref throws' => sub {
	throws_ok {
		Service::Vault::Admin->new(bless {}, 'SomeOtherClass');
	} qr/requires a Service::Vault object/,
		'new() with wrong class throws';
};

# ---------------------------------------------------------------------------
# 3. Admin::vault
# ---------------------------------------------------------------------------
subtest 'Admin::vault - returns constructor arg' => sub {
	my $vault = make_vault();
	my $admin = Service::Vault::Admin->new($vault);
	is($admin->vault, $vault, 'vault() returns the vault passed to new()');
};

# ---------------------------------------------------------------------------
# 4. Admin::approles - lazy creation and caching
# ---------------------------------------------------------------------------
subtest 'Admin::approles - lazy AppRole creation' => sub {
	my $admin = make_admin();
	my $svc = $admin->approles();
	isa_ok($svc, 'Service::Vault::Admin::AppRole',
		'approles() returns an AppRole object');
};

subtest 'Admin::approles - result is cached' => sub {
	my $admin = make_admin();
	my $svc1  = $admin->approles();
	my $svc2  = $admin->approles();
	is($svc1, $svc2, 'approles() returns the same object on successive calls');
};

# ---------------------------------------------------------------------------
# 5. Admin::policy_exists
# ---------------------------------------------------------------------------
subtest 'Admin::policy_exists - found' => sub {
	my $vault = make_vault();
	$vault->_push_query(["root\ndefault\nmy-policy\n", 0]);
	my $admin = Service::Vault::Admin->new($vault);
	ok($admin->policy_exists('my-policy'),
		'policy_exists() returns true when policy is listed');
};

subtest 'Admin::policy_exists - not found' => sub {
	my $vault = make_vault();
	$vault->_push_query(["root\ndefault\n", 0]);
	my $admin = Service::Vault::Admin->new($vault);
	ok(!$admin->policy_exists('my-policy'),
		'policy_exists() returns false when policy is absent');
};

subtest 'Admin::policy_exists - query failure returns 0' => sub {
	my $vault = make_vault();
	$vault->_push_query(['error output', 1]);
	my $admin = Service::Vault::Admin->new($vault);
	is($admin->policy_exists('my-policy'), 0,
		'policy_exists() returns 0 when vault query fails');
};

# ---------------------------------------------------------------------------
# 6. Admin::create_policy
# ---------------------------------------------------------------------------
subtest 'Admin::create_policy - new policy created' => sub {
	my $vault = make_vault();
	# Call 1: policy list — empty (policy does not exist)
	$vault->_push_query(['', 0]);
	# Call 2: policy write — succeeds
	$vault->_push_query(['', 0]);
	my $admin = Service::Vault::Admin->new($vault);
	my $result = $admin->create_policy('new-policy', 'path "secret/*" {}', prompt => 0);
	is($result, 1, 'create_policy() returns 1 for new policy');
};

subtest 'Admin::create_policy - existing policy with overwrite' => sub {
	my $vault = make_vault();
	# Call 1: policy list — policy exists
	$vault->_push_query(["new-policy\n", 0]);
	# Call 2: policy write — succeeds
	$vault->_push_query(['', 0]);
	my $admin = Service::Vault::Admin->new($vault);
	my $result = $admin->create_policy('new-policy', 'path "secret/*" {}',
		overwrite => 1, prompt => 0);
	is($result, 1, 'create_policy() returns 1 when overwriting existing policy');
};

subtest 'Admin::create_policy - existing policy without overwrite skips' => sub {
	my $vault = make_vault();
	$vault->_push_query(["new-policy\n", 0]);
	my $admin = Service::Vault::Admin->new($vault);
	my $result = $admin->create_policy('new-policy', 'path "secret/*" {}',
		prompt => 0, overwrite => 0);
	is($result, 0, 'create_policy() returns 0 when skipping existing policy');
};

subtest 'Admin::create_policy - missing name throws' => sub {
	my $admin = make_admin();
	throws_ok {
		$admin->create_policy(undef, 'content');
	} qr/Policy name is required/,
		'create_policy() throws when name is missing';
};

subtest 'Admin::create_policy - missing content throws' => sub {
	my $admin = make_admin();
	throws_ok {
		$admin->create_policy('my-policy', undef);
	} qr/Policy content is required/,
		'create_policy() throws when content is missing';
};

subtest 'Admin::create_policy - vault write failure throws' => sub {
	my $vault = make_vault();
	# Call 1: policy list — policy does not exist
	$vault->_push_query(['', 0]);
	# Call 2: policy write — fails
	$vault->_push_query(['vault error message', 1]);
	my $admin = Service::Vault::Admin->new($vault);
	throws_ok {
		$admin->create_policy('my-policy', 'content', prompt => 0);
	} qr/Failed to create policy/,
		'create_policy() throws when vault write fails';
};

# ---------------------------------------------------------------------------
# 7. Admin::create_approle
# ---------------------------------------------------------------------------
subtest 'Admin::create_approle - new role with defaults' => sub {
	my $vault = make_vault();
	# vault write auth/approle/role/concourse — succeeds
	$vault->_push_query(['', 0]);
	my $admin = Service::Vault::Admin->new($vault);

	no warnings 'redefine';
	local *Service::Vault::Admin::AppRole::list = sub { () };
	use warnings 'redefine';

	my $result = $admin->create_approle('concourse', prompt => 0);
	is($result, 1, 'create_approle() returns 1 for new role');
};

subtest 'Admin::create_approle - missing name throws' => sub {
	my $admin = make_admin();
	throws_ok {
		$admin->create_approle(undef);
	} qr/AppRole name is required/,
		'create_approle() throws when role name is missing';
};

subtest 'Admin::create_approle - existing role with overwrite deletes and recreates' => sub {
	my $vault = make_vault();
	# Call 1: vault delete existing role — succeeds
	$vault->_push_query(['', 0]);
	# Call 2: vault write new role — succeeds
	$vault->_push_query(['', 0]);
	my $admin = Service::Vault::Admin->new($vault);

	no warnings 'redefine';
	local *Service::Vault::Admin::AppRole::list = sub { ('concourse') };
	use warnings 'redefine';

	my $result = $admin->create_approle('concourse', overwrite => 1, prompt => 0);
	is($result, 1, 'create_approle() returns 1 when overwriting existing role');

	my $has_delete = grep { grep { /vault delete/ } @$_ } @{$vault->{_query_calls}};
	ok($has_delete, 'create_approle() issued a vault delete for the existing role');
};

subtest 'Admin::create_approle - existing role without overwrite skips' => sub {
	my $vault = make_vault();
	my $admin = Service::Vault::Admin->new($vault);

	no warnings 'redefine';
	local *Service::Vault::Admin::AppRole::list = sub { ('concourse') };
	use warnings 'redefine';

	my $result = $admin->create_approle('concourse', prompt => 0, overwrite => 0);
	ok(!defined($result), 'create_approle() returns undef when skipping existing role');
};

subtest 'Admin::create_approle - custom config overrides defaults' => sub {
	my $vault = make_vault();
	$vault->_push_query(['', 0]);
	my $admin = Service::Vault::Admin->new($vault);

	no warnings 'redefine';
	local *Service::Vault::Admin::AppRole::list = sub { () };
	use warnings 'redefine';

	$admin->create_approle('concourse', token_ttl => '120m', prompt => 0);

	my @all_args = map { @$_ } @{$vault->{_query_calls}};
	ok((grep { $_ eq 'token_ttl=120m' } @all_args),
		'create_approle() forwards custom token_ttl to vault write');
};

# ---------------------------------------------------------------------------
# 8. Admin::get_approle_credentials
# ---------------------------------------------------------------------------
subtest 'Admin::get_approle_credentials - success' => sub {
	my $vault = make_vault();
	# Call 1: vault read role-id
	$vault->_push_query(["my-role-id\n", 0]);
	# Call 2: vault write secret-id
	$vault->_push_query(["my-secret-id\n", 0]);
	my $admin = Service::Vault::Admin->new($vault);

	no warnings 'redefine';
	local *Service::Vault::Admin::AppRole::list = sub { ('myrole') };
	use warnings 'redefine';

	my ($role_id, $secret_id) = $admin->get_approle_credentials('myrole');
	is($role_id,   'my-role-id',   'get_approle_credentials() returns role_id');
	is($secret_id, 'my-secret-id', 'get_approle_credentials() returns secret_id');
};

subtest 'Admin::get_approle_credentials - missing name throws' => sub {
	my $admin = make_admin();
	throws_ok {
		$admin->get_approle_credentials(undef);
	} qr/AppRole name is required/,
		'get_approle_credentials() throws when name is missing';
};

subtest 'Admin::get_approle_credentials - nonexistent role throws' => sub {
	my $vault = make_vault();
	my $admin = Service::Vault::Admin->new($vault);

	no warnings 'redefine';
	local *Service::Vault::Admin::AppRole::list = sub { () };
	use warnings 'redefine';

	throws_ok {
		$admin->get_approle_credentials('no-such-role');
	} qr/does not exist/,
		'get_approle_credentials() throws when role does not exist';
};

subtest 'Admin::get_approle_credentials - vault query failure throws' => sub {
	my $vault = make_vault();
	# Call 1: vault read role-id — fails
	$vault->_push_query(['error', 1]);
	# Call 2: vault write secret-id — also fails (rc included for completeness)
	$vault->_push_query(['error', 1]);
	my $admin = Service::Vault::Admin->new($vault);

	no warnings 'redefine';
	local *Service::Vault::Admin::AppRole::list = sub { ('myrole') };
	use warnings 'redefine';

	throws_ok {
		$admin->get_approle_credentials('myrole');
	} qr/Failed to retrieve credentials/,
		'get_approle_credentials() throws when vault read/write fails';
};

# ---------------------------------------------------------------------------
# 9. Admin::store_approle_credentials
# ---------------------------------------------------------------------------
subtest 'Admin::store_approle_credentials - success' => sub {
	my $vault = make_vault();
	my $admin = Service::Vault::Admin->new($vault);
	my $result = $admin->store_approle_credentials(
		'concourse', '/secret/ci/concourse', 'role-abc', 'secret-xyz',
	);
	is($result, 1, 'store_approle_credentials() returns 1');
	is(scalar(@{$vault->{_set_calls}}), 2,
		'store_approle_credentials() calls set() twice');

	my %written = map { $_->[1] => $_->[2] } @{$vault->{_set_calls}};
	is($written{'approle-id'},     'role-abc',   'stored approle-id correctly');
	is($written{'approle-secret'}, 'secret-xyz', 'stored approle-secret correctly');
};

subtest 'Admin::store_approle_credentials - missing params throws' => sub {
	my $admin = make_admin();

	throws_ok {
		$admin->store_approle_credentials('role', '/path', undef, 'secret');
	} qr/All parameters are required/,
		'store_approle_credentials() throws when role_id is missing';

	throws_ok {
		$admin->store_approle_credentials('role', '/path', 'rid', undef);
	} qr/All parameters are required/,
		'store_approle_credentials() throws when secret_id is missing';

	throws_ok {
		$admin->store_approle_credentials(undef, '/path', 'rid', 'sid');
	} qr/All parameters are required/,
		'store_approle_credentials() throws when role_name is missing';

	throws_ok {
		$admin->store_approle_credentials('role', undef, 'rid', 'sid');
	} qr/All parameters are required/,
		'store_approle_credentials() throws when storage_path is missing';
};

# ---------------------------------------------------------------------------
# 10. Admin::setup_concourse_approle (prompt => 0)
# ---------------------------------------------------------------------------
subtest 'Admin::setup_concourse_approle - orchestration chain (no prompt)' => sub {
	my @method_calls;
	my $vault = make_vault();
	my $admin = Service::Vault::Admin->new($vault);

	no warnings 'redefine';

	local *Service::Vault::Admin::AppRole::enable = sub {
		push @method_calls, 'approles.enable';
		return 1;
	};

	local *Service::Vault::Admin::create_policy = sub {
		push @method_calls, 'create_policy';
		return 1;
	};

	local *Service::Vault::Admin::create_approle = sub {
		push @method_calls, 'create_approle';
		return 1;
	};

	local *Service::Vault::Admin::get_approle_credentials = sub {
		push @method_calls, 'get_approle_credentials';
		return ('rid', 'sid');
	};

	local *Service::Vault::Admin::store_approle_credentials = sub {
		push @method_calls, 'store_approle_credentials';
		return 1;
	};

	use warnings 'redefine';

	my $result = $admin->setup_concourse_approle(
		prompt       => 0,
		role_name    => 'concourse',
		overwrite    => 1,
		storage_base => '/secret/genesis/',
	);

	is($result, 1, 'setup_concourse_approle() returns 1');
	is($method_calls[0], 'approles.enable',           'step 1: approles.enable() called');
	is($method_calls[1], 'create_policy',             'step 2: create_policy() called');
	is($method_calls[2], 'create_approle',            'step 3: create_approle() called');
	is($method_calls[3], 'get_approle_credentials',   'step 4: get_approle_credentials() called');
	is($method_calls[4], 'store_approle_credentials', 'step 5: store_approle_credentials() called');
};

# ---------------------------------------------------------------------------
# 11. Admin::setup_genesis_pipelines_approle (prompt => 0)
# ---------------------------------------------------------------------------
subtest 'Admin::setup_genesis_pipelines_approle - orchestration chain (no prompt)' => sub {
	my @method_calls;
	my $vault = make_vault();
	my $admin = Service::Vault::Admin->new($vault);

	no warnings 'redefine';

	local *Service::Vault::Admin::AppRole::enable = sub {
		push @method_calls, 'approles.enable';
		return 1;
	};

	local *Service::Vault::Admin::create_policy = sub {
		push @method_calls, 'create_policy';
		return 1;
	};

	local *Service::Vault::Admin::create_approle = sub {
		push @method_calls, 'create_approle';
		return 1;
	};

	local *Service::Vault::Admin::get_approle_credentials = sub {
		push @method_calls, 'get_approle_credentials';
		return ('rid', 'sid');
	};

	local *Service::Vault::Admin::store_approle_credentials = sub {
		push @method_calls, 'store_approle_credentials';
		return 1;
	};

	use warnings 'redefine';

	my $result = $admin->setup_genesis_pipelines_approle(
		prompt       => 0,
		role_name    => 'genesis-pipelines',
		exodus_mount => '/secret/exodus',
		storage_base => '/secret/ci/',
		overwrite    => 1,
	);

	is($result, 1, 'setup_genesis_pipelines_approle() returns 1');
	is($method_calls[0], 'approles.enable',           'step 1: approles.enable() called');
	is($method_calls[1], 'create_policy',             'step 2: create_policy() called');
	is($method_calls[2], 'create_approle',            'step 3: create_approle() called');
	is($method_calls[3], 'get_approle_credentials',   'step 4: get_approle_credentials() called');
	is($method_calls[4], 'store_approle_credentials', 'step 5: store_approle_credentials() called');
};

subtest 'Admin::setup_genesis_pipelines_approle - missing exodus_mount throws' => sub {
	delete local $ENV{GENESIS_EXODUS_MOUNT};
	my $admin = make_admin();
	throws_ok {
		$admin->setup_genesis_pipelines_approle(prompt => 0);
	} qr/Cannot find mount for exodus path/,
		'setup_genesis_pipelines_approle() throws when exodus_mount is absent';
};

# ---------------------------------------------------------------------------
# 12. AppRole::new
# ---------------------------------------------------------------------------
subtest 'AppRole::new - valid admin succeeds' => sub {
	my $admin = make_admin();
	my $ar = Service::Vault::Admin::AppRole->new($admin);
	isa_ok($ar, 'Service::Vault::Admin::AppRole', 'new() returns AppRole object');
};

subtest 'AppRole::new - undef admin throws' => sub {
	throws_ok {
		Service::Vault::Admin::AppRole->new(undef);
	} qr/requires a Service::Vault::Admin object/,
		'AppRole::new(undef) throws with expected message';
};

subtest 'AppRole::new - wrong class throws' => sub {
	throws_ok {
		Service::Vault::Admin::AppRole->new(bless {}, 'WrongClass');
	} qr/requires a Service::Vault::Admin object/,
		'AppRole::new() with wrong class throws';
};

# ---------------------------------------------------------------------------
# AppRole::new constructor bail message spelling
# ---------------------------------------------------------------------------
eval {
	Service::Vault::Admin::AppRole->new(undef);
};
like($@, qr/\brequires\b/,
	'AppRole::new error message spells "requires" correctly');

# ---------------------------------------------------------------------------
# 13. AppRole::vault
# ---------------------------------------------------------------------------
subtest 'AppRole::vault - returns admin vault' => sub {
	my $vault = make_vault();
	my $admin = Service::Vault::Admin->new($vault);
	my $ar    = Service::Vault::Admin::AppRole->new($admin);
	is($ar->vault, $vault, 'AppRole::vault() returns the underlying vault object');
};

# ---------------------------------------------------------------------------
# 14. AppRole::enabled
# ---------------------------------------------------------------------------
subtest 'AppRole::enabled - approle/ key present means enabled' => sub {
	my $vault = make_vault();
	$vault->_push_query(['{"approle/":{"type":"approle"}}', 0]);
	my $admin = Service::Vault::Admin->new($vault);
	my $ar    = Service::Vault::Admin::AppRole->new($admin);

	my $result = eval { $ar->enabled() };
	ok(!$@, 'enabled() does not die');
	ok($result, 'enabled() returns true when approle/ key is present');
};

subtest 'AppRole::enabled - approle/ key absent means disabled' => sub {
	my $vault = make_vault();
	$vault->_push_query(['{"token/":{"type":"token"}}', 0]);
	my $admin = Service::Vault::Admin->new($vault);
	my $ar    = Service::Vault::Admin::AppRole->new($admin);

	my $result = eval { $ar->enabled() };
	ok(!$@, 'enabled() does not die');
	ok(!$result, 'enabled() returns false when approle/ key is absent');
};

# ---------------------------------------------------------------------------
# 15. AppRole::enable
# ---------------------------------------------------------------------------
subtest 'AppRole::enable - already enabled short-circuits' => sub {
	my $vault = make_vault();
	$vault->_push_query(['{"approle/":{"type":"approle"}}', 0]);
	my $admin = Service::Vault::Admin->new($vault);
	my $ar    = Service::Vault::Admin::AppRole->new($admin);

	my $result = eval { $ar->enable() };
	ok(!$@, 'enable() does not die when already enabled');
	is($result, 1, 'enable() returns 1 when already enabled');
	my $enable_calls = grep { join(' ', @$_) =~ /auth enable/ } @{$vault->{_query_calls}};
	is($enable_calls, 0,
		'enable() does not call vault auth enable when already enabled');
};

subtest 'AppRole::enable - not enabled calls vault auth enable' => sub {
	my $vault = make_vault();
	# Call 1: vault auth list — approle not present
	$vault->_push_query(['{"token/":{"type":"token"}}', 0]);
	# Call 2: vault auth enable approle — succeeds
	$vault->_push_query(['', 0]);
	my $admin = Service::Vault::Admin->new($vault);
	my $ar    = Service::Vault::Admin::AppRole->new($admin);

	my $result = eval { $ar->enable() };
	ok(!$@, 'enable() does not die when needs enabling');
	is($result, 1, 'enable() returns 1 after enabling');
	my $enable_calls = grep { join(' ', @$_) =~ /auth enable/ } @{$vault->{_query_calls}};
	ok($enable_calls,
		'enable() calls vault auth enable when not already enabled');
};

subtest 'AppRole::enable - vault failure throws' => sub {
	my $vault = make_vault();
	# Call 1: vault auth list — approle not present
	$vault->_push_query(['{"token/":{"type":"token"}}', 0]);
	# Call 2: vault auth enable — fails
	$vault->_push_query(['enable error', 1]);
	my $admin = Service::Vault::Admin->new($vault);
	my $ar    = Service::Vault::Admin::AppRole->new($admin);

	throws_ok {
		$ar->enable();
	} qr/Failed to enable AppRole auth method/,
		'enable() throws when vault auth enable fails';
};

# ---------------------------------------------------------------------------
# 16. AppRole::list
# ---------------------------------------------------------------------------
subtest 'AppRole::list - parses JSON array' => sub {
	my $vault = make_vault();
	$vault->_push_query(['["concourse","genesis-pipelines"]', 0]);
	my $admin = Service::Vault::Admin->new($vault);
	my $ar    = Service::Vault::Admin::AppRole->new($admin);

	my @roles = eval { $ar->list() };
	ok(!$@, 'list() does not die');
	is(scalar(@roles), 2, 'list() returns correct number of roles');
	ok((grep { $_ eq 'concourse' }         @roles), 'list() includes concourse');
	ok((grep { $_ eq 'genesis-pipelines' } @roles), 'list() includes genesis-pipelines');
};

subtest 'AppRole::list - vault failure returns empty list' => sub {
	my $vault = make_vault();
	$vault->_push_query(['', 1]);
	my $admin = Service::Vault::Admin->new($vault);
	my $ar    = Service::Vault::Admin::AppRole->new($admin);

	my @roles = eval { $ar->list() };
	ok(!$@, 'list() does not die on vault failure');
	is(scalar(@roles), 0, 'list() returns empty list when vault fails');
};

# ---------------------------------------------------------------------------
# 17. AppRole::exists
# ---------------------------------------------------------------------------
subtest 'AppRole::exists - found in list' => sub {
	my $vault = make_vault();
	$vault->_push_query(['["concourse","genesis-pipelines"]', 0]);
	my $admin = Service::Vault::Admin->new($vault);
	my $ar    = Service::Vault::Admin::AppRole->new($admin);

	my $result = eval { $ar->exists('concourse') };
	ok(!$@, 'exists() does not die');
	ok($result, 'exists() returns true when role is in the list');
};

subtest 'AppRole::exists - not found' => sub {
	my $vault = make_vault();
	$vault->_push_query(['["genesis-pipelines"]', 0]);
	my $admin = Service::Vault::Admin->new($vault);
	my $ar    = Service::Vault::Admin::AppRole->new($admin);

	my $result = eval { $ar->exists('concourse') };
	ok(!$@, 'exists() does not die');
	ok(!$result, 'exists() returns false when role is not in the list');
};

done_testing;
