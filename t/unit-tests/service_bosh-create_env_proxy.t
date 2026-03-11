#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::Deep;
use Test::Exception;
use Test::Output;

use_ok 'Service::BOSH';
use_ok 'Service::BOSH::CreateEnvProxy';
use Genesis;

# ---------------------------------------------------------------------------
# Helper: build a CreateEnvProxy with fake-bosh already wired up
# ---------------------------------------------------------------------------
sub get_create_env_proxy {
	my ($env_or_undef) = @_;
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	return Service::BOSH::CreateEnvProxy->new($env_or_undef);
}

# ---------------------------------------------------------------------------
# Helper: build a minimal mock env object that responds to ->name
# ---------------------------------------------------------------------------
sub mock_env {
	my ($name) = @_;
	return Mock->new(name => $name);
}

# ===========================================================================
# 1. Module loading
# ===========================================================================
subtest 'Module loading' => sub {
	plan tests => 3;

	use_ok 'Service::BOSH::CreateEnvProxy';

	# Verify the class is reachable and blessed correctly
	fake_bosh('');
	my $proxy = Service::BOSH::CreateEnvProxy->new(undef);
	isa_ok $proxy, 'Service::BOSH::CreateEnvProxy',
		'new() returns a Service::BOSH::CreateEnvProxy object';
	isa_ok $proxy, 'Service::BOSH',
		'Service::BOSH::CreateEnvProxy isa Service::BOSH';
};

# ===========================================================================
# 2. Inheritance
# ===========================================================================
subtest 'Inheritance' => sub {
	plan tests => 2;

	ok Service::BOSH::CreateEnvProxy->isa('Service::BOSH'),
		'Service::BOSH::CreateEnvProxy ISA Service::BOSH';

	my @isa = @Service::BOSH::CreateEnvProxy::ISA;
	ok scalar(grep { $_ eq 'Service::BOSH' } @isa),
		'@ISA contains Service::BOSH directly';
};

# ===========================================================================
# 3. new() constructor
# ===========================================================================
subtest 'new() constructor' => sub {
	plan tests => 5;

	fake_bosh('');

	# With an env object
	my $env = mock_env('my-bosh-director');
	my $proxy = get_create_env_proxy($env);
	isa_ok $proxy, 'Service::BOSH::CreateEnvProxy',
		'new($env) returns a CreateEnvProxy object';
	is $proxy->alias, 'my-bosh-director',
		'new($env) sets alias to env->name';

	# With undef
	my $proxy_no_env = get_create_env_proxy(undef);
	isa_ok $proxy_no_env, 'Service::BOSH::CreateEnvProxy',
		'new(undef) returns a CreateEnvProxy object';
	is $proxy_no_env->alias, 'create-env',
		'new(undef) defaults alias to "create-env"';

	# With an env that has a different name
	my $env2 = mock_env('sandbox-bosh');
	my $proxy2 = get_create_env_proxy($env2);
	is $proxy2->alias, 'sandbox-bosh',
		'new($env) uses the name returned by env->name';
};

# ===========================================================================
# 4. alias()
# ===========================================================================
subtest 'alias()' => sub {
	plan tests => 4;

	fake_bosh('');

	# Returns env name when env is set
	my $env = mock_env('prod-bosh');
	my $proxy = get_create_env_proxy($env);
	is $proxy->alias, 'prod-bosh',
		'alias() returns the env name when env was provided';

	# Returns 'create-env' when no env
	my $proxy_no_env = get_create_env_proxy(undef);
	is $proxy_no_env->alias, 'create-env',
		'alias() returns "create-env" when no env was provided';

	# Returns 'create-env' when internal alias is empty string
	my $proxy_empty = Service::BOSH::CreateEnvProxy->new(undef);
	$proxy_empty->{alias} = '';
	is $proxy_empty->alias, 'create-env',
		'alias() returns "create-env" when internal alias is empty string';

	# Returns 'create-env' when internal alias is undef
	my $proxy_undef_alias = Service::BOSH::CreateEnvProxy->new(undef);
	$proxy_undef_alias->{alias} = undef;
	is $proxy_undef_alias->alias, 'create-env',
		'alias() returns "create-env" when internal alias is undef';
};

