#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use helper;
use Test::More;
use Test::Exception;
use Test::Deep;
use Carp qw/croak/;
use Genesis qw(logger struct_lookup bail);
use Cwd qw(abs_path);

use JSON::PP;

$ENV{GENESIS_CALLBACK_BIN} ||= abs_path('bin/genesis');
$ENV{GENESIS_LIB} ||= abs_path('lib');
$ENV{GENESIS_OUTPUT_COLUMNS}=80;
$ENV{NOCOLOR} = 1;

my $ocfp_config = {
	vpc => {
		azs => {
			'az1' => {
				cloud_properties => '{"zone": "us-east-1a"}'
			},
			'az2' => {
				cloud_properties => '{"zone": "us-east-1b"}'
			},
			'az3' => {
				cloud_properties => '{"zone": "us-east-1c"}'
			}
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
				az              => 'az1',
				cidr_block      => '10.0.0.0/24',
				gateway         => '10.0.0.1',
				dns             => '10.0.0.2',
				'reserved-ips'  => {
					'available_a' => '10.0.0.37',
					'available_b' => '10.0.0.250',
					'bosh_ip'     => '10.0.0.5',
				}
			},
			'ocfp-1' => {
				az              => 'az2',
				cidr_block      => '10.0.1.0/24',
				gateway         => '10.0.1.1',
				dns             => '10.0.1.2',
				'reserved-ips'  => {
					'available_a' => '10.0.1.16',
					'available_b' => '10.0.1.250',
					'reserved_a'  => '10.0.1.0',
					'reserved_b'  => '10.0.1.36' # not a typo - testing reserved and available overlap
				}
			},
			'ocfp-2' => {
				az              => 'az3',
				cidr_block      => '10.0.2.0/24',
				gateway         => '10.0.2.1',
				dns             => '10.0.2.2',
				'reserved-ips'  => {
					'reserved_a'  => '10.0.2.0',
					'reserved_b'  => '10.0.2.36',
					'reserved_c'  => '10.0.2.255',
					'reserved_d'  => '10.0.2.255',
					'bosh_ip'     => '10.0.2.6',
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
		my ( $self, $msg, @args ) = @_;
		bail( "Throwing a kit bug: ".$msg, @args );
	},
};

my $bosh = mock "Genesis::BOSH" => {
	alias => 'mock-bosh',
};

sub mock_env {
	mock "Genesis::Env" => {(
			name           => 'test-env-ocf',
			type           => 'bosh',
			kit            => $kit,
			bosh           => $bosh,
			use_create_env => 0,
			features       => Mock::ReferencedValue->new(['ocfp', 'some-feature']),
			iaas           => 'openstack',
			scale          => 'dev',

			env_config_overrides => {},
			director_config_overrides => {},

			# OCFP configuration
			ocfp_subnet_prefix => 'ocfp',
			ocfp_config => $ocfp_config,

			# Methods
			is_ocfp => sub {
				return $_[0]->features && grep { $_ eq 'ocfp' } ($_[0]->features);
			},
			lookup => sub {
				my ( $self, $key, $default ) = @_;
				return struct_lookup( $self->config, $key, $default );
			},
			director_exodus_lookup => sub {
				die 'Create-env environments do not have directors'
			},
			ocfp_config_lookup => sub {
				my ( $self, $key ) = @_;
				return struct_lookup( $self->ocfp_config, $key );
			},

			# Environment configuration
			config => {
				params => {
					cloud_config_prefix => 'test-env.test'
				}
			},

		), @_};
};
my ($mgmt_env, $env, $cf_env, $director_network_exodus);
my ($cc_hook, $cc_director_hook, $cc_cf_hook);

subtest 'Genesis::Hook::CloudConfig::Bosh' => sub {
	# Test initialization
	$Genesis::VERSION = '3.1.0-rc.10';
	$ENV{GENESIS_CALL_BIN} = 'genesis';
	$ENV{"GENESIS_KIT_HOOK"} = "cloud-config";

	subtest "director cloudconfig" => sub {
		$mgmt_env = mock_env(
			use_create_env => 1,
			name           => 'test-env-mgmt',
			ocfp_type      => 'mgmt',
		);

		subtest 'initialization' => sub {
			require_ok "hooks/cloud-config-bosh-director.pm";

			local $ENV{GENESIS_ENVIRONMENT} = 'test-env-mgmt';

			throws_ok {
				Genesis::Hook::CloudConfig::Bosh::Director->init(env => $mgmt_env)
			} qr/Purpose must be 'director' - no purpose provided/m, 'Purpose must be director, none given';
			throws_ok {
				Genesis::Hook::CloudConfig::Bosh::Director->init(env => $mgmt_env, purpose => 'interloper')
			} qr/Purpose must be 'director' - got 'interloper'/m, 'Purpose must be director, alternate given';

			$mgmt_env->_mock_set_responses( 'config', { value => {params => {cloud_config_prefix => 'test-env.supertest'}}, count => 1} );
			$cc_director_hook = Genesis::Hook::CloudConfig::Bosh::Director->init(env => $mgmt_env, purpose => 'director');
			isa_ok( $cc_director_hook, 'Genesis::Hook::CloudConfig::Bosh::Director' );
			isa_ok( $cc_director_hook, 'Genesis::Hook::CloudConfig' );
			isa_ok( $cc_director_hook, 'Genesis::Hook' );
		};

		subtest 'basic cloud-config director properties' => sub {

			is( $cc_director_hook->{purpose}, 'director', 'Purpose is set if provided' );
			is( $cc_director_hook->{basename}, 'test-env-mgmt.bosh', 'Basename should match environment name.type by default' );
			is( $cc_director_hook->basename, 'test-env-mgmt.bosh', 'Basename can be accessed as a method' );
			is( $cc_director_hook->{id}, 'test-env-mgmt.bosh@director', 'ID should include purpose if set' );
		};

		subtest 'az definitions' => sub {
			my @azs = $cc_director_hook->build_az_definitions();
			cmp_deeply([@azs], [
				{
					cloud_properties => {"zone" => "us-east-1a"},
					name             => 'test-env-mgmt-az1',
				},
				{
					cloud_properties => {"zone" => "us-east-1b"},
					name             => 'test-env-mgmt-az2',
				},
				{
					cloud_properties => {"zone" => "us-east-1c"},
					name             => 'test-env-mgmt-az3',
				},
			], 'AZ definitions are correct');
		};

		subtest 'compilation network definition' => sub {
			my $network = $cc_director_hook->network_definition('compilation',
				strategy => 'ocfp',
				dynamic_subnets => {
					subnets => ['ocfp-1'],
					allocation => {
						size => 4,
						statics => 0,
					},
					cloud_properties_for_iaas => {
						openstack => {
							'net_id' => $cc_director_hook->network_reference('id'),
							'security_groups' => ['default']
						},
					},
				}
			);

			ok($network, 'Network definition generated');
			is($network->{name}, 'test-env-mgmt.bosh.net-compilation', 'Network name is correct');
			is($network->{type}, 'manual', 'Network type is correct');
			ok(scalar(@{$network->{subnets}}), 'Network has subnets');
		};

		subtest 'vm type definition' => sub {
			my $vm_type = $cc_director_hook->vm_type_definition('compilation',
				cloud_properties_for_iaas => {
					openstack => {
						'instance_type' => 'm1.2',
						'boot_from_volume' => $cc_director_hook->TRUE,
						'root_disk' => {
							'size' => 30
						},
					},
				}
			);

			ok($vm_type, 'VM type definition generated');
			is($vm_type->{name}, 'test-env-mgmt.bosh.vm-compilation', 'VM type name is correct');
			ok($vm_type->{cloud_properties}, 'VM type has cloud properties');
			is($vm_type->{cloud_properties}{instance_type}, 'm1.2', 'VM type instance type is correct');
			cmp_deeply([sort keys %{$cc_director_hook->network->{azs}}], ['az1', 'az2', 'az3'], 'Available AZs are correct and unaltered');
		};

		subtest 'compilation definition' => sub {
			throws_ok {
				$cc_director_hook->compilation_definition(strategy => 'generic')
			} qr/Unsupported strategy for building compilation definitions: generic/m, 'Unsupported strategy';

			my %compilation = $cc_director_hook->compilation_definition(strategy => 'ocfp');
			cmp_deeply(\%compilation, {
					network => 'test-env-mgmt.bosh.net-compilation',
					vm_type => 'test-env-mgmt.bosh.vm-compilation',
					az      => 'test-env-mgmt-az2',
					workers => 4,
					reuse_compilation => JSON::PP::true,
				}, 'Compilation definition is correct');
			cmp_deeply([sort keys %{$cc_director_hook->network->{azs}}], ['az1', 'az2', 'az3'], 'Available AZs are correct and unaltered');
		};

		subtest 'build cloud config' => sub {
			$mgmt_env->_mock_set_responses( workdir => {value => workdir} );
			ok($cc_director_hook->perform, 'Cloud config generation succeeds');
			ok($cc_director_hook->completed, 'Cloud config is marked as completed');
			my $results = $cc_director_hook->results;
			is(ref($results), 'HASH', 'Cloud config results returned');
			eq_or_diff($results->{config}, <<EOF, 'Cloud config is correct');
azs:
- name: test-env-mgmt-az1
- name: test-env-mgmt-az2
- name: test-env-mgmt-az3

compilation:
  az: test-env-mgmt-az2
  network: test-env-mgmt.bosh.net-compilation
  reuse_compilation: true
  vm_type: test-env-mgmt.bosh.vm-compilation
  workers: 4

networks:
- name: test-env-mgmt.bosh.net-compilation
  subnets:
  - az: test-env-mgmt-az2
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
- name: test-env-mgmt.bosh.vm-compilation
  cloud_properties:
    boot_from_volume: true
    instance_type: m1.2
    root_disk:
      size: 30
EOF
			cmp_deeply($results->{network}, {
				'azs' => {
					'az1' => {
						'cloud_properties' => '{"zone": "us-east-1a"}',
						'name' => 'test-env-mgmt-az1'
					},
					'az2' => {
						'cloud_properties' => '{"zone": "us-east-1b"}',
						'name' => 'test-env-mgmt-az2'
					},
					'az3' => {
						'cloud_properties' => '{"zone": "us-east-1c"}',
						'name' => 'test-env-mgmt-az3'
					}
				},
				'subnets' => {
					'ocfp-0' => {
						'az' => 'test-env-mgmt-az1',
						'claims' => {},
						'range' => '10.0.0.0-10.0.0.255'
					},
					'ocfp-1' => {
						'az' => 'test-env-mgmt-az2',
						'claims' => {
							'test-env-mgmt.bosh.net-compilation' => '10.0.1.37-10.0.1.40'
						},
						'range' => '10.0.1.0-10.0.1.255'
					},
					'ocfp-2' => {
						'az' => 'test-env-mgmt-az3',
						'claims' => {},
						'range' => '10.0.2.0-10.0.2.255'
					}
				}
			}, 'Network data is correct');
		};
	};

  $director_network_exodus = $cc_director_hook->results->{network};

	subtest 'cloud config - bosh' => sub {

		# Get a new env and use the director hook output as the network data
		$env = mock_env(
			director_exodus_lookup => sub {
				my ($self, $key) = @_;
				return $director_network_exodus if $key eq '/network';
				die "Unknown key: $key";
			}
		);

		subtest "initialization" => sub {
			require_ok "hooks/cloud-config-bosh.pm";

			# Test that invalid initialization conditions are caught
			throws_ok {
				Genesis::Hook::CloudConfig::Bosh->init()
			} qr/Missing required arguments for a perl-based kit hook call: env$/m, 'Missing required arguments: env';

			throws_ok {
				Genesis::Hook::CloudConfig::Bosh->init(env => $mgmt_env)
			} qr/Create-env environments do not have deployment cloud configs/, 'create-env environments don\'t have cloud configs';

			{
				local $Genesis::VERSION = '3.1.0-rc0';
				throws_ok {
					Genesis::Hook::CloudConfig::Bosh->init(env => $env)
				} qr/The test-kit\/1.0.0 kit cloud-config hook requires Genesis v3.1.0.* or.*higher -- cannot continue./s, 'Genesis version too low';
			}

			lives_ok {
				$cc_hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env)
			} 'Hook initialization succeeds with valid arguments';

			isa_ok( $cc_hook, 'Genesis::Hook::CloudConfig::Bosh' );
			isa_ok( $cc_hook, 'Genesis::Hook::CloudConfig' );
			isa_ok( $cc_hook, 'Genesis::Hook' );
		};

		subtest 'basic properties' => sub {
			# Test basic hook properties
			is( $cc_hook->completed, 0, 'Freshly initiated hook is not completed' );
			is( $cc_hook->results, undef, 'Freshly initiated hook has no results' );
			cmp_deeply( [$cc_hook->features], ['ocfp', 'some-feature'], 'Hook has features (as array ref)' );
			ok( $cc_hook->want_feature('ocfp'), 'Hook want feature' );
			ok( $cc_hook->wants_feature('some-feature'), 'Hook wants feature (alias)' );
			not_ok( $cc_hook->want_feature('non-existent-feature'), 'Hook does not want unspecified feature' );

			is( $cc_hook->iaas, 'openstack', 'Hook has iaas' );
			is( $cc_hook->scale, 'dev', 'Hook has scale' );
			not_ok( $cc_hook->use_create_env, 'Hook does not use create-env' );
			ok( $cc_hook->is_ocfp, 'Hook is ocfp' );
			$env->_mock_set_responses( 'features', {value => Mock::ReferencedValue->new([]), count => 1} );
			not_ok( $cc_hook->is_ocfp, 'Hook is not ocfp (when missing feature "ocfp")' );

			is( $cc_hook->label, '[#M{Bosh CloudConfig}] ', 'Hook label is correct' );
		};

		subtest "basic cloud-config properties" => sub{

			is( $cc_hook->{purpose}, undef, 'Purpose is empty' );
			is( $cc_hook->{basename}, 'test-env-ocf.bosh', 'Basename should match environment name by default' );
			is( $cc_hook->basename, 'test-env-ocf.bosh', 'Basename can be accessed as a method' );
			is( $cc_hook->{id}, 'test-env-ocf.bosh', 'ID should match basename by default' );

			is( $cc_hook->name_for('network', 'bosh'), 'test-env-ocf.bosh.network-bosh', 'Network name is correct' );

			my @scale_args = (
				{dev => 'small', prod => 'large'},
				'medium'
			);
			is( $cc_hook->for_scale(@scale_args), 'small', 'Scale-based configuration returns correct value for dev' );
			$env->_mock_set_responses( 'scale', {value => 'prod', count => 1} );
			is( $cc_hook->for_scale(@scale_args), 'large', 'Scale-based configuration returns correct value for prod' );
			$env->_mock_set_responses( 'scale', {value => 'unknown', count => 1} );
			is( $cc_hook->for_scale(@scale_args), 'medium', 'Scale-based configuration returns correct value for unknown scale' );

			# TODO: Test lookup_ref
		};

		subtest "network availability zones" => sub {

      is( $cc_hook->lookup_az('az1'), 'test-env-mgmt-az1', 'AZ lookup is correct' );
      is( $cc_hook->lookup_az('az4'), undef, 'AZ lookup returns undef for unknown AZ' );

			# TODO: Test network_reference and subnet_reference
			cmp_deeply( $cc_hook->get_available_azs, {
				'az1' => {
					'cloud_properties' => '{"zone": "us-east-1a"}',
					'name'             => 'test-env-mgmt-az1'
				},
				'az2' => {
					'cloud_properties' => '{"zone": "us-east-1b"}',
					'name'             => 'test-env-mgmt-az2'
				},
				'az3' => {
					'cloud_properties' => '{"zone": "us-east-1c"}',
					'name'             => 'test-env-mgmt-az3'
				}
			}, 'Available AZs are correct');
		};

		subtest "existing network definition from director" => sub {
			my $allocations = $cc_hook->_get_existing_allocations();
			cmp_deeply([keys %$allocations], ['test-env-mgmt.bosh.net-compilation'], 'Just the director\'s compilation network is allocated');
			cmp_deeply([keys %{$allocations->{'test-env-mgmt.bosh.net-compilation'}}], ['ocfp-1'], 'The director\'s compilation network only uses "ocfp-1" subnet');
			my $compilation_range = $allocations->{'test-env-mgmt.bosh.net-compilation'}{'ocfp-1'};
			isa_ok($compilation_range, 'IP4::MultiRange', 'Compilation range is an IP4::MultiRange');
			is($compilation_range->size, 4, 'Compilation range is 4 addresses');
			is($compilation_range->range, '10.0.1.37-10.0.1.40', 'Compilation range is correct');

			cmp_deeply([sort keys %{$cc_hook->_filter_subnets}], ['ocfp-0', 'ocfp-1', 'ocfp-2'], 'All subnets are available when unfilitered');
			cmp_deeply([sort keys %{$cc_hook->_filter_subnets(['ocfp-0', 'ocfp-2', 'ocfp-4'])}], ['ocfp-0', 'ocfp-2'], 'Subnets can be filtered by multiple strings, and return only the matching ones');
			cmp_deeply([sort keys %{$cc_hook->_filter_subnets(qr/ocfp-[2-4]/)}], ['ocfp-2'], 'Subnets can be filtered by regex, and return only the matching ones');
			cmp_deeply([sort keys %{$cc_hook->_filter_subnets([qr/ocfp-[2-4]/,'ocfp-0','ocfp-2'])}], ['ocfp-0', 'ocfp-2'], 'Subnets can be filtered by regex and string, and return only the matching ones with no duplicates');
			cmp_deeply([sort keys %{$cc_hook->_filter_subnets('random-string')}], [], 'Subnets can be filtered by string, and return nothing');

			cmp_deeply($cc_hook->_filter_subnets('ocfp-0'), {'ocfp-0' => {
				'az' => 'az1',
				'cidr_block' => '10.0.0.0/24',
				'dns' => '10.0.0.2',
				'gateway' => '10.0.0.1',
				'reserved-ips' => {
					'available_a' => '10.0.0.37',
					'available_b' => '10.0.0.250',
					'bosh_ip' => '10.0.0.5'
				}
			}}, 'Subnet data is correct');
    }; # existing network definition from director

		subtest "network definition generation" => sub {
			my $network = $cc_hook->network_definition('bosh',
				strategy => 'ocfp',
				dynamic_subnets => {
					allocation => {
						size => 0,
						statics => 0,
					},
					cloud_properties_for_iaas => {
						openstack => {
							'net_id' => $cc_hook->network_reference('id'),
							'security_groups' => ['default']
						},
					},
				}
			);

			ok($network, 'Network definition generated');
			is($network->{name}, 'test-env-ocf.bosh.net-bosh', 'Network name is correct');
			is($network->{type}, 'manual', 'Network type is correct');
			is(scalar(@{$network->{subnets}}), 2, 'Network has 2 subnets');
			cmp_deeply($network->{subnets}[0], {
				'az' => 'test-env-mgmt-az1',
				'cloud_properties' => {
					'net_id' => 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxx01',
					'security_groups' => [ 'default' ]
				},
				'dns' => [ '10.0.0.2' ],
				'gateway' => '10.0.0.1',
				'range' => '10.0.0.0/24',
				'reserved' => [ '10.0.0.0-10.0.0.4', '10.0.0.6-10.0.0.255' ],
				'static' => [ '10.0.0.5' ]
			}, 'First subnet is correct');
			cmp_deeply($network->{subnets}[1], {
				'az' => 'test-env-mgmt-az3',
				'cloud_properties' => {
					'net_id' => 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxx01',
					'security_groups' => [ 'default' ]
				},
				'dns' => [ '10.0.2.2' ],
				'gateway' => '10.0.2.1',
				'range' => '10.0.2.0/24',
				'reserved' => [ '10.0.2.0-10.0.2.5', '10.0.2.7-10.0.2.255' ],
				'static' => [ '10.0.2.6' ]
			}, 'Second subnet is correct');

			cmp_deeply($cc_hook->network->{subnets}{'ocfp-0'}{claims}, {
				'test-env-ocf.bosh.net-bosh' => '10.0.0.5'
			}, 'ocfp-0 subnet has correct claims');
			cmp_deeply($cc_hook->network->{subnets}{'ocfp-1'}{claims}, {
				'test-env-mgmt.bosh.net-compilation' => '10.0.1.37-10.0.1.40'
			}, 'ocfp-1 subnet has correct claims');
			cmp_deeply($cc_hook->network->{subnets}{'ocfp-2'}{claims}, {
				'test-env-ocf.bosh.net-bosh' => '10.0.2.6'
			}, 'ocfp-2 subnet has correct claims');
		}; # network definition generation

		subtest "VM type definition" => sub {
			my $build_vm_type = sub {
				$cc_hook->vm_type_definition('bosh', cloud_properties_for_iaas => {
					aws => {
						'instance_type' => 'c4.2xlarge',
						'root_disk' => {
							'size' => 25,
							'type' => 'gp3'
						},
					},
					openstack => {
						'instance_type' => $cc_hook->for_scale({
							dev => 'm1.1',
							prod => 'm1.3'
						}, 'm1.2'),
						'boot_from_volume' => $cc_hook->TRUE,
						'root_disk' => {
							'size' => $cc_hook->for_scale({
								dev => 32,
								prod => 64
							}, 48),
						},
					},
				})
			};
			my $vm_type = $build_vm_type->();
			cmp_deeply($vm_type, {
				'name' => 'test-env-ocf.bosh.vm-bosh',
				'cloud_properties' => {
					'boot_from_volume' => $cc_hook->TRUE,
					'instance_type' => 'm1.1',
					'root_disk' => {
						'size' => 32
					}
				}
			}, 'VM type definition is correct (dev scale)');

			$env->_mock_set_responses( 'scale' => 'prod' );
			$vm_type = $build_vm_type->();
			cmp_deeply($vm_type, {
				'name' => 'test-env-ocf.bosh.vm-bosh',
				'cloud_properties' => {
					'boot_from_volume' => $cc_hook->TRUE,
					'instance_type' => 'm1.3',
					'root_disk' => {
						'size' => 64
					}
				}
			}, 'VM type definition is correct for prod scale');

			$env->_mock_set_responses( 'scale' => 'unknown' );
			$vm_type = $build_vm_type->();
			cmp_deeply($vm_type, {
				'name' => 'test-env-ocf.bosh.vm-bosh',
				'cloud_properties' => {
					'boot_from_volume' => $cc_hook->TRUE,
					'instance_type' => 'm1.2',
					'root_disk' => {
						'size' => 48
					}
				}
			}, 'VM type definition is correct for unknown scale');

			$env->_mock_remove_responses( 'scale' );
			$env->_mock_set_responses( 'iaas' => 'aws' );
			$vm_type = $build_vm_type->();
			cmp_deeply($vm_type, {
				'name' => 'test-env-ocf.bosh.vm-bosh',
				'cloud_properties' => {
					'instance_type' => 'c4.2xlarge',
					'root_disk' => {
						'size' => 25,
						'type' => 'gp3'
					}
				}
			}, 'VM type definition is correct for AWS');

			$env->_mock_set_responses( 'iaas' => 'unknown' );
			throws_ok {
				$build_vm_type->()
			} qr/Unsupported unknown IaaS for building vm_type\s+definitions in test-kit\/1.0.0/ms, 'Unsupported IaaS';
			$env->_mock_remove_responses( 'iaas' );
		}; # VM type definition

		subtest "disk type definition" => sub {

			BEGIN {
				use_ok('Genesis::Hook::CloudConfig::Helpers', qw/gigabytes megabytes/)
			};

			my $build_disk_type = sub {
				$cc_hook->disk_type_definition('bosh', common => {
					disk_size => $cc_hook->for_scale({
						dev => gigabytes(64),
						prod => gigabytes(128)
					}, gigabytes(96)),
				}, cloud_properties_for_iaas => {
					aws => {
						'type' => 'gp3',
					},
					openstack => {
						'type' => 'storage_premium_perf6',
					},
				})
			};
			my $disk_type = $build_disk_type->();
			cmp_deeply($disk_type, {
				'name' => 'test-env-ocf.bosh.disk-bosh',
				'disk_size' => 64 * 1024,
				'cloud_properties' => {
					'type' => 'storage_premium_perf6',
				}
			}, 'Disk type definition is correct (dev scale)');

			$env->_mock_set_responses( 'scale' => 'prod' );
			$disk_type = $build_disk_type->();
			cmp_deeply($disk_type, {
				'name' => 'test-env-ocf.bosh.disk-bosh',
				'disk_size' => 128 * 1024,
				'cloud_properties' => {
					'type' => 'storage_premium_perf6',
				}
			}, 'Disk type definition is correct for prod scale');

			$env->_mock_set_responses( 'scale' => 'unknown' );
			$disk_type = $build_disk_type->();
			cmp_deeply($disk_type, {
				'name' => 'test-env-ocf.bosh.disk-bosh',
				'disk_size' => 96 * 1024,
				'cloud_properties' => {
					'type' => 'storage_premium_perf6',
				}
			}, 'Disk type definition is correct for unknown scale');

			$env->_mock_remove_responses( 'scale' );
			$env->_mock_set_responses( 'iaas' => 'aws' );
			$disk_type = $build_disk_type->();
			cmp_deeply($disk_type, {
				'name' => 'test-env-ocf.bosh.disk-bosh',
				'disk_size' => 64 * 1024,
				'cloud_properties' => {
					'type' => 'gp3',
				}
			}, 'Disk type definition is correct for AWS');

			$env->_mock_set_responses( 'iaas' => 'vsphere' );
			throws_ok {
				$build_disk_type->()
			} qr/Unsupported vsphere IaaS for building disk_type\s+definitions in test-kit\/1.0.0/ms, 'Unsupported IaaS: vsphere';	
			$env->_mock_remove_responses( 'iaas' );

		}; # disk type definition

		subtest "cloud config generation" => sub {
			$env->_mock_set_responses( workdir => {value => workdir} );
			delete $cc_hook->{ocfp_config}{subnets}{'ocfp-2'}{'reserved-ips'}{bosh_ip};
			# $env->{config}{'bosh-config'}{cloud}{networks}{bosh}{subnets} = ['ocfp-1'];
			# `cp /Users/dennis.bell/.replyrc \$HOME/` unless -f $ENV{HOME}."/.replyrc"; use Pry; pry;
			ok($cc_hook->perform, 'Cloud config generation succeeds');
			ok($cc_hook->completed, 'Cloud config is marked as completed');
			my $results = $cc_hook->results;
			is(ref($results), 'HASH', 'Cloud config results returned');
			is_deeply([sort keys %{$results}], ['config', 'network'], 'Cloud config results contain expected keys');
			eq_or_diff($results->{config}, <<EOF, 'Cloud config is correct');
disk_types:
- name: test-env-ocf.bosh.disk-bosh
  disk_size: 65536
  cloud_properties:
    type: storage_premium_perf6

networks:
- name: test-env-ocf.bosh.net-bosh
  subnets:
  - az: test-env-mgmt-az1
    dns:
    - 10.0.0.2
    gateway: 10.0.0.1
    range: 10.0.0.0/24
    reserved:
    - 10.0.0.0-10.0.0.4
    - 10.0.0.6-10.0.0.255
    static:
    - 10.0.0.5
    cloud_properties:
      net_id: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxx01
      security_groups:
      - default
  type: manual

vm_types:
- name: test-env-ocf.bosh.vm-bosh
  cloud_properties:
    boot_from_volume: true
    instance_type: m1.2
    root_disk:
      size: 32
EOF

			cmp_deeply($results->{network}, {
				'azs' => {
					'az1' => {
						'cloud_properties' => '{"zone": "us-east-1a"}',
						'name' => 'test-env-mgmt-az1'
					},
					'az2' => {
						'cloud_properties' => '{"zone": "us-east-1b"}',
						'name' => 'test-env-mgmt-az2'
					},
					'az3' => {
						'cloud_properties' => '{"zone": "us-east-1c"}',
						'name' => 'test-env-mgmt-az3'
					}
				},
				'subnets' => {
					'ocfp-0' => {
						'az' => 'test-env-mgmt-az1',
						'claims' => {
							'test-env-ocf.bosh.net-bosh' => '10.0.0.5'
						},
						'range' => '10.0.0.0-10.0.0.255',
					},
					'ocfp-1' => {
						'az' => 'test-env-mgmt-az2',
						'claims' => {
							'test-env-mgmt.bosh.net-compilation' => '10.0.1.37-10.0.1.40'
						},
						'range' => '10.0.1.0-10.0.1.255',
					},
					'ocfp-2' => {
						'az' => 'test-env-mgmt-az3',
						'claims' => {},
						'range' => '10.0.2.0-10.0.2.255',
					}
				},
			}, 'Network data is correct');
		}; # cloud config generation
	}; # cloud-config bosh
};

subtest "Genesis::Hook::CloudConfig::CF" => sub {

	my $cf_kit = mock "Genesis::Kit" => {
		name => 'cf',
		version => '8.8.8',
		genesis_version_min => '3.1.0-rc.10',
		id  => sub { return $_[0]->name . '/' . $_[0]->version },
		kit_bug => sub {
				my ( $self, $msg, @args ) = @_;
				bail( "Throwing a kit bug: " . $msg, @args );
		},
	};

	$cf_env = mock_env(
		name => 'test-env-ocf',
		type => 'cf',
		kit  => $cf_kit,
		scale => 'prod',
		features => Mock::ReferencedValue->new(['ocfp', 'split-network']),
		env_config_overrides => sub {
			my ($self, $type) = @_;
			croak "CloudConfig hook called env_config_overrides without a type" unless $type;
			croak "CloudConfig hook called env_config_overrides with an invalid type: $type" unless $type eq 'cloud';

			return struct_lookup($self->{config}, 'bosh-configs.cloud', {});
		},
		director_config_overrides => {},
		ocfp_subnet_prefix => 'ocfp',
		ocfp_config => $ocfp_config, # maybe something different?
		is_ocfp => 1,
		lookup => sub {
			my ( $self, $key, $default ) = @_;
			return struct_lookup( $self->config, $key, $default );
		},
		director_exodus_lookup => sub {
			my ($self, $key) = @_;
			return $director_network_exodus if $key eq '/network';
			die "Unknown key: $key";
		},
		ocfp_config_lookup => sub {
			my ( $self, $key ) = @_;
			return struct_lookup( $self->ocfp_config, $key );
		}
	);

	subtest 'initialization' => sub {

		require_ok('hooks/cloud-config-cf.pm');

		lives_ok {
			$cc_cf_hook = Genesis::Hook::CloudConfig::CF->init( env => $cf_env )
		} 'Hook initialization succeeds with valid arguments';

		isa_ok( $cc_cf_hook, 'Genesis::Hook::CloudConfig::CF' );
		isa_ok( $cc_cf_hook, 'Genesis::Hook::CloudConfig' );
		isa_ok( $cc_cf_hook, 'Genesis::Hook' );
	};

	subtest 'basic properties' => sub {
		is( $cc_cf_hook->completed, 0, 'Freshly initiated hook is not completed' );
		is( $cc_cf_hook->results, undef, 'Freshly initiated hook has no results' );
		cmp_deeply( [$cc_cf_hook->features], ['ocfp', 'split-network'], 'Hook has features (as array ref)' );
		ok( $cc_cf_hook->want_feature('split-network'), 'Hook want feature' );

		is( $cc_cf_hook->iaas, 'openstack', 'Hook has iaas' );
		is( $cc_cf_hook->scale, 'prod', 'Hook has scale' );
		not_ok( $cc_cf_hook->use_create_env, 'Hook does not use create-env' );
		ok( $cc_cf_hook->is_ocfp, 'Hook is ocfp' );

		is( $cc_cf_hook->label, '[#M{CF CloudConfig}] ', 'Hook label is correct' );
	};

	subtest 'correct generation of cloud config and network updates' => sub {
		$cf_env->_mock_set_responses( workdir => {value => workdir} );
		my $success = 0;
		lives_ok {
			$success = $cc_cf_hook->perform
		} 'Cloud config generation succeeds';
		ok( $success, 'Cloud config generation returns true' );
		ok( $cc_cf_hook->completed, 'Cloud config is marked as completed' );

		my $results = $cc_cf_hook->results;
		is(ref($results), 'HASH', 'Cloud config results returned');
		eq_or_diff($results->{config}, <<EOF, 'Cloud config is correct');
disk_types:
- name: test-env-ocf.cf.disk-database
  disk_size: 10240
  cloud_properties:
    type: storage_premium_perf6
- name: test-env-ocf.cf.disk-blobstore
  disk_size: 204800
  cloud_properties:
    type: storage_premium_perf6

networks:
- name: test-env-ocf.cf.net-ocf-core
  subnets:
  - az: test-env-mgmt-az1
    dns:
    - 10.0.0.2
    gateway: 10.0.0.1
    range: 10.0.0.0/24
    reserved:
    - 10.0.0.0-10.0.0.36
    - 10.0.0.48-10.0.0.255
    cloud_properties:
      net_id: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxx01
      security_groups:
      - default
  - az: test-env-mgmt-az2
    dns:
    - 10.0.1.2
    gateway: 10.0.1.1
    range: 10.0.1.0/24
    reserved:
    - 10.0.1.0-10.0.1.40
    - 10.0.1.52-10.0.1.255
    cloud_properties:
      net_id: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxx01
      security_groups:
      - default
  - az: test-env-mgmt-az3
    dns:
    - 10.0.2.2
    gateway: 10.0.2.1
    range: 10.0.2.0/24
    reserved:
    - 10.0.2.0-10.0.2.36
    - 10.0.2.48-10.0.2.255
    cloud_properties:
      net_id: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxx01
      security_groups:
      - default
  type: manual
- name: test-env-ocf.cf.net-ocf-edge
  subnets:
  - az: test-env-mgmt-az1
    dns:
    - 10.0.0.2
    gateway: 10.0.0.1
    range: 10.0.0.0/24
    reserved:
    - 10.0.0.0-10.0.0.47
    - 10.0.0.49-10.0.0.255
    cloud_properties:
      net_id: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxx01
      security_groups:
      - default
  - az: test-env-mgmt-az2
    dns:
    - 10.0.1.2
    gateway: 10.0.1.1
    range: 10.0.1.0/24
    reserved:
    - 10.0.1.0-10.0.1.51
    - 10.0.1.53-10.0.1.255
    cloud_properties:
      net_id: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxx01
      security_groups:
      - default
  - az: test-env-mgmt-az3
    dns:
    - 10.0.2.2
    gateway: 10.0.2.1
    range: 10.0.2.0/24
    reserved:
    - 10.0.2.0-10.0.2.47
    - 10.0.2.49-10.0.2.255
    cloud_properties:
      net_id: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxx01
      security_groups:
      - default
  type: manual
- name: test-env-ocf.cf.net-ocf-tcp
  subnets:
  - az: test-env-mgmt-az1
    dns:
    - 10.0.0.2
    gateway: 10.0.0.1
    range: 10.0.0.0/24
    reserved:
    - 10.0.0.0-10.0.0.48
    - 10.0.0.50-10.0.0.255
    cloud_properties:
      net_id: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxx01
      security_groups:
      - default
  - az: test-env-mgmt-az2
    dns:
    - 10.0.1.2
    gateway: 10.0.1.1
    range: 10.0.1.0/24
    reserved:
    - 10.0.1.0-10.0.1.52
    - 10.0.1.54-10.0.1.255
    cloud_properties:
      net_id: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxx01
      security_groups:
      - default
  - az: test-env-mgmt-az3
    dns:
    - 10.0.2.2
    gateway: 10.0.2.1
    range: 10.0.2.0/24
    reserved:
    - 10.0.2.0-10.0.2.48
    - 10.0.2.50-10.0.2.255
    cloud_properties:
      net_id: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxx01
      security_groups:
      - default
  type: manual
- name: test-env-ocf.cf.net-ocf-db
  subnets:
  - az: test-env-mgmt-az1
    dns:
    - 10.0.0.2
    gateway: 10.0.0.1
    range: 10.0.0.0/24
    reserved:
    - 10.0.0.0-10.0.0.49
    - 10.0.0.51-10.0.0.255
    cloud_properties:
      net_id: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxx01
      security_groups:
      - default
  type: manual
- name: test-env-ocf.cf.net-ocf-runtime
  subnets:
  - az: test-env-mgmt-az1
    dns:
    - 10.0.0.2
    gateway: 10.0.0.1
    range: 10.0.0.0/24
    reserved:
    - 10.0.0.0-10.0.0.50
    - 10.0.0.91-10.0.0.255
    cloud_properties:
      net_id: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxx01
      security_groups:
      - default
  - az: test-env-mgmt-az2
    dns:
    - 10.0.1.2
    gateway: 10.0.1.1
    range: 10.0.1.0/24
    reserved:
    - 10.0.1.0-10.0.1.53
    - 10.0.1.94-10.0.1.255
    cloud_properties:
      net_id: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxx01
      security_groups:
      - default
  - az: test-env-mgmt-az3
    dns:
    - 10.0.2.2
    gateway: 10.0.2.1
    range: 10.0.2.0/24
    reserved:
    - 10.0.2.0-10.0.2.49
    - 10.0.2.90-10.0.2.255
    cloud_properties:
      net_id: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxx01
      security_groups:
      - default
  type: manual

vm_extensions:
- name: test-env-ocf.cf.vmx-diego-ssh-proxy-network-properties
- name: test-env-ocf.cf.vmx-cf-router-network-properties
- name: test-env-ocf.cf.vmx-cf-tcp-router-network-properties

vm_types:
- name: test-env-ocf.cf.vm-api
  cloud_properties:
    boot_from_volume: true
    ephemeral_disk:
      encrypted: true
    instance_type: c1a.4d
    root_disk:
      size: 15
- name: test-env-ocf.cf.vm-cc-worker
  cloud_properties:
    boot_from_volume: true
    ephemeral_disk:
      encrypted: true
    instance_type: c1a.1d
    root_disk:
      size: 15
- name: test-env-ocf.cf.vm-credhub
  cloud_properties:
    boot_from_volume: true
    ephemeral_disk:
      encrypted: true
    instance_type: c1a.1d
    root_disk:
      size: 30
- name: test-env-ocf.cf.vm-diego-api
  cloud_properties:
    boot_from_volume: true
    ephemeral_disk:
      encrypted: true
    instance_type: c1a.1d
    root_disk:
      size: 15
- name: test-env-ocf.cf.vm-diego-cell
  cloud_properties:
    boot_from_volume: true
    ephemeral_disk:
      encrypted: true
    instance_type: m1a.16d
    root_disk:
      size: 256
- name: test-env-ocf.cf.vm-doppler
  cloud_properties:
    boot_from_volume: true
    ephemeral_disk:
      encrypted: true
    instance_type: c1a.2d
    root_disk:
      size: 15
- name: test-env-ocf.cf.vm-errand
  cloud_properties:
    boot_from_volume: true
    ephemeral_disk:
      encrypted: true
    instance_type: c1.1
    root_disk:
      size: 15
- name: test-env-ocf.cf.vm-log-api
  cloud_properties:
    boot_from_volume: true
    ephemeral_disk:
      encrypted: true
    instance_type: c1a.1d
    root_disk:
      size: 15
- name: test-env-ocf.cf.vm-log-cache
  cloud_properties:
    boot_from_volume: true
    ephemeral_disk:
      encrypted: true
    instance_type: c1a.2d
    root_disk:
      size: 15
- name: test-env-ocf.cf.vm-nats
  cloud_properties:
    boot_from_volume: true
    ephemeral_disk:
      encrypted: true
    instance_type: c1a.1d
    root_disk:
      size: 15
- name: test-env-ocf.cf.vm-router
  cloud_properties:
    boot_from_volume: true
    ephemeral_disk:
      encrypted: true
    instance_type: c1a.4d
    root_disk:
      size: 15
- name: test-env-ocf.cf.vm-scheduler
  cloud_properties:
    boot_from_volume: true
    ephemeral_disk:
      encrypted: true
    instance_type: c1a.1d
    root_disk:
      size: 15
- name: test-env-ocf.cf.vm-tcp-router
  cloud_properties:
    boot_from_volume: true
    ephemeral_disk:
      encrypted: true
    instance_type: c1.1
    root_disk:
      size: 10
- name: test-env-ocf.cf.vm-uaa
  cloud_properties:
    boot_from_volume: true
    ephemeral_disk:
      encrypted: true
    instance_type: c1a.2d
    root_disk:
      size: 30
EOF

		cmp_deeply($results->{network}, {
			'azs' => {
				'az1' => {
					'cloud_properties' => '{"zone": "us-east-1a"}',
					'name' => 'test-env-mgmt-az1'
				},
				'az2' => {
					'cloud_properties' => '{"zone": "us-east-1b"}', 
					'name' => 'test-env-mgmt-az2'
				},
				'az3' => {
					'cloud_properties' => '{"zone": "us-east-1c"}',
					'name' => 'test-env-mgmt-az3'
				}
			},
			'subnets' => {
				'ocfp-0' => {
					'az' => 'test-env-mgmt-az1',
					'claims' => {
						'test-env-ocf.bosh.net-bosh' => '10.0.0.5',
						'test-env-ocf.cf.net-ocf-core' => '10.0.0.37-10.0.0.47',
						'test-env-ocf.cf.net-ocf-db' => '10.0.0.50',
						'test-env-ocf.cf.net-ocf-edge' => '10.0.0.48',
						'test-env-ocf.cf.net-ocf-runtime' => '10.0.0.51-10.0.0.90',
						'test-env-ocf.cf.net-ocf-tcp' => '10.0.0.49'
					},
					'range' => '10.0.0.0-10.0.0.255'
				},
				'ocfp-1' => {
					'az' => 'test-env-mgmt-az2', 
					'claims' => {
						'test-env-mgmt.bosh.net-compilation' => '10.0.1.37-10.0.1.40',
						'test-env-ocf.cf.net-ocf-core' => '10.0.1.41-10.0.1.51',
						'test-env-ocf.cf.net-ocf-edge' => '10.0.1.52',
						'test-env-ocf.cf.net-ocf-runtime' => '10.0.1.54-10.0.1.93',
						'test-env-ocf.cf.net-ocf-tcp' => '10.0.1.53'
					},
					'range' => '10.0.1.0-10.0.1.255'
				},
				'ocfp-2' => {
					'az' => 'test-env-mgmt-az3',
					'claims' => {
						'test-env-ocf.cf.net-ocf-core' => '10.0.2.37-10.0.2.47',
						'test-env-ocf.cf.net-ocf-edge' => '10.0.2.48',
						'test-env-ocf.cf.net-ocf-runtime' => '10.0.2.50-10.0.2.89',
						'test-env-ocf.cf.net-ocf-tcp' => '10.0.2.49'
					},
					'range' => '10.0.2.0-10.0.2.255' 
				}
			}
		}, 'Network data is correct');
	}
};


done_testing;

# vim - fdm=marker:foldlevel=1:ts=2:sts=2:sw=2:noet
