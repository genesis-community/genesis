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
require_ok 'Genesis::Hook::Features';

# ---------------------------------------------------------------------------
# Test subclass — Genesis::Hook requires the class name to follow the pattern
# Genesis::Hook::<Type>::<KitName> so that label() can parse it correctly.
# ---------------------------------------------------------------------------
{
	package Genesis::Hook::Features::test_kit;
	use parent -norequire, 'Genesis::Hook::Features';

	sub perform {
		my ($self) = @_;
		$self->add_feature('ha');
		$self->add_feature('mtls');
		$self->done;
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

# Convenience: instantiate our Features test subclass
sub make_hook {
	my $env = shift || mock_env();
	return Genesis::Hook::Features::test_kit->init(
		env      => $env,
		kit      => $kit,
		features => ['ha', 'tls'],
		@_,
	);
}

# ---------------------------------------------------------------------------
# Globals set before all subtests
# ---------------------------------------------------------------------------
$Genesis::VERSION = '3.1.0-rc.10';
$ENV{GENESIS_CALL_BIN} = 'genesis';
$ENV{GENESIS_KIT_HOOK} = 'features';

# ---------------------------------------------------------------------------
# Module loads
# ---------------------------------------------------------------------------
subtest 'Genesis::Hook::Features module loads' => sub {
	plan tests => 1;
	ok(defined(&Genesis::Hook::Features::init),
		'Genesis::Hook::Features::init is defined');
};

# ---------------------------------------------------------------------------
# init
# ---------------------------------------------------------------------------
subtest 'init - missing env dies' => sub {
	plan tests => 1;

	throws_ok {
		Genesis::Hook::Features::test_kit->init(
			kit      => $kit,
			features => [],
		)
	} qr/Missing required arguments for a perl-based kit hook call: env/,
		'init() without env dies with required-args message';
};

subtest 'init - missing kit dies' => sub {
	plan tests => 1;

	my $env = mock_env();
	throws_ok {
		Genesis::Hook::Features::test_kit->init(
			env      => $env,
			features => [],
		)
	} qr/Missing required arguments for a perl-based kit hook call: kit/,
		'init() without kit dies with required-args message';
};

subtest 'init - missing features dies' => sub {
	plan tests => 1;

	my $env = mock_env();
	throws_ok {
		Genesis::Hook::Features::test_kit->init(
			env => $env,
			kit => $kit,
		)
	} qr/Missing required arguments for a perl-based kit hook call: features/,
		'init() without features dies with required-args message';
};

subtest 'init - missing multiple required args lists all missing' => sub {
	plan tests => 1;

	throws_ok {
		Genesis::Hook::Features::test_kit->init()
	} qr/Missing required arguments for a perl-based kit hook call:/,
		'init() with no args dies listing missing arguments';
};

subtest 'init - returns blessed Genesis::Hook::Features object' => sub {
	plan tests => 4;

	my $env  = mock_env();
	my $hook;
	lives_ok {
		$hook = Genesis::Hook::Features::test_kit->init(
			env      => $env,
			kit      => $kit,
			features => ['ha', 'tls'],
		)
	} 'init() succeeds with all required arguments';

	ok(defined $hook, 'init() returns a defined value');
	isa_ok($hook, 'Genesis::Hook::Features',
		'returned object isa Genesis::Hook::Features');
	isa_ok($hook, 'Genesis::Hook',
		'returned object also isa Genesis::Hook');
};

subtest 'init - initialises all_features as empty array ref' => sub {
	plan tests => 2;

	my $hook = make_hook();
	ok(defined $hook->{all_features},
		'all_features key exists after init()');
	cmp_deeply($hook->{all_features}, [],
		'all_features initialised as empty array ref');
};

subtest 'init - initialises has_feature as empty hash ref' => sub {
	plan tests => 2;

	my $hook = make_hook();
	ok(defined $hook->{has_feature},
		'has_feature key exists after init()');
	cmp_deeply($hook->{has_feature}, {},
		'has_feature initialised as empty hash ref');
};

subtest 'init - stores env on object' => sub {
	plan tests => 1;

	my $env  = mock_env();
	my $hook = Genesis::Hook::Features::test_kit->init(
		env      => $env,
		kit      => $kit,
		features => [],
	);
	is($hook->env, $env, 'env() returns the env passed to init()');
};

subtest 'init - type set from GENESIS_KIT_HOOK env var' => sub {
	plan tests => 1;

	my $hook = make_hook();
	is($hook->{type}, 'features',
		'type is set from GENESIS_KIT_HOOK env var');
};

subtest 'init - complete flag starts at 0' => sub {
	plan tests => 1;

	my $hook = make_hook();
	is($hook->{complete}, 0, 'complete flag initializes to 0');
};

# ---------------------------------------------------------------------------
# add_feature
# ---------------------------------------------------------------------------
subtest 'add_feature - default value is 1 when set arg omitted' => sub {
	plan tests => 2;

	my $hook = make_hook();
	$hook->add_feature('ha');

	is($hook->{has_feature}{'ha'}, 1,
		'has_feature map records value 1 when $set omitted');
	cmp_deeply($hook->{all_features}, ['ha'],
		'feature appended to all_features list');
};

subtest 'add_feature - explicit truthy set value stored' => sub {
	plan tests => 2;

	my $hook = make_hook();
	$hook->add_feature('ha', 42);

	is($hook->{has_feature}{'ha'}, 42,
		'has_feature map records supplied truthy value');
	cmp_deeply($hook->{all_features}, ['ha'],
		'feature appended to all_features list');
};

subtest 'add_feature - explicit falsy set value 0 stored' => sub {
	plan tests => 2;

	my $hook = make_hook();
	$hook->add_feature('debug', 0);

	is($hook->{has_feature}{'debug'}, 0,
		'has_feature map records supplied falsy value 0');
	cmp_deeply($hook->{all_features}, ['debug'],
		'feature appended to all_features list even with falsy value');
};

subtest 'add_feature - preserves insertion order across multiple calls' => sub {
	plan tests => 1;

	my $hook = make_hook();
	$hook->add_feature('ha');
	$hook->add_feature('mtls');
	$hook->add_feature('debug');

	cmp_deeply($hook->{all_features}, ['ha', 'mtls', 'debug'],
		'all_features preserves insertion order');
};

subtest 'add_feature - returns nothing significant' => sub {
	plan tests => 1;

	my $hook = make_hook();
	# add_feature has no documented return value; we verify it does not die
	lives_ok { $hook->add_feature('ha') } 'add_feature() lives without error';
};

# ---------------------------------------------------------------------------
# has_feature
# ---------------------------------------------------------------------------
subtest 'has_feature - returns 1 for feature added with default value' => sub {
	plan tests => 1;

	my $hook = make_hook();
	$hook->add_feature('ha');
	is($hook->has_feature('ha'), 1,
		'has_feature() returns 1 for feature added with default value');
};

subtest 'has_feature - returns stored value for feature added with explicit value' => sub {
	plan tests => 1;

	my $hook = make_hook();
	$hook->add_feature('ha', 42);
	is($hook->has_feature('ha'), 42,
		'has_feature() returns the value supplied to add_feature()');
};

subtest 'has_feature - returns undef for unregistered feature' => sub {
	plan tests => 1;

	my $hook = make_hook();
	ok(!defined($hook->has_feature('nonexistent')),
		'has_feature() returns undef for a feature that was never added');
};

subtest 'has_feature - returns 0 for feature registered with value 0' => sub {
	plan tests => 1;

	my $hook = make_hook();
	$hook->add_feature('debug', 0);
	is($hook->has_feature('debug'), 0,
		'has_feature() returns 0 when feature was registered with value 0');
};

# ---------------------------------------------------------------------------
# delete_feature
# ---------------------------------------------------------------------------
subtest 'delete_feature - returns old value and removes from map' => sub {
	plan tests => 2;

	my $hook = make_hook();
	$hook->add_feature('ha');

	my $old = $hook->delete_feature('ha');

	is($old, 1, 'delete_feature() returns the previously stored value');
	ok(!defined($hook->has_feature('ha')),
		'has_feature() returns undef after delete_feature()');
};

subtest 'delete_feature - returns undef for feature not in map' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my $old  = $hook->delete_feature('nonexistent');

	ok(!defined($old),
		'delete_feature() returns undef when feature was not registered');
};

subtest 'delete_feature - feature stays in all_features list but skipped by build_features_list' => sub {
	plan tests => 2;

	my $hook = make_hook();
	$hook->add_feature('ha');
	$hook->add_feature('mtls');
	$hook->delete_feature('ha');

	cmp_deeply($hook->{all_features}, ['ha', 'mtls'],
		'all_features still contains deleted feature name');

	my @list = $hook->build_features_list();
	cmp_deeply(\@list, ['mtls'],
		'build_features_list() omits the deleted feature');
};

subtest 'delete_feature - returns stored value when explicit value was used' => sub {
	plan tests => 1;

	my $hook = make_hook();
	$hook->add_feature('ha', 99);
	my $old = $hook->delete_feature('ha');

	is($old, 99, 'delete_feature() returns the explicit value that was stored');
};

# ---------------------------------------------------------------------------
# build_features_list
# ---------------------------------------------------------------------------
subtest 'build_features_list - returns active features in insertion order' => sub {
	plan tests => 1;

	my $hook = make_hook();
	$hook->add_feature('ha');
	$hook->add_feature('mtls');
	$hook->add_feature('debug');

	my @list = $hook->build_features_list();
	cmp_deeply(\@list, ['ha', 'mtls', 'debug'],
		'build_features_list() returns features in insertion order');
};

subtest 'build_features_list - omits features with falsy value' => sub {
	plan tests => 1;

	my $hook = make_hook();
	$hook->add_feature('ha');
	$hook->add_feature('debug', 0);
	$hook->add_feature('mtls');

	my @list = $hook->build_features_list();
	cmp_deeply(\@list, ['ha', 'mtls'],
		'build_features_list() skips feature registered with value 0');
};

subtest 'build_features_list - second call returns empty list' => sub {
	plan tests => 2;

	my $hook = make_hook();
	$hook->add_feature('ha');
	$hook->add_feature('mtls');

	my @first  = $hook->build_features_list();
	my @second = $hook->build_features_list();

	cmp_deeply(\@first,  ['ha', 'mtls'],
		'first call returns expected features');
	cmp_deeply(\@second, [],
		'second call returns empty list because entries were deleted');
};

subtest 'build_features_list - deletes emitted features from map' => sub {
	plan tests => 2;

	my $hook = make_hook();
	$hook->add_feature('ha');

	$hook->build_features_list();

	ok(!defined($hook->has_feature('ha')),
		'has_feature() returns undef after build_features_list() emitted it');
	cmp_deeply($hook->{all_features}, ['ha'],
		'all_features list still contains the feature name');
};

subtest 'build_features_list - virtual_features option promotes to + prefix' => sub {
	plan tests => 1;

	my $hook = make_hook();
	$hook->add_feature('+internal-blobstore');
	$hook->add_feature('ocfp');

	# 'internal-blobstore' appears in virtual_features so the method looks up
	# '+internal-blobstore' in the map and emits that prefixed form.
	my @list = $hook->build_features_list(
		virtual_features => ['internal-blobstore'],
	);
	cmp_deeply(\@list, ['+internal-blobstore', 'ocfp'],
		'build_features_list() emits + prefix for virtual features');
};

subtest 'build_features_list - virtual feature skipped when + entry absent' => sub {
	plan tests => 1;

	my $hook = make_hook();
	$hook->add_feature('internal-blobstore');
	$hook->add_feature('ocfp');

	# 'internal-blobstore' is in virtual_features, so the method looks for
	# '+internal-blobstore', which was never added — the feature is skipped.
	my @list = $hook->build_features_list(
		virtual_features => ['internal-blobstore'],
	);
	cmp_deeply(\@list, ['ocfp'],
		'virtual feature without + entry is skipped entirely');
};

subtest 'build_features_list - empty hook returns empty list' => sub {
	plan tests => 1;

	my $hook = make_hook();
	my @list = $hook->build_features_list();
	cmp_deeply(\@list, [],
		'build_features_list() returns empty list when no features were added');
};

subtest 'build_features_list - default virtual_features is empty list' => sub {
	plan tests => 1;

	my $hook = make_hook();
	$hook->add_feature('ha');

	# Calling with no options should behave the same as virtual_features => []
	my @list = $hook->build_features_list();
	cmp_deeply(\@list, ['ha'],
		'omitting virtual_features option does not affect plain feature output');
};

# ---------------------------------------------------------------------------
# done
# ---------------------------------------------------------------------------
subtest 'done - no args calls build_features_list and marks complete' => sub {
	plan tests => 3;

	my $hook = make_hook();
	$hook->add_feature('ha');
	$hook->add_feature('mtls');

	my $ret;
	lives_ok { $ret = $hook->done() } 'done() with no args lives';

	is($hook->{complete}, 1, 'complete flag set to 1');
	cmp_deeply($ret, ['ha', 'mtls'],
		'done() returns array ref built by build_features_list()');
};

subtest 'done - no args with empty feature registry returns empty array ref' => sub {
	plan tests => 2;

	my $hook = make_hook();
	my $ret  = $hook->done();

	is($hook->{complete}, 1, 'complete flag set to 1');
	cmp_deeply($ret, [], 'done() with no features returns empty array ref');
};

subtest 'done - array ref argument passed directly to parent done' => sub {
	plan tests => 3;

	my $hook     = make_hook();
	my $features = ['ha', 'mtls', 'tls'];
	my $ret      = $hook->done($features);

	is($hook->{complete}, 1, 'complete flag set to 1');
	is($ret, $features, 'done(\@ref) returns the same array reference');
	cmp_deeply($hook->{results}, ['ha', 'mtls', 'tls'],
		'results stored as the supplied array reference');
};

subtest 'done - multiple string args collected into array ref' => sub {
	plan tests => 3;

	my $hook = make_hook();
	my $ret  = $hook->done('ha', 'mtls', 'tls');

	is($hook->{complete}, 1, 'complete flag set to 1');
	isa_ok($ret, 'ARRAY', 'done(strings...) returns an array reference');
	cmp_deeply($ret, ['ha', 'mtls', 'tls'],
		'done(strings...) collects all string args into array ref');
};

subtest 'done - single string arg collected into array ref' => sub {
	plan tests => 2;

	my $hook = make_hook();
	my $ret  = $hook->done('ha');

	isa_ok($ret, 'ARRAY', 'done(single_string) returns an array reference');
	cmp_deeply($ret, ['ha'],
		'done(single_string) wraps the string in an array ref');
};

subtest 'done - single undef marks hook as not complete' => sub {
	plan tests => 3;

	my $hook = make_hook();
	my $ret  = $hook->done(undef);

	ok(!defined($ret), 'done(undef) returns undef');
	is($hook->{complete}, 0, 'complete flag remains 0 when done(undef) called');
	ok(!defined($hook->results), 'results() returns undef when not complete');
};

subtest 'done - single 0 delegates to parent done and marks complete' => sub {
	plan tests => 2;

	my $hook = make_hook();
	my $ret  = $hook->done(0);

	is($ret, 0, 'done(0) returns 0');
	# 0 is defined so SUPER::done records it and sets complete = 1
	is($hook->{complete}, 1,
		'complete flag is 1 after done(0) because 0 is defined');
};

subtest 'done - results accessible via results() after completion' => sub {
	plan tests => 2;

	my $hook = make_hook();
	$hook->add_feature('ha');
	$hook->done();

	is($hook->completed, 1, 'completed() returns 1 after done()');
	cmp_deeply($hook->results, ['ha'],
		'results() returns the feature array ref after done()');
};

subtest 'done - results() returns undef when not complete' => sub {
	plan tests => 1;

	my $hook = make_hook();
	ok(!defined($hook->results),
		'results() returns undef before done() is called');
};

done_testing;