# ===========================================================================
# 5. has_director()
# ===========================================================================
subtest 'has_director() inherited from base class' => sub {
	plan tests => 3;

	fake_bosh('');

	# Class method on CreateEnvProxy
	is(Service::BOSH::CreateEnvProxy->has_director, 0,
		'CreateEnvProxy->has_director() class method returns 0');

	# Instance method
	my $proxy = get_create_env_proxy(undef);
	is($proxy->has_director, 0,
		'$proxy->has_director() instance method returns 0');

	# Contrast with base class behaviour
	is(Service::BOSH->has_director, 0,
		'Service::BOSH->has_director() also returns 0 (base defines it)');
};

# ===========================================================================
# 6. create_env()
# ===========================================================================
subtest 'create_env() - missing argument errors' => sub {
	plan tests => 2;

	local $ENV{GENESIS_BOSH_COMMAND};
	fake_bosh('');
	my $proxy = get_create_env_proxy(undef);

	quietly {
		throws_ok { $proxy->create_env() }
			qr/missing deployment manifest/i,
			'create_env() dies when manifest is not provided';
	};

	quietly {
		throws_ok { $proxy->create_env('manifest.yml') }
			qr/missing 'state' option/i,
			'create_env() dies when state option is missing';
	};
};

subtest 'create_env() - manifest and state args' => sub {
	plan tests => 2;

	local $ENV{GENESIS_BOSH_COMMAND};
	pushd $ENV{HOME};

	bosh_runs_as('create-env --state /path/to/state.json /path/to/bosh.yml');
	my $proxy = get_create_env_proxy(undef);
	my ($out, $rc) = $proxy->create_env('/path/to/bosh.yml',
		state => '/path/to/state.json',
	);
	ok !$rc,
		'create_env() with manifest and state succeeds (exit code 0)';

	# State is always passed as --state regardless of path
	bosh_runs_as('create-env --state relative/state.json relative/manifest.yml');
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	($out, $rc) = $proxy->create_env('relative/manifest.yml',
		state => 'relative/state.json',
	);
	ok !$rc,
		'create_env() accepts relative paths for manifest and state';

	popd;
};

subtest 'create_env() - vars_file option' => sub {
	plan tests => 2;

	local $ENV{GENESIS_BOSH_COMMAND};
	pushd $ENV{HOME};

	mkdir_or_fail('path/to');
	put_file('path/to/vars.yml', "---\nname: value\n");

	# vars_file is added with -l when the file exists
	bosh_runs_as('create-env --state state.json -l path/to/vars.yml manifest.yml');
	my $proxy = get_create_env_proxy(undef);
	my ($out, $rc) = $proxy->create_env('manifest.yml',
		state     => 'state.json',
		vars_file => 'path/to/vars.yml',
	);
	ok !$rc,
		'create_env() includes -l <vars_file> when file exists';

	# vars_file is silently skipped when file does not exist
	bosh_runs_as('create-env --state state.json manifest.yml');
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	($out, $rc) = $proxy->create_env('manifest.yml',
		state     => 'state.json',
		vars_file => 'path/to/nonexistent.yml',
	);
	ok !$rc,
		'create_env() omits -l when vars_file does not exist on disk';

	popd;
};

