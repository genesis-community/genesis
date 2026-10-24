#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use helper;
use Test::More;
use Test::Exception;
use Test::Deep;
use Test::Differences;
use Test::Output;
use Carp qw/croak/;
use Genesis qw(logger struct_lookup bail);
use Cwd qw(abs_path);
use JSON::PP;
use Storable qw(dclone);

$ENV{GENESIS_CALLBACK_BIN} ||= abs_path('bin/genesis');
$ENV{GENESIS_LIB} ||= abs_path('lib');
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# ---------------------------------------------------------------------------
# Shared mock OCFP config data
# ---------------------------------------------------------------------------
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
				'reserved-ips' => {
					'available_a' => '10.0.0.37',
					'available_b' => '10.0.0.250',
					'bosh_ip'     => '10.0.0.5',
				}
			},
			'ocfp-1' => {
				az => 'az2', cidr_block => '10.0.1.0/24',
				gateway => '10.0.1.1', dns => '10.0.1.2',
				'reserved-ips' => {
					'available_a' => '10.0.1.16',
					'available_b' => '10.0.1.250',
					'reserved_a'  => '10.0.1.0',
					'reserved_b'  => '10.0.1.36',
				}
			},
			'ocfp-2' => {
				az => 'az3', cidr_block => '10.0.2.0/24',
				gateway => '10.0.2.1', dns => '10.0.2.2',
				'reserved-ips' => {
					'reserved_a' => '10.0.2.0',
					'reserved_b' => '10.0.2.36',
					'reserved_c' => '10.0.2.255',
					'reserved_d' => '10.0.2.255',
					'bosh_ip'    => '10.0.2.6',
				}
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

# ---------------------------------------------------------------------------
# Genesis version and env vars (set once before all subtests)
# ---------------------------------------------------------------------------
$Genesis::VERSION = '3.1.0-rc.10';
$ENV{GENESIS_CALL_BIN}  = 'genesis';
$ENV{GENESIS_KIT_HOOK}  = 'cloud-config';

# ---------------------------------------------------------------------------
# Load hook implementations
# ---------------------------------------------------------------------------
subtest 'require hook implementations' => sub {
	plan tests => 2;
	require_ok 'hooks/cloud-config-bosh-director.pm';
	require_ok 'hooks/cloud-config-bosh.pm';
};

# ---------------------------------------------------------------------------
# Build director network exodus once for all deployment hook subtests.
# The director hook allocates 4 IPs on ocfp-1 for the compilation network.
# ---------------------------------------------------------------------------
my $director_network_exodus;

subtest 'director hook - build network exodus for deployment tests' => sub {
	plan tests => 5;

	my $mgmt_env = mock "Genesis::Env" => {
		name           => 'test-env-mgmt',
		type           => 'bosh',
		kit            => $kit,
		bosh           => $bosh,
		use_create_env => 1,
		features       => Mock::ReferencedValue->new(['ocfp']),
		iaas           => 'openstack',
		scale          => 'dev',

		env_config_overrides      => {},
		director_config_overrides => {},

		ocfp_subnet_prefix => 'ocfp',
		ocfp_config        => $ocfp_config,

		is_ocfp => sub {
			return $_[0]->features && grep { $_ eq 'ocfp' } ($_[0]->features);
		},
		lookup => sub {
			my ($self, $key, $default) = @_;
			return struct_lookup($self->config, $key, $default);
		},
		director_exodus_lookup => sub {
			die 'Create-env environments do not have directors';
		},
		# Director hook calls exodus_lookup_strict('/network:.') to preserve existing
		# claims; returning undef indicates a fresh first-time deploy.
		exodus_lookup_strict => sub { return undef },
		# With no record of claims the director hook asks the director whether
		# it has deployments; this one has none, so it is a first build.
		exodus_base => 'secret/exodus/test-env-mgmt/bosh',
		get_target_bosh => sub { return mock "Genesis::BOSH" => {alias => 'mock-bosh', deployments => {}} },
		cpi_enabled => 0,
		cpi_name => undef,
		ocfp_config_lookup => sub {
			my ($self, $key) = @_;
			return struct_lookup($self->ocfp_config, $key);
		},
		config => { params => { cloud_config_prefix => 'test-env-mgmt.bosh' } },
	};

	local $ENV{GENESIS_ENVIRONMENT} = 'test-env-mgmt';

	my $dir_hook = Genesis::Hook::CloudConfig::Bosh::Director->init(
		env     => $mgmt_env,
		purpose => 'director',
	);

	isa_ok($dir_hook, 'Genesis::Hook::CloudConfig::Bosh::Director',
		'director hook initialised');

	# Define compilation network on ocfp-1 with 4-IP allocation
	my $comp_net = $dir_hook->network_definition('compilation',
		strategy => 'ocfp',
		dynamic_subnets => {
			subnets    => ['ocfp-1'],
			allocation => { size => 4, statics => 0 },
			cloud_properties_for_iaas => {
				openstack => {
					'net_id'          => $dir_hook->network_reference('id'),
					'security_groups' => ['default'],
				},
			},
		},
	);

	ok($comp_net, 'director compilation network definition generated');
	is($comp_net->{name}, 'test-env-mgmt.bosh.net-compilation',
		'director compilation network has correct name');

	$mgmt_env->_mock_set_responses(workdir => {value => workdir});
	ok($dir_hook->perform, 'director hook perform succeeds');

	$director_network_exodus = $dir_hook->results->{network};

	# Verify the exodus shows the correct allocation on ocfp-1
	is(
		$director_network_exodus->{subnets}{'ocfp-1'}{claims}{'test-env-mgmt.bosh.net-compilation'},
		'10.0.1.37-10.0.1.40',
		'director exodus records compilation claim 10.0.1.37-10.0.1.40 on ocfp-1',
	);
};

# ---------------------------------------------------------------------------
# Helper: create a fresh deployment-hook env that uses the director exodus.
# Each call uses a unique name to avoid the CloudConfig object cache.
# ---------------------------------------------------------------------------
my $env_seq = 0;
sub make_deploy_env {
	$env_seq++;
	my $seq = $env_seq;
	mock "Genesis::Env" => {(
		name           => "test-env-ocf-$seq",
		type           => 'bosh',
		kit            => $kit,
		bosh           => $bosh,
		use_create_env => 0,
		features       => Mock::ReferencedValue->new(['ocfp', 'some-feature']),
		iaas           => 'openstack',
		scale          => 'dev',

		env_config_overrides      => {},
		director_config_overrides => {},

		ocfp_subnet_prefix => 'ocfp',
		ocfp_config        => $ocfp_config,

		is_ocfp => sub {
			return $_[0]->features && grep { $_ eq 'ocfp' } ($_[0]->features);
		},
		lookup => sub {
			my ($self, $key, $default) = @_;
			return struct_lookup($self->config, $key, $default);
		},
		director_exodus_lookup => sub {
			my ($self, $key) = @_;
			# Deep-copy so each hook instance gets its own isolated copy of the
			# director network data; prevents test-state leakage across subtests.
			return dclone($director_network_exodus) if $key eq '/network';
			die "Unknown exodus key: $key";
		},
		ocfp_config_lookup => sub {
			my ($self, $key) = @_;
			return struct_lookup($self->ocfp_config, $key);
		},
		cpi_enabled => 0,
		cpi_name    => undef,
		config => { params => { cloud_config_prefix => 'test-env.test' } },
	), @_};
}

# expect_bosh_drop - run a network_definition('bosh', ...) call, capture the
# expected "Dropping subnet ocfp-1" warning off STDERR (fixture has no
# bosh_* reservations on ocfp-1 so the drop always fires), assert it
# appeared, and return whatever the block returned.  Counts as one test.
sub expect_bosh_drop (&) {
	my $code = shift;
	my ($result, $warn);
	$warn = stderr_from { $result = $code->() };
	like $warn, qr/Dropping subnet ocfp-1.*bosh/i,
		'expected drop warning emitted for ocfp-1';
	return $result;
}

# ---------------------------------------------------------------------------
# AZ Management
# ---------------------------------------------------------------------------
subtest 'get_available_azs - returns full AZ hash from director network data' => sub {
	plan tests => 2;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);
	my $azs  = $hook->get_available_azs;

	is(ref($azs), 'HASH', 'get_available_azs() returns a hashref');
	# The director hook stores index, name (env-name + '-z' + index), and
	# cloud_properties in each AZ entry.  The base CloudConfig.pm always derives
	# the az_prefix as "$env->name . '-z'", so canonical names are '-z1' etc.
	cmp_deeply($azs, {
		'az1' => superhashof({ 'cloud_properties' => '{"zone": "us-east-1a"}', 'name' => 'test-env-mgmt-z1' }),
		'az2' => superhashof({ 'cloud_properties' => '{"zone": "us-east-1b"}', 'name' => 'test-env-mgmt-z2' }),
		'az3' => superhashof({ 'cloud_properties' => '{"zone": "us-east-1c"}', 'name' => 'test-env-mgmt-z3' }),
	}, 'get_available_azs() returns all three AZs with correct name and cloud_properties');
};

subtest 'lookup_az - resolves short AZ name to canonical full name' => sub {
	plan tests => 3;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	is($hook->lookup_az('az1'), 'test-env-mgmt-z1',
		'lookup_az("az1") returns canonical name test-env-mgmt-z1');

	is($hook->lookup_az('az2'), 'test-env-mgmt-z2',
		'lookup_az("az2") returns canonical name test-env-mgmt-z2');

	is($hook->lookup_az('az3'), 'test-env-mgmt-z3',
		'lookup_az("az3") returns canonical name test-env-mgmt-z3');
};

subtest 'lookup_az - bails for unknown AZ identifier' => sub {
	plan tests => 1;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	throws_ok {
		$hook->lookup_az('az99')
	} qr/Availability zone az99 not found in the available AZs for the network/,
		'lookup_az() dies with informative message for unknown AZ';
};

subtest 'lookup_az - also resolves by canonical full name' => sub {
	plan tests => 1;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	is($hook->lookup_az('test-env-mgmt-z1'), 'test-env-mgmt-z1',
		'lookup_az() also resolves canonical full name to itself');
};

subtest 'lookup_az - resolves the short form of a rendered name by AZ index' => sub {
	plan tests => 2;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	is($hook->lookup_az('z2'), 'test-env-mgmt-z2',
		'lookup_az("z2") resolves to the AZ whose rendered name ends in 2');

	throws_ok {
		$hook->lookup_az('z9')
	} qr/Availability zone z9 not found in the available AZs for the network/,
		'lookup_az() still bails for a short form with no matching index';
};

subtest 'lookup_az - a CPI-less hook is not answered by an earlier CPI hook' => sub {
	plan tests => 2;

	# A hook with a CPI, whose AZ carries a CPI-specific name
	my $cpi_env  = make_deploy_env(cpi_enabled => 1, cpi_name => 'test-cpi');
	my $cpi_hook = Genesis::Hook::CloudConfig::Bosh->init(env => $cpi_env);
	$cpi_hook->network->{azs}{az1}{for_cpi}{'test-cpi'} = 'test-env-cpi-z1';
	is($cpi_hook->lookup_az('az1'), 'test-env-cpi-z1',
		'a CPI hook resolves the AZ to its CPI-specific name');

	# A second hook without a CPI, asking for the same AZ afterwards in the
	# same process, must get the rendered name rather than the value the
	# previous call left behind
	my $plain_hook = Genesis::Hook::CloudConfig::Bosh->init(env => make_deploy_env());
	is($plain_hook->lookup_az('az1'), 'test-env-mgmt-z1',
		'a CPI-less hook resolves the same AZ to its rendered name');
};

subtest 'az_cloud_properties - decodes the AZ cloud properties for any AZ identifier' => sub {
	plan tests => 5;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	cmp_deeply($hook->az_cloud_properties('az1'), { zone => 'us-east-1a' },
		'az_cloud_properties() resolves by AZ key and decodes the JSON string');

	cmp_deeply($hook->az_cloud_properties('test-env-mgmt-z2'), { zone => 'us-east-1b' },
		'az_cloud_properties() resolves by canonical full name');

	cmp_deeply($hook->az_cloud_properties('z3'), { zone => 'us-east-1c' },
		'az_cloud_properties() resolves by the short form of the rendered name');

	my $first = $hook->az_cloud_properties('z1');
	$first->{extra} = 'mine';
	cmp_deeply($hook->az_cloud_properties('z1'), { zone => 'us-east-1a' },
		'az_cloud_properties() hands back a fresh hashref each call, so callers may extend it');

	throws_ok {
		$hook->az_cloud_properties('az99')
	} qr/Availability zone az99 not found in the available AZs for the network/,
		'az_cloud_properties() bails with the lookup_az message for an unknown AZ';
};

subtest 'az_cloud_properties - empty and malformed cloud properties' => sub {
	plan tests => 3;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	$hook->network->{azs}{az1}{cloud_properties} = '{}';
	cmp_deeply($hook->az_cloud_properties('az1'), {},
		'az_cloud_properties() returns an empty hashref for "{}"');

	delete $hook->network->{azs}{az1}{cloud_properties};
	cmp_deeply($hook->az_cloud_properties('az1'), {},
		'az_cloud_properties() returns an empty hashref when the AZ has no cloud_properties');

	$hook->network->{azs}{az2}{cloud_properties} = '{"zone": ';
	throws_ok {
		$hook->az_cloud_properties('az2')
	} qr/Invalid JSON in the cloud properties for availability zone az2/,
		'az_cloud_properties() bails on cloud properties that are not valid JSON';
};

subtest 'get_available_azs_in_network - returns AZs for allocated network' => sub {
	plan tests => 5;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	# Build a bosh network so there are allocations to query
	expect_bosh_drop { $hook->network_definition('bosh',
		strategy => 'ocfp',
		dynamic_subnets => {
			allocation => { size => 0, statics => 0 },
			cloud_properties_for_iaas => {
				openstack => {
					'net_id'          => $hook->network_reference('id'),
					'security_groups' => ['default'],
				},
			},
		},
	) };

	my $azs = $hook->get_available_azs_in_network('bosh');

	ok(defined $azs, 'get_available_azs_in_network() returns a defined value');
	is(ref($azs), 'ARRAY', 'get_available_azs_in_network() returns an arrayref');

	# bosh network uses ocfp-0 (az1) and ocfp-2 (az3) — ocfp-1 (az2) is
	# fully claimed by the director compilation network
	my @sorted = sort @$azs;
	is(scalar @sorted, 2, 'get_available_azs_in_network() returns 2 AZs for bosh network');
	cmp_deeply(\@sorted, ['test-env-mgmt-z1', 'test-env-mgmt-z3'],
		'get_available_azs_in_network() returns the AZs for subnets actually used');
};

# ---------------------------------------------------------------------------
# Subnet Filtering
# ---------------------------------------------------------------------------
subtest '_filter_subnets - no args returns all subnets' => sub {
	plan tests => 2;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $result = $hook->_filter_subnets();
	is(ref($result), 'HASH', '_filter_subnets() returns a hashref');
	cmp_deeply([sort keys %$result], ['ocfp-0', 'ocfp-1', 'ocfp-2'],
		'_filter_subnets() with no args returns all three subnets');
};

