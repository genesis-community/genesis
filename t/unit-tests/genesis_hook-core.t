#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 't';
use helper;
use Test::More;
use Test::Exception;
use Test::Deep;
use Carp qw/croak/;
use Genesis qw(logger struct_lookup bail);
use Cwd qw(abs_path);
use JSON::PP;
use Digest::SHA qw(sha1_hex);

$ENV{GENESIS_CALLBACK_BIN} ||= abs_path('bin/genesis');
$ENV{GENESIS_LIB} ||= abs_path('lib');
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# ---------------------------------------------------------------------------
# Load the module under test
# ---------------------------------------------------------------------------
require_ok 'Genesis::Hook';

# ---------------------------------------------------------------------------
# Test subclass - Genesis::Hook requires the class name to match
# Genesis::Hook::<Type>::<KitName> so that label() can parse it.
# We define a minimal subclass here for use throughout the test file.
# ---------------------------------------------------------------------------
{
	package Genesis::Hook::Blueprint::test_kit;
	use parent -norequire, 'Genesis::Hook';

	# Minimal perform so the base-class abstract test can call the SUPER
	# version explicitly, while subtest 'perform - base class' bypasses this.
	sub perform {
		my ($self) = @_;
		$self->done('test-result');
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

# Convenience: instantiate our test subclass
sub make_hook {
	my $env = shift || mock_env();
	return Genesis::Hook::Blueprint::test_kit->init(env => $env, @_);
}

# ---------------------------------------------------------------------------
# Globals set before all subtests
# ---------------------------------------------------------------------------
$Genesis::VERSION = '3.1.0-rc.10';
$ENV{GENESIS_CALL_BIN} = 'genesis';
$ENV{GENESIS_KIT_HOOK} = 'blueprint';

# ---------------------------------------------------------------------------
# Genesis::Hook must be loaded
# ---------------------------------------------------------------------------
subtest 'Genesis::Hook module loads' => sub {
	plan tests => 1;
	ok(defined(&Genesis::Hook::init), 'Genesis::Hook::init is defined');
};

# ---------------------------------------------------------------------------
# init
# ---------------------------------------------------------------------------
subtest 'init - missing env dies' => sub {
	plan tests => 1;

	throws_ok {
		Genesis::Hook::Blueprint::test_kit->init()
	} qr/Missing required arguments for a perl-based kit hook call: env/,
		'init() without env argument dies with required-args message';
};

subtest 'init - returns blessed object with env set' => sub {
	plan tests => 5;

	my $env  = mock_env();
	my $hook;
	lives_ok {
		$hook = Genesis::Hook::Blueprint::test_kit->init(env => $env)
	} 'init() succeeds with valid env';

	ok(defined $hook, 'init() returns a defined value');
	isa_ok($hook, 'Genesis::Hook', 'returned object isa Genesis::Hook');
	is($hook->env, $env,                    'env() returns the env passed to init()');
	is($hook->{type}, $ENV{GENESIS_KIT_HOOK},
		'type is set from GENESIS_KIT_HOOK env var');
};

subtest 'init - complete flag starts at 0' => sub {
	plan tests => 1;

	my $hook = make_hook();
	is($hook->{complete}, 0, 'complete flag initializes to 0');
};

subtest 'init - stores extra opts on object' => sub {
	plan tests => 2;

	my $env  = mock_env();
	my $hook = Genesis::Hook::Blueprint::test_kit->init(
		env     => $env,
		purpose => 'extra',
		count   => 42,
	);
	is($hook->{purpose}, 'extra', 'extra opt "purpose" stored on hook');
	is($hook->{count},   42,      'extra opt "count" stored on hook');
};

subtest 'init - type read from GENESIS_KIT_HOOK at construction time' => sub {
	plan tests => 1;

	local $ENV{GENESIS_KIT_HOOK} = 'rotate';
	my $hook = make_hook();
	is($hook->{type}, 'rotate', 'type reflects GENESIS_KIT_HOOK at init() call time');
};

# ---------------------------------------------------------------------------
# perform (abstract)
# ---------------------------------------------------------------------------
subtest 'perform - base class implementation calls kit_bug and dies' => sub {
	plan tests => 1;

	my $env  = mock_env();
	# Bless a raw hook directly as base Genesis::Hook so label is bypassed by
	# pre-populating {label}; then call the base perform via package-qualified call.
	my $hook = bless(
		{ env => $env, complete => 0, type => 'blueprint', label => '[test] ' },
		'Genesis::Hook'
	);

	throws_ok {
		Genesis::Hook::perform($hook)
	} qr/Throwing a kit bug:[\s\S]*perform/i,
		'Genesis::Hook::perform() calls kit_bug and dies';
};

# ---------------------------------------------------------------------------
# done / completed / results
# ---------------------------------------------------------------------------
subtest 'done - no args marks complete with result 1' => sub {
	plan tests => 3;

	my $hook = make_hook();
	my $ret  = $hook->done();

	is($ret,              1, 'done() with no args returns 1');
	is($hook->{complete}, 1, 'complete flag set to 1');
	is($hook->{results},  1, 'results stored as 1');
};

subtest 'done - with defined value stores value and marks complete' => sub {
	plan tests => 3;

	my $hook = make_hook();
	my $yaml = "name: foo\n";
	my $ret  = $hook->done($yaml);

	is($ret,              $yaml, 'done($value) returns the value');
	is($hook->{complete}, 1,     'complete flag set to 1');
	is($hook->{results},  $yaml, 'results stored as supplied value');
};

subtest 'done - undef argument marks NOT complete' => sub {
	plan tests => 3;

	my $hook = make_hook();
	my $ret  = $hook->done(undef);

	ok(!defined($ret),             'done(undef) returns undef');
	is($hook->{complete},  0,      'complete flag set to 0 when undef passed');
	ok(!defined($hook->{results}), 'results is undef when done(undef)');
};

subtest 'done - returns value that was passed in' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $ret  = $hook->done('my-yaml-output');
	is($ret, 'my-yaml-output', 'done($val) return value matches argument');
};

subtest 'completed - reflects complete flag' => sub {
	plan tests => 2;

	my $hook = make_hook();
	is($hook->completed, 0, 'completed() returns 0 before done()');
	$hook->done('something');
	is($hook->completed, 1, 'completed() returns 1 after done($value)');
};

subtest 'results - returns undef when not complete, value when complete' => sub {
	plan tests => 2;

	my $hook = make_hook();
	ok(!defined($hook->results), 'results() returns undef when not complete');

	$hook->done('my-result');
	is($hook->results, 'my-result', 'results() returns stored value after done()');
};

subtest 'results - returns undef when done(undef) called' => sub {
	plan tests => 2;

	my $hook = make_hook();
	$hook->done(undef);

	is($hook->completed, 0, 'completed() is 0 after done(undef)');
	ok(!defined($hook->results), 'results() returns undef after done(undef)');
};

# ---------------------------------------------------------------------------
# check_minimum_genesis_version
# ---------------------------------------------------------------------------
subtest 'check_minimum_genesis_version - passes when version meets requirement' => sub {
	plan tests => 2;

	my $hook = make_hook();

	lives_ok {
		$hook->check_minimum_genesis_version('3.0.0')
	} 'does not die when running version exceeds minimum';

	lives_ok {
		$hook->check_minimum_genesis_version('3.1.0-rc.10')
	} 'does not die when running version exactly equals minimum';
};

subtest 'check_minimum_genesis_version - passes for older minimum' => sub {
	plan tests => 1;

	my $hook = make_hook();
	lives_ok {
		$hook->check_minimum_genesis_version('2.0.0')
	} 'does not die when minimum is much older than current';
};

subtest 'check_minimum_genesis_version - dies when version too old' => sub {
	plan tests => 1;

	my $hook = make_hook();
	throws_ok {
		$hook->check_minimum_genesis_version('99.0.0')
	} qr/requires Genesis v99\.0\.0 or higher/,
		'dies with upgrade message when running version is too old';
};

subtest 'check_minimum_genesis_version - dies on invalid minimum version string' => sub {
	plan tests => 1;

	my $hook = make_hook();
	throws_ok {
		$hook->check_minimum_genesis_version('not-a-version')
	} qr/requires Genesis v/,
		'dies when minimum version is not a valid semver string';
};

# ---------------------------------------------------------------------------
# env / deployed / use_create_env
# ---------------------------------------------------------------------------
subtest 'env - returns env object passed to init()' => sub {
	plan tests => 1;

	my $env  = mock_env();
	my $hook = make_hook($env);
	is($hook->env, $env, 'env() returns the stored env object');
};

subtest 'deployed - returns 1 when deployment state is "deployed"' => sub {
	plan tests => 1;

	# mock_env defaults to current_state => 'deployed'
	my $hook = make_hook();
	is($hook->deployed, 1, 'deployed() returns 1 when current_state is "deployed"');
};

subtest 'deployed - returns 0 when deployment state is not "deployed"' => sub {
	plan tests => 1;

	my $seq = $test_seq + 1;
	my $env = mock_env(
		deployments => mock("Genesis::Env::Deployments::nd$seq" => {
			current_state => 'undeployed',
		})
	);
	my $hook = make_hook($env);
	is($hook->deployed, 0, 'deployed() returns 0 when current_state is not "deployed"');
};

subtest 'use_create_env - returns env->use_create_env' => sub {
	plan tests => 2;

	my $env0 = mock_env(use_create_env => 0);
	is(make_hook($env0)->use_create_env, 0,
		'use_create_env() returns 0 when env returns 0');

	my $env1 = mock_env(use_create_env => 1);
	is(make_hook($env1)->use_create_env, 1,
		'use_create_env() returns 1 when env returns 1');
};

# ---------------------------------------------------------------------------
# features / set_features / want_feature / wants_feature
# ---------------------------------------------------------------------------
subtest 'features - returns feature list from env' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my @got  = $hook->features();
	cmp_deeply(\@got, ['ha', 'tls'], 'features() returns list from env');
};

