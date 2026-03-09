#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use helper;
use Test::More;
use Test::Exception;
use Test::Deep;
use Genesis qw(struct_lookup bail);
use Cwd qw(abs_path);
use JSON::PP;

$ENV{GENESIS_CALLBACK_BIN} ||= abs_path('bin/genesis');
$ENV{GENESIS_LIB} ||= abs_path('lib');
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

use IPv4;
use Genesis::Commands::Ocfp::ShowNetwork;

# ============================================================================
# Test Fixtures
# ============================================================================

my $ocfp_config = {
	vpc => {
		azs => {
			'az1' => { cloud_properties => '{"zone": "us-east-1a"}' },
			'az2' => { cloud_properties => '{"zone": "us-east-1b"}' },
			'az3' => { cloud_properties => '{"zone": "us-east-1c"}' },
		},
		cidr_block => '192.168.0.0/20',
		dns        => '1.1.1.1',
		id         => 'vpc-test-001',
		region     => 'us-east-1',
		subnets    => {
			'ocfp-0' => {
				az         => 'az1',
				cidr_block => '10.0.0.0/24',
				gateway    => '10.0.0.1',
				dns        => '10.0.0.2',
				'reserved-ips' => {
					'available_a' => '10.0.0.37',
					'available_b' => '10.0.0.250',
					'bosh_ip'     => '10.0.0.5',
				},
			},
			'ocfp-1' => {
				az         => 'az2',
				cidr_block => '10.0.1.0/24',
				gateway    => '10.0.1.1',
				dns        => '10.0.1.2',
				'reserved-ips' => {
					'available_a' => '10.0.1.16',
					'available_b' => '10.0.1.250',
					'reserved_a'  => '10.0.1.0',
					'reserved_b'  => '10.0.1.36',
				},
			},
			'ocfp-2' => {
				az         => 'az3',
				cidr_block => '10.0.2.0/24',
				gateway    => '10.0.2.1',
				dns        => '10.0.2.2',
				'reserved-ips' => {
					'reserved_a' => '10.0.2.0',
					'reserved_b' => '10.0.2.36',
					'reserved_c' => '10.0.2.255',
					'reserved_d' => '10.0.2.255',
					'bosh_ip'    => '10.0.2.6',
				},
			},
		},
	},
};

# BOSH director exodus network data (simulates claims)
my $bosh_network_data = {
	subnets => {
		'ocfp-0' => {
			claims => {
				'test-env.bosh.net-default' => '10.0.0.37-10.0.0.60',
				'test-env.cf.net-cf-core'   => '10.0.0.61-10.0.0.80',
			},
		},
		'ocfp-1' => {
			claims => {
				'test-env.bosh.net-default' => '10.0.1.16-10.0.1.40',
			},
		},
	},
};

# ============================================================================
# Mock helpers
# ============================================================================

sub mock_env {
	my (%overrides) = @_;
	my $kit = mock "Genesis::Kit" => {
		name    => 'test-kit',
		version => '1.0.0',
	};

	my $config = $overrides{ocfp_config} // $ocfp_config;
	my $network_data = $overrides{bosh_network_data} // $bosh_network_data;
	my $is_create_env = $overrides{use_create_env} // 0;
	my $is_ocfp = exists $overrides{is_ocfp} ? $overrides{is_ocfp} : 1;

	return mock "Genesis::Env" => {
		name           => $overrides{name} // 'test-env-ocf',
		type           => 'bosh',
		kit            => $kit,
		use_create_env => $is_create_env,
		features       => Mock::ReferencedValue->new($is_ocfp ? ['ocfp'] : []),

		ocfp_config => $config,

		is_ocfp => sub { return $is_ocfp },

		ocfp_type => sub {
			my $self = shift;
			return '' unless $is_ocfp;
			my $name = $self->name;
			if ($name =~ /-(mgmt|ocf)(?:-|$)/ || $name =~ /^(mgmt|ocf)-/) {
				return $1;
			}
			return 'ocf';
		},

		ocfp_config_lookup => sub {
			my ($self, $key) = @_;
			return struct_lookup($self->ocfp_config, $key);
		},

		director_exodus_lookup => sub {
			my ($self, $path) = @_;
			die 'Create-env environments do not have directors'
				if $is_create_env;
			return $network_data if $path eq '/network';
			return undef;
		},
	};
}