subtest '_filter_subnets - single string filter' => sub {
	plan tests => 2;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $result = $hook->_filter_subnets('ocfp-0');
	cmp_deeply([sort keys %$result], ['ocfp-0'],
		'_filter_subnets("ocfp-0") returns exactly one subnet');
	cmp_deeply($result, {
		'ocfp-0' => {
			az             => 'az1',
			cidr_block     => '10.0.0.0/24',
			dns            => '10.0.0.2',
			gateway        => '10.0.0.1',
			'reserved-ips' => {
				'available_a' => '10.0.0.37',
				'available_b' => '10.0.0.250',
				'bosh_ip'     => '10.0.0.5',
			},
		},
	}, '_filter_subnets("ocfp-0") returns correct subnet data');
};

subtest '_filter_subnets - multiple name array filter' => sub {
	plan tests => 2;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $result = $hook->_filter_subnets(['ocfp-0', 'ocfp-2', 'ocfp-4']);
	cmp_deeply([sort keys %$result], ['ocfp-0', 'ocfp-2'],
		'_filter_subnets(["ocfp-0","ocfp-2","ocfp-4"]) returns only existing subnets');

	my $result2 = $hook->_filter_subnets(['ocfp-1', 'ocfp-2']);
	cmp_deeply([sort keys %$result2], ['ocfp-1', 'ocfp-2'],
		'_filter_subnets(["ocfp-1","ocfp-2"]) returns both matching subnets');
};

subtest '_filter_subnets - regex filter' => sub {
	plan tests => 2;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $result = $hook->_filter_subnets(qr/ocfp-[2-4]/);
	cmp_deeply([sort keys %$result], ['ocfp-2'],
		'_filter_subnets(qr/ocfp-[2-4]/) matches only ocfp-2');

	my $result2 = $hook->_filter_subnets(qr/ocfp-[0-1]/);
	cmp_deeply([sort keys %$result2], ['ocfp-0', 'ocfp-1'],
		'_filter_subnets(qr/ocfp-[0-1]/) matches ocfp-0 and ocfp-1');
};

subtest '_filter_subnets - mixed array of regex and string, no duplicates' => sub {
	plan tests => 1;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $result = $hook->_filter_subnets([qr/ocfp-[2-4]/, 'ocfp-0', 'ocfp-2']);
	cmp_deeply([sort keys %$result], ['ocfp-0', 'ocfp-2'],
		'_filter_subnets([regex, string, string]) deduplicates and returns correct subnets');
};

subtest '_filter_subnets - nonexistent name returns empty hashref' => sub {
	plan tests => 2;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $result = $hook->_filter_subnets('nonexistent');
	is(ref($result), 'HASH', '_filter_subnets("nonexistent") returns a hashref');
	cmp_deeply([keys %$result], [],
		'_filter_subnets("nonexistent") returns an empty hashref');
};

subtest 'dynamic_subnets - subnet named exactly the prefix is selected' => sub {
	plan tests => 3;

	# A bloc may hold a single subnet whose name IS the prefix (e.g. an
	# 'infra' subnet with ocfp_subnet_prefix 'infra') alongside numbered
	# '<prefix>-N' subnets for other prefixes.
	my $config = dclone($ocfp_config);
	$config->{vpc}{subnets} = {
		'infra' => {
			az => 'az1', cidr_block => '10.0.3.0/24',
			gateway => '10.0.3.1', dns => '10.0.3.2',
			'reserved-ips' => {
				'wireguard_ip' => '10.0.3.6',
			},
		},
	};

	my $env  = make_deploy_env(
		ocfp_subnet_prefix => 'infra',
		ocfp_config        => $config,
	);
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $net;
	lives_ok {
		$net = $hook->network_definition('wireguard',
			strategy => 'ocfp',
			dynamic_subnets => {
				allocation => { size => 0, statics => 0 },
				cloud_properties_for_iaas => {
					openstack => {
						'net_id'          => $hook->network_reference('id'),
						'security_groups' => ['default'],
					},
				},
			},
		);
	} 'network_definition() succeeds when the only subnet is named exactly the prefix';

	is(scalar @{$net->{subnets}}, 1, 'network definition contains one subnet');
	is($net->{subnets}[0]{range}, '10.0.3.0/24',
		'subnet range comes from the prefix-named subnet');
};

# ---------------------------------------------------------------------------
# Allocation Tracking
# ---------------------------------------------------------------------------
subtest 'get_allocated_networks - reflects director compilation claim before any build' => sub {
	plan tests => 4;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $allocs = $hook->get_allocated_networks;
	is(ref($allocs), 'HASH', 'get_allocated_networks() returns a hashref');

	cmp_deeply([keys %$allocs], ['test-env-mgmt.bosh.net-compilation'],
		'get_allocated_networks() shows only director compilation network is allocated');

	cmp_deeply([keys %{$allocs->{'test-env-mgmt.bosh.net-compilation'}}], ['ocfp-1'],
		'director compilation allocation is on ocfp-1 only');

	is($allocs->{'test-env-mgmt.bosh.net-compilation'}{'ocfp-1'}{allocated},
		'10.0.1.37-10.0.1.40',
		'compilation allocation range is 10.0.1.37-10.0.1.40');
};

subtest 'get_allocated_networks - returns per-subnet allocation details' => sub {
	plan tests => 5;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	# Build a bosh network first to create an allocation
	expect_bosh_drop { $hook->network_definition('bosh',
		strategy => 'ocfp',
		dynamic_subnets => {
			allocation => { size => 0, statics => 0 },
			cloud_properties_for_iaas => {
				openstack => {
					'net_id'          => $hook->network_reference('id'),
					'security_groups' => ['default'],
				},
			},
		},
	) };

	my $allocated = $hook->get_allocated_networks();
	is(ref($allocated), 'HASH', 'get_allocated_networks() returns a hashref');

	my $bosh_net_name = $hook->basename . '.net-bosh';
	ok(exists $allocated->{$bosh_net_name},
		"get_allocated_networks() contains entry for $bosh_net_name");

	my $bosh_alloc = $allocated->{$bosh_net_name};
	ok(exists $bosh_alloc->{'ocfp-0'}, 'bosh network allocation includes ocfp-0');

	cmp_deeply($bosh_alloc->{'ocfp-0'}, {
		allocated => '10.0.0.5',
		az        => 'test-env-mgmt-z1',
	}, 'ocfp-0 allocation shows bosh_ip 10.0.0.5 and correct AZ');
};

subtest 'get_network_size - returns total IP count for a network' => sub {
	plan tests => 4;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	expect_bosh_drop { $hook->network_definition('bosh',
		strategy => 'ocfp',
		dynamic_subnets => {
			allocation => { size => 0, statics => 0 },
			cloud_properties_for_iaas => {
				openstack => {
					'net_id'          => $hook->network_reference('id'),
					'security_groups' => ['default'],
				},
			},
		},
	) };

	my $total_size = $hook->get_network_size('bosh');
	ok(defined $total_size, 'get_network_size() returns a defined value');
	ok($total_size > 0, 'get_network_size() returns a positive value');

	# bosh network uses bosh_ip on ocfp-0 (1 IP) and bosh_ip on ocfp-2 (1 IP)
	is($total_size, 2, 'get_network_size("bosh") returns 2 (one bosh_ip per subnet)');
};

subtest 'get_network_size - filtered by AZ returns subset' => sub {
	plan tests => 3;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	expect_bosh_drop { $hook->network_definition('bosh',
		strategy => 'ocfp',
		dynamic_subnets => {
			allocation => { size => 0, statics => 0 },
			cloud_properties_for_iaas => {
				openstack => {
					'net_id'          => $hook->network_reference('id'),
					'security_groups' => ['default'],
				},
			},
		},
	) };

	my $az1_size = $hook->get_network_size('bosh', 'az1');
	is($az1_size, 1, 'get_network_size("bosh", "az1") returns 1 (ocfp-0 only)');

	my $az3_size = $hook->get_network_size('bosh', 'az3');
	is($az3_size, 1, 'get_network_size("bosh", "az3") returns 1 (ocfp-2 only)');
};

subtest 'update_network - records allocations for named network' => sub {
	plan tests => 5;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	# Start: no bosh claims yet
	my $allocs_before = $hook->get_allocated_networks;
	ok(!exists $allocs_before->{$hook->basename.'.net-bosh'},
		'no bosh network claim before network_definition is called');

	# Build network definition — this internally calls update_network
	expect_bosh_drop { $hook->network_definition('bosh',
		strategy => 'ocfp',
		dynamic_subnets => {
			allocation => { size => 0, statics => 0 },
			cloud_properties_for_iaas => {
				openstack => {
					'net_id'          => $hook->network_reference('id'),
					'security_groups' => ['default'],
				},
			},
		},
	) };

	# After: claims on ocfp-0 and ocfp-2
	cmp_deeply($hook->network->{subnets}{'ocfp-0'}{claims}, {
		$hook->basename.'.net-bosh' => '10.0.0.5',
	}, 'update_network records bosh_ip claim on ocfp-0');

	cmp_deeply($hook->network->{subnets}{'ocfp-2'}{claims}, {
		$hook->basename.'.net-bosh' => '10.0.2.6',
	}, 'update_network records bosh_ip claim on ocfp-2');

	# director claim on ocfp-1 is preserved
	cmp_deeply($hook->network->{subnets}{'ocfp-1'}{claims}, {
		'test-env-mgmt.bosh.net-compilation' => '10.0.1.37-10.0.1.40',
	}, 'director compilation claim on ocfp-1 is not disturbed');
};

subtest 'relinquish_networks - removes claim records for named networks' => sub {
	plan tests => 4;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	# Build two networks
	expect_bosh_drop { $hook->network_definition('bosh',
		strategy => 'ocfp',
		dynamic_subnets => {
			allocation => { size => 0, statics => 0 },
			cloud_properties_for_iaas => {
				openstack => {
					'net_id'          => $hook->network_reference('id'),
					'security_groups' => ['default'],
				},
			},
		},
	) };

	my $bosh_net = $hook->basename . '.net-bosh';
	ok(
		exists $hook->network->{subnets}{'ocfp-0'}{claims}{$bosh_net},
		'bosh network claim exists on ocfp-0 before relinquish',
	);

	$hook->relinquish_networks('bosh');

	ok(
		!exists $hook->network->{subnets}{'ocfp-0'}{claims}{$bosh_net},
		'bosh network claim removed from ocfp-0 after relinquish',
	);
	ok(
		!exists $hook->network->{subnets}{'ocfp-2'}{claims}{$bosh_net},
		'bosh network claim removed from ocfp-2 after relinquish',
	);
};

# ---------------------------------------------------------------------------
# Network Definition
# ---------------------------------------------------------------------------
subtest 'network_definition - ocfp strategy returns hashref with name/type/subnets' => sub {
	plan tests => 6;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $net = expect_bosh_drop { $hook->network_definition('bosh',
		strategy => 'ocfp',
		dynamic_subnets => {
			allocation => { size => 0, statics => 0 },
			cloud_properties_for_iaas => {
				openstack => {
					'net_id'          => $hook->network_reference('id'),
					'security_groups' => ['default'],
				},
			},
		},
	) };

	ok($net, 'network_definition() returns a defined value');
	is(ref($net), 'HASH', 'network_definition() returns a hashref');
	is($net->{name}, $hook->basename.'.net-bosh',
		'network name follows basename.net-target format');
	is($net->{type}, 'manual', 'network type is "manual" for ocfp strategy');
	ok(scalar @{$net->{subnets}}, 'network definition contains at least one subnet');
};

subtest 'network_definition - vip strategy returns name and type only' => sub {
	plan tests => 3;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $net = $hook->network_definition('floaters', strategy => 'vip');

	ok($net, 'network_definition() with vip strategy returns a defined value');
	is($net->{name}, $hook->basename.'.net-floaters',
		'vip network name is correct');
	is($net->{type}, 'vip', 'vip strategy sets type to "vip"');
};

subtest 'network_definition - vip strategy has no subnets key' => sub {
	plan tests => 1;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $net = $hook->network_definition('floaters', strategy => 'vip');
	ok(!exists $net->{subnets},
		'vip network definition has no subnets key');
};

subtest 'network_definition - unsupported strategy throws error' => sub {
	plan tests => 1;

	# The unsupported-strategy bail fires when (strategy eq 'ocfp') xor is_ocfp
	# evaluates to FALSE.  For a non-OCFP env, any non-ocfp strategy reaches the
	# bail path because the env and strategy are both non-ocfp (xor = false).
	my $env  = make_deploy_env(
		is_ocfp  => 0,
		features => Mock::ReferencedValue->new([]),
	);
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	throws_ok {
		$hook->network_definition('bosh', strategy => 'badstrategy')
	} qr/Network definition strategy badstrategy is not supported/,
		'network_definition() throws for unsupported strategy on non-ocfp env';
};

subtest 'network_definition - name_prefix overrides default prefix' => sub {
	plan tests => 2;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $net = $hook->network_definition('floaters',
		strategy    => 'vip',
		name_prefix => 'custom-prefix-',
	);

	ok($net, 'network_definition() with name_prefix returns a value');
	is($net->{name}, 'custom-prefix-floaters',
		'name_prefix option replaces default basename prefix');
};

subtest 'network_definition - ocfp subnets: 2 subnets (ocfp-1 fully claimed)' => sub {
	plan tests => 5;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $net = expect_bosh_drop { $hook->network_definition('bosh',
		strategy => 'ocfp',
		dynamic_subnets => {
			allocation => { size => 0, statics => 0 },
			cloud_properties_for_iaas => {
				openstack => {
					'net_id'          => $hook->network_reference('id'),
					'security_groups' => ['default'],
				},
			},
		},
	) };

	is(scalar @{$net->{subnets}}, 2,
		'bosh network has 2 subnets (ocfp-1 excluded as fully claimed by director)');

	is($net->{subnets}[0]{az}, 'test-env-mgmt-z1',
		'first subnet AZ is test-env-mgmt-z1 (ocfp-0)');

	is($net->{subnets}[1]{az}, 'test-env-mgmt-z3',
		'second subnet AZ is test-env-mgmt-z3 (ocfp-2)');

	cmp_deeply($net->{subnets}[0]{static}, ['10.0.0.5'],
		'first subnet static list contains bosh_ip 10.0.0.5');
};

# ---------------------------------------------------------------------------
# subnets accessor
# ---------------------------------------------------------------------------
subtest 'subnets - returns OCFP subnet definitions from ocfp_config' => sub {
	plan tests => 3;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $subnets = $hook->subnets;
	is(ref($subnets), 'HASH', 'subnets() returns a hashref');
	cmp_deeply([sort keys %$subnets], ['ocfp-0', 'ocfp-1', 'ocfp-2'],
		'subnets() contains all three OCFP subnets');
	ok(exists $subnets->{'ocfp-0'}{cidr_block},
		'subnet data includes cidr_block field');
};

# ---------------------------------------------------------------------------
# Network Security Groups
# ---------------------------------------------------------------------------
subtest 'get_network_security_groups - returns a LookupNetworkRef' => sub {
	plan tests => 2;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $ref = $hook->get_network_security_groups('id');
	isa_ok($ref, 'Genesis::Hook::CloudConfig::LookupNetworkRef',
		'get_network_security_groups() returns a LookupNetworkRef');

	is($ref->{ref}, 'sgs',
		'LookupNetworkRef is keyed on "sgs"');
};

subtest 'get_network_security_groups - resolves to SG ids when resolved' => sub {
	plan tests => 2;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $ref    = $hook->get_network_security_groups('id');
	my $vpc_data = $hook->env->ocfp_config_lookup(['net','vpc']);

	my $result = $ref->resolve($hook, $vpc_data);
	ok(defined $result, 'resolved security groups is defined');
	cmp_deeply($result, ['xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxx02'],
		'resolved SG ids match expected default SG id');
};

