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
use Cwd qw/cwd abs_path/;
use Time::Piece;

# Initialize Genesis
use_ok 'Genesis::Config';
$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");

use_ok 'Genesis::Env';
use Service::BOSH;
use Genesis::Top;
use Genesis::Env;
use Genesis;

# BOSH mock setup
local $ENV{BOSH_NON_INTERACTIVE} = 1;
local $ENV{GENESIS_BOSH_COMMAND};
write_bosh_config 'standalone';
my ($director1) = fake_bosh_directors(
    {alias => 'standalone'},
);
fake_bosh;

# Environment setup
$ENV{GENESIS_CALLBACK_BIN} ||= abs_path('bin/genesis');
$ENV{GENESIS_LIB} ||= abs_path('lib');
$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;

sub reset_exodus_data {
	my $env = shift;
	my $action = scalar(@_) % 2 ? shift : 'deploy';
	my %overrides = @_;

	note "-- resetting exodus data for ".$env->name;

	$action //= 'deploy';
	$env->vault->clear($env->exodus_base,1);

	# Write exodus data directly to vault (bypass update_deployment_exodus
	# which tries to extract manifest data for 'deploy' actions)
	$env->vault->query('set', $env->exodus_base,
		'deployer=test-user',
		'dated=2024-12-06 01:23:45 +0000',
		'completed=2024-12-06 11:23:58 +0000',
		'kit_name=dev',
		'kit_version=latest',
		'kit_is_dev=1',
	);

	# Write deployment audit entry directly to vault using 'state' field
	# which triggers the sanitize path in Deployment->new (fills defaults
	# for kit, user, manifest, etc.)
	my $timestamp = Time::Piece->new->strftime('%Y%m%d%H%M%S');
	my $state = ($action eq 'deploy') ? 'deployed' : 'terminated';
	my $reason = exists $overrides{reason} ? $overrides{reason} : 'test';
	my $deploy_path = $env->exodus_base.'/deployments/'.$timestamp;
	$env->vault->query('set', $deploy_path,
		"state=$state",
		"genesis_version=$Genesis::VERSION",
		"started=2024-12-06 01:23:45 +0000",
		"completed=2024-12-06 11:23:58 +0000",
		"timestamp=$timestamp",
		"sequence=1",
		"reason=$reason",
	);
	$env->vault->set($env->exodus_base, 'sequence', 1);

	# Set up deployment cache
	my $filemap = $env->deployment_cache_setup('preserve');
	mkfile_or_fail($filemap->{$_}, "Contents of $_ file")
		for (grep {! -f $filemap->{$_}} keys %$filemap);

	$env->deployments->reset;
	delete $env->{deployment_state};
}

sub reset_secrets {
    my ($env) = @_;
    note "-- resetting secrets for ".$env->name;
    $env->{__secrets_plan} = undef;
    $env->{__secrets_store} = undef;
    $env->vault->set($env->secrets_base.'super_secrets','password', 'super-secret-password');
    quietly {$env->add_secrets()};
}