# ============================================================================
# Tests: _compute_cidr_info
# ============================================================================

subtest '_compute_cidr_info' => sub {

	subtest '/24 network (256 addresses)' => sub {
		my $info = Genesis::Commands::Ocfp::ShowNetwork::_compute_cidr_info('10.0.0.0/24');
		is($info->{network},         '10.0.0.0',       'network address');
		is($info->{broadcast},       '10.0.0.255',     'broadcast address');
		is($info->{netmask},         '255.255.255.0',  'netmask');
		is($info->{wildcard},        '0.0.0.255',      'wildcard mask');
		is($info->{prefix_length},   24,               'prefix length');
		is($info->{total_addresses}, 256,              'total addresses');
		is($info->{usable_hosts},    254,              'usable hosts');
		is($info->{first_host},      '10.0.0.1',      'first host');
		is($info->{last_host},       '10.0.0.254',    'last host');
	};

	subtest '/20 network (4096 addresses)' => sub {
		my $info = Genesis::Commands::Ocfp::ShowNetwork::_compute_cidr_info('192.168.0.0/20');
		is($info->{network},         '192.168.0.0',    'network address');
		is($info->{broadcast},       '192.168.15.255', 'broadcast address');
		is($info->{netmask},         '255.255.240.0',  'netmask');
		is($info->{wildcard},        '0.0.15.255',     'wildcard mask');
		is($info->{prefix_length},   20,               'prefix length');
		is($info->{total_addresses}, 4096,             'total addresses');
		is($info->{usable_hosts},    4094,             'usable hosts');
		is($info->{first_host},      '192.168.0.1',   'first host');
		is($info->{last_host},       '192.168.15.254', 'last host');
	};

	subtest '/28 network (16 addresses)' => sub {
		my $info = Genesis::Commands::Ocfp::ShowNetwork::_compute_cidr_info('172.16.5.0/28');
		is($info->{network},         '172.16.5.0',     'network address');
		is($info->{broadcast},       '172.16.5.15',    'broadcast address');
		is($info->{netmask},         '255.255.255.240','netmask');
		is($info->{wildcard},        '0.0.0.15',       'wildcard mask');
		is($info->{prefix_length},   28,               'prefix length');
		is($info->{total_addresses}, 16,               'total addresses');
		is($info->{usable_hosts},    14,               'usable hosts');
		is($info->{first_host},      '172.16.5.1',    'first host');
		is($info->{last_host},       '172.16.5.14',   'last host');
	};

	subtest '/32 network (single host)' => sub {
		my $info = Genesis::Commands::Ocfp::ShowNetwork::_compute_cidr_info('10.0.0.5/32');
		is($info->{network},         '10.0.0.5',       'network address');
		is($info->{broadcast},       '10.0.0.5',       'broadcast address');
		is($info->{netmask},         '255.255.255.255','netmask');
		is($info->{wildcard},        '0.0.0.0',        'wildcard mask');
		is($info->{prefix_length},   32,               'prefix length');
		is($info->{total_addresses}, 1,                'total addresses');
		is($info->{usable_hosts},    1,                'usable hosts for /32');
		is($info->{first_host},      '10.0.0.5',      'first host');
		is($info->{last_host},       '10.0.0.5',      'last host');
	};

};

# ============================================================================
# Tests: _compute_ranges
# ============================================================================