subtest 'features - caches result after first call' => sub {
	plan tests => 2;

	my $env  = mock_env();
	my $hook = make_hook($env);

	# First call populates cache
	my @first = $hook->features();
	is(scalar @first, 2, 'initial feature list has 2 entries');

	# Change what env->features returns for subsequent calls
	$env->_mock_set_responses(
		'features' => Mock::ReferencedValue->new(['other'])
	);
	my @second = $hook->features();
	cmp_deeply(\@second, ['ha', 'tls'],
		'features() returns cached list, ignoring updated env response');
};

subtest 'set_features - replaces cached list' => sub {
	plan tests => 1;

	my $hook = make_hook();
	$hook->set_features('proto', 'db');

	my @got = $hook->features();
	cmp_deeply(\@got, ['proto', 'db'],
		'set_features() replaces the cached feature list');
};

subtest 'set_features - clears __wanted_features lookup cache' => sub {
	plan tests => 2;

	my $hook = make_hook();
	# Prime the wanted-features cache
	$hook->want_feature('ha');
	ok(defined $hook->{__wanted_features}, '__wanted_features populated after want_feature');

	$hook->set_features('proto', 'db');
	ok(!defined($hook->{__wanted_features}),
		'set_features() clears the __wanted_features cache');
};

subtest 'want_feature - exact string: present feature returns true' => sub {
	plan tests => 1;
	ok(make_hook()->want_feature('ha'),
		'want_feature("ha") returns true for present feature');
};

