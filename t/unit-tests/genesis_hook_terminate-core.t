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
require_ok 'Genesis::Hook::Terminate';

# ---------------------------------------------------------------------------
# Test subclass - implements all three mode-specific methods.
# Class name matches Genesis::Hook::<Type>::<KitName> convention for label().
# ---------------------------------------------------------------------------
{
	package Genesis::Hook::Terminate::test_kit;
	use parent -norequire, 'Genesis::Hook::Terminate';

	sub before_terminate  { return 1 }
	sub after_terminate   { return 1 }
	sub failed_terminate  { return 1 }
}

# ---------------------------------------------------------------------------
# Incomplete test subclass - no mode-specific methods implemented.
# Used to verify kit_bug is raised for unimplemented dispatch targets.
# ---------------------------------------------------------------------------
{
	package Genesis::Hook::Terminate::test_kit_empty;
	use parent -norequire, 'Genesis::Hook::Terminate';
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

# Convenience: instantiate the full test subclass with defaults
sub make_hook {
	my %args = (
		env      => mock_env(),
		kit      => $kit,
		mode     => 'before',
		dryrun   => 0,
		force    => 0,
		noprompt => 0,
		@_,
	);
	return Genesis::Hook::Terminate::test_kit->init(%args);
}

# ---------------------------------------------------------------------------
# Globals set before all subtests
# ---------------------------------------------------------------------------
$Genesis::VERSION = '3.1.0-rc.10';
$ENV{GENESIS_CALL_BIN} = 'genesis';
$ENV{GENESIS_KIT_HOOK} = 'terminate';

# ---------------------------------------------------------------------------
# Module loads
# ---------------------------------------------------------------------------
subtest 'Genesis::Hook::Terminate module loads' => sub {
	plan tests => 1;
	ok(defined(&Genesis::Hook::Terminate::init),
		'Genesis::Hook::Terminate::init is defined');
};

# ---------------------------------------------------------------------------
# init - required arguments
# ---------------------------------------------------------------------------
subtest 'init - dies when env is missing' => sub {
	plan tests => 1;

	throws_ok {
		Genesis::Hook::Terminate::test_kit->init(
			kit      => $kit,
			mode     => 'before',
			dryrun   => 0,
			force    => 0,
			noprompt => 0,
		)
	} qr/Missing required arguments for a perl-based kit hook call:.*env/,
		'init() without env dies with required-args message';
};

subtest 'init - dies when kit is missing' => sub {
	plan tests => 1;

	throws_ok {
		Genesis::Hook::Terminate::test_kit->init(
			env      => mock_env(),
			mode     => 'before',
			dryrun   => 0,
			force    => 0,
			noprompt => 0,
		)
	} qr/Missing required arguments for a perl-based kit hook call:.*kit/,
		'init() without kit dies with required-args message';
};

subtest 'init - dies when mode is missing' => sub {
	plan tests => 1;

	throws_ok {
		Genesis::Hook::Terminate::test_kit->init(
			env      => mock_env(),
			kit      => $kit,
			dryrun   => 0,
			force    => 0,
			noprompt => 0,
		)
	} qr/Missing required arguments for a perl-based kit hook call:.*mode/,
		'init() without mode dies with required-args message';
};

subtest 'init - dies when dryrun is missing' => sub {
	plan tests => 1;

	throws_ok {
		Genesis::Hook::Terminate::test_kit->init(
			env      => mock_env(),
			kit      => $kit,
			mode     => 'before',
			force    => 0,
			noprompt => 0,
		)
	} qr/Missing required arguments for a perl-based kit hook call:.*dryrun/,
		'init() without dryrun dies with required-args message';
};

subtest 'init - dies when force is missing' => sub {
	plan tests => 1;

	throws_ok {
		Genesis::Hook::Terminate::test_kit->init(
			env      => mock_env(),
			kit      => $kit,
			mode     => 'before',
			dryrun   => 0,
			noprompt => 0,
		)
	} qr/Missing required arguments for a perl-based kit hook call:.*force/,
		'init() without force dies with required-args message';
};

subtest 'init - dies when noprompt is missing' => sub {
	plan tests => 1;

	throws_ok {
		Genesis::Hook::Terminate::test_kit->init(
			env    => mock_env(),
			kit    => $kit,
			mode   => 'before',
			dryrun => 0,
			force  => 0,
		)
	} qr/Missing required arguments for a perl-based kit hook call:.*noprompt/,
		'init() without noprompt dies with required-args message';
};

# ---------------------------------------------------------------------------
# init - valid construction
# ---------------------------------------------------------------------------
subtest 'init - returns blessed object with all args stored' => sub {
	plan tests => 7;

	my $env  = mock_env();
	my $hook;
	lives_ok {
		$hook = Genesis::Hook::Terminate::test_kit->init(
			env      => $env,
			kit      => $kit,
			mode     => 'before',
			dryrun   => 0,
			force    => 0,
			noprompt => 0,
		)
	} 'init() with all required args succeeds';

	ok(defined $hook,                        'init() returns a defined value');
	isa_ok($hook, 'Genesis::Hook::Terminate', 'returned object isa Genesis::Hook::Terminate');
	isa_ok($hook, 'Genesis::Hook',            'returned object isa Genesis::Hook');
	is($hook->env,       $env,     'env() returns the env passed to init()');
	is($hook->{mode},    'before', 'mode stored on object');
	is($hook->{dryrun},  0,        'dryrun stored on object');
};

subtest 'init - complete flag starts at 0' => sub {
	plan tests => 1;

	my $hook = make_hook();
	is($hook->{complete}, 0, 'complete flag initializes to 0');
};

subtest 'init - type set from GENESIS_KIT_HOOK env var' => sub {
	plan tests => 1;

	my $hook = make_hook();
	is($hook->{type}, 'terminate', 'type reflects GENESIS_KIT_HOOK=terminate');
};

# ---------------------------------------------------------------------------
# init - mode validation
# ---------------------------------------------------------------------------
subtest 'init - accepts mode "before"' => sub {
	plan tests => 2;

	my $hook;
	lives_ok {
		$hook = make_hook(mode => 'before')
	} 'init() with mode "before" succeeds';
	is($hook->{mode}, 'before', 'mode stored as "before"');
};

subtest 'init - accepts mode "after"' => sub {
	plan tests => 2;

	my $hook;
	lives_ok {
		$hook = make_hook(mode => 'after')
	} 'init() with mode "after" succeeds';
	is($hook->{mode}, 'after', 'mode stored as "after"');
};

subtest 'init - accepts mode "failed"' => sub {
	plan tests => 2;

	my $hook;
	lives_ok {
		$hook = make_hook(mode => 'failed')
	} 'init() with mode "failed" succeeds';
	is($hook->{mode}, 'failed', 'mode stored as "failed"');
};

subtest 'init - dies on invalid mode' => sub {
	plan tests => 3;

	for my $bad_mode (qw(start finish broken)) {
		throws_ok {
			make_hook(mode => $bad_mode)
		} qr/Unknown termination mode '$bad_mode'/,
			"init() dies with unknown mode '$bad_mode'";
	}
};

subtest 'init - dies with message naming invalid mode value' => sub {
	plan tests => 1;

	throws_ok {
		make_hook(mode => 'deploy')
	} qr/expected.*before.*after.*failed/s,
		'error message names the three valid modes';
};

# ---------------------------------------------------------------------------
# init - dry_run alias is renamed to dryrun
# ---------------------------------------------------------------------------
subtest 'init - dry_run argument is renamed to dryrun' => sub {
	plan tests => 3;

	my $hook;
	lives_ok {
		$hook = Genesis::Hook::Terminate::test_kit->init(
			env      => mock_env(),
			kit      => $kit,
			mode     => 'after',
			dry_run  => 1,
			force    => 0,
			noprompt => 1,
		)
	} 'init() with dry_run (underscored) succeeds';

	is($hook->{dryrun},  1,     'dryrun set to 1 from dry_run');
	ok(!exists $hook->{dry_run}, 'dry_run key was removed from object');
};

subtest 'init - dry_run => 0 renamed to dryrun => 0' => sub {
	plan tests => 2;

	my $hook = Genesis::Hook::Terminate::test_kit->init(
		env      => mock_env(),
		kit      => $kit,
		mode     => 'before',
		dry_run  => 0,
		force    => 0,
		noprompt => 0,
	);
	is($hook->{dryrun},  0,     'dryrun set to 0 from dry_run => 0');
	ok(!exists $hook->{dry_run}, 'dry_run key absent after rename');
};

# ---------------------------------------------------------------------------
# is_dryrun
# ---------------------------------------------------------------------------
subtest 'is_dryrun - returns false when dryrun is 0' => sub {
	plan tests => 1;

	my $hook = make_hook(dryrun => 0);
	ok(!$hook->is_dryrun, 'is_dryrun() returns false when dryrun => 0');
};

subtest 'is_dryrun - returns true when dryrun is 1' => sub {
	plan tests => 1;

	my $hook = make_hook(dryrun => 1);
	ok($hook->is_dryrun, 'is_dryrun() returns true when dryrun => 1');
};

subtest 'is_dryrun - reflects dry_run value supplied at init' => sub {
	plan tests => 1;

	my $hook = Genesis::Hook::Terminate::test_kit->init(
		env      => mock_env(),
		kit      => $kit,
		mode     => 'before',
		dry_run  => 1,
		force    => 0,
		noprompt => 0,
	);
	ok($hook->is_dryrun, 'is_dryrun() returns true when constructed with dry_run => 1');
};

# ---------------------------------------------------------------------------
# perform - dispatch to mode-specific methods
# ---------------------------------------------------------------------------
subtest 'perform - dispatches to before_terminate for mode "before"' => sub {
	plan tests => 3;

	my $hook = make_hook(mode => 'before');
	my $ret;
	lives_ok { $ret = $hook->perform } 'perform() with mode "before" lives';
	is($ret, 1, 'perform() returns result of before_terminate()');
	is($hook->completed, 1, 'hook is marked complete after perform()');
};

subtest 'perform - dispatches to after_terminate for mode "after"' => sub {
	plan tests => 3;

	my $hook = make_hook(mode => 'after');
	my $ret;
	lives_ok { $ret = $hook->perform } 'perform() with mode "after" lives';
	is($ret, 1, 'perform() returns result of after_terminate()');
	is($hook->completed, 1, 'hook is marked complete after perform()');
};

subtest 'perform - dispatches to failed_terminate for mode "failed"' => sub {
	plan tests => 3;

	my $hook = make_hook(mode => 'failed');
	my $ret;
	lives_ok { $ret = $hook->perform } 'perform() with mode "failed" lives';
	is($ret, 1, 'perform() returns result of failed_terminate()');
	is($hook->completed, 1, 'hook is marked complete after perform()');
};

subtest 'perform - calls done() with method return value' => sub {
	plan tests => 2;

	# Subclass that returns a custom value
	{
		package Genesis::Hook::Terminate::test_kit_retval;
		use parent -norequire, 'Genesis::Hook::Terminate';
		sub before_terminate { return 'custom-result' }
		sub after_terminate  { return 1 }
		sub failed_terminate { return 1 }
	}

	my $hook = Genesis::Hook::Terminate::test_kit_retval->init(
		env      => mock_env(),
		kit      => $kit,
		mode     => 'before',
		dryrun   => 0,
		force    => 0,
		noprompt => 0,
	);

	my $ret = $hook->perform;
	is($ret,           'custom-result', 'perform() returns the value from mode method');
	is($hook->results, 'custom-result', 'results() returns the same value');
};

# ---------------------------------------------------------------------------
# perform - kit_bug raised for unimplemented mode methods
# ---------------------------------------------------------------------------
subtest 'perform - raises kit_bug when before_terminate is not implemented' => sub {
	plan tests => 1;

	my $hook = Genesis::Hook::Terminate::test_kit_empty->init(
		env      => mock_env(),
		kit      => $kit,
		mode     => 'before',
		dryrun   => 0,
		force    => 0,
		noprompt => 0,
	);

	throws_ok {
		$hook->perform
	} qr/Throwing a kit bug:.*before_terminate/,
		'perform() raises kit_bug when before_terminate is not implemented';
};

subtest 'perform - raises kit_bug when after_terminate is not implemented' => sub {
	plan tests => 1;

	my $hook = Genesis::Hook::Terminate::test_kit_empty->init(
		env      => mock_env(),
		kit      => $kit,
		mode     => 'after',
		dryrun   => 0,
		force    => 0,
		noprompt => 0,
	);

	throws_ok {
		$hook->perform
	} qr/Throwing a kit bug:.*after_terminate/,
		'perform() raises kit_bug when after_terminate is not implemented';
};

subtest 'perform - raises kit_bug when failed_terminate is not implemented' => sub {
	plan tests => 1;

	my $hook = Genesis::Hook::Terminate::test_kit_empty->init(
		env      => mock_env(),
		kit      => $kit,
		mode     => 'failed',
		dryrun   => 0,
		force    => 0,
		noprompt => 0,
	);

	throws_ok {
		$hook->perform
	} qr/Throwing a kit bug:.*failed_terminate/,
		'perform() raises kit_bug when failed_terminate is not implemented';
};

subtest 'perform - kit_bug message names the kit' => sub {
	plan tests => 1;

	my $hook = Genesis::Hook::Terminate::test_kit_empty->init(
		env      => mock_env(),
		kit      => $kit,
		mode     => 'before',
		dryrun   => 0,
		force    => 0,
		noprompt => 0,
	);

	throws_ok {
		$hook->perform
	} qr/Throwing a kit bug:[\s\S]*test-kit/,
		'kit_bug message includes the kit name';
};

done_testing;
