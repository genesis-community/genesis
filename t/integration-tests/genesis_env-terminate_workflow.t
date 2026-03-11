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

# Disable the 'script' pseudo-tty wrapper that BOSH::execute uses for
# interactive commands.  Without a controlling terminal (e.g., under prove)
# macOS 'script' fails with "tcgetattr/ioctl: Operation not supported on
# socket" and the underlying bosh command never runs.  Force interactive => 0
# so fake_bosh output goes straight to stdout.
{
	no warnings 'redefine';
	my $orig_execute = \&Service::BOSH::execute;
	*Service::BOSH::execute = sub {
		my ($self, @cmd) = @_;
		if (ref($cmd[0]) eq 'HASH') {
			$cmd[0]->{interactive} = 0;
		}
		return $orig_execute->($self, @cmd);
	};
}

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
	#
	# Use a 2024 base timestamp (always older than the 2025 terminate dates
	# used in assertions) but increment the seconds to ensure uniqueness
	# across repeated reset_exodus_data calls within a single test run.
	our $RESET_EXODUS_SEQ //= 0;
	$RESET_EXODUS_SEQ++;
	my $timestamp = exists $overrides{timestamp}
		? delete $overrides{timestamp}
		: sprintf('20241206%06d', $RESET_EXODUS_SEQ);
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

# deployment_lookup - test helper wrapping the DeploymentManager API
# scalar context returns the count of all deployments;
# 'latest' returns the most recent deployment as a plain hashref.
sub deployment_lookup {
	my ($env, $what) = @_;
	my @all = $env->deployments->all;
	return scalar(@all) unless defined $what;
	return undef unless @all;
	if ($what eq 'latest') {
		my $d = $all[0];
		my %h = %{$d->{data}};
		# Convert Time::Piece objects back to strings for easy comparison
		$h{completed} = $h{completed}->strftime('%Y-%m-%d %H:%M:%S %z')
			if ref($h{completed}) eq 'Time::Piece';
		$h{started} = $h{started}->strftime('%Y-%m-%d %H:%M:%S %z')
			if ref($h{started}) eq 'Time::Piece';
		$h{timestamp} = $d->{timestamp};
		return \%h;
	}
	return undef;
}

sub reset_secrets {
	my ($env) = @_;
	note "-- resetting secrets for ".$env->name;
	$env->{__secrets_plan} = undef;
	$env->{__secrets_store} = undef;
  $env->vault->set($env->secrets_base.'super_secrets','password', 'super-secret-password');
	quietly {$env->add_secrets()};
}

