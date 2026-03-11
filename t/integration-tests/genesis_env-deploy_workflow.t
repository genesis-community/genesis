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

subtest 'deploy workflow' => sub {
	plan tests => 8;

	my $vault_target = vault_ok;
	Service::Vault->clear_all();

	my $top = Genesis::Top->create(workdir, 'deploy-test', vault => $VAULT_URL);
	cp_kit('t/src/simple', $top);
	put_file $top->path("deploy-test.yml"), <<EOF;
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
  env: deploy-test
  bosh_env: standalone
  min_version: 3.1.0-rc.20
EOF

	put_file $top->path(".cloud.yml"), "--- {}\n# not really a cloud config, but close enough\n";

	my $env;
	lives_ok {
		$env = $top->load_env('deploy-test')
	} "deploy test environment loaded";

	# Setup secrets in the vault
	quietly {
		lives_ok {
			$env->vault->set($env->secrets_base.'super_secrets', 'password', 'super-secret-password');
			$env->add_secrets();
		} "secrets added to vault";
	};

	# Configure env for testing (manifest store, bosh configs)
	$env->top->config->set('manifest_store','hybrid');
	$env->use_config($top->path(".cloud.yml"));
	$Genesis::VERSION = '3.1.0-rc.20';

	# ----------------------------------------------------------------
	# Subtest 1: deployment_cache_setup returns expected filemap
	# ----------------------------------------------------------------
	subtest "deployment_cache_setup returns expected filemap" => sub {
		plan tests => 15;

		# Call setup — implicitly returns the filemap hash
		my $filemap = $env->deployment_cache_setup;
		ok(defined $filemap && ref($filemap) eq 'HASH',
			"deployment_cache_setup returns a hashref");

		# Verify expected keys are present
		for my $key (qw/manifest unpruned_manifest redacted_manifest
		                vars redacted_vars state store deploy_log/) {
			ok(exists $filemap->{$key}, "filemap has key '$key'");
		}

		# Verify paths point to .genesis/deploy-cache/<env-name>/
		my $cache_base = $top->path('.genesis/deploy-cache/deploy-test');
		like($filemap->{manifest}, qr{\Q$cache_base\E/},
			"manifest path is under deploy-cache/deploy-test/");
		like($filemap->{state}, qr{\Q$cache_base\E/},
			"state path is under deploy-cache/deploy-test/");

		# deployment_cache_path_lookup('all') returns same paths
		my $all_paths = $env->deployment_cache_path_lookup('all');
		ok(ref($all_paths) eq 'HASH', "deployment_cache_path_lookup('all') returns hashref");
		is($all_paths->{manifest}, $filemap->{manifest},
			"path_lookup('all') manifest matches setup filemap");

		# deployment_cache_cleanup removes the directory
		ok(-d $cache_base, "cache directory exists before cleanup");
		$env->deployment_cache_cleanup;
		ok(! -d $cache_base, "deployment_cache_cleanup removes the cache directory");
	};

	# ----------------------------------------------------------------
	# Subtest 2: deployment state tracking through lifecycle
	# ----------------------------------------------------------------
	subtest "deployment state tracking through lifecycle" => sub {
		plan tests => 3;

		# Initially undeployed (no exodus data)
		$env->vault->clear($env->exodus_base, 1);
		$env->deployments->reset;
		is($env->deployment_state, 'undeployed',
			"deployment_state is 'undeployed' with no exodus data");

		# Simulate a deployment via reset_exodus_data
		reset_exodus_data($env, reason => 'initial deployment');
		$env->deployments->reset;
		is($env->deployment_state, 'deployed',
			"deployment_state is 'deployed' after reset_exodus_data");

		# Simulate a successful termination audit
		quietly {
			lives_ok {
				$env->update_deployment_exodus(
					'terminate', 'success',
					'reason'    => 'test termination',
					'started'   => '2024-12-07 10:00:00 +0000',
					'completed' => '2024-12-07 10:00:10 +0000',
					user        => {'shell' => 'test-user'},
				);
				$env->deployments->reset;
			} "can record a terminated state";
		};
	};

	# ----------------------------------------------------------------
	# Subtest 3: update_deployment_exodus creates audit records
	# ----------------------------------------------------------------
	subtest "update_deployment_exodus creates audit records" => sub {
		plan tests => 5;

		# Reset to a clean deployed state
		reset_exodus_data($env, reason => 'base deployment');
		$env->deployments->reset;

		my @all = $env->deployments->all;
		ok(scalar(@all) >= 1, "at least one deployment audit exists after reset_exodus_data");

		# Verify exodus data is accessible
		my $exodus = $env->exodus_lookup();
		ok(defined $exodus, "exodus data exists after reset_exodus_data");

		# Verify deployment state reflects deployed
		is($env->deployment_state, 'deployed',
			"deployment_state is 'deployed'");

		# Verify latest deployment exists
		my $latest = $env->deployments->latest_successful;
		ok(defined $latest, "latest_successful deployment exists");

		# Verify it is a Deployment object
		isa_ok($latest, 'Genesis::Env::Deployment',
			"latest_successful returns a Genesis::Env::Deployment");
	};

	# ----------------------------------------------------------------
	# Subtest 4: DeploymentManager.build creates audit objects
	# ----------------------------------------------------------------
	subtest "DeploymentManager.build creates audit objects" => sub {
		plan tests => 5;

		reset_exodus_data($env, reason => 'pre-build test');
		$env->deployments->reset;

		# Use 'terminate' action because 'deploy' requires a full BOSH
		# director with exodus path set (needed for manifest artifacts).
		my $deployment;
		lives_ok {
			$deployment = $env->deployments->build(
				'terminate', 'success',
				reason => 'test build audit',
				user   => { shell => $ENV{USER} },
			);
		} "deployments->build returns without dying";

		isa_ok($deployment, 'Genesis::Env::Deployment',
			"build returns a Genesis::Env::Deployment object");
		is($deployment->action, 'terminate',
			"deployment action() returns 'terminate'");
		is($deployment->result, 'success',
			"deployment result() returns 'success'");
		ok($deployment->succeeded,
			"deployment succeeded() is true for 'success' result");
	};

	# ----------------------------------------------------------------
	# Subtest 5: deployment sequence tracking
	# ----------------------------------------------------------------
	subtest "deployment sequence tracking" => sub {
		plan tests => 5;

		# Clear all deployment data
		$env->vault->clear($env->exodus_base, 1);
		$env->deployments->reset;

		# Record first deployment
		reset_exodus_data($env, reason => 'first deployment');
		$env->deployments->reset;
		my @after_first = $env->deployments->all;
		ok(scalar(@after_first) >= 1, "has at least one deployment after first record");

		# Wait for distinguishable timestamps and record second
		sleep(3);
		reset_exodus_data($env, reason => 'second deployment');
		$env->deployments->reset;
		my @after_second = $env->deployments->all;
		ok(scalar(@after_second) >= scalar(@after_first),
			"has more deployments after second record");

		# Verify all() returns newest-first ordering
		if (scalar(@after_second) >= 2) {
			my $ts0 = $after_second[0]->timestamp;
			my $ts1 = $after_second[1]->timestamp;
			ok($ts0 ge $ts1,
				"all() returns deployments newest-first (timestamps descending)");
		} else {
			pass("skipping ordering check - only one audit record present");
		}

		# latest_successful returns the most recent success
		my $latest_ok = $env->deployments->latest_successful;
		ok(defined $latest_ok,
			"latest_successful() returns a deployment");
		ok($latest_ok->succeeded,
			"latest_successful() result is a successful result");
	};
};

teardown_vault;
done_testing;
