#!perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;
use Test::Exception;
use Test::Output;
use Test::Exit;
use Cwd qw/abs_path/;

use Genesis::Commands;
use PadWalker qw/closed_over/;
use Genesis;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 120;

# Initialize Genesis runtime (RC config, logger, etc.)
require Genesis::Config;
Genesis::Init();

sub reset_commands_state {
	$Genesis::Commands::COMMAND = undef;
	$Genesis::Commands::CALLED = undef;
	%Genesis::Commands::RUN = ();
	%Genesis::Commands::PROPS = ();
	%Genesis::Commands::GENESIS_COMMANDS = ();
	@Genesis::Commands::COMMANDS = ();
	$Genesis::Commands::COMMAND_OPTIONS = {};
	@Genesis::Commands::COMMAND_ARGS = ();
	$Genesis::Commands::END_HOOKS = [];
}

# ============================================================================
# Block A: Command Registry, Lookup & Equivalence (Subtests 1-9)
# ============================================================================

subtest 'define_command - minimal registration' => sub {
	reset_commands_state();

	define_command('test-minimal');

	ok(exists $Genesis::Commands::PROPS{'test-minimal'}, "props entry created");
	is($Genesis::Commands::PROPS{'test-minimal'}{scope}, 'any', "default scope is 'any'");
	is($Genesis::Commands::PROPS{'test-minimal'}{no_vault}, 0, "default no_vault is 0");
	is_deeply(
		$Genesis::Commands::PROPS{'test-minimal'}{function_group},
		Genesis::Commands::GENESIS,
		"default function_group is GENESIS"
	);
	is($Genesis::Commands::PROPS{'test-minimal'}{option_group}, Genesis::Commands::BASE_OPTIONS, "default option_group is BASE_OPTIONS");
	is($Genesis::Commands::PROPS{'test-minimal'}{option_passthrough}, 0, "default option_passthrough is 0");
	ok(exists $Genesis::Commands::RUN{'test-minimal'}, "RUN entry created");
	is(ref($Genesis::Commands::RUN{'test-minimal'}), 'CODE', "RUN entry is a coderef");
};

subtest 'define_command - full properties and coderef' => sub {
	reset_commands_state();

	my $called = 0;
	my $coderef = sub { $called = 1; return 42 };

	define_command('full-cmd', {
		summary        => 'A full command',
		description    => 'A detailed description',
		scope          => 'env',
		no_vault       => 1,
		function_group => Genesis::Commands::ENVIRONMENT,
		option_group   => Genesis::Commands::ENV_OPTIONS,
		alias          => 'fc',
		options        => ['flag|f' => 'A flag', 'name|n=s' => 'A name'],
	}, $coderef);

	is($Genesis::Commands::PROPS{'full-cmd'}{summary}, 'A full command', "summary set correctly");
	is($Genesis::Commands::PROPS{'full-cmd'}{scope}, 'env', "scope set to env");
	is($Genesis::Commands::PROPS{'full-cmd'}{no_vault}, 1, "no_vault set to 1");
	is_deeply(
		$Genesis::Commands::PROPS{'full-cmd'}{function_group},
		Genesis::Commands::ENVIRONMENT,
		"function_group is ENVIRONMENT"
	);
	is($Genesis::Commands::PROPS{'full-cmd'}{option_group}, Genesis::Commands::ENV_OPTIONS, "option_group is ENV_OPTIONS");
	is($Genesis::Commands::GENESIS_COMMANDS{'full-cmd'}, 'full-cmd', "canonical name maps to itself");
	is($Genesis::Commands::GENESIS_COMMANDS{'fc'}, 'full-cmd', "alias maps to canonical");
	ok(exists $Genesis::Commands::RUN{'full-cmd'}, "RUN entry exists for canonical");
	is(ref($Genesis::Commands::RUN{'full-cmd'}), 'CODE', "RUN entry is a coderef");

	my @cmd_list = commands();
	is(scalar(@cmd_list), 1, "one command registered");

	# Verify the wrapper closure dispatches to the provided coderef
	$Genesis::Commands::RUN{'full-cmd'}->();
	is($called, 1, "RUN closure dispatches to provided coderef");
};