subtest 'genesis env secrets workflow' => sub {
    plan tests => 9;

    my $vault_target = vault_ok;
    Service::Vault->clear_all();

    my $top = Genesis::Top->create(workdir, 'secrets-test', vault => $VAULT_URL);
    cp_kit('t/src/simple', $top);
    put_file $top->path("secrets-test.yml"), <<'EOF';
---
kit:
  name:   dev
  version: latest
  features: []
  overrides:
    certificates:
      base:
        test_cert:
          ca:
            valid_for: 1h
          server:
            names:
            - test-server-cert
            valid_for: 1h
    credentials:
      base:
        test_cred:
          username: uuid
          password: random 40
    provided:
      base:
        super_secrets:
          type: generic
          keys:
            password:
              prompt: "Enter the super secret password"
              type: string

genesis:
  env: secrets-test
  bosh_env: standalone
  min_version: 3.1.0-rc.20
EOF

    put_file $top->path(".cloud.yml"), <<'EOF';
--- {}
# not really a cloud config, but close enough
EOF

    my $env;
    lives_ok {
        $env = $top->load_env('secrets-test')
    } "secrets-test environment loaded";

    # Configure env for testing
    $env->top->config->set('manifest_store','hybrid');
    $env->use_config($top->path(".cloud.yml"));
    $Genesis::VERSION = '3.1.0-rc.20';

    # ----------------------------------------------------------------
    # Subtest 1: secrets_plan construction
    # ----------------------------------------------------------------
    subtest 'secrets_plan construction' => sub {
        plan tests => 6;

        # Pre-set the user-provided secret so plan construction succeeds
        quietly {
            $env->vault->set($env->secrets_base.'super_secrets', 'password', 'super-secret-password');
        };
        $env->{__secrets_plan} = undef;
        $env->{__secrets_store} = undef;

        my $plan;
        lives_ok {
            quietly { $plan = $env->secrets_plan(no_validate => 1) };
        } "secrets_plan() does not die";

        isa_ok($plan, 'Genesis::Env::Secrets::Plan',
            "secrets_plan returns a Genesis::Env::Secrets::Plan");

        my @secrets = $plan->secrets;
        ok(scalar(@secrets) > 0,
            "plan->secrets returns a non-empty list (".scalar(@secrets)." secrets)");

        my @types = map { $_->type } @secrets;
        ok(grep({ $_ eq 'x509' } @types),
            "plan includes at least one x509 certificate secret");

        ok(grep({ $_ =~ /random|password/ } @types)
            || grep({ $_->isa('Genesis::Secret::Random') } @secrets),
            "plan includes at least one random/credential secret");

        # Verify paths are populated
        my @paths = $plan->paths;
        ok(scalar(@paths) > 0,
            "plan->paths returns a non-empty list (".scalar(@paths)." paths)");
    };

    # ----------------------------------------------------------------
    # Subtest 2: add_secrets generates missing secrets
    # ----------------------------------------------------------------
    subtest 'add_secrets generates missing secrets' => sub {
        plan tests => 5;

        # Start with a clean vault state for this env
        quietly {
            $env->vault->clear($env->secrets_base, 1);
        };
        $env->{__secrets_plan} = undef;
        $env->{__secrets_store} = undef;

        # Set only the user-provided secret; all generated ones should be absent
        $env->vault->set($env->secrets_base.'super_secrets', 'password', 'super-secret-password');

        # Verify at least one generated secret is missing before add_secrets
        my @present_before;
        quietly {
            $env->{__secrets_plan} = undef;
            $env->{__secrets_store} = undef;
            @present_before = grep { $_->exists } $env->secrets_plan(no_validate => 1)->secrets;
        };
        ok(scalar(@present_before) < 5,
            "before add_secrets: not all secrets are present (".scalar(@present_before)." present)");

        # Call add_secrets (suppress output)
        my $result;
        lives_ok {
            quietly { $result = $env->add_secrets() };
        } "add_secrets() does not die";

        ok(defined($result), "add_secrets returns a defined result");
        # add_secrets returns a boolean (1/0) in scalar context, not a hashref;
        # {empty=>1} is only returned on early-exit when there are no secrets at all.
        ok($result, "add_secrets result indicates success (secrets were added)");

        # Verify all secrets are now present
        $env->{__secrets_plan} = undef;
        $env->{__secrets_store} = undef;
        my @present_after;
        quietly {
            @present_after = grep { $_->exists } $env->secrets_plan(no_validate => 1)->secrets;
        };
        is(scalar(@present_after), 5,
            "after add_secrets: all 5 secrets present in vault");
    };

    # ----------------------------------------------------------------
    # Subtest 3: check_secrets reports presence and absence
    # ----------------------------------------------------------------
    subtest 'check_secrets reports presence and absence' => sub {
        plan tests => 6;

        reset_secrets($env);

        # All secrets present -> check_secrets should succeed
        my ($results, $msg);
        lives_ok {
            quietly { ($results, $msg) = $env->check_secrets() };
        } "check_secrets() does not die when all secrets present";

        ok(defined($results), "check_secrets returns a defined results hashref");
        ok(!$results->{empty}, "check_secrets result is not empty when secrets exist");

        my $missing_count = $results->{missing} // 0;
        is($missing_count, 0,
            "check_secrets reports 0 missing secrets when all are present");

        # Remove a generated secret so check detects it missing
        quietly {
            $env->vault->clear($env->secrets_base.'test_cred', 1);
        };
        $env->{__secrets_plan} = undef;
        $env->{__secrets_store} = undef;

        my ($results2, $msg2);
        lives_ok {
            quietly { ($results2, $msg2) = $env->check_secrets() };
        } "check_secrets() does not die when secrets are missing";

        my $missing2 = $results2->{missing} // 0;
        ok($missing2 > 0,
            "check_secrets reports missing count > 0 after removing test_cred ($missing2 missing)");
    };

    # ----------------------------------------------------------------
    # Subtest 4: rotate_secrets regenerates generated values
    # ----------------------------------------------------------------
    subtest 'rotate_secrets regenerates generated values' => sub {
        plan tests => 5;

        reset_secrets($env);

        # Record original credential value (random password)
        my $original_password = $env->vault->get(
            $env->secrets_base.'test_cred', 'password'
        );
        ok(defined($original_password),
            "original test_cred:password is present in vault");

        # Record original user-provided secret value
        my $original_user_secret = $env->vault->get(
            $env->secrets_base.'super_secrets', 'password'
        );
        ok(defined($original_user_secret),
            "original super_secrets:password is present in vault");

        # Rotate secrets (no prompt, no terminal needed)
        $env->{__secrets_plan} = undef;
        $env->{__secrets_store} = undef;
        lives_ok {
            quietly { $env->rotate_secrets('no-prompt' => 1) };
        } "rotate_secrets() does not die";

        # Verify the generated credential was rotated (value changed)
        $env->{__secrets_plan} = undef;
        $env->{__secrets_store} = undef;
        my $new_password = $env->vault->get(
            $env->secrets_base.'test_cred', 'password'
        );
        isnt($new_password, $original_password,
            "test_cred:password was rotated to a new value");

        # Verify user-provided secret was NOT rotated
        my $new_user_secret = $env->vault->get(
            $env->secrets_base.'super_secrets', 'password'
        );
        is($new_user_secret, $original_user_secret,
            "user-provided super_secrets:password was NOT rotated");
    };

    # ----------------------------------------------------------------
    # Subtest 5: remove_secrets removes generated secrets
    # ----------------------------------------------------------------
    subtest 'remove_secrets removes generated secrets' => sub {
        plan tests => 4;

        reset_secrets($env);

        # Verify all 5 secrets are present before removal
        $env->{__secrets_plan} = undef;
        $env->{__secrets_store} = undef;
        my @before;
        quietly {
            @before = grep { $_->exists } $env->secrets_plan(no_validate => 1)->secrets;
        };
        is(scalar(@before), 5,
            "all 5 secrets present before remove_secrets");

        # Remove all secrets via the all => 1, no-prompt path
        my $result;
        lives_ok {
            quietly { $result = $env->remove_secrets(all => 1, 'no-prompt' => 1) };
        } "remove_secrets(all => 1, 'no-prompt' => 1) does not die";

        ok(defined($result), "remove_secrets returns a defined result");

        # Verify all secrets are now gone
        $env->{__secrets_plan} = undef;
        $env->{__secrets_store} = undef;
        my @after;
        quietly {
            @after = grep { $_->exists } $env->secrets_plan(no_validate => 1)->secrets;
        };
        is(scalar(@after), 0,
            "all secrets removed from vault after remove_secrets(all => 1)");
    };

    # ----------------------------------------------------------------
    # Subtest 6: full secrets lifecycle end-to-end
    # ----------------------------------------------------------------
    subtest 'full secrets lifecycle end-to-end' => sub {
        plan tests => 10;

        # Start from a clean state
        quietly { $env->vault->clear($env->secrets_base, 1) };
        $env->{__secrets_plan} = undef;
        $env->{__secrets_store} = undef;

        # Step 1: add secrets (vault is empty except user-provided seed)
        $env->vault->set($env->secrets_base.'super_secrets', 'password', 'super-secret-password');
        my $add_result;
        lives_ok {
            quietly { $add_result = $env->add_secrets() };
        } "step 1: add_secrets succeeds on empty vault";

        $env->{__secrets_plan} = undef;
        $env->{__secrets_store} = undef;
        my @present;
        quietly {
            @present = grep { $_->exists } $env->secrets_plan(no_validate => 1)->secrets;
        };
        is(scalar(@present), 5,
            "step 1: all 5 secrets present after add");

        # Step 2: check passes
        my ($check_result, $check_msg);
        lives_ok {
            $env->{__secrets_plan} = undef;
            $env->{__secrets_store} = undef;
            quietly { ($check_result, $check_msg) = $env->check_secrets() };
        } "step 2: check_secrets succeeds";
        is($check_result->{missing} // 0, 0,
            "step 2: check reports 0 missing");

        # Step 3: remove one generated secret -> check detects it missing
        quietly { $env->vault->clear($env->secrets_base.'test_cred', 1) };
        $env->{__secrets_plan} = undef;
        $env->{__secrets_store} = undef;
        my ($check2);
        quietly { ($check2) = $env->check_secrets() };
        ok(($check2->{missing} // 0) > 0,
            "step 3: check detects missing after removing test_cred");

        # Step 4: add again to fill the gap
        $env->{__secrets_plan} = undef;
        $env->{__secrets_store} = undef;
        lives_ok {
            quietly { $env->add_secrets() };
        } "step 4: add_secrets again fills missing secret";

        $env->{__secrets_plan} = undef;
        $env->{__secrets_store} = undef;
        my ($check3);
        quietly { ($check3) = $env->check_secrets() };
        is($check3->{missing} // 0, 0,
            "step 4: check passes again after re-adding");

        # Step 5: rotate secrets
        $env->{__secrets_plan} = undef;
        $env->{__secrets_store} = undef;
        lives_ok {
            quietly { $env->rotate_secrets('no-prompt' => 1) };
        } "step 5: rotate_secrets succeeds";

        # Step 6: remove all secrets
        $env->{__secrets_plan} = undef;
        $env->{__secrets_store} = undef;
        my $remove_result;
        lives_ok {
            quietly { $remove_result = $env->remove_secrets(all => 1, 'no-prompt' => 1) };
        } "step 6: remove_secrets(all) succeeds";

        $env->{__secrets_plan} = undef;
        $env->{__secrets_store} = undef;
        my @final;
        quietly {
            @final = grep { $_->exists } $env->secrets_plan(no_validate => 1)->secrets;
        };
        is(scalar(@final), 0,
            "step 6: vault is empty after remove_secrets(all)");
    };

    # ----------------------------------------------------------------
    # Subtest 7: secrets_base and secrets_store path construction
    # ----------------------------------------------------------------
    subtest 'secrets_base and secrets_store path construction' => sub {
        plan tests => 6;

        # secrets_base returns a string with a trailing slash
        my $base = $env->secrets_base;
        ok(defined($base), "secrets_base returns a defined value");
        like($base, qr|^/secret/|,
            "secrets_base begins with /secret/");
        like($base, qr|/$|,
            "secrets_base has a trailing slash");

        # The env name 'secrets-test' with top type 'secrets-test' maps to
        # secrets/test/secrets-test/ under /secret/
        like($base, qr|secrets|,
            "secrets_base path contains the environment name components");

        # secrets_store returns the correct class
        my $store = $env->secrets_store;
        ok(defined($store),
            "secrets_store returns a defined store object");
        isa_ok($store, 'Genesis::Env::Secrets::Store::Vault',
            "secrets_store returns a Vault-backed store");
    };
};

teardown_vault;
done_testing;