subtest 'want_feature - exact string: absent feature returns false' => sub {
	plan tests => 1;
	ok(!make_hook()->want_feature('missing-feature'),
		'want_feature("missing-feature") returns false for absent feature');
};

subtest 'want_feature - regex: returns 1 when a feature name matches' => sub {
	plan tests => 1;
	is(make_hook()->want_feature(qr/^t/), 1,
		'want_feature(qr/^t/) returns 1 when feature "tls" matches');
};

subtest 'want_feature - regex: returns 0 when no feature matches' => sub {
	plan tests => 1;
	is(make_hook()->want_feature(qr/^xyz/), 0,
		'want_feature(qr/^xyz/) returns 0 when no feature matches regex');
};

subtest 'want_feature - regex matches partial name' => sub {
	plan tests => 1;
	is(make_hook()->want_feature(qr/ls$/), 1,
		'want_feature(qr/ls$/) returns 1 matching end of "tls"');
};

subtest 'wants_feature - alias for want_feature' => sub {
	plan tests => 2;

	my $hook = make_hook();
	ok($hook->wants_feature('ha'),
		'wants_feature("ha") returns true (alias works)');
	ok(!$hook->wants_feature('absent'),
		'wants_feature("absent") returns false (alias works)');
};

# ---------------------------------------------------------------------------
# iaas / scale / is_ocfp / cpi_name / cpi_enabled
# ---------------------------------------------------------------------------
subtest 'iaas - delegates to env->iaas' => sub {
	plan tests => 1;
	is(make_hook()->iaas, 'aws', 'iaas() returns env->iaas');
};