subtest 'create_env() - store option' => sub {
	plan tests => 2;

	local $ENV{GENESIS_BOSH_COMMAND};
	pushd $ENV{HOME};

	mkdir_or_fail('path/to');
	put_file('path/to/creds.yml', "---\n");

	# store is added with --vars-store when the file exists
	bosh_runs_as('create-env --state state.json --vars-store path/to/creds.yml manifest.yml');
	my $proxy = get_create_env_proxy(undef);
	my ($out, $rc) = $proxy->create_env('manifest.yml',
		state => 'state.json',
		store => 'path/to/creds.yml',
	);
	ok !$rc,
		'create_env() includes --vars-store when store file exists';

	# store is silently skipped when file does not exist
	bosh_runs_as('create-env --state state.json manifest.yml');
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	($out, $rc) = $proxy->create_env('manifest.yml',
		state => 'state.json',
		store => 'path/to/nonexistent-creds.yml',
	);
	ok !$rc,
		'create_env() omits --vars-store when store file does not exist';

	popd;
};

subtest 'create_env() - flags option' => sub {
	plan tests => 1;

	local $ENV{GENESIS_BOSH_COMMAND};
	pushd $ENV{HOME};

	bosh_runs_as('create-env --recreate --state state.json manifest.yml');
	my $proxy = get_create_env_proxy(undef);
	my ($out, $rc) = $proxy->create_env('manifest.yml',
		state => 'state.json',
		flags => ['--recreate'],
	);
	ok !$rc,
		'create_env() prepends extra flags before --state and manifest';

	popd;
};

subtest 'create_env() - full options combined' => sub {
	plan tests => 1;

	local $ENV{GENESIS_BOSH_COMMAND};
	pushd $ENV{HOME};

	mkdir_or_fail('combined');
	put_file('combined/creds.yml',    "---\n");
	put_file('combined/vars.yml',     "---\n");

	bosh_runs_as(
		'create-env --debug --state combined/state.json'
		. ' --vars-store combined/creds.yml'
		. ' -l combined/vars.yml combined/manifest.yml'
	);
	my $proxy = get_create_env_proxy(undef);
	my ($out, $rc) = $proxy->create_env('combined/manifest.yml',
		state     => 'combined/state.json',
		store     => 'combined/creds.yml',
		vars_file => 'combined/vars.yml',
		flags     => ['--debug'],
	);
	ok !$rc,
		'create_env() builds correct command with all options combined';

	popd;
};

subtest 'create_env() - CEP-2: missing dryrun path (known defect)' => sub {
	plan tests => 1;

	local $ENV{GENESIS_BOSH_COMMAND};
	pushd $ENV{HOME};

	# Known defect CEP-2: create_env() missing dryrun path.
	# Passing dryrun => 1 has NO effect: the real bosh create-env command
	# still executes unconditionally.  This test documents the current
	# (broken) behaviour so that when CEP-2 is fixed the test will need
	# updating.
	#
	# Expected correct behaviour (post-fix): create_env() with dryrun => 1
	# should log the would-execute message and return without running bosh.
	# Current behaviour: create_env() ignores dryrun and executes bosh.
	bosh_runs_as('create-env --state state.json manifest.yml');
	my $proxy = get_create_env_proxy(undef);
	my ($out, $rc) = $proxy->create_env('manifest.yml',
		state  => 'state.json',
		dryrun => 1,       # CEP-2: this option is silently ignored
	);
	ok !$rc,
		'CEP-2: create_env() executes bosh even when dryrun => 1 is passed'
		. ' (should be a no-op -- this test documents the bug)';

	popd;
};

# ===========================================================================
# 7. delete_env()
# ===========================================================================
subtest 'delete_env() - missing argument errors' => sub {
	plan tests => 2;

	local $ENV{GENESIS_BOSH_COMMAND};
	fake_bosh('');
	my $proxy = get_create_env_proxy(undef);

	quietly {
		throws_ok { $proxy->delete_env() }
			qr/missing deployment manifest/i,
			'delete_env() dies when manifest is not provided';
	};

	quietly {
		throws_ok { $proxy->delete_env('manifest.yml') }
			qr/missing 'state' option/i,
			'delete_env() dies when state option is missing';
	};
};