subtest 'define_command - explicit function name string' => sub {
	reset_commands_state();

	define_command('my-cmd', {}, 'Genesis::Commands::Utility::my_cmd');

	my $subref = $Genesis::Commands::RUN{'my-cmd'};
	ok(defined $subref, "RUN entry exists");
	is(ref($subref), 'CODE', "RUN entry is a coderef");

	cmp_deeply(scalar(closed_over($subref)), {
		'$fn' => \'Genesis::Commands::Utility::my_cmd',
		'$fn_require' => \'Genesis/Commands/Utility.pm',
		'$name' => \'my-cmd',
	}, "closure captures correct variables for explicit function name");
};

subtest 'define_command - function name resolution from function_group' => sub {
	reset_commands_state();

	define_command('my-thing', {
		function_group => Genesis::Commands::ENVIRONMENT,
	});

	my $subref = $Genesis::Commands::RUN{'my-thing'};
	cmp_deeply(scalar(closed_over($subref)), {
		'$fn' => \'Genesis::Commands::Env::my_thing',
		'$fn_require' => \'Genesis/Commands/Env.pm',
		'$name' => \'my-thing',
	}, "hyphens converted to underscores, module from function_group");
};

subtest 'commands and known_commands' => sub {
	reset_commands_state();

	define_command('alpha', { alias => 'a' });
	define_command('beta');
	define_command('gamma', { aliases => ['g', 'gam'] });

	my @cmds = commands();
	is_deeply(\@cmds, ['alpha', 'beta', 'gamma'], "commands() returns registration order");

	my @known = known_commands();
	cmp_bag(\@known, ['alpha', 'beta', 'gamma'], "known_commands returns only canonical names");

	ok(exists $Genesis::Commands::GENESIS_COMMANDS{'a'}, "alias 'a' in GENESIS_COMMANDS");
	ok(exists $Genesis::Commands::GENESIS_COMMANDS{'g'}, "alias 'g' in GENESIS_COMMANDS");
	ok(exists $Genesis::Commands::GENESIS_COMMANDS{'gam'}, "alias 'gam' in GENESIS_COMMANDS");
};

subtest 'has_command' => sub {
	reset_commands_state();

	define_command('deploy', { alias => 'dep' });

	ok(     has_command('deploy'),     "canonical command found");
	ok(     has_command('dep'),        "alias found");
	not_ok( has_command('nosuchcmd'),  "nonexistent returns false");
	not_ok( has_command(''),           "empty string returns false");
};

subtest 'is_equivalent_command' => sub {
	reset_commands_state();

	define_command('deploy', { alias => 'dep' });
	define_command('check');

	ok(     is_equivalent_command('dep', 'deploy'),       "alias and canonical are equivalent");
	ok(     is_equivalent_command('deploy', 'dep'),       "reversed order also equivalent");
	not_ok( is_equivalent_command('deploy', 'check'),     "different commands not equivalent");
	not_ok( is_equivalent_command('', 'deploy'),           "empty string not equivalent");
	not_ok( is_equivalent_command('nonexist', 'deploy'),   "nonexistent not equivalent");
};

subtest 'equivalent_commands' => sub {
	reset_commands_state();

	define_command('deploy', { aliases => ['dep', 'd'] });

	my @equivs = equivalent_commands('deploy');
	cmp_bag(\@equivs, ['deploy', 'dep', 'd'], "list context returns all equivalent names");

	my @via_alias = equivalent_commands('dep');
	cmp_bag(\@via_alias, ['deploy', 'dep', 'd'], "lookup via alias returns same set");

	my $ref = equivalent_commands('deploy');
	is(ref($ref), 'ARRAY', "scalar context returns arrayref");
	cmp_bag($ref, ['deploy', 'dep', 'd'], "scalar arrayref has correct contents");

	my @unknown = equivalent_commands('nonexistent');
	is(scalar(@unknown), 0, "unknown command returns empty list");
};