subtest '_compute_ranges' => sub {

	subtest 'explicit available range (ocfp-0 pattern)' => sub {
		# ocfp-0: has available_a/available_b defining usable range
		my $subnet = $ocfp_config->{vpc}{subnets}{'ocfp-0'};
		my ($available, $reserved) = Genesis::Commands::Ocfp::ShowNetwork::_compute_ranges($subnet);

		ok($available > 0, 'available range is non-empty');
		ok($reserved > 0, 'reserved range is non-empty');

		# Available should be 10.0.0.37-10.0.0.250
		is($available->start->address, '10.0.0.37', 'available starts at .37');
		is($available->end->address,   '10.0.0.250', 'available ends at .250');
		is($available->size, 214, 'available has 214 IPs');

		# Reserved should cover 10.0.0.0-10.0.0.36 and 10.0.0.251-10.0.0.255
		ok($reserved->contains(IPv4->address('10.0.0.0')), 'reserved contains .0');
		ok($reserved->contains(IPv4->address('10.0.0.36')), 'reserved contains .36');
		ok($reserved->contains(IPv4->address('10.0.0.255')), 'reserved contains .255');
		ok(!$reserved->contains(IPv4->address('10.0.0.37')), 'reserved does not contain .37');
	};

	subtest 'both reserved and available (ocfp-1 pattern)' => sub {
		# ocfp-1: has reserved_a/reserved_b AND available_a/available_b
		my $subnet = $ocfp_config->{vpc}{subnets}{'ocfp-1'};
		my ($available, $reserved) = Genesis::Commands::Ocfp::ShowNetwork::_compute_ranges($subnet);

		ok($available > 0, 'available range is non-empty');
		ok($reserved > 0, 'reserved range is non-empty');

		# Available is defined as 10.0.1.16-10.0.1.250, minus reserved 10.0.1.0-10.0.1.36
		# Since reserved overlaps with available start (10.0.1.16-10.0.1.36 is both),
		# the net available should be 10.0.1.37-10.0.1.250
		is($available->start->address, '10.0.1.37', 'available starts at .37 after reserved subtraction');
		is($available->end->address,   '10.0.1.250', 'available ends at .250');
	};

	subtest 'explicit reserved only (ocfp-2 pattern)' => sub {
		# ocfp-2: has reserved_a/reserved_b and reserved_c/reserved_d, no available
		my $subnet = $ocfp_config->{vpc}{subnets}{'ocfp-2'};
		my ($available, $reserved) = Genesis::Commands::Ocfp::ShowNetwork::_compute_ranges($subnet);

		ok($available > 0, 'available range is non-empty');
		ok($reserved > 0, 'reserved range is non-empty');

		# Reserved: 10.0.2.0-10.0.2.36 and 10.0.2.255-10.0.2.255
		ok($reserved->contains(IPv4->address('10.0.2.0')), 'reserved contains .0');
		ok($reserved->contains(IPv4->address('10.0.2.36')), 'reserved contains .36');
		ok($reserved->contains(IPv4->address('10.0.2.255')), 'reserved contains .255');

		# Available: everything else => 10.0.2.37-10.0.2.254
		is($available->start->address, '10.0.2.37', 'available starts at .37');
		is($available->end->address,   '10.0.2.254', 'available ends at .254');
	};

	subtest 'no explicit ranges defaults' => sub {
		# When no reserved_* or available_* keys exist, defaults apply:
		# reserved: .0-.4 and .255, available: full range minus reserved
		my $subnet = {
			cidr_block    => '10.0.3.0/24',
			'reserved-ips' => {
				'some_ip' => '10.0.3.10',
			},
		};
		my ($available, $reserved) = Genesis::Commands::Ocfp::ShowNetwork::_compute_ranges($subnet);

		ok($available > 0, 'available range is non-empty');
		ok($reserved > 0, 'reserved range is non-empty');

		# Default reserved: .0-.4 and .255
		ok($reserved->contains(IPv4->address('10.0.3.0')), 'default reserved contains .0');
		ok($reserved->contains(IPv4->address('10.0.3.4')), 'default reserved contains .4');
		ok($reserved->contains(IPv4->address('10.0.3.255')), 'default reserved contains .255');
		ok(!$reserved->contains(IPv4->address('10.0.3.5')), 'default reserved does not contain .5');

		# Available: .5-.254
		is($available->start->address, '10.0.3.5', 'default available starts at .5');
		is($available->end->address,   '10.0.3.254', 'default available ends at .254');
		is($available->size, 250, 'default available has 250 IPs');
	};

	subtest 'missing reserved-ips key entirely' => sub {
		# When reserved-ips key is absent (undef), should not crash
		my $subnet = {
			cidr_block => '10.0.4.0/24',
		};
		my ($available, $reserved);
		lives_ok(
			sub { ($available, $reserved) = Genesis::Commands::Ocfp::ShowNetwork::_compute_ranges($subnet) },
			'does not crash when reserved-ips is missing'
		);
		ok($available > 0, 'available range computed with defaults');
		ok($reserved > 0, 'reserved range computed with defaults');
	};

};

