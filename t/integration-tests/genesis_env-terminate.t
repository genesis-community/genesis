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
use DateTime;

# Initialize the Genesis environment
use_ok 'Genesis::Config';
$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");

use_ok 'Genesis::Env';
use Service::BOSH;
use Genesis::Top;
use Genesis::Env;
use Genesis;

local $ENV{BOSH_NON_INTERACTIVE} = 1; # This gets set by the Genesis::Commands::Env::terminate command
local $ENV{GENESIS_BOSH_COMMAND};
write_bosh_config 'standalone';
my ($director1) = fake_bosh_directors(
	{alias => 'standalone'},
);
fake_bosh;

$ENV{GENESIS_CALLBACK_BIN} ||= abs_path('bin/genesis');
$ENV{GENESIS_LIB} ||= abs_path('lib');
$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;

sub reset_exodus_data {
	my $env = shift;
	my $state = scalar(@_) % 2 ? shift : 'deployed';
	my %overrides = @_;

	note "-- resetting exodus data for ".$env->name;

	$state //= 'deployed';
	$env->vault->clear($env->exodus_base,1);
	my $exodus_overrides = deep_merge({
		deployer => 'test-user',
		dated => '2024-12-06 01:23:45 +0000',
		completed => '2024-12-06 11:23:58 +0000',
	}, delete(%overrides{exodus_overrides})//{},
	'unflatten'
	);

	my $filemap = $env->deployment_cache_setup('preserve');
	mkfile_or_fail($filemap->{$_}, "Contents of $_ file")
		for (grep {! -f $filemap->{$_}} keys %$filemap);

	quietly {
		$env->update_deployment_exodus(
			$state,
			completed => '2024-12-06 11:23:58 +0000',
			user => {'shell' => 'test-user', vault => 'test-vault', 'repo' => 'test-repo'},
			%overrides,
			exodus_overrides => $exodus_overrides
		);
	};
}
sub reset_secrets {
	my ($env) = @_;

	note "-- resetting secrets for ".$env->name;

	$env->{__secrets_plan} = undef;
	$env->{__secrets_store} = undef;
  $env->vault->set($env->secrets_base.'super_secrets','password', 'super-secret-password');
	quietly {$env->add_secrets()};
}

