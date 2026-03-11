#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::Deep;

use_ok 'Genesis';
use_ok 'Genesis::Kit';
use_ok 'Genesis::Kit::Compiled';
use_ok 'Genesis::Kit::Dev';
use_ok 'Service::Vault::Remote';

use_ok 'Genesis::Config';
$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");

use Genesis::Kit::Compiler;

# NOTE: Genesis-community provider, kit URLs, available kits, and kit versions
# tests moved to integration tests

package mockenv;

sub new {
	my ($class, @features) = @_;
	bless {
		f => \@features,
		vault => Service::Vault::Remote->new(url => "https://localhost:8999", name => "mockvault")
	}, $class;
}
sub features { @{$_[0]{f}}; }
sub name { "mock-env"; }
sub type { "mock-type"; }
sub secrets_path { "mock/env"; }
sub use_create_env { 0; }
sub lookup_bosh_target { wantarray ? ('a-bosh', 'params.bosh') : 'a-bosh'; }
sub lookup { "a-value" }
sub bosh_target { 'a-bosh'; }
sub path { "some/path/some/where".($_[1]?"/$_[1]":""); }
sub vault { $_[0]->{vault} }
sub get_environment_variables {
	my $self = shift;
	my %env;
	$env{GENESIS_ROOT}         = $self->path;
	$env{GENESIS_ENVIRONMENT}  = $self->name;
	$env{GENESIS_TYPE}         = $self->type;
	$env{GENESIS_TARGET_VAULT} = $env{SAFE_TARGET} = $self->vault->ref;
	$env{GENESIS_VERIFY_VAULT} = $self->vault->verify || "";

	$env{HOOK_ENV_VARS}='setup';
	$env{GENESIS_VAULT_PREFIX} = $env{GENESIS_SECRETS_PATH} = $self->secrets_path;
	return %env;
}

package main;