subtest 'scale - delegates to env->scale' => sub {
	plan tests => 1;
	is(make_hook()->scale, 'dev', 'scale() returns env->scale');
};

subtest 'is_ocfp - delegates to env->is_ocfp' => sub {
	plan tests => 1;
	is(make_hook()->is_ocfp, 0, 'is_ocfp() returns env->is_ocfp');
};

subtest 'cpi_name - delegates to env->cpi_name' => sub {
	plan tests => 1;
	is(make_hook()->cpi_name, 'aws_cpi', 'cpi_name() returns env->cpi_name');
};

subtest 'cpi_enabled - delegates to env->cpi_enabled' => sub {
	plan tests => 1;
	is(make_hook()->cpi_enabled, 1, 'cpi_enabled() returns env->cpi_enabled');
};

# ---------------------------------------------------------------------------
# kit / kit_bug / kit_has_file / supports_iaas
# ---------------------------------------------------------------------------
subtest 'kit - returns kit object from env' => sub {
	plan tests => 1;
	is(make_hook()->kit, $kit, 'kit() returns env->kit');
};

subtest 'kit_bug - delegates to kit->kit_bug and terminates' => sub {
	plan tests => 1;

	my $hook = make_hook();
	throws_ok {
		$hook->kit_bug("Something went wrong: %s", "bad value")
	} qr/Throwing a kit bug: Something went wrong: bad value/,
		'kit_bug() delegates to kit->kit_bug and terminates with bail()';
};

subtest 'kit_has_file - returns false for nonexistent file' => sub {
	plan tests => 1;

	my $hook = make_hook();
	# kit->path returns /mock/kit/path/<file> which does not exist on disk
	ok(!$hook->kit_has_file('hooks/nonexistent.pm'),
		'kit_has_file() returns false when file does not exist');
};

subtest 'kit_has_file - returns true for existing file' => sub {
	plan tests => 1;

	my $tmpdir  = workdir('kit-has-file-test');
	my $tmpfile = "$tmpdir/real-hook.pm";
	put_file($tmpfile, "# placeholder\n");

	# Use a local kit so we do not mutate the shared $kit mock
	my $local_kit = mock "Genesis::Kit::LocalForFileTest" => {
		name     => 'test-kit',
		version  => '1.0.0',
		id       => sub { return $_[0]->name . '/' . $_[0]->version },
		kit_bug  => sub {
			my ($self, $msg, @args) = @_;
			bail("Throwing a kit bug: ".$msg, @args);
		},
		path     => sub { return $tmpfile },
		metadata => { supports => ['aws', 'vsphere', 'openstack'] },
		get_hook_module => sub { return undef },
	};
	my $env  = mock_env(kit => $local_kit);
	my $hook = make_hook($env);

	ok($hook->kit_has_file('real-hook.pm'),
		'kit_has_file() returns true for a file that exists on disk');
};

subtest 'supports_iaas - returns true when iaas is in kit supports list' => sub {
	plan tests => 1;

	# mock_env has iaas => 'aws'; kit metadata supports includes 'aws'
	ok(make_hook()->supports_iaas,
		'supports_iaas() returns true when IaaS is in kit supports list');
};

subtest 'supports_iaas - returns false when iaas not in kit supports list' => sub {
	plan tests => 1;

	my $env  = mock_env(iaas => 'gcp');
	ok(!make_hook($env)->supports_iaas,
		'supports_iaas() returns false when IaaS is not in kit supports list');
};

