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
use Digest::SHA qw(sha1_hex);

$ENV{GENESIS_CALLBACK_BIN} ||= abs_path('bin/genesis');
$ENV{GENESIS_LIB} ||= abs_path('lib');
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# ---------------------------------------------------------------------------
# Load the module under test
# ---------------------------------------------------------------------------
require_ok 'Genesis::Hook::CpiConfig';

# ---------------------------------------------------------------------------
# Test subclass - Genesis::Hook requires the class name to match
# Genesis::Hook::<Type>::<KitName> so that label() can parse it.
# ---------------------------------------------------------------------------
{
	package Genesis::Hook::CpiConfig::test_kit;
	use parent -norequire, 'Genesis::Hook::CpiConfig';

	sub perform {
		my ($self) = @_;
		my $config = $self->build_cpi_config_for_iaas(
			aws => { region => 'us-east-1' },
		);
		$self->done($config);
	}
}

# ---------------------------------------------------------------------------
# Shared kit and bosh mocks
# ---------------------------------------------------------------------------

my $kit = mock "Genesis::Kit::CpiConfig" => {
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

my $bosh = mock "Genesis::BOSH::CpiConfig" => {
	alias                => 'mock-bosh',
	connect_and_validate => sub { return $_[0] },
};

# Each call to mock_env() uses a unique env name so each subtest gets a fresh
# CpiConfig object from init().
my $test_seq = 0;

sub mock_env {
	$test_seq++;
	my $seq = $test_seq;
	my $tmp = workdir("cpiconfig-$seq");
	mock "Genesis::Env::CpiConfig::$seq" => {(
		name            => "test-env-$seq",
		type            => 'bosh',
		kit             => $kit,
		bosh            => $bosh,
		use_create_env  => 0,
		features        => Mock::ReferencedValue->new(['ha', 'tls']),
		iaas            => 'aws',
		scale           => 'dev',
		is_ocfp         => 0,
		cpi_name        => 'aws_cpi',
		cpi_credhub_base => '/bosh/my-env/',
		workdir         => $tmp,
		workpath => sub {
			my ($self, $path) = @_;
			return "$tmp/$path";
		},
		lookup => sub {
			my ($self, $key, $default) = @_;
			return wantarray ? ($default, undef) : $default;
		},
		ocfp_config_lookup => sub {
			my ($self, $key, $default) = @_;
			return wantarray ? ($default, undef) : $default;
		},
		lookup_unevaled => sub {
			my ($self, $key) = @_;
			return {};
		},
		exodus_lookup => sub {
			my ($self, $key, $default) = @_;
			return $default;
		},
		deployments => mock("Genesis::Env::CpiConfig::Deployments::$seq" => {
			current_state => 'deployed',
		}),
		file => 'test-env.yml',
	), @_};
}

sub make_hook {
	my $env = shift || mock_env();
	return Genesis::Hook::CpiConfig::test_kit->init(env => $env, @_);
}

# ---------------------------------------------------------------------------
# Globals set before all subtests
# ---------------------------------------------------------------------------
$Genesis::VERSION = '3.1.0-rc.10';
$ENV{GENESIS_CALL_BIN} = 'genesis';
$ENV{GENESIS_KIT_HOOK} = 'cpi-config';

# ---------------------------------------------------------------------------
# Genesis::Hook::CpiConfig module loads
# ---------------------------------------------------------------------------
subtest 'Genesis::Hook::CpiConfig module loads' => sub {
	plan tests => 1;
	ok(defined(&Genesis::Hook::CpiConfig::init), 'Genesis::Hook::CpiConfig::init is defined');
};

# ---------------------------------------------------------------------------
# init
# ---------------------------------------------------------------------------
subtest 'init - missing env dies' => sub {
	plan tests => 1;

	throws_ok {
		Genesis::Hook::CpiConfig::test_kit->init()
	} qr/Missing required arguments for a perl-based kit hook call: env/,
		'init() without env argument dies with required-args message';
};

subtest 'init - returns blessed object with env set' => sub {
	plan tests => 4;

	my $env = mock_env();
	my $hook;
	lives_ok {
		$hook = Genesis::Hook::CpiConfig::test_kit->init(env => $env)
	} 'init() succeeds with valid env';

	ok(defined $hook, 'init() returns a defined value');
	isa_ok($hook, 'Genesis::Hook::CpiConfig', 'returned object isa Genesis::Hook::CpiConfig');
	is($hook->env, $env, 'env() returns the env passed to init()');
};

subtest 'init - initializes empty cpi_config hash' => sub {
	plan tests => 2;

	my $hook = make_hook();

	ok(exists $hook->{cpi_config}, 'cpi_config key exists on hook after init');
	cmp_deeply($hook->{cpi_config}, {}, 'cpi_config is an empty hashref after init');
};

subtest 'init - initializes empty credhub_secrets hash' => sub {
	plan tests => 2;

	my $hook = make_hook();

	ok(exists $hook->{credhub_secrets}, 'credhub_secrets key exists on hook after init');
	cmp_deeply($hook->{credhub_secrets}, {}, 'credhub_secrets is an empty hashref after init');
};

subtest 'init - complete flag starts at 0' => sub {
	plan tests => 1;

	my $hook = make_hook();
	is($hook->{complete}, 0, 'complete flag initializes to 0');
};

# ---------------------------------------------------------------------------
# done
# ---------------------------------------------------------------------------
subtest 'done - with config: serializes to yaml and sets complete=1' => sub {
	plan tests => 5;

	my $hook = make_hook();

	my $config = {
		cpis => [
			{ name => 'aws_cpi', type => 'aws', properties => { region => 'us-east-1' } }
		]
	};

	my $ret;
	lives_ok {
		$ret = $hook->done($config);
	} 'done($config) does not die';

	is($ret, 1, 'done($config) returns 1');
	is($hook->{complete}, 1, 'complete flag set to 1 after done($config)');
	ok(defined $hook->{contents}, 'contents is defined after done($config)');
	like($hook->{contents}, qr/cpis:/i, 'contents contains YAML with cpis key');
};

subtest 'done - with config: contents is a YAML string' => sub {
	plan tests => 2;

	my $hook = make_hook();
	my $config = {
		cpis => [
			{ name => 'test_cpi', type => 'vsphere', properties => { datacenter => 'my-dc' } }
		]
	};

	$hook->done($config);

	like($hook->{contents}, qr/name:.*test_cpi|test_cpi/s,
		'YAML contents includes cpi name');
	like($hook->{contents}, qr/vsphere/,
		'YAML contents includes iaas type');
};

subtest 'done - without config: sets contents to undef and sets complete=1' => sub {
	plan tests => 3;

	my $hook = make_hook();
	my $ret = $hook->done(undef, undef);

	is($ret, 1, 'done(undef) returns 1');
	is($hook->{complete}, 1, 'complete flag set to 1 after done(undef)');
	ok(!defined $hook->{contents}, 'contents is undef when done(undef)');
};

subtest 'done - with error message: stores error and sets complete=1' => sub {
	plan tests => 3;

	my $hook = make_hook();
	my $ret = $hook->done(undef, 'IaaS not supported');

	is($ret, 1, 'done(undef, $error) returns 1');
	is($hook->{complete}, 1, 'complete flag set to 1 after done with error');
	is($hook->{error}, 'IaaS not supported', 'error stored from done(undef, $error)');
};

subtest 'done - without error: error field is undef' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $config = { cpis => [{ name => 'aws_cpi', type => 'aws', properties => {} }] };
	$hook->done($config);

	ok(!defined $hook->{error}, 'error is undef when done($config) called without error arg');
};

