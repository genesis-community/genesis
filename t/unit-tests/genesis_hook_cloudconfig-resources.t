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

BEGIN { use_ok('Genesis::Hook::CloudConfig::Helpers', qw/gigabytes megabytes/) }

# ---------------------------------------------------------------------------
# Shared mock data
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

# Director network exodus (pre-populated, no claims)
my $director_network_exodus = {
	'azs' => {
		'az1' => { 'cloud_properties' => '{"zone": "us-east-1a"}', 'name' => 'test-env-mgmt-az1' },
		'az2' => { 'cloud_properties' => '{"zone": "us-east-1b"}', 'name' => 'test-env-mgmt-az2' },
		'az3' => { 'cloud_properties' => '{"zone": "us-east-1c"}', 'name' => 'test-env-mgmt-az3' }
	},
	'subnets' => {
		'ocfp-0' => { 'az' => 'test-env-mgmt-az1', 'claims' => {}, 'range' => '10.0.0.0-10.0.0.255' },
		'ocfp-1' => { 'az' => 'test-env-mgmt-az2', 'claims' => {}, 'range' => '10.0.1.0-10.0.1.255' },
		'ocfp-2' => { 'az' => 'test-env-mgmt-az3', 'claims' => {}, 'range' => '10.0.2.0-10.0.2.255' }
	}
};

my $test_seq = 0;
sub mock_env {
	$test_seq++;
	mock "Genesis::Env" => {(
		name           => "test-env-res-$test_seq",
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
		is_ocfp => sub { return $_[0]->features && grep { $_ eq 'ocfp' } ($_[0]->features); },
		lookup => sub { my ($self, $key, $default) = @_; return struct_lookup($self->config, $key, $default); },
		director_exodus_lookup => sub {
			my ($self, $key) = @_;
			return $director_network_exodus if $key eq '/network';
			die "Unknown key: $key";
		},
		ocfp_config_lookup => sub { my ($self, $key) = @_; return struct_lookup($self->ocfp_config, $key); },
		config => { params => { cloud_config_prefix => 'test-env.test' } },
	), @_};
}

$Genesis::VERSION = '3.1.0-rc.10';
$ENV{GENESIS_CALL_BIN} = 'genesis';
$ENV{"GENESIS_KIT_HOOK"} = "cloud-config";

require_ok "hooks/cloud-config-bosh.pm";

# ---------------------------------------------------------------------------
# Helper: create a fresh hook with a fresh env
# ---------------------------------------------------------------------------
sub make_hook {
	my (%overrides) = @_;
	my $env = mock_env(%overrides);
	return Genesis::Hook::CloudConfig::Bosh->init(env => $env);
}