# ---------------------------------------------------------------------------
# Reserved IP target aliasing (openbao/vault rename fallback)
# ---------------------------------------------------------------------------
# ocfp-0 reserves a single vault_ip, ocfp-1 reserves a vault_a/vault_b pair,
# and ocfp-2 has no target-specific reservation at all (used to prove the
# no-match/no-alias case still drops the subnet and now warns).
my $alias_ocfp_config = {
	vpc => {
		azs => {
			'az1' => { cloud_properties => '{"zone": "us-east-1a"}' },
			'az2' => { cloud_properties => '{"zone": "us-east-1b"}' },
			'az3' => { cloud_properties => '{"zone": "us-east-1c"}' },
		},
		cidr_block => '10.9.0.0/20',
		dns        => '1.1.1.1',
		id         => 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxx09',
		region     => 'us-east-1',
		sgs => {
			default => {
				'description' => 'Default security group',
				'id'          => 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxx09',
				'name'        => 'default',
			},
		},
		subnets => {
			'ocfp-0' => {
				az => 'az1', cidr_block => '10.9.0.0/24',
				gateway => '10.9.0.1', dns => '10.9.0.2',
				'reserved-ips' => {
					'vault_ip' => '10.9.0.5',
				},
			},
			'ocfp-1' => {
				az => 'az2', cidr_block => '10.9.1.0/24',
				gateway => '10.9.1.1', dns => '10.9.1.2',
				'reserved-ips' => {
					'vault_a' => '10.9.1.9',
					'vault_b' => '10.9.1.11',
				},
			},
			'ocfp-2' => {
				az => 'az3', cidr_block => '10.9.2.0/24',
				gateway => '10.9.2.1', dns => '10.9.2.2',
				'reserved-ips' => {},
			},
		},
	},
};

# A catalog whose keys are well-formed, but where one target's name occurs
# inside another key.  `_ip` denotes a single value and `_a`/`_b` a range; a
# target uses one form or the other, never both, and never `_ip_a`.
my $embedded_name_ocfp_config = {
	vpc => {
		azs => {
			'az1' => { cloud_properties => '{"zone": "us-east-1a"}' },
		},
		cidr_block => '10.8.0.0/20',
		dns        => '1.1.1.1',
		id         => 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxx08',
		region     => 'us-east-1',
		sgs => {
			default => {
				'description' => 'Default security group',
				'id'          => 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxx08',
				'name'        => 'default',
			},
		},
		subnets => {
			'ocfp-0' => {
				az => 'az1', cidr_block => '10.8.0.0/24',
				gateway => '10.8.0.1', dns => '10.8.0.2',
				'reserved-ips' => {
					'bosh_ip'      => '10.8.0.5',
					# A different target whose key contains "bosh_ip".
					'ocfp_bosh_ip' => '10.8.0.9',
				},
			},
		},
	},
};

subtest '_get_reserved_allocation - another target key containing the name is not claimed' => sub {
	plan tests => 2;

	# The match is against the start of the key, not anywhere within it:
	# ocfp_bosh_ip belongs to ocfp_bosh, and sweeping it into bosh's
	# allocation hands bosh a static range covering someone else's address.
	my $env  = make_deploy_env(ocfp_config => $embedded_name_ocfp_config);
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);
	my $subnet = $hook->subnets->{'ocfp-0'};

	my ($bosh_alloc) = $hook->_get_reserved_allocation('bosh', $subnet);
	is($bosh_alloc->range, '10.8.0.5',
		'bosh claims only its own bosh_ip, not the ocfp_bosh_ip beside it');

	my ($ocfp_alloc) = $hook->_get_reserved_allocation('ocfp_bosh', $subnet);
	is($ocfp_alloc->range, '10.8.0.9',
		'ocfp_bosh still resolves its own key');
};

# Build a one-subnet config whose only reservations are the given keys, so a
# subtest can say exactly what shape it is exercising.
sub reserved_ip_config {
	my (%reserved) = @_;
	my $config = {%$embedded_name_ocfp_config};
	$config->{vpc} = {%{$config->{vpc}}};
	$config->{vpc}{subnets} = {
		'ocfp-0' => {
			az => 'az1', cidr_block => '10.8.0.0/24',
			gateway => '10.8.0.1', dns => '10.8.0.2',
			'reserved-ips' => \%reserved,
		},
	};
	return $config;
}

subtest '_get_reserved_allocation - unexplained _ip_<suffix> keys are reported' => sub {
	plan tests => 2;

	# `bosh_ip_a` is neither spelling: the bracket-pair loop looks for
	# `bosh_a` and never sees it, so such a key silently alters the
	# allocation instead of being rejected.  Say so rather than absorb it.
	# These two are far from bosh_ip, so they describe nothing we recognise.
	my $env  = make_deploy_env(ocfp_config => reserved_ip_config(
		'bosh_ip'   => '10.8.0.5',
		'bosh_ip_a' => '10.8.0.40',
		'bosh_ip_b' => '10.8.0.60',
	));
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	# Genesis::warning writes to STDERR directly rather than through warn.
	my $alloc;
	my $warn = stderr_from {
		($alloc) = $hook->_get_reserved_allocation('bosh', $hook->subnets->{'ocfp-0'});
	};

	is($alloc->range, '10.8.0.5',
		'only the well-formed bosh_ip is claimed; the malformed bounds are ignored');
	like($warn, qr/bosh_ip_a.*bosh_ip_b/s,
		'and the malformed keys are named rather than silently changing the allocation');
};

subtest '_get_reserved_allocation - neighbour annotations are dropped quietly' => sub {
	plan tests => 3;

	# An OCFP carve written under scheme_version 2 records the address on
	# either side of the reservation, so `_a` holds bosh_ip's predecessor and
	# `_b` its successor.  Those addresses belong to whichever target sits
	# beside bosh in the run, so ignoring them is correct, and every bloc in
	# the fleet writes this shape.  Warning about it on every lookup teaches
	# operators to ignore the warning.
	my $env  = make_deploy_env(ocfp_config => reserved_ip_config(
		'bosh_ip'   => '10.8.0.5',
		'bosh_ip_a' => '10.8.0.4',
		'bosh_ip_b' => '10.8.0.6',
	));
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $alloc;
	my $warn = stderr_from {
		($alloc) = $hook->_get_reserved_allocation('bosh', $hook->subnets->{'ocfp-0'});
	};

	is($alloc->range, '10.8.0.5',
		'the neighbours are still left out of the allocation');
	unlike($warn, qr/bosh_ip_a/,
		'the predecessor is not reported as malformed');
	unlike($warn, qr/bosh_ip_b/,
		'nor is the successor');
};

subtest '_get_reserved_allocation - a neighbour on the wrong side still warns' => sub {
	plan tests => 2;

	# `_a` is the address below and `_b` the address above.  A pair written
	# the other way round is not the shape we recognise, so it goes back to
	# being reported rather than quietly assumed to be deliberate.
	my $env  = make_deploy_env(ocfp_config => reserved_ip_config(
		'bosh_ip'   => '10.8.0.5',
		'bosh_ip_a' => '10.8.0.6',
		'bosh_ip_b' => '10.8.0.4',
	));
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $alloc;
	my $warn = stderr_from {
		($alloc) = $hook->_get_reserved_allocation('bosh', $hook->subnets->{'ocfp-0'});
	};

	is($alloc->range, '10.8.0.5', 'the allocation is unchanged either way');
	like($warn, qr/bosh_ip_a.*bosh_ip_b/s, 'and both keys are still named');
};

subtest '_get_reserved_allocation - an annotation without its anchor still warns' => sub {
	plan tests => 2;

	# With no `bosh_ip` to sit beside, `bosh_ip_a` describes nothing and the
	# operator has no way to know it was dropped unless we say so.
	my $env  = make_deploy_env(ocfp_config => reserved_ip_config(
		'bosh_a'    => '10.8.0.3',
		'bosh_b'    => '10.8.0.7',
		'bosh_ip_a' => '10.8.0.4',
	));
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $alloc;
	my $warn = stderr_from {
		($alloc) = $hook->_get_reserved_allocation('bosh', $hook->subnets->{'ocfp-0'});
	};

	is($alloc->range, '10.8.0.4-10.8.0.6',
		'the bracket pair still gives the interior range');
	like($warn, qr/bosh_ip_a/, 'and the orphaned annotation is named');
};

subtest '_get_reserved_allocation - openbao falls back to vault reserved-ips' => sub {
	plan tests => 3;

	my $env  = make_deploy_env(ocfp_config => $alias_ocfp_config);
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);
	my $subnets = $hook->subnets;

	my ($ip_alloc) = $hook->_get_reserved_allocation('openbao', $subnets->{'ocfp-0'});
	is($ip_alloc->range, '10.9.0.5',
		'openbao resolves the single vault_ip reservation on ocfp-0');

	my ($pair_alloc) = $hook->_get_reserved_allocation('openbao', $subnets->{'ocfp-1'});
	is($pair_alloc->range, '10.9.1.10',
		'openbao resolves the vault_a/vault_b pair reservation on ocfp-1');

	my ($empty_alloc) = $hook->_get_reserved_allocation('openbao', $subnets->{'ocfp-2'});
	is($empty_alloc->size, 0,
		'openbao has no allocation on ocfp-2, which defines no vault reservation either');
};

subtest '_get_reserved_allocation - vault target is unchanged (regression)' => sub {
	plan tests => 3;

	my $env  = make_deploy_env(ocfp_config => $alias_ocfp_config);
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);
	my $subnets = $hook->subnets;

	my ($ip_alloc) = $hook->_get_reserved_allocation('vault', $subnets->{'ocfp-0'});
	is($ip_alloc->range, '10.9.0.5',
		'vault still resolves its own vault_ip reservation directly on ocfp-0');

	my ($pair_alloc) = $hook->_get_reserved_allocation('vault', $subnets->{'ocfp-1'});
	is($pair_alloc->range, '10.9.1.10',
		'vault still resolves its own vault_a/vault_b pair directly on ocfp-1');

	my ($empty_alloc) = $hook->_get_reserved_allocation('vault', $subnets->{'ocfp-2'});
	is($empty_alloc->size, 0,
		'vault has no allocation on ocfp-2, which defines no reservation at all');
};

subtest '_get_reserved_allocation - unaliased target with no keys returns empty' => sub {
	plan tests => 1;

	my $env  = make_deploy_env(ocfp_config => $alias_ocfp_config);
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my ($alloc) = $hook->_get_reserved_allocation('foobar', $hook->subnets->{'ocfp-0'});
	is($alloc->size, 0,
		'target with no matching keys and no alias table entry resolves to no allocation');
};

subtest 'reserved-ips records - every <owner>_ip form owns its addresses, for the owner and for others' => sub {
	my @forms = (
		['garage _ip with an _ip_smoke beside it', {garage_ip => '10.8.0.84', garage_ip_smoke => '10.8.0.86'}, '10.8.0.84,10.8.0.86'],
		['rustfs _ip with an _ip_smoke beside it', {rustfs_ip => '10.8.0.77', rustfs_ip_smoke => '10.8.0.85'}, '10.8.0.77,10.8.0.85'],
		['a comma list',                           {garage_ip => '10.8.0.84,10.8.0.90'},                       '10.8.0.84,10.8.0.90'],
		['a dash range',                           {garage_ip => '10.8.0.84-10.8.0.86'},                       '10.8.0.84-10.8.0.86'],
		['a CIDR',                                 {garage_ip => '10.8.0.80/30'},                              '10.8.0.80-10.8.0.83'],
		['an _ips key',                            {garage_ips => '10.8.0.84,10.8.0.85'},                      '10.8.0.84-10.8.0.85'],
		['an _ip2 key beside _ip',                 {garage_ip => '10.8.0.84', garage_ip2 => '10.8.0.88'},      '10.8.0.84,10.8.0.88'],
		['a value with trailing whitespace',       {garage_ip => '10.8.0.84 '},                                '10.8.0.84'],
		['a value with leading whitespace',        {garage_ip => '  10.8.0.84'},                               '10.8.0.84'],
		['a range with whitespace on both ends',   {garage_ip => " \t10.8.0.84-10.8.0.86 "},                   '10.8.0.84-10.8.0.86'],
		['a dash range with spaces around the dash', {garage_ip => '10.8.0.84 - 10.8.0.86'},                   '10.8.0.84-10.8.0.86'],
		['a list holding a spaced dash range',     {garage_ip => '10.8.0.80, 10.8.0.84 - 10.8.0.86'},          '10.8.0.80,10.8.0.84-10.8.0.86'],
		['a list with spaces before its commas',   {garage_ip => '10.8.0.84 - 10.8.0.86 , 10.8.0.90'},         '10.8.0.84-10.8.0.86,10.8.0.90'],
		['bounds with leading whitespace',         {garage_a => ' 10.8.0.20', garage_b => "\t10.8.0.24"},      '10.8.0.21-10.8.0.23'],
		['bounds with trailing whitespace',        {garage_a => '10.8.0.20 ', garage_b => '10.8.0.24  '},      '10.8.0.21-10.8.0.23'],
	);
	plan tests => 3 * @forms;

	for my $form (@forms) {
		my ($label, $records, $expect) = @$form;
		my $env  = make_deploy_env(ocfp_config => reserved_ip_config(%$records));
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);
		my $subnet = $hook->subnets->{'ocfp-0'};

		my $owner = (grep {/^rustfs/} keys %$records) ? 'rustfs' : 'garage';
		my ($alloc) = $hook->_get_reserved_allocation($owner, $subnet);
		is($alloc->range, $expect, "own record: $label");

		# Per owner, so a record credited to the wrong owner is a difference
		my $others = $hook->_all_reserved_ip_records($subnet, 'bosh');
		is_deeply([sort keys %$others], [$owner], "other owners' view credits $owner alone: $label");
		is(exists $others->{$owner} ? $others->{$owner}->range : '', $expect, "other owners' view gives $owner the addresses: $label");
	}
};

subtest 'reserved-ips records - an owner whose name holds another owner\'s name keeps its suffixed keys' => sub {
	my @cases = (
		['an owner named by its _ip key', {my_ipsec_ip => '10.8.0.20', my_ipsec_ip_smoke => '10.8.0.22'},
			'bosh', {my_ipsec => '10.8.0.20,10.8.0.22'}],
		['beside a shorter owner with an _ip key', {my_ip => '10.8.0.10', my_ipsec_ip => '10.8.0.20', my_ipsec_ip_smoke => '10.8.0.22'},
			'bosh', {my => '10.8.0.10', my_ipsec => '10.8.0.20,10.8.0.22'}],
		['an owner named by its _a/_b pair', {my_ipsec_a => '10.8.0.20', my_ipsec_b => '10.8.0.24', my_ipsec_ip_smoke => '10.8.0.22'},
			'bosh', {my_ipsec => '10.8.0.21-10.8.0.23'}],
		['a suffixed key with no key that names its owner', {my_ipsec_ip_smoke => '10.8.0.22'},
			'bosh', {my => '10.8.0.22'}],
	);
	plan tests => 2 * @cases + 3;

	for my $case (@cases) {
		my ($label, $records, $asking, $want) = @$case;
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => make_deploy_env(ocfp_config => reserved_ip_config(%$records)));
		my $others = $hook->_all_reserved_ip_records($hook->subnets->{'ocfp-0'}, $asking);
		is_deeply({map {($_ => $others->{$_}->range)} keys %$others}, $want, "other owners' view: $label");
		is_deeply([sort keys %$others], [sort keys %$want], "and no owner is credited that holds nothing: $label");
	}

	# The asking target is the one owner name that is certain
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => make_deploy_env(ocfp_config => reserved_ip_config(
		my_ipsec_ip_smoke => '10.8.0.22',
	)));
	my $subnet = $hook->subnets->{'ocfp-0'};
	my ($own) = $hook->_get_reserved_allocation('my_ipsec', $subnet);
	is($own->range, '10.8.0.22', 'the target\'s own record includes a suffixed key even with no key that names it');
	is_deeply([sort keys %{$hook->_all_reserved_ip_records($subnet, 'my_ipsec')}], [],
		'and no other owner is credited with it');
	my ($mine) = $hook->_get_reserved_allocation('my', $subnet);
	is($mine->range, '10.8.0.22', 'while target my, which the split names, also reads it as its own');
};