# ---------------------------------------------------------------------------
# relative_env_path
# ---------------------------------------------------------------------------
subtest 'relative_env_path - returns a string path' => sub {
	plan tests => 1;

	local $ENV{GENESIS_ORIGINATING_DIR} = workdir();
	my $hook = make_hook();

	my $path;
	lives_ok { $path = $hook->relative_env_path() }
		'relative_env_path() lives without error';
};

# ---------------------------------------------------------------------------
# titleize
# NOTE: The POD documents titleize as applying title-case to each word.
# The current implementation uses double-escaped regex substitution
# (s/([\\w']+)/\\u\\L\$1/gr) which, due to the escaped \$1, does not
# interpolate the capture group. The character class [\\w']+ matches
# only literal backslash, 'w', or apostrophe characters rather than \w
# word chars. As a result the function does not produce title-case output.
# These tests document the intended (POD-specified) behaviour. The
# implementation must be fixed to make them pass.
# ---------------------------------------------------------------------------
subtest 'titleize - capitalizes first letter, lowercases rest in each word' => sub {
	plan tests => 1;

	TODO: {
		local $TODO = 'titleize() has a double-escaped substitution bug (HK-TODO)';
		my @result = Genesis::Hook::titleize('hello world');
		cmp_deeply(\@result, ['Hello World'],
			'titleize("hello world") returns ("Hello World")');
	}
};

subtest 'titleize - handles multiple string arguments' => sub {
	plan tests => 1;

	TODO: {
		local $TODO = 'titleize() has a double-escaped substitution bug (HK-TODO)';
		my @result = Genesis::Hook::titleize('foo bar', 'baz qux');
		cmp_deeply(\@result, ['Foo Bar', 'Baz Qux'],
			'titleize with two strings applies title case to each');
	}
};

subtest 'titleize - lowercases non-initial letters' => sub {
	plan tests => 1;

	TODO: {
		local $TODO = 'titleize() has a double-escaped substitution bug (HK-TODO)';
		my @result = Genesis::Hook::titleize('HELLO WORLD');
		cmp_deeply(\@result, ['Hello World'],
			'titleize("HELLO WORLD") lowercases non-initial letters');
	}
};

subtest 'titleize - single word' => sub {
	plan tests => 1;

	TODO: {
		local $TODO = 'titleize() has a double-escaped substitution bug (HK-TODO)';
		my @result = Genesis::Hook::titleize('genesis');
		cmp_deeply(\@result, ['Genesis'],
			'titleize("genesis") capitalizes single word');
	}
};

# ---------------------------------------------------------------------------
# TRUE / FALSE / NULL
# ---------------------------------------------------------------------------
subtest 'TRUE - returns JSON::PP boolean true' => sub {
	plan tests => 2;

	my $t = Genesis::Hook::TRUE();
	ok(JSON::PP::is_bool($t), 'TRUE() returns a JSON boolean value');
	ok($t,                    'TRUE() is truthy');
};

subtest 'FALSE - returns JSON::PP boolean false' => sub {
	plan tests => 2;

	my $f = Genesis::Hook::FALSE();
	ok(JSON::PP::is_bool($f), 'FALSE() returns a JSON boolean value');
	ok(!$f,                   'FALSE() is falsy');
};

subtest 'NULL - returns JSON null singleton' => sub {
	plan tests => 1;

	my $n = Genesis::Hook::NULL();
	is($n, JSON::PP::null, 'NULL() returns the JSON::PP::null singleton');
};

# ---------------------------------------------------------------------------
# check_for_required_args
# ---------------------------------------------------------------------------
subtest 'check_for_required_args - returns 1 when all required keys present' => sub {
	plan tests => 2;

	my $opts = { env => 'something', name => 'foo' };
	my $ret;
	lives_ok {
		$ret = Genesis::Hook->check_for_required_args($opts, qw/env name/)
	} 'check_for_required_args() lives when all required keys are present';
	is($ret, 1, 'check_for_required_args() returns 1 on success');
};

subtest 'check_for_required_args - dies listing all missing keys' => sub {
	plan tests => 1;

	my $opts = { env => 'something' };
	throws_ok {
		Genesis::Hook->check_for_required_args($opts, qw/env name type/)
	} qr/Missing required arguments for a perl-based kit hook call: /,
		'check_for_required_args() dies listing missing keys';
};

