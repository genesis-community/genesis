#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 't';
use helper;
use Test::More;
use Test::Exception;
use Test::Deep;
use Genesis qw(bail);
use Cwd qw(abs_path);

$ENV{GENESIS_CALLBACK_BIN} ||= abs_path('bin/genesis');
$ENV{GENESIS_LIB} ||= abs_path('lib');
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# ---------------------------------------------------------------------------
# Load the module under test
# ---------------------------------------------------------------------------
require_ok 'Genesis::Hook::Check';

# ---------------------------------------------------------------------------
# Test subclass — Genesis::Hook requires class name
# Genesis::Hook::<Type>::<KitName> so that label() can parse it.
# ---------------------------------------------------------------------------
{
	package Genesis::Hook::Check::test_kit;
	use parent -norequire, 'Genesis::Hook::Check';

	sub perform {
		my ($self) = @_;
		$self->done(0);
	}
}

# ---------------------------------------------------------------------------
# Shared mock objects
# ---------------------------------------------------------------------------

my $test_seq = 0;

my $kit = mock "Genesis::Kit" => {
	name                => 'test-kit',
	version             => '1.0.0',
	genesis_version_min => '3.1.0-rc.10',
	id                  => sub { return $_[0]->name . '/' . $_[0]->version },
	kit_bug => sub {
		my ($self, $msg, @args) = @_;
		bail("Throwing a kit bug: " . $msg, @args);
	},
	path => sub {
		my ($self, $file) = @_;
		return "/mock/kit/path/$file";
	},
	metadata => { supports => ['aws', 'vsphere', 'openstack'] },
	get_hook_module => sub { return undef },
};

my $bosh = mock "Genesis::BOSH" => {
	alias                => 'mock-bosh',
	connect_and_validate => sub { return $_[0] },
};

my $cloud_config_data = {
	vm_types  => [ { name => 'small' }, { name => 'large' } ],
	networks  => [ { name => 'default' } ],
	disk_types => [ { name => 'default' } ],
};

my $runtime_config_data = {
	addons => [
		{
			name => 'addon1',
			jobs  => [ { name => 'bosh-dns' }, { name => 'syslog' } ],
		},
	],
};

my $env_lookup_data = {
	params => {
		base_domain     => 'example.com',
		scale           => 'dev',
		list_param      => [1, 2, 3],
	},
};

