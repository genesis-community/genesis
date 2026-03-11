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
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

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

my $bosh = mock "Genesis::BOSH" => {
	alias => 'mock-bosh',
};

# Director network exodus data (simulates what director hook produces)
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

# Each call to mock_env() uses a unique env name so each subtest gets a fresh
# CloudConfig object from init() — the internal cache key is "name.type", so
# unique names guarantee no stale cached hook is returned.
my $test_seq = 0;
sub mock_env {
	$test_seq++;
	my $seq = $test_seq;
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
			return $director_network_exodus if $key eq '/network';
			die "Unknown key: $key";
		},
		ocfp_config_lookup => sub {
			my ($self, $key) = @_;
			return struct_lookup($self->ocfp_config, $key);
		},
		config => { params => { cloud_config_prefix => 'test-env.test' } },
	), @_};
}

# ---------------------------------------------------------------------------
# Establish Genesis version and hook env vars once before all subtests
# ---------------------------------------------------------------------------
$Genesis::VERSION = '3.1.0-rc.10';
$ENV{GENESIS_CALL_BIN}  = 'genesis';
$ENV{GENESIS_KIT_HOOK}  = 'cloud-config';

# ---------------------------------------------------------------------------
# Load the hook implementation we test against
# ---------------------------------------------------------------------------
subtest 'require hook implementation' => sub {
	plan tests => 1;
	require_ok 'hooks/cloud-config-bosh.pm';
};

# ---------------------------------------------------------------------------
# init
# ---------------------------------------------------------------------------
subtest 'init - argument validation' => sub {
	plan tests => 2;

	throws_ok {
		Genesis::Hook::CloudConfig::Bosh->init()
	} qr/Missing required arguments for a perl-based kit hook call: env/,
		'init() dies when env argument is omitted';

	my $create_env = mock_env(use_create_env => 1);
	throws_ok {
		Genesis::Hook::CloudConfig::Bosh->init(env => $create_env)
	} qr/Create-env environments do not have deployment cloud configs/,
		'init() dies for create-env environments';
};

subtest 'init - returns blessed CloudConfig object' => sub {
	plan tests => 3;

	my $env  = mock_env();
	my $hook;
	lives_ok {
		$hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env)
	} 'init() succeeds with valid env';

	isa_ok($hook, 'Genesis::Hook::CloudConfig',
		'returned object isa Genesis::Hook::CloudConfig');

	isa_ok($hook, 'Genesis::Hook',
		'returned object isa Genesis::Hook');
};

subtest 'init - caching by id returns same object' => sub {
	plan tests => 2;

	my $env   = mock_env();
	my $hook1 = Genesis::Hook::CloudConfig::Bosh->init(env => $env);
	my $hook2 = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	ok(defined $hook1, 'first call returns an object');
	is($hook1, $hook2,
		'second call with same env returns the cached object');
};

subtest 'init - basename defaults to env_name.env_type' => sub {
	plan tests => 1;

	my $env  = mock_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);
	my $expected = $env->name . '.bosh';

	is($hook->basename, $expected,
		'basename defaults to env_name.env_type');
};

subtest 'init - id equals basename when no purpose' => sub {
	plan tests => 2;

	my $env  = mock_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	is($hook->{id}, $hook->basename,
		'id equals basename when no purpose is set');
	is($hook->{purpose}, undef,
		'purpose is undef when not provided');
};

# ---------------------------------------------------------------------------
# basename, contents, overrides_base
# ---------------------------------------------------------------------------
subtest 'basename accessor' => sub {
	plan tests => 2;

	my $env  = mock_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);
	my $expected = $env->name . '.bosh';

	is($hook->basename, $expected,
		'basename() returns env_name.env_type string');

	is($hook->basename, $hook->{basename},
		'basename() method returns the internal basename field');
};

subtest 'contents accessor - empty hashref before done()' => sub {
	plan tests => 2;

	my $env  = mock_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	ok(defined $hook->contents,
		'contents() returns a defined value before done()');
	is(ref($hook->contents), 'HASH',
		'contents() returns a HASH ref (empty) before done() is called');
};

subtest 'overrides_base' => sub {
	plan tests => 1;

	my $env  = mock_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	is($hook->overrides_base, 'bosh-configs.cloud',
		'overrides_base() returns "bosh-configs.cloud"');
};

# ---------------------------------------------------------------------------
# name_for
# ---------------------------------------------------------------------------
subtest 'name_for - builds qualified component names' => sub {
	plan tests => 3;

	my $env  = mock_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);
	my $base = $hook->basename;

	is($hook->name_for('vm', 'default'), "${base}.vm-default",
		'name_for("vm", "default") returns correct name');

	is($hook->name_for('net', 'deployment'), "${base}.net-deployment",
		'name_for("net", "deployment") returns correct name');

	is($hook->name_for('disk', 'large'), "${base}.disk-large",
		'name_for("disk", "large") returns correct name');
};