# ===========================================================================
# 1. vm_type_definition
# ===========================================================================
subtest 'vm_type_definition' => sub {
	plan tests => 5;

	# 1a. Basic: name is basename.vm-<target>
	subtest 'name format is basename.vm-<target>' => sub {
		plan tests => 2;

		my $hook = make_hook();
		my $vm_type = $hook->vm_type_definition('default',
			cloud_properties_for_iaas => {
				openstack => { instance_type => 'm1.small' },
			},
		);
		ok(defined $vm_type, 'vm_type_definition returns a defined value');
		is($vm_type->{name}, $hook->basename . '.vm-default',
			'name is prefixed with basename and vm- prefix');
	};

	# 1b. for_scale returns dev value when scale is dev
	subtest 'for_scale resolves dev value at dev scale' => sub {
		plan tests => 1;

		my $hook = make_hook();
		my $vm_type = $hook->vm_type_definition('bosh',
			cloud_properties_for_iaas => {
				openstack => {
					'instance_type' => $hook->for_scale({ dev => 'm1.1', prod => 'm1.3' }, 'm1.2'),
					'boot_from_volume' => $hook->TRUE,
					'root_disk' => { 'size' => $hook->for_scale({ dev => 32, prod => 64 }, 48) },
				},
			},
		);
		cmp_deeply($vm_type, {
			'name' => $hook->basename . '.vm-bosh',
			'cloud_properties' => {
				'boot_from_volume' => $hook->TRUE,
				'instance_type' => 'm1.1',
				'root_disk' => { 'size' => 32 }
			}
		}, 'vm_type_definition resolves for_scale with dev scale correctly');
	};

	# 1c. for_scale returns prod value when scale is prod
	subtest 'for_scale resolves prod value at prod scale' => sub {
		plan tests => 1;

		my $env  = mock_env();
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

		$env->_mock_set_responses('scale' => 'prod');
		my $vm_type = $hook->vm_type_definition('bosh',
			cloud_properties_for_iaas => {
				openstack => {
					'instance_type' => $hook->for_scale({ dev => 'm1.1', prod => 'm1.3' }, 'm1.2'),
					'root_disk' => { 'size' => $hook->for_scale({ dev => 32, prod => 64 }, 48) },
				},
			},
		);
		cmp_deeply($vm_type, {
			'name' => $hook->basename . '.vm-bosh',
			'cloud_properties' => {
				'instance_type' => 'm1.3',
				'root_disk' => { 'size' => 64 }
			}
		}, 'vm_type_definition resolves for_scale with prod scale correctly');
	};

	# 1d. for_scale returns default value for unknown scale
	subtest 'for_scale resolves default value for unknown scale' => sub {
		plan tests => 1;

		my $env  = mock_env();
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

		$env->_mock_set_responses('scale' => 'staging');
		my $vm_type = $hook->vm_type_definition('bosh',
			cloud_properties_for_iaas => {
				openstack => {
					'instance_type' => $hook->for_scale({ dev => 'm1.1', prod => 'm1.3' }, 'm1.2'),
					'root_disk' => { 'size' => $hook->for_scale({ dev => 32, prod => 64 }, 48) },
				},
			},
		);
		cmp_deeply($vm_type, {
			'name' => $hook->basename . '.vm-bosh',
			'cloud_properties' => {
				'instance_type' => 'm1.2',
				'root_disk' => { 'size' => 48 }
			}
		}, 'vm_type_definition resolves for_scale default for unknown scale correctly');
	};

	# 1e. IaaS selection: aws selects aws cloud_properties
	subtest 'cloud_properties_for_iaas selects correct IaaS properties' => sub {
		plan tests => 2;

		my $env  = mock_env();
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

		$env->_mock_set_responses('iaas' => 'aws');
		my $vm_type = $hook->vm_type_definition('bosh',
			cloud_properties_for_iaas => {
				aws => {
					'instance_type' => 'c4.2xlarge',
					'root_disk' => { 'size' => 25, 'type' => 'gp3' },
				},
				openstack => {
					'instance_type' => 'm1.2',
					'boot_from_volume' => $hook->TRUE,
				},
			},
		);
		cmp_deeply($vm_type, {
			'name' => $hook->basename . '.vm-bosh',
			'cloud_properties' => {
				'instance_type' => 'c4.2xlarge',
				'root_disk' => { 'size' => 25, 'type' => 'gp3' }
			}
		}, 'vm_type_definition selects aws cloud_properties when iaas is aws');

		# When no IaaS matches, returns empty list (not an error)
		$env->_mock_set_responses('iaas' => 'vsphere');
		my @result = $hook->vm_type_definition('bosh',
			cloud_properties_for_iaas => {
				aws => { 'instance_type' => 'c4.2xlarge' },
				openstack => { 'instance_type' => 'm1.2' },
			},
		);
		is(scalar(@result), 0,
			'vm_type_definition returns empty list when no IaaS match and no common properties');
	};
};

