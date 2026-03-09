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

done_testing;
