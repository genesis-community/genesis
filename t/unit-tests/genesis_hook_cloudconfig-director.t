#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use helper;
use Test::More;
use Test::Exception;
use Test::Deep;
use Test::Differences;
use Carp qw/croak/;
use Genesis qw(logger struct_lookup bail);
use Cwd qw(abs_path);
use JSON::PP;

$ENV{GENESIS_CALLBACK_BIN} ||= abs_path('bin/genesis');
$ENV{GENESIS_LIB} ||= abs_path('lib');
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $ocfp_config = {
	vpc => {
		azs => {
			'az1' => { cloud_properties => '{"zone": "us-east-1a"}' },
			'az2' => { cloud_properties => '{"zone": "us-east-1b"}' },
			'az3' => { cloud_properties => '{"zone": "us-east-1c"}' }
		},
		cidr_block => '192.168.0.0/20',
		dns => '1.1.1.1',
		id => 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxx01',
		region => 'us-east-1',
		sgs => {
			default => {
				'description' => 'Default security group',
				'id' => 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxx02',
				'name' => 'default'
			}
		},
		subnets => {
			'ocfp-0' => {
				az => 'az1', cidr_block => '10.0.0.0/24',
				gateway => '10.0.0.1', dns => '10.0.0.2',
				'reserved-ips' => { 'available_a' => '10.0.0.37', 'available_b' => '10.0.0.250', 'bosh_ip' => '10.0.0.5' }
			},
			'ocfp-1' => {
				az => 'az2', cidr_block => '10.0.1.0/24',
				gateway => '10.0.1.1', dns => '10.0.1.2',
				'reserved-ips' => { 'available_a' => '10.0.1.16', 'available_b' => '10.0.1.250', 'reserved_a' => '10.0.1.0', 'reserved_b' => '10.0.1.36' }
			},
			'ocfp-2' => {
				az => 'az3', cidr_block => '10.0.2.0/24',
				gateway => '10.0.2.1', dns => '10.0.2.2',
				'reserved-ips' => { 'reserved_a' => '10.0.2.0', 'reserved_b' => '10.0.2.36', 'reserved_c' => '10.0.2.255', 'reserved_d' => '10.0.2.255', 'bosh_ip' => '10.0.2.6' }
			}
		}
	}
};

my $kit = mock "Genesis::Kit" => {
	name                => 'test-kit',
	version             => '1.0.0',
	genesis_version_min => '3.1.0-rc.10',
	id                  => sub { return $_[0]->name . '/' . $_[0]->version },
	kit_bug => sub {
		my ($self, $msg, @args) = @_;
		bail("Throwing a kit bug: ".$msg, @args);
	},
};

my $bosh = mock "Genesis::BOSH" => { alias => 'mock-bosh' };

my $test_seq = 0;
sub mock_env {
	$test_seq++;
	mock "Genesis::Env" => {(
		name           => "test-env-dir-$test_seq",
		type           => 'bosh',
		kit            => $kit,
		bosh           => $bosh,
		use_create_env => 1,   # Director env uses create-env
		features       => Mock::ReferencedValue->new(['ocfp', 'some-feature']),
		iaas           => 'openstack',
		scale          => 'dev',
		env_config_overrides      => {},
		director_config_overrides => {},
		ocfp_subnet_prefix => 'ocfp',
		ocfp_config        => $ocfp_config,
		ocfp_type          => 'mgmt',
		is_ocfp => sub { return $_[0]->features && grep { $_ eq 'ocfp' } ($_[0]->features); },
		lookup => sub { my ($self, $key, $default) = @_; return struct_lookup($self->config, $key, $default); },
		cpi_enabled => 0,
		cpi_name => undef,
		exodus_lookup => sub { return undef },
		director_exodus_lookup => sub { die 'Create-env environments do not have directors' },
		ocfp_config_lookup => sub { my ($self, $key) = @_; return struct_lookup($self->ocfp_config, $key); },
		config => { params => { cloud_config_prefix => 'test-env.test' } },
	), @_};
}

$Genesis::VERSION = '3.1.0-rc.10';
$ENV{GENESIS_CALL_BIN} = 'genesis';
$ENV{"GENESIS_KIT_HOOK"} = "cloud-config";

