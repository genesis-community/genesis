#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use helper;
use Test::More;
use Test::Exception;
use Test::Deep;
use Cwd qw(abs_path);

$ENV{GENESIS_CALLBACK_BIN} ||= abs_path('bin/genesis');
$ENV{GENESIS_LIB} ||= abs_path('lib');
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# ---------------------------------------------------------------------------
# LookupRef
# ---------------------------------------------------------------------------
subtest 'Genesis::Hook::CloudConfig::LookupRef' => sub {
	plan tests => 9;

	use_ok 'Genesis::Hook::CloudConfig::LookupRef';

	subtest 'new() - scalar path is wrapped in arrayref' => sub {
		plan tests => 3;

		my $ref = Genesis::Hook::CloudConfig::LookupRef->new('some.key');
		isa_ok $ref, 'Genesis::Hook::CloudConfig::LookupRef',
			'new() returns a LookupRef object';
		my @paths = $ref->paths;
		is scalar(@paths), 1, 'scalar path produces exactly one entry in paths()';
		is $paths[0], 'some.key', 'scalar path is stored correctly';
	};

	subtest 'new() - arrayref paths are preserved as-is' => sub {
		plan tests => 3;

		my $ref = Genesis::Hook::CloudConfig::LookupRef->new(['key.one', 'key.two', 'key.three']);
		my @paths = $ref->paths;
		is scalar(@paths), 3, 'arrayref with 3 paths produces 3 entries in paths()';
		is $paths[0], 'key.one',   'first path stored correctly';
		is $paths[1], 'key.two',   'second path stored correctly';
	};

	subtest 'paths() - returns list of path strings' => sub {
		plan tests => 2;

		my $ref = Genesis::Hook::CloudConfig::LookupRef->new(['alpha', 'beta']);
		my @paths = $ref->paths;
		is $paths[0], 'alpha', 'paths() returns first path';
		is $paths[1], 'beta',  'paths() returns second path';
	};

	subtest 'default() - returns stored default value' => sub {
		plan tests => 3;

		my $with_default = Genesis::Hook::CloudConfig::LookupRef->new('key', 'fallback');
		is $with_default->default, 'fallback',
			'default() returns the stored default string';

		my $with_undef = Genesis::Hook::CloudConfig::LookupRef->new('key');
		is $with_undef->default, undef,
			'default() returns undef when no default was given';

		my $with_zero = Genesis::Hook::CloudConfig::LookupRef->new('key', 0);
		is $with_zero->default, 0,
			'default() returns 0 when 0 was given as default';
	};

	subtest 'resolve() - finds matching path in config hash' => sub {
		plan tests => 2;

		my $config = { vpc => { region => 'us-east-1' } };

		my $ref = Genesis::Hook::CloudConfig::LookupRef->new('vpc.region');
		is $ref->resolve($config), 'us-east-1',
			'resolve() finds value at a nested dot-notation path';

		my $flat = { host => 'example.com', port => 8080 };
		my $ref2 = Genesis::Hook::CloudConfig::LookupRef->new('port');
		is $ref2->resolve($flat), 8080,
			'resolve() finds a top-level key in a flat hash';
	};

	subtest 'resolve() - falls back to default when no paths match' => sub {
		plan tests => 2;

		my $config = { vpc => { region => 'us-east-1' } };

		my $ref = Genesis::Hook::CloudConfig::LookupRef->new('no.such.key', 'default-value');
		is $ref->resolve($config), 'default-value',
			'resolve() returns string default when path is absent';

		my $ref2 = Genesis::Hook::CloudConfig::LookupRef->new('also.missing', 42);
		is $ref2->resolve($config), 42,
			'resolve() returns numeric default when path is absent';
	};

	subtest 'resolve() - returns undef when no match and no default' => sub {
		plan tests => 1;

		my $config = { vpc => {} };
		my $ref = Genesis::Hook::CloudConfig::LookupRef->new('vpc.nonexistent');
		is $ref->resolve($config), undef,
			'resolve() returns undef when path not found and no default provided';
	};

	subtest 'resolve() - single path, first found value is returned' => sub {
		plan tests => 2;

		my $config = {
			primary   => 'first-value',
			secondary => 'second-value',
		};

		my $ref = Genesis::Hook::CloudConfig::LookupRef->new('primary');
		is $ref->resolve($config), 'first-value',
			'resolve() returns value at single present path';

		my $ref2 = Genesis::Hook::CloudConfig::LookupRef->new('secondary');
		is $ref2->resolve($config), 'second-value',
			'resolve() returns value at another present path';
	};
};