sub kit {
	my ($name, $version, $path) = @_;
	$version ||= 'latest';
	$path ||= 't/src/simple';
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
# Subtest: Genesis::Kit->new() abstract guard
# ---------------------------------------------------------------------------
subtest 'Genesis::Kit->new() dies for abstract base class' => sub {
	throws_ok { Genesis::Kit->new() }
		qr/abstract class/i,
		'Genesis::Kit->new() dies with abstract class error';
};

# ---------------------------------------------------------------------------
# Subtest 1: kit_bug for compiled and dev kits
# ---------------------------------------------------------------------------
subtest 'kit utilities' => sub {
	my $kit = kit('test', '1.0.0');
	quietly { throws_ok { $kit->kit_bug('buggy behavior') }
		qr{
			buggy \s+ behavior.*
			a \s+ bug \s+ in \s+ the \s+ test/1\.0\.0 \s+ kit.*
			file \s+ an \s+ issue \s+ at .* https://github\.com/.*/issues
		}six, "kit_bug() reports the pertinent details for a compiled kit";
	};

	my $dev = decompile_kit('test', '1.0.0');
	quietly { throws_ok { $dev->kit_bug('buggy behavior') }
		qr{
			buggy \s+ behavior.*
			a \s+ bug \s+ in \s+ your \s+ dev/ \s+ kit.*
			contact .* author .* you
		}six, "kit_bug() reports the pertinent details for a dev kit";
	};
};

# ---------------------------------------------------------------------------
# Subtest 2: compiled kit identity, metadata, paths, has_hook
# ---------------------------------------------------------------------------
subtest 'compiled kits' => sub {
	my $kit = kit(test => '0.0.1');

	cmp_deeply($kit->metadata, superhashof({
			name => 'simple',
		}), "a kit should be able to parse its metadata");
	cmp_deeply($kit->metadata, $kit->metadata,
		"subsequent calls to kit->metadata should return the same metadata");

	is($kit->id, "test/0.0.1", "compiled kits should report their ID properly");
	is($kit->name, "test", "compiled kits should know their own name");
	is($kit->version, "0.0.1", "compiled kits should know their own version");
	for my $f (qw(kit.yml manifest.yml hooks/new hooks/blueprint)) {
		ok(-f $kit->path($f), "[test-0.0.1] $f file should exist in compiled kit");
	}
	for my $d (qw(hooks)) {
		ok(-d $kit->path($d), "[test-0.0.1] $d/ should exist in compiled kit");
	}
	ok(!$kit->has_hook('secrets'), "[test-0.0.1] kit should not report hooks it doesn't have");
};

# ---------------------------------------------------------------------------
# Subtest 3: dev kit identity, paths, source_yaml_files
# ---------------------------------------------------------------------------
subtest 'dev kits' => sub {
	my $kit = kit(test => '0.0.1');
	my $dev = decompile_kit(test => '0.0.1');
	is($dev->name, "dev", "dev kits are all named 'dev'");
	is($dev->version, "latest", "dev kits are always at latest");
	is($dev->id, "simple/in-development (dev)", "dev kits should report their ID as dev, all the time");
	for my $f (qw(kit.yml manifest.yml hooks/new hooks/blueprint)) {
		ok(-f $dev->path($f), "[dev :: test-0.0.1] $f file should exist in dev kit");
	}
	for my $d (qw(hooks)) {
		ok(-d $dev->path($d), "[dev :: test-0.0.1] $d/ should exist in dev kit");
	}

	isnt($kit->path("kit.yml"), $dev->path("kit.yml"),
		"compiled-kit paths are not the same as dev-kit paths");

	cmp_deeply(
		[$kit->source_yaml_files(mockenv->new())],
		[re('\bmanifest.yml$')],
		"simple kits without subkits should return base yaml files only"
	);

	cmp_deeply(
		[$kit->source_yaml_files(mockenv->new('bogus', 'features'))],
		[$kit->source_yaml_files(mockenv->new())],
		"simple kits ignore features they don't know about"
	);
};

# ---------------------------------------------------------------------------
# Subtest 4: version requirements (check_prereqs)
# ---------------------------------------------------------------------------
subtest 'version requirements' => sub {
	my $kit = kit(test => '1.2.3');
	local $Genesis::VERSION;

	$Genesis::VERSION = '0.0.1';
	quietly { ok !$kit->check_prereqs, 'v0.0.1 is too old for the t/src/simple kit prereq of 2.8.0'; };

	$Genesis::VERSION = '9.9.9';
	ok $kit->check_prereqs, 'v9.9.9 is new enough for the t/src/simple kit prereq of 2.8.0';

	$Genesis::VERSION = "dev";
	ok $kit->check_prereqs, 'dev versions are new enough for any kit prereq';
};

# ---------------------------------------------------------------------------
# Subtest 5: known_hooks class and instance methods
# ---------------------------------------------------------------------------
subtest 'known_hooks' => sub {
	my @expected = qw(
		new feature blueprint info check pre-deploy post-deploy terminate
		edit shell addon cloud-config cpi-config features runtime-config
	);

	# Class method call
	my @class_hooks = Genesis::Kit::known_hooks();
	cmp_deeply(\@class_hooks, \@expected,
		"known_hooks() class call returns the full list of recognized hook names");

	# Instance method call produces the same list
	my $kit = kit(test => '0.0.1');
	my @inst_hooks = $kit->known_hooks();
	cmp_deeply(\@inst_hooks, \@expected,
		"known_hooks() instance call returns the same list as the class call");

	ok scalar(@class_hooks) == 15,
		"known_hooks() returns exactly 15 hooks";
};

# ---------------------------------------------------------------------------
# Subtest 6: is_dev distinguishes compiled vs dev kits
# ---------------------------------------------------------------------------
subtest 'is_dev' => sub {
	my $compiled = kit(test => '0.0.1');
	my $dev = decompile_kit(test => '0.0.1');

	ok !$compiled->is_dev, "compiled kits return false for is_dev()";
	ok  $dev->is_dev,      "dev kits return true for is_dev()";

	is($compiled->is_dev, 0, "compiled kit is_dev() returns exactly 0");
	is($dev->is_dev,      1, "dev kit is_dev() returns exactly 1");
};

# ---------------------------------------------------------------------------
# Subtest 7: path() returns workspace root and relative sub-paths
# ---------------------------------------------------------------------------
subtest 'path method' => sub {
	my $kit = kit(test => '0.0.1');

	my $root = $kit->path();
	ok defined($root) && length($root) > 0,
		"path() with no args returns a non-empty root directory";
	ok -d $root, "path() root directory exists on disk";

	my $kityml = $kit->path('kit.yml');
	like $kityml, qr{/kit\.yml$}, "path('kit.yml') has kit.yml at the end";
	ok -f $kityml, "path('kit.yml') points to an existing file";
	is $kityml, "$root/kit.yml",
		"path('kit.yml') equals root . '/kit.yml'";

	# Leading slash should be stripped
	my $with_slash = $kit->path('/hooks/blueprint');
	my $without_slash = $kit->path('hooks/blueprint');
	is $with_slash, $without_slash,
		"path() strips leading slashes from the argument";

	my $hook_path = $kit->path('hooks/blueprint');
	ok -f $hook_path, "path('hooks/blueprint') points to an existing hook file";
};

# ---------------------------------------------------------------------------
# Subtest 8: glob() matches files relative and absolute
# ---------------------------------------------------------------------------
subtest 'glob method' => sub {
	my $kit = kit(test => '0.0.1');

	# Relative glob — should return paths relative to the kit root
	my @rel = $kit->glob('hooks/*');
	ok scalar(@rel) > 0, "glob('hooks/*') returns at least one match";
	for my $f (@rel) {
		like $f, qr{^hooks/}, "relative glob result '$f' starts with 'hooks/'";
		unlike $f, qr{^/}, "relative glob result '$f' is not an absolute path";
	}

	# Absolute glob
	my @abs = $kit->glob('hooks/*', 1);
	ok scalar(@abs) > 0, "glob('hooks/*', 1) returns at least one match";
	for my $f (@abs) {
		like $f, qr{^/}, "absolute glob result '$f' is an absolute path";
		ok -f $f, "absolute glob result '$f' exists on disk";
	}

	ok scalar(@rel) == scalar(@abs),
		"relative and absolute globs return the same number of results";

	# Leading slash stripped
	my @a = $kit->glob('/hooks/*');
	my @b = $kit->glob('hooks/*');
	cmp_deeply(\@a, \@b,
		"glob() strips leading slash from pattern");

	# No matches for non-existent pattern
	my @none = $kit->glob('no-such-dir/*');
	is scalar(@none), 0, "glob() returns empty list for non-matching pattern";
};

# ---------------------------------------------------------------------------
# Subtest 9: has_hook for known and unknown hooks
# ---------------------------------------------------------------------------
subtest 'has_hook' => sub {
	my $kit = kit(test => '0.0.1');

	# The simple fixture only has blueprint and new hooks
	ok $kit->has_hook('blueprint'), "has_hook('blueprint') is true for the simple kit";
	ok $kit->has_hook('new'),       "has_hook('new') is true for the simple kit";

	# Hooks that are NOT present in the simple fixture
	for my $absent (qw(check info pre-deploy post-deploy terminate
	                   cloud-config cpi-config features runtime-config prereqs secrets)) {
		ok !$kit->has_hook($absent), "has_hook('$absent') is false (not in simple kit)";
	}

	# The addon hook is special: has_hook('addon') without a script option
	# resolves script='' which always maps to the built-in '@Genesis::Hook::Addon'
	# module handler when GENESIS_NO_MODULE_HOOKS is not set.  This is
	# documented behavior.  To test whether a specific named addon script is
	# present in the kit, pass the script option:
	ok !$kit->has_hook('addon', script => 'login'),
		"has_hook('addon', script=>'login') is false (no addon-login in simple kit)";

	# Result is a file path (truthy string) when hook exists
	my $bp = $kit->has_hook('blueprint');
	ok -f $bp, "has_hook('blueprint') returns a path to an existing file";

	# Caching: second call returns same result
	my $bp2 = $kit->has_hook('blueprint');
	is $bp, $bp2, "has_hook() returns cached result on repeated calls";
};

# ---------------------------------------------------------------------------
# Subtest 10: metadata content and memoization
# ---------------------------------------------------------------------------
subtest 'metadata' => sub {
	my $kit = kit(test => '0.0.1');

	my $meta = $kit->metadata();
	ok ref($meta) eq 'HASH', "metadata() returns a hashref";

	# Keys from t/src/simple/kit.yml
	is $meta->{name},   'simple',
		"metadata()->{name} matches kit.yml";
	like $meta->{author}, qr/James Hunt/,
		"metadata()->{author} contains expected author";
	like $meta->{docs},   qr{https://github\.com},
		"metadata()->{docs} is a GitHub URL";
	like $meta->{code},   qr{https://github\.com},
		"metadata()->{code} is a GitHub URL";
	is $meta->{genesis_version_min}, '2.8.0',
		"metadata()->{genesis_version_min} is 2.8.0";

	# Single-key retrieval
	my $name_val = $kit->metadata('name');
	is $name_val, 'simple', "metadata('name') single-key form returns scalar";

	# Missing key returns undef
	my $missing = $kit->metadata('no_such_key');
	ok !defined($missing), "metadata() returns undef for missing keys";

	# Memoization: same hashref returned on repeated calls
	my $meta2 = $kit->metadata();
	is $meta, $meta2, "metadata() returns the same memoized reference on repeat calls";

	# use_create_env defaults to 'allow' for genesis_version_min >= 2.8.0
	is $meta->{use_create_env}, 'allow',
		"metadata() sets use_create_env='allow' for 2.8.0+ kits that omit the field";
};

# ---------------------------------------------------------------------------
# Subtest 11: genesis_version_min extraction and memoization
# ---------------------------------------------------------------------------
subtest 'genesis_version_min' => sub {
	my $kit = kit(test => '0.0.1');

	my $min = $kit->genesis_version_min();
	is $min, '2.8.0',
		"genesis_version_min() returns the value from kit.yml";

	# Calling twice should return the same memoized string
	my $min2 = $kit->genesis_version_min();
	is $min, $min2, "genesis_version_min() is memoized";
};

# ---------------------------------------------------------------------------
# Subtest 12: feature_compatibility version comparisons
# ---------------------------------------------------------------------------
subtest 'feature_compatibility' => sub {
	my $kit = kit(test => '0.0.1');
	# kit.yml has genesis_version_min: 2.8.0

	ok  $kit->feature_compatibility('2.8.0'),
		"feature_compatibility('2.8.0') is true (kit meets exact version)";
	ok  $kit->feature_compatibility('2.7.0'),
		"feature_compatibility('2.7.0') is true (kit exceeds that version)";
	ok  $kit->feature_compatibility('2.6.13'),
		"feature_compatibility('2.6.13') is true (kit exceeds that version)";
	ok !$kit->feature_compatibility('2.9.0'),
		"feature_compatibility('2.9.0') is false (kit is below that version)";
	ok !$kit->feature_compatibility('3.0.0'),
		"feature_compatibility('3.0.0') is false (kit is well below that version)";

	# Invalid version string must die
	quietly {
		throws_ok { $kit->feature_compatibility('not-a-version') }
			qr/Invalid base version/,
			"feature_compatibility() dies on an invalid version string";
	};
};

# ---------------------------------------------------------------------------
# Subtest 13: secrets_store and uses_credhub defaults
# ---------------------------------------------------------------------------
subtest 'secrets_store and uses_credhub' => sub {
	my $kit = kit(test => '0.0.1');
	# t/src/simple/kit.yml has no secrets_store key; default is 'vault'

	is $kit->secrets_store(), 'vault',
		"secrets_store() defaults to 'vault' when not specified in kit.yml";

	ok !$kit->uses_credhub(),
		"uses_credhub() is false when secrets_store is 'vault'";
};

# ---------------------------------------------------------------------------
# Subtest 14: required_configs defaults (no required_configs in kit.yml)
# ---------------------------------------------------------------------------
subtest 'required_configs' => sub {
	my $kit = kit(test => '0.0.1');
	# simple kit.yml has no required_configs key

	# blueprint hook requires cloud config by default
	my @bp_req = $kit->required_configs('blueprint');
	cmp_deeply(\@bp_req, ['cloud'],
		"required_configs('blueprint') returns ['cloud'] by default");

	# cloud-config hook never requires any config
	my @cc_req = $kit->required_configs('cloud-config');
	cmp_deeply(\@cc_req, [],
		"required_configs('cloud-config') returns empty list");

	# check hook requires cloud config (when GENESIS_CONFIG_NO_CHECK is not set)
	{
		local $ENV{GENESIS_CONFIG_NO_CHECK};
		delete $ENV{GENESIS_CONFIG_NO_CHECK};
		my @chk_req = $kit->required_configs('check');
		cmp_deeply(\@chk_req, ['cloud'],
			"required_configs('check') returns ['cloud'] when GENESIS_CONFIG_NO_CHECK is not set");
	}

	# Some hook that is not blueprint/check/manifest requires nothing
	my @other = $kit->required_configs('info');
	cmp_deeply(\@other, [],
		"required_configs('info') returns empty list by default");
};

# ---------------------------------------------------------------------------
# Subtest 15: required_connectivity returns empty list when not declared
# ---------------------------------------------------------------------------
subtest 'required_connectivity' => sub {
	my $kit = kit(test => '0.0.1');
	# simple kit.yml has no required_connectivity key

	my @conns = $kit->required_connectivity();
	cmp_deeply(\@conns, [],
		"required_connectivity() returns empty list when not declared in kit.yml");

	my @conns2 = $kit->required_connectivity('blueprint');
	cmp_deeply(\@conns2, [],
		"required_connectivity('blueprint') returns empty list when not declared");
};

# ---------------------------------------------------------------------------
# Subtest 16: services and provides_service (simple kit has no services key)
# ---------------------------------------------------------------------------
subtest 'services and provides_service' => sub {
	my $kit = kit(test => '0.0.1');
	# simple kit.yml has no services key

	my @svcs = $kit->services();
	cmp_deeply(\@svcs, [],
		"services() returns empty list when not declared in kit.yml");

	# No explicit services declared; fall back to heuristics
	# kit name is 'test', not 'vault' — so provides_service('vault') => 0
	ok !$kit->provides_service('vault'),
		"provides_service('vault') is false for non-vault kit name";

	# Kit id is 'test/0.0.1', does not start with 'bosh/' — so director is false
	ok !$kit->provides_service('director'),
		"provides_service('director') is false for non-bosh kit";

	# Arbitrary service also returns 0
	ok !$kit->provides_service('some-service'),
		"provides_service('some-service') is false for unknown service";
};

# ---------------------------------------------------------------------------
# Subtest 17: requires_iaas and requires_scale return undef when not declared
# ---------------------------------------------------------------------------
subtest 'requires_iaas and requires_scale' => sub {
	my $kit = kit(test => '0.0.1');

	my $iaas = $kit->requires_iaas(undef);
	ok !defined($iaas),
		"requires_iaas() returns undef when not declared in kit.yml";

	my $scale = $kit->requires_scale(undef);
	ok !defined($scale),
		"requires_scale() returns undef when not declared in kit.yml";
};

# ---------------------------------------------------------------------------
# Subtest 18: dereferenced_metadata
# ---------------------------------------------------------------------------
subtest 'dereferenced_metadata' => sub {
	my $kit = kit(test => '0.0.1');

	# Simple kit.yml has no ${key} references, so dereferenced == metadata
	my $lookup = sub { return undef };
	my $deref = $kit->dereferenced_metadata($lookup);
	ok defined($deref), "dereferenced_metadata() returns a defined value";
	is ref($deref), 'HASH', "dereferenced_metadata() returns a hashref";
	is $deref->{name}, 'simple',
		"dereferenced_metadata() preserves the kit name";

	# Memoized: second call returns same reference
	my $deref2 = $kit->dereferenced_metadata($lookup);
	is $deref2, $deref,
		"dereferenced_metadata() is memoized (same ref on second call)";
};

# ---------------------------------------------------------------------------
# Subtest 19: apply_env_overrides and env_override_files
# ---------------------------------------------------------------------------
subtest 'apply_env_overrides and env_override_files' => sub {
	my $kit = kit(test => '0.0.1');

	# Before any overrides are registered
	my @files = $kit->env_override_files();
	cmp_deeply(\@files, [],
		"env_override_files() returns empty list when no overrides registered");

	# Prime the metadata cache so we can verify it gets cleared
	$kit->metadata;
	ok defined($kit->{__metadata}),
		"metadata cache is populated after calling metadata()";

	# Register overrides — uses real kit path so metadata() can re-read safely
	my $override = $kit->path('kit.yml');  # a file that exists
	$kit->apply_env_overrides($override);
	my @registered = $kit->env_override_files();
	cmp_deeply(\@registered, [$override],
		"env_override_files() returns the files passed to apply_env_overrides()");

	# apply_env_overrides clears the cached metadata
	ok !defined($kit->{__metadata}),
		"apply_env_overrides() clears the cached metadata";
};

# ---------------------------------------------------------------------------
# Subtest 19: extract produces expected directory structure
# ---------------------------------------------------------------------------
subtest 'extract' => sub {
	my $kit = kit(test => '0.0.1');

	# Force extraction by calling path()
	my $root = $kit->path();
	ok defined($root) && -d $root,
		"extract() sets a root directory that exists on disk";

	# kit.yml must be present at root
	ok -f "$root/kit.yml",
		"extract() places kit.yml at the root of the workspace";

	# hooks/ directory
	ok -d "$root/hooks",
		"extract() creates the hooks/ directory";

	# Specific hook files from simple kit fixture
	ok -f "$root/hooks/blueprint",
		"extract() places hooks/blueprint in the workspace";
	ok -f "$root/hooks/new",
		"extract() places hooks/new in the workspace";

	# .helper file written by Compiled->extract
	ok -f "$root/.helper",
		"extract() writes the .helper sourcing file";

	# Calling path() again does not re-extract (memoized root stays the same)
	my $root2 = $kit->path();
	is $root, $root2, "extract() is idempotent; path() returns the same root";
};

done_testing;