sub mock_env {
	$test_seq++;
	my $seq = $test_seq;
	mock "Genesis::Env" => {(
		name           => "test-env-$seq",
		type           => 'test',
		kit            => $kit,
		bosh           => sub { return $bosh },
		use_create_env => 0,
		features       => Mock::ReferencedValue->new(['ha', 'tls']),
		iaas           => 'aws',
		scale          => 'dev',
		is_ocfp        => 0,
		cpi_name       => 'aws_cpi',
		cpi_enabled    => 1,
		deployments    => mock("Genesis::Env::Deployments::$seq" => {
			current_state => 'deployed',
		}),
		workpath => sub {
			my ($self, $path) = @_;
			return "/tmp/genesis-test-work/$path";
		},
		config_contents => sub {
			my ($self, %opts) = @_;
			return $cloud_config_data   if ($opts{type} // '') eq 'cloud';
			return $runtime_config_data if ($opts{type} // '') eq 'runtime';
			return {};
		},
		exodus_lookup => sub {
			my ($self, $key, $default, $for) = @_;
			if ($key eq '.') {
				return { name => 'test-env', director_url => 'https://bosh.example.com' };
			}
			# When $for ends in '/bosh' (env_name/bosh), return data for director_url
			if (defined $for && $for =~ m{/bosh$}) {
				return 'https://bosh.example.com' if $key eq 'director_url';
			}
			return $default;
		},
		lookup => sub {
			my ($self, $key, $default) = @_;
			return $env_lookup_data unless defined $key;
			return $default;
		},
		path => sub { return "/mock/env/path/$_[1]" },
		file => 'test-env.yml',
	), @_};
}

sub make_hook {
	my $env = shift || mock_env();
	return Genesis::Hook::Check::test_kit->init(env => $env, kit => $kit, @_);
}

# ---------------------------------------------------------------------------
# Globals set before all subtests
# ---------------------------------------------------------------------------
$Genesis::VERSION = '3.1.0-rc.10';
$ENV{GENESIS_CALL_BIN}  = 'genesis';
$ENV{GENESIS_KIT_HOOK}  = 'check';

# ---------------------------------------------------------------------------
# Genesis::Hook::Check must be loaded
# ---------------------------------------------------------------------------
subtest 'Genesis::Hook::Check module loads' => sub {
	plan tests => 1;
	ok(defined(&Genesis::Hook::Check::init), 'Genesis::Hook::Check::init is defined');
};

# ---------------------------------------------------------------------------
# init
# ---------------------------------------------------------------------------
subtest 'init - missing env dies' => sub {
	plan tests => 1;

	throws_ok {
		Genesis::Hook::Check::test_kit->init(kit => $kit)
	} qr/Missing required arguments for a perl-based kit hook call: env/,
		'init() without env argument dies with required-args message';
};

subtest 'init - missing kit dies' => sub {
	plan tests => 1;

	my $env = mock_env();
	throws_ok {
		Genesis::Hook::Check::test_kit->init(env => $env)
	} qr/Missing required arguments for a perl-based kit hook call: kit/,
		'init() without kit argument dies with required-args message';
};

subtest 'init - returns blessed object' => sub {
	plan tests => 4;

	my $env  = mock_env();
	my $hook;
	lives_ok {
		$hook = Genesis::Hook::Check::test_kit->init(env => $env, kit => $kit)
	} 'init() succeeds with env and kit';

	ok(defined $hook, 'init() returns a defined value');
	isa_ok($hook, 'Genesis::Hook::Check', 'returned object isa Genesis::Hook::Check');
	isa_ok($hook, 'Genesis::Hook',        'returned object isa Genesis::Hook');
};

subtest 'init - env stored on object' => sub {
	plan tests => 1;

	my $env  = mock_env();
	my $hook = Genesis::Hook::Check::test_kit->init(env => $env, kit => $kit);
	is($hook->env, $env, 'env() returns the env passed to init()');
};

subtest 'init - type set from GENESIS_KIT_HOOK' => sub {
	plan tests => 1;

	my $hook = make_hook();
	is($hook->{type}, 'check', 'type is set to "check" from GENESIS_KIT_HOOK');
};

subtest 'init - complete flag starts at 0' => sub {
	plan tests => 1;

	my $hook = make_hook();
	is($hook->{complete}, 0, 'complete flag initializes to 0');
};

# ---------------------------------------------------------------------------
# start_check
# ---------------------------------------------------------------------------
subtest 'start_check - does not die on cloud-config' => sub {
	plan tests => 1;

	my $hook = make_hook();
	lives_ok {
		quietly { $hook->start_check('cloud-config') }
	} 'start_check("cloud-config") does not die';
};

subtest 'start_check - does not die on runtime-config' => sub {
	plan tests => 1;

	my $hook = make_hook();
	lives_ok {
		quietly { $hook->start_check('runtime-config') }
	} 'start_check("runtime-config") does not die';
};

subtest 'start_check - does not die on environment' => sub {
	plan tests => 1;

	my $hook = make_hook();
	lives_ok {
		quietly { $hook->start_check('environment') }
	} 'start_check("environment") does not die';
};

subtest 'start_check - does not die with underscore type' => sub {
	plan tests => 1;

	my $hook = make_hook();
	lives_ok {
		quietly { $hook->start_check('runtime_config') }
	} 'start_check("runtime_config") does not die';
};

# ---------------------------------------------------------------------------
# check_result — explicit result values
# ---------------------------------------------------------------------------
subtest 'check_result - "passed" returns 1' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $ret;
	quietly { $ret = $hook->check_result('cloud-config', 'passed') };
	is($ret, 1, 'check_result with "passed" returns 1');
};

subtest 'check_result - "ok" normalized to passed returns 1' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $ret;
	quietly { $ret = $hook->check_result('cloud-config', 'ok') };
	is($ret, 1, 'check_result with "ok" returns 1');
};

subtest 'check_result - "1" normalized to passed returns 1' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $ret;
	quietly { $ret = $hook->check_result('cloud-config', '1') };
	is($ret, 1, 'check_result with "1" returns 1');
};