# ---------------------------------------------------------------------------
# results
# ---------------------------------------------------------------------------
subtest 'results - returns undef in scalar context when not completed' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $r = $hook->results;
	ok(!defined $r, 'results() returns undef in scalar context before done()');
};

subtest 'results - returns empty list in list context when not completed' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my @r = $hook->results;
	is(scalar @r, 0, 'results() returns empty list in list context before done()');
};

subtest 'results - scalar context returns hashref after done($config)' => sub {
	plan tests => 4;

	my $hook = make_hook();
	my $config = { cpis => [{ name => 'aws_cpi', type => 'aws', properties => {} }] };
	$hook->done($config);

	my $r = $hook->results;
	ok(defined $r, 'results() returns defined value after done($config)');
	ok(ref $r eq 'HASH', 'results() returns a hashref in scalar context');
	ok(exists $r->{content}, 'hashref has "content" key');
	ok(exists $r->{credhub_secrets}, 'hashref has "credhub_secrets" key');
};

subtest 'results - scalar context hashref has content/credhub_secrets/error keys' => sub {
	plan tests => 3;

	my $hook = make_hook();
	my $config = { cpis => [{ name => 'aws_cpi', type => 'aws', properties => {} }] };
	$hook->done($config, 'some error');

	my $r = $hook->results;
	ok(exists $r->{error}, 'hashref has "error" key');
	is($r->{error}, 'some error', 'error key holds the error message');
	ok(defined $r->{content}, 'content key holds YAML string');
};