subtest 'simple bosh-deployed genesis terminate' => sub {
	plan tests => 6;

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
  min_version: 3.1.0-rc.20
EOF

	put_file $top->path(".cloud.yml"), <<EOF;
--- {}
# not really a cloud config, but close enough
EOF

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

	# Configure env for testing (manifest store, bosh configs, etc)
	$env->top->config->set('genesis.manifest_store','hybrid');
	$env->use_config($top->path(".cloud.yml"));
	$Genesis::VERSION = '3.1.0-rc.20';

	subtest "missing or terminated exodus status" => sub {
		plan tests => 26;

		# Test that a nonexistent deployment warns and exits
		my ($stdout,$stderr) = output_from {
			not_ok(
				$env->terminate('force' => 0, 'nopronmpt' => 1), "terminate exits when no prior deployment found"
			)
		};
		like($stderr, qr/No exodus data found for termination-test; may not exist./, "terminate warns when no prior deployment found");
		like($stderr, qr/Cowardly refusing to terminate.  Use --force to attempt anyway./, "terminate refses to terminate, but suggests --force to override");

		# This test needs the manifest store to be in hybrid mode
		is($env->manifest_store, 'hybrid', "manifest store set to hybrid mode");

		# Setup an existing terminated exodus entry
		quietly {
			lives_ok {
				is($env->deployment_state, 'undeployed', "deployment status is 'undeployed'");
				reset_exodus_data($env, reason => 'initial deployment');
				is($env->deployment_state, 'deployed', "deployment status is 'deployed'");
				sleep(3);
				$env->update_deployment_exodus(
					'terminated',
					'reason' => 'shenanigans',
					'started' => '2025-01-02 17:34:05 +0000',
					'completed' => '2025-01-02 17:34:15 +0000',
					user => {'shell' => 'sus-agent'},
				);
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
		like($stderr, qr/on 2025-01-02 at 17:34:15/, "terminate reports when the environment was terminated");
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
		like($stderr, qr/on 2025-01-02 at 17:34:15/, "forced terminate reports when the environment was terminated");
		like($stderr, qr/for reason: 'shenanigans'/, "forced terminate reports why the environment was terminated");
		like($stderr, qr/Forcing termination anyway.../, "forced terminate forces termination of a terminated deployment");

		# Test that exodus was updated
		my $exodus = $env->exodus_lookup();
		cmp_deeply($exodus, undef, "exodus entry was removed");
		is(scalar($env->deployment_lookup), 3, "new terminated deployment entry was created");
		is($env->deployment_state, 'terminated', "exodus entry has a termination time");

		my $last_deployment = $env->deployment_lookup('latest');
		my $termination_time = Time::Piece->strptime($last_deployment->{completed}, '%Y-%m-%d %H:%M:%S %z');
		my $time_diff = Time::Piece->new - $termination_time;
		ok($time_diff < 60, "exodus entry was updated within the last minute");
		is($last_deployment->{user}{shell}, $ENV{USER}, "exodus entry has an updated terminated_by field");
		is($last_deployment->{reason}, 'forced termination', "exodus entry has an updated terminated_reason field");
	};

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
		is(scalar($env->deployment_lookup), 1, "no new deployment entry was created");
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

		is(scalar($env->deployment_lookup), 1, "no new deployment entry was created");
		is($env->deployment_state, 'deployed', "deployment status is still 'deployed'");
		cmp_deeply(scalar($env->exodus_lookup()), $original_exodus, "exodus entry was not modified");

	};

	subtest "terminating a deployed environment" => sub {
		plan tests => 7;

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

		eq_or_diff($out, <<'EOF',"genesis terminate output is correct (force and yes)");

[termination-test/terminate-test] terminating deployed environment...

[termination-test/terminate-test] deleting deployment...
bosh
-n
delete-deployment
--force
-d
termination-test-terminate-test

[termination-test/terminate-test] cleaning up any unused resources...
bosh
-n
clean-up
--all

[termination-test/terminate-test] gathering list of associated items for
cleanup... done

[termination-test/terminate-test] removing generated secrets...
  - removing 4 secrets under path '/secret/termination/test/terminate-test/':
  [1/4] test_cert/ca X.509 certificate - CA, self-signed ... done.
  [2/4] test_cert/server X.509 certificate - signed by 'test_cert/ca' ... done.
  [3/4] test_cred:password Random - 40 bytes ... done.
  [4/4] test_cred:username UUID - random:system RNG based (v4) ... done.
  completed [4 removed/0 skipped/0 errors]
done.
EOF

		# Confirm the secrets got removed from the vault
		my @secrets = map {$_->path} grep {$_->exists} $env->secrets_plan->secrets;
		is(scalar(@secrets), 1, "all generated secrets removed from vault");

		# Confirm the environment is reported terminated in exodus
		is(scalar($env->deployment_lookup), 2, "new terminated deployment entry was created");
		is($env->deployment_state, 'terminated', "deployment status is now 'terminated'");
		cmp_deeply(scalar($env->exodus_lookup()), undef, "exodus entry was cleared");
		my $latest = $env->deployment_lookup('latest');
		cmp_deeply($latest, {
			'started' => re(qr/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \+\d{4}/),
			'completed' => re(qr/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \+\d{4}/),
			'reason' => 'forced termination',
			'sequence' => 2,
			'state' => 'terminated',
			'success' => 'success',
			'flags' => '--force --no-user-secrets --yes',
			'genesis_version' => $Genesis::VERSION,
			'kit' => {
				name => 'dev',
				version => 'latest',
				id => 'simple/in-development (dev)',
				is_dev => 1,
				features => ''
			},
			'user' => {
				'shell' => $ENV{USER},
				'vault' => 'root',
				'repo' => ignore
			},
			'timestamp' => $latest->{completed} =~ s/ \+\d{4}//r =~s/[^\d]//gr, 
		}, "deployment audit entry was added correctly");
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