subtest 'check_result - "error" normalized to failed returns 0' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $ret;
	quietly { $ret = $hook->check_result('cloud-config', 'error') };
	is($ret, 0, 'check_result with "error" returns 0');
};

subtest 'check_result - false value returns 0' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $ret;
	quietly { $ret = $hook->check_result('cloud-config', 0) };
	is($ret, 0, 'check_result with 0 returns 0');
};

subtest 'check_result - truthy non-standard string returns 1' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $ret;
	quietly { $ret = $hook->check_result('cloud-config', 'warning') };
	is($ret, 1, 'check_result with "warning" (other truthy) returns 1');
};

subtest 'check_result - explicit message does not die' => sub {
	plan tests => 1;

	my $hook = make_hook();
	lives_ok {
		quietly { $hook->check_result('environment', 0, 'missing required params') }
	} 'check_result with message does not die';
};

# ---------------------------------------------------------------------------
# check_result — derived from accumulated has_entry checks
# ---------------------------------------------------------------------------
subtest 'check_result - undef result: all passing checks yields 1' => sub {
	plan tests => 1;

	my $hook = make_hook();
	quietly {
		$hook->has_entry('cloud-config', 'vm_type', 'small');
		$hook->has_entry('cloud-config', 'network', 'default');
	};
	my $ret;
	quietly { $ret = $hook->check_result('cloud-config') };
	is($ret, 1, 'check_result(undef) returns 1 when all prior has_entry checks passed');
};

subtest 'check_result - undef result: any failing check yields 0' => sub {
	plan tests => 1;

	my $hook = make_hook();
	quietly {
		$hook->has_entry('cloud-config', 'vm_type', 'small');
		$hook->has_entry('cloud-config', 'vm_type', 'nonexistent');
	};
	my $ret;
	quietly { $ret = $hook->check_result('cloud-config') };
	is($ret, 0, 'check_result(undef) returns 0 when any prior has_entry check failed');
};

# ---------------------------------------------------------------------------
# has_entry — dispatch and accumulation
# ---------------------------------------------------------------------------
subtest 'has_entry - unknown config type returns 0' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $ret;
	quietly { $ret = $hook->has_entry('bogus-config', 'vm_type', 'small') };
	is($ret, 0, 'has_entry with unknown config type returns 0');
};

subtest 'has_entry - unknown config type does not accumulate' => sub {
	plan tests => 1;

	my $hook = make_hook();
	quietly { $hook->has_entry('bogus-config', 'vm_type', 'small') };
	ok(!exists $hook->{__entry_checks}{'bogus-config'},
		'unknown config type does not store an entry check result');
};

subtest 'has_entry - cloud-config hit accumulates as true' => sub {
	plan tests => 1;

	my $hook = make_hook();
	quietly { $hook->has_entry('cloud-config', 'vm_type', 'small') };
	is($hook->{__entry_checks}{'cloud-config'}{vm_type}{small}, 1,
		'has_entry stores 1 for matching cloud-config vm_type');
};

subtest 'has_entry - cloud-config miss accumulates as false' => sub {
	plan tests => 1;

	my $hook = make_hook();
	quietly { $hook->has_entry('cloud-config', 'vm_type', 'xlarge') };
	is($hook->{__entry_checks}{'cloud-config'}{vm_type}{xlarge}, 0,
		'has_entry stores 0 for missing cloud-config vm_type');
};

subtest 'has_entry - runtime-config job hit accumulates as true' => sub {
	plan tests => 1;

	my $hook = make_hook();
	quietly { $hook->has_entry('runtime-config', 'job', 'bosh-dns') };
	is($hook->{__entry_checks}{'runtime-config'}{job}{'bosh-dns'}, 1,
		'has_entry stores 1 for matching runtime-config job');
};

subtest 'has_entry - runtime-config job miss accumulates as false' => sub {
	plan tests => 1;

	my $hook = make_hook();
	quietly { $hook->has_entry('runtime-config', 'job', 'nonexistent-job') };
	is($hook->{__entry_checks}{'runtime-config'}{job}{'nonexistent-job'}, 0,
		'has_entry stores 0 for missing runtime-config job');
};