subtest 'command_properties' => sub {
	reset_commands_state();

	define_command('test-props', {
		summary => 'Test props',
		scope   => 'repo',
		alias   => 'tp',
	});

	# Named lookup
	my $props = command_properties('test-props');
	is($props->{summary}, 'Test props', "named lookup returns correct summary");
	is($props->{scope}, 'repo', "named lookup returns correct scope");

	# Alias lookup
	my $alias_props = command_properties('tp');
	is($alias_props->{summary}, 'Test props', "alias lookup returns same properties");

	# Active command lookup
	prepare_command('test-props');
	my $active_props = command_properties();
	is($active_props->{summary}, 'Test props', "no-arg returns active command properties");

	# No active command and no name
	reset_commands_state();
	throws_ok { command_properties() } qr/No active or given command/,
		"no-arg with no active command throws bug";
};

# ============================================================================
# Block B: Command Preparation & Option/Arg Access (Subtests 10-17)
# ============================================================================

subtest 'prepare_command - basic' => sub {
	reset_commands_state();

	define_command('test-prep', {
		summary => 'Test prepare',
		options => ['flag|f' => 'A flag', 'name|n=s' => 'A name'],
	});

	my $result = prepare_command('test-prep', '--flag', '--name', 'hello', 'arg1', 'arg2');

	is($result, 1, "prepare_command returns 1");
	is(current_command(), 'test-prep', "current_command set correctly");
	is(current_command_alias(), 'test-prep', "current_command_alias matches (canonical used)");
	ok(get_options()->{flag}, "flag option parsed");
	is(get_options()->{name}, 'hello', "string option parsed");

	my @args = get_args();
	is_deeply(\@args, ['arg1', 'arg2'], "positional args captured");

	# Verify infrastructure options removed
	ok(!exists get_options()->{color}, "color option consumed by infrastructure");
};

subtest 'prepare_command - alias resolution' => sub {
	reset_commands_state();

	define_command('test-alias', {
		summary => 'Test alias',
		alias   => 'ta',
	});

	prepare_command('ta');
	is(current_command(), 'test-alias', "current_command is canonical name");
	is(current_command_alias(), 'ta', "current_command_alias is the alias");

	# Prepare via canonical name
	prepare_command('test-alias');
	is(current_command(), 'test-alias', "canonical via canonical");
	is(current_command_alias(), 'test-alias', "alias matches canonical when called directly");
};

subtest 'current_command initial state' => sub {
	reset_commands_state();
	is(current_command(), undef, "current_command is undef after reset");
	is(current_command_alias(), undef, "current_command_alias is undef after reset");
};

subtest 'get_options - full and sliced' => sub {
	reset_commands_state();

	define_command('opt-test', {
		options => [
			'flag|f'   => 'A flag',
			'name|n=s' => 'A name',
			'count=i'  => 'A count',
		],
	});

	prepare_command('opt-test', '--flag', '--name', 'hello', '--count', '5');

	# Full options
	my $all = get_options();
	ok($all->{flag}, "flag is set");
	is($all->{name}, 'hello', "name is set");
	is($all->{count}, 5, "count is set");

	# Sliced
	my $slice = get_options('flag', 'name');
	ok(exists $slice->{flag}, "flag in slice");
	is($slice->{name}, 'hello', "name in slice");
	ok(!exists $slice->{count}, "count excluded from slice");

	# NOTE: get_options is intended to have an underscore-to-dash fallback via
	# _u2d(), but _u2d currently lives privately in Genesis.pm and is not
	# exported to Commands.  The following TODO test documents the desired
	# behavior and exposes the current bug without breaking the suite.
	{
		local $TODO = "get_options underscore-to-dash fallback via _u2d() is currently broken";

		reset_commands_state();
		define_command('u2d-opt-test', {
			options => [
				'bosh-env=s' => 'BOSH environment',
			],
		});

		prepare_command('u2d-opt-test', '--bosh-env', 'dev');

		lives_ok {
			my $u2d = get_options('bosh_env');
			is($u2d->{bosh_env}, 'dev',
				"underscore key 'bosh_env' should be resolved from '--bosh-env' option");
		} "get_options supports underscore-to-dash fallback for option keys";
	}
};

