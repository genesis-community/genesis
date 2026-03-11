#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::Deep;

use_ok 'Genesis';
use_ok 'Genesis::Kit';
use_ok 'Genesis::Kit::Dev';
use_ok 'Genesis::Kit::Compiled';
use_ok 'Genesis::Kit::Compiler';
use_ok 'Genesis::Config';
use_ok 'Service::Vault::Remote';

$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sub kit {
	my ($name, $version, $path) = @_;
	$version ||= 'latest';
	$path    ||= 't/src/simple';
	my $tmp = workdir;
	my $file;
	quietly {
		$file = Genesis::Kit::Compiler->new($path)->compile($name, $version, $tmp, force => 1);
	};
	return Genesis::Kit::Compiled->new(
		name    => $name,
		version => $version,
		archive => "$tmp/$file"
	);
}

sub decompile_kit {
	return Genesis::Kit::Dev->new(kit(@_)->path);
}

# ---------------------------------------------------------------------------
# Minimal mock environment for source_yaml_files testing
# ---------------------------------------------------------------------------

package mockenv;

sub new {
	my ($class, @features) = @_;
	bless { f => \@features }, $class;
}
sub features           { @{$_[0]{f}}; }
sub name               { "mock-env"; }
sub type               { "mock-type"; }
sub secrets_path       { "mock/env"; }
sub use_create_env     { 0; }
sub lookup_bosh_target { wantarray ? ('a-bosh', 'params.bosh') : 'a-bosh'; }
sub lookup             { "a-value" }
sub bosh_target        { 'a-bosh'; }
sub path               { "some/path/some/where" . ($_[1] ? "/$_[1]" : ""); }

package main;

# ===========================================================================
# new($path) — constructor
# ===========================================================================

subtest 'Genesis::Kit::Dev->new stores source path' => sub {
	my $compiled = kit('test', '1.0.0');
	my $src_path = $compiled->path;   # extract and get root

	my $dev = Genesis::Kit::Dev->new($src_path);
	isa_ok($dev, 'Genesis::Kit::Dev', 'new() returns a Genesis::Kit::Dev object');
	isa_ok($dev, 'Genesis::Kit',      'Genesis::Kit::Dev inherits from Genesis::Kit');

	is($dev->{source}, $src_path, 'new() stores the path in {source}');
};

# ===========================================================================
# name() — always returns "dev"
# ===========================================================================

subtest 'name() always returns "dev"' => sub {
	my $dev = decompile_kit('test', '1.0.0');
	is($dev->name, 'dev', 'name() returns the literal string "dev"');

	# Reconfirm with a differently-named compile target to show it is not
	# derived from kit.yml.
	my $dev2 = decompile_kit('mykit', '2.3.4');
	is($dev2->name, 'dev', 'name() returns "dev" regardless of kit name in kit.yml');
};

# ===========================================================================
# version() — always returns "latest"
# ===========================================================================

subtest 'version() always returns "latest"' => sub {
	my $dev = decompile_kit('test', '1.0.0');
	is($dev->version, 'latest', 'version() returns the literal string "latest"');

	my $dev2 = decompile_kit('mykit', '9.9.9');
	is($dev2->version, 'latest', 'version() returns "latest" regardless of compiled version');
};

# ===========================================================================
# is_dev() — always returns 1
# ===========================================================================

subtest 'is_dev() returns 1' => sub {
	my $dev = decompile_kit('test', '1.0.0');
	ok($dev->is_dev, 'is_dev() returns a true value');
	is($dev->is_dev, 1, 'is_dev() returns exactly 1');

	# Compiled kits return 0 (contrast)
	my $compiled = kit('test', '1.0.0');
	ok(!$compiled->is_dev, 'compiled kits report is_dev() as false');
};

# ===========================================================================
# id() — "$name/$version (dev)" using kit.yml fields
# ===========================================================================