subtest 'results - list context returns 3-tuple after done($config)' => sub {
	plan tests => 3;

	my $hook = make_hook();
	my $config = { cpis => [{ name => 'aws_cpi', type => 'aws', properties => {} }] };
	$hook->done($config);

	my ($content, $secrets, $error) = $hook->results;
	ok(defined $content, 'list context: first element (content) is defined');
	ok(ref $secrets eq 'HASH', 'list context: second element (credhub_secrets) is a hashref');
	ok(!defined $error, 'list context: third element (error) is undef when no error given');
};

subtest 'results - list context returns 3-tuple with undef content when no config' => sub {
	plan tests => 3;

	my $hook = make_hook();
	$hook->done(undef, 'no config produced');

	my ($content, $secrets, $error) = $hook->results;
	ok(!defined $content, 'list context: content is undef when no config given to done()');
	ok(ref $secrets eq 'HASH', 'list context: secrets is always a hashref');
	is($error, 'no config produced', 'list context: error message is returned');
};

subtest 'results - credhub_secrets in results is initially empty hashref' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $config = { cpis => [{ name => 'aws_cpi', type => 'aws', properties => {} }] };
	$hook->done($config);

	my $r = $hook->results;
	cmp_deeply($r->{credhub_secrets}, {}, 'credhub_secrets is empty hashref when no secrets gathered');
};

# ---------------------------------------------------------------------------
# build_cpi_config_for_iaas
# ---------------------------------------------------------------------------
subtest 'build_cpi_config_for_iaas - valid IaaS with hash value returns correct structure' => sub {
	plan tests => 5;

	my $hook = make_hook();
	my $props = { region => 'us-east-1', default_key_name => 'bosh' };

	my $config;
	lives_ok {
		$config = $hook->build_cpi_config_for_iaas(
			aws     => $props,
			vsphere => { datacenter => 'my-dc' },
		);
	} 'build_cpi_config_for_iaas() does not die for known IaaS';

	ok(ref $config eq 'HASH', 'returned value is a hashref');
	ok(exists $config->{cpis}, 'returned hashref has "cpis" key');
	ok(ref $config->{cpis} eq 'ARRAY', '"cpis" value is an arrayref');
	is(scalar @{$config->{cpis}}, 1, '"cpis" array has exactly one entry');
};

subtest 'build_cpi_config_for_iaas - cpi entry has correct name, type, and properties' => sub {
	plan tests => 3;

	my $hook = make_hook();
	my $props = { region => 'us-east-1' };

	my $config = $hook->build_cpi_config_for_iaas(aws => $props);

	my $cpi = $config->{cpis}[0];
	is($cpi->{name}, 'aws_cpi', 'cpi name comes from env->cpi_name');
	is($cpi->{type}, 'aws',     'cpi type matches the IaaS key selected');
	cmp_deeply($cpi->{properties}, $props, 'cpi properties matches the supplied hashref');
};

subtest 'build_cpi_config_for_iaas - valid IaaS with code ref value: coderef is called' => sub {
	plan tests => 2;

	my $hook = make_hook();
	my $called = 0;
	my $props  = { region => 'us-west-2', called => 1 };

	my $config = $hook->build_cpi_config_for_iaas(
		aws => sub { $called = 1; return $props },
	);

	is($called, 1, 'code ref was invoked by build_cpi_config_for_iaas');
	cmp_deeply($config->{cpis}[0]{properties}, $props,
		'properties come from the code ref return value');
};