# ---------------------------------------------------------------------------
# initialization
# ---------------------------------------------------------------------------
subtest 'initialization' => sub {
	plan tests => 9;

	require_ok "hooks/cloud-config-bosh-director.pm";

	my $env = mock_env();
	local $ENV{GENESIS_ENVIRONMENT} = "test-env-dir-$test_seq";

	throws_ok {
		Genesis::Hook::CloudConfig::Bosh::Director->init(env => $env)
	} qr/Purpose must be 'director' - no purpose provided/m,
		'init() dies when purpose is omitted';

	throws_ok {
		Genesis::Hook::CloudConfig::Bosh::Director->init(env => $env, purpose => 'interloper')
	} qr/Purpose must be 'director' - got 'interloper'/m,
		'init() dies when wrong purpose is provided';

	my $hook;
	lives_ok {
		$hook = Genesis::Hook::CloudConfig::Bosh::Director->init(env => $env, purpose => 'director')
	} 'init() succeeds with purpose => director';

	isa_ok($hook, 'Genesis::Hook::CloudConfig::Bosh::Director',
		'returned object isa Genesis::Hook::CloudConfig::Bosh::Director');
	isa_ok($hook, 'Genesis::Hook::CloudConfig',
		'returned object isa Genesis::Hook::CloudConfig');
	isa_ok($hook, 'Genesis::Hook',
		'returned object isa Genesis::Hook');

	is($hook->{purpose}, 'director',
		'purpose is stored as "director"');
	is($hook->{basename}, "test-env-dir-$test_seq.bosh",
		'basename is env_name.env_type');
};

# ---------------------------------------------------------------------------
# id
# ---------------------------------------------------------------------------
subtest 'id includes purpose' => sub {
	plan tests => 1;

	my $env = mock_env();
	local $ENV{GENESIS_ENVIRONMENT} = "test-env-dir-$test_seq";
	my $hook = Genesis::Hook::CloudConfig::Bosh::Director->init(
		env => $env, purpose => 'director'
	);

	is($hook->{id}, "test-env-dir-$test_seq.bosh\@director",
		'id is basename@director');
};

# ---------------------------------------------------------------------------
# overrides_base
# ---------------------------------------------------------------------------
subtest 'overrides_base' => sub {
	plan tests => 1;

	my $env = mock_env();
	local $ENV{GENESIS_ENVIRONMENT} = "test-env-dir-$test_seq";
	my $hook = Genesis::Hook::CloudConfig::Bosh::Director->init(
		env => $env, purpose => 'director'
	);

	is($hook->overrides_base, 'bosh-configs.director_cloud',
		'overrides_base() returns "bosh-configs.director_cloud"');
};

# ---------------------------------------------------------------------------
# _can_build_cloud_config
# ---------------------------------------------------------------------------
subtest '_can_build_cloud_config' => sub {
	plan tests => 2;

	# create-env env should work for director (unlike the parent class)
	my $create_env = mock_env(use_create_env => 1);
	local $ENV{GENESIS_ENVIRONMENT} = "test-env-dir-$test_seq";
	my $hook;
	lives_ok {
		$hook = Genesis::Hook::CloudConfig::Bosh::Director->init(
			env => $create_env, purpose => 'director'
		);
	} '_can_build_cloud_config returns true even for create-env environments';

	ok($hook, 'hook was created successfully for create-env environment');
};

# ---------------------------------------------------------------------------
# build_az_definitions
# ---------------------------------------------------------------------------
subtest 'build_az_definitions' => sub {
	plan tests => 4;

	my $env = mock_env();
	local $ENV{GENESIS_ENVIRONMENT} = "test-env-dir-$test_seq";
	my $hook = Genesis::Hook::CloudConfig::Bosh::Director->init(
		env => $env, purpose => 'director'
	);
	my $env_name = "test-env-dir-$test_seq";

	my @azs = $hook->build_az_definitions();

	is(scalar(@azs), 3, 'build_az_definitions returns 3 AZ definitions');

	# Sorted by name, so az1 < az2 < az3
	is($azs[0]{name}, "${env_name}-z1", 'first AZ name uses az_prefix + index');
	is($azs[1]{name}, "${env_name}-z2", 'second AZ name uses az_prefix + index');
	is($azs[2]{name}, "${env_name}-z3", 'third AZ name uses az_prefix + index');
};