subtest 'delete_env() - basic call (scalar context)' => sub {
	plan tests => 2;

	local $ENV{GENESIS_BOSH_COMMAND};
	pushd $ENV{HOME};

	bosh_runs_as('delete-env --state state.json manifest.yml');
	my $proxy = get_create_env_proxy(undef);

	my $ok = $proxy->delete_env('manifest.yml',
		state => 'state.json',
	);
	ok defined($ok),
		'delete_env() in scalar context returns a defined value';
	is $ok, 1,
		'delete_env() in scalar context returns 1 on success';

	popd;
};

subtest 'delete_env() - basic call (list context)' => sub {
	plan tests => 3;

	local $ENV{GENESIS_BOSH_COMMAND};
	pushd $ENV{HOME};

	bosh_runs_as('delete-env --state state.json manifest.yml');
	my $proxy = get_create_env_proxy(undef);

	my ($out, $rc, $third) = $proxy->delete_env('manifest.yml',
		state => 'state.json',
	);
	ok defined($rc),
		'delete_env() in list context: exit code is defined';
	is $rc, 0,
		'delete_env() in list context: exit code is 0 on success';
	is $third, undef,
		'delete_env() in list context: third element is always undef';

	popd;
};

subtest 'delete_env() - dryrun mode (scalar context)' => sub {
	plan tests => 1;

	local $ENV{GENESIS_BOSH_COMMAND};
	fake_bosh('');
	my $proxy = get_create_env_proxy(undef);

	my $ok;
	quietly {
		$ok = $proxy->delete_env('manifest.yml',
			state  => 'state.json',
			dryrun => 1,
		);
	};
	is $ok, 1,
		'delete_env() dryrun scalar context returns 1';
};

subtest 'delete_env() - dryrun mode (list context)' => sub {
	plan tests => 3;

	local $ENV{GENESIS_BOSH_COMMAND};
	fake_bosh('');
	my $proxy = get_create_env_proxy(undef);

	my ($out, $rc, $third);
	quietly {
		($out, $rc, $third) = $proxy->delete_env('manifest.yml',
			state  => 'state.json',
			dryrun => 1,
		);
	};
	is $out, undef,
		'delete_env() dryrun list context: first element is undef';
	is $rc, 0,
		'delete_env() dryrun list context: exit code is 0';
	is $third, undef,
		'delete_env() dryrun list context: third element is undef';
};

subtest 'delete_env() - dryrun does not invoke bosh' => sub {
	plan tests => 1;

	local $ENV{GENESIS_BOSH_COMMAND};

	# Configure bosh to exit 2 on any invocation so we know if it runs
	fake_bosh(<<'SCRIPT');
#!/bin/bash
exit 2
SCRIPT
	my $proxy = get_create_env_proxy(undef);

	my $ok;
	quietly {
		$ok = $proxy->delete_env('manifest.yml',
			state  => 'state.json',
			dryrun => 1,
		);
	};
	is $ok, 1,
		'delete_env() dryrun returns 1 even when bosh would fail -- bosh was not called';
};

subtest 'delete_env() - vars_file option' => sub {
	plan tests => 2;

	local $ENV{GENESIS_BOSH_COMMAND};
	pushd $ENV{HOME};

	mkdir_or_fail('delpath');
	put_file('delpath/vars.yml', "---\n");

	bosh_runs_as('delete-env --state state.json -l delpath/vars.yml manifest.yml');
	my $proxy = get_create_env_proxy(undef);
	my ($out, $rc, undef) = $proxy->delete_env('manifest.yml',
		state     => 'state.json',
		vars_file => 'delpath/vars.yml',
	);
	ok !$rc,
		'delete_env() includes -l <vars_file> when file exists';

	bosh_runs_as('delete-env --state state.json manifest.yml');
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	($out, $rc, undef) = $proxy->delete_env('manifest.yml',
		state     => 'state.json',
		vars_file => 'delpath/missing.yml',
	);
	ok !$rc,
		'delete_env() omits -l when vars_file does not exist on disk';

	popd;
};