subtest 'build_cpi_config_for_iaas - unsupported IaaS dies with descriptive message' => sub {
	plan tests => 1;

	my $hook = make_hook();

	throws_ok {
		$hook->build_cpi_config_for_iaas(
			vsphere => { datacenter => 'my-dc' },
		);
	} qr/Unsupported IaaS: aws/,
		'dies with "Unsupported IaaS: aws" when env IaaS not in dispatch table';
};

subtest 'build_cpi_config_for_iaas - selects only the matching IaaS entry' => sub {
	plan tests => 2;

	my $hook = make_hook();  # env->iaas = 'aws'
	my $aws_props   = { region => 'us-east-1' };
	my $vsph_props  = { datacenter => 'should-not-appear' };

	my $config = $hook->build_cpi_config_for_iaas(
		aws     => $aws_props,
		vsphere => $vsph_props,
	);

	cmp_deeply($config->{cpis}[0]{properties}, $aws_props,
		'aws properties are selected, not vsphere');
	is($config->{cpis}[0]{type}, 'aws', 'type is aws, not vsphere');
};

# ---------------------------------------------------------------------------
# cpi_entombment_path_for
# ---------------------------------------------------------------------------
subtest 'cpi_entombment_path_for - returns deterministic path for known key/value' => sub {
	plan tests => 2;

	my $hook = make_hook();
	my $key   = 'vcenter_password';
	my $value = 's3cr3t';

	my $stub = 'cpi-config-property';
	my $expected_sha = substr(sha1_hex("$stub--$key--$value"), 0, 8);
	my $expected_path = "/bosh/my-env/${stub}--${key}--${expected_sha}";

	my $path;
	lives_ok {
		$path = $hook->cpi_entombment_path_for($key, $value);
	} 'cpi_entombment_path_for() does not die';

	is($path, $expected_path,
		'returned path matches expected deterministic CredHub path');
};

subtest 'cpi_entombment_path_for - path uses env->cpi_credhub_base as prefix' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $path = $hook->cpi_entombment_path_for('region', 'us-east-1');

	ok($path =~ m{^/bosh/my-env/}, 'path is prefixed with cpi_credhub_base from env');
};

subtest 'cpi_entombment_path_for - uses credhub_prefix override when set' => sub {
	plan tests => 1;

	my $hook = make_hook();
	$hook->{credhub_prefix} = '/cpi-config/properties/';

	my $key   = 'api_key';
	my $value = 'abc123';
	my $stub  = 'cpi-config-property';
	my $sha   = substr(sha1_hex("$stub--$key--$value"), 0, 8);

	my $path = $hook->cpi_entombment_path_for($key, $value);
	is($path, "/cpi-config/properties/${stub}--${key}--${sha}",
		'credhub_prefix override is used when set on hook');
};

subtest 'cpi_entombment_path_for - dotted keys are flattened out of the path' => sub {
	plan tests => 3;

	my $hook  = make_hook();
	my $key   = 'pve.host';
	my $value = 'pve.example.com';

	my $stub = 'cpi-config-property';
	my $sha  = substr(sha1_hex("$stub--$key--$value"), 0, 8);

	my $path = $hook->cpi_entombment_path_for($key, $value);

	is($path, "/bosh/my-env/${stub}--pve_host--${sha}",
		'dot in the property key is replaced in the CredHub path');
	unlike($path, qr/\./,
		'returned path contains no dot for BOSH to split the reference on');
	isnt($path, $hook->cpi_entombment_path_for('pve_host', $value),
		'a key that flattens alike still gets its own path, since the sha covers the original key');
};

subtest 'cpi_entombment_path_for - different values produce different paths' => sub {
	plan tests => 1;

	my $hook   = make_hook();
	my $path_a = $hook->cpi_entombment_path_for('password', 'secret-a');
	my $path_b = $hook->cpi_entombment_path_for('password', 'secret-b');

	isnt($path_a, $path_b, 'different values for the same key produce different CredHub paths');
};

