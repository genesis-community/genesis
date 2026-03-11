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
require_ok 'Genesis::Hook::Addon';

# ---------------------------------------------------------------------------
# Test subclass - Genesis::Hook::Addon requires the class name to match
# Genesis::Hook::<Type>::<KitName> so that label() can parse it.
# ---------------------------------------------------------------------------
{
	package Genesis::Hook::Addon::test_kit;
	use parent -norequire, 'Genesis::Hook::Addon';

	sub perform {
		my ($self) = @_;
		$self->done('addon-result');
	}
}

# ---------------------------------------------------------------------------
# Shared mock objects
# ---------------------------------------------------------------------------

my $test_seq = 0;

my $vault_service = mock "Genesis::Vault::Service" => {
	type => 'vault',
};

my $secrets_store = mock "Genesis::Env::SecretsStore" => {
	service => sub { return $vault_service },
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
	path => sub {
		my ($self, $file) = @_;
		return defined($file) ? "/mock/kit/path/$file" : "/mock/kit/path";
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
		secrets_store   => sub { return $secrets_store },
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

# Convenience: instantiate our Addon test subclass
sub make_hook {
	my %args = @_;
	my $env    = delete $args{env}    || mock_env();
	my $script = delete $args{script} || 'test-cmd';
	my $args   = delete $args{args}   || [];
	return Genesis::Hook::Addon::test_kit->init(
		env    => $env,
		kit    => $kit,
		script => $script,
		args   => $args,
		%args,
	);
}

# ---------------------------------------------------------------------------
# Globals set before all subtests
# ---------------------------------------------------------------------------
$Genesis::VERSION = '3.1.0-rc.10';
$ENV{GENESIS_CALL_BIN} = 'genesis';
$ENV{GENESIS_KIT_HOOK} = 'addon';

# ---------------------------------------------------------------------------
# Genesis::Hook::Addon must be loaded
# ---------------------------------------------------------------------------
subtest 'Genesis::Hook::Addon module loads' => sub {
	plan tests => 1;
	ok(defined(&Genesis::Hook::Addon::init), 'Genesis::Hook::Addon::init is defined');
};

# ---------------------------------------------------------------------------
# init
# ---------------------------------------------------------------------------
subtest 'init - missing env dies' => sub {
	plan tests => 1;

	throws_ok {
		Genesis::Hook::Addon::test_kit->init(
			kit    => $kit,
			script => 'test-cmd',
			args   => [],
		)
	} qr/Missing required arguments for a perl-based kit hook call: env/,
		'init() without env argument dies with required-args message';
};

subtest 'init - missing kit dies' => sub {
	plan tests => 1;

	my $env = mock_env();
	throws_ok {
		Genesis::Hook::Addon::test_kit->init(
			env    => $env,
			script => 'test-cmd',
			args   => [],
		)
	} qr/Missing required arguments for a perl-based kit hook call: kit/,
		'init() without kit argument dies with required-args message';
};

subtest 'init - missing script dies' => sub {
	plan tests => 1;

	my $env = mock_env();
	throws_ok {
		Genesis::Hook::Addon::test_kit->init(
			env  => $env,
			kit  => $kit,
			args => [],
		)
	} qr/Missing required arguments for a perl-based kit hook call: script/,
		'init() without script argument dies with required-args message';
};

subtest 'init - missing args dies' => sub {
	plan tests => 1;

	my $env = mock_env();
	throws_ok {
		Genesis::Hook::Addon::test_kit->init(
			env    => $env,
			kit    => $kit,
			script => 'test-cmd',
		)
	} qr/Missing required arguments for a perl-based kit hook call: args/,
		'init() without args argument dies with required-args message';
};

subtest 'init - returns blessed object with all required fields' => sub {
	plan tests => 8;

	my $env = mock_env();
	my $hook;
	lives_ok {
		$hook = Genesis::Hook::Addon::test_kit->init(
			env    => $env,
			kit    => $kit,
			script => 'rotate-creds',
			args   => ['--force'],
		)
	} 'init() succeeds with all required arguments';

	ok(defined $hook,                          'init() returns a defined value');
	isa_ok($hook, 'Genesis::Hook::Addon',      'returned object isa Genesis::Hook::Addon');
	isa_ok($hook, 'Genesis::Hook',             'returned object isa Genesis::Hook');
	is($hook->env,       $env,                 'env() returns the env passed to init()');
	is($hook->{script},  'rotate-creds',       'script is stored on the object');
	is_deeply($hook->{args}, ['--force'],      'args are stored on the object');
	is($hook->{type},    $ENV{GENESIS_KIT_HOOK}, 'type is set from GENESIS_KIT_HOOK');
};

subtest 'init - stores kit on object' => sub {
	plan tests => 1;

	my $hook = make_hook();
	is($hook->{kit}, $kit, 'kit is stored on the hook object');
};

subtest 'init - complete flag starts at 0' => sub {
	plan tests => 1;

	my $hook = make_hook();
	is($hook->{complete}, 0, 'complete flag initializes to 0');
};

subtest 'init - empty args array is valid' => sub {
	plan tests => 2;

	my $env = mock_env();
	my $hook;
	lives_ok {
		$hook = Genesis::Hook::Addon::test_kit->init(
			env    => $env,
			kit    => $kit,
			script => 'test-cmd',
			args   => [],
		)
	} 'init() accepts empty args array ref';
	is_deeply($hook->{args}, [], 'empty args array stored correctly');
};

# ---------------------------------------------------------------------------
# parse_options
# ---------------------------------------------------------------------------
subtest 'parse_options - returns hash in list context' => sub {
	plan tests => 3;

	my $hook = make_hook(args => ['--verbose', '--output', 'result.txt']);
	my %opts;
	lives_ok {
		%opts = $hook->parse_options(['verbose|v', 'output|o=s']);
	} 'parse_options() succeeds with matching args';

	is($opts{verbose}, 1,            'verbose flag parsed correctly');
	is($opts{output},  'result.txt', 'output option parsed correctly');
};

subtest 'parse_options - returns hashref in scalar context' => sub {
	plan tests => 3;

	my $hook = make_hook(args => ['--dry-run']);
	my $opts;
	lives_ok {
		$opts = $hook->parse_options(['dry-run|n']);
	} 'parse_options() succeeds in scalar context';

	ok(ref($opts) eq 'HASH', 'scalar context returns a hash reference');
	is($opts->{'dry-run'}, 1, 'dry-run flag parsed correctly');
};

subtest 'parse_options - applies defaults for unset options' => sub {
	plan tests => 3;

	my $hook = make_hook(args => []);
	my %opts;
	lives_ok {
		%opts = $hook->parse_options(
			['verbose|v', 'output|o=s'],
			output => 'default.txt',
		);
	} 'parse_options() succeeds with no args and defaults';

	ok(!$opts{verbose}, 'verbose is false/undef when not specified');
	is($opts{output}, 'default.txt', 'output retains default when not in args');
};

subtest 'parse_options - command-line args override defaults' => sub {
	plan tests => 1;

	my $hook = make_hook(args => ['--output', 'custom.txt']);
	my %opts = $hook->parse_options(
		['output|o=s'],
		output => 'default.txt',
	);
	is($opts{output}, 'custom.txt', 'command-line arg overrides default value');
};

subtest 'parse_options - short flags work via bundling' => sub {
	plan tests => 2;

	my $hook = make_hook(args => ['-v', '-o', 'out.txt']);
	my %opts = $hook->parse_options(['verbose|v', 'output|o=s']);

	is($opts{verbose}, 1,        'short flag -v parsed correctly');
	is($opts{output},  'out.txt','short option -o parsed correctly');
};

subtest 'parse_options - unknown option dies' => sub {
	plan tests => 1;

	# With no_pass_through, GetOptionsFromArray rejects unknown flags and
	# returns false, causing bail("Error parsing command line arguments").
	my $hook = make_hook(args => ['--unknown-flag']);
	throws_ok {
		$hook->parse_options(['verbose|v']);
	} qr/Error parsing command line arguments/,
		'parse_options() dies when GetOptionsFromArray rejects unknown option';
};

subtest 'parse_options - non-option args remain in args array' => sub {
	plan tests => 2;

	my $hook = make_hook(args => ['--verbose', 'positional-arg']);
	my %opts = $hook->parse_options(['verbose|v']);

	is($opts{verbose}, 1,               'flag parsed correctly alongside positional');
	is_deeply($hook->{args}, ['positional-arg'],
		'positional arg remains in args after parsing');
};

subtest 'parse_options - no args and no defaults yields empty-ish hash' => sub {
	plan tests => 1;

	my $hook = make_hook(args => []);
	my %opts = $hook->parse_options(['verbose|v', 'count|c=i']);
	ok(!defined $opts{verbose} && !defined $opts{count},
		'unprovided options are undef with no defaults');
};

# ---------------------------------------------------------------------------
# vault
# ---------------------------------------------------------------------------
subtest 'vault - returns vault service from secrets_store' => sub {
	plan tests => 2;

	my $hook = make_hook();
	my $got;
	lives_ok { $got = $hook->vault } 'vault() does not die';
	is($got, $vault_service, 'vault() returns the vault service object');
};

subtest 'vault - caches vault service on second call' => sub {
	plan tests => 2;

	my $hook = make_hook();
	my $first  = $hook->vault;
	my $second = $hook->vault;

	is($first,  $vault_service, 'first call returns vault service');
	is($second, $first,         'second call returns same cached object');
};

subtest 'vault - cached in {vault} slot on hook' => sub {
	plan tests => 1;

	my $hook = make_hook();
	$hook->vault;
	is($hook->{vault}, $vault_service,
		'vault service cached in {vault} slot after first call');
};

# ---------------------------------------------------------------------------
# results
# ---------------------------------------------------------------------------
subtest 'results - returns 1 unconditionally' => sub {
	plan tests => 1;

	my $hook = make_hook();
	is($hook->results, 1, 'results() returns 1 without calling done()');
};

subtest 'results - returns 1 even after done(0)' => sub {
	plan tests => 1;

	my $hook = make_hook();
	$hook->done(0);
	is($hook->results, 1, 'results() returns 1 even after done(0)');
};

subtest 'results - returns 1 even when complete flag is 0' => sub {
	plan tests => 2;

	my $hook = make_hook();
	is($hook->{complete}, 0, 'complete flag is 0 before done()');
	is($hook->results, 1, 'results() still returns 1 when not yet complete');
};

subtest 'results - is independent of done() call' => sub {
	plan tests => 3;

	my $hook = make_hook();
	is($hook->results, 1, 'results() is 1 before done()');
	$hook->done('something');
	is($hook->results, 1, 'results() is still 1 after done("something")');
	$hook->done(undef);
	is($hook->results, 1, 'results() is still 1 after done(undef)');
};

# ---------------------------------------------------------------------------
# help - no addons defined case
# ---------------------------------------------------------------------------
subtest 'help - returns 0 and prints message when no addon files exist' => sub {
	plan tests => 2;

	# Use a real temp directory that has no addon-* files
	require File::Temp;
	my $tmpdir = File::Temp::tempdir(CLEANUP => 1);
	mkdir("$tmpdir/hooks") or die "cannot create hooks dir: $!";

	# Create a kit mock whose path() points to the temp dir
	my $empty_kit = mock "Genesis::Kit::Empty" => {
		name    => 'empty-kit',
		version => '0.0.1',
		id      => sub { 'empty-kit/0.0.1' },
		kit_bug => sub {
			my ($self, $msg, @args) = @_;
			bail("Throwing a kit bug: ".$msg, @args);
		},
		path => sub {
			my ($self, $file) = @_;
			return defined($file) ? "$tmpdir/$file" : $tmpdir;
		},
		metadata            => { supports => [] },
		get_hook_module     => sub { return undef },
		genesis_version_min => '3.1.0-rc.10',
	};

	# Build an env whose kit() returns the empty kit
	my $env = mock_env(kit => $empty_kit);

	# Build the hook pointing at this temp kit
	my $hook = Genesis::Hook::Addon::test_kit->init(
		env    => $env,
		kit    => $empty_kit,
		script => 'test-cmd',
		args   => [],
	);

	# Capture STDERR output from help()
	my $stderr_output = '';
	{
		local *STDERR;
		open(STDERR, '>', \$stderr_output) or die "can't redirect STDERR: $!";
		$hook->help;
	}

	ok(1, 'help() ran without dying when no addon files present');
	like(
		$stderr_output,
		qr/No addons are defined for the empty-kit\/0\.0\.1 kit/,
		'help() prints "no addons" message to STDERR',
	);
};

done_testing;