subtest 'has_entry - environment params hit accumulates as true' => sub {
	plan tests => 1;

	my $hook = make_hook();
	quietly { $hook->has_entry('environment', 'params', 'base_domain') };
	is($hook->{__entry_checks}{environment}{params}{base_domain}, 1,
		'has_entry stores 1 for defined environment param');
};

subtest 'has_entry - environment params miss accumulates as false' => sub {
	plan tests => 1;

	my $hook = make_hook();
	quietly { $hook->has_entry('environment', 'params', 'undefined_param') };
	is($hook->{__entry_checks}{environment}{params}{undefined_param}, 0,
		'has_entry stores 0 for missing environment param');
};

# ---------------------------------------------------------------------------
# has_cloud_config_entry
# ---------------------------------------------------------------------------
subtest 'has_cloud_config_entry - vm_type small exists returns 1' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $ret;
	quietly { $ret = $hook->has_cloud_config_entry('vm_type', 'small') };
	is($ret, 1, 'has_cloud_config_entry returns 1 for existing vm_type "small"');
};

subtest 'has_cloud_config_entry - vm_type large exists returns 1' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $ret;
	quietly { $ret = $hook->has_cloud_config_entry('vm_type', 'large') };
	is($ret, 1, 'has_cloud_config_entry returns 1 for existing vm_type "large"');
};

subtest 'has_cloud_config_entry - vm_type xlarge missing returns 0' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $ret;
	quietly { $ret = $hook->has_cloud_config_entry('vm_type', 'xlarge') };
	is($ret, 0, 'has_cloud_config_entry returns 0 for missing vm_type "xlarge"');
};

subtest 'has_cloud_config_entry - network default exists returns 1' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $ret;
	quietly { $ret = $hook->has_cloud_config_entry('network', 'default') };
	is($ret, 1, 'has_cloud_config_entry returns 1 for existing network "default"');
};

subtest 'has_cloud_config_entry - network missing returns 0' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $ret;
	quietly { $ret = $hook->has_cloud_config_entry('network', 'private') };
	is($ret, 0, 'has_cloud_config_entry returns 0 for missing network "private"');
};

subtest 'has_cloud_config_entry - empty type list returns 0' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $ret;
	# 'az' is not in our cloud config mock, so the list is empty/absent
	quietly { $ret = $hook->has_cloud_config_entry('az', 'z1') };
	is($ret, 0, 'has_cloud_config_entry returns 0 when type list is absent');
};

subtest 'has_cloud_config_entry - cloud config is cached after first call' => sub {
	plan tests => 1;

	my $hook = make_hook();
	quietly {
		$hook->has_cloud_config_entry('vm_type', 'small');
		$hook->has_cloud_config_entry('network', 'default');
	};
	ok(exists $hook->{__cloud_config}, 'cloud config is cached in __cloud_config after first call');
};

# ---------------------------------------------------------------------------
# has_runtime_config_entry
# ---------------------------------------------------------------------------
subtest 'has_runtime_config_entry - job bosh-dns exists returns 1' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my ($ret) = $hook->has_runtime_config_entry('job', 'bosh-dns');
	is($ret, 1, 'has_runtime_config_entry returns 1 for job "bosh-dns" in addon');
};

subtest 'has_runtime_config_entry - job syslog exists returns 1' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my ($ret) = $hook->has_runtime_config_entry('job', 'syslog');
	is($ret, 1, 'has_runtime_config_entry returns 1 for job "syslog" in addon');
};

subtest 'has_runtime_config_entry - missing job returns 0' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my ($ret) = $hook->has_runtime_config_entry('job', 'nonexistent-job');
	is($ret, 0, 'has_runtime_config_entry returns 0 for missing job');
};

subtest 'has_runtime_config_entry - non-job type dies' => sub {
	plan tests => 1;

	my $hook = make_hook();
	throws_ok {
		$hook->has_runtime_config_entry('addon', 'some-addon')
	} qr/bug|Unknown check type/i,
		'has_runtime_config_entry with non-job type calls bug() and dies';
};

subtest 'has_runtime_config_entry - runtime config cached after first call' => sub {
	plan tests => 1;

	my $hook = make_hook();
	$hook->has_runtime_config_entry('job', 'bosh-dns');
	ok(exists $hook->{__runtime_config}, 'runtime config cached in __runtime_config after first call');
};