subtest 'get_args' => sub {
	reset_commands_state();

	define_command('args-test', {});
	prepare_command('args-test', 'first', 'second', 'third');

	my @args = get_args();
	is_deeply(\@args, ['first', 'second', 'third'], "list context returns args in order");

	dies_ok { my $h = scalar(get_args()) } "scalar context dies with 'hashref not yet implemented'";
};

subtest 'has_option' => sub {
	reset_commands_state();

	define_command('hasopt-test', {
		options => [
			'mode=s' => 'Mode',
			'flag'   => 'Flag',
			'maybe'  => 'Maybe',
		],
	});
	prepare_command('hasopt-test', '--mode', 'json', '--flag');

	# Existence tests
	ok( has_option('flag'),  "existing boolean option returns true");
	ok( has_option('mode'),  "existing string option returns true");
	not_ok( has_option('maybe'), "unset option returns false");
	not_ok( has_option('nope'),  "nonexistent option returns false");

	# Value tests
	ok( has_option('mode', 'json'),     "string match returns true");
	not_ok( has_option('mode', 'yaml'),     "string mismatch returns false");
	ok(     has_option('mode', qr/^js/),    "regex match returns true");
	not_ok( has_option('mode', qr/^xml/),   "regex mismatch returns false");
};

subtest 'option_defaults' => sub {
	reset_commands_state();

	define_command('defaults-test', {
		options => ['format=s' => 'Format'],
	});
	prepare_command('defaults-test', '--format', 'json');

	option_defaults(format => 'table', verbose => 0);
	is(get_options()->{format}, 'json', "existing option not overwritten");
	is(get_options()->{verbose}, 0, "new default applied");

	option_defaults(verbose => 1, extra => 'yes');
	is(get_options()->{verbose}, 0, "already-set default not overwritten");
	is(get_options()->{extra}, 'yes', "additional default applied");

	# undef value edge case: defined() check means undef IS overwritten
	append_options(maybe => undef);
	option_defaults(maybe => 'fallback');
	is(get_options()->{maybe}, 'fallback', "undef value IS overwritten by option_defaults");
};

subtest 'append_options' => sub {
	reset_commands_state();

	define_command('append-test', {
		options => ['flag' => 'Flag'],
	});
	prepare_command('append-test', '--flag');

	my $result = append_options(injected => 1, source => 'internal');
	is(ref($result), 'HASH', "returns hashref");
	is($result->{injected}, 1, "new key added");
	is($result->{source}, 'internal', "another new key added");

	# Overwrite existing
	append_options(flag => 0);
	ok(!get_options()->{flag}, "existing key overwritten");
};

# ============================================================================
# Block C: Option Parsing & Scope (Subtests 18-25)
# ============================================================================

subtest 'parse_options - type coercion' => sub {
	reset_commands_state();

	define_command('types-test', {
		options => [
			'str=s'    => 'String option',
			'num=i'    => 'Integer option',
			'opt:s'    => 'Optional string',
			'toggle!'  => 'Negatable boolean',
			'verbose+' => 'Incrementing',
		],
	});

	prepare_command('types-test', '--str', 'hello', '--num', '42', '--opt',
		'--toggle', '--verbose', '--verbose', '--verbose');

	my $opts = get_options();
	is($opts->{str}, 'hello', "=s captures string");
	is($opts->{num}, 42, "=i captures integer");
	is($opts->{opt}, '', ":s with no value gives empty string");
	is($opts->{toggle}, 1, "! boolean is true when set");
	is($opts->{verbose}, 3, "+ increments with each use");

	# Negated boolean
	reset_commands_state();
	define_command('neg-test', {
		options => ['toggle!' => 'Negatable'],
	});
	prepare_command('neg-test', '--no-toggle');
	is(get_options()->{toggle}, 0, "! negated with --no- prefix gives 0");

	# Integer coercion
	reset_commands_state();
	define_command('int-test', {
		options => ['count=i' => 'Count'],
	});
	prepare_command('int-test', '--count', '0');
	is(get_options()->{count}, 0, "=i preserves 0 as integer");
	ok(defined(get_options()->{count}), "=i with 0 is defined");
};

