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

subtest 'genesis env BOSH config workflow' => sub {
    plan tests => 9;

    my $vault_target = vault_ok;
    Service::Vault->clear_all();

    my $top = Genesis::Top->create(workdir, 'config-test', vault => $VAULT_URL);
    cp_kit('t/src/simple', $top);
    put_file $top->path("config-test.yml"), <<'EOF';
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
  env: config-test
  bosh_env: standalone
  min_version: 3.1.0-rc.20
EOF

    put_file $top->path(".cloud.yml"), <<'EOF';
--- {}
# not really a cloud config, but close enough
EOF

    put_file $top->path(".runtime.yml"), <<'EOF';
--- {}
# minimal runtime config for testing
EOF

    my $env;
    lives_ok {
        $env = $top->load_env('config-test')
    } "config-test environment loaded";

    # Configure env for testing
    $env->top->config->set('manifest_store','hybrid');
    $Genesis::VERSION = '3.1.0-rc.20';

    subtest 'use_config registers config file' => sub {
        plan tests => 4;

        my $cloud_file = $top->path(".cloud.yml");

        # Before registration, config should not be present
        ok(!$env->has_config('cloud'), "cloud config not registered before use_config");

        # Register the cloud config
        lives_ok {
            $env->use_config($cloud_file, 'cloud');
        } "use_config does not die";

        # After registration, has_config should return true
        ok($env->has_config('cloud'), "cloud config registered after use_config");

        # config_file should return the registered path
        is($env->config_file('cloud'), $cloud_file, "config_file returns registered path");
    };

    subtest 'can_build_cloud_configs feature check' => sub {
        plan tests => 2;

        # With min_version >= 3.1.0-rc.9 and no manage-cloud-configs override,
        # can_build_cloud_configs should return true
        my $result;
        lives_ok {
            $result = $env->can_build_cloud_configs;
        } "can_build_cloud_configs does not die";

        ok($result, "can_build_cloud_configs returns true for env with min_version 3.1.0-rc.20");
    };

    subtest 'missing_required_configs detection' => sub {
        plan tests => 3;

        # Create a fresh env object without configs set to test missing detection
        my $top2 = Genesis::Top->create(workdir, 'missing-config-test', vault => $VAULT_URL);
        cp_kit('t/src/simple', $top2);
        put_file $top2->path("missing-config.yml"), <<'EOF';
---
kit:
  name:   dev
  version: latest
  features: []
genesis:
  env: missing-config
  bosh_env: standalone
  min_version: 3.1.0-rc.20
EOF

        my $env2;
        lives_ok {
            $env2 = $top2->load_env('missing-config');
        } "missing-config environment loaded";

        $env2->top->config->set('manifest_store','hybrid');
        $Genesis::VERSION = '3.1.0-rc.20';

        # The simple kit's blueprint hook does not declare required configs,
        # so missing_required_configs should return an empty list
        my @missing;
        lives_ok {
            @missing = $env2->missing_required_configs('blueprint');
        } "missing_required_configs does not die";

        # Verify we get a list back (empty for simple kit)
        is(ref(\@missing), 'ARRAY', "missing_required_configs returns a list");
    };

    subtest 'has_config returns false before registration, true after' => sub {
        plan tests => 4;

        my $top3 = Genesis::Top->create(workdir, 'hasconfig-test', vault => $VAULT_URL);
        cp_kit('t/src/simple', $top3);
        put_file $top3->path("hasconfig-test.yml"), <<'EOF';
---
kit:
  name:   dev
  version: latest
  features: []
genesis:
  env: hasconfig-test
  bosh_env: standalone
  min_version: 3.1.0-rc.20
EOF

        my $env3;
        lives_ok {
            $env3 = $top3->load_env('hasconfig-test');
        } "hasconfig-test environment loaded";

        $env3->top->config->set('manifest_store','hybrid');

        # use_config() sets $ENV{GENESIS_CLOUD_CONFIG} as a side effect;
        # localise it so the previous subtest's registration does not bleed in.
        local $ENV{GENESIS_CLOUD_CONFIG};
        delete $ENV{GENESIS_CLOUD_CONFIG};

        ok(!$env3->has_config('cloud'), "cloud config absent before registration");

        my $cloud_file = $top3->path(".cloud.yml");
        put_file $cloud_file, "--- {}\n";
        $env3->use_config($cloud_file, 'cloud');

        ok($env3->has_config('cloud'), "cloud config present after use_config");

        is($env3->config_file('cloud'), $cloud_file,
            "config_file returns the registered path");
    };

    subtest 'cloud_config_files from manifest_provider' => sub {
        plan tests => 3;

        # Ensure cloud config is registered on $env
        my $cloud_file = $top->path(".cloud.yml");
        $env->use_config($cloud_file, 'cloud');

        my $provider;
        lives_ok {
            $provider = $env->manifest_provider;
        } "manifest_provider accessor does not die";

        ok(defined $provider, "manifest_provider returns a defined object");

        my @files;
        lives_ok {
            @files = $provider->cloud_config_files();
        } "cloud_config_files does not die";
    };

    subtest 'multiple config types tracked independently' => sub {
        plan tests => 5;

        my $top4 = Genesis::Top->create(workdir, 'multiconfig-test', vault => $VAULT_URL);
        cp_kit('t/src/simple', $top4);
        put_file $top4->path("multiconfig-test.yml"), <<'EOF';
---
kit:
  name:   dev
  version: latest
  features: []
genesis:
  env: multiconfig-test
  bosh_env: standalone
  min_version: 3.1.0-rc.20
EOF

        my $env4;
        lives_ok {
            $env4 = $top4->load_env('multiconfig-test');
        } "multiconfig-test environment loaded";

        $env4->top->config->set('manifest_store','hybrid');

        my $cloud_file   = $top4->path(".cloud.yml");
        my $runtime_file = $top4->path(".runtime.yml");
        put_file $cloud_file,   "--- {}\n";
        put_file $runtime_file, "--- {}\n";

        # Register both config types
        $env4->use_config($cloud_file, 'cloud');
        $env4->use_config($runtime_file, 'runtime');

        ok($env4->has_config('cloud'),   "cloud config registered");
        ok($env4->has_config('runtime'), "runtime config registered");

        is($env4->config_file('cloud'),   $cloud_file,   "cloud config_file correct");
        is($env4->config_file('runtime'), $runtime_file, "runtime config_file correct");
    };

    subtest 'config_file returns empty string for unregistered type' => sub {
        plan tests => 2;

        my $top5 = Genesis::Top->create(workdir, 'unregistered-config-test', vault => $VAULT_URL);
        cp_kit('t/src/simple', $top5);
        put_file $top5->path("unregistered-config.yml"), <<'EOF';
---
kit:
  name:   dev
  version: latest
  features: []
genesis:
  env: unregistered-config
  bosh_env: standalone
  min_version: 3.1.0-rc.20
EOF

        my $env5;
        lives_ok {
            $env5 = $top5->load_env('unregistered-config');
        } "unregistered-config environment loaded";

        my $result;
        lives_ok {
            $result = $env5->config_file('runtime');
        } "config_file for unregistered type does not die";
    };
};

teardown_vault;
done_testing;