subtest 'reserved-ips records - reversed or adjacent bounds hold nothing, and an _ip_static key is not an address' => sub {
	my %forms = (
		'adjacent bounds'          => [{garage_a => '10.8.0.20', garage_b => '10.8.0.21'}, ''],
		'equal bounds'             => [{garage_a => '10.8.0.20', garage_b => '10.8.0.20'}, ''],
		'reversed bounds'          => [{garage_a => '10.8.0.30', garage_b => '10.8.0.20'}, ''],
		'a bracket with one address inside' => [{garage_a => '10.8.0.20', garage_b => '10.8.0.22'}, '10.8.0.21'],
		'reversed later bounds'    => [{garage_a => '10.8.0.20', garage_b => '10.8.0.24', garage_c => '10.8.0.40', garage_d => '10.8.0.30'}, '10.8.0.21-10.8.0.23'],
		'an _ip_static of 1'       => [{garage_ip_static => 1}, ''],
		'an _ip_static of 0'       => [{garage_ip_static => 0}, ''],
		'an _ip_static beside the _ip' => [{garage_ip => '10.8.0.84', garage_ip_static => 1}, '10.8.0.84'],
	);
	plan tests => 3 * keys %forms;

	for my $label (sort keys %forms) {
		my ($records, $expect) = @{$forms{$label}};
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => make_deploy_env(ocfp_config => reserved_ip_config(%$records)));
		my $subnet = $hook->subnets->{'ocfp-0'};
		my $warn;
		my ($own) = do {
			my @r;
			$warn = stderr_from { @r = $hook->_get_reserved_allocation('garage', $subnet) };
			@r;
		};
		is($own->range, $expect, "own record: $label");
		my $others = $hook->_all_reserved_ip_records($subnet, 'bosh');
		is_deeply({map {($_ => $others->{$_}->range)} keys %$others}, ($expect eq '' ? {} : {garage => $expect}),
			"other owners' view: $label");
		is($warn, '', "and nothing is warned about: $label");
	}
};

subtest '_get_reserved_allocation - kit-declared aliases resolve (scalar + arrayref forms)' => sub {
	plan tests => 3;

	my $env  = make_deploy_env(ocfp_config => $alias_ocfp_config);

	# Scalar form.
	{
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);
		no warnings 'redefine';
		local *Genesis::Hook::CloudConfig::ocfp_reserved_ip_target_aliases = sub {
			my (undef, $target) = @_;
			return $target eq 'foobar' ? 'vault' : undef;
		};
		my ($alloc) = $hook->_get_reserved_allocation('foobar', $hook->subnets->{'ocfp-0'});
		is($alloc->range, '10.9.0.5',
			'kit override (scalar) resolves foobar via vault');
	}

	# Arrayref form.
	{
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);
		no warnings 'redefine';
		local *Genesis::Hook::CloudConfig::ocfp_reserved_ip_target_aliases = sub {
			my (undef, $target) = @_;
			return $target eq 'foobar' ? ['nonexistent', 'vault'] : undef;
		};
		my ($alloc) = $hook->_get_reserved_allocation('foobar', $hook->subnets->{'ocfp-1'});
		is($alloc->range, '10.9.1.10',
			'kit override (arrayref) walks candidates and finds vault');
	}

	# Kit override supersedes core-registered fallback.
	{
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);
		no warnings 'redefine';
		local *Genesis::Hook::CloudConfig::ocfp_reserved_ip_target_aliases = sub {
			my (undef, $target) = @_;
			# Divert openbao to a nonexistent alias -- core would send it to
			# vault, so if the kit path wins we get no allocation.
			return $target eq 'openbao' ? 'nonexistent' : undef;
		};
		my ($alloc) = $hook->_get_reserved_allocation('openbao', $hook->subnets->{'ocfp-0'});
		is($alloc->size, 0,
			'kit-declared aliases run before core fallback (openbao->nonexistent yields empty)');
	}
};

subtest 'network_definition - openbao target keeps subnets via vault alias fallback' => sub {
	plan tests => 3;

	my $env  = make_deploy_env(ocfp_config => $alias_ocfp_config);
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $net;
	my $warn = stderr_from {
		$net = $hook->network_definition('openbao',
			strategy => 'ocfp',
			dynamic_subnets => {
				allocation => { size => 0, statics => 0 },
				cloud_properties_for_iaas => {
					openstack => {
						'net_id'          => $hook->network_reference('id'),
						'security_groups' => ['default'],
					},
				},
			},
		);
	};

	is(scalar @{$net->{subnets}}, 2,
		'openbao network keeps ocfp-0 and ocfp-1, which resolve via the vault alias');

	my @names = map { $_->{az} } @{$net->{subnets}};
	cmp_deeply(\@names, ['test-env-mgmt-z1', 'test-env-mgmt-z2'],
		'surviving subnets are ocfp-0 (az1) and ocfp-1 (az2)');

	like($warn, qr/ocfp-2.*openbao|openbao.*ocfp-2/,
		'dropping ocfp-2 for openbao (no vault reservation either) emits a warning naming both');
};

subtest 'network_definition - unaliased target with no reservations drops and warns for every subnet' => sub {
	plan tests => 2;

	my $env  = make_deploy_env(ocfp_config => $alias_ocfp_config);
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $net;
	my $warn = stderr_from {
		$net = $hook->network_definition('foobar',
			strategy => 'ocfp',
			dynamic_subnets => {
				allocation => { size => 0, statics => 0 },
				cloud_properties_for_iaas => {
					openstack => {
						'net_id'          => $hook->network_reference('id'),
						'security_groups' => ['default'],
					},
				},
			},
		);
	};

	is(scalar @{$net->{subnets}}, 0,
		'foobar network has no alias and no reservations, so every subnet is dropped');

	like($warn, qr/ocfp-0/,
		'warning names at least one dropped subnet for the unaliased target');
};

# ---------------------------------------------------------------------------
# a network's own claim is never one of the "other networks"
# ---------------------------------------------------------------------------
# A dry run reported a subnet as claimed by other networks, and the number
# looked large enough to include the deployment's own claim on that subnet --
# a network counted against itself, which would shrink every redeploy.  The
# env file carried an allocation override, so the question is whether an
# override changes the key a claim is filed under.  It does not: the override
# only sets how many addresses are wanted, and the claim stays under the
# network's own name.
#
# Written as a comparison rather than a fixed number, because the figure that
# matters is the difference a self-claim makes to it, and that difference must
# be nothing.
subtest 'network_definition - an allocation override does not count a network\'s own claim against it' => sub {
	plan tests => 6;

	my $own_claim = '10.0.1.100-10.0.1.163'; # 64 addresses, ours, on ocfp-1

	# size_ocfp_1 - ask for the bosh network with an allocation override in the
	# env file, optionally with a claim of our own already on ocfp-1, and give
	# back the "claimed by other networks" figure out of the drop warning.
	my $size_ocfp_1 = sub {
		my ($with_own_claim) = @_;
		my $env = make_deploy_env(
			config => {
				params => {cloud_config_prefix => 'test-env.test'},
				# The override the operator wrote, under the base the hook reads.
				'bosh-configs' => {
					cloud => {networks => {bosh => {allocation => {size => 0}}}},
				},
			},
			director_exodus_lookup => sub {
				my ($self, $key) = @_;
				die "Unknown exodus key: $key" unless $key eq '/network';
				my $network = dclone($director_network_exodus);
				# Filed under this network's own name, which is what the sizing
				# code has to recognise as ours.
				$network->{subnets}{'ocfp-1'}{claims}{$self->name.'.bosh.net-bosh'} = $own_claim
					if $with_own_claim;
				return $network;
			},
		);
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

		my ($net, $warn);
		$warn = stderr_from {
			$net = $hook->network_definition('bosh',
				strategy => 'ocfp',
				dynamic_subnets => {
					# Overridden to 0 by the env file, which is what drops the
					# subnet and prints the figure this subtest is about.
					allocation => {size => 8, statics => 0},
					cloud_properties_for_iaas => {
						openstack => {
							'net_id'          => $hook->network_reference('id'),
							'security_groups' => ['default'],
						},
					},
				},
			);
		};
		return ($warn, $net);
	};

	my ($alone_warn) = $size_ocfp_1->(0);
	like($alone_warn, qr/Dropping subnet ocfp-1.*net-bosh/s,
		'the override is read: a size of 0 drops ocfp-1 rather than allocating the 8 the kit asked for');
	my ($alone) = $alone_warn =~ /(\d+)\s+claimed\s+by\s+other\s+networks/s;
	ok(defined $alone, 'the drop warning reports what other networks have claimed');
	is($alone, 4,
		'which is the director\'s four-address compilation claim and nothing else');

	my ($with_own_warn) = $size_ocfp_1->(1);
	like($with_own_warn, qr/Dropping subnet ocfp-1.*net-bosh/s,
		'the same run with a claim of our own already on ocfp-1 still drops it');
	my ($with_own) = $with_own_warn =~ /(\d+)\s+claimed\s+by\s+other\s+networks/s;
	ok(defined $with_own, 'and still reports what other networks have claimed');

	is($with_own, $alone,
		'the figure is unchanged, so the network\'s own claim is not counted against it');
};

# ---------------------------------------------------------------------------
# Claim keys under a name_prefix
#
# A claim is keyed by the name that reaches the cloud config.  Where a kit
# passes a name_prefix -- including an empty one -- that is not the prefixed
# form name_for produces, which is what earlier releases keyed by regardless.
# The two subtests below cover the halves of that migration: the writer
# retires the old spelling, and the readers treat a claim still recorded under
# it as their own rather than as a foreign claim to allocate around.  Both
# geometries are invisible to a fixture that lets the naming default, because
# there the two spellings are the same string.
# ---------------------------------------------------------------------------

subtest 'update_network - a name_prefix claim replaces the legacy spelling' => sub {
	plan tests => 5;

	my $env  = make_deploy_env(
		director_exodus_lookup => sub {
			my ($self, $key) = @_;
			die "Unknown exodus key: $key" unless $key eq '/network';
			my $network = dclone($director_network_exodus);
			# What an earlier release recorded for this same network.
			$network->{subnets}{'ocfp-0'}{claims}{$self->name.'.bosh.net-bosh'} = '10.0.0.5';
			return $network;
		},
	);
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);
	my $legacy = $hook->basename.'.net-bosh';

	ok(exists $hook->get_allocated_networks->{$legacy},
		'the legacy claim is on the director before the deploy');

	expect_bosh_drop { $hook->network_definition('bosh',
		strategy => 'ocfp',
		name_prefix => 'ocfp-',
		dynamic_subnets => {
			allocation => { size => 0, statics => 0 },
			cloud_properties_for_iaas => {
				openstack => {
					'net_id'          => $hook->network_reference('id'),
					'security_groups' => ['default'],
				},
			},
		},
	) };

	my $claims = $hook->network->{subnets}{'ocfp-0'}{claims};
	is($claims->{'ocfp-bosh'}, '10.0.0.5',
		'the claim is recorded under the name that reaches the cloud config');
	ok(!exists $claims->{$legacy},
		'and the legacy spelling is deleted rather than left beside it');
	cmp_deeply($hook->network->{subnets}{'ocfp-1'}{claims}, {
		'test-env-mgmt.bosh.net-compilation' => '10.0.1.37-10.0.1.40',
	}, 'another network\'s claim is untouched by the migration');
};

subtest 'network_definition - a legacy-keyed claim is still our own' => sub {
	plan tests => 3;

	my $own_claim = '10.0.1.100-10.0.1.163'; # 64 addresses, ours, on ocfp-1

	# As the self-claim subtest above, but the claim is filed under the
	# spelling an earlier release used while the network now answers to a
	# name_prefix.  Counting it as foreign is what shrank the pool and bailed
	# with 'Not enough available IPs' on the second deploy.
	my $size_ocfp_1 = sub {
		my ($with_legacy_claim) = @_;
		my $env = make_deploy_env(
			config => {
				params => {cloud_config_prefix => 'test-env.test'},
				'bosh-configs' => {
					cloud => {networks => {bosh => {allocation => {size => 0}}}},
				},
			},
			director_exodus_lookup => sub {
				my ($self, $key) = @_;
				die "Unknown exodus key: $key" unless $key eq '/network';
				my $network = dclone($director_network_exodus);
				$network->{subnets}{'ocfp-1'}{claims}{$self->name.'.bosh.net-bosh'} = $own_claim
					if $with_legacy_claim;
				return $network;
			},
		);
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

		my ($net, $warn);
		$warn = stderr_from {
			$net = $hook->network_definition('bosh',
				strategy => 'ocfp',
				name_prefix => 'ocfp-',
				dynamic_subnets => {
					allocation => {size => 8, statics => 0},
					cloud_properties_for_iaas => {
						openstack => {
							'net_id'          => $hook->network_reference('id'),
							'security_groups' => ['default'],
						},
					},
				},
			);
		};
		return $warn;
	};

	my ($alone) = $size_ocfp_1->(0) =~ /(\d+)\s+claimed\s+by\s+other\s+networks/s;
	is($alone, 4,
		'with no claim of ours, other networks hold the director\'s four addresses');

	my ($with_legacy) = $size_ocfp_1->(1) =~ /(\d+)\s+claimed\s+by\s+other\s+networks/s;
	ok(defined $with_legacy, 'the run with a legacy-keyed claim still reports the figure');
	is($with_legacy, $alone,
		'which is unchanged, so the legacy spelling is recognised as our own claim');
};

# ---------------------------------------------------------------------------
# Logical Subnet Amalgamation
#
# BOSH refuses two subnets that share a range inside one network, so Genesis
# folds same-range subnets into a single subnet carrying a list of AZs.  The
# shape below is the one the OCFP CLI's PVE provider writes: bridge mode
# adopts an existing vnet and never brings up per-child L3, so every child
# record carries the parent range and the parent gateway, and only the AZ and
# the available band distinguish them.
# ---------------------------------------------------------------------------

# lsa_subnet - one child of an amalgamation, in the shape _subnet_definition
# builds and _build_logical_subnet_amalgamation consumes.  The reserved spans
# leave a single 24-address window open, mirroring how the provider carves one
# band per AZ out of a shared parent range.
sub lsa_subnet {
	my (%overrides) = @_;
	return {
		name             => 'ocfp-0',
		range            => '10.0.0.0/22',
		gateway          => '10.0.0.1',
		az               => 'z1',
		dns              => ['10.0.0.2'],
		reserved         => ['10.0.0.0-10.0.0.95', '10.0.0.120-10.0.3.255'],
		static           => ['10.0.0.96-10.0.0.98'],
		cloud_properties => {bridge => 'vmbr0'},
		%overrides,
	};
}