subtest 'check_for_required_args - dies when the only required key is absent' => sub {
	plan tests => 1;

	throws_ok {
		Genesis::Hook->check_for_required_args({}, qw/env/)
	} qr/Missing required arguments for a perl-based kit hook call: env/,
		'check_for_required_args() dies when required key is absent';
};

# ---------------------------------------------------------------------------
# spruce_merge - argument validation
# ---------------------------------------------------------------------------
subtest 'spruce_merge - dies on unrecognized string argument' => sub {
	plan tests => 1;

	my $hook = make_hook();
	# 'not-a-real-file' is not a flag, not a hash, not an existing file, and
	# kit->path() returns /mock/kit/path/not-a-real-file which also does not exist
	throws_ok {
		$hook->spruce_merge('not-a-real-file')
	} qr/Invalid argument for spruce merge: not-a-real-file/,
		'spruce_merge() dies when argument is not a file, hash, or flag';
};

# ---------------------------------------------------------------------------
# exodus_data
# ---------------------------------------------------------------------------
subtest 'exodus_data - no args returns full hash ref' => sub {
	plan tests => 2;

	my $hook = make_hook();
	my $data = $hook->exodus_data();

	ok(ref($data) eq 'HASH',
		'exodus_data() with no args returns a HASH ref');
	is($data->{director_url}, 'https://bosh.example.com',
		'exodus_data() full hash contains expected director_url key');
};

subtest 'exodus_data - single key returns scalar value' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $url  = $hook->exodus_data('director_url');
	is($url, 'https://bosh.example.com',
		'exodus_data("director_url") returns scalar value for the key');
};

subtest 'exodus_data - multiple keys in list context returns list of values' => sub {
	plan tests => 2;

	my $hook          = make_hook();
	my ($url, $user)  = $hook->exodus_data('director_url', 'admin_user');

	is($url,  'https://bosh.example.com', 'first key value is correct');
	is($user, 'admin',                    'second key value is correct');
};

subtest 'exodus_data - multiple keys in scalar context returns arrayref' => sub {
	plan tests => 2;

	my $hook = make_hook();
	my $aref = $hook->exodus_data('director_url', 'admin_user');

	ok(ref($aref) eq 'ARRAY',
		'scalar context with multiple keys returns ARRAY ref');
	is($aref->[0], 'https://bosh.example.com',
		'arrayref first element is the first key value');
};

subtest 'exodus_data - caches result after first call' => sub {
	plan tests => 2;

	my $env  = mock_env();
	my $hook = make_hook($env);

	# Populate cache
	my $first = $hook->exodus_data();
	ok(defined $hook->{__exodus_data},
		'__exodus_data cache is populated after first call');

	# Change what env->exodus_lookup returns
	$env->_mock_set_responses(
		exodus_lookup => sub { return { director_url => 'https://changed.example.com' } }
	);

	my $second = $hook->exodus_data();
	is($second->{director_url}, 'https://bosh.example.com',
		'exodus_data() returns cached value on second call despite changed env response');
};

# ---------------------------------------------------------------------------
# get_credhub_variable
# ---------------------------------------------------------------------------
subtest 'get_credhub_variable - returns deterministic credential name' => sub {
	plan tests => 1;

	my $hook         = make_hook();
	my $prefix       = '/bosh/';
	my $path         = 'certs';
	my $key          = 'ca';
	my $value        = 'pem-data-here';
	my $expected_sha = substr(sha1_hex("$path--$key--$value"), 0, 8);
	my $expected     = "${prefix}${path}--${key}--${expected_sha}";

	my $result = $hook->get_credhub_variable($prefix, $path, $key, $value);
	is($result, $expected,
		'get_credhub_variable() returns the expected deterministic credential name');
};

subtest 'get_credhub_variable - is deterministic for identical inputs' => sub {
	plan tests => 1;

	my $hook    = make_hook();
	my $result1 = $hook->get_credhub_variable('/p/', 'mypath', 'mykey', 'myval');
	my $result2 = $hook->get_credhub_variable('/p/', 'mypath', 'mykey', 'myval');
	is($result1, $result2,
		'get_credhub_variable() produces the same name for identical inputs');
};