# ===========================================================================
# 2. disk_type_definition
# ===========================================================================
subtest 'disk_type_definition' => sub {
	plan tests => 5;

	# 2a. Basic: name format and gigabytes helper
	subtest 'name format is basename.disk-<target> and gigabytes helper works' => sub {
		plan tests => 3;

		my $hook = make_hook();
		my $disk_type = $hook->disk_type_definition('data',
			common => { disk_size => gigabytes(64) },
			cloud_properties_for_iaas => {
				openstack => { 'type' => 'storage_premium_perf6' },
			},
		);
		ok(defined $disk_type, 'disk_type_definition returns a defined value');
		is($disk_type->{name}, $hook->basename . '.disk-data',
			'name is prefixed with basename and disk- prefix');
		is($disk_type->{disk_size}, 64 * 1024,
			'gigabytes(64) correctly converts to 65536 MB for disk_size');
	};

	# 2b. for_scale resolves dev disk size
	subtest 'for_scale resolves dev disk size' => sub {
		plan tests => 1;

		my $hook = make_hook();
		my $disk_type = $hook->disk_type_definition('bosh',
			common => {
				disk_size => $hook->for_scale({ dev => gigabytes(64), prod => gigabytes(128) }, gigabytes(96)),
			},
			cloud_properties_for_iaas => {
				openstack => { 'type' => 'storage_premium_perf6' },
			},
		);
		cmp_deeply($disk_type, {
			'name' => $hook->basename . '.disk-bosh',
			'disk_size' => 64 * 1024,
			'cloud_properties' => { 'type' => 'storage_premium_perf6' }
		}, 'disk_type_definition returns correct dev-scale disk size (64 GB)');
	};

	# 2c. for_scale resolves prod disk size
	subtest 'for_scale resolves prod disk size' => sub {
		plan tests => 1;

		my $env  = mock_env();
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

		$env->_mock_set_responses('scale' => 'prod');
		my $disk_type = $hook->disk_type_definition('bosh',
			common => {
				disk_size => $hook->for_scale({ dev => gigabytes(64), prod => gigabytes(128) }, gigabytes(96)),
			},
			cloud_properties_for_iaas => {
				openstack => { 'type' => 'storage_premium_perf6' },
			},
		);
		cmp_deeply($disk_type, {
			'name' => $hook->basename . '.disk-bosh',
			'disk_size' => 128 * 1024,
			'cloud_properties' => { 'type' => 'storage_premium_perf6' }
		}, 'disk_type_definition returns correct prod-scale disk size (128 GB)');
	};

	# 2d. for_scale resolves default disk size for unknown scale
	subtest 'for_scale resolves default disk size for unknown scale' => sub {
		plan tests => 1;

		my $env  = mock_env();
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

		$env->_mock_set_responses('scale' => 'canary');
		my $disk_type = $hook->disk_type_definition('bosh',
			common => {
				disk_size => $hook->for_scale({ dev => gigabytes(64), prod => gigabytes(128) }, gigabytes(96)),
			},
			cloud_properties_for_iaas => {
				openstack => { 'type' => 'storage_premium_perf6' },
			},
		);
		cmp_deeply($disk_type, {
			'name' => $hook->basename . '.disk-bosh',
			'disk_size' => 96 * 1024,
			'cloud_properties' => { 'type' => 'storage_premium_perf6' }
		}, 'disk_type_definition returns correct default-scale disk size (96 GB)');
	};

	# 2e. IaaS selection for disk types
	subtest 'cloud_properties_for_iaas selects correct IaaS properties for disk' => sub {
		plan tests => 2;

		my $env  = mock_env();
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

		$env->_mock_set_responses('iaas' => 'aws');
		my $disk_type = $hook->disk_type_definition('bosh',
			common => { disk_size => gigabytes(64) },
			cloud_properties_for_iaas => {
				aws => { 'type' => 'gp3' },
				openstack => { 'type' => 'storage_premium_perf6' },
			},
		);
		cmp_deeply($disk_type, {
			'name' => $hook->basename . '.disk-bosh',
			'disk_size' => 64 * 1024,
			'cloud_properties' => { 'type' => 'gp3' }
		}, 'disk_type_definition selects aws cloud_properties when iaas is aws');

		# When IaaS has no match but common is present, name+common fields remain
		$env->_mock_set_responses('iaas' => 'vsphere');
		my $disk_type_no_cp = $hook->disk_type_definition('bosh',
			common => { disk_size => gigabytes(64) },
			cloud_properties_for_iaas => {
				aws => { 'type' => 'gp3' },
				openstack => { 'type' => 'storage_premium_perf6' },
			},
		);
		cmp_deeply($disk_type_no_cp, {
			'name' => $hook->basename . '.disk-bosh',
			'disk_size' => 64 * 1024,
		}, 'disk_type_definition returns common properties without cloud_properties when IaaS not in map');
	};
};

# ===========================================================================
# 3. vm_extension_definition
# ===========================================================================
subtest 'vm_extension_definition' => sub {
	plan tests => 4;

	# 3a. Name is used verbatim (not prefixed with basename)
	subtest 'name is used verbatim without basename prefix' => sub {
		plan tests => 2;

		my $hook = make_hook();
		my $ext = $hook->vm_extension_definition('100GB_ephemeral_disk', {
			cloud_properties_for_iaas => {
				openstack => { ephemeral_disk => { size => 102400 } },
			},
		});
		ok(defined $ext, 'vm_extension_definition returns a defined value for matching IaaS');
		is($ext->{name}, '100GB_ephemeral_disk',
			'vm extension name is used verbatim, not prefixed with basename');
	};

	# 3b. cloud_properties_for_iaas key triggers IaaS lookup
	subtest 'cloud_properties_for_iaas key triggers IaaS-based property selection' => sub {
		plan tests => 1;

		my $hook = make_hook();
		my $ext = $hook->vm_extension_definition('cf-router-network-properties', {
			cloud_properties_for_iaas => {
				openstack => {
					'security_groups' => ['cf-public'],
				},
				aws => {
					'lb_target_groups' => ['cf-router-lb'],
				},
			},
		});
		cmp_deeply($ext, {
			name => 'cf-router-network-properties',
			cloud_properties => {
				'security_groups' => ['cf-public'],
			},
		}, 'vm_extension_definition selects openstack cloud_properties correctly');
	};

	# 3c. Returns empty list when no cloud_properties for current IaaS
	subtest 'returns empty list when IaaS has no cloud properties' => sub {
		plan tests => 1;

		my $env  = mock_env();
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

		$env->_mock_set_responses('iaas' => 'vsphere');
		my @result = $hook->vm_extension_definition('some-extension', {
			cloud_properties_for_iaas => {
				openstack => { 'security_groups' => ['default'] },
				aws => { 'lb_target_groups' => ['web-lb'] },
			},
		});
		is(scalar(@result), 0,
			'vm_extension_definition returns empty list when IaaS not in cloud_properties_for_iaas');
	};

	# 3d. Data treated as IaaS map when cloud_properties_for_iaas key is absent
	subtest 'data treated as IaaS map when cloud_properties_for_iaas key is absent' => sub {
		plan tests => 2;

		my $hook = make_hook();
		# When data itself is the IaaS map (no nested cloud_properties_for_iaas key)
		my $ext = $hook->vm_extension_definition('direct-iaas-extension', {
			openstack => { 'network_type' => 'provider' },
			aws => { 'enhanced_networking' => 1 },
		});
		ok(defined $ext, 'vm_extension_definition returns a value when data is an IaaS map directly');
		is($ext->{name}, 'direct-iaas-extension',
			'name is verbatim when data is used as IaaS map directly');
	};
};