subtest 'has_runtime_config_entry - job list cached after first call' => sub {
	plan tests => 1;

	my $hook = make_hook();
	$hook->has_runtime_config_entry('job', 'bosh-dns');
	ok(exists $hook->{__runtime_config_jobs}, 'job list cached in __runtime_config_jobs after first call');
};

# ---------------------------------------------------------------------------
# has_environment_entry — params: plain existence
# ---------------------------------------------------------------------------
subtest 'has_environment_entry - params defined param returns 1' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my ($ret) = $hook->has_environment_entry('params', 'base_domain');
	is($ret, 1, 'has_environment_entry returns 1 for defined params.base_domain');
};

subtest 'has_environment_entry - params undefined param returns 0' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my ($ret) = $hook->has_environment_entry('params', 'no_such_param');
	is($ret, 0, 'has_environment_entry returns 0 for undefined params.no_such_param');
};

# ---------------------------------------------------------------------------
# has_environment_entry — params: type check
# ---------------------------------------------------------------------------
subtest 'has_environment_entry - params type=string for string value returns 1' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my ($ret) = $hook->has_environment_entry('params', 'base_domain', type => 'string');
	is($ret, 1, 'has_environment_entry returns 1 when param is a string and type=string');
};

subtest 'has_environment_entry - params type=string for array ref also returns 1' => sub {
	plan tests => 1;

	# The implementation computes actualtype as:
	#   lc(ref($param) || defined($param) ? 'string' : 'undefined')
	# Any truthy ref() causes the ternary to yield 'string', so array refs
	# are also treated as type 'string' by the current implementation.
	my $hook = make_hook();
	my ($ret) = $hook->has_environment_entry('params', 'list_param', type => 'string');
	is($ret, 1, 'has_environment_entry returns 1 for array ref with type=string (ref is truthy in ternary)');
};

subtest 'has_environment_entry - params type=undefined for absent param returns 1' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my ($ret) = $hook->has_environment_entry('params', 'no_such_param', type => 'undefined');
	is($ret, 1, 'has_environment_entry returns 1 when param is absent and type=undefined');
};

subtest 'has_environment_entry - params type=undefined for defined param returns 0' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my ($ret) = $hook->has_environment_entry('params', 'base_domain', type => 'undefined');
	is($ret, 0, 'has_environment_entry returns 0 when param is defined and type=undefined');
};

# ---------------------------------------------------------------------------
# has_environment_entry — params: value_in
# ---------------------------------------------------------------------------
subtest 'has_environment_entry - params value_in matches returns 1' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my ($ret) = $hook->has_environment_entry('params', 'scale',
		value_in => [qw(dev staging prod)]);
	is($ret, 1, 'has_environment_entry returns 1 when param value is in allowed list');
};

subtest 'has_environment_entry - params value_in no match returns 0' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my ($ret) = $hook->has_environment_entry('params', 'scale',
		value_in => [qw(staging prod)]);
	is($ret, 0, 'has_environment_entry returns 0 when param value is not in allowed list');
};

subtest 'has_environment_entry - params value_in undefined param returns 0' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my ($ret) = $hook->has_environment_entry('params', 'no_such_param',
		value_in => [qw(a b c)]);
	is($ret, 0, 'has_environment_entry returns 0 when param is undefined and value_in used');
};

# ---------------------------------------------------------------------------
# has_environment_entry — params: retired
# ---------------------------------------------------------------------------
subtest 'has_environment_entry - params retired and absent returns 1' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my ($ret) = $hook->has_environment_entry('params', 'no_such_param', retired => 1);
	is($ret, 1, 'has_environment_entry returns 1 for retired param that is absent');
};

subtest 'has_environment_entry - params retired but still defined returns 0' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my ($ret) = $hook->has_environment_entry('params', 'base_domain', retired => 1);
	is($ret, 0, 'has_environment_entry returns 0 for retired param that is still defined');
};

# ---------------------------------------------------------------------------
# has_environment_entry — exodus type
# ---------------------------------------------------------------------------
subtest 'has_environment_entry - exodus name key present returns 1' => sub {
	plan tests => 1;

	my $hook = make_hook();
	# Without env/deployment opts, checks $self->exodus_data->{name}
	my ($ret) = $hook->has_environment_entry('exodus', 'name');
	is($ret, 1, 'has_environment_entry returns 1 when exodus_data has "name" key');
};