subtest 'get_credhub_variable - different value produces different name' => sub {
	plan tests => 1;

	my $hook    = make_hook();
	my $result1 = $hook->get_credhub_variable('/p/', 'mypath', 'mykey', 'value-A');
	my $result2 = $hook->get_credhub_variable('/p/', 'mypath', 'mykey', 'value-B');
	isnt($result1, $result2,
		'get_credhub_variable() produces different names when value differs');
};

subtest 'get_credhub_variable - sha1 prefix is exactly 8 hex characters' => sub {
	plan tests => 1;

	my $hook   = make_hook();
	my $result = $hook->get_credhub_variable('/prefix/', 'mypath', 'mykey', 'myval');
	like($result, qr/--[0-9a-f]{8}$/,
		'credential name ends with exactly 8 lowercase hex sha1 characters');
};

subtest 'get_credhub_variable - name format is prefix+path--key--sha' => sub {
	plan tests => 1;

	my $hook   = make_hook();
	my $result = $hook->get_credhub_variable('/bosh/', 'certs', 'ca', 'val');
	like($result, qr{^/bosh/certs--ca--[0-9a-f]{8}$},
		'credential name matches expected format: prefix+path--key--sha8');
};

# ---------------------------------------------------------------------------
# tempfile / tempdir
# ---------------------------------------------------------------------------
subtest 'tempfile - with explicit name returns workpath for that name' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $path = $hook->tempfile('manifest.yml');
	is($path, '/tmp/genesis-test-work/manifest.yml',
		'tempfile("manifest.yml") returns env->workpath("manifest.yml")');
};

subtest 'tempfile - without name generates auto-named path under workpath' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $path = $hook->tempfile();
	like($path, qr{/tmp/genesis-test-work/tempfile-\d+-\d+$},
		'tempfile() with no name generates a timestamped path');
};

subtest 'tempdir - with explicit name returns correct path' => sub {
	plan tests => 1;

	my $tmpbase = workdir('tempdir-test-named');
	my $env     = mock_env(
		workpath => sub {
			my ($self, $path) = @_;
			return "$tmpbase/$path";
		}
	);
	my $hook = make_hook($env);
	my $dir  = $hook->tempdir('staging');
	is($dir, "$tmpbase/staging", 'tempdir("staging") returns expected path');
};

subtest 'tempdir - without name generates auto-named path' => sub {
	plan tests => 1;

	my $tmpbase = workdir('tempdir-test-auto');
	my $env     = mock_env(
		workpath => sub {
			my ($self, $path) = @_;
			return "$tmpbase/$path";
		}
	);
	my $hook = make_hook($env);
	my $dir  = $hook->tempdir();
	like($dir, qr{tempdir-\d+-\d+$},
		'tempdir() with no name generates a timestamped path');
};

subtest 'tempdir - creates directory on disk' => sub {
	plan tests => 1;

	my $tmpbase = workdir('tempdir-test-create');
	my $env     = mock_env(
		workpath => sub {
			my ($self, $path) = @_;
			return "$tmpbase/$path";
		}
	);
	my $hook = make_hook($env);
	my $dir  = $hook->tempdir('mydir');
	ok(-d $dir, 'tempdir() creates the directory on disk');
};

subtest 'tempdir - returns existing path if directory already present' => sub {
	plan tests => 2;

	my $tmpbase = workdir('tempdir-test-exists');
	my $env     = mock_env(
		workpath => sub {
			my ($self, $path) = @_;
			return "$tmpbase/$path";
		}
	);
	my $hook = make_hook($env);

	my $dir1 = $hook->tempdir('existing');
	my $dir2 = $hook->tempdir('existing');
	ok(-d $dir1, 'directory created by first call');
	is($dir1, $dir2, 'second call returns same path without error');
};

# ---------------------------------------------------------------------------
# load_hook_module
# ---------------------------------------------------------------------------
subtest 'load_hook_module - dies when kit returns no module name' => sub {
	plan tests => 1;

	# kit->get_hook_module returns undef (as set in shared $kit definition).
	# bail() wraps output at 80 columns so the error may span multiple lines;
	# match the two key fragments independently using [\s\S]* to cross lines.
	throws_ok {
		Genesis::Hook->load_hook_module('hooks/blueprint.pm', $kit)
	} qr/does not exist for kit[\s\S]*test-kit\/1\.0\.0/,
		'load_hook_module() dies when kit->get_hook_module returns undef';
};