subtest 'delete_env() - store option' => sub {
	plan tests => 2;

	local $ENV{GENESIS_BOSH_COMMAND};
	pushd $ENV{HOME};

	mkdir_or_fail('delstore');
	put_file('delstore/creds.yml', "---\n");

	bosh_runs_as('delete-env --state state.json --vars-store delstore/creds.yml manifest.yml');
	my $proxy = get_create_env_proxy(undef);
	my ($out, $rc, undef) = $proxy->delete_env('manifest.yml',
		state => 'state.json',
		store => 'delstore/creds.yml',
	);
	ok !$rc,
		'delete_env() includes --vars-store when store file exists';

	bosh_runs_as('delete-env --state state.json manifest.yml');
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	($out, $rc, undef) = $proxy->delete_env('manifest.yml',
		state => 'state.json',
		store => 'delstore/missing.yml',
	);
	ok !$rc,
		'delete_env() omits --vars-store when store file does not exist';

	popd;
};

subtest 'delete_env() - flags option' => sub {
	plan tests => 1;

	local $ENV{GENESIS_BOSH_COMMAND};
	pushd $ENV{HOME};

	bosh_runs_as('delete-env --force --state state.json manifest.yml');
	my $proxy = get_create_env_proxy(undef);
	my ($out, $rc, undef) = $proxy->delete_env('manifest.yml',
		state => 'state.json',
		flags => ['--force'],
	);
	ok !$rc,
		'delete_env() prepends extra flags before --state and manifest';

	popd;
};

subtest 'delete_env() - failure returns 0 in scalar context' => sub {
	plan tests => 1;

	local $ENV{GENESIS_BOSH_COMMAND};
	pushd $ENV{HOME};

	# Simulate bosh delete-env failing with exit code 1
	fake_bosh(<<'SCRIPT');
#!/bin/bash
exit 1
SCRIPT
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $proxy = get_create_env_proxy(undef);

	my $ok = $proxy->delete_env('manifest.yml',
		state => 'state.json',
	);
	is $ok, 0,
		'delete_env() returns 0 in scalar context when bosh exits non-zero';

	popd;
};

# ===========================================================================
# 8. connect_and_validate()
# ===========================================================================
subtest 'connect_and_validate() - returns self when CLI exists' => sub {
	plan tests => 2;

	local $ENV{GENESIS_BOSH_COMMAND};
	fake_bosh('');

	my $proxy = get_create_env_proxy(undef);
	my $result = $proxy->connect_and_validate();

	ok defined($result),
		'connect_and_validate() returns a defined value';
	is $result, $proxy,
		'connect_and_validate() returns the proxy object itself ($self)';
};

subtest 'connect_and_validate() - does not attempt director connection' => sub {
	plan tests => 1;

	local $ENV{GENESIS_BOSH_COMMAND};

	# Provide a fake bosh that exits non-zero for any env/login commands --
	# connect_and_validate should never call them
	fake_bosh(<<'SCRIPT');
#!/bin/bash
case "$*" in
	env*|log-in*|login*)
		echo "connect_and_validate called a director command -- should not happen" >&2
		exit 99
		;;
	*)
		exit 0
		;;
esac
SCRIPT
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});

	my $proxy = get_create_env_proxy(undef);
	my $result;
	lives_ok { $result = $proxy->connect_and_validate() }
		'connect_and_validate() succeeds without attempting director login';
};

# ===========================================================================
# 9. download_configs()
# ===========================================================================
subtest 'download_configs() - always dies' => sub {
	plan tests => 2;

	local $ENV{GENESIS_BOSH_COMMAND};
	fake_bosh('');

	my $proxy = get_create_env_proxy(undef);

	quietly {
		throws_ok { $proxy->download_configs() }
			qr/create-env environments do not support configuration files/i,
			'download_configs() dies with the expected error message';
	};

	# Also verify it dies even when called with arguments
	quietly {
		throws_ok { $proxy->download_configs('/some/path', 'cloud', 'default') }
			qr/create-env environments do not support configuration files/i,
			'download_configs() dies regardless of arguments';
	};
};

done_testing;