subtest '_build_logical_subnet_amalgamation - folds two same-range subnets into one' => sub {
	plan tests => 6;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $lsa = $hook->_build_logical_subnet_amalgamation('test.net-ocf', [
		lsa_subnet(),
		lsa_subnet(
			name     => 'ocfp-1',
			az       => 'z2',
			reserved => ['10.0.0.0-10.0.1.95', '10.0.1.120-10.0.3.255'],
			static   => ['10.0.1.96-10.0.1.98'],
		),
	]);

	ok($lsa, 'the amalgamation returns a subnet');
	is($lsa->{range}, '10.0.0.0/22', 'the merged subnet keeps the shared range');
	is($lsa->{gateway}, '10.0.0.1', 'and the shared gateway');
	cmp_deeply($lsa->{azs}, ['z1', 'z2'],
		'both AZs come through on the single merged subnet');
	cmp_deeply($lsa->{reserved}, [
		'10.0.0.0-10.0.0.95', '10.0.0.120-10.0.1.95', '10.0.1.120-10.0.3.255'
	], 'the reserved spans are the parent range minus both available bands, so neither band is lost');
	cmp_deeply($lsa->{cloud_properties}, {bridge => 'vmbr0'},
		'the agreed cloud properties survive the merge');
};

subtest '_build_logical_subnet_amalgamation - unions an azs list as well as a bare az' => sub {
	plan tests => 1;

	# _subnet_definition builds a child with either an `az` scalar or an `azs`
	# list, depending on which key the network fields declare.  Reading `az`
	# alone put an undef in the merged list for the second shape.
	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $second = lsa_subnet(
		name     => 'ocfp-1',
		reserved => ['10.0.0.0-10.0.1.95', '10.0.1.120-10.0.3.255'],
		static   => ['10.0.1.96-10.0.1.98'],
		azs      => ['z2', 'z3'],
	);
	delete $second->{az};

	my $lsa = $hook->_build_logical_subnet_amalgamation('test.net-ocf', [
		lsa_subnet(), $second,
	]);

	cmp_deeply($lsa->{azs}, ['z1', 'z2', 'z3'],
		'every AZ is listed once and no undef entry creeps in');
};

subtest '_build_logical_subnet_amalgamation - refuses subnets that disagree on cloud properties' => sub {
	plan tests => 4;

	# A BOSH subnet carries one cloud_properties hash for every AZ in it, so
	# two children naming different bridges are describing two wires and
	# cannot be represented as one subnet.  Taking the first child's bridge
	# would attach the other AZ's VMs to the wrong network silently.
	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	throws_ok {
		$hook->_build_logical_subnet_amalgamation('test.net-ocf', [
			lsa_subnet(),
			lsa_subnet(
				name             => 'ocfp-1',
				az               => 'z2',
				reserved         => ['10.0.0.0-10.0.1.95', '10.0.1.120-10.0.3.255'],
				static           => ['10.0.1.96-10.0.1.98'],
				cloud_properties => {bridge => 'vmbr1'},
			),
		]);
	} qr/Cannot create LSA for subnets with different cloud properties/,
		'the merge bails rather than picking one child\'s properties';

	my $err = $@;
	like($err, qr/bridge/, 'the message names the property that differs');
	like($err, qr/'vmbr0' on ocfp-0/, 'and which subnet carries which value');
	like($err, qr/'vmbr1' on ocfp-1/, 'for both of them');
};

subtest '_build_logical_subnet_amalgamation - an absent cloud_properties key is not a difference' => sub {
	plan tests => 2;

	# _subnet_definition deletes cloud_properties outright when the IaaS branch
	# resolves to nothing, so a child with no key and a child with an empty one
	# describe the same wire and must still merge.
	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $bare = lsa_subnet(
		name     => 'ocfp-1',
		az       => 'z2',
		reserved => ['10.0.0.0-10.0.1.95', '10.0.1.120-10.0.3.255'],
		static   => ['10.0.1.96-10.0.1.98'],
	);
	delete $bare->{cloud_properties};

	my $lsa;
	lives_ok {
		$lsa = $hook->_build_logical_subnet_amalgamation('test.net-ocf', [
			lsa_subnet(cloud_properties => {}), $bare,
		]);
	} 'an empty hash and a missing key merge without complaint';
	ok(!exists $lsa->{cloud_properties},
		'and the merged subnet carries no cloud_properties of its own');
};

subtest '_process_network_subnets - groups by range and leaves distinct ranges alone' => sub {
	plan tests => 4;

	my $env  = make_deploy_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $network = {
		name    => 'test.net-ocf',
		subnets => [
			lsa_subnet(),
			lsa_subnet(
				name     => 'ocfp-1',
				az       => 'z2',
				reserved => ['10.0.0.0-10.0.1.95', '10.0.1.120-10.0.3.255'],
				static   => ['10.0.1.96-10.0.1.98'],
			),
			lsa_subnet(
				name     => 'ocfp-2',
				az       => 'z3',
				range    => '10.0.8.0/22',
				gateway  => '10.0.8.1',
				reserved => ['10.0.8.0-10.0.8.95', '10.0.8.120-10.0.11.255'],
				static   => ['10.0.8.96-10.0.8.98'],
			),
		],
	};

	$hook->_process_network_subnets([$network]);

	is(scalar @{$network->{subnets}}, 2,
		'the two subnets sharing a range become one, and the third stays on its own');
	cmp_deeply($network->{subnets}[0]{azs}, ['z1', 'z2'],
		'the merged subnet carries both of its AZs');
	is($network->{subnets}[1]{range}, '10.0.8.0/22',
		'the unmerged subnet keeps its own range');
	ok(!exists $network->{subnets}[1]{name},
		'and loses the name, which BOSH has no use for');
};

# ---------------------------------------------------------------------------
# Overrides against a bare kit target name
#
# _add_extended_cloud_config decides whether an override under
# bosh-configs.cloud names an entry the kit already registered or asks for a
# new one, and a new network is refused because additional networks are not
# supported.  A kit registers under the prefixed form name_for produces unless
# it passes network_definition an empty name_prefix, which the blacksmith kit
# does for valkey-service because the valkey-forge release hardcodes that
# network name.  An override keyed by the bare target then has to be
# recognised as naming that entry; matching only the prefixed form read it as
# a new network and refused an override an operator legitimately wrote.
# ---------------------------------------------------------------------------

# extended_env - an environment whose only cloud override is one network, and
# a cloud config that already carries the entries named.
sub extended_env {
	my ($override_target, @registered) = @_;
	my $env = make_deploy_env(
		config => {
			'bosh-configs' => {
				cloud => {networks => {$override_target => {allocation => {size => 8}}}},
			},
		},
	);
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);
	return ($hook, {networks => [map {{name => $_}} @registered]});
}

subtest '_add_extended_cloud_config - an override keyed by a bare target names the kit entry' => sub {
	plan tests => 3;

	# The blacksmith case: registered bare, overridden bare.
	my ($bare, $bare_config) = extended_env('valkey-service', 'valkey-service');
	lives_ok { $bare->_add_extended_cloud_config($bare_config) }
		'an override keyed by the bare name the kit registered is a match, not a new network';

	# The ordinary case, where the kit let the naming default.
	my ($pfx, $pfx_config) = extended_env('bosh');
	push @{$pfx_config->{networks}}, {name => $pfx->name_for('net', 'bosh')};
	lives_ok { $pfx->_add_extended_cloud_config($pfx_config) }
		'an override keyed by the target still matches the prefixed form the kit registered';

	# The guard: accepting the bare target must not accept every override.
	my ($new, $new_config) = extended_env('nowhere', 'valkey-service');
	throws_ok { $new->_add_extended_cloud_config($new_config) }
		qr/network definitions are not supported yet.*nowhere/s,
		'an override naming no registered entry is still refused as a new network';
};

subtest 'network_definition - statics take the front of the allocation' => sub {
	plan tests => 3;

	# ocfp-1 has the director's compilation claim on .37-.40, so an allocation
	# of four lands on .41-.44.  The target has no reserved-ips records, so
	# nothing joins the static list from that side.
	my $subnet_for = sub {
		my ($statics) = @_;
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => make_deploy_env());
		my $net = $hook->network_definition('app',
			strategy => 'ocfp',
			dynamic_subnets => {
				subnets    => ['ocfp-1'],
				allocation => {size => 4, statics => $statics},
				cloud_properties_for_iaas => {openstack => {'net_id' => 'x'}},
			},
		);
		return $net->{subnets}[0];
	};

	is_deeply($subnet_for->(2)->{static}, ['10.0.1.41-10.0.1.42'],
		'a count of statics is the first addresses of the allocation');
	is_deeply($subnet_for->('50%')->{static}, ['10.0.1.41-10.0.1.42'],
		'a percentage of statics is that fraction of the allocation');
	ok(!exists $subnet_for->(0)->{static},
		'no statics leaves the static key off the subnet');
};

subtest '_calculate_subnet_allocation - growing and shrinking a claim' => sub {
	plan tests => 7;

	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => make_deploy_env());
	my $pool = IPv4->new('10.0.0.10-10.0.0.100');
	my $calc = sub {
		my ($existing, $count) = @_;
		return $hook->_calculate_subnet_allocation('net', $pool, IPv4->new($existing), $count)->range;
	};

	is($calc->('10.0.0.10-10.0.0.17', 4), '10.0.0.10-10.0.0.13',
		'shrinking a claim at the front of the pool keeps its lowest addresses');
	is($calc->('10.0.0.40-10.0.0.47', 4), '10.0.0.40-10.0.0.43',
		'shrinking a claim that sits after a gap keeps its own lowest addresses, not the pool\'s');
	is($calc->('10.0.0.40-10.0.0.47', 0), '',
		'shrinking a claim to nothing yields an empty range');
	is($calc->('10.0.0.40-10.0.0.43', 8), '10.0.0.10-10.0.0.13,10.0.0.40-10.0.0.43',
		'growing a claim keeps it and appends from the pool');
	is($calc->('10.0.0.40-10.0.0.47', 8), '10.0.0.40-10.0.0.47',
		'a claim already at the requested size is returned unchanged');
	throws_ok { $calc->('10.0.0.40-10.0.0.47', -1) }
		qr/allocation for network 'net' must not be negative/,
		'a negative allocation is refused rather than releasing the claim';
	is($calc->('10.0.0.10-10.0.0.13', 8), '10.0.0.10-10.0.0.17',
		'growing a claim at the front of the pool takes new addresses instead of counting its own');
};


# ---------------------------------------------------------------------------
# Lab claims
#
# A director's network exodus, reserved-ips records, and kit network
# definitions shaped like a three-band PVE lab on one /24, so the claims model
# can be exercised on the claim shapes a long-lived director accumulates.
# Each band carries the 3-compact reserved-ips layout: the subnet-reserved and
# available pairs, the bosh, jumpbox, blacksmith, and haproxy triples,
# director_ip, a bare ip, and scheme_version.
#
# %LAB is keyed by director, and $LAB_DIRECTOR picks the one the lab_* helpers
# work on, so another director's fixture is one more entry plus a
# `local $LAB_DIRECTOR = ...` in its subtests.  The mgmt entry models the mgmt
# director, whose carve gives every service a triple on adjacent addresses.
# ---------------------------------------------------------------------------