# ---------------------------------------------------------------------------
# for_scale
# ---------------------------------------------------------------------------
subtest 'for_scale - returns value for current scale' => sub {
	plan tests => 3;

	my $env  = mock_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $map     = { dev => 'small', prod => 'large' };
	my $default = 'medium';

	is($hook->for_scale($map, $default), 'small',
		'for_scale() returns dev value when scale is "dev"');

	$env->_mock_set_responses('scale' => 'prod');
	is($hook->for_scale($map, $default), 'large',
		'for_scale() returns prod value when scale is "prod"');

	$env->_mock_set_responses('scale' => 'unknown');
	is($hook->for_scale($map, $default), 'medium',
		'for_scale() returns default when scale is not in map');
};

# ---------------------------------------------------------------------------
# for_iaas
# ---------------------------------------------------------------------------
subtest 'for_iaas - returns value for current IaaS' => sub {
	plan tests => 3;

	my $env  = mock_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $map     = { openstack => 'os-value', aws => 'aws-value' };
	my $default = 'generic-value';

	is($hook->for_iaas($map, $default), 'os-value',
		'for_iaas() returns openstack value when iaas is "openstack"');

	$env->_mock_set_responses('iaas' => 'aws');
	is($hook->for_iaas($map, $default), 'aws-value',
		'for_iaas() returns aws value when iaas is "aws"');

	$env->_mock_set_responses('iaas' => 'vsphere');
	is($hook->for_iaas($map, $default), 'generic-value',
		'for_iaas() returns default when iaas is not in map');
};

# ---------------------------------------------------------------------------
# lookup_ref
# ---------------------------------------------------------------------------
subtest 'lookup_ref - returns a LookupRef object with correct attributes' => sub {
	plan tests => 4;

	my $env  = mock_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $ref = $hook->lookup_ref('some.path', 'default-val');

	isa_ok($ref, 'Genesis::Hook::CloudConfig::LookupRef',
		'lookup_ref() returns a LookupRef object');

	cmp_deeply([$ref->paths], ['some.path'],
		'LookupRef holds the given path');

	is($ref->default, 'default-val',
		'LookupRef holds the given default');

	my $ref2 = $hook->lookup_ref(['path.a', 'path.b'], 42);
	cmp_deeply([$ref2->paths], ['path.a', 'path.b'],
		'LookupRef accepts array of paths');
};

# ---------------------------------------------------------------------------
# network_reference
# ---------------------------------------------------------------------------
subtest 'network_reference - returns a LookupNetworkRef object' => sub {
	plan tests => 2;

	my $env  = mock_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $ref = $hook->network_reference('id');

	isa_ok($ref, 'Genesis::Hook::CloudConfig::LookupNetworkRef',
		'network_reference() returns a LookupNetworkRef object');

	is($ref->{ref}, 'id',
		'LookupNetworkRef stores the requested field name');
};

# ---------------------------------------------------------------------------
# subnet_reference
# ---------------------------------------------------------------------------
subtest 'subnet_reference - returns a LookupSubnetRef object' => sub {
	plan tests => 2;

	my $env  = mock_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	my $ref = $hook->subnet_reference('net_id');

	isa_ok($ref, 'Genesis::Hook::CloudConfig::LookupSubnetRef',
		'subnet_reference() returns a LookupSubnetRef object');

	is($ref->{ref}, 'net_id',
		'LookupSubnetRef stores the requested field name');
};

# ---------------------------------------------------------------------------
# done
# ---------------------------------------------------------------------------
subtest 'done - rejects non-hashref argument' => sub {
	plan tests => 3;

	my $env  = mock_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	throws_ok {
		$hook->done('a plain string')
	} qr/CloudConfig hook must return a hashref/,
		'done() dies when passed a plain scalar';

	throws_ok {
		$hook->done([1, 2, 3])
	} qr/CloudConfig hook must return a hashref/,
		'done() dies when passed an arrayref';

	throws_ok {
		$hook->done(undef)
	} qr/CloudConfig hook must return a hashref/,
		'done() dies when passed undef';
};

subtest 'done - marks hook as completed and stores YAML contents' => sub {
	plan tests => 3;

	my $env  = mock_env();
	$env->_mock_set_responses(workdir => workdir());
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	ok(!$hook->completed, 'hook is not completed before done() is called');

	$hook->done({ vm_types => [] });

	ok($hook->completed, 'hook is marked completed after done() is called');

	ok(length($hook->contents) > 0,
		'contents() is non-empty after done() is called');
};

# ---------------------------------------------------------------------------
# results
# ---------------------------------------------------------------------------
subtest 'results - returns undef before done()' => sub {
	plan tests => 1;

	my $env  = mock_env();
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	is($hook->results, undef,
		'results() returns undef before done() is called');
};

subtest 'results - returns hashref with config and network after done()' => sub {
	plan tests => 3;

	my $env  = mock_env();
	$env->_mock_set_responses(workdir => workdir());
	my $hook = Genesis::Hook::CloudConfig::Bosh->init(env => $env);

	$hook->done({ vm_types => [] });

	my $results = $hook->results;

	is(ref($results), 'HASH',
		'results() returns a hashref after done()');

	ok(exists $results->{config},
		'results hashref contains "config" key');

	ok(exists $results->{network},
		'results hashref contains "network" key');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
