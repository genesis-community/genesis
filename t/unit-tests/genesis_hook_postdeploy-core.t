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
require_ok 'Genesis::Hook::PostDeploy';

# ---------------------------------------------------------------------------
# Test subclass - class name matches Genesis::Hook::<Type>::<KitName>
# convention required by label() in the base class.
# ---------------------------------------------------------------------------
{
	package Genesis::Hook::PostDeploy::test_kit;
	use parent -norequire, 'Genesis::Hook::PostDeploy';

	sub perform {
		my ($self) = @_;
		$self->done(1);
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

sub mock_env {
	$test_seq++;
	my $seq = $test_seq;
	mock "Genesis::Env" => {(
		name            => "test-env-$seq",
		type            => 'test',
		kit             => $kit,
		bosh            => sub {
			my $self = shift;
			return $bosh;
		},
		use_create_env  => 0,
		features        => Mock::ReferencedValue->new(['ha', 'tls']),
		iaas            => 'aws',
		scale           => 'dev',
		is_ocfp         => 0,
		cpi_name        => 'aws_cpi',
		cpi_enabled     => 1,
		deployments     => mock("Genesis::Env::Deployments::$seq" => {
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

# Convenience: instantiate the test subclass with minimal required args
sub make_hook {
	my %args = (
		env => mock_env(),
		rc  => 0,
		@_,
	);
	return Genesis::Hook::PostDeploy::test_kit->init(%args);
}

# ---------------------------------------------------------------------------
# Globals set before all subtests
# ---------------------------------------------------------------------------
$Genesis::VERSION = '3.1.0-rc.10';
$ENV{GENESIS_CALL_BIN} = 'genesis';
$ENV{GENESIS_KIT_HOOK} = 'post-deploy';
$ENV{GENESIS_CALL_ENV} = 'genesis test-env';

# ---------------------------------------------------------------------------
# Module loads
# ---------------------------------------------------------------------------
subtest 'Genesis::Hook::PostDeploy module loads' => sub {
	plan tests => 1;
	ok(defined(&Genesis::Hook::PostDeploy::init),
		'Genesis::Hook::PostDeploy::init is defined');
};

# ---------------------------------------------------------------------------
# init - required arguments
# ---------------------------------------------------------------------------
subtest 'init - dies when env is missing' => sub {
	plan tests => 1;

	throws_ok {
		Genesis::Hook::PostDeploy::test_kit->init(rc => 0)
	} qr/Missing required arguments for a perl-based kit hook call:.*env/,
		'init() without env dies with required-args message';
};

subtest 'init - dies when rc is missing' => sub {
	plan tests => 1;

	throws_ok {
		Genesis::Hook::PostDeploy::test_kit->init(env => mock_env())
	} qr/Missing required arguments for a perl-based kit hook call:.*rc/,
		'init() without rc dies with required-args message';
};

subtest 'init - dies when both env and rc are missing' => sub {
	plan tests => 1;

	throws_ok {
		Genesis::Hook::PostDeploy::test_kit->init()
	} qr/Missing required arguments for a perl-based kit hook call:/,
		'init() with no arguments dies with required-args message';
};

# ---------------------------------------------------------------------------
# init - valid construction
# ---------------------------------------------------------------------------
subtest 'init - returns blessed object with rc=0' => sub {
	plan tests => 6;

	my $env = mock_env();
	my $hook;
	lives_ok {
		$hook = Genesis::Hook::PostDeploy::test_kit->init(env => $env, rc => 0)
	} 'init() with env and rc=0 succeeds';

	ok(defined $hook, 'init() returns a defined value');
	isa_ok($hook, 'Genesis::Hook::PostDeploy',
		'returned object isa Genesis::Hook::PostDeploy');
	isa_ok($hook, 'Genesis::Hook',
		'returned object isa Genesis::Hook');
	is($hook->env, $env,
		'env() returns the env passed to init()');
	is($hook->{rc}, 0,
		'rc stored on object as 0');
};

subtest 'init - returns blessed object with rc=1' => sub {
	plan tests => 3;

	my $hook;
	lives_ok {
		$hook = Genesis::Hook::PostDeploy::test_kit->init(
			env => mock_env(),
			rc  => 1,
		)
	} 'init() with rc=1 succeeds';

	ok(defined $hook, 'init() returns a defined value');
	is($hook->{rc}, 1, 'rc stored on object as 1');
};

subtest 'init - complete flag starts at 0' => sub {
	plan tests => 1;

	my $hook = make_hook();
	is($hook->{complete}, 0, 'complete flag initializes to 0');
};

subtest 'init - type set from GENESIS_KIT_HOOK env var' => sub {
	plan tests => 1;

	my $hook = make_hook();
	is($hook->{type}, 'post-deploy',
		'type reflects GENESIS_KIT_HOOK=post-deploy');
};

subtest 'init - stores extra opts on object' => sub {
	plan tests => 2;

	my $hook = Genesis::Hook::PostDeploy::test_kit->init(
		env        => mock_env(),
		rc         => 0,
		interactive => 1,
		purpose    => 'test-purpose',
	);
	is($hook->{interactive}, 1,              'extra opt "interactive" stored on hook');
	is($hook->{purpose},     'test-purpose', 'extra opt "purpose" stored on hook');
};

# ---------------------------------------------------------------------------
# deploy_successful
# ---------------------------------------------------------------------------
subtest 'deploy_successful - returns true when rc is 0' => sub {
	plan tests => 1;

	my $hook = make_hook(rc => 0);
	ok($hook->deploy_successful,
		'deploy_successful() returns true when rc=0');
};

subtest 'deploy_successful - returns false when rc is 1' => sub {
	plan tests => 1;

	my $hook = make_hook(rc => 1);
	ok(!$hook->deploy_successful,
		'deploy_successful() returns false when rc=1');
};

subtest 'deploy_successful - returns false when rc is 255' => sub {
	plan tests => 1;

	my $hook = make_hook(rc => 255);
	ok(!$hook->deploy_successful,
		'deploy_successful() returns false when rc=255');
};

subtest 'deploy_successful - returns false for any non-zero rc' => sub {
	plan tests => 3;

	for my $rc (2, 127, 128) {
		my $hook = make_hook(rc => $rc);
		ok(!$hook->deploy_successful,
			"deploy_successful() returns false when rc=$rc");
	}
};

subtest 'deploy_successful - distinguishes rc=0 from rc=1 on same hook' => sub {
	plan tests => 2;

	my $success = make_hook(rc => 0);
	my $failure = make_hook(rc => 1);

	ok( $success->deploy_successful, 'rc=0 hook: deploy_successful is true');
	ok(!$failure->deploy_successful, 'rc=1 hook: deploy_successful is false');
};

# ---------------------------------------------------------------------------
# data
# ---------------------------------------------------------------------------
subtest 'data - returns a hash reference' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $data = $hook->data;
	ok(ref($data) eq 'HASH', 'data() returns a hash reference');
};

subtest 'data - returns empty hash on first call' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $data = $hook->data;
	is(scalar keys %$data, 0, 'data() returns empty hash on first call');
};

subtest 'data - returns the same reference on subsequent calls' => sub {
	plan tests => 2;

	my $hook = make_hook();
	my $first  = $hook->data;
	my $second = $hook->data;

	is(ref($first),  'HASH', 'first call returns hash reference');
	is($first, $second, 'second call returns the same reference as first');
};

subtest 'data - mutations are visible across calls' => sub {
	plan tests => 2;

	my $hook = make_hook();
	my $data = $hook->data;
	$data->{custom_key} = 'custom_value';

	my $again = $hook->data;
	is($again->{custom_key}, 'custom_value',
		'mutation on first ref visible through second call');
	is(scalar keys %{$hook->data}, 1,
		'data hash has exactly one key after one mutation');
};

subtest 'data - each new hook instance has its own hash' => sub {
	plan tests => 2;

	my $hook_a = make_hook();
	my $hook_b = make_hook();

	$hook_a->data->{x} = 1;

	is($hook_a->data->{x}, 1, 'hook_a data has key x');
	ok(!exists $hook_b->data->{x}, 'hook_b data does not have key x');
};

# ---------------------------------------------------------------------------
# command
# ---------------------------------------------------------------------------
subtest 'command - simple args joined with spaces' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $cmd = $hook->command('do', 'test');
	is($cmd, 'genesis test-env do test',
		'command() joins GENESIS_CALL_ENV and simple args with spaces');
};

subtest 'command - no args returns just the call env' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $cmd = $hook->command();
	is($cmd, 'genesis test-env',
		'command() with no args returns GENESIS_CALL_ENV alone');
};

subtest 'command - multiple args all joined' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $cmd = $hook->command('do', 'upload-stemcells');
	is($cmd, 'genesis test-env do upload-stemcells',
		'command() with two args returns full joined string');
};

subtest 'command - uses GENESIS_CALL_ENV over GENESIS_CALL' => sub {
	plan tests => 1;

	local $ENV{GENESIS_CALL_ENV} = 'genesis my-env';
	local $ENV{GENESIS_CALL}     = 'genesis other';

	my $hook = make_hook();
	my $cmd = $hook->command('action');
	is($cmd, 'genesis my-env action',
		'command() prefers GENESIS_CALL_ENV when both env vars are set');
};

subtest 'command - falls back to GENESIS_CALL when GENESIS_CALL_ENV is unset' => sub {
	plan tests => 1;

	local $ENV{GENESIS_CALL_ENV} = undef;
	local $ENV{GENESIS_CALL}     = 'genesis fallback-env';

	my $hook = make_hook();
	my $cmd = $hook->command('do', 'something');
	is($cmd, 'genesis fallback-env do something',
		'command() falls back to GENESIS_CALL when GENESIS_CALL_ENV is unset');
};

subtest 'command - args without special chars are not quoted' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $cmd = $hook->command('deploy', '--dry-run');
	is($cmd, 'genesis test-env deploy --dry-run',
		'command() does not quote plain args');
};

subtest 'command - arg containing the quoting trigger sequence is quoted' => sub {
	plan tests => 1;

	# The regex in command() is / \(\)!\*\?/ -- a literal string match.
	# Only an arg containing exactly that sequence (space, (, ), !, *, ?)
	# will be wrapped in single quotes.
	#
	# NOTE: command() modifies its @_ aliases in place, so $trigger_arg is
	# mutated after the call.  Build the expected string before calling.
	my $hook = make_hook();
	my $raw_arg  = 'x ()!*?';
	my $expected = "genesis test-env '$raw_arg'";
	my $cmd = $hook->command($raw_arg);
	is($cmd, $expected,
		'command() single-quotes arg that matches the special-char trigger sequence');
};

# ---------------------------------------------------------------------------
# results
# ---------------------------------------------------------------------------
subtest 'results - returns 1 unconditionally' => sub {
	plan tests => 1;

	my $hook = make_hook();
	is($hook->results, 1,
		'results() returns 1 unconditionally');
};

subtest 'results - returns 1 regardless of rc' => sub {
	plan tests => 2;

	my $success = make_hook(rc => 0);
	my $failure = make_hook(rc => 1);

	is($success->results, 1, 'results() returns 1 when rc=0');
	is($failure->results, 1, 'results() returns 1 when rc=1');
};

# ---------------------------------------------------------------------------
# Heavy methods exist as can() checks
# ---------------------------------------------------------------------------
subtest 'update_director_network_config - method exists' => sub {
	plan tests => 1;

	my $hook = make_hook();
	ok($hook->can('update_director_network_config'),
		'hook can() update_director_network_config');
};

subtest 'upload_stemcells - method exists' => sub {
	plan tests => 1;

	my $hook = make_hook();
	ok($hook->can('upload_stemcells'),
		'hook can() upload_stemcells');
};

subtest 'upload_runtime_configs - method exists' => sub {
	plan tests => 1;

	my $hook = make_hook();
	ok($hook->can('upload_runtime_configs'),
		'hook can() upload_runtime_configs');
};

subtest 'upload_director_cpi_config - method exists' => sub {
	plan tests => 1;

	my $hook = make_hook();
	ok($hook->can('upload_director_cpi_config'),
		'hook can() upload_director_cpi_config');
};

subtest '_commit_config_credhub_secrets - method exists' => sub {
	plan tests => 1;

	my $hook = make_hook();
	ok($hook->can('_commit_config_credhub_secrets'),
		'hook can() _commit_config_credhub_secrets');
};

subtest 'upload_stemcells - returns immediately without action when rc is non-zero' => sub {
	plan tests => 1;

	# When deploy_successful is false, upload_stemcells must return early.
	# We verify this by ensuring no BOSH call is attempted (the mock env has
	# no get_target_bosh, so any BOSH access would die).
	my $hook = make_hook(rc => 1);
	my $ret;
	lives_ok {
		$ret = $hook->upload_stemcells
	} 'upload_stemcells() with rc=1 returns early without BOSH access';
};

done_testing;