subtest 'id() uses kit.yml metadata name and version' => sub {
	my $dev = decompile_kit('test', '1.0.0');

	# The simple kit fixture kit.yml has:
	#   name: simple
	#   (no version field)
	# So version defaults to 'in-development'.
	is(
		$dev->id,
		'simple/in-development (dev)',
		'id() returns "<kit.yml name>/in-development (dev)" when kit.yml has no version'
	);

	# The id always carries "(dev)" regardless of the compiled version label.
	like($dev->id, qr/\(dev\)$/, 'id() always ends with "(dev)"');
	unlike($dev->id, qr/^test\//, 'id() does not use the compiled kit name "test"');
};

# ===========================================================================
# extract() — copies source to temp workspace
# ===========================================================================

subtest 'extract() copies dev directory to a temp workspace' => sub {
	# Use a fresh kit to get a clean extracted path.
	my $compiled = kit('test', '0.0.1');
	my $src_path = $compiled->path;   # this is the extracted compiled root

	my $dev = Genesis::Kit::Dev->new($src_path);

	# Before extraction, {root} is not set.
	ok(!$dev->{root}, 'root is not set before extract()');

	my $result;
	quietly { $result = $dev->extract; };

	# First call returns 1.
	is($result, 1, 'extract() returns 1 on first call');

	# root is now set.
	ok($dev->{root}, 'extract() sets {root}');

	# The root must differ from the source (copy, not a symlink/reuse).
	isnt($dev->{root}, $src_path, 'extracted root differs from source path');

	# kit.yml must exist in the extracted workspace.
	ok(-f $dev->path('kit.yml'), 'kit.yml exists in extracted workspace');

	# hooks/ directory must exist.
	ok(-d $dev->path('hooks'), 'hooks/ directory exists in extracted workspace');

	# manifest.yml must exist.
	ok(-f $dev->path('manifest.yml'), 'manifest.yml exists in extracted workspace');

	# .helper script was installed.
	ok(-f "$dev->{root}/.helper", '.helper script was installed after extract()');
};

subtest 'extract() is memoized (second call is a no-op)' => sub {
	my $compiled = kit('test', '0.0.2');
	my $dev = Genesis::Kit::Dev->new($compiled->path);

	quietly { $dev->extract };
	my $first_root = $dev->{root};

	# Second call.
	my $result2;
	quietly { $result2 = $dev->extract };

	is($result2, undef, 'extract() returns nothing (undef) on subsequent calls');
	is($dev->{root}, $first_root, 'extract() does not change {root} on subsequent calls');
};

# ===========================================================================
# kit_bug(@msg) — dies with dev-kit-specific message
# ===========================================================================

subtest 'kit_bug() dies with dev-kit message and sets $! to 2' => sub {
	my $dev = decompile_kit('test', '1.0.0');

	quietly {
		throws_ok {
			$dev->kit_bug('something broke badly');
		} qr{something broke badly}i,
		'kit_bug() includes the caller-supplied message in the exception';
	};

	quietly {
		throws_ok {
			$dev->kit_bug('some failure');
		} qr{bug in your dev/ kit}i,
		'kit_bug() mentions "bug in your dev/ kit"';
	};

	quietly {
		throws_ok {
			$dev->kit_bug('some failure');
		} qr{contact.*author.*you}si,
		'kit_bug() says to contact the author (you)';
	};

	my $captured_errno;
	quietly {
		eval { $dev->kit_bug('errno check') };
		$captured_errno = 0+$!;
	};
	is($captured_errno, 2, 'kit_bug() sets $! to 2 (ENOENT) before dying');
};

subtest 'kit_bug() message differs from compiled kit_bug()' => sub {
	my $compiled = kit('test', '1.0.0');
	my $dev      = decompile_kit('test', '1.0.0');

	my ($compiled_err, $dev_err);
	quietly {
		eval { $compiled->kit_bug('buggy behavior') };
		$compiled_err = $@;
		eval { $dev->kit_bug('buggy behavior') };
		$dev_err = $@;
	};

	# Compiled kit mentions GitHub issues URL; dev kit mentions "you".
	like($compiled_err, qr{github\.com.*/issues}i,
		'compiled kit_bug() mentions the GitHub issues URL');
	unlike($dev_err, qr{github\.com}i,
		'dev kit_bug() does NOT mention GitHub');
	like($dev_err, qr{you}i,
		'dev kit_bug() tells the developer to contact themselves');
};

# ===========================================================================
# Inherited methods from Genesis::Kit
# ===========================================================================

subtest 'path($relative) returns full path inside the extracted workspace' => sub {
	my $dev = decompile_kit('test', '1.0.0');
	quietly { $dev->extract };

	my $root = $dev->path;
	ok(-d $root, 'path() with no arg returns the workspace root directory');

	my $kit_yml = $dev->path('kit.yml');
	is($kit_yml, "$root/kit.yml", 'path("kit.yml") appends relative path to root');
	ok(-f $kit_yml, 'path("kit.yml") points to an existing file');

	# Leading slashes are stripped.
	is($dev->path('/hooks/blueprint'), "$root/hooks/blueprint",
		'path() strips leading slashes from the relative argument');
};

subtest 'glob($pattern) matches files in the extracted workspace' => sub {
	my $dev = decompile_kit('test', '1.0.0');
	quietly { $dev->extract };

	my @yml = $dev->glob('*.yml');
	ok(scalar @yml > 0, 'glob("*.yml") returns at least one result');
	ok((grep { $_ eq 'kit.yml' } @yml), 'glob("*.yml") finds kit.yml');

	my @hooks = $dev->glob('hooks/*');
	ok(scalar @hooks > 0, 'glob("hooks/*") returns at least one result');
};

subtest 'has_hook($name) checks for hook existence in extracted workspace' => sub {
	my $dev = decompile_kit('test', '1.0.0');
	quietly { $dev->extract };

	ok($dev->has_hook('blueprint'), 'has_hook("blueprint") returns true for existing hook');
	ok($dev->has_hook('new'),       'has_hook("new") returns true for existing hook');
	ok(!$dev->has_hook('secrets'),  'has_hook("secrets") returns false for missing hook');
};

subtest 'metadata() parses kit.yml from the dev directory' => sub {
	my $dev = decompile_kit('test', '1.0.0');

	my $meta;
	quietly { $meta = $dev->metadata };

	ok(defined $meta, 'metadata() returns a defined value');
	is(ref $meta, 'HASH', 'metadata() returns a hash reference');
	is($meta->{name}, 'simple', 'metadata()->{name} equals "simple" from kit.yml');

	# Subsequent calls return the same data (memoization).
	my $meta2;
	quietly { $meta2 = $dev->metadata };
	cmp_deeply($meta2, $meta, 'subsequent calls to metadata() return the same data');
};

subtest 'check_prereqs() performs genesis version check' => sub {
	my $dev = decompile_kit('test', '1.0.0');

	# kit.yml has genesis_version_min: 2.8.0 — the test suite sets
	# $Genesis::VERSION to '999.999.999' (via GENESIS_TESTING), so it passes.
	local $Genesis::VERSION = '999.999.999';
	my $ok;
	quietly { $ok = $dev->check_prereqs };
	ok($ok, 'check_prereqs() passes when genesis version satisfies genesis_version_min');

	local $Genesis::VERSION = '0.0.1';
	my $not_ok;
	quietly { $not_ok = $dev->check_prereqs };
	ok(!$not_ok, 'check_prereqs() fails when genesis version is too old');
};

done_testing;