subtest 'build_az_definitions - sorted by name' => sub {
	plan tests => 1;

	my $env = mock_env();
	local $ENV{GENESIS_ENVIRONMENT} = "test-env-dir-$test_seq";
	my $hook = Genesis::Hook::CloudConfig::Bosh::Director->init(
		env => $env, purpose => 'director'
	);
	my $env_name = "test-env-dir-$test_seq";

	my @azs = $hook->build_az_definitions();
	cmp_deeply(\@azs, [
		{ cloud_properties => {"zone" => "us-east-1a"}, name => "${env_name}-z1" },
		{ cloud_properties => {"zone" => "us-east-1b"}, name => "${env_name}-z2" },
		{ cloud_properties => {"zone" => "us-east-1c"}, name => "${env_name}-z3" },
	], 'AZ definitions are sorted by name and have correct cloud_properties');
};

subtest 'build_az_definitions - cloud_properties are decoded from JSON' => sub {
	plan tests => 3;

	my $env = mock_env();
	local $ENV{GENESIS_ENVIRONMENT} = "test-env-dir-$test_seq";
	my $hook = Genesis::Hook::CloudConfig::Bosh::Director->init(
		env => $env, purpose => 'director'
	);

	my @azs = $hook->build_az_definitions();

	is(ref($azs[0]{cloud_properties}), 'HASH',
		'cloud_properties is decoded from JSON string to hashref');
	is($azs[0]{cloud_properties}{zone}, 'us-east-1a',
		'first AZ cloud_properties zone is correct');
	is($azs[1]{cloud_properties}{zone}, 'us-east-1b',
		'second AZ cloud_properties zone is correct');
};

# ---------------------------------------------------------------------------
# network data population via init
# ---------------------------------------------------------------------------
subtest 'network data population - azs after init' => sub {
	plan tests => 6;

	my $env = mock_env();
	local $ENV{GENESIS_ENVIRONMENT} = "test-env-dir-$test_seq";
	my $hook = Genesis::Hook::CloudConfig::Bosh::Director->init(
		env => $env, purpose => 'director'
	);
	my $env_name = "test-env-dir-$test_seq";

	ok(defined $hook->{network}, 'network data is set after init');
	ok(defined $hook->{network}{azs}, 'network azs are set after init');

	is(scalar(keys %{$hook->{network}{azs}}), 3,
		'network azs has 3 entries');

	ok(exists $hook->{network}{azs}{az1}, 'az1 is present in network azs');
	is($hook->{network}{azs}{az1}{name}, "${env_name}-z1",
		'az1 name uses the az_prefix derived from env name');
	is($hook->{network}{azs}{az2}{name}, "${env_name}-z2",
		'az2 name uses the az_prefix derived from env name');
};

subtest 'network data population - subnets after init' => sub {
	plan tests => 8;

	my $env = mock_env();
	local $ENV{GENESIS_ENVIRONMENT} = "test-env-dir-$test_seq";
	my $hook = Genesis::Hook::CloudConfig::Bosh::Director->init(
		env => $env, purpose => 'director'
	);
	my $env_name = "test-env-dir-$test_seq";

	ok(defined $hook->{network}{subnets}, 'network subnets are set after init');
	is(scalar(keys %{$hook->{network}{subnets}}), 3,
		'network subnets has 3 ocfp-prefixed entries');

	ok(exists $hook->{network}{subnets}{'ocfp-0'}, 'ocfp-0 subnet is present');
	ok(exists $hook->{network}{subnets}{'ocfp-1'}, 'ocfp-1 subnet is present');
	ok(exists $hook->{network}{subnets}{'ocfp-2'}, 'ocfp-2 subnet is present');

	is($hook->{network}{subnets}{'ocfp-0'}{az}, "${env_name}-z1",
		'ocfp-0 subnet az is mapped to the az_prefix name');
	is($hook->{network}{subnets}{'ocfp-1'}{az}, "${env_name}-z2",
		'ocfp-1 subnet az is mapped to the az_prefix name');

	is($hook->{network}{subnets}{'ocfp-0'}{range}, '10.0.0.0-10.0.0.255',
		'ocfp-0 subnet range is derived from cidr_block');
};