# ============================================================================
# Tests: _gather_network_data
# ============================================================================

subtest '_gather_network_data' => sub {

	subtest 'basic data gathering with BOSH claims' => sub {
		my $env = mock_env();
		my $data = Genesis::Commands::Ocfp::ShowNetwork::_gather_network_data($env);

		is($data->{env_name},  'test-env-ocf', 'env_name set correctly');
		is($data->{ocfp_type}, 'ocf',          'ocfp_type detected correctly');
		is($data->{vpc_cidr},  '192.168.0.0/20', 'vpc_cidr from config');

		ok(exists $data->{vpc_info}, 'vpc_info present');
		is($data->{vpc_info}{total_addresses}, 4096, 'vpc_info computed');

		# Verify subnets
		ok(exists $data->{subnets}{'ocfp-0'}, 'ocfp-0 subnet present');
		ok(exists $data->{subnets}{'ocfp-1'}, 'ocfp-1 subnet present');
		ok(exists $data->{subnets}{'ocfp-2'}, 'ocfp-2 subnet present');
		is(scalar keys %{$data->{subnets}}, 3, 'exactly 3 subnets');

		# Verify subnet fields
		my $s0 = $data->{subnets}{'ocfp-0'};
		is($s0->{cidr_block}, '10.0.0.0/24', 'subnet cidr_block');
		is($s0->{az},         'az1',          'subnet az');
		is($s0->{gateway},    '10.0.0.1',    'subnet gateway');
		is($s0->{dns},        '10.0.0.2',    'subnet dns');

		# Verify CIDR info
		is($s0->{cidr_info}{total_addresses}, 256, 'cidr_info computed');

		# Verify ranges are IPv4 objects
		ok(ref($s0->{available_range}), 'available_range is an object');
		ok(ref($s0->{reserved_range}),  'reserved_range is an object');
		ok(ref($s0->{allocated_range}), 'allocated_range is an object');
		ok(ref($s0->{free_range}),      'free_range is an object');

		# Verify claims from BOSH exodus data
		ok(exists $s0->{claims}{'test-env.bosh.net-default'}, 'BOSH claim present');
		is($s0->{claims}{'test-env.bosh.net-default'}, '10.0.0.37-10.0.0.60', 'BOSH claim range correct');

		# Verify allocated range includes claims
		ok($s0->{allocated_range}->size > 0, 'allocated range non-empty with claims');
	};

	subtest 'create-env graceful degradation' => sub {
		my $env = mock_env(use_create_env => 1);
		my $data;
		lives_ok(
			sub { $data = Genesis::Commands::Ocfp::ShowNetwork::_gather_network_data($env) },
			'gathers data without dying for create-env'
		);

		ok(exists $data->{subnets}{'ocfp-0'}, 'subnets still present');
		my $s0 = $data->{subnets}{'ocfp-0'};

		# No claims since director exodus is unavailable
		is_deeply($s0->{claims}, {}, 'no claims for create-env');
		is($s0->{allocated_range}->size, 0, 'no allocations for create-env');

		# But ranges should still be computed from OCFP config
		ok($s0->{available_range}->size > 0, 'available range still computed');
		ok($s0->{reserved_range}->size > 0, 'reserved range still computed');
	};

	subtest 'subnet with no BOSH claims' => sub {
		my $env = mock_env();
		my $data = Genesis::Commands::Ocfp::ShowNetwork::_gather_network_data($env);

		# ocfp-2 has no claims in the BOSH exodus data
		my $s2 = $data->{subnets}{'ocfp-2'};
		is_deeply($s2->{claims}, {}, 'no claims for unclaimed subnet');
		is($s2->{allocated_range}->size, 0, 'no allocations for unclaimed subnet');

		# Free should equal available
		is($s2->{free_range}->size, $s2->{available_range}->size,
			'free equals available when nothing allocated');
	};

};

# ============================================================================
# Tests: _filter_by_subnet
# ============================================================================