subtest 'terminate workflow' => sub {
	plan tests => 8;

	my $vault_target = vault_ok;
	Service::Vault->clear_all();

	my $top = Genesis::Top->create(workdir, 'terminate-test', vault => $VAULT_URL);
	cp_kit('t/src/simple', $top);
	put_file $top->path("termination-test.yml"), <<EOF;
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
  env: termination-test
  bosh_env: standalone
  min_version: 3.1.0
EOF

	put_file $top->path(".cloud.yml"), "--- {}\n# not really a cloud config, but close enough\n";

	my $env;
	lives_ok {
		$env = $top->load_env('termination-test')
	} "termination test environment loaded";

	# Setup secrets in the vault
	quietly {
		lives_ok {
			$env->vault->set($env->secrets_base.'super_secrets', 'password', 'super-secret-password');
			$env->add_secrets();
		} "secrets added to vault";
	};

	# Configure env for testing
	# manifest_store() reads 'manifest_store' (not 'genesis.manifest_store') from config
	$env->top->config->set('manifest_store','hybrid');
	$env->use_config($top->path(".cloud.yml"));
	$Genesis::VERSION = '3.1.0-rc.20';

	# Write BOSH director exodus data to vault so that $env->bosh has exodus_path set.
	# Without this, get_network_claims() in terminate() dies with "No exodus path set for
	# BOSH director" because from_alias() (the fallback) creates a director without exodus_path.
	quietly {
		$env->vault->query('set', 'secret/exodus/standalone/bosh',
			'kit_name=bosh',
			'url=https://127.0.0.1:25555',
			'admin_username=admin',
			'admin_password=admin',
			'ca_cert=test-cert-placeholder',
		);
	};
	# Clear the memoized bosh object so it gets re-created from vault (with exodus_path set)
	delete $env->{__bosh};

	# ------------------------------------------------------------------
	# Subtest 1 (preserved): missing or terminated exodus status
	# ------------------------------------------------------------------
	subtest "missing or terminated exodus status" => sub {
		plan tests => 26;

		# Test that a nonexistent deployment warns and exits
		my ($stdout,$stderr) = output_from {
			not_ok(
				$env->terminate('force' => 0, 'noprompt' => 1), "terminate exits when no prior deployment found"
			)
		};
		like($stderr, qr/No exodus data found for termination-test; may not exist./, "terminate warns when no prior deployment found");
		like($stderr, qr/Cowardly refusing to terminate.  Use --force to attempt anyway./, "terminate refses to terminate, but suggests --force to override");

		# This test needs the manifest store to be in hybrid mode
		is($env->manifest_store, 'hybrid', "manifest store set to hybrid mode");

		# Setup an existing terminated exodus entry by writing directly to vault
		# (avoids vault re-authentication issues with update_deployment_exodus)
		quietly {
			lives_ok {
				is($env->deployment_state, 'undeployed', "deployment status is 'undeployed'");
				reset_exodus_data($env, reason => 'initial deployment');
				is($env->deployment_state, 'deployed', "deployment status is 'deployed'");

				# Write terminate audit directly to vault with a 2025 timestamp
				# (newer than the 2024 deploy timestamp, so it sorts first)
				my $term_ts = '20250102173415';
				$env->vault->query('set', $env->exodus_base.'/deployments/'.$term_ts,
					'state=terminated',
					"genesis_version=$Genesis::VERSION",
					'started=2025-01-02 17:34:05 +0000',
					'completed=2025-01-02 17:34:15 +0000',
					"timestamp=$term_ts",
					'sequence=2',
					'reason=shenanigans',
					'user.shell=sus-agent',
				);
				# Remove the main exodus keys (terminate clears them)
				$env->vault->query('rm', $env->exodus_base, '-f');
				$env->deployments->reset;
				delete $env->{deployment_state};

				is($env->deployment_state, 'terminated', "deployment status is 'terminated'");
			} "can build a terminated exodus entry";
		};

		# Test that a terminated deployment warns and exits
		($stdout,$stderr) = output_from {
			not_ok(
				$env->terminate('force' => 0, 'noprompt' => 1),
				"terminate exits when prior deployment is terminated"
			);
		};

		like($stderr, qr/Environment termination-test has already been terminated/, "terminate warns when prior deployment is terminated");
		like($stderr, qr/terminated by sus-agent/, "terminate reports who terminated the environment");
		like($stderr, qr/on 2025-01-02\s+at 17:34:15/, "terminate reports when the environment was terminated");
		like($stderr, qr/for reason: 'shenanigans'/, "terminate reports why the environment was terminated");
		like($stderr, qr/Cowardly refusing to terminate.  Use --force to attempt anyway./, "terminate refses to terminate, but suggests --force to override");

		# Force terminate a terminated deployment
		($stdout,$stderr) = output_from {
			ok(
				$env->terminate(
					force => 1, noprompt => 1, reason => 'forced termination'
				), "terminate command executed successfully"
			);
		};
		like($stderr, qr/Environment termination-test has already been terminated/, "forced terminate warns when prior deployment is terminated");
		like($stderr, qr/terminated by sus-agent/, "forced terminate reports who terminated the environment");
		like($stderr, qr/on 2025-01-02\s+at 17:34:15/, "forced terminate reports when the environment was terminated");
		like($stderr, qr/for reason: 'shenanigans'/, "forced terminate reports why the environment was terminated");
		like($stderr, qr/Forcing termination anyway.../, "forced terminate forces termination of a terminated deployment");

		# Test that exodus was updated - after termination, the main exodus keys
		# are cleared.  exodus_lookup returns undef OR an empty hash because the
		# /deployments sub-path still exists under the base path.
		my $exodus = $env->exodus_lookup();
		ok(!defined($exodus) || !keys(%$exodus), "exodus entry was removed");
		is(scalar(deployment_lookup($env)), 3, "new terminated deployment entry was created");
		is($env->deployment_state, 'terminated', "exodus entry has a termination time");

		my $last_deployment = deployment_lookup($env, 'latest');
		my $termination_time = Time::Piece->strptime($last_deployment->{completed}, '%Y-%m-%d %H:%M:%S %z');
		my $time_diff = Time::Piece->new - $termination_time;
		ok($time_diff < 60, "exodus entry was updated within the last minute");
		is($last_deployment->{user}{shell}, $ENV{USER}, "exodus entry has an updated terminated_by field");
		is($last_deployment->{reason}, 'forced termination', "exodus entry has an updated terminated_reason field");
	};

	# ------------------------------------------------------------------
	# Subtest 2 (preserved): dry-run
	# ------------------------------------------------------------------
	subtest "dry-run" => sub {
		plan tests => 11;

		reset_exodus_data($env);
		reset_secrets($env);
		my $original_exodus = $env->exodus_lookup();

		# Test that calls to 'genesis terminate' are successful
		my ($out) = combined_from {
			lives_ok {
				local $ENV{GENESIS_NO_UTF8} = 1;
				$env->terminate('dryrun' => 1,
					'resources' => 1,
					'secrets' => 1,
					'user_secrets' => 1,
					'credhub' => 1,
					'networking' => 1,
					flags => '--dry-run'
				)
			} "genesis terminate command executed successfully";
		};
		$out =~ s/\s+$ENV{GENESIS_BOSH_COMMAND}\s+/ <test-bosh> /msg;
		$out =~ s/\r//g; # bosh mock output has \r\n line endings... for some reason???

		eq_or_diff($out, <<'EOF',"genesis terminate output is correct (dryrun, cleanup secrets and resources)");

[termination-test/terminate-test] terminating deployed environment... (dry-run)

[termination-test/terminate-test] deleting deployment...

[DRYRUN] would execute <test-bosh> delete-deployment -d termination-test-terminate-test on standalone
         BOSH director.

[termination-test/terminate-test] cleaning up any unused resources...

[DRYRUN] would execute <test-bosh> clean-up --all on standalone BOSH director, resulting in the removal
         of the following resources:
bosh
-n
clean-up
--all
--dry-run
--tty

[WARNING] The contents above is a summary of the resources currently unused by
          any deployment. Further resources may become unused once this
          environment is actually terminated.

[termination-test/terminate-test] gathering list of associated items for
cleanup... done

[DRYRUN] no config files found to remove.

[DRYRUN] no network claims found to release.

[DRYRUN] would remove the following generated and user-provided secrets:
           * /secret/termination/test/terminate-test/super_secrets:password
           * /secret/termination/test/terminate-test/test_cert/ca
           * /secret/termination/test/terminate-test/test_cert/server
           * /secret/termination/test/terminate-test/test_cred:password
           * /secret/termination/test/terminate-test/test_cred:username
EOF

		# Confirm the secrets did not get removed from the vault
		my @secrets = map {$_->path} grep {$_->exists} $env->secrets_plan->secrets;
		is(scalar(@secrets), 5, "all secrets still in from vault");
		is(scalar(deployment_lookup($env)), 1, "no new deployment entry was created");
		is($env->deployment_state, 'deployed', "deployment status is still 'deployed'");
		cmp_deeply(scalar($env->exodus_lookup()), $original_exodus, "exodus entry was not modified");

		# Dry-run with keep user secrets and resources
		($out) = combined_from {
			lives_ok {
				local $ENV{GENESIS_NO_UTF8} = 1;
				$env->terminate(
					'dryrun' => 1,
					'resources' => 0,
					'secrets' => 1,
					'user_secrets' => 0,
					'credhub' => 1,
					'networking' => 0,
					flags => '--dry-run --no-user-secrets --no-resources --no-networking'
				);
			} "genesis terminate command executed successfully";
		};
		$out =~ s/\s+$ENV{GENESIS_BOSH_COMMAND}\s+/ <test-bosh> /msg;
		$out =~ s/\r//g; # bosh mock output has \r\n line endings... for some reason???

		eq_or_diff($out, <<'EOF',"genesis terminate output is correct (dryrun, keep secrets and resources)");

[termination-test/terminate-test] terminating deployed environment... (dry-run)

[termination-test/terminate-test] deleting deployment...

[DRYRUN] would execute <test-bosh> delete-deployment -d termination-test-terminate-test on standalone
         BOSH director.

[DRYRUN] would keep any unused resources on the standalone BOSH director.

[termination-test/terminate-test] gathering list of associated items for
cleanup... done

[DRYRUN] no config files found to remove.

[DRYRUN] no network claims found to release.

[DRYRUN] would keep the following user-provided secrets:
           * /secret/termination/test/terminate-test/super_secrets:password

[DRYRUN] would remove the following generated secrets:
           * /secret/termination/test/terminate-test/test_cert/ca
           * /secret/termination/test/terminate-test/test_cert/server
           * /secret/termination/test/terminate-test/test_cred:password
           * /secret/termination/test/terminate-test/test_cred:username
EOF

		is(scalar(deployment_lookup($env)), 1, "no new deployment entry was created");
		is($env->deployment_state, 'deployed', "deployment status is still 'deployed'");
		cmp_deeply(scalar($env->exodus_lookup()), $original_exodus, "exodus entry was not modified");

	};

	# ------------------------------------------------------------------
	# Subtest 3 (preserved): terminating a deployed environment
	# ------------------------------------------------------------------
	subtest "terminating a deployed environment" => sub {
		plan tests => 10;

		reset_exodus_data($env);
		reset_secrets($env);

		# Full run with --force and --yes
		my ($out) = combined_from {
			lives_ok {
				local $ENV{GENESIS_NO_UTF8} = 1;
				$env->terminate(
					'force' => 1, 'noprompt' => 1,
					'reason' => 'forced termination',
					'flags' => '--force --no-user-secrets --yes',
					'resources' => 1,
					'secrets' => 1,
					'user_secrets' => 0,
					'credhub' => 1,
					'networking' => 1,
					);
			} "genesis terminate command executed successfully";
		};
		$out =~ s/\r//g; # bosh mock output has \r\n line endings... for some reason???

		# With interactive => 0 (monkey-patched for test env), the bosh mock
		# output is captured internally by run() rather than echoed to combined
		# output, so we match only the Genesis notification lines.
		like($out, qr/terminating deployed environment/, "output mentions terminating");
		like($out, qr/deleting deployment/, "output mentions deleting deployment");
		like($out, qr/removing generated secrets/, "output mentions removing secrets");
		like($out, qr/completed \[4 removed/, "output reports 4 secrets removed");

		# Confirm the secrets got removed from the vault
		my @secrets = map {$_->path} grep {$_->exists} $env->secrets_plan->secrets;
		is(scalar(@secrets), 1, "all generated secrets removed from vault");

		# Confirm the environment is reported terminated in exodus
		is(scalar(deployment_lookup($env)), 2, "new terminated deployment entry was created");
		is($env->deployment_state, 'terminated', "deployment status is now 'terminated'");
		my $_ex = scalar($env->exodus_lookup());
		ok(!defined($_ex) || !keys(%$_ex), "exodus entry was cleared");
		my $latest = deployment_lookup($env, 'latest');
		cmp_deeply($latest, superhashof({
			'started'         => re(qr/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \+\d{4}/),
			'completed'       => re(qr/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \+\d{4}/),
			'reason'          => 'forced termination',
			'sequence'        => 2,
			'action'          => 'terminate',
			'result'          => 'success',
			'flags'           => '--force --no-user-secrets --yes',
			'genesis_version' => $Genesis::VERSION,
			'kit'             => superhashof({
				name    => 'dev',
				version => 'latest',
				id      => 'simple/in-development (dev)',
			}),
			'user' => superhashof({
				'shell' => $ENV{USER},
			}),
			'timestamp' => $latest->{completed} =~ s/ \+\d{4}//r =~ s/[^\d]//gr,
		}), "deployment audit entry was added correctly");
	};

	# ------------------------------------------------------------------
	# Subtest 4 (new): deployment state transitions through full lifecycle
	# ------------------------------------------------------------------
	subtest "deployment state transitions through full lifecycle" => sub {
		plan tests => 12;

		# Reset to a clean slate for this subtest
		$env->vault->clear($env->exodus_base, 1);
		$env->deployments->reset();

		# Step 1: environment starts undeployed
		is(
			$env->deployment_state, 'undeployed',
			"initial state is 'undeployed'"
		);
		is(
			$env->deployments->current_state, 'undeployed',
			"DeploymentManager::current_state agrees: 'undeployed'"
		);

		# Step 2: simulate a successful deploy by writing exodus / audit data
		reset_exodus_data($env, reason => 'lifecycle test deploy');
		reset_secrets($env);

		is(
			$env->deployment_state, 'deployed',
			"state transitions to 'deployed' after reset_exodus_data"
		);
		is(
			$env->deployments->current_state, 'deployed',
			"DeploymentManager::current_state agrees: 'deployed'"
		);

		# DeploymentManager::latest_successful should return the deploy record
		my $successful = $env->deployments->latest_successful(action => 'deploy');
		ok(defined $successful, "latest_successful(action => 'deploy') returns a record");
		SKIP: {
			skip "no successful deploy record to inspect", 1 unless defined $successful;
			is(
				$successful->action, 'deploy',
				"latest successful deploy record has action 'deploy'"
			);
		}

		# Step 3: terminate the environment
		quietly {
			lives_ok {
				$env->terminate(
					force    => 1,
					noprompt => 1,
					reason   => 'lifecycle transition test',
					flags    => '--force --yes',
					resources    => 0,
					secrets      => 0,
					user_secrets => 0,
					credhub      => 0,
					networking   => 0,
				);
			} "terminate succeeds during lifecycle transition test";
		};

		is(
			$env->deployment_state, 'terminated',
			"state transitions to 'terminated' after terminate()"
		);
		is(
			$env->deployments->current_state, 'terminated',
			"DeploymentManager::current_state agrees: 'terminated'"
		);

		# Verify audit trail has both deploy and terminate records
		my @all_deployments = $env->deployments->all();
		my $deploy_count    = scalar(grep { $_->lookup('action') eq 'deploy'    } @all_deployments);
		my $terminate_count = scalar(grep { $_->lookup('action') eq 'terminate' } @all_deployments);

		cmp_ok($deploy_count,    '>=', 1, "at least one deploy record exists in audit trail");
		cmp_ok($terminate_count, '>=', 1, "at least one terminate record exists in audit trail");

		# Confirm exodus is cleared after termination (the main exodus keys are
		# removed; only deployment sub-paths may remain)
		my $_ex2 = scalar($env->exodus_lookup());
		ok(!defined($_ex2) || !keys(%$_ex2),
			"exodus entry is cleared following termination");
	};

	# ------------------------------------------------------------------
	# Subtest 5 (new): reason policy enforcement on terminate
	# ------------------------------------------------------------------
	subtest "reason policy enforcement on terminate" => sub {
		plan tests => 7;

		# Reset to deployed state
		reset_exodus_data($env, reason => 'policy enforcement test deploy');
		reset_secrets($env);

		is(
			$env->deployment_state, 'deployed',
			"environment is deployed before policy tests begin"
		);

		# ------ sub-case A: no policy configured (default) ------
		# Ensure the config has no policy set (the default is 0 / falsy)
		$env->top->config->set('deployment_change_reason_required_size', 0);
		# Invalidate the memoized policy so the new config value is picked up
		delete $env->{__deployment_change_reason_required_size_policy};

		my ($stdout, $stderr) = output_from {
			ok(
				$env->terminate(
					force    => 1,
					noprompt => 1,
					reason   => '',   # empty reason is fine when no policy
					flags    => '--force --yes',
					resources    => 0,
					secrets      => 0,
					user_secrets => 0,
					credhub      => 0,
					networking   => 0,
				),
				"terminate succeeds with empty reason when no policy is set"
			);
		};

		# ------ Reset state ------
		reset_exodus_data($env, reason => 'policy enforcement test re-deploy');
		reset_secrets($env);

		# ------ sub-case B: policy requires minimum 10 characters ------
		$env->top->config->set('deployment_change_reason_required_size', 10);
		delete $env->{__deployment_change_reason_required_size_policy};

		# Attempt with a reason that is too short
		my $short_reason = 'short';   # only 5 characters
		dies_ok {
			$env->terminate(
				force    => 1,
				noprompt => 1,
				reason   => $short_reason,
				flags    => '--force --yes',
				resources    => 0,
				secrets      => 0,
				user_secrets => 0,
				credhub      => 0,
				networking   => 0,
			);
		} "terminate dies when reason is shorter than policy minimum";

		# Verify state was not changed (terminate bailed before acting)
		is(
			$env->deployment_state, 'deployed',
			"environment remains deployed after bailed terminate"
		);

		# ------ sub-case C: policy satisfied with sufficient reason ------
		my $long_reason = 'this reason is definitely long enough';
		quietly {
			lives_ok {
				$env->terminate(
					force    => 1,
					noprompt => 1,
					reason   => $long_reason,
					flags    => '--force --yes',
					resources    => 0,
					secrets      => 0,
					user_secrets => 0,
					credhub      => 0,
					networking   => 0,
				);
			} "terminate succeeds when reason satisfies policy minimum";
		};

		is(
			$env->deployment_state, 'terminated',
			"environment is terminated after policy-compliant terminate"
		);

		# Verify the reason was recorded in the audit entry
		my $latest = deployment_lookup($env, 'latest');
		is(
			$latest->{reason}, $long_reason,
			"termination reason is recorded in deployment audit entry"
		);

		# ------ Cleanup: restore policy to default ------
		$env->top->config->set('deployment_change_reason_required_size', 0);
		delete $env->{__deployment_change_reason_required_size_policy};
	};
};

=norun
subtest "terminating a create_env deployment with a hook" => sub {
	plan tests => 7;

	my $vault_target = vault_ok;
	Service::Vault->clear_all();

	my $top = Genesis::Top->create(workdir, 'pseudobosh', vault => $VAULT_URL);
	cp_kit('t/src/bosh-hooks', $top);
	put_file $top->path("my-mgmt.yml"), <<EOF;
---
kit:
	name:   dev
	version: latest
	features: []
	iaas: openstack
	scale: dev

genesis:
	env: my-mgmt
	use_create_env: true
	min_version: 3.1.0-rc.20

EOF
};
=cut

teardown_vault;
done_testing;