subtest 'network data population - subnets have empty claims initially' => sub {
	plan tests => 3;

	my $env = mock_env();
	local $ENV{GENESIS_ENVIRONMENT} = "test-env-dir-$test_seq";
	my $hook = Genesis::Hook::CloudConfig::Bosh::Director->init(
		env => $env, purpose => 'director'
	);

	# claims key does not exist initially (only set when claims come in from exodus)
	ok(!exists $hook->{network}{subnets}{'ocfp-0'}{claims} ||
	   ref($hook->{network}{subnets}{'ocfp-0'}{claims}) eq 'HASH',
		'ocfp-0 subnet claims is absent or empty hash initially');
	ok(!exists $hook->{network}{subnets}{'ocfp-1'}{claims} ||
	   ref($hook->{network}{subnets}{'ocfp-1'}{claims}) eq 'HASH',
		'ocfp-1 subnet claims is absent or empty hash initially');
	ok(!exists $hook->{network}{subnets}{'ocfp-2'}{claims} ||
	   ref($hook->{network}{subnets}{'ocfp-2'}{claims}) eq 'HASH',
		'ocfp-2 subnet claims is absent or empty hash initially');
};

# ---------------------------------------------------------------------------
# compilation_definition
# ---------------------------------------------------------------------------
subtest 'compilation_definition - unsupported strategy error' => sub {
	plan tests => 2;

	my $env = mock_env();
	local $ENV{GENESIS_ENVIRONMENT} = "test-env-dir-$test_seq";
	my $hook = Genesis::Hook::CloudConfig::Bosh::Director->init(
		env => $env, purpose => 'director'
	);

	# Build the compilation network so the hook has one to work with
	$hook->network_definition('compilation',
		strategy => 'ocfp',
		dynamic_subnets => {
			subnets => ['ocfp-1'],
			allocation => { size => 4, statics => 0 },
			cloud_properties_for_iaas => {
				openstack => {
					'net_id' => $hook->network_reference('id'),
					'security_groups' => ['default']
				},
			},
		}
	);

	throws_ok {
		$hook->compilation_definition(strategy => 'generic')
	} qr/Unsupported strategy for building compilation definitions: generic/m,
		'compilation_definition() dies for unsupported strategy "generic"';

	throws_ok {
		$hook->compilation_definition(strategy => 'other')
	} qr/Unsupported strategy for building compilation definitions: other/m,
		'compilation_definition() dies for unsupported strategy "other"';
};

subtest 'compilation_definition - correct output with ocfp strategy' => sub {
	plan tests => 3;

	my $env = mock_env();
	local $ENV{GENESIS_ENVIRONMENT} = "test-env-dir-$test_seq";
	my $hook = Genesis::Hook::CloudConfig::Bosh::Director->init(
		env => $env, purpose => 'director'
	);
	my $env_name = "test-env-dir-$test_seq";

	# Build required compilation network and vm_type before calling compilation_definition
	$hook->network_definition('compilation',
		strategy => 'ocfp',
		dynamic_subnets => {
			subnets => ['ocfp-1'],
			allocation => { size => 4, statics => 0 },
			cloud_properties_for_iaas => {
				openstack => {
					'net_id' => $hook->network_reference('id'),
					'security_groups' => ['default']
				},
			},
		}
	);
	$hook->vm_type_definition('compilation',
		cloud_properties_for_iaas => {
			openstack => {
				'instance_type' => 'm1.2',
				'boot_from_volume' => $hook->TRUE,
				'root_disk' => { 'size' => 30 },
			},
		},
	);

	my %compilation = $hook->compilation_definition(strategy => 'ocfp');

	cmp_deeply(\%compilation, {
		network           => "${env_name}.bosh.net-compilation",
		vm_type           => "${env_name}.bosh.vm-compilation",
		az                => "${env_name}-z2",
		workers           => 4,
		reuse_compilation_vms => JSON::PP::true,
	}, 'compilation_definition returns correct hash with ocfp strategy');

	is($compilation{network}, "${env_name}.bosh.net-compilation",
		'compilation network name is correct');

	is($compilation{az}, "${env_name}-z2",
		'compilation az is the first az in the compilation network (ocfp-1 is az2)');
};

subtest 'compilation_definition - azs remain unaltered' => sub {
	plan tests => 1;

	my $env = mock_env();
	local $ENV{GENESIS_ENVIRONMENT} = "test-env-dir-$test_seq";
	my $hook = Genesis::Hook::CloudConfig::Bosh::Director->init(
		env => $env, purpose => 'director'
	);

	$hook->network_definition('compilation',
		strategy => 'ocfp',
		dynamic_subnets => {
			subnets => ['ocfp-1'],
			allocation => { size => 4, statics => 0 },
			cloud_properties_for_iaas => {
				openstack => {
					'net_id' => $hook->network_reference('id'),
					'security_groups' => ['default']
				},
			},
		}
	);

	$hook->compilation_definition(strategy => 'ocfp');

	cmp_deeply(
		[sort keys %{$hook->network->{azs}}],
		['az1', 'az2', 'az3'],
		'available AZs are unchanged after compilation_definition'
	);
};