# ---------------------------------------------------------------------------
# LookupNetworkRef
# ---------------------------------------------------------------------------
subtest 'Genesis::Hook::CloudConfig::LookupNetworkRef' => sub {
	plan tests => 7;

	use_ok 'Genesis::Hook::CloudConfig::LookupNetworkRef';

	subtest 'new() - stores ref, lookup_method, and lookup_args' => sub {
		plan tests => 3;

		my $obj = Genesis::Hook::CloudConfig::LookupNetworkRef->new('vpc_id', 'my_method', 'arg1', 'arg2');
		is $obj->{ref},           'vpc_id',    'ref is stored correctly';
		is $obj->{lookup_method}, 'my_method', 'lookup_method is stored correctly';
		cmp_deeply $obj->{lookup_args}, ['arg1', 'arg2'],
			'lookup_args are stored as arrayref';
	};

	subtest 'resolve() - Strategy 1: CODE reference is called with (config, network_data, ref, @args)' => sub {
		plan tests => 3;

		my @call_args;
		my $coderef = sub {
			@call_args = @_;
			return 'code-result';
		};

		my $config       = { marker => 'config-obj' };
		my $network_data = { vpc_id => 'vpc-123' };

		my $obj = Genesis::Hook::CloudConfig::LookupNetworkRef->new('vpc_id', $coderef, 'extra1');
		my $result = $obj->resolve($config, $network_data);

		is $result, 'code-result',
			'resolve() returns value from CODE reference';
		is $call_args[0], $config,
			'CODE reference receives config as first argument';
		is $call_args[2], 'vpc_id',
			'CODE reference receives ref as third argument';
	};

	subtest 'resolve() - Strategy 1: CODE reference receives lookup_args' => sub {
		plan tests => 2;

		my @call_args;
		my $coderef = sub { @call_args = @_; return 'done' };
		my $obj = Genesis::Hook::CloudConfig::LookupNetworkRef->new(
			'my_ref', $coderef, 'argA', 'argB'
		);

		$obj->resolve({}, {});

		is $call_args[3], 'argA', 'CODE reference receives first lookup_arg';
		is $call_args[4], 'argB', 'CODE reference receives second lookup_arg';
	};

	subtest 'resolve() - Strategy 2: named method on config object is called' => sub {
		plan tests => 3;

		my @received;
		my $config = mock "NetRef::MockConfig1" => {}, {
			my_lookup => sub {
				my ($self, $network_data, $ref, @args) = @_;
				@received = ($network_data, $ref, @args);
				return 'method-result';
			},
		};

		my $network_data = { az => 'az1' };
		my $obj = Genesis::Hook::CloudConfig::LookupNetworkRef->new(
			'az', 'my_lookup', 'extra'
		);

		my $result = $obj->resolve($config, $network_data);

		is $result, 'method-result',
			'resolve() returns value from named method on config';
		is $received[1], 'az',
			'named method receives ref as second argument';
		is $received[2], 'extra',
			'named method receives lookup_args';
	};

	subtest 'resolve() - Strategy 3: direct hash lookup in network_data' => sub {
		plan tests => 2;

		my $config = mock "NetRef::MockConfig2" => {}, {};

		my $network_data = { net_id => 'vpc-abc123', other => 'x' };
		my $obj = Genesis::Hook::CloudConfig::LookupNetworkRef->new('net_id', undef);

		my $result = $obj->resolve($config, $network_data);
		is $result, 'vpc-abc123',
			'resolve() returns direct hash value from network_data';

		my $obj2 = Genesis::Hook::CloudConfig::LookupNetworkRef->new('other', undef);
		is $obj2->resolve($config, $network_data), 'x',
			'resolve() returns correct value for another key';
	};

	subtest 'resolve() - dies with informative message when ref not found' => sub {
		plan tests => 2;

		my $config = mock "NetRef::MockConfig3" => {}, {};
		my $network_data = { existing_key => 'value' };

		my $obj = Genesis::Hook::CloudConfig::LookupNetworkRef->new('nonexistent_ref', undef);

		throws_ok {
			$obj->resolve($config, $network_data)
		} qr/Could not resolve reference 'nonexistent_ref' in network data/,
			'resolve() throws when ref not found in network_data';

		throws_ok {
			$obj->resolve($config, $network_data)
		} qr/Could not resolve reference/,
			'resolve() always throws when ref is absent';
	};
};