subtest 'has_environment_entry - exodus with deployment returns 1 for known key' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my ($ret) = $hook->has_environment_entry('exodus', 'director_url',
		deployment => 'bosh');
	is($ret, 1, 'has_environment_entry returns 1 for known exodus key with deployment');
};

subtest 'has_environment_entry - exodus with deployment returns 0 for unknown key' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my ($ret) = $hook->has_environment_entry('exodus', 'no_such_key',
		deployment => 'bosh');
	is($ret, 0, 'has_environment_entry returns 0 for missing exodus key with deployment');
};

# ---------------------------------------------------------------------------
# has_environment_entry — unknown type dies
# ---------------------------------------------------------------------------
subtest 'has_environment_entry - unknown type dies' => sub {
	plan tests => 1;

	my $hook = make_hook();
	throws_ok {
		$hook->has_environment_entry('unknown_type', 'some_name')
	} qr/bug|Unknown check type/i,
		'has_environment_entry with unknown type calls bug() and dies';
};

# ---------------------------------------------------------------------------
# environment manifest is cached
# ---------------------------------------------------------------------------
subtest 'has_environment_entry - environment manifest cached after first call' => sub {
	plan tests => 1;

	my $hook = make_hook();
	$hook->has_environment_entry('params', 'base_domain');
	ok(exists $hook->{__environment}, 'environment manifest cached in __environment');
};

# ---------------------------------------------------------------------------
# Full check workflow integration
# ---------------------------------------------------------------------------
subtest 'full check workflow - cloud-config all pass' => sub {
	plan tests => 3;

	my $hook = make_hook();
	quietly { $hook->start_check('cloud-config') };
	quietly { $hook->has_entry('cloud-config', 'vm_type', 'small') };
	quietly { $hook->has_entry('cloud-config', 'network', 'default') };
	my $ret;
	quietly { $ret = $hook->check_result('cloud-config') };
	is($ret, 1, 'full cloud-config check with all passing entries returns 1');
	is($hook->{__entry_checks}{'cloud-config'}{vm_type}{small},  1, 'vm_type small recorded as pass');
	is($hook->{__entry_checks}{'cloud-config'}{network}{default}, 1, 'network default recorded as pass');
};

subtest 'full check workflow - cloud-config with failure' => sub {
	plan tests => 1;

	my $hook = make_hook();
	quietly { $hook->start_check('cloud-config') };
	quietly { $hook->has_entry('cloud-config', 'vm_type', 'small') };
	quietly { $hook->has_entry('cloud-config', 'vm_type', 'missing') };
	my $ret;
	quietly { $ret = $hook->check_result('cloud-config') };
	is($ret, 0, 'full cloud-config check with one failing entry returns 0');
};

subtest 'full check workflow - runtime-config job check' => sub {
	plan tests => 1;

	my $hook = make_hook();
	quietly { $hook->start_check('runtime-config') };
	quietly { $hook->has_entry('runtime-config', 'job', 'bosh-dns') };
	my $ret;
	quietly { $ret = $hook->check_result('runtime-config') };
	is($ret, 1, 'full runtime-config check with existing job returns 1');
};

subtest 'full check workflow - environment params check' => sub {
	plan tests => 1;

	my $hook = make_hook();
	quietly { $hook->start_check('environment') };
	quietly { $hook->has_entry('environment', 'params', 'base_domain') };
	my $ret;
	quietly { $ret = $hook->check_result('environment') };
	is($ret, 1, 'full environment check with defined param returns 1');
};

subtest 'full check workflow - independent check results per config' => sub {
	plan tests => 2;

	my $hook = make_hook();
	quietly {
		$hook->start_check('cloud-config');
		$hook->has_entry('cloud-config', 'vm_type', 'small');

		$hook->start_check('environment');
		$hook->has_entry('environment', 'params', 'no_such_param');
	};

	my ($cloud_ret, $env_ret);
	quietly {
		$cloud_ret = $hook->check_result('cloud-config');
		$env_ret   = $hook->check_result('environment');
	};
	is($cloud_ret, 1, 'cloud-config check result is 1 (independent of env check)');
	is($env_ret,   0, 'environment check result is 0 (independent of cloud-config check)');
};

done_testing;