subtest 'parse_options - option_passthrough' => sub {
	reset_commands_state();

	define_command('passthru-test', {
		option_passthrough => 1,
		options => ['known' => 'Known option'],
	});

	prepare_command('passthru-test', '--known', '--unknown-opt', 'extra-arg');
	ok(get_options()->{known}, "known option parsed");

	my @args = get_args();
	ok((grep { $_ eq '--unknown-opt' } @args), "unknown option passed through to args");
};

subtest 'parse_options - option_require_order' => sub {
	reset_commands_state();

	define_command('reqorder-test', {
		option_require_order => 1,
		options => ['flag|f' => 'A flag', 'name=s' => 'Name'],
	});

	prepare_command('reqorder-test', '--flag', 'positional', '--name', 'should-be-arg');

	ok(get_options()->{flag}, "option before first non-option parsed");
	ok(!exists get_options()->{name}, "option after first non-option NOT parsed");

	my @args = get_args();
	is($args[0], 'positional', "first non-option becomes arg");
	ok((grep { $_ eq '--name' } @args), "--name ends up in args");
};

subtest 'parse_options - color and quiet extraction' => sub {
	reset_commands_state();

	define_command('colorquiet-test', {});

	{
		local $ENV{NOCOLOR};
		local $ENV{QUIET};

		prepare_command('colorquiet-test', '--no-color', '--quiet');
		is($ENV{NOCOLOR}, 'y', "--no-color sets NOCOLOR env var");
		is($ENV{QUIET}, 'y', "--quiet sets QUIET env var");

		# Verify these keys are removed from options
		ok(!exists get_options()->{color}, "color key removed from options");
		ok(!exists get_options()->{quiet}, "quiet key removed from options");
	}
};

subtest 'parse_options - double dash separator' => sub {
	reset_commands_state();

	define_command('doubledash-test', {
		options => ['flag' => 'A flag'],
	});

	prepare_command('doubledash-test', '--flag', '--', '--not-an-option', 'plain-arg');

	ok(get_options()->{flag}, "option before -- parsed normally");

	my @args = get_args();
	ok((grep { $_ eq '--not-an-option' } @args), "--not-an-option treated as positional after --");
	ok((grep { $_ eq 'plain-arg' } @args), "plain arg after -- also positional");
};

subtest 'has_scope - simple string' => sub {
	reset_commands_state();

	define_command('scope-env', { scope => 'env' });
	prepare_command('scope-env');

	ok( has_scope('env'),  "'env' matches scope 'env'");
	ok(!has_scope('repo'), "'repo' does not match scope 'env'");
	ok(!has_scope('kit'),  "'kit' does not match scope 'env'");
	ok(!has_scope('any'),  "'any' does not match scope 'env'");
};

subtest 'has_scope - any scope' => sub {
	reset_commands_state();

	define_command('scope-any', { scope => 'any' });
	prepare_command('scope-any');

	ok( has_scope('any'),      "'any' matches scope 'any'");
	ok(!has_scope('env'),      "'env' does not match scope 'any' (literal match)");
	ok(!has_scope('pipeline'), "'pipeline' does not match scope 'any'");
};

subtest 'has_scope - conditional array fragments' => sub {
	reset_commands_state();

	# Conditional scope: if --create is set, scope is 'empty'; otherwise 'env'
	# Both fragments must be conditional to prevent fallback matching
	define_command('cond-scope', {
		scope   => [
			['create', 'empty'],
			['!create', 'env'],
		],
		options => ['create' => 'Create mode'],
	});

	# Without --create: second fragment matches (negated condition true)
	prepare_command('cond-scope');
	ok( has_scope('env'),   "!create fragment matches 'env' when --create not set");
	ok(!has_scope('empty'), "create fragment does not match 'empty' when --create not set");

	# With --create: first fragment matches
	prepare_command('cond-scope', '--create');
	ok( has_scope('empty'), "create fragment matches 'empty' when --create set");
	ok(!has_scope('env'),   "!create fragment does not match 'env' when --create set");

	# Value comparison: opt_name=value
	reset_commands_state();
	define_command('val-scope', {
		scope   => [
			['mode=kit', 'kit'],
			['!mode=kit', 'repo'],
		],
		options => ['mode=s' => 'Mode'],
	});

	prepare_command('val-scope', '--mode', 'kit');
	ok( has_scope('kit'),  "value comparison matches when option equals value");
	ok(!has_scope('repo'), "negated value comparison does not match");
};