# ===========================================================================
# 4. override processing
# ===========================================================================
subtest 'override processing' => sub {
	plan tests => 3;

	# 4a. vm_type_defaults override merges into all vm_type definitions
	subtest 'vm_type_defaults are merged into vm_type definitions' => sub {
		plan tests => 2;

		my $env = mock_env(
			config => {
				params => { cloud_config_prefix => 'test-env.test' },
				'bosh-configs' => {
					cloud => {
						vm_type_defaults => {
							'cloud_properties' => { 'boot_from_volume' => JSON::PP::true },
						},
					},
				},
			},
		);
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

		my $vm_type = $hook->vm_type_definition('web',
			cloud_properties_for_iaas => {
				openstack => { 'instance_type' => 'm1.medium' },
			},
		);

		ok(defined $vm_type, 'vm_type_definition returns a value with defaults override');
		is($vm_type->{cloud_properties}{'boot_from_volume'}, JSON::PP::true,
			'vm_type_defaults boot_from_volume is merged into vm_type cloud_properties');
	};

	# 4b. vm_types specific override replaces properties for named target
	subtest 'vm_types specific override replaces properties for named vm_type' => sub {
		plan tests => 2;

		my $env = mock_env(
			config => {
				params => { cloud_config_prefix => 'test-env.test' },
				'bosh-configs' => {
					cloud => {
						vm_types => {
							worker => {
								'cloud_properties' => {
									'instance_type' => 'c4.4xlarge',
									'root_disk' => { 'size' => 50 },
								},
							},
						},
					},
				},
			},
		);
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

		my $vm_type = $hook->vm_type_definition('worker',
			cloud_properties_for_iaas => {
				openstack => { 'instance_type' => 'm1.medium' },
			},
		);

		ok(defined $vm_type, 'vm_type_definition returns a value with specific vm_types override');
		is($vm_type->{cloud_properties}{'instance_type'}, 'c4.4xlarge',
			'specific vm_types override replaces instance_type in cloud_properties');
	};

	# 4c. env_config_overrides via matching_vm_types conditionally applies overrides
	subtest 'matching_vm_types conditionally applies overrides based on conditions' => sub {
		plan tests => 2;

		my $env = mock_env(
			config => {
				params => { cloud_config_prefix => 'test-env.test' },
				'bosh-configs' => {
					cloud => {
						matching_vm_types => [
							{
								conditions => [
									{ 'name' => '/\.vm-large$/' },
								],
								properties => {
									'cloud_properties' => { 'instance_type' => 'm1.xlarge' },
								},
							},
						],
					},
				},
			},
		);
		my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

		# This vm type name ends in .vm-large, so the matching rule fires
		my $large = $hook->vm_type_definition('large',
			cloud_properties_for_iaas => {
				openstack => { 'instance_type' => 'm1.small' },
			},
		);
		is($large->{cloud_properties}{'instance_type'}, 'm1.xlarge',
			'matching_vm_types override applies when condition matches name pattern');

		# This vm type name does NOT end in .vm-large, so the rule does not fire
		my $small = $hook->vm_type_definition('small',
			cloud_properties_for_iaas => {
				openstack => { 'instance_type' => 'm1.small' },
			},
		);
		is($small->{cloud_properties}{'instance_type'}, 'm1.small',
			'matching_vm_types override does not apply when condition does not match');
	};
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