# ---------------------------------------------------------------------------
# LookupSubnetRef
# ---------------------------------------------------------------------------
subtest 'Genesis::Hook::CloudConfig::LookupSubnetRef' => sub {
	plan tests => 5;

	use_ok 'Genesis::Hook::CloudConfig::LookupSubnetRef';

	subtest 'new() - stores ref, lookup_method, and lookup_args' => sub {
		plan tests => 3;

		my $obj = Genesis::Hook::CloudConfig::LookupSubnetRef->new('cidr_block', 'my_method', 'arg1');
		is $obj->{ref},           'cidr_block', 'ref is stored correctly';
		is $obj->{lookup_method}, 'my_method',  'lookup_method is stored correctly';
		cmp_deeply $obj->{lookup_args}, ['arg1'],
			'lookup_args stored as arrayref';
	};

	subtest 'resolve() - Strategy 1: named method on config is called with (subnet_data, ref, @args)' => sub {
		plan tests => 3;

		my @received;
		my $config = mock "SubnetRef::MockConfig1" => {}, {
			subnet_lookup => sub {
				my ($self, $subnet_data, $ref, @args) = @_;
				@received = ($subnet_data, $ref, @args);
				return 'subnet-method-result';
			},
		};

		my $subnet_data = { cidr_block => '10.0.0.0/24', az => 'az1' };
		my $obj = Genesis::Hook::CloudConfig::LookupSubnetRef->new(
			'cidr_block', 'subnet_lookup', 'extra-arg'
		);

		my $result = $obj->resolve($config, $subnet_data);

		is $result, 'subnet-method-result',
			'resolve() returns value from named method on config';
		is $received[1], 'cidr_block',
			'named method receives ref as second argument';
		is $received[2], 'extra-arg',
			'named method receives lookup_args';
	};

	subtest 'resolve() - Strategy 2: direct key lookup in subnet_data' => sub {
		plan tests => 3;

		my $config = mock "SubnetRef::MockConfig2" => {}, {};

		my $subnet_data = {
			cidr_block => '10.0.1.0/24',
			gateway    => '10.0.1.1',
			az         => 'az2',
		};

		my $obj = Genesis::Hook::CloudConfig::LookupSubnetRef->new('cidr_block', undef);
		is $obj->resolve($config, $subnet_data), '10.0.1.0/24',
			'resolve() returns cidr_block from subnet_data directly';

		my $obj2 = Genesis::Hook::CloudConfig::LookupSubnetRef->new('gateway', undef);
		is $obj2->resolve($config, $subnet_data), '10.0.1.1',
			'resolve() returns gateway from subnet_data directly';

		my $obj3 = Genesis::Hook::CloudConfig::LookupSubnetRef->new('az', undef);
		is $obj3->resolve($config, $subnet_data), 'az2',
			'resolve() returns az from subnet_data directly';
	};

	subtest 'resolve() - dies with informative message when ref not found' => sub {
		plan tests => 2;

		my $config = mock "SubnetRef::MockConfig3" => {}, {};
		my $subnet_data = { known_key => 'value' };

		my $obj = Genesis::Hook::CloudConfig::LookupSubnetRef->new('missing_ref', undef);

		throws_ok {
			$obj->resolve($config, $subnet_data)
		} qr/Could not resolve reference 'missing_ref' in subnet data/,
			'resolve() throws when ref not found in subnet_data';

		throws_ok {
			$obj->resolve($config, $subnet_data)
		} qr/Could not resolve reference/,
			'resolve() always throws when ref is absent';
	};
};

done_testing;