# ============================================================================
# Block D: Environment, Help, Constants & at_exit (Subtests 26-36)
# ============================================================================

subtest 'build_command_environment - bosh-env' => sub {
	reset_commands_state();

	define_command('boshenv-test', {
		option_group => Genesis::Commands::ENV_OPTIONS,
	});

	{
		local $ENV{GENESIS_BOSH_ENVIRONMENT};
		prepare_command('boshenv-test', '--bosh-env', 'my-director');
		build_command_environment();

		is($ENV{GENESIS_BOSH_ENVIRONMENT}, 'my-director', "bosh-env sets GENESIS_BOSH_ENVIRONMENT");
		ok(!exists get_options()->{'bosh-env'}, "bosh-env removed from options");
	}
};

subtest 'build_command_environment - cpi' => sub {
	reset_commands_state();

	define_command('cpi-test', {
		option_group => Genesis::Commands::ENV_OPTIONS,
	});

	{
		local $ENV{GENESIS_TESTING_BOSH_CPI};
		prepare_command('cpi-test', '--cpi', 'vsphere');
		build_command_environment();

		is($ENV{GENESIS_TESTING_BOSH_CPI}, 'vsphere', "cpi sets GENESIS_TESTING_BOSH_CPI");
	}
};

subtest 'build_command_environment - config expansion' => sub {
	reset_commands_state();

	define_command('config-test', {
		option_group => Genesis::Commands::ENV_OPTIONS,
	});

	# Create a temp file for the config path
	my $config_file = workdir() . "/test-cloud-config.yml";
	put_file($config_file, "--- {}");
	my $abs_config = abs_path($config_file);

	{
		local $ENV{GENESIS_CLOUD_CONFIG};
		prepare_command('config-test', '--config', "cloud=$config_file");
		build_command_environment();

		is($ENV{GENESIS_CLOUD_CONFIG}, $abs_config, "cloud config sets GENESIS_CLOUD_CONFIG");
	}

	# Runtime config with name
	reset_commands_state();
	define_command('config-test2', {
		option_group => Genesis::Commands::ENV_OPTIONS,
	});

	{
		local $ENV{GENESIS_RUNTIME_CONFIG_myname};
		prepare_command('config-test2', '--config', "runtime\@myname=$config_file");
		build_command_environment();

		is($ENV{GENESIS_RUNTIME_CONFIG_myname}, $abs_config,
			"runtime\@name config sets GENESIS_RUNTIME_CONFIG_myname");
	}

	# Default type (no prefix = cloud)
	reset_commands_state();
	define_command('config-test3', {
		option_group => Genesis::Commands::ENV_OPTIONS,
	});

	{
		local $ENV{GENESIS_CLOUD_CONFIG};
		prepare_command('config-test3', '--config', $config_file);
		build_command_environment();

		is($ENV{GENESIS_CLOUD_CONFIG}, $abs_config,
			"bare path defaults to cloud config");
	}
};

subtest 'build_command_environment - spruce-log error' => sub {
	reset_commands_state();

	define_command('spruce-err', {
		option_group => Genesis::Commands::ENV_OPTIONS,
		options => ['spruce-log=s' => 'Spruce log level'],
	});

	prepare_command('spruce-err', '--spruce-log', 'invalid');

	throws_ok { build_command_environment() }
		qr/spruce-log is expected to be one of TRACE or DEBUG/,
		"invalid spruce-log value bails";
};

subtest 'command_help - exits 0' => sub {
	reset_commands_state();

	define_command('help-test', {
		summary        => 'A help test command',
		function_group => Genesis::Commands::GENESIS,
	});

	my ($stdout, $stderr) = output_from {
		exits_zero { command_help() } "command_help with no message exits 0";
	};

	like($stderr, qr/help-test/, "help output mentions registered command");
};