{
	# The lab's kit hooks, reduced to the network each one defines.  Each
	# lab_network method calls network_definition with the arguments the real
	# kit passes; allocation overrides come from the env file, as they do in a
	# real render.
	package Genesis::Hook::CloudConfig::LabCF;
	use parent -norequire, 'Genesis::Hook::CloudConfig';
	# The cf kit points its ocf network at the carve's haproxy records when the
	# haproxy feature is on, which it is in the lab.
	sub ocfp_reserved_ip_target_aliases {
		my ($self, $target) = @_;
		return ['haproxy'] if $target =~ /^ocf(-edge)?$/;
		return;
	}
	sub lab_network {
		my ($self, %opts) = @_;
		return $self->network_definition('ocf', strategy => 'ocfp',
			dynamic_subnets => {
				subnets                   => ['ocfp-0', 'ocfp-1', 'ocfp-2'],
				cloud_properties_for_iaas => {pve => {bridge => 'vlan54'}},
				allocation                => {size => 15, statics => $opts{statics} // 3},
			},
		);
	}

	package Genesis::Hook::CloudConfig::LabAutoscaler;
	use parent -norequire, 'Genesis::Hook::CloudConfig';
	sub lab_network {
		return $_[0]->network_definition('autoscaler', strategy => 'ocfp',
			dynamic_subnets => {
				allocation                => {size => 7},
				cloud_properties_for_iaas => {pve => {bridge => 'vlan54'}},
			},
		);
	}

	package Genesis::Hook::CloudConfig::LabScheduler;
	use parent -norequire, 'Genesis::Hook::CloudConfig';
	sub lab_network {
		return $_[0]->network_definition('scheduler', strategy => 'ocfp',
			dynamic_subnets => {
				allocation                => {size => 2, statics => 0},
				cloud_properties_for_iaas => {pve => {bridge => 'vlan54'}},
			},
		);
	}

	package Genesis::Hook::CloudConfig::LabBlacksmith;
	use parent -norequire, 'Genesis::Hook::CloudConfig';
	sub lab_network {
		return $_[0]->network_definition('blacksmith', strategy => 'ocfp',
			dynamic_subnets => {
				subnets                   => ['ocfp-1'],
				allocation                => {size => 0, statics => 0},
				cloud_properties_for_iaas => {pve => {bridge => 'vlan54'}},
			},
		);
	}

	package Genesis::Hook::CloudConfig::LabValkey;
	use parent -norequire, 'Genesis::Hook::CloudConfig';
	sub lab_network {
		return $_[0]->network_definition('valkey-service', strategy => 'ocfp',
			name_prefix     => '',
			dynamic_subnets => {
				subnets                   => ['ocfp-1'],
				allocation                => {size => 0, statics => 0},
				cloud_properties_for_iaas => {pve => {bridge => 'vlan54'}},
			},
		);
	}

	package Genesis::Hook::CloudConfig::LabDirector;
	use parent -norequire, 'Genesis::Hook::CloudConfig::Director';
	sub lab_network {
		return $_[0]->network_definition('compilation', strategy => 'ocfp',
			dynamic_subnets => {
				subnets                   => ['ocfp-2'],
				allocation                => {size => 4, statics => 0},
				cloud_properties_for_iaas => {pve => {bridge => 'vlan54'}},
			},
		);
	}

	# The bosh kit's parent-side config for the ocf director, built on the
	# mgmt director: one address for the director on each subnet, from the
	# pool the mgmt carve leaves free
	package Genesis::Hook::CloudConfig::LabOcfBosh;
	use parent -norequire, 'Genesis::Hook::CloudConfig';
	sub lab_network {
		return $_[0]->network_definition('bosh', strategy => 'ocfp',
			dynamic_subnets => {
				allocation                => {size => 0, statics => 0},
				cloud_properties_for_iaas => {pve => {bridge => 'vlan54'}},
			},
		);
	}

	# A deploy hook asking for a network called compilation, which the
	# director-only exemption must not cover
	package Genesis::Hook::CloudConfig::LabCompilationDeploy;
	use parent -norequire, 'Genesis::Hook::CloudConfig';
	sub lab_network {
		return $_[0]->network_definition('compilation', strategy => 'ocfp',
			dynamic_subnets => {
				subnets                   => ['ocfp-2'],
				allocation                => {size => 4, statics => 0},
				cloud_properties_for_iaas => {pve => {bridge => 'vlan54'}},
			},
		);
	}

	# The concourse kit on PVE: every VM in ocfp-0, the web node on the
	# reserved concourse_ip static, and four dynamic addresses for the rest
	package Genesis::Hook::CloudConfig::LabConcourse;
	use parent -norequire, 'Genesis::Hook::CloudConfig';
	sub lab_network {
		return $_[0]->network_definition('concourse', strategy => 'ocfp',
			dynamic_subnets => {
				subnets                   => ['ocfp-0'],
				allocation                => {total_size => 4},
				cloud_properties_for_iaas => {pve => {bridge => 'vlan54'}},
			},
		);
	}
}

# lab_band - one /24 band's ocfp subnet record, with its 3-compact reserved-ips
sub lab_band {
	my ($prefix, $base, $az) = @_;
	my $a = sub { $prefix . ($base + $_[0]) };
	return {
		az => $az, cidr_block => "${prefix}0/24", gateway => "${prefix}1",
		dns => ['10.97.160.160', '10.97.160.161'],
		'reserved-ips' => {
			reserved_0  => $a->(0),  reserved_1  => $a->(35),
			available_0 => $a->(36), available_1 => $a->(62),
			bosh_a       => $a->(22), bosh_ip       => $a->(23), bosh_b       => $a->(24),
			director_ip  => $a->(23), ip            => $a->(23),
			jumpbox_a    => $a->(24), jumpbox_ip    => $a->(25), jumpbox_b    => $a->(26),
			blacksmith_a => $a->(25), blacksmith_ip => $a->(26), blacksmith_b => $a->(27),
			haproxy_a    => $a->(36), haproxy_ip    => $a->(37), haproxy_b    => $a->(38),
			scheme_version => '3-compact',
		},
	};
}

our $LAB_DIRECTOR = 'ocf';
my %LAB = (
	ocf => {
		env_name => 'ocfp-cf1-lab-ocf',
		create_env => 0,
		prefix   => '10.61.148.',
		# The targets whose _ip records lab_assert_disjoint_and_record_clean checks
		record_owners => [qw(bosh jumpbox blacksmith haproxy)],
		bands    => {'ocfp-0' => [64, 'pvupvecf101'], 'ocfp-1' => [128, 'pvupvecf102'], 'ocfp-2' => [192, 'pvupvecf103']},
		# The owner of each reserved-ips record that a network may hold, by claim key
		record_holders => {
			haproxy    => 'ocfp-cf1-lab-ocf.cf.net-ocf',
			blacksmith => 'ocfp-cf1-lab-ocf.blacksmith.net-blacksmith',
		},
		networks => {
			cf            => {class => 'LabCF',         type => 'cf',         claim => 'ocfp-cf1-lab-ocf.cf.net-ocf',
			                  overrides => {ocf => {allocation => {total_size => 45}}}},
			'cf-4statics' => {class => 'LabCF',         type => 'cf',         claim => 'ocfp-cf1-lab-ocf.cf.net-ocf',
			                  overrides => {ocf => {allocation => {total_size => 45}}}, statics => 4},
			autoscaler    => {class => 'LabAutoscaler', type => 'autoscaler', claim => 'ocfp-cf1-lab-ocf.autoscaler.net-autoscaler',
			                  overrides => {autoscaler => {allocation => {vms_per_subnet => {'ocfp-0' => 7}}}}},
			scheduler     => {class => 'LabScheduler',  type => 'scheduler',  claim => 'ocfp-cf1-lab-ocf.scheduler.net-scheduler'},
			blacksmith    => {class => 'LabBlacksmith', type => 'blacksmith', claim => 'ocfp-cf1-lab-ocf.blacksmith.net-blacksmith'},
			valkey        => {class => 'LabValkey',     type => 'blacksmith', claim => 'valkey-service',
			                  overrides => {'valkey-service' => {allocation => {size => 8}}}},
			compilation   => {class => 'LabDirector',   type => 'bosh',       claim => 'ocfp-cf1-lab-ocf.bosh.net-compilation',
			                  director => 1},
			'compilation-deploy' => {class => 'LabCompilationDeploy', type => 'bosh',
			                  claim => 'ocfp-cf1-lab-ocf.bosh.net-compilation'},
		},
		# The director's saved claims, as read from its network exodus
		claims_today => {
			'ocfp-0' => {
				'ocfp-cf1-lab-ocf.cf.net-ocf'                 => '10.61.148.100-10.61.148.114',
				'ocfp-cf1-lab-ocf.autoscaler.net-autoscaler'  => '10.61.148.115-10.61.148.121',
				'ocfp-cf1-lab-ocf.scheduler.net-scheduler'    => '10.61.148.122-10.61.148.123',
			},
			'ocfp-1' => {
				'ocfp-cf1-lab-ocf.blacksmith.net-blacksmith'  => '10.61.148.154',
				'ocfp-cf1-lab-ocf.cf.net-ocf'                 => '10.61.148.164-10.61.148.178',
				'valkey-service'                              => '10.61.148.179-10.61.148.186',
				'ocfp-cf1-lab-ocf.scheduler.net-scheduler'    => '10.61.148.187-10.61.148.188',
			},
			'ocfp-2' => {
				'ocfp-cf1-lab-ocf.bosh.net-compilation'       => '10.61.148.228-10.61.148.231',
				'ocfp-cf1-lab-ocf.cf.net-ocf'                 => '10.61.148.229,10.61.148.232-10.61.148.245',
				'ocfp-cf1-lab-ocf.scheduler.net-scheduler'    => '10.61.148.246-10.61.148.247',
			},
		},
		# What changes once the compilation network gives up the address CF's
		# haproxy record holds
		claims_repaired => {
			'ocfp-2' => {compilation => '10.61.148.228,10.61.148.230-10.61.148.231,10.61.148.248'},
		},
	},
);

my %LAB_STATE; # claims and extra reserved-ips records the lab_* helpers work on
sub lab { return $LAB{$LAB_DIRECTOR} // die "No lab fixture for director '$LAB_DIRECTOR'"; }

# lab_ocfp_config - the ocfp net config, with any records lab_add_record added
sub lab_ocfp_config {
	my $lab = lab();
	my %subnets = map {
		($_ => ($lab->{band} // \&lab_band)->($lab->{prefix}, @{$lab->{bands}{$_}}))
	} keys %{$lab->{bands}};
	for my $subnet (keys %{$LAB_STATE{records} // {}}) {
		my $extra = $LAB_STATE{records}{$subnet};
		$subnets{$subnet}{'reserved-ips'}{$_} = $extra->{$_} for keys %$extra;
	}
	my %azs = map {
		my $az = $lab->{bands}{$_}[1];
		($az => {index => ($az =~ /(\d)$/)[0]})
	} keys %{$lab->{bands}};
	return {net => {topology => 'v2', subnets => \%subnets, azs => \%azs}};
}

# lab_claims_today - a fresh copy of the director's saved claims
sub lab_claims_today { return dclone(lab()->{claims_today}); }

# lab_claims_repaired - today's claims after the compilation network's repair
sub lab_claims_repaired {
	my $claims = lab_claims_today();
	my $repair = lab()->{claims_repaired};
	for my $subnet (keys %$repair) {
		$claims->{$subnet}{lab()->{networks}{$_}{claim}} = $repair->{$subnet}{$_}
			for keys %{$repair->{$subnet}};
	}
	return $claims;
}

# lab_reset_claims - start from these claims (none if omitted), with optional
# per-subnet claims laid over them, and drop any records lab_add_record added
sub lab_reset_claims {
	my ($claims, %over) = @_;
	$claims = $claims ? dclone($claims) : {};
	$claims->{$_} //= {} for keys %{lab()->{bands}};
	for my $subnet (keys %over) {
		for my $net (keys %{$over{$subnet}}) {
			my $key = lab()->{networks}{$net} ? lab()->{networks}{$net}{claim} : $net;
			$claims->{$subnet}{$key} = $over{$subnet}{$net};
		}
	}
	%LAB_STATE = (claims => $claims, records => {});
}

# lab_add_record - add a reserved-ips record to one subnet of the lab
sub lab_add_record {
	my ($subnet, $key, $value) = @_;
	$LAB_STATE{records}{$subnet}{$key} = $value;
}

# lab_exodus - the director's network exodus over the current claims
sub lab_exodus {
	my $lab = lab();
	my %azs = map {
		my $az = $lab->{bands}{$_}[1];
		my $idx = ($az =~ /(\d)$/)[0];
		($az => {name => "$lab->{env_name}-z$idx", index => $idx})
	} keys %{$lab->{bands}};
	my %subnets = map {
		($_ => {
			az     => $lab->{bands}{$_}[1],
			range  => IPv4->new("$lab->{prefix}0/24")->range,
			claims => dclone($LAB_STATE{claims}{$_} // {}),
		})
	} keys %{$lab->{bands}};
	return {azs => \%azs, subnets => \%subnets};
}

# lab_env - an environment of the given type, with these env file overrides,
# deployed with create-env if $create_env is given and true, or if it is not
# given and the lab's create_env is true
my $lab_seq = 0;
sub lab_env {
	my ($type, $overrides, $create_env, $env_name) = @_;
	my $lab = lab();
	my $ocfp = lab_ocfp_config();
	my $config = {
		params => {},
		'bosh-configs' => {cloud => {networks => $overrides // {}}},
	};
	return mock "Genesis::Env" => {
		name           => $env_name // $lab->{env_name},
		type           => $type,
		kit            => $kit,
		bosh           => mock("Genesis::BOSH" => {alias => $lab->{env_name}}),
		use_create_env => $create_env // $lab->{create_env},
		features       => Mock::ReferencedValue->new(['ocfp', 'haproxy']),
		iaas           => 'pve',
		scale          => 'dev',
		is_ocfp        => 1,
		config         => $config,

		env_config_overrides      => sub { $config->{'bosh-configs'}{$_[1]} // {} },
		director_config_overrides => {},
		ocfp_subnet_prefix        => 'ocfp',
		ocfp_config               => $ocfp,

		lookup => sub {
			my ($self, $key, $default) = @_;
			return scalar struct_lookup($config, $key, $default);
		},
		ocfp_config_lookup => sub {
			my ($self, $key, $default) = @_;
			return scalar struct_lookup($ocfp, $key, $default);
		},
		director_exodus_lookup => sub {
			my ($self, $key) = @_;
			return lab_exodus() if $key eq '/network';
			die "Unknown director exodus key: $key";
		},
		exodus_lookup_strict => sub {
			my ($self, $key) = @_;
			return lab_exodus() if $key eq '/network:.';
			return undef;
		},
		cpi_enabled => 0,
		cpi_name    => undef,
	};
}

# lab_run_net_with_stderr - build one lab network on the current claims and
# save its claims back, as a deploy would; returns the network definition and
# whatever the build printed on stderr.  A build that bails saves nothing.
sub lab_run_net_with_stderr {
	my ($name, %opts) = @_;
	my $spec = lab()->{networks}{$name} or die "No lab network '$name'";
	my $overrides = dclone($spec->{overrides} // {});
	if (defined $opts{total_size}) {
		$overrides->{ocf}{allocation}{total_size} = $opts{total_size};
	}
	my $env = lab_env($spec->{type}, $overrides, $spec->{create_env}, $spec->{env_name});
	my $class = "Genesis::Hook::CloudConfig::$spec->{class}";

	my ($hook, $net);
	my $err = stderr_from {
		if ($spec->{director}) {
			$hook = $class->init(env => $env, purpose => 'director');
			# A real build is a fresh process, but the hook cache hands back the
			# director hook from the last build.  Point it at this run's env and
			# rebuild what init read from the env, so it sees this run's claims and
			# reserved-ips records rather than those of the first build.
			$hook->{env} = $env;
			delete @$hook{qw(subnets features __exodus_data)};
			$hook->{overrides} = {
				environment => $env->env_config_overrides('cloud'),
				director    => $env->director_config_overrides('cloud'),
			};
			$hook->{ocfp_config} = $env->ocfp_config_lookup(['net', 'vpc']);
			$hook->{network} = {};
			$hook->_set_network_azs();
			$hook->_set_network_subnets();
		} else {
			# A distinct purpose keeps the hook cache from handing back the last
			# build of the same deployment, without changing any network name
			$hook = $class->init(env => $env, purpose => 'lab-'.(++$lab_seq));
		}
		$net = $hook->lab_network(statics => $spec->{statics});
	};
	$LAB_STATE{claims} = {map {
		($_ => dclone($hook->network->{subnets}{$_}{claims} // {}))
	} keys %{lab()->{bands}}};
	return ($net, $err);
}

# lab_run_net - lab_run_net_with_stderr without the stderr
sub lab_run_net {
	my ($net) = lab_run_net_with_stderr(@_);
	return $net;
}

# lab_claims_snapshot - the saved claims after the last build
sub lab_claims_snapshot { return dclone($LAB_STATE{claims}); }

# lab_claim - one network's saved claim on one subnet
sub lab_claim {
	my ($subnet, $name) = @_;
	return $LAB_STATE{claims}{$subnet}{lab()->{networks}{$name}{claim}};
}

# lab_assert_disjoint_and_record_clean - no two claims on a subnet share an
# address, and no claim holds a reserved-ips record of a target it isn't.
# Counts as one test.
sub lab_assert_disjoint_and_record_clean {
	my ($label) = @_;
	my $lab = lab();
	my $ocfp = lab_ocfp_config();
	my @problems;
	for my $subnet (sort keys %{$LAB_STATE{claims}}) {
		my $claims = $LAB_STATE{claims}{$subnet};
		my @keys = sort keys %$claims;
		for my $i (0 .. $#keys) {
			for my $j ($i+1 .. $#keys) {
				my $x = IPv4->range(IPv4->new($claims->{$keys[$i]}));
				my $shared = IPv4->range($x - (IPv4->range($x) - IPv4->new($claims->{$keys[$j]})));
				push @problems, "$subnet: $keys[$i] and $keys[$j] share ".$shared->range
					if $shared->size;
			}
		}
		my $records = $ocfp->{net}{subnets}{$subnet}{'reserved-ips'};
		for my $owner (@{$lab->{record_owners}}) {
			my $record = IPv4->new($records->{"${owner}_ip"});
			for my $key (@keys) {
				next if ($lab->{record_holders}{$owner} // '') eq $key;
				my $claim = IPv4->range(IPv4->new($claims->{$key}));
				push @problems, "$subnet: $key holds the $owner record ".$records->{"${owner}_ip"}
					if $claim->size && ($claim - $record)->size < $claim->size;
			}
		}
	}
	is_deeply(\@problems, [], "claims are disjoint and record-clean after $label");
}

# lab_cf_statics_today - the static lists CF renders today, one per subnet
sub lab_cf_statics_today {
	return [map {$_->{static}} @{lab_golden('cf')->{subnets}}];
}

# lab_golden - how each lab network renders on today's claims
sub lab_golden {
	my ($name) = @_;
	return dclone(lab()->{golden}{$name} // die "No golden render for '$name'");
}


# lab_subnet - one rendered subnet of a lab network, as network_definition
# returns it before the subnets are folded for BOSH
sub lab_subnet {
	my ($name, $zone, $reserved, $static) = @_;
	my $lab = lab();
	return {
		name             => $name,
		az               => "$lab->{env_name}-z$zone",
		range            => "$lab->{prefix}0/24",
		gateway          => "$lab->{prefix}1",
		dns              => ['10.97.160.160', '10.97.160.161'],
		cloud_properties => {bridge => 'vlan54'},
		reserved         => $reserved,
		($static ? (static => $static) : ()),
	};
}

# How each lab network renders on today's claims, captured from the claims
# model as it stood before reserved-ips records of other targets were taken
# out of a network's free pool.  The renders agree with the lab's real kit
# hooks on the same claims.
$LAB{ocf}{golden} = {
	cf => {name => 'ocfp-cf1-lab-ocf.cf.net-ocf', type => 'manual', subnets => [
		lab_subnet('ocfp-0', 1, ['10.61.148.0-10.61.148.99', '10.61.148.115-10.61.148.255'],
		                        ['10.61.148.100-10.61.148.102']),
		lab_subnet('ocfp-1', 2, ['10.61.148.0-10.61.148.163', '10.61.148.179-10.61.148.255'],
		                        ['10.61.148.164-10.61.148.166']),
		lab_subnet('ocfp-2', 3, ['10.61.148.0-10.61.148.228', '10.61.148.230-10.61.148.231', '10.61.148.246-10.61.148.255'],
		                        ['10.61.148.229', '10.61.148.232-10.61.148.233']),
	]},
	'cf-4statics' => {name => 'ocfp-cf1-lab-ocf.cf.net-ocf', type => 'manual', subnets => [
		lab_subnet('ocfp-0', 1, ['10.61.148.0-10.61.148.99', '10.61.148.115-10.61.148.255'],
		                        ['10.61.148.100-10.61.148.103']),
		lab_subnet('ocfp-1', 2, ['10.61.148.0-10.61.148.163', '10.61.148.179-10.61.148.255'],
		                        ['10.61.148.164-10.61.148.167']),
		lab_subnet('ocfp-2', 3, ['10.61.148.0-10.61.148.228', '10.61.148.230-10.61.148.231', '10.61.148.246-10.61.148.255'],
		                        ['10.61.148.229', '10.61.148.232-10.61.148.234']),
	]},
	autoscaler => {name => 'ocfp-cf1-lab-ocf.autoscaler.net-autoscaler', type => 'manual', subnets => [
		lab_subnet('ocfp-0', 1, ['10.61.148.0-10.61.148.114', '10.61.148.122-10.61.148.255']),
	]},
	scheduler => {name => 'ocfp-cf1-lab-ocf.scheduler.net-scheduler', type => 'manual', subnets => [
		lab_subnet('ocfp-0', 1, ['10.61.148.0-10.61.148.121', '10.61.148.124-10.61.148.255']),
		lab_subnet('ocfp-1', 2, ['10.61.148.0-10.61.148.186', '10.61.148.189-10.61.148.255']),
		lab_subnet('ocfp-2', 3, ['10.61.148.0-10.61.148.245', '10.61.148.248-10.61.148.255']),
	]},
	blacksmith => {name => 'ocfp-cf1-lab-ocf.blacksmith.net-blacksmith', type => 'manual', subnets => [
		lab_subnet('ocfp-1', 2, ['10.61.148.0-10.61.148.153', '10.61.148.155-10.61.148.255'],
		                        ['10.61.148.154']),
	]},
	valkey => {name => 'valkey-service', type => 'manual', subnets => [
		lab_subnet('ocfp-1', 2, ['10.61.148.0-10.61.148.178', '10.61.148.187-10.61.148.255']),
	]},
	# The compilation network gives up 10.61.148.229, which is CF's haproxy
	# record, and takes the next free address in its place
	compilation => {name => 'ocfp-cf1-lab-ocf.bosh.net-compilation', type => 'manual', subnets => [
		lab_subnet('ocfp-2', 3, ['10.61.148.0-10.61.148.227', '10.61.148.229', '10.61.148.232-10.61.148.247', '10.61.148.249-10.61.148.255']),
	]},
};

subtest 'lab claims - every lab network renders as it does today' => sub {
	my @nets = qw(cf cf-4statics autoscaler scheduler blacksmith valkey);
	plan tests => 2 * @nets;
	for my $net (@nets) {
		lab_reset_claims(lab_claims_today());
		my $got = lab_run_net($net);
		is_deeply($got, lab_golden($net), "$net renders the same network");
		is_deeply(lab_claims_snapshot(), lab_claims_today(), "$net saves the same claims");
	}
};

subtest 'lab claims - the director compilation network gives up another target\'s record and nothing else' => sub {
	plan tests => 4;
	lab_reset_claims(lab_claims_today());
	my ($net, $err) = lab_run_net_with_stderr('compilation');
	is_deeply($net, lab_golden('compilation'), 'compilation renders without 10.61.148.229');
	is_deeply(lab_claims_snapshot(), lab_claims_repaired(),
		'only the compilation claim changes, to .228,.230-.231,.248');
	like($err, qr/net-compilation.*ocfp-2.*10\.61\.148\.229.*haproxy/s,
		'the warning names the network, the subnet, the address, and its owner');
	lab_run_net('compilation');
	is_deeply(lab_claims_snapshot(), lab_claims_repaired(), 'a second build changes nothing');
};

subtest 'lab claims - a CF rebuild keeps every claim and every static and names the stray compilation address' => sub {
	plan tests => 3;
	lab_reset_claims(lab_claims_today());
	my ($net, $err) = lab_run_net_with_stderr('cf');
	is_deeply(lab_claims_snapshot(), lab_claims_today(), 'no claim changes');
	is_deeply([map {$_->{static}} @{$net->{subnets}}],
		[['10.61.148.100-10.61.148.102'], ['10.61.148.164-10.61.148.166'], ['10.61.148.229', '10.61.148.232-10.61.148.233']],
		'the real kit statics stay where the running VMs are');
	like($err, qr/10\.61\.148\.229.*haproxy.*net-compilation/s,
		'the warning names the address, the owner, and the other network');
};

subtest 'lab claims - every other network renders the same after the compilation repair' => sub {
	my @nets = qw(cf cf-4statics autoscaler scheduler blacksmith valkey);
	plan tests => 2 * @nets;
	for my $net (@nets) {
		lab_reset_claims(lab_claims_repaired());
		my ($got, $err) = lab_run_net_with_stderr($net);
		is_deeply($got, lab_golden($net), "$net renders as it does today");
		unlike($err, qr/reserved-ips record for|both claim/, "$net warns of no reserved address or clash");
	}
};

subtest 'lab claims - a growing claim takes new addresses and keeps its statics' => sub {
	plan tests => 4;
	lab_reset_claims(lab_claims_repaired());
	my $net = lab_run_net('cf', total_size => 48);
	is(lab_claim('ocfp-0', 'cf'), '10.61.148.100-10.61.148.114,10.61.148.124',
		'ocfp-0 grows past the autoscaler and scheduler');
	is(lab_claim('ocfp-1', 'cf'), '10.61.148.164-10.61.148.178,10.61.148.189',
		'ocfp-1 grows past valkey-service and the scheduler');
	is(lab_claim('ocfp-2', 'cf'), '10.61.148.229,10.61.148.232-10.61.148.245,10.61.148.249',
		'ocfp-2 grows past the scheduler and compilation');
	is_deeply([map {$_->{static}} @{$net->{subnets}}], lab_cf_statics_today(), 'statics unchanged');
};

subtest 'lab claims - fresh claims are disjoint, record-clean, and stable in either order' => sub {
	my @lab_order = qw(compilation cf blacksmith valkey autoscaler scheduler);
	plan tests => 4;
	for my $order ([@lab_order], [reverse @lab_order]) {
		# Named loop variables: a build iterates IPv4 sets into $_, which would
		# overwrite the names in @$order through an aliased $_
		lab_reset_claims();
		for my $name (@$order) { lab_run_net($name) }
		lab_assert_disjoint_and_record_clean("@$order");
		my $snap = lab_claims_snapshot();
		for my $name (@$order) { lab_run_net($name) }
		is_deeply(lab_claims_snapshot(), $snap, "a second pass in order @$order changes nothing");
	}
};

subtest 'lab claims - a record added inside a persistent network claim stops the build' => sub {
	plan tests => 4;
	lab_reset_claims(lab_claims_today());
	lab_add_record('ocfp-1', nfs_ip => '10.61.148.182');
	throws_ok { lab_run_net('valkey') }
		qr/valkey-service.*ocfp-1.*10\.61\.148\.182.*nfs.*bosh vms.*GENESIS_ALLOW_CLAIM_PRUNE=valkey-service/s,
		'the bail names the network, subnet, address, owner, the check, and the opt-in';
	is_deeply(lab_claims_snapshot(), lab_claims_today(), 'nothing changed');
	local $ENV{GENESIS_ALLOW_CLAIM_PRUNE} = 'valkey-service';
	my (undef, $err) = lab_run_net_with_stderr('valkey');
	is(lab_claim('ocfp-1', 'valkey'), '10.61.148.179-10.61.148.181,10.61.148.183-10.61.148.186,10.61.148.189',
		'the opt-in drops .182 and refills');
	like($err, qr/valkey-service.*ocfp-1.*10\.61\.148\.182.*nfs.*GENESIS_ALLOW_CLAIM_PRUNE/s,
		'and warns what it dropped and why it was allowed');
};

subtest 'lab claims - the compilation exemption belongs to a director hook, not a deploy hook' => sub {
	plan tests => 2;
	# The same compilation claim that a director hook repairs with a warning
	lab_reset_claims(lab_claims_today());
	my $before = lab_claims_snapshot();
	throws_ok { lab_run_net('compilation-deploy') }
		qr/net-compilation.*10\.61\.148\.229.*haproxy.*GENESIS_ALLOW_CLAIM_PRUNE/s,
		'a deploy hook stops at a reserved address in a compilation claim';
	is_deeply(lab_claims_snapshot(), $before, 'and saves nothing');
};

subtest 'lab claims - two dynamic claims over the same addresses stop the build' => sub {
	plan tests => 2;
	lab_reset_claims(lab_claims_today(), 'ocfp-2' => {scheduler => '10.61.148.245-10.61.148.246'});
	my $before = lab_claims_snapshot();
	throws_ok { lab_run_net('scheduler') }
		qr/net-scheduler.*net-ocf.*both claim 10\.61\.148\.245 on subnet ocfp-2.*network claims lock/s,
		'the bail names both networks, the address, and the likely cause';
	is_deeply(lab_claims_snapshot(), $before, 'neither claim changed');
};

subtest '_all_reserved_ip_records - returns owner to records with aliases applied' => sub {
	plan tests => 4;
	my $subnet = {'reserved-ips' => {
		reserved_0  => '10.9.0.0',  reserved_1  => '10.9.0.35',      # subnet-reserved pair
		available_0 => '10.9.0.36', available_1 => '10.9.0.62',      # available pair
		reserved_a  => '10.9.0.250', reserved_b => '10.9.0.255',
		available_a => '10.9.0.100', available_b => '10.9.0.200',
		scheme_version => '3-compact',
		bosh_a => '10.9.0.22', bosh_ip => '10.9.0.23', bosh_b => '10.9.0.24',
		director_ip => '10.9.0.23', ip => '10.9.0.30',               # both name the director
		haproxy_ip => '10.9.0.37', haproxy_ip_a => '10.9.0.36', haproxy_ip_b => '10.9.0.38',
		web_a => '10.9.0.40', web_b => '10.9.0.44', web_c => '10.9.0.50', web_d => '10.9.0.53',
		router_static => 1,
		vault_ip => '10.9.0.60',
		lonely_a => '10.9.0.70',                                      # no closing _b
	}};
	my $ranges = sub { my ($h) = @_; return {map {($_ => $h->{$_}->range)} keys %$h} };

	my $plain = Genesis::Hook::CloudConfig::Bosh->init(env => make_deploy_env());
	is_deeply($ranges->($plain->_all_reserved_ip_records($subnet, 'app')), {
		bosh    => '10.9.0.23,10.9.0.30',
		haproxy => '10.9.0.37',
		web     => '10.9.0.41-10.9.0.43,10.9.0.51-10.9.0.52',
		vault   => '10.9.0.60',
	}, 'singles, exclusive pairs, and later letter pairs are read; neighbour notes, statics, and subnet keys are not');

	is_deeply([sort keys %{$plain->_all_reserved_ip_records($subnet, 'web')}], [qw(bosh haproxy vault)],
		'the asking target\'s own records are not another owner\'s');
	is_deeply([sort keys %{$plain->_all_reserved_ip_records($subnet, 'openbao')}], [qw(bosh haproxy web)],
		'a module alias (openbao to vault) counts as the target\'s own');

	lab_reset_claims(lab_claims_today());
	my $cf = Genesis::Hook::CloudConfig::LabCF->init(env => lab_env('cf'), purpose => 'lab-'.(++$lab_seq));
	is_deeply([sort keys %{$cf->_all_reserved_ip_records($subnet, 'ocf')}], [qw(bosh vault web)],
		'a kit alias (ocf to haproxy) counts as the target\'s own');
};

subtest '_get_reserved_allocation and _all_reserved_ip_records read every form the same way' => sub {
	my %forms = (
		'a single <owner>_ip'            => [bosh  => {bosh_ip => '10.9.0.23'},                         '10.9.0.23'],
		'an exclusive <owner>_a/_b pair' => [web   => {web_a => '10.9.0.40', web_b => '10.9.0.44'},     '10.9.0.41-10.9.0.43'],
		'later letter pairs'             => [web   => {web_a => '10.9.0.40', web_b => '10.9.0.44',
		                                               web_c => '10.9.0.50', web_d => '10.9.0.53'},     '10.9.0.41-10.9.0.43,10.9.0.51-10.9.0.52'],
		'director_ip for bosh'           => [bosh  => {director_ip => '10.9.0.30'},                     '10.9.0.30'],
		'a bare ip for bosh'             => [bosh  => {ip => '10.9.0.31'},                              '10.9.0.31'],
		'bosh_ip with director_ip'       => [bosh  => {bosh_ip => '10.9.0.23', director_ip => '10.9.0.30', ip => '10.9.0.31'},
		                                                                                                '10.9.0.23,10.9.0.30-10.9.0.31'],
		'an unpaired trailing bound'     => [web   => {web_a => '10.9.0.40'},                           ''],
		'a suffixed key beside a longer owner name'
		                                 => [bosh  => {bosh_ipfoo => '10.9.0.23', ocfp_bosh_ip => '10.9.0.24'}, '10.9.0.23'],
	);
	plan tests => 2 * keys %forms;

	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => make_deploy_env());
	for my $name (sort keys %forms) {
		my ($owner, $records, $expect) = @{$forms{$name}};
		my $subnet = {'reserved-ips' => $records};

		my ($own) = $hook->_get_reserved_allocation($owner, $subnet);
		is($own->range, $expect, "$name, as the target's own record");

		my $others = $hook->_all_reserved_ip_records($subnet, 'unrelated');
		my $other = exists $others->{$owner} ? $others->{$owner}->range : '';
		is($other, $expect, "$name, as another target's record");
	}
};


# lab_mgmt_band - one band of the mgmt carve: the subnet-reserved, available,
# and second subnet-reserved pairs, then a triple per service with
# <t>_a = <t>_ip - 1 and <t>_b = <t>_ip + 1, so each service's _a and _b keys
# sit on its neighbours' _ip addresses, plus the two smoke-test triples
sub lab_mgmt_band {
	my ($prefix, $base, $az) = @_;
	my $a = sub { $prefix . ($base + $_[0]) };
	my %records = (
		reserved_0  => $a->(0),  reserved_1  => $a->(27),
		available_0 => $a->(28), available_1 => $a->(35),
		reserved_2  => $a->(36), reserved_3  => $a->(62),
		director_ip => $a->(4),  ip => $a->(4),
		garage_smoke_a => $a->(21), garage_ip_smoke => $a->(22), garage_smoke_b => $a->(23),
		rustfs_smoke_a => $a->(20), rustfs_ip_smoke => $a->(21), rustfs_smoke_b => $a->(22),
		scheme_version => '3-compact',
	);
	my @services = lab_mgmt_services();
	for my $i (0 .. $#services) {
		my $o = 3 + $i;
		@records{map {"$services[$i]_$_"} qw(a ip b)} = ($a->($o - 1), $a->($o), $a->($o + 1));
	}
	return {
		az => $az, cidr_block => "${prefix}0/24", gateway => "${prefix}1",
		dns => ['10.97.160.160', '10.97.160.161'],
		'reserved-ips' => \%records,
	};
}

# lab_mgmt_services - the mgmt carve's services, in address order from .3 of each band
sub lab_mgmt_services {
	return qw(bastion bosh vault jumpbox concourse prometheus shield blacksmith artifacts
	          wireguard ovpn rustfs proxycache nfs ocfp_ui doomsday shout garage);
}

$LAB{mgmt} = {
	env_name   => 'ocfp-cf1-lab-mgmt',
	create_env => 0,
	prefix     => '10.61.148.',
	band       => \&lab_mgmt_band,
	bands      => {'ocfp-0' => [64, 'pvupvecf101'], 'ocfp-1' => [128, 'pvupvecf102'], 'ocfp-2' => [192, 'pvupvecf103']},
	record_owners => [lab_mgmt_services()],
	record_holders => {
		concourse => 'ocfp-cf1-lab-mgmt.concourse.net-concourse',
		vault     => 'ocfp-cf1-lab-mgmt.openbao.net-openbao',
		jumpbox   => 'ocfp-cf1-lab-mgmt.jumpbox.net-jumpbox',
		shield    => 'ocfp-cf1-lab-mgmt.shield.net-shield',
		doomsday  => 'ocfp-cf1-lab-mgmt.doomsday.net-doomsday',
	},
	networks => {
		concourse   => {class => 'LabConcourse', type => 'concourse', claim => 'ocfp-cf1-lab-mgmt.concourse.net-concourse'},
		# The mgmt director is deployed with create-env; its own cloud config
		# still carries the compilation network
		compilation => {class => 'LabDirector',  type => 'bosh',      claim => 'ocfp-cf1-lab-mgmt.bosh.net-compilation',
		                director => 1, create_env => 1},
		# The ocf director's own address, in the parent-side cloud config the
		# mgmt director holds for it
		'ocf-bosh'  => {class => 'LabOcfBosh',   type => 'bosh',      claim => 'ocfp-cf1-lab-ocf.bosh.net-bosh',
		                env_name => 'ocfp-cf1-lab-ocf'},
	},
	# The mgmt director's saved claims, as read from its network exodus on
	# 2026-10-04; ocfp-cf1-lab-ocf.bosh.net-bosh is the ocf director's address
	claims_today => {
		'ocfp-0' => {
			'ocfp-cf1-lab-mgmt.concourse.net-concourse' => '10.61.148.71,10.61.148.92-10.61.148.95',
			'ocfp-cf1-lab-mgmt.doomsday.net-doomsday'   => '10.61.148.82',
			'ocfp-cf1-lab-mgmt.openbao.net-openbao'     => '10.61.148.69',
			'ocfp-cf1-lab-mgmt.shield.net-shield'       => '10.61.148.73',
			'ocfp-cf1-lab-ocf.bosh.net-bosh'            => '10.61.148.87',
		},
		'ocfp-1' => {
			'ocfp-cf1-lab-mgmt.doomsday.net-doomsday'   => '10.61.148.146',
			'ocfp-cf1-lab-mgmt.jumpbox.net-jumpbox'     => '10.61.148.134',
			'ocfp-cf1-lab-mgmt.openbao.net-openbao'     => '10.61.148.133',
			'ocfp-cf1-lab-mgmt.shield.net-shield'       => '10.61.148.137',
			'ocfp-cf1-lab-ocf.bosh.net-bosh'            => '10.61.148.151',
		},
		'ocfp-2' => {
			'ocfp-cf1-lab-mgmt.bosh.net-compilation'    => '10.61.148.220-10.61.148.223',
			'ocfp-cf1-lab-mgmt.doomsday.net-doomsday'   => '10.61.148.210',
			'ocfp-cf1-lab-mgmt.openbao.net-openbao'     => '10.61.148.197',
			'ocfp-cf1-lab-mgmt.shield.net-shield'       => '10.61.148.201',
			'ocfp-cf1-lab-ocf.bosh.net-bosh'            => '10.61.148.215',
		},
	},
};
{
	# How the mgmt networks render on today's claims, which is how they render
	# under the claims model before reserved-ips records of other targets were
	# taken out of a network's free pool, too
	local $LAB_DIRECTOR = 'mgmt';
	$LAB{mgmt}{golden} = {
		concourse => {name => 'ocfp-cf1-lab-mgmt.concourse.net-concourse', type => 'manual', subnets => [
			lab_subnet('ocfp-0', 1, ['10.61.148.0-10.61.148.70', '10.61.148.72-10.61.148.91', '10.61.148.96-10.61.148.255'],
			                        ['10.61.148.71']),
		]},
		compilation => {name => 'ocfp-cf1-lab-mgmt.bosh.net-compilation', type => 'manual', subnets => [
			lab_subnet('ocfp-2', 3, ['10.61.148.0-10.61.148.219', '10.61.148.224-10.61.148.255']),
		]},
		# The ocf director takes the carve's bosh record on each subnet as its static
		'ocf-bosh' => {name => 'ocfp-cf1-lab-ocf.bosh.net-bosh', type => 'manual', subnets => [
			lab_subnet('ocfp-0', 1, ['10.61.148.0-10.61.148.67',  '10.61.148.69-10.61.148.255'],  ['10.61.148.68']),
			lab_subnet('ocfp-1', 2, ['10.61.148.0-10.61.148.131', '10.61.148.133-10.61.148.255'], ['10.61.148.132']),
			lab_subnet('ocfp-2', 3, ['10.61.148.0-10.61.148.195', '10.61.148.197-10.61.148.255'], ['10.61.148.196']),
		]},
	};
}

subtest 'lab claims (mgmt) - Concourse and the director compilation network render as they do today, with no warning' => sub {
	local $LAB_DIRECTOR = 'mgmt';
	plan tests => 6;
	for my $net (qw(concourse compilation)) {
		lab_reset_claims(lab_claims_today());
		my ($got, $err) = lab_run_net_with_stderr($net);
		is_deeply($got, lab_golden($net), "$net renders the same network");
		is_deeply(lab_claims_snapshot(), lab_claims_today(), "$net saves the same claims");
		is($err, '', "$net prints no prune, clash, or own-record warning");
	}
};

subtest 'lab claims (mgmt) - compact neighbour keys add no address and no owner of their own' => sub {
	local $LAB_DIRECTOR = 'mgmt';
	plan tests => 4;
	lab_reset_claims(lab_claims_today());
	my $hook = Genesis::Hook::CloudConfig::LabConcourse->init(env => lab_env('concourse'), purpose => 'lab-'.(++$lab_seq));
	my $ocfp = lab_ocfp_config();
	my $records_seen = IPv4->new();
	for my $subnet (qw(ocfp-0 ocfp-1 ocfp-2)) {
		my $base = lab()->{bands}{$subnet}[0];
		my @services = lab_mgmt_services();
		my %want = map {
			($services[$_] => '10.61.148.'.($base + 3 + $_))
		} grep {$services[$_] ne 'concourse'} 0 .. $#services;
		# the _ip_smoke addresses are the owner's own, beside its _ip
		$want{garage} .= ',10.61.148.'.($base + 22);
		$want{rustfs} .= ',10.61.148.'.($base + 21);
		$want{garage_smoke} = '10.61.148.'.($base + 22);
		$want{rustfs_smoke} = '10.61.148.'.($base + 21);
		my $got = $hook->_all_reserved_ip_records($ocfp->{net}{subnets}{$subnet}, 'concourse');
		$records_seen += $got->{$_} for keys %$got;
		is_deeply({map {($_ => $got->{$_}->range)} keys %$got}, \%want,
			"$subnet: each owner holds only its own _ip address, and the _a/_b keys name no address or owner beyond it");
	}
	my $bands = IPv4->new('10.61.148.92-10.61.148.99,10.61.148.156-10.61.148.163,10.61.148.220-10.61.148.227');
	is(($bands - ($bands - $records_seen))->size, 0, 'no record lies in an available band');
};

subtest 'lab claims (mgmt) - Concourse keeps .71 and .92-.95, compilation keeps .220-.223, and .248 stays unclaimed' => sub {
	local $LAB_DIRECTOR = 'mgmt';
	plan tests => 7;
	my $claims  = lab_claims_today()->{'ocfp-2'};
	my $records = lab_ocfp_config()->{net}{subnets}{'ocfp-2'}{'reserved-ips'};
	my $holds   = sub { my $set = IPv4->range(IPv4->new($_[0])); ($set - IPv4->new('10.61.148.248'))->size < $set->size };
	my @holding = (
		(grep {$holds->($claims->{$_})} sort keys %$claims),
		(grep {$records->{$_} =~ /^\d+\.\d+\.\d+\.\d+$/ && $holds->($records->{$_})} sort keys %$records),
	);
	is_deeply(\@holding, [], 'no mgmt claim and no mgmt record on ocfp-2 holds 10.61.148.248');

	lab_reset_claims(lab_claims_today());
	lab_run_net('concourse');
	lab_run_net('compilation');
	is_deeply(lab_claims_snapshot(), lab_claims_today(), 'building both on today\'s claims changes nothing');
	lab_assert_disjoint_and_record_clean('building both on today\'s claims');

	lab_reset_claims();
	for my $name (qw(compilation concourse)) { lab_run_net($name) }
	is(lab_claim('ocfp-0', 'concourse'), '10.61.148.71,10.61.148.92-10.61.148.95',
		'fresh claims give Concourse its own record and the first four available addresses');
	is(lab_claim('ocfp-2', 'compilation'), '10.61.148.220-10.61.148.223',
		'fresh claims give compilation the first four available addresses');
	lab_assert_disjoint_and_record_clean('fresh claims');
	my $snap = lab_claims_snapshot();
	for my $name (qw(compilation concourse)) { lab_run_net($name) }
	is_deeply(lab_claims_snapshot(), $snap, 'a second pass changes nothing');
};

subtest 'lab claims (mgmt) - the exempt compilation network gives up an address a new record takes, and warns' => sub {
	local $LAB_DIRECTOR = 'mgmt';
	plan tests => 3;
	lab_reset_claims(lab_claims_today());
	lab_add_record('ocfp-2', minio_ip => '10.61.148.221');
	my $err;
	lives_ok { (undef, $err) = lab_run_net_with_stderr('compilation') }
		'the compilation network does not stop the build';
	is(lab_claim('ocfp-2', 'compilation'), '10.61.148.220,10.61.148.222-10.61.148.224',
		'it drops .221 and takes the next free address');
	like($err, qr/net-compilation.*ocfp-2.*10\.61\.148\.221.*minio/s,
		'the warning names the network, the subnet, the address, and its owner');
};

subtest 'lab claims (mgmt) - the ocf director\'s parent-side net-bosh config renders from the carve\'s bosh records' => sub {
	local $LAB_DIRECTOR = 'mgmt';
	plan tests => 3;
	lab_reset_claims(lab_claims_today());
	my ($got, $err) = lab_run_net_with_stderr('ocf-bosh');
	is_deeply($got, lab_golden('ocf-bosh'), 'the network takes one static from each subnet\'s bosh record');
	is($err, '', 'and prints no prune, clash, or own-record warning');
	my %bosh_ip = map {($_ => lab_ocfp_config()->{net}{subnets}{$_}{'reserved-ips'}{bosh_ip})} qw(ocfp-0 ocfp-1 ocfp-2);
	is_deeply({map {($_ => lab_claim($_, 'ocf-bosh'))} sort keys %bosh_ip}, \%bosh_ip,
		'and its saved claim on each subnet is that record');
};

subtest 'lab claims (mgmt) - records outside the subnet-reserved range keep a claim out of the pool' => sub {
	local $LAB_DIRECTOR = 'mgmt';
	plan tests => 6;

	# The carve's own records sit inside the subnet-reserved range, where the
	# pool would leave them out anyway.  These two sit in the available band.
	lab_reset_claims();
	lab_add_record('ocfp-0', minio_ip   => '10.61.148.93');
	lab_add_record('ocfp-2', grafana_ip => '10.61.148.221');
	for my $name (qw(compilation concourse)) { lab_run_net($name) }
	is(lab_claim('ocfp-0', 'concourse'), '10.61.148.71,10.61.148.92,10.61.148.94-10.61.148.96',
		'Concourse\'s fresh claim steps over the record at .93');
	is(lab_claim('ocfp-2', 'compilation'), '10.61.148.220,10.61.148.222-10.61.148.224',
		'compilation\'s fresh claim steps over the record at .221');
	lab_assert_disjoint_and_record_clean('fresh claims beside records in the available band');

	my $snap = lab_claims_snapshot();
	for my $name (qw(compilation concourse)) { lab_run_net($name) }
	is_deeply(lab_claims_snapshot(), $snap, 'a second pass changes nothing');

	my $claim = IPv4->range(lab_claim('ocfp-0', 'concourse'));
	is((IPv4->range('10.61.148.93') - $claim)->size, 1, 'the record at .93 is in no claim on ocfp-0');
	is((IPv4->range('10.61.148.221') - IPv4->range(lab_claim('ocfp-2', 'compilation')))->size, 1,
		'and the record at .221 is in no claim on ocfp-2');
};

# ---------------------------------------------------------------------------
# network_definition must not touch the caller's $_.  Kits call it from inside
# map/for over constant lists, where $_ is a read-only alias.
# ---------------------------------------------------------------------------
subtest 'network_definition - leaves the caller\'s $_ alone' => sub {
	plan tests => 6;

	my $build = sub {
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => make_deploy_env());
		my $net;
		stderr_from { $net = $hook->network_definition('bosh',
			strategy => 'ocfp',
			dynamic_subnets => {
				allocation => { size => 0, statics => 0 },
				cloud_properties_for_iaas => {
					openstack => {
						'net_id'          => $hook->network_reference('id'),
						'security_groups' => ['default'],
					},
				},
			},
		) };
		return $net;
	};

	my $plain = $build->();
	ok(scalar @{$plain->{subnets}}, 'baseline network has subnets from own reserved-ips');

	my @mapped;
	lives_ok { @mapped = map { $build->() } qw(x) }
		'network_definition survives a read-only $_ (map over constants)';
	cmp_deeply($mapped[0]{subnets}, $plain->{subnets}, "subnets match the call made without the alias");

	lives_ok { for (qw(x)) { $build->() } }
		'network_definition survives a read-only $_ (for over constants)';

	my $mine = 'caller value';
	for ($mine) { $build->() }
	is($mine, 'caller value', 'caller\'s writable $_ keeps its value');

	local $_ = 'outer';
	$build->();
	is($_, 'outer', 'global $_ is untouched');
};

done_testing;


# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
