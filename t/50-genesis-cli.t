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

use Genesis::Commands;
use PadWalker qw/closed_over/;
use Genesis;

# Initialize the Genesis environment
# dont need a vault yet? : my $vault_target = vault_ok();
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;

subtest 'bin/genesis' => sub {

    require_ok './bin/genesis';

    # TODO: Add tests to make sure all the defined commands are valid in their definitions in general (ie: specify existing function groups, correct format of options, etc)

};

subtest 'genesis terminate' => sub {
    plan tests => 3;

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
    ok(exists $terminate_opts{'force|f'}, "terminate has force option");
    ok(exists $terminate_opts{'yes|y'}, "terminate has yes (no-prompt) option");
    ok(exists $terminate_opts{'dry-run|n'}, "terminate has dry-run option");

    is(scalar(keys %terminate_opts), 3, "terminate only has the 3 options above");

    not_ok(command_properties('terminate')->{deprecated}, "terminate command is not deprecated");

    my $subref = $Genesis::Commands::RUN{terminate};
    is(ref($subref), 'CODE', "terminate command has a subroutine reference");
    cmp_deeply(scalar(closed_over($subref)), {
        '$fn' => \'Genesis::Commands::Env::terminate',
        '$fn_require' => \'Genesis/Commands/Env.pm',
        '$name' => \'terminate',
    }, "terminate command subroutine has the correct closed-over variables");
};

=defer
subtest 'Command Registration' => sub {
    plan tests => 4;

    # Test core commands exist
    ok(has_command('help'), "Help command is registered");
    ok(has_command('version'), "Version command is registered");

    # Test command aliasing
    ok(equivalent_commands('deploy', 'd'), "deploy command aliases to 'd'");
    ok(equivalent_commands('env-shell', 'sh'), "env-shell command aliases to 'sh'");
};

subtest 'Command Properties' => sub {
    plan tests => 6;

    my $props = command_properties('version');
    ok($props->{skip_check_prereqs}, "Version command skips prereq checks");
    ok(!$props->{no_vault}, "Version command does not disable vault");

    $props = command_properties('init');
    is($props->{function_group}, Genesis::Commands::REPOSITORY, "Init command belongs to repository group");
    is($props->{scope}, 'empty', "Init command has empty scope");

    $props = command_properties('deploy');
    is($props->{scope}, 'env', "Deploy command has env scope");
    ok($props->{option_group} eq Genesis::Commands::ENV_OPTIONS, "Deploy command uses ENV_OPTIONS");
};

subtest 'Command Options' => sub {
    plan tests => 5;

    my $fetch_kit_opts = command_properties('fetch-kit')->{options};
    ok(exists $fetch_kit_opts->{'force|f'}, "fetch-kit has force option");

    my $rotate_opts = command_properties('rotate-secrets')->{options};
    ok(exists $rotate_opts->{'no-prompt|y'}, "rotate-secrets has no-prompt option");
    ok(exists $rotate_opts->{'regen-x509-keys'}, "rotate-secrets has regen-x509-keys option");

    my $deploy_opts = command_properties('deploy')->{options};
    ok(exists $deploy_opts->{'dry-run|n'}, "deploy has dry-run option");
    ok(exists $deploy_opts->{'recreate'}, "deploy has recreate option");
};

subtest 'Command Groups' => sub {
    plan tests => 4;

    my @repo_cmds = grep {
        command_properties($_)->{function_group} eq Genesis::Commands::REPOSITORY
    } list_commands();

    ok(scalar(@repo_cmds) > 0, "Found repository management commands");

    my @env_cmds = grep {
        command_properties($_)->{function_group} eq Genesis::Commands::ENVIRONMENT
    } list_commands();

    ok(scalar(@env_cmds) > 0, "Found environment management commands");

    my @kit_cmds = grep {
        command_properties($_)->{function_group} eq Genesis::Commands::KIT
    } list_commands();

    ok(scalar(@kit_cmds) > 0, "Found kit management commands");

    my @pipeline_cmds = grep {
        command_properties($_)->{function_group} eq Genesis::Commands::PIPELINE
    } list_commands();

    ok(scalar(@pipeline_cmds) > 0, "Found pipeline management commands");
};

subtest 'Command Variables' => sub {
    plan tests => 3;

    my $vars = command_properties('ci-pipeline-deploy')->{variables};
    ok(grep({$_ eq 'CURRENT_ENV'} @$vars), "ci-pipeline-deploy defines CURRENT_ENV var");
    ok(grep({$_ eq 'VAULT_ADDR'} @$vars), "ci-pipeline-deploy defines VAULT_ADDR var");
    ok(grep({$_ eq 'GIT_BRANCH'} @$vars), "ci-pipeline-deploy defines GIT_BRANCH var");
};

subtest 'Deprecated Commands' => sub {
    plan tests => 2;

    my $props = command_properties('download');
    is($props->{deprecated}, 'fetch-kit', "download command is deprecated in favor of fetch-kit");
    is($props->{function_group}, Genesis::Commands::DEPRECATED, "download command is in deprecated group");
};

teardown_vault();
=cut

done_testing;