subtest 'cpi_entombment_path_for - different keys produce different paths' => sub {
	plan tests => 1;

	my $hook   = make_hook();
	my $path_a = $hook->cpi_entombment_path_for('key-one', 'same-value');
	my $path_b = $hook->cpi_entombment_path_for('key-two', 'same-value');

	isnt($path_a, $path_b, 'different keys with the same value produce different CredHub paths');
};

subtest 'cpi_entombment_path_for - same key/value is idempotent' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $path_a = $hook->cpi_entombment_path_for('region', 'us-east-1');
	my $path_b = $hook->cpi_entombment_path_for('region', 'us-east-1');

	is($path_a, $path_b, 'same key and value always produce the same CredHub path');
};

subtest 'cpi_entombment_path_for - SHA1 stub is exactly 8 hex characters' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $path = $hook->cpi_entombment_path_for('api_key', 'my-secret');

	# The sha portion is the 8 hex chars at the end after the last '--'
	my ($sha_part) = $path =~ /--([0-9a-f]+)$/;
	is(length($sha_part), 8, 'SHA1 suffix in CredHub path is exactly 8 hex characters');
};

# ---------------------------------------------------------------------------
# gather_properties - basic cases
# ---------------------------------------------------------------------------
subtest 'gather_properties - value found in env lookup (bosh-configs.cpi.*)' => sub {
	plan tests => 2;

	# Mock env where lookup returns a value with a source for the first lookup
	my $tmp = workdir('gather-1');
	my $env = mock "Genesis::Env::CpiConfig::GP1" => {(
		name            => 'test-env-gp1',
		type            => 'bosh',
		kit             => $kit,
		bosh            => $bosh,
		use_create_env  => 0,
		features        => Mock::ReferencedValue->new([]),
		iaas            => 'aws',
		scale           => 'dev',
		is_ocfp         => 0,
		cpi_name        => 'aws_cpi',
		cpi_credhub_base => '/bosh/test-env-gp1/',
		workdir         => $tmp,
		deployments     => mock("Genesis::Env::CpiConfig::GP1Deployments" => {
			current_state => 'deployed',
		}),
		lookup => sub {
			my ($self, $key, $default) = @_;
			# Return a value + source for bosh-configs.cpi.region
			if ($key eq 'bosh-configs.cpi.region') {
				return wantarray ? ('us-east-1', 'env-file') : 'us-east-1';
			}
			return wantarray ? ($default, undef) : $default;
		},
		ocfp_config_lookup => sub {
			my ($self, $key, $default) = @_;
			return wantarray ? ($default, undef) : $default;
		},
		lookup_unevaled => sub { return {} },
	)};

	my $hook = Genesis::Hook::CpiConfig::test_kit->init(env => $env);
	my $props;
	lives_ok {
		$props = $hook->gather_properties('region');
	} 'gather_properties() does not die when value found in env';

	is($props->{region}, 'us-east-1',
		'property value from env lookup is returned under its key');
};

subtest 'gather_properties - uses default when not found anywhere' => sub {
	plan tests => 2;

	my $hook = make_hook();  # lookup always returns ($default, undef)

	my $props;
	lives_ok {
		$props = $hook->gather_properties('timeout:30');
	} 'gather_properties() does not die when using a default value';

	is($props->{timeout}, 30, 'JSON-parsed default integer is stored under property key');
};

subtest 'gather_properties - string default used verbatim when not valid JSON' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $props = $hook->gather_properties('datacenter:dc-west-2');
	is($props->{datacenter}, 'dc-west-2',
		'non-JSON default string is stored verbatim');
};

subtest 'gather_properties - optional property omitted when not found' => sub {
	plan tests => 2;

	my $hook = make_hook();  # all lookups return undef / no source

	my $props;
	lives_ok {
		$props = $hook->gather_properties('optional_key?');
	} 'gather_properties() does not die for optional missing property';

	ok(!exists $props->{optional_key},
		'optional property is absent from result when not found in any source');
};