# ---------------------------------------------------------------------------
# full cloud config generation (perform)
# ---------------------------------------------------------------------------
subtest 'full cloud config generation' => sub {
	plan tests => 5;

	my $env = mock_env();
	local $ENV{GENESIS_ENVIRONMENT} = "test-env-dir-$test_seq";
	my $hook = Genesis::Hook::CloudConfig::Bosh::Director->init(
		env => $env, purpose => 'director'
	);
	my $env_name = "test-env-dir-$test_seq";

	$env->_mock_set_responses(workdir => {value => workdir});

	ok($hook->perform, 'perform() returns true');
	ok($hook->completed, 'hook is marked completed after perform()');

	my $results = $hook->results;
	is(ref($results), 'HASH', 'results() returns a HASH ref');

	ok(exists $results->{config}, 'results has "config" key');
	ok(exists $results->{network}, 'results has "network" key');
};

subtest 'full cloud config - YAML structure' => sub {
	plan tests => 1;

	my $env = mock_env();
	local $ENV{GENESIS_ENVIRONMENT} = "test-env-dir-$test_seq";
	my $hook = Genesis::Hook::CloudConfig::Bosh::Director->init(
		env => $env, purpose => 'director'
	);
	my $env_name = "test-env-dir-$test_seq";

	$env->_mock_set_responses(workdir => {value => workdir});
	$hook->perform;

	my $results = $hook->results;
	eq_or_diff($results->{config}, <<"EOF", 'generated YAML cloud config is correct');
azs:
- name: ${env_name}-z1
- name: ${env_name}-z2
- name: ${env_name}-z3

compilation:
  az: ${env_name}-z2
  network: ${env_name}.bosh.net-compilation
  reuse_compilation_vms: true
  vm_type: ${env_name}.bosh.vm-compilation
  workers: 4

networks:
- name: ${env_name}.bosh.net-compilation
  subnets:
  - az: ${env_name}-z2
    dns:
    - 10.0.1.2
    gateway: 10.0.1.1
    range: 10.0.1.0/24
    reserved:
    - 10.0.1.0-10.0.1.36
    - 10.0.1.41-10.0.1.255
    cloud_properties:
      net_id: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxx01
      security_groups:
      - default
  type: manual

vm_types:
- name: ${env_name}.bosh.vm-compilation
  cloud_properties:
    boot_from_volume: true
    instance_type: m1.2
    root_disk:
      size: 30
EOF
};

subtest 'full cloud config - network results structure' => sub {
	plan tests => 1;

	my $env = mock_env();
	local $ENV{GENESIS_ENVIRONMENT} = "test-env-dir-$test_seq";
	my $hook = Genesis::Hook::CloudConfig::Bosh::Director->init(
		env => $env, purpose => 'director'
	);
	my $env_name = "test-env-dir-$test_seq";

	$env->_mock_set_responses(workdir => {value => workdir});
	$hook->perform;

	my $results = $hook->results;
	cmp_deeply($results->{network}, {
		'azs' => {
			'az1' => {
				'cloud_properties' => '{"zone": "us-east-1a"}',
				'index' => '1',
				'name' => "${env_name}-z1"
			},
			'az2' => {
				'cloud_properties' => '{"zone": "us-east-1b"}',
				'index' => '2',
				'name' => "${env_name}-z2"
			},
			'az3' => {
				'cloud_properties' => '{"zone": "us-east-1c"}',
				'index' => '3',
				'name' => "${env_name}-z3"
			}
		},
		'subnets' => {
			'ocfp-0' => {
				'az' => "${env_name}-z1",
				'claims' => {},
				'range' => '10.0.0.0-10.0.0.255'
			},
			'ocfp-1' => {
				'az' => "${env_name}-z2",
				'claims' => {
					"${env_name}.bosh.net-compilation" => '10.0.1.37-10.0.1.40'
				},
				'range' => '10.0.1.0-10.0.1.255'
			},
			'ocfp-2' => {
				'az' => "${env_name}-z3",
				'claims' => {},
				'range' => '10.0.2.0-10.0.2.255'
			}
		}
	}, 'network results structure matches expected exodus data');
};

done_testing;

# vim: fdm=marker:foldlevel=1:ts=2:sts=2:sw=2:noet