subtest '_filter_by_subnet' => sub {
	my $env = mock_env();
	my $data = Genesis::Commands::Ocfp::ShowNetwork::_gather_network_data($env);

	subtest 'valid subnet filter' => sub {
		my $filtered = Genesis::Commands::Ocfp::ShowNetwork::_filter_by_subnet($data, 'ocfp-0');
		is(scalar keys %{$filtered->{subnets}}, 1, 'filtered to one subnet');
		ok(exists $filtered->{subnets}{'ocfp-0'}, 'correct subnet retained');
		is($filtered->{env_name}, $data->{env_name}, 'env_name preserved');
		is($filtered->{vpc_cidr}, $data->{vpc_cidr}, 'vpc_cidr preserved');
	};

	subtest 'invalid subnet filter bails' => sub {
		throws_ok(
			sub { Genesis::Commands::Ocfp::ShowNetwork::_filter_by_subnet($data, 'nonexistent') },
			qr/Unknown subnet 'nonexistent'/,
			'bails on unknown subnet'
		);
	};
};

# ============================================================================
# Tests: _extract_named_reserved
# ============================================================================

subtest '_extract_named_reserved' => sub {

	subtest 'extracts named IPs, skips pairs and flags' => sub {
		my $reserved_ips = {
			'available_a' => '10.0.0.37',
			'available_b' => '10.0.0.250',
			'bosh_ip'     => '10.0.0.5',
			'director_ip' => '10.0.0.6',
			'network_a'   => '10.0.0.10',
			'network_b'   => '10.0.0.20',
			'network_static' => 1,
		};
		my $named = Genesis::Commands::Ocfp::ShowNetwork::_extract_named_reserved($reserved_ips);
		my @names = map { $_->{name} } @$named;
		ok(grep({ $_ eq 'bosh_ip' } @names), 'includes bosh_ip');
		ok(grep({ $_ eq 'director_ip' } @names), 'includes director_ip');
		ok(!grep({ $_ eq 'available_a' } @names), 'excludes available_a');
		ok(!grep({ $_ eq 'network_static' } @names), 'excludes network_static');
	};

};

# ============================================================================
# Tests: Output mode selection (run dispatch)
# ============================================================================

subtest 'run dispatches to correct output mode' => sub {
	my $env = mock_env();

	# We test that run doesn't die for each mode
	lives_ok(
		sub { Genesis::Commands::Ocfp::ShowNetwork::run($env, json => 1) },
		'json output mode runs without error'
	);

	lives_ok(
		sub { Genesis::Commands::Ocfp::ShowNetwork::run($env, summary => 1) },
		'summary output mode runs without error'
	);

	lives_ok(
		sub { Genesis::Commands::Ocfp::ShowNetwork::run($env, reserved => 1) },
		'reserved output mode runs without error'
	);

	lives_ok(
		sub { Genesis::Commands::Ocfp::ShowNetwork::run($env, allocated => 1) },
		'allocated output mode runs without error'
	);

	lives_ok(
		sub { Genesis::Commands::Ocfp::ShowNetwork::run($env, available => 1) },
		'available output mode runs without error'
	);

	lives_ok(
		sub { Genesis::Commands::Ocfp::ShowNetwork::run($env) },
		'full (default) output mode runs without error'
	);

	lives_ok(
		sub { Genesis::Commands::Ocfp::ShowNetwork::run($env, verbose => 1) },
		'verbose output mode runs without error'
	);

	lives_ok(
		sub { Genesis::Commands::Ocfp::ShowNetwork::run($env, subnet => 'ocfp-0') },
		'subnet filter runs without error'
	);
};

# ============================================================================
# Tests: Compact output format
# ============================================================================