subtest 'gather_properties - missing required property falls back to empty string default' => sub {
	# NOTE: The bail("Missing default...") in CpiConfig.pm is unreachable dead
	# code because $default //= '' is set unconditionally before the defined
	# check.  A property with no ':' separator and no lookup match silently
	# falls through to empty string, not bail.  This test documents that
	# actual runtime behavior.
	plan tests => 2;

	my $hook = make_hook();  # all lookups return undef / no source

	my $props;
	lives_ok {
		$props = $hook->gather_properties('required_prop');
	} 'gather_properties() does not die for required property not found (falls back to empty string)';

	is($props->{required_prop}, '',
		'required property not found falls back to empty string (bail is unreachable dead code)');
};

subtest 'gather_properties - secret property entombed in credhub_secrets' => sub {
	plan tests => 3;

	my $tmp = workdir('gather-secret');
	my $env = mock "Genesis::Env::CpiConfig::Secret1" => {(
		name            => 'test-env-sec1',
		type            => 'bosh',
		kit             => $kit,
		bosh            => $bosh,
		use_create_env  => 0,
		features        => Mock::ReferencedValue->new([]),
		iaas            => 'aws',
		scale           => 'dev',
		is_ocfp         => 0,
		cpi_name        => 'aws_cpi',
		cpi_credhub_base => '/bosh/test-env-sec1/',
		workdir         => $tmp,
		deployments     => mock("Genesis::Env::CpiConfig::Sec1Deployments" => {
			current_state => 'deployed',
		}),
		lookup => sub {
			my ($self, $key, $default) = @_;
			if ($key eq 'bosh-configs.cpi.api_key') {
				return wantarray ? ('my-secret-value', 'env-file') : 'my-secret-value';
			}
			return wantarray ? ($default, undef) : $default;
		},
		ocfp_config_lookup => sub {
			my ($self, $key, $default) = @_;
			return wantarray ? ($default, undef) : $default;
		},
		lookup_unevaled => sub { return {} },
	)};

	my $hook = Genesis::Hook::CpiConfig::test_kit->init(env => $env);
	my $props = $hook->gather_properties('!api_key');

	# The value in props should be a CredHub reference
	like($props->{api_key}, qr/^\(\(.*\)\)$/,
		'secret property value in config is a CredHub ((reference))');

	# The credhub_secrets hash should hold the real value
	my $secrets = $hook->{credhub_secrets};
	is(scalar keys %$secrets, 1, 'exactly one entry stored in credhub_secrets');

	my ($path, $value) = each %$secrets;
	is($value, 'my-secret-value', 'original secret value stored in credhub_secrets');
};

subtest 'gather_properties - config_path override (>) places value under alternate key' => sub {
	plan tests => 2;

	my $tmp = workdir('gather-path');
	my $env = mock "Genesis::Env::CpiConfig::Path1" => {(
		name            => 'test-env-path1',
		type            => 'bosh',
		kit             => $kit,
		bosh            => $bosh,
		use_create_env  => 0,
		features        => Mock::ReferencedValue->new([]),
		iaas            => 'aws',
		scale           => 'dev',
		is_ocfp         => 0,
		cpi_name        => 'aws_cpi',
		cpi_credhub_base => '/bosh/test-env-path1/',
		workdir         => $tmp,
		deployments     => mock("Genesis::Env::CpiConfig::Path1Deployments" => {
			current_state => 'deployed',
		}),
		lookup => sub {
			my ($self, $key, $default) = @_;
			if ($key eq 'bosh-configs.cpi.ntp') {
				return wantarray ? ('ntp.example.com', 'env-file') : 'ntp.example.com';
			}
			return wantarray ? ($default, undef) : $default;
		},
		ocfp_config_lookup => sub {
			my ($self, $key, $default) = @_;
			return wantarray ? ($default, undef) : $default;
		},
		lookup_unevaled => sub { return {} },
	)};

	my $hook = Genesis::Hook::CpiConfig::test_kit->init(env => $env);
	my $props = $hook->gather_properties('ntp>global.ntp');

	ok(!exists $props->{ntp}, 'original key "ntp" not present in output');
	ok(exists $props->{global} && exists $props->{global}{ntp},
		'value is placed at the nested path global.ntp via unflatten');
};

done_testing;