subtest 'command_help - exits nonzero with message' => sub {
	reset_commands_state();

	define_command('help-err', { summary => 'Error test' });

	my ($stdout, $stderr) = output_from {
		exits_nonzero { command_help("Unrecognized command 'foo'") }
			"command_help with message exits nonzero";
	};

	like($stderr, qr/Unrecognized command/, "error message appears in output");
};

subtest 'command_usage - exits 0 full help' => sub {
	reset_commands_state();

	define_command('usage-test', {
		summary     => 'Usage test command',
		description => 'A detailed usage description',
		options     => ['verbose|v' => 'Verbose output'],
	});
	prepare_command('usage-test');

	my ($stdout, $stderr) = output_from {
		exits_zero { command_usage(0) } "command_usage(0) exits 0";
	};

	like($stderr, qr/Usage test command/, "output includes command summary");
	like($stderr, qr/verbose/, "output includes option listing");
};

subtest 'command_usage - exits nonzero with error' => sub {
	reset_commands_state();

	define_command('usage-err', {
		summary => 'Usage error test',
		options => ['flag' => 'A flag'],
	});
	prepare_command('usage-err');

	my ($stdout, $stderr) = output_from {
		exits_nonzero { command_usage(1, "missing required argument") }
			"command_usage(1, msg) exits nonzero";
	};

	# NOTE: under_test() is true ($ENV{GENESIS_TESTING}), so the error
	# message path (fatal + brief hint) is skipped. Instead, the full
	# usage screen is shown and exit($rc) is called. The error message
	# content cannot be verified in the test harness.
	like($stderr, qr/Usage error test/, "full usage shown even with error rc under test");
};

subtest 'show_global_options' => sub {
	reset_commands_state();

	my ($stdout, $stderr) = output_from {
		exits_zero { show_global_options() } "show_global_options exits 0";
	};

	like($stderr, qr/Global Options/, "output contains Global Options heading");
	like($stderr, qr/--help/, "output lists --help option");
};

subtest 'at_exit' => sub {
	reset_commands_state();

	my $hook_count = scalar(@$Genesis::Commands::END_HOOKS);
	is($hook_count, 0, "END_HOOKS starts empty after reset");

	at_exit(sub { 1 });
	is(scalar(@$Genesis::Commands::END_HOOKS), 1, "one callback registered");

	at_exit(sub { 2 });
	is(scalar(@$Genesis::Commands::END_HOOKS), 2, "two callbacks registered");
};

subtest 'constants' => sub {
	# Function group constants
	is(ref(Genesis::Commands::ENVIRONMENT), 'HASH', "ENVIRONMENT is a hashref");
	is(Genesis::Commands::ENVIRONMENT->{order}, 0, "ENVIRONMENT order is 0");
	is(Genesis::Commands::ENVIRONMENT->{module}, 'Env', "ENVIRONMENT module is 'Env'");
	is(Genesis::Commands::ENVIRONMENT->{label}, 'Environment Management', "ENVIRONMENT label correct");

	is(ref(Genesis::Commands::GENESIS), 'HASH', "GENESIS is a hashref");
	is(Genesis::Commands::GENESIS->{order}, 6, "GENESIS order is 6");
	is(Genesis::Commands::GENESIS->{module}, 'Core', "GENESIS module is 'Core'");

	is(ref(Genesis::Commands::DEPRECATED), 'HASH', "DEPRECATED is a hashref");
	ok(Genesis::Commands::DEPRECATED->{order} < 0, "DEPRECATED has negative order (hidden)");

	# Option group constants
	is(Genesis::Commands::BLANK_OPTIONS, 0, "BLANK_OPTIONS is 0");
	is(Genesis::Commands::BASE_OPTIONS, 1, "BASE_OPTIONS is 1");
	is(Genesis::Commands::REPO_OPTIONS, 2, "REPO_OPTIONS is 2");
	is(Genesis::Commands::ENV_OPTIONS, 3, "ENV_OPTIONS is 3");
};

done_testing;