subtest 'compact output format' => sub {
	my $env = mock_env();

	# Capture full default (non-verbose) output via STDERR (info() writes to STDERR)
	my $output = '';
	{
		local *STDERR;
		open STDERR, '>', \$output or die "Cannot redirect STDERR: $!";
		Genesis::Commands::Ocfp::ShowNetwork::run($env);
	}

	subtest 'no CIDR info in default mode' => sub {
		unlike($output, qr/CIDR Info/,    'no CIDR Info header in default output');
		unlike($output, qr/Netmask:/,     'no Netmask line in default output');
		unlike($output, qr/Wildcard:/,    'no Wildcard line in default output');
		unlike($output, qr/Broadcast:/,   'no Broadcast line in default output');
		unlike($output, qr/Total Addresses:/, 'no Total Addresses in default output');
	};

	subtest 'CIDR info present in verbose mode' => sub {
		my $verbose_output = '';
		{
			local *STDERR;
			open STDERR, '>', \$verbose_output or die "Cannot redirect STDERR: $!";
			Genesis::Commands::Ocfp::ShowNetwork::run($env, verbose => 1);
		}
		like($verbose_output, qr/CIDR Info/,    'CIDR Info header in verbose output');
		like($verbose_output, qr/Netmask:/,     'Netmask line in verbose output');
		like($verbose_output, qr/Wildcard:/,    'Wildcard line in verbose output');
		like($verbose_output, qr/Broadcast:/,   'Broadcast line in verbose output');
		like($verbose_output, qr/Total Addresses:/, 'Total Addresses in verbose output');
	};

	subtest 'lightweight separator' => sub {
		# Should not have full-width '=' separator
		unlike($output, qr/={40,}/, 'no full-width = separator');
		# Should have the 40-char dash separator
		like($output, qr/-{40}/, 'has 40-char dash separator');
	};

	subtest 'utilization bar shows counts and percentages' => sub {
		# Bar should show format like R:42/16% A:44/17% F:170/66%
		like($output, qr/R:\d+\/\d+%/, 'reserved shows count/percentage');
		like($output, qr/A:\d+\/\d+%/, 'allocated shows count/percentage');
		like($output, qr/F:\d+\/\d+%/, 'free shows count/percentage');
	};

	subtest 'combined assignments table' => sub {
		# Should have Type column
		like($output, qr/Type.*Name.*IP \/ Range/s, 'assignments table has correct headers');
		# Should have reserved and allocated rows
		like($output, qr/reserved.*bosh_ip/s, 'table contains reserved entries');
		like($output, qr/allocated.*test-env\.bosh\.net-default/s, 'table contains allocated entries');
	};

	subtest 'compact free range display' => sub {
		# Free line should just show the range, no "X IPs" count
		like($output, qr/Free:.*\d+\.\d+\.\d+\.\d+/, 'free range shown inline');
		unlike($output, qr/Free:\s+\d+\s+IPs/, 'no "X IPs" in free display');
	};
};

# ============================================================================
# Tests: Empty section suppression
# ============================================================================

subtest 'empty section suppression' => sub {
	# ocfp-1 has no named reserved IPs, but has claims
	# ocfp-2 has named reserved IPs but no claims
	# Use an env with no claims at all to test full suppression
	my $env = mock_env(
		bosh_network_data => { subnets => {} },
	);

	my $output = '';
	{
		local *STDERR;
		open STDERR, '>', \$output or die "Cannot redirect STDERR: $!";
		# Run for a subnet that has named reserved but no claims
		Genesis::Commands::Ocfp::ShowNetwork::run($env, subnet => 'ocfp-1');
	}

	# ocfp-1 has no named IPs (only reserved_a/reserved_b pairs)
	# and we gave it no claims, so assignments table should be absent
	unlike($output, qr/Type.*Name.*IP \/ Range/, 'no assignments table when no named IPs and no claims');
};

# ============================================================================
# Tests: JSON output structure
# ============================================================================

subtest 'JSON output structure' => sub {
	my $env = mock_env();

	# Capture JSON output
	my $json_output = '';
	{
		local *STDOUT;
		open STDOUT, '>', \$json_output or die "Cannot redirect STDOUT: $!";
		Genesis::Commands::Ocfp::ShowNetwork::run($env, json => 1);
	}

	my $parsed;
	lives_ok(
		sub { $parsed = JSON::PP->new->decode($json_output) },
		'JSON output is valid JSON'
	);

	is($parsed->{env_name}, 'test-env-ocf', 'JSON env_name correct');
	is($parsed->{vpc_cidr}, '192.168.0.0/20', 'JSON vpc_cidr correct');
	ok(exists $parsed->{subnets}{'ocfp-0'}, 'JSON contains ocfp-0');
	ok(exists $parsed->{subnets}{'ocfp-0'}{cidr_info}, 'JSON contains cidr_info');
	ok(exists $parsed->{subnets}{'ocfp-0'}{claims}, 'JSON contains claims');
};

done_testing();
