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
use JSON::PP;

$ENV{GENESIS_CALLBACK_BIN} ||= abs_path('bin/genesis');
$ENV{GENESIS_LIB} ||= abs_path('lib');
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# ---------------------------------------------------------------------------
# Load the module under test
# ---------------------------------------------------------------------------
require_ok 'Genesis::Hook::RuntimeConfig';

# ---------------------------------------------------------------------------
# Test subclass - must match Genesis::Hook::<type>::<kit-name> pattern so
# that label() can parse it.  We define build_dns_runtime and
# build_logging_runtime methods here.
# ---------------------------------------------------------------------------
{
	package Genesis::Hook::RuntimeConfig::test_kit;
	use parent -norequire, 'Genesis::Hook::RuntimeConfig';

	sub build_dns_runtime {
		my ($self) = @_;
		my $data = {
			releases => [{name => 'bosh-dns', version => '1.31.0'}],
			addons   => [{name => 'bosh-dns', jobs => []}],
		};
		return ($data, undef, undef);
	}

	sub build_logging_runtime {
		my ($self) = @_;
		my $yaml = "releases:\n- name: loggregator\n  version: '1.0'\n";
		return ($yaml, undef, undef);
	}

	sub build_failing_runtime {
		my ($self) = @_;
		return (undef, 'failed', 'something went wrong');
	}

	sub build_skipped_runtime {
		my ($self) = @_;
		return (undef, 'skipped', 'not applicable here');
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
		bail("Throwing a kit bug: ".$msg, @args);
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
	exodus_vault         => undef,
	connect_and_validate => sub { return $_[0] },
};

sub mock_env {
	$test_seq++;
	my $seq = $test_seq;
	mock "Genesis::Env" => {(
		name             => "test-env-$seq",
		type             => 'test',
		kit              => $kit,
		bosh             => sub { return $bosh },
		is_bosh_director => 0,
		bosh_config_name => 'test-env-bosh',
		use_create_env   => 0,
		features         => Mock::ReferencedValue->new(['ha', 'tls']),
		iaas             => 'aws',
		scale            => 'dev',
		is_ocfp          => 0,
		cpi_name         => 'aws_cpi',
		cpi_enabled      => 1,
		feature_compatibility => sub { return 0 },
		deployments      => mock("Genesis::Env::Deployments::$seq" => {
			current_state => 'deployed',
		}),
		workpath => sub {
			my ($self, $path) = @_;
			return "/tmp/genesis-test-work/$path";
		},
		exodus_lookup => sub {
			my ($self, $key, $default) = @_;
			return { director_url => 'https://bosh.example.com', admin_user => 'admin' }
				if $key eq '.';
			return $default;
		},
		lookup => sub {
			my ($self, $key, $default) = @_;
			return $default;
		},
		path => sub { return "/mock/env/path/$_[1]" },
		file => 'test-env.yml',
	), @_};
}

# Build a hook by manual blessing to avoid the Service::Credhub->from_bosh
# call inside init().  This is the preferred approach when the constructor
# has too many external dependencies.
sub make_hook {
	my (%args) = @_;
	my $env = $args{env} || mock_env();
	# Use exists check so that an explicit args => undef is preserved as undef,
	# rather than defaulting to [] the way // would.
	my $hook_args = exists $args{args} ? $args{args} : [];
	my $hook = bless {
		env              => $env,
		complete         => 0,
		type             => 'runtime-config',
		label            => '[test_kit RuntimeConfig] ',
		builds           => {},
		bosh             => $bosh,
		credhub          => undef,
		secrets          => {},
		args             => $hook_args,
		dryrun           => $args{dryrun}      // 0,
		interactive      => $args{interactive} // 0,
		print            => $args{print}       // 0,
		remove           => $args{remove}      // 0,
		requests         => [],
		request_options  => {},
	}, 'Genesis::Hook::RuntimeConfig::test_kit';
	return $hook;
}

# ---------------------------------------------------------------------------
# Globals set before all subtests
# ---------------------------------------------------------------------------
$Genesis::VERSION = '3.1.0-rc.10';
$ENV{GENESIS_CALL_BIN}  = 'genesis';
$ENV{GENESIS_KIT_HOOK}  = 'runtime-config';

# ---------------------------------------------------------------------------
# Module loads
# ---------------------------------------------------------------------------
subtest 'Genesis::Hook::RuntimeConfig module loads' => sub {
	plan tests => 1;
	ok(defined(&Genesis::Hook::RuntimeConfig::init),
		'Genesis::Hook::RuntimeConfig::init is defined');
};

# ---------------------------------------------------------------------------
# Accessor: dryrun
# ---------------------------------------------------------------------------
subtest 'dryrun - defaults to 0' => sub {
	plan tests => 1;
	my $hook = make_hook();
	is($hook->dryrun, 0, 'dryrun() returns 0 by default');
};

subtest 'dryrun - returns 1 when set' => sub {
	plan tests => 1;
	my $hook = make_hook(dryrun => 1);
	is($hook->dryrun, 1, 'dryrun() returns 1 when dryrun is set');
};

# ---------------------------------------------------------------------------
# Accessor: interactive
# ---------------------------------------------------------------------------
subtest 'interactive - defaults to 0' => sub {
	plan tests => 1;
	my $hook = make_hook();
	is($hook->interactive, 0, 'interactive() returns 0 by default');
};

subtest 'interactive - returns 1 when set' => sub {
	plan tests => 1;
	my $hook = make_hook(interactive => 1);
	is($hook->interactive, 1, 'interactive() returns 1 when interactive is set');
};

# ---------------------------------------------------------------------------
# Accessor: print
# ---------------------------------------------------------------------------
subtest 'print - defaults to 0' => sub {
	plan tests => 1;
	my $hook = make_hook();
	is($hook->print, 0, 'print() returns 0 by default');
};

subtest 'print - returns 1 when set' => sub {
	plan tests => 1;
	my $hook = make_hook(print => 1);
	is($hook->print, 1, 'print() returns 1 when print is set');
};

# ---------------------------------------------------------------------------
# Accessor: remove
# ---------------------------------------------------------------------------
subtest 'remove - defaults to 0' => sub {
	plan tests => 1;
	my $hook = make_hook();
	is($hook->remove, 0, 'remove() returns 0 by default');
};

subtest 'remove - returns 1 when set' => sub {
	plan tests => 1;
	my $hook = make_hook(remove => 1);
	is($hook->remove, 1, 'remove() returns 1 when remove is set');
};

# ---------------------------------------------------------------------------
# action()
# ---------------------------------------------------------------------------
subtest 'action - default is generate and upload' => sub {
	plan tests => 1;
	my $hook = make_hook();
	is($hook->action, 'generate and upload',
		'action() returns "generate and upload" in normal mode');
};

subtest 'action - dryrun mode returns generate' => sub {
	plan tests => 1;
	my $hook = make_hook(dryrun => 1);
	is($hook->action, 'generate',
		'action() returns "generate" in dryrun mode');
};

subtest 'action - remove mode returns remove' => sub {
	plan tests => 1;
	my $hook = make_hook(remove => 1);
	is($hook->action, 'remove',
		'action() returns "remove" in remove mode');
};

subtest 'action - remove takes precedence over dryrun' => sub {
	plan tests => 1;
	my $hook = make_hook(remove => 1, dryrun => 1);
	is($hook->action, 'remove',
		'action() returns "remove" when both remove and dryrun are set');
};

# ---------------------------------------------------------------------------
# config_name_for()
# ---------------------------------------------------------------------------
subtest 'config_name_for - returns bosh_config_name dot build' => sub {
	plan tests => 2;
	my $hook = make_hook();
	is($hook->config_name_for('dns'),     'test-env-bosh.dns',
		'config_name_for("dns") returns correct name');
	is($hook->config_name_for('logging'), 'test-env-bosh.logging',
		'config_name_for("logging") returns correct name');
};

# ---------------------------------------------------------------------------
# register_runtime_config_builds()
# ---------------------------------------------------------------------------
subtest 'register_runtime_config_builds - plain string derives description' => sub {
	plan tests => 4;
	my $hook = make_hook();
	$hook->register_runtime_config_builds('dns');
	ok(exists $hook->{builds}{dns}, 'dns build registered');
	is($hook->{builds}{dns}{description}, 'Dns',
		'single-word name title-cased as description');
	is($hook->{builds}{dns}{method}, 'build_dns_runtime',
		'method name is build_dns_runtime');
	is($hook->{builds}{dns}{order}, 0, 'order is 0 for first registered build');
};

subtest 'register_runtime_config_builds - multi-word name derives description' => sub {
	plan tests => 2;
	my $hook = make_hook();
	$hook->register_runtime_config_builds('dns', 'logging');
	is($hook->{builds}{dns}{description},     'Dns',
		'dns description auto-derived');
	is($hook->{builds}{logging}{description}, 'Logging',
		'logging description auto-derived');
};

subtest 'register_runtime_config_builds - arrayref uses explicit description' => sub {
	plan tests => 2;
	my $hook = make_hook();
	$hook->register_runtime_config_builds(['logging', 'Log Aggregation']);
	ok(exists $hook->{builds}{logging}, 'logging build registered');
	is($hook->{builds}{logging}{description}, 'Log Aggregation',
		'explicit description stored');
};

subtest 'register_runtime_config_builds - preserves registration order' => sub {
	plan tests => 2;
	my $hook = make_hook();
	$hook->register_runtime_config_builds('logging', 'dns');
	is($hook->{builds}{logging}{order}, 0, 'logging registered first has order 0');
	is($hook->{builds}{dns}{order},     1, 'dns registered second has order 1');
};

subtest 'register_runtime_config_builds - resets builds on re-registration' => sub {
	plan tests => 2;
	my $hook = make_hook();
	$hook->register_runtime_config_builds('dns', 'logging');
	$hook->register_runtime_config_builds('logging');
	ok(!exists $hook->{builds}{dns}, 'dns removed after re-registration');
	ok( exists $hook->{builds}{logging}, 'logging present after re-registration');
};

subtest 'register_runtime_config_builds - returns self for chaining' => sub {
	plan tests => 1;
	my $hook = make_hook();
	my $ret = $hook->register_runtime_config_builds('dns');
	is($ret, $hook, 'register_runtime_config_builds() returns $self');
};

subtest 'register_runtime_config_builds - dies on empty list' => sub {
	plan tests => 1;
	my $hook = make_hook();
	throws_ok {
		$hook->register_runtime_config_builds()
	} qr/No builds specified for registration/,
		'dies with no-builds message when called with empty list';
};

subtest 'register_runtime_config_builds - dies on invalid name chars' => sub {
	plan tests => 1;
	my $hook = make_hook();
	throws_ok {
		$hook->register_runtime_config_builds('dns!bad')
	} qr/Invalid runtime config name 'dns!bad' specified/,
		'dies when name contains invalid characters';
};

subtest 'register_runtime_config_builds - dies when build method missing' => sub {
	plan tests => 1;
	my $hook = make_hook();
	throws_ok {
		$hook->register_runtime_config_builds('nonexistent')
	} qr/Cannot find build method 'build_nonexistent_runtime'/,
		'dies via kit_bug when build_<name>_runtime method does not exist';
};

subtest 'register_runtime_config_builds - hyphen converted to underscore in method name' => sub {
	plan tests => 1;
	# build_dns_runtime exists; 'dns' with hyphen variant is not testable unless we
	# add a method.  Verify the method lookup converts hyphens.
	# We add a method dynamically for this test only.
	{
		no warnings 'redefine', 'once';
		*Genesis::Hook::RuntimeConfig::test_kit::build_my_config_runtime = sub {
			return ({}, undef, undef);
		};
	}
	my $hook = make_hook();
	lives_ok {
		$hook->register_runtime_config_builds('my-config')
	} 'hyphen in name maps to underscore in method name (build_my_config_runtime)';
	# clean up
	no strict 'refs';
	delete $Genesis::Hook::RuntimeConfig::test_kit::{build_my_config_runtime};
};

# ---------------------------------------------------------------------------
# _get_req_names()
# ---------------------------------------------------------------------------
subtest '_get_req_names - star returns all sorted by order' => sub {
	plan tests => 1;
	my $hook = make_hook();
	$hook->register_runtime_config_builds('logging', 'dns');
	my @names = $hook->_get_req_names('*');
	cmp_deeply(\@names, ['logging', 'dns'],
		'* returns builds in registration order');
};

subtest '_get_req_names - all returns all sorted by order' => sub {
	plan tests => 1;
	my $hook = make_hook();
	$hook->register_runtime_config_builds('dns', 'logging');
	my @names = $hook->_get_req_names('all');
	cmp_deeply(\@names, ['dns', 'logging'],
		'"all" returns builds in registration order');
};

subtest '_get_req_names - single name returned as single-element list' => sub {
	plan tests => 1;
	my $hook = make_hook();
	$hook->register_runtime_config_builds('dns', 'logging');
	my @names = $hook->_get_req_names('dns');
	cmp_deeply(\@names, ['dns'], 'single name returns single-element list');
};

subtest '_get_req_names - comma-separated names split correctly' => sub {
	plan tests => 1;
	my $hook = make_hook();
	$hook->register_runtime_config_builds('dns', 'logging');
	my @names = $hook->_get_req_names('dns,logging');
	cmp_deeply(\@names, ['dns', 'logging'],
		'comma-separated names split into list');
};

# ---------------------------------------------------------------------------
# validate_runtime_config_requests()
# ---------------------------------------------------------------------------
subtest 'validate_runtime_config_requests - undef args requests all builds' => sub {
	plan tests => 3;
	my $hook = make_hook(args => undef);
	$hook->register_runtime_config_builds('dns', 'logging');
	my $ret = $hook->validate_runtime_config_requests();
	is($ret, 1, 'returns 1 on success');
	cmp_deeply($hook->{requests}, ['dns', 'logging'],
		'requests contains all builds in order when args is undef');
	cmp_deeply($hook->{request_options}, {},
		'request_options is empty hash when args is undef');
};

subtest 'validate_runtime_config_requests - empty arrayref args yields empty requests' => sub {
	plan tests => 2;
	# An empty arrayref is truthy in Perl so it does NOT short-circuit to
	# "all builds".  The ARRAY branch processes it into an empty hash, and
	# step 2 finds no names and no excludes, leaving requests empty.
	my $hook = make_hook(args => []);
	$hook->register_runtime_config_builds('dns', 'logging');
	$hook->validate_runtime_config_requests();
	cmp_deeply($hook->{requests}, [],
		'empty arrayref produces empty requests list');
	cmp_deeply($hook->{request_options}, {},
		'request_options is empty when args is empty array');
};

subtest 'validate_runtime_config_requests - JSON true args bails as invalid type' => sub {
	plan tests => 1;
	# JSON::PP::Boolean true is truthy so the early-exit guard
	# ( !($args || ...) ) evaluates to false and does not short-circuit.
	# It is not a string, array, or hash, so the code bails.
	my $hook = make_hook(args => $JSON::PP::true);
	$hook->register_runtime_config_builds('dns', 'logging');
	throws_ok {
		$hook->validate_runtime_config_requests()
	} qr/Invalid runtime config request arguments/,
		'JSON true alone bails because it is not string/array/hash';
};

subtest 'validate_runtime_config_requests - string requests single build' => sub {
	plan tests => 2;
	# A plain string is promoted to {$string => {}}.  Step 2 sees an empty
	# options hash for the build, so request_options gets {dns => {}}.
	my $hook = make_hook(args => 'dns');
	$hook->register_runtime_config_builds('dns', 'logging');
	$hook->validate_runtime_config_requests();
	cmp_deeply($hook->{requests}, ['dns'],
		'string arg requests only the named build');
	cmp_deeply($hook->{request_options}, {dns => {}},
		'request_options contains empty hash for the requested build');
};

subtest 'validate_runtime_config_requests - comma-separated string requests multiple' => sub {
	plan tests => 1;
	my $hook = make_hook(args => 'dns,logging');
	$hook->register_runtime_config_builds('dns', 'logging');
	$hook->validate_runtime_config_requests();
	cmp_deeply([sort @{$hook->{requests}}], ['dns', 'logging'],
		'comma-separated string requests both named builds');
};

subtest 'validate_runtime_config_requests - hash with options stores options' => sub {
	plan tests => 2;
	my $hook = make_hook(args => {dns => {ttl => 300}, logging => {}});
	$hook->register_runtime_config_builds('dns', 'logging');
	$hook->validate_runtime_config_requests();
	cmp_deeply([sort @{$hook->{requests}}], ['dns', 'logging'],
		'hash arg requests named builds');
	is($hook->{request_options}{dns}{ttl}, 300,
		'options stored in request_options under build name');
};

subtest 'validate_runtime_config_requests - hash with JSON true includes build' => sub {
	plan tests => 1;
	my $hook = make_hook(args => {dns => $JSON::PP::true, logging => $JSON::PP::false});
	$hook->register_runtime_config_builds('dns', 'logging');
	$hook->validate_runtime_config_requests();
	cmp_deeply($hook->{requests}, ['dns'],
		'JSON true includes build, JSON false excludes it');
};

subtest 'validate_runtime_config_requests - JSON false excludes build from all' => sub {
	plan tests => 1;
	my $hook = make_hook(args => {logging => $JSON::PP::false});
	$hook->register_runtime_config_builds('dns', 'logging');
	$hook->validate_runtime_config_requests();
	cmp_deeply($hook->{requests}, ['dns'],
		'JSON false on one build excludes it, leaving others from default all');
};

subtest 'validate_runtime_config_requests - invalid build name dies' => sub {
	plan tests => 1;
	my $hook = make_hook(args => 'nosuchbuild');
	$hook->register_runtime_config_builds('dns', 'logging');
	throws_ok {
		$hook->validate_runtime_config_requests()
	} qr/Invalid runtime config requests: nosuchbuild/,
		'invalid build name raises error listing valid names';
};

subtest 'validate_runtime_config_requests - invalid args type dies' => sub {
	plan tests => 1;
	my $hook = make_hook(args => sub { 1 });
	$hook->register_runtime_config_builds('dns');
	throws_ok {
		$hook->validate_runtime_config_requests()
	} qr/Invalid runtime config request arguments/,
		'CODE reference args raises invalid-args error';
};

subtest 'validate_runtime_config_requests - array of strings requests those builds' => sub {
	plan tests => 1;
	my $hook = make_hook(args => ['dns']);
	$hook->register_runtime_config_builds('dns', 'logging');
	$hook->validate_runtime_config_requests();
	cmp_deeply($hook->{requests}, ['dns'],
		'array with one string requests that build');
};

subtest 'validate_runtime_config_requests - array with hash uses build-keyed options' => sub {
	plan tests => 2;
	# Hash elements in the array are merged into %new_args at the top level of
	# the final hash.  To set per-build options, the hash must use the build
	# name as the key, e.g. {dns => {ttl => 300}}.
	my $hook = make_hook(args => ['dns', {dns => {ttl => 300}}]);
	$hook->register_runtime_config_builds('dns', 'logging');
	$hook->validate_runtime_config_requests();
	cmp_deeply([sort @{$hook->{requests}}], ['dns'],
		'array with string and build-keyed hash requests the named build');
	is($hook->{request_options}{dns}{ttl}, 300,
		'per-build options stored in request_options under build name');
};

subtest 'validate_runtime_config_requests - returns 1 on success' => sub {
	plan tests => 1;
	my $hook = make_hook(args => undef);
	$hook->register_runtime_config_builds('dns');
	my $ret = $hook->validate_runtime_config_requests();
	is($ret, 1, 'validate_runtime_config_requests returns 1 on success');
};

# ---------------------------------------------------------------------------
# build()
# ---------------------------------------------------------------------------
subtest 'build - dies when no build name given' => sub {
	plan tests => 1;
	my $hook = make_hook();
	$hook->register_runtime_config_builds('dns');
	throws_ok {
		$hook->build(undef)
	} qr/No runtime config name specified/,
		'build(undef) dies with no-name message';
};

subtest 'build - dies for unregistered build name' => sub {
	plan tests => 1;
	my $hook = make_hook();
	$hook->register_runtime_config_builds('dns');
	throws_ok {
		$hook->build('logging')
	} qr/Invalid runtime config name 'logging' specified/,
		'build("logging") dies when logging not registered';
};

subtest 'build - returns YAML string for hash return value' => sub {
	plan tests => 2;
	my $hook = make_hook();
	$hook->register_runtime_config_builds('dns');
	my $result = $hook->build('dns');
	ok(defined $result, 'build("dns") returns a defined value');
	like($result, qr/releases/,
		'returned value contains "releases" key from hash-to-YAML conversion');
};

subtest 'build - returns YAML string unchanged when build returns string' => sub {
	plan tests => 2;
	my $hook = make_hook();
	$hook->register_runtime_config_builds('logging');
	my $result = $hook->build('logging');
	ok(defined $result, 'build("logging") returns a defined value');
	like($result, qr/loggregator/,
		'returned YAML contains loggregator release name');
};

subtest 'build - returns undef when build method returns failed status' => sub {
	plan tests => 2;
	{
		no warnings 'redefine';
		*Genesis::Hook::RuntimeConfig::test_kit::build_failing_runtime = sub {
			return (undef, 'failed', 'something went wrong');
		};
	}
	my $hook = make_hook();
	$hook->register_runtime_config_builds('failing');
	my $result;
	lives_ok { $result = $hook->build('failing') }
		'build() does not die when build method returns failed status';
	ok(!defined $result, 'build() returns undef for failed status');
};

subtest 'build - returns undef when build method returns skipped status' => sub {
	plan tests => 2;
	{
		no warnings 'redefine';
		*Genesis::Hook::RuntimeConfig::test_kit::build_skipped_runtime = sub {
			return (undef, 'skipped', 'not applicable here');
		};
	}
	my $hook = make_hook();
	$hook->register_runtime_config_builds('skipped');
	my $result;
	lives_ok { $result = $hook->build('skipped') }
		'build() does not die when build method returns skipped status';
	ok(!defined $result, 'build() returns undef for skipped status');
};

subtest 'build - clears secrets for failed build' => sub {
	plan tests => 1;
	my $hook = make_hook();
	$hook->{secrets}{failing} = {'/some/path:key' => 'value'};
	$hook->register_runtime_config_builds('failing');
	$hook->build('failing');
	ok(!exists $hook->{secrets}{failing},
		'secrets entry cleared for failed build');
};

# ---------------------------------------------------------------------------
# bosh() accessor
# ---------------------------------------------------------------------------
subtest 'bosh - returns the bosh object set at construction' => sub {
	plan tests => 1;
	my $hook = make_hook();
	is($hook->bosh, $bosh, 'bosh() returns the bosh mock object');
};

# ---------------------------------------------------------------------------
# credhub() accessor
# ---------------------------------------------------------------------------
subtest 'credhub - returns undef by default in manual-bless mode' => sub {
	plan tests => 1;
	my $hook = make_hook();
	ok(!defined $hook->credhub,
		'credhub() returns undef when not set');
};

# ---------------------------------------------------------------------------
# credhub_base() - feature_compatibility returns 0, so base is undef
# ---------------------------------------------------------------------------
subtest 'credhub_base - returns undef when feature_compatibility is false' => sub {
	plan tests => 1;
	my $hook = make_hook();
	ok(!defined $hook->credhub_base,
		'credhub_base() returns undef when feature_compatibility returns 0');
};

# ---------------------------------------------------------------------------
# done testing
# ---------------------------------------------------------------------------
done_testing;
