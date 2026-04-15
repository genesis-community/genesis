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

use Genesis::Commands;
use PadWalker qw/closed_over/;
use Genesis;

# Initialize the Genesis environment
$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

subtest 'bin/genesis' => sub {

	require_ok './bin/genesis';

	# TODO: Add tests to make sure all the defined commands are valid in their definitions in general (ie: specify existing function groups, correct format of options, etc)

};

subtest 'genesis terminate' => sub {
	plan tests => 55;

	ok(has_command('terminate'), "Terminate command is registered");

	ok(is_equivalent_command('destroy' => 'terminate'), "terminate command aliases to 'destroy'");
	ok(is_equivalent_command(terminate => 'kill'), "terminate command aliases to 'delete'");
	not_ok(is_equivalent_command(terminate => 'deploy'), "terminate command does not alias to 'deploy'");
	not_ok(is_equivalent_command('','terminate'), "terminate command does not alias to 'init'");
	cmp_bag([equivalent_commands('terminate')], ['terminate', 'implode', 'destroy', 'kill'], "terminate command aliases to 'implode', 'destroy', and 'kill' (and itself), but no others");

	is(command_properties('terminate')->{function_group}, Genesis::Commands::ENVIRONMENT, "Terminate command belongs to environment group"); # This works becaus its a constant
	is(command_properties('terminate')->{scope}, 'env', "Terminate command has env scope");
	is(command_properties('terminate')->{option_group}, Genesis::Commands::ENV_OPTIONS, "Terminate command uses ENV_OPTIONS");

	my %terminate_opts = command_properties('terminate')->{options}->@*;
	ok(exists $terminate_opts{'resources!'}, "terminate has toggleable resources option");
	ok(exists $terminate_opts{'secrets!'}, "terminate has toggleable secrets option");
	ok(exists $terminate_opts{'user-secrets!'}, "terminate has toggleable user-secrets option");
	ok(exists $terminate_opts{'credhub!'}, "terminate has toggleable credhub option");
	ok(exists $terminate_opts{'networking!'}, "terminate has toggleable networking option");
	ok(exists $terminate_opts{'no-cleanup|K'}, "terminate has no-cleanup option");
	ok(exists $terminate_opts{'force|f'}, "terminate has force option");
	ok(exists $terminate_opts{'yes|y'}, "terminate has yes (no-prompt) option");
	ok(exists $terminate_opts{'dry-run|n'}, "terminate has dry-run option");
	is(scalar(keys %terminate_opts), 9, "terminate only has the 5 options above");

	my %terminate_args = command_properties('terminate')->{arguments}->@*;
	is(scalar(keys %terminate_args), 1, "terminate has one argument");
	ok(exists $terminate_args{reason}, "terminate has a 'reason' argument");

	not_ok(command_properties('terminate')->{deprecated}, "terminate command is not deprecated");

	my $subref = $Genesis::Commands::RUN{terminate};
	is(ref($subref), 'CODE', "terminate command has a subroutine reference");
	cmp_deeply(scalar(closed_over($subref)), {
		'$fn' => \'Genesis::Commands::Env::terminate',
		'$fn_require' => \'Genesis/Commands/Env.pm',
		'$name' => \'terminate',
	}, "terminate command subroutine has the correct closed-over variables");

	# Setup a dry-run terminate command
	prepare_command('terminate', 'my-env','-f','--no-cleanup', '--credhub', '--dry-run','--yes','reason');
	build_command_environment

	my @args = get_args();
	$args[0] = mock 'Genesis::Env' => {
		name => 'my-env',
		type => 'my-type',
		deployment_change_reason_required_size_policy => 0,
		notify => sub {
			my ($self, $msg) = @_;
			info("[my-env/my-type] ".$msg);
		},
		use_create_env => 0,
		terminate => sub {
			my ($self, %opts) = @_;
			subtest "terminate call validation (dryrun, no cleanup)" => sub {
				plan tests => 7;
				is($self->name, 'my-env', "terminate called with correct environment name");
				is($opts{reason}, 'reason', "terminate called with correct reason");
				ok($opts{force},"terminate called with --force");
				ok($opts{dryrun}, "terminate called with --dry-run");
				ok($opts{noprompt}, "terminate called with --yes");
				eq_or_diff($opts{flags}, '--credhub --dry-run --force --no-cleanup --yes', "terminate called with correct flags");
				cmp_deeply({%opts{qw/resources secrets user_secrets credhub networking/}}, {
					resources => 0,
					secrets => 0,
					user_secrets => 0,
					credhub => 1,
					networking => 0
				}, "terminate called with correct cleanup options");
			};
			return 1;
		},
	};

	my ($stdout, $stderr) = output_from {
		exits_zero { $subref->(@args) } "terminate dry-run command exits with 0";
	};
	like($stderr, qr/\[my-env\/my-type] This would terminate this deployment:/, "terminate dry-run command prints dry-run message");
	like($stderr, qr/- all its VMs and persistent disks would be destroyed\.$/m, "terminate dry-run command prints VM and disk destruction message");
	like($stderr, qr/- this environment's generated secrets would be left in place \(use --secrets to remove\)\.$/m, "terminate dry-run command prints generated secret retention message (--no-cleanup)");
	like($stderr, qr/- this environment's user-provided secrets would be left in place \(use --user-secrets to remove\)\.$/m, "terminate dry-run command prints user secret retention message (--no-cleanup)");
	like($stderr, qr/- this environment's credhub secrets would be removed\.$/m, "terminate dry-run command prints credhub secret retention message (--credhub)");
	like($stderr, qr/- all unused resources would be left in place on its BOSH director \(use --resources to remove\)\.$/m, "terminate dry-run command prints resource retention message (--no-cleanup)");
	like($stderr, qr/- all claimed networks would be left in place on its BOSH director \(use --networking to remove\)\.$/m, "terminate dry-run command prints network retention message (--no-cleanup)");
	like($stderr, qr/- all associated BOSH configs on its BOSH director would be removed\.$/m, "terminate dry-run command prints BOSH config removal message");
	like($stderr, qr/my-env\/my-type termination dry-run completed/, "terminate dry-run command prints termination message");
	is($stdout, '', "terminate dry-run command prints nothing to stdout");

	# Run a successful terminate command
	prepare_command('terminate', 'my-env','-f','-y');
	build_command_environment;

	@args = get_args();
	$args[0] = mock 'Genesis::Env' => {
		name => 'my-env',
		type => 'my-type',
		deployment_change_reason_required_size_policy => 0,
		notify => sub {
			my ($self, $msg) = @_;
			info("[my-env/my-type] ".$msg);
		},
		use_create_env => 0,
		terminate => sub {
			my ($self, %opts) = @_;
			subtest "terminate call validation (default cleanup, no-dryrun)" => sub {
				plan tests => 7;
				is($self->name, 'my-env', "terminate called with correct environment name");
				is($opts{reason}, undef, "terminate called with no reason");
				ok($opts{force},"terminate called with --force");
				not_ok($opts{dryrun}, "terminate called without --dry-run");
				ok($opts{noprompt}, "terminate called with --yes");
				eq_or_diff($opts{flags}, '--force --yes', "terminate called with correct flags");
				cmp_deeply({%opts{qw/resources secrets user_secrets credhub networking/}}, {
					resources => 1,
					secrets => 1,
					user_secrets => 1,
					credhub => 1,
					networking => 1
				}, "terminate called with correct cleanup options");
			};
			return 1;
		},
	};
	($stdout, $stderr) = output_from {
		exits_zero { $subref->(@args) } "terminate command exits with 0";
	};

	like($stderr, qr/\[my-env\/my-type] This will terminate this deployment:$/m, "terminate command prints dry-run message");
	like($stderr, qr/- all its VMs and persistent disks will be destroyed\.$/m, "terminate command prints VM and disk destruction message");
	like($stderr, qr/- this environment's generated secrets will be removed \(use --no-secrets to keep\)\.$/m, "terminate command prints secret destruction message");
	like($stderr, qr/- this environment's user-provided secrets will be removed \(use --no-user-secrets to keep\)\.$/m, "terminate command prints user secret destruction message");
	like($stderr, qr/- this environment's credhub secrets will be removed \(use --no-credhub to keep\)\.$/m, "terminate command prints credhub destruction message");
	like($stderr, qr/- all unused resources will be removed from its BOSH director \(use --no-resources to keep\)\.$/m, "terminate command prints resource destruction message");
	like($stderr, qr/- all claimed networks will be removed from its BOSH director \(use --no-networking to keep\)\.$/m, "terminate command prints network destruction message");
	like($stderr, qr/- all associated BOSH configs on its BOSH director will be removed\.$/m, "terminate dry-run command prints BOSH config removal message");
	like($stderr, qr/my-env\/my-type terminated successfully/, "terminate command prints successful termination message");
	is($stdout, '', "terminate successful command prints nothing to stdout");

	# Run a terminal command with prompt, but abort on a create_env environment
	prepare_command('terminate', 'my-env', '--no-user-secrets', 'trying to do something bad');
	build_command_environment;

	my $return_value = 1;
	@args = get_args();
	$args[0] = mock 'Genesis::Env' => {
		name => 'my-env',
		type => 'my-type',
		deployment_change_reason_required_size_policy => 0,
		notify => sub {
			my ($self, $msg) = @_;
			info("[my-env/my-type] ".$msg);
		},
		use_create_env => 1,
		terminate => sub {
			my ($self, %opts) = @_;
			subtest "terminate call validation (prompt, create_env, no-user-secrets)" => sub {
				plan tests => 7;
				is($self->name, 'my-env', "terminate called with correct environment name");
				is($opts{reason}, 'trying to do something bad', "terminate called with correct reason");
				not_ok($opts{force},"terminate called without --force");
				not_ok($opts{dryrun}, "terminate called without --dry-run");
				not_ok($opts{noprompt}, "terminate called without --yes");
				eq_or_diff($opts{flags}, '--no-user-secrets', "terminate called with correct flags");
				cmp_deeply({%opts{qw/resources secrets user_secrets credhub networking/}}, {
					resources => 1,
					secrets => 1,
					user_secrets => 0,
					credhub => 1,
					networking => 1
				}, "terminate called with correct cleanup options");
			};
			return $return_value;
		},
	};
	# Redirect STDIN to answer 'n' to the prompt
	set_stdin("n\n");
	$ENV{GENESIS_IGNORE_EVAL} = 1; # Prevent the eval from catching the exit
	($stdout, $stderr) = output_from {
		exits_nonzero { $subref->(@args) } "terminate command exits with non-zero";
	};
	# Clean up the STDIN redirection
	reset_stdin;

	is($stdout, '', "terminate failed command prints nothing to stdout");
	$stderr =~ s/\e\[\?25h$//; # Strip ANSI show cursor code
	eq_or_diff($stderr, <<'EOF', "terminate failed command prints failure message");
[my-env/my-type] This will terminate this deployment:
  - all its VMs and persistent disks will be destroyed.
  - this environment's generated secrets will be removed (use --no-secrets to keep).
  - this environment's user-provided secrets will be left in place.

[NOTICE] You can run this command with the --dry-run option to see exactly what would be removed without actually terminating the deployment or removing any asscoiated items.

[WARNING] This action is irreversible and cannot be undone!

Are you sure you want to terminate my-env/my-type deployment? [y|N] > 
[FATAL] Aborted by user!

EOF

	# Run a failing terminate command with --yes, don't abort
	$return_value = 0;
	set_stdin("y\n");
	$ENV{GENESIS_IGNORE_EVAL} = 1; # Prevent the eval from catching the exit
	($stdout, $stderr) = output_from {
		exits_nonzero { $subref->(@args) } "terminate command exits with non-zero";
	};
	reset_stdin;

	is($stdout, '', "terminate failed command prints nothing to stdout");
	$stderr =~ s/\e\[\?25h$//; # Strip ANSI show cursor code
	eq_or_diff($stderr, <<'EOF', "terminate failed command prints failure message");
[my-env/my-type] This will terminate this deployment:
  - all its VMs and persistent disks will be destroyed.
  - this environment's generated secrets will be removed (use --no-secrets to keep).
  - this environment's user-provided secrets will be left in place.

[NOTICE] You can run this command with the --dry-run option to see exactly what would be removed without actually terminating the deployment or removing any asscoiated items.

[WARNING] This action is irreversible and cannot be undone!

Are you sure you want to terminate my-env/my-type deployment? [y|N] > 
[FATAL] my-env/my-type termination failed!

EOF

};

subtest 'genesis repo-init' => sub {
	plan tests => 17;

	ok(has_command('repo-init'), "repo-init command is registered");
	ok(is_equivalent_command('init' => 'repo-init'), "init is an alias for repo-init");
	like(command_properties('repo-init')->{usage}, qr/repo-init.*\[.*options/, "usage string mentions repo-init and options");

	is(command_properties('repo-init')->{function_group}, Genesis::Commands::REPOSITORY, "repo-init belongs to repository group");
	is(command_properties('repo-init')->{scope}, 'empty', "repo-init has empty scope (no existing repo needed)");

	my %opts = command_properties('repo-init')->{options}->@*;

	# Existing init options preserved
	ok(exists $opts{'kit|k=s'}, "repo-init has --kit option");
	ok(exists $opts{'link-dev-kit|l=s'}, "repo-init has --link-dev-kit option");
	ok(exists $opts{'directory|d=s'}, "repo-init has --directory option");
	ok(exists $opts{'vault=s'}, "repo-init has --vault option");

	# New options
	ok(exists $opts{'sub!'}, "repo-init has toggleable --sub option for subrepo detection");
	ok(exists $opts{'skip-vault'}, "repo-init has --skip-vault option to defer vault config");
	ok(exists $opts{'ci-provider=s'}, "repo-init has --ci-provider option");
	ok(exists $opts{'force|F'}, "repo-init has --force option");

	not_ok(command_properties('repo-init')->{deprecated}, "repo-init is not deprecated");

	my $subref = $Genesis::Commands::RUN{'repo-init'};
	is(ref($subref), 'CODE', "repo-init command has a subroutine reference");
	cmp_deeply(scalar(closed_over($subref)), {
		'$fn' => \'Genesis::Commands::Repo::repo_init',
		'$fn_require' => \'Genesis/Commands/Repo.pm',
		'$name' => \'repo-init',
	}, "repo-init command routes to Repo::repo_init");

	# init alias resolves to repo-init via GENESIS_COMMANDS
	is($Genesis::Commands::GENESIS_COMMANDS{init}, 'repo-init',
		"init alias resolves to repo-init");
};

subtest 'repo-init option processing' => sub {
	plan tests => 18;

	# Basic invocation with kit and name
	prepare_command('repo-init', '-k', 'bosh', 'my-bosh');
	build_command_environment;
	my %opts = %{get_options()};
	my @args = get_args();
	is($opts{kit}, 'bosh', "kit option parsed correctly");
	is($args[0], 'my-bosh', "name argument passed through");

	# With --skip-vault
	prepare_command('repo-init', '-k', 'bosh', '--skip-vault', 'my-bosh');
	build_command_environment;
	%opts = %{get_options()};
	ok($opts{'skip-vault'}, "--skip-vault flag is set");
	ok(!$opts{vault}, "vault is not set when skip-vault used");

	# With --vault
	prepare_command('repo-init', '-k', 'bosh', '--vault', 'my-vault', 'my-bosh');
	build_command_environment;
	%opts = %{get_options()};
	is($opts{vault}, 'my-vault', "--vault value parsed correctly");
	ok(!$opts{'skip-vault'}, "skip-vault not set when vault specified");

	# With --ci-provider
	prepare_command('repo-init', '-k', 'cf', '--ci-provider', 'concourse', 'my-cf');
	build_command_environment;
	%opts = %{get_options()};
	is($opts{'ci-provider'}, 'concourse', "--ci-provider concourse parsed");

	prepare_command('repo-init', '-k', 'cf', '--ci-provider', 'github-actions', 'my-cf');
	build_command_environment;
	%opts = %{get_options()};
	is($opts{'ci-provider'}, 'github-actions', "--ci-provider github-actions parsed");

	prepare_command('repo-init', '-k', 'cf', '--ci-provider', 'manual', 'my-cf');
	build_command_environment;
	%opts = %{get_options()};
	is($opts{'ci-provider'}, 'manual', "--ci-provider manual parsed");

	# With --sub
	prepare_command('repo-init', '-k', 'bosh', '--sub', 'my-bosh');
	build_command_environment;
	%opts = %{get_options()};
	is($opts{sub}, 1, "--sub flag sets sub to true");

	# With --no-sub
	prepare_command('repo-init', '-k', 'bosh', '--no-sub', 'my-bosh');
	build_command_environment;
	%opts = %{get_options()};
	is($opts{sub}, 0, "--no-sub flag sets sub to false");

	# Without --sub (not specified)
	prepare_command('repo-init', '-k', 'bosh', 'my-bosh');
	build_command_environment;
	%opts = %{get_options()};
	ok(!defined($opts{sub}), "sub is undefined when not specified");

	# With --directory
	prepare_command('repo-init', '-k', 'bosh', '-d', '/tmp/my-repo', 'my-bosh');
	build_command_environment;
	%opts = %{get_options()};
	is($opts{directory}, '/tmp/my-repo', "--directory parsed correctly");

	# With --link-dev-kit
	prepare_command('repo-init', '-l', '/path/to/dev-kit', 'my-dev');
	build_command_environment;
	%opts = %{get_options()};
	is($opts{'link-dev-kit'}, '/path/to/dev-kit', "--link-dev-kit parsed correctly");
	ok(!$opts{kit}, "kit not set when link-dev-kit used");

	# Name defaults from kit when not specified
	prepare_command('repo-init', '-k', 'shield');
	build_command_environment;
	@args = get_args();
	is(scalar(@args), 0, "no positional args when name not specified");

	# All options together
	prepare_command('repo-init', '-k', 'bosh', '--ci-provider', 'concourse', '--skip-vault', '--sub', '-d', '/tmp/test', 'my-bosh');
	build_command_environment;
	%opts = %{get_options()};
	@args = get_args();
	is($opts{kit}, 'bosh', "kit parsed in combined invocation");
	is($args[0], 'my-bosh', "name parsed in combined invocation");
};

subtest 'repo-init validation' => sub {
	plan tests => 10;

	require Genesis::Commands::Repo;
	delete $ENV{GENESIS_IGNORE_EVAL}; # Allow bail() to die instead of exit
	$ENV{GIT_AUTHOR_NAME} = 'Test User';
	$ENV{GIT_AUTHOR_EMAIL} = 'test@example.com';
	$ENV{GIT_COMMITTER_NAME} = 'Test User';
	$ENV{GIT_COMMITTER_EMAIL} = 'test@example.com';

	# Setup local kit fixtures for validation tests (no network access)
	my $vt_devkit = workdir('validation-devkit');
	my $vt_tarball = workdir('validation-tarball');
	mkfile_or_fail("$vt_tarball/bosh-0.0.1.tar.gz", "fake kit tarball");

	# Valid cases
	prepare_command('repo-init', '-k', "$vt_tarball/bosh-0.0.1.tar.gz", 'my-bosh');
	build_command_environment;
	lives_ok { Genesis::Commands::Repo::_repo_init_validate() }
		"valid: local kit tarball + name passes";

	prepare_command('repo-init', '-l', $vt_devkit, '--skip-vault', 'my-bosh');
	build_command_environment;
	lives_ok { Genesis::Commands::Repo::_repo_init_validate() }
		"valid: link-dev-kit + skip-vault passes";

	prepare_command('repo-init', '-k', "$vt_tarball/bosh-0.0.1.tar.gz", '--ci-provider', 'concourse', 'my-bosh');
	build_command_environment;
	lives_ok { Genesis::Commands::Repo::_repo_init_validate() }
		"valid: ci-provider concourse passes";

	prepare_command('repo-init', '-l', $vt_devkit, '--ci-provider', 'manual', 'my-bosh');
	build_command_environment;
	lives_ok { Genesis::Commands::Repo::_repo_init_validate() }
		"valid: ci-provider manual passes";

	prepare_command('repo-init', '-k', "$vt_tarball/bosh-0.0.1.tar.gz", '--ci-provider', 'github-actions', 'my-bosh');
	build_command_environment;
	lives_ok { Genesis::Commands::Repo::_repo_init_validate() }
		"valid: ci-provider github-actions passes";

	# Name derived from link-dev-kit when not specified
	prepare_command('repo-init', '-l', $vt_devkit);
	build_command_environment;
	lives_ok { Genesis::Commands::Repo::_repo_init_validate() }
		"valid: name derived from link-dev-kit";

	# Invalid: --vault and --skip-vault together
	prepare_command('repo-init', '-l', $vt_devkit, '--vault', 'my-vault', '--skip-vault', 'my-bosh');
	build_command_environment;
	throws_ok { Genesis::Commands::Repo::_repo_init_validate() }
		qr/Cannot specify both --vault and --skip-vault/,
		"rejects --vault with --skip-vault";

	# Invalid: --kit and --link-dev-kit together
	prepare_command('repo-init', '-k', "$vt_tarball/bosh-0.0.1.tar.gz", '-l', $vt_devkit, 'my-bosh');
	build_command_environment;
	throws_ok { Genesis::Commands::Repo::_repo_init_validate() }
		qr/only specify one of kit.*or link/i,
		"rejects --kit with --link-dev-kit";

	# Invalid: no name, no kit, no link-dev-kit
	prepare_command('repo-init');
	build_command_environment;
	throws_ok { Genesis::Commands::Repo::_repo_init_validate() }
		qr/must specify a deployment name/i,
		"rejects empty invocation";

	# Invalid: bad ci-provider value
	prepare_command('repo-init', '-l', $vt_devkit, '--ci-provider', 'jenkins', 'my-bosh');
	build_command_environment;
	throws_ok { Genesis::Commands::Repo::_repo_init_validate() }
		qr/Invalid --ci-provider 'jenkins'/,
		"rejects invalid ci-provider value";
};

subtest 'repo-init execution (integration)' => sub {
	plan tests => 56;

	require Genesis::Commands::Repo;
	local $Genesis::VERSION = '3.2.0-rc2';
	delete $ENV{GENESIS_IGNORE_EVAL};
	$ENV{GIT_AUTHOR_NAME} = 'Test User';
	$ENV{GIT_AUTHOR_EMAIL} = 'test@example.com';
	$ENV{GIT_COMMITTER_NAME} = 'Test User';
	$ENV{GIT_COMMITTER_EMAIL} = 'test@example.com';

	# Local kit fixtures (no network access)
	my $devkit = Cwd::abs_path('t/src/simple');
	my $kit_tarball = Cwd::abs_path('t/repos/compiled-kit-test/.genesis/kits/compiled-0.0.1.tar.gz');

	# Test 1: Basic --sub --skip-vault creates directory without .git
	my $basedir = workdir('repo-init-test-1');
	pushd($basedir);
	# Init a git repo so --sub detection works
	run('git init 2>/dev/null');

	prepare_command('repo-init', '-l', $devkit, '--sub', '--skip-vault', 'bosh');
	build_command_environment;
Genesis::Commands::Repo::_repo_init_validate();
	my $result = Genesis::Commands::Repo::_repo_init_execute();

	ok(-d "$basedir/bosh", "bosh directory created");
	ok(-d "$basedir/bosh/.genesis", ".genesis directory created");
	ok(-f "$basedir/bosh/.genesis/config", ".genesis/config created");
	ok(!-e "$basedir/bosh/.git", "no .git in subdirectory mode");
	ok(-l "$basedir/bosh/dev", "dev symlink created for linked dev kit");
	ok(!-d "$basedir/bosh/.genesis/bin", "no .genesis/bin without CI provider");

	# Verify config has no secrets_provider
	my $config_text = slurp("$basedir/bosh/.genesis/config");
	unlike($config_text, qr/secrets_provider/, "config has no secrets_provider when skip-vault");
	like($config_text, qr/deployment_type: bosh/, "config has correct deployment_type");

	# Verify result hash
	is($result->{name}, 'bosh', "result name is bosh");
	ok($result->{vault_skipped}, "result vault_skipped is true");
	ok(!$result->{vault}, "result vault is undef");
	ok($result->{submodule}, "result submodule is true");
	popd;

	# Test 2: --no-sub creates .git (using kit tarball)
	my $basedir2 = workdir('repo-init-test-2');
	pushd($basedir2);
	run('git init 2>/dev/null');

	prepare_command('repo-init', '-k', $kit_tarball, '--no-sub', '--skip-vault', 'bosh');
	build_command_environment;
	Genesis::Commands::Repo::_repo_init_validate();
	my $result2 = Genesis::Commands::Repo::_repo_init_execute();

	ok(-d "$basedir2/bosh/.git", ".git created in --no-sub mode");
	ok(!$result2->{submodule}, "result submodule is false");
	popd;

	# Test 3: --force replaces existing directory
	my $basedir3 = workdir('repo-init-test-3');
	pushd($basedir3);
	mkdir_or_fail("$basedir3/bosh");
	mkfile_or_fail("$basedir3/bosh/sentinel.txt", "should be removed");

	prepare_command('repo-init', '-l', $devkit, '--no-sub', '--skip-vault', '-F', 'bosh');
	build_command_environment;
	Genesis::Commands::Repo::_repo_init_validate();
	my $result3 = Genesis::Commands::Repo::_repo_init_execute();

	ok(-d "$basedir3/bosh/.genesis", ".genesis created after force replace");
	ok(!-f "$basedir3/bosh/sentinel.txt", "old sentinel file removed by force");
	popd;

	# Test 4: Name derived from link-dev-kit basename
	my $basedir4 = workdir('repo-init-test-4');
	pushd($basedir4);

	prepare_command('repo-init', '-l', $devkit, '--no-sub', '--skip-vault');
	build_command_environment;
	Genesis::Commands::Repo::_repo_init_validate();
	my $result4 = Genesis::Commands::Repo::_repo_init_execute();

	ok(-d "$basedir4/simple/.genesis", "directory named from dev-kit basename");
	is($result4->{name}, 'simple', "name derived from dev-kit");
	popd;

	# Test 5: Existing directory without --force bails (non-interactive)
	my $basedir5 = workdir('repo-init-test-5');
	pushd($basedir5);
	mkdir_or_fail("$basedir5/bosh");

	prepare_command('repo-init', '-l', $devkit, '--no-sub', '--skip-vault', 'bosh');
	build_command_environment;
	throws_ok {
		Genesis::Commands::Repo::_repo_init_validate();
	} qr/already exists.*-F/i,
		"bails on existing directory in non-interactive mode";
	popd;

	# Test 6: Custom --directory (using kit tarball)
	my $basedir6 = workdir('repo-init-test-6');
	pushd($basedir6);

	prepare_command('repo-init', '-k', $kit_tarball, '--no-sub', '--skip-vault', '-d', 'my-custom-dir', 'bosh');
	build_command_environment;
	Genesis::Commands::Repo::_repo_init_validate();
	my $result6 = Genesis::Commands::Repo::_repo_init_execute();

	ok(-d "$basedir6/my-custom-dir/.genesis", "custom directory created via --directory");
	ok(!-e "$basedir6/bosh", "default 'bosh' directory not created when --directory used");
	my $cfg6 = slurp("$basedir6/my-custom-dir/.genesis/config");
	like($cfg6, qr/deployment_type: bosh/, "config deployment_type is still bosh despite custom dir name");
	popd;

	# Test 7: Custom name different from kit
	my $basedir7 = workdir('repo-init-test-7');
	pushd($basedir7);

	prepare_command('repo-init', '-l', $devkit, '--no-sub', '--skip-vault', 'my-boshen');
	build_command_environment;
	Genesis::Commands::Repo::_repo_init_validate();
	my $result7 = Genesis::Commands::Repo::_repo_init_execute();

	ok(-d "$basedir7/my-boshen/.genesis", "directory uses custom name, not kit name");
	ok(!-e "$basedir7/simple", "default dev-kit name directory not created");
	is($result7->{name}, 'my-boshen', "result name matches custom name");
	my $cfg7 = slurp("$basedir7/my-boshen/.genesis/config");
	like($cfg7, qr/deployment_type: my-boshen/, "config deployment_type uses custom name");
	popd;

	# Test 8: --link-dev-kit creates symlink
	my $basedir8 = workdir('repo-init-test-8');
	my $devkit_dir = workdir('repo-init-test-8-devkit');
	mkdir_or_fail("$devkit_dir/hooks");
	mkfile_or_fail("$devkit_dir/kit.yml", "name: testkit\nversion: 0.0.1\n");
	pushd($basedir8);

	prepare_command('repo-init', '-l', $devkit_dir, '--no-sub', '--skip-vault', 'my-devkit');
	build_command_environment;
Genesis::Commands::Repo::_repo_init_validate();
	my $result8 = Genesis::Commands::Repo::_repo_init_execute();

	ok(-d "$basedir8/my-devkit/.genesis", ".genesis created for linked dev kit");
	ok(-l "$basedir8/my-devkit/dev", "dev is a symlink");
	is(Cwd::abs_path(readlink("$basedir8/my-devkit/dev")), Cwd::abs_path($devkit_dir), "dev symlink points to correct target");
	like($result8->{kit_desc}, qr/linked.*kit/i, "result kit_desc mentions linked kit");
	popd;

	# Test 9: Auto-detect git repo → subdirectory mode (no --sub flag)
	my $basedir9a = workdir('repo-init-test-9a');
	pushd($basedir9a);
	run('git init 2>/dev/null');

	prepare_command('repo-init', '-l', $devkit, '--skip-vault', 'bosh');
	build_command_environment;
	Genesis::Commands::Repo::_repo_init_validate();
	my $result9a = Genesis::Commands::Repo::_repo_init_execute();

	ok(!-e "$basedir9a/bosh/.git", "auto-detected git repo: no .git created");
	ok($result9a->{submodule}, "auto-detected git repo: result submodule is true");
	popd;

	# Test 10: Outside git repo without --sub → standalone with .git
	my $basedir10 = workdir('repo-init-test-10');
	pushd($basedir10);
	# Do NOT run git init — this is not a git repo

	prepare_command('repo-init', '-l', $devkit, '--skip-vault', 'bosh');
	build_command_environment;
	Genesis::Commands::Repo::_repo_init_validate();
	my $result10 = Genesis::Commands::Repo::_repo_init_execute();

	ok(-d "$basedir10/bosh/.git", "outside git repo: .git created");
	ok(!$result10->{submodule}, "outside git repo: result submodule is false");
	popd;

	# Test 11: Config values are correct (using kit tarball)
	my $basedir11 = workdir('repo-init-test-11');
	pushd($basedir11);

	prepare_command('repo-init', '-k', $kit_tarball, '--no-sub', '--skip-vault', 'my-cf');
	build_command_environment;
	Genesis::Commands::Repo::_repo_init_validate();
	my $result11 = Genesis::Commands::Repo::_repo_init_execute();

	my $cfg11 = slurp("$basedir11/my-cf/.genesis/config");
	like($cfg11, qr/deployment_type: my-cf/, "config has deployment_type: my-cf");
	like($cfg11, qr/version: 2/, "config has version: 2");
	like($cfg11, qr/creator_version: 3\.2\.0-rc2/, "config has correct creator_version");
	like($cfg11, qr/minimum_version: 3\.2\.0-rc2/, "config has minimum_version");
	like($cfg11, qr/manifest_store: exodus/, "config has manifest_store: exodus");
	unlike($cfg11, qr/secrets_provider/, "config has no secrets_provider when skip-vault");
	unlike($cfg11, qr/kit_provider/, "config has no kit_provider (using default genesis-community)");
	popd;

	# Test 12: --ci-provider concourse writes config and creates ci dir
	my $basedir12 = workdir('repo-init-test-12');
	pushd($basedir12);

	prepare_command('repo-init', '-l', $devkit, '--no-sub', '--skip-vault', '--ci-provider', 'concourse', 'bosh');
	build_command_environment;
	Genesis::Commands::Repo::_repo_init_validate();
	my $result12 = Genesis::Commands::Repo::_repo_init_execute();

	my $cfg12 = slurp("$basedir12/bosh/.genesis/config");
	like($cfg12, qr/ci:/, "concourse: config has ci: section");
	like($cfg12, qr/type: concourse/, "concourse: ci.provider.type set");
	like($cfg12, qr/enabled: true/, "concourse: ci.enabled is true");
	like($cfg12, qr/name: bosh/, "concourse: ci.pipeline.name matches deployment type");
	ok(-d "$basedir12/bosh/.genesis/ci", "concourse: .genesis/ci/ directory created");
	ok(-d "$basedir12/bosh/.genesis/bin", "concourse: genesis binary embedded for pipeline");
	is($result12->{ci_provider}, 'concourse', "concourse: result ci_provider correct");
	popd;

	# Test 13: --ci-provider manual
	my $basedir13 = workdir('repo-init-test-13');
	pushd($basedir13);

	prepare_command('repo-init', '-k', $kit_tarball, '--no-sub', '--skip-vault', '--ci-provider', 'manual', 'my-cf');
	build_command_environment;
	Genesis::Commands::Repo::_repo_init_validate();
	my $result13 = Genesis::Commands::Repo::_repo_init_execute();

	my $cfg13 = slurp("$basedir13/my-cf/.genesis/config");
	like($cfg13, qr/type: manual/, "manual: ci.provider.type set");
	ok(-d "$basedir13/my-cf/.genesis/ci", "manual: .genesis/ci/ directory created");
	is($result13->{ci_provider}, 'manual', "manual: result ci_provider correct");
	popd;

	# Test 14: --ci-provider github-actions
	my $basedir14 = workdir('repo-init-test-14');
	pushd($basedir14);

	prepare_command('repo-init', '-l', $devkit, '--no-sub', '--skip-vault', '--ci-provider', 'github-actions', 'bosh');
	build_command_environment;
	Genesis::Commands::Repo::_repo_init_validate();
	my $result14 = Genesis::Commands::Repo::_repo_init_execute();

	my $cfg14 = slurp("$basedir14/bosh/.genesis/config");
	like($cfg14, qr/type: github-actions/, "github-actions: ci.provider.type set");
	is($result14->{ci_provider}, 'github-actions', "github-actions: result ci_provider correct");
	popd;

	# Test 15: No --ci-provider → no ci: in config, no .genesis/ci/
	my $basedir15 = workdir('repo-init-test-15');
	pushd($basedir15);

	prepare_command('repo-init', '-l', $devkit, '--no-sub', '--skip-vault', 'bosh');
	build_command_environment;
	Genesis::Commands::Repo::_repo_init_validate();
	my $result15 = Genesis::Commands::Repo::_repo_init_execute();

	my $cfg15 = slurp("$basedir15/bosh/.genesis/config");
	unlike($cfg15, qr/^ci:/m, "no-provider: config has no ci: section");
	ok(!-d "$basedir15/bosh/.genesis/ci", "no-provider: no .genesis/ci/ directory");
	ok(!$result15->{ci_provider}, "no-provider: result ci_provider is undef");
	popd;
};

done_testing;