# ---------------------------------------------------------------------------
# bosh
# ---------------------------------------------------------------------------
subtest 'bosh - returns connected bosh client' => sub {
	plan tests => 2;

	my $hook = make_hook();
	my $got;
	lives_ok { $got = $hook->bosh() } 'bosh() lives without error';
	is($got, $bosh, 'bosh() returns the bosh object from env->bosh');
};

subtest 'bosh - caches the result' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $got1 = $hook->bosh();
	my $got2 = $hook->bosh();
	is($got1, $got2, 'bosh() returns the same cached object on second call');
};

# ---------------------------------------------------------------------------
# get_config_override
# ---------------------------------------------------------------------------
subtest 'get_config_override - CloudConfig subclass resolves under bosh-configs.cloud' => sub {
	plan tests => 1;

	my $env = mock_env(
		lookup => sub {
			my ($self, $key, $default) = @_;
			return 'found-value' if $key eq 'bosh-configs.cloud.networks';
			return $default;
		}
	);

	require Genesis::Hook::CloudConfig;
	my $hook = bless(
		{ env => $env, complete => 0, type => 'cloud-config', label => '[test] ' },
		'Genesis::Hook::CloudConfig'
	);

	my $val = $hook->get_config_override('networks', 'default-val');
	is($val, 'found-value',
		'CloudConfig hook resolves key under bosh-configs.cloud.*');
};

subtest 'get_config_override - RuntimeConfig subclass resolves under bosh-configs.runtime' => sub {
	plan tests => 1;

	my $env = mock_env(
		lookup => sub {
			my ($self, $key, $default) = @_;
			return 'runtime-found' if $key eq 'bosh-configs.runtime.addons';
			return $default;
		}
	);

	require Genesis::Hook::RuntimeConfig;
	my $hook = bless(
		{ env => $env, complete => 0, type => 'runtime-config', label => '[test] ' },
		'Genesis::Hook::RuntimeConfig'
	);

	my $val = $hook->get_config_override('addons', []);
	is($val, 'runtime-found',
		'RuntimeConfig hook resolves key under bosh-configs.runtime.*');
};

subtest 'get_config_override - falls back to default when key is absent' => sub {
	plan tests => 1;

	my $env = mock_env();  # lookup always returns $default

	require Genesis::Hook::CloudConfig;
	my $hook = bless(
		{ env => $env, complete => 0, type => 'cloud-config', label => '[test] ' },
		'Genesis::Hook::CloudConfig'
	);

	my $val = $hook->get_config_override('nonexistent', 'the-default');
	is($val, 'the-default',
		'get_config_override() returns default when key is not found');
};

subtest 'get_config_override - explicit type prefix bypasses class detection' => sub {
	plan tests => 1;

	my $env = mock_env(
		lookup => sub {
			my ($self, $key, $default) = @_;
			return 'runtime-value' if $key eq 'bosh-configs.runtime.addons';
			return $default;
		}
	);

	require Genesis::Hook::CloudConfig;
	my $hook = bless(
		{ env => $env, complete => 0, type => 'cloud-config', label => '[test] ' },
		'Genesis::Hook::CloudConfig'
	);

	my $val = $hook->get_config_override('runtime.addons', []);
	is($val, 'runtime-value',
		'explicit "runtime." prefix is used as-is regardless of hook class');
};

subtest 'get_config_override - dies for base Genesis::Hook without type prefix' => sub {
	plan tests => 1;

	my $hook = bless(
		{ env => mock_env(), complete => 0, type => 'blueprint', label => '[test] ' },
		'Genesis::Hook'
	);

	throws_ok {
		$hook->get_config_override('networks', [])
	} qr/hooks must specify the bosh_config type/,
		'get_config_override() dies when hook is base class and key has no type prefix';
};

done_testing;
# vim: fdm=marker:ts=2:sw=2:sts=2:noet:cc=80
