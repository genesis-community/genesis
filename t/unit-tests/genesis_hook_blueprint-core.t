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
require_ok 'Genesis::Hook::Blueprint';

# ---------------------------------------------------------------------------
# Test subclass - Genesis::Hook requires the class name to match
# Genesis::Hook::<Type>::<KitName> so that label() can parse it.
# ---------------------------------------------------------------------------
{
	package Genesis::Hook::Blueprint::test_kit;
	use parent -norequire, 'Genesis::Hook::Blueprint';

	sub perform {
		my ($self) = @_;
		$self->done($self->results);
	}
}

# ---------------------------------------------------------------------------
# Globals set before all subtests
# ---------------------------------------------------------------------------
$Genesis::VERSION = '3.1.0-rc.10';
$ENV{GENESIS_CALL_BIN} = 'genesis';
$ENV{GENESIS_KIT_HOOK} = 'blueprint';

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
		return defined($file) ? "/mock/kit/path/$file" : "/mock/kit/path";
	},
	metadata            => { supports => ['aws', 'vsphere', 'openstack'] },
	get_hook_module     => sub { return undef },
};

my $bosh = mock "Genesis::BOSH" => {
	alias                => 'mock-bosh',
	connect_and_validate => sub { return $_[0] },
};

sub mock_env {
	$test_seq++;
	my $seq = $test_seq;
	my %overrides = @_;
	mock "Genesis::Env::$seq" => {(
		name           => "test-env-$seq",
		type           => 'test',
		kit            => $kit,
		bosh           => sub { return $bosh },
		use_create_env => 0,
		features       => Mock::ReferencedValue->new(['ha', 'tls']),
		iaas           => 'aws',
		scale          => 'dev',
		is_ocfp        => 0,
		cpi_name       => 'aws_cpi',
		cpi_enabled    => 1,
		deployments    => mock("Genesis::Env::Deployments::$seq" => {
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
		path => sub {
			my ($self, $file) = @_;
			return defined($file) ? "/mock/env/path/$file" : "/mock/env/path";
		},
		file => 'test-env.yml',
	), %overrides};
}

sub make_hook {
	my $env = ref($_[0]) ? shift : mock_env();
	return Genesis::Hook::Blueprint::test_kit->init(env => $env, @_);
}

# ---------------------------------------------------------------------------
# Genesis::Hook::Blueprint must be loaded
# ---------------------------------------------------------------------------
subtest 'Genesis::Hook::Blueprint module loads' => sub {
	plan tests => 1;
	ok(defined(&Genesis::Hook::Blueprint::init),
		'Genesis::Hook::Blueprint::init is defined');
};

# ---------------------------------------------------------------------------
# init
# ---------------------------------------------------------------------------
subtest 'init - delegates to parent and returns blessed object' => sub {
	plan tests => 4;

	my $env  = mock_env();
	my $hook;
	lives_ok {
		$hook = Genesis::Hook::Blueprint::test_kit->init(env => $env)
	} 'init() succeeds with valid env';

	ok(defined $hook, 'init() returns a defined value');
	isa_ok($hook, 'Genesis::Hook::Blueprint',
		'returned object isa Genesis::Hook::Blueprint');
	isa_ok($hook, 'Genesis::Hook', 'returned object isa Genesis::Hook');
};

subtest 'init - initializes features from env' => sub {
	plan tests => 2;

	my $hook = make_hook();
	ok(defined $hook->{features}, 'features array ref is defined after init');
	cmp_deeply(
		$hook->{features},
		['ha', 'tls'],
		'features initialized from env->features'
	);
};

subtest 'init - initializes files to empty array ref' => sub {
	plan tests => 2;

	my $hook = make_hook();
	ok(defined $hook->{files}, 'files array ref is defined after init');
	cmp_deeply($hook->{files}, [], 'files starts as empty array ref');
};

subtest 'init - complete flag starts at 0' => sub {
	plan tests => 1;

	my $hook = make_hook();
	is($hook->{complete}, 0, 'complete flag initializes to 0');
};

# ---------------------------------------------------------------------------
# add_files
# ---------------------------------------------------------------------------
subtest 'add_files - appends a single file' => sub {
	plan tests => 2;

	my $hook = make_hook();
	$hook->add_files('base/base.yml');

	is(scalar(@{$hook->{files}}), 1, 'one file in list after add_files');
	is($hook->{files}[0], 'base/base.yml', 'correct file appended');
};

subtest 'add_files - appends multiple files in one call' => sub {
	plan tests => 4;

	my $hook = make_hook();
	$hook->add_files('base/base.yml', 'base/ha.yml', 'base/tls.yml');

	is(scalar(@{$hook->{files}}), 3, 'three files in list');
	is($hook->{files}[0], 'base/base.yml',  'first file correct');
	is($hook->{files}[1], 'base/ha.yml',    'second file correct');
	is($hook->{files}[2], 'base/tls.yml',   'third file correct');
};

subtest 'add_files - preserves insertion order across multiple calls' => sub {
	plan tests => 3;

	my $hook = make_hook();
	$hook->add_files('first.yml');
	$hook->add_files('second.yml');
	$hook->add_files('third.yml');

	is($hook->{files}[0], 'first.yml',  'first call order preserved');
	is($hook->{files}[1], 'second.yml', 'second call order preserved');
	is($hook->{files}[2], 'third.yml',  'third call order preserved');
};

# ---------------------------------------------------------------------------
# add_files_if_wants
# ---------------------------------------------------------------------------
subtest 'add_files_if_wants - adds file when feature is active' => sub {
	plan tests => 2;

	# env has 'ha' and 'tls' features
	my $hook = make_hook();
	$hook->add_files_if_wants('ha', 'base/ha.yml');

	is(scalar(@{$hook->{files}}), 1, 'one file added when feature active');
	is($hook->{files}[0], 'base/ha.yml', 'correct file added for active feature');
};

subtest 'add_files_if_wants - no-op when feature not active' => sub {
	plan tests => 1;

	my $hook = make_hook();
	$hook->add_files_if_wants('external-db', 'base/external-db.yml');

	is(scalar(@{$hook->{files}}), 0, 'no files added when feature not active');
};

subtest 'add_files_if_wants - adds multiple files when feature active' => sub {
	plan tests => 3;

	my $hook = make_hook();
	$hook->add_files_if_wants('tls', 'base/tls.yml', 'base/tls-certs.yml');

	is(scalar(@{$hook->{files}}), 2, 'both files added when feature active');
	is($hook->{files}[0], 'base/tls.yml',       'first file correct');
	is($hook->{files}[1], 'base/tls-certs.yml', 'second file correct');
};

subtest 'add_files_if_wants - accepts regexp feature test' => sub {
	plan tests => 2;

	my $hook = make_hook();
	$hook->add_files_if_wants(qr/^ha$/, 'base/ha.yml');

	is(scalar(@{$hook->{files}}), 1, 'one file added on regexp match');
	is($hook->{files}[0], 'base/ha.yml', 'correct file added via regexp');
};

subtest 'add_files_if_wants - regexp no-op when no feature matches' => sub {
	plan tests => 1;

	my $hook = make_hook();
	$hook->add_files_if_wants(qr/^proto-/, 'base/proto.yml');

	is(scalar(@{$hook->{files}}), 0, 'no files added when regexp does not match');
};

# ---------------------------------------------------------------------------
# add_files_if_exists
# ---------------------------------------------------------------------------
subtest 'add_files_if_exists - adds relative file when it exists under kit root' => sub {
	plan tests => 2;

	my $dir = workdir();
	put_file("$dir/overlays/custom.yml", "---\n# custom\n");

	my $local_kit = mock "Genesis::Kit::Exists" => {
		name    => 'test-kit',
		version => '1.0.0',
		id      => sub { $_[0]->name . '/' . $_[0]->version },
		kit_bug => sub { bail("Throwing a kit bug: " . $_[1]) },
		path    => sub {
			my ($self, $file) = @_;
			return defined($file) ? "$dir/$file" : $dir;
		},
		metadata        => { supports => ['aws'] },
		get_hook_module => sub { undef },
	};

	my $env = mock_env(kit => $local_kit);
	my $hook = make_hook($env);

	$hook->add_files_if_exists('overlays/custom.yml');

	is(scalar(@{$hook->{files}}), 1, 'one file added when relative file exists');
	is($hook->{files}[0], 'overlays/custom.yml', 'relative path added as-is');
};

subtest 'add_files_if_exists - skips relative file when it does not exist' => sub {
	plan tests => 1;

	my $hook = make_hook();
	$hook->add_files_if_exists('overlays/nonexistent.yml');

	is(scalar(@{$hook->{files}}), 0, 'no file added when relative path does not exist');
};

subtest 'add_files_if_exists - adds absolute path when within env dir and exists' => sub {
	plan tests => 2;

	my $dir = workdir();
	my $env_dir = "$dir/myenv";
	put_file("$env_dir/ops/override.yml", "---\n# override\n");

	my $local_kit = mock "Genesis::Kit::AbsExists" => {
		name    => 'test-kit',
		version => '1.0.0',
		id      => sub { $_[0]->name . '/' . $_[0]->version },
		kit_bug => sub { bail("Throwing a kit bug: " . $_[1]) },
		path    => sub {
			my ($self, $file) = @_;
			return defined($file) ? "$env_dir/$file" : $env_dir;
		},
		metadata        => { supports => ['aws'] },
		get_hook_module => sub { undef },
	};

	my $env = mock_env(
		kit  => $local_kit,
		path => sub {
			my ($self, $file) = @_;
			return defined($file) ? "$env_dir/$file" : $env_dir;
		},
	);

	my $hook = make_hook($env);
	my $abs_path = "$env_dir/ops/override.yml";
	$hook->add_files_if_exists($abs_path);

	is(scalar(@{$hook->{files}}), 1, 'one file added for existing absolute path in env dir');
	is($hook->{files}[0], $abs_path, 'absolute path stored as-is');
};

subtest 'add_files_if_exists - skips absolute path outside env dir' => sub {
	plan tests => 1;

	my $hook = make_hook();
	$hook->add_files_if_exists('/etc/passwd');

	is(scalar(@{$hook->{files}}), 0,
		'absolute path outside env dir silently skipped');
};

subtest 'add_files_if_exists - processes multiple files independently' => sub {
	plan tests => 2;

	my $dir = workdir();
	put_file("$dir/exists.yml", "---\n# exists\n");

	my $local_kit = mock "Genesis::Kit::MultiExists" => {
		name    => 'test-kit',
		version => '1.0.0',
		id      => sub { $_[0]->name . '/' . $_[0]->version },
		kit_bug => sub { bail("Throwing a kit bug: " . $_[1]) },
		path    => sub {
			my ($self, $file) = @_;
			return defined($file) ? "$dir/$file" : $dir;
		},
		metadata        => { supports => ['aws'] },
		get_hook_module => sub { undef },
	};

	my $env = mock_env(kit => $local_kit);
	my $hook = make_hook($env);

	$hook->add_files_if_exists('exists.yml', 'missing.yml');

	is(scalar(@{$hook->{files}}), 1, 'only existing file added');
	is($hook->{files}[0], 'exists.yml', 'correct existing file in list');
};

# ---------------------------------------------------------------------------
# remove_files
# ---------------------------------------------------------------------------
subtest 'remove_files - removes a file from the list' => sub {
	plan tests => 2;

	my $hook = make_hook();
	$hook->add_files('a.yml', 'b.yml', 'c.yml');
	$hook->remove_files('b.yml');

	is(scalar(@{$hook->{files}}), 2, 'two files remain after removal');
	cmp_deeply($hook->{files}, ['a.yml', 'c.yml'],
		'remaining files in original order');
};

subtest 'remove_files - silently ignores files not in the list' => sub {
	plan tests => 2;

	my $hook = make_hook();
	$hook->add_files('a.yml', 'b.yml');
	$hook->remove_files('nonexistent.yml');

	is(scalar(@{$hook->{files}}), 2, 'list unchanged when file not found');
	cmp_deeply($hook->{files}, ['a.yml', 'b.yml'], 'original files still present');
};

subtest 'remove_files - removes multiple files at once' => sub {
	plan tests => 2;

	my $hook = make_hook();
	$hook->add_files('a.yml', 'b.yml', 'c.yml', 'd.yml');
	$hook->remove_files('a.yml', 'c.yml');

	is(scalar(@{$hook->{files}}), 2, 'two files remain after removing two');
	cmp_deeply($hook->{files}, ['b.yml', 'd.yml'],
		'remaining files in original order');
};

subtest 'remove_files - preserves order of remaining files' => sub {
	plan tests => 1;

	my $hook = make_hook();
	$hook->add_files('first.yml', 'second.yml', 'third.yml', 'fourth.yml');
	$hook->remove_files('second.yml');

	cmp_deeply(
		$hook->{files},
		['first.yml', 'third.yml', 'fourth.yml'],
		'order of remaining files preserved after removal'
	);
};

# ---------------------------------------------------------------------------
# exchange_files
# ---------------------------------------------------------------------------
subtest 'exchange_files - replaces a file in-place' => sub {
	plan tests => 2;

	my $hook = make_hook();
	$hook->add_files('base/networking-v1.yml', 'base/ha.yml');
	$hook->exchange_files('base/networking-v1.yml' => 'base/networking-v2.yml');

	is(scalar(@{$hook->{files}}), 2, 'file count unchanged after exchange');
	is($hook->{files}[0], 'base/networking-v2.yml',
		'old file replaced with new file at same position');
};

subtest 'exchange_files - preserves position of exchanged file' => sub {
	plan tests => 3;

	my $hook = make_hook();
	$hook->add_files('a.yml', 'old.yml', 'c.yml');
	$hook->exchange_files('old.yml' => 'new.yml');

	is($hook->{files}[0], 'a.yml',   'file before exchange unchanged');
	is($hook->{files}[1], 'new.yml', 'exchanged file at original position');
	is($hook->{files}[2], 'c.yml',   'file after exchange unchanged');
};

subtest 'exchange_files - ignores keys not in file list' => sub {
	plan tests => 2;

	my $hook = make_hook();
	$hook->add_files('a.yml', 'b.yml');
	$hook->exchange_files('nonexistent.yml' => 'replacement.yml');

	is(scalar(@{$hook->{files}}), 2, 'list unchanged when key not found');
	cmp_deeply($hook->{files}, ['a.yml', 'b.yml'],
		'original files unchanged after non-matching exchange');
};

subtest 'exchange_files - handles multiple exchanges at once' => sub {
	plan tests => 2;

	my $hook = make_hook();
	$hook->add_files('old-a.yml', 'middle.yml', 'old-b.yml');
	$hook->exchange_files(
		'old-a.yml' => 'new-a.yml',
		'old-b.yml' => 'new-b.yml',
	);

	is($hook->{files}[0], 'new-a.yml', 'first exchange applied');
	is($hook->{files}[2], 'new-b.yml', 'second exchange applied');
};

# ---------------------------------------------------------------------------
# ops_dir
# ---------------------------------------------------------------------------
subtest 'ops_dir - returns default ops when genesis.ops_dir not set' => sub {
	plan tests => 1;

	my $hook = make_hook();
	is($hook->ops_dir, 'ops', 'ops_dir returns default "ops"');
};

subtest 'ops_dir - returns configured genesis.ops_dir value' => sub {
	plan tests => 1;

	my $env = mock_env(
		lookup => sub {
			my ($self, $key, $default) = @_;
			return 'custom-ops' if $key eq 'genesis.ops_dir';
			return $default;
		},
	);
	my $hook = make_hook($env);

	is($hook->ops_dir, 'custom-ops',
		'ops_dir returns value from genesis.ops_dir lookup');
};

# ---------------------------------------------------------------------------
# upstream_dir
# ---------------------------------------------------------------------------
subtest 'upstream_dir - returns undef when not configured' => sub {
	plan tests => 1;

	my $hook = make_hook();
	is($hook->upstream_dir, undef,
		'upstream_dir returns undef when upstream_dir not set');
};

subtest 'upstream_dir - returns value with trailing slash' => sub {
	plan tests => 1;

	my $hook = make_hook();
	$hook->{upstream_dir} = 'upstream';
	is($hook->upstream_dir, 'upstream/', 'upstream_dir appends trailing slash');
};

subtest 'upstream_dir - does not double-append trailing slash' => sub {
	plan tests => 1;

	my $hook = make_hook();
	$hook->{upstream_dir} = 'upstream/';
	is($hook->upstream_dir, 'upstream/',
		'upstream_dir does not duplicate trailing slash');
};

# ---------------------------------------------------------------------------
# upstream_pattern_match
# ---------------------------------------------------------------------------
subtest 'upstream_pattern_match - returns default regex when not configured' => sub {
	plan tests => 2;

	my $hook = make_hook();
	my $re = $hook->upstream_pattern_match;

	ok(ref($re) eq 'Regexp', 'upstream_pattern_match returns a Regexp');
	ok('operations/ha' =~ $re,
		'default pattern matches operations/ha');
};

subtest 'upstream_pattern_match - default pattern does not match non-operations path' => sub {
	plan tests => 1;

	my $hook = make_hook();
	ok('ha' !~ $hook->upstream_pattern_match,
		'default pattern does not match bare feature name');
};

subtest 'upstream_pattern_match - returns custom regex when configured' => sub {
	plan tests => 2;

	my $hook = make_hook();
	my $custom = qr/^features\/(.*)$/;
	$hook->{upstream_pattern_match} = $custom;

	my $re = $hook->upstream_pattern_match;
	ok('features/ha' =~ $re, 'custom pattern matches features/ha');
	ok('operations/ha' !~ $re, 'custom pattern does not match operations/ha');
};

# ---------------------------------------------------------------------------
# validate_features
# ---------------------------------------------------------------------------
subtest 'validate_features - accepts valid features (array ref)' => sub {
	plan tests => 2;

	my $env = mock_env(
		features => Mock::ReferencedValue->new(['ha', 'tls']),
	);
	my $hook = make_hook($env);

	lives_ok {
		$hook->validate_features(
			valid_features => [qw(ha tls external-db)],
		);
	} 'validate_features lives with all valid features';

	cmp_deeply([$hook->features], ['ha', 'tls'],
		'valid features retained after validation');
};

subtest 'validate_features - accepts valid features (hash ref)' => sub {
	plan tests => 1;

	my $env = mock_env(
		features => Mock::ReferencedValue->new(['ha']),
	);
	my $hook = make_hook($env);

	lives_ok {
		$hook->validate_features(
			valid_features => { ha => 1, tls => 1 },
		);
	} 'validate_features accepts hash ref for valid_features';
};

subtest 'validate_features - dies on invalid valid_features type' => sub {
	plan tests => 1;

	my $hook = make_hook();

	throws_ok {
		$hook->validate_features(
			valid_features => 'not-a-ref',
		);
	} qr/Invalid valid_features parameter/,
		'validate_features bails when valid_features is a plain scalar';
};

subtest 'validate_features - dies on undef valid_features' => sub {
	plan tests => 1;

	my $hook = make_hook();

	throws_ok {
		$hook->validate_features(
			valid_features => undef,
		);
	} qr/Invalid valid_features parameter/,
		'validate_features bails when valid_features is undef';
};

subtest 'validate_features - bails on invalid feature' => sub {
	plan tests => 1;

	my $env = mock_env(
		features => Mock::ReferencedValue->new(['unknown-feature']),
	);
	my $hook = make_hook($env);

	throws_ok {
		$hook->validate_features(
			valid_features => [qw(ha tls)],
		);
	} qr/Feature validation encountered the following errors/,
		'validate_features bails when feature is not valid';
};

subtest 'validate_features - deprecated feature with single string replacement' => sub {
	plan tests => 2;

	my $env = mock_env(
		features => Mock::ReferencedValue->new(['postgres']),
	);
	my $hook = make_hook($env);

	lives_ok {
		$hook->validate_features(
			valid_features => [qw(ha tls external-db)],
			deprecated_features => {
				'postgres' => { replace => 'external-db' },
			},
		);
	} 'validate_features lives when deprecated feature has single replacement';

	cmp_deeply([$hook->features], ['external-db'],
		'deprecated feature replaced with its single replacement');
};

subtest 'validate_features - deprecated feature with array replacement' => sub {
	plan tests => 2;

	my $env = mock_env(
		features => Mock::ReferencedValue->new(['old-tls']),
	);
	my $hook = make_hook($env);

	lives_ok {
		$hook->validate_features(
			valid_features => [qw(ha tls mutual-tls)],
			deprecated_features => {
				'old-tls' => { replace => ['tls', 'mutual-tls'] },
			},
		);
	} 'validate_features lives when deprecated feature has array replacement';

	cmp_deeply([$hook->features], ['tls', 'mutual-tls'],
		'deprecated feature replaced with all array replacements');
};

subtest 'validate_features - deprecated feature with empty array (now default)' => sub {
	plan tests => 2;

	my $env = mock_env(
		features => Mock::ReferencedValue->new(['legacy']),
	);
	my $hook = make_hook($env);

	lives_ok {
		$hook->validate_features(
			valid_features => [qw(ha tls)],
			deprecated_features => {
				'legacy' => { replace => [] },
			},
		);
	} 'validate_features lives when deprecated feature is now default (empty array)';

	cmp_deeply([$hook->features], [],
		'deprecated default feature removed from feature list');
};

subtest 'validate_features - deprecated feature with undef replacement (removed)' => sub {
	plan tests => 1;

	my $env = mock_env(
		features => Mock::ReferencedValue->new(['removed-feature']),
	);
	my $hook = make_hook($env);

	throws_ok {
		$hook->validate_features(
			valid_features => [qw(ha tls)],
			deprecated_features => {
				'removed-feature' => { replace => undef },
			},
		);
	} qr/Feature validation encountered the following errors/,
		'validate_features bails when deprecated feature has been removed (undef replacement)';
};

subtest 'validate_features - mutually exclusive features error' => sub {
	plan tests => 1;

	my $env = mock_env(
		features => Mock::ReferencedValue->new(['internal-db', 'external-db']),
	);
	my $hook = make_hook($env);

	throws_ok {
		$hook->validate_features(
			valid_features => [qw(internal-db external-db)],
			mutually_exclusive_features => {
				'database' => [qw(internal-db external-db)],
			},
		);
	} qr/Feature validation encountered the following errors/,
		'validate_features bails when mutually exclusive features both set';
};

subtest 'validate_features - single member of exclusive group is allowed' => sub {
	plan tests => 2;

	my $env = mock_env(
		features => Mock::ReferencedValue->new(['external-db']),
	);
	my $hook = make_hook($env);

	lives_ok {
		$hook->validate_features(
			valid_features => [qw(internal-db external-db)],
			mutually_exclusive_features => {
				'database' => [qw(internal-db external-db)],
			},
		);
	} 'validate_features lives with only one member of exclusive group';

	cmp_deeply([$hook->features], ['external-db'],
		'single exclusive feature retained');
};

subtest 'validate_features - updates features list after validation' => sub {
	plan tests => 1;

	my $env = mock_env(
		features => Mock::ReferencedValue->new(['ha', 'tls']),
	);
	my $hook = make_hook($env);

	$hook->validate_features(
		valid_features => [qw(ha tls external-db)],
	);

	cmp_deeply([$hook->features], bag('ha', 'tls'),
		'feature list updated via set_features after validation');
};

subtest 'validate_features - accepts ops file feature from env ops_dir' => sub {
	plan tests => 2;

	my $dir = workdir();
	my $ops_dir = "$dir/ops";
	put_file("$ops_dir/custom-ops.yml", "---\n# custom ops\n");

	my $env = mock_env(
		features => Mock::ReferencedValue->new(['custom-ops']),
		lookup   => sub {
			my ($self, $key, $default) = @_;
			return $default;
		},
		path => sub {
			my ($self, $file) = @_;
			return defined($file) ? "$dir/$file" : $dir;
		},
	);
	my $hook = make_hook($env);

	lives_ok {
		$hook->validate_features(
			valid_features => [qw(ha tls)],
		);
	} 'validate_features accepts feature backed by ops file in env ops_dir';

	cmp_deeply([$hook->features], ['custom-ops'],
		'ops-file-backed feature retained after validation');
};

# ---------------------------------------------------------------------------
# results
# ---------------------------------------------------------------------------
subtest 'results - returns file list after done() called' => sub {
	plan tests => 2;

	my $hook = make_hook();
	$hook->add_files('base/base.yml', 'base/ha.yml');
	$hook->{complete} = 1;

	my $files;
	lives_ok { $files = $hook->results } 'results() lives when hook is complete';
	cmp_deeply($files, ['base/base.yml', 'base/ha.yml'],
		'results() returns the file list array ref');
};

subtest 'results - dies when hook not complete' => sub {
	plan tests => 1;

	my $hook = make_hook();
	$hook->add_files('base/base.yml');
	# complete remains 0

	throws_ok {
		$hook->results
	} qr/Blueprint hook could not be run/,
		'results() bails when hook not marked complete';
};

subtest 'results - dies when file list is empty after completion' => sub {
	plan tests => 1;

	my $hook = make_hook();
	$hook->{complete} = 1;
	# files remains empty

	throws_ok {
		$hook->results
	} qr/Could not determine which YAML files to merge/,
		'results() bails when hook complete but no files were added';
};

done_testing;
