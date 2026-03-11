#!perl
use strict;
use warnings;

use lib 't';
use helper;
use Test::Differences;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 120;
$ENV{GENESIS_CONFIG_AUTOMATIC_UPGRADE} = 'silent';

vault_ok();
bosh2_cli_ok;

my $tmp = workdir;
ok -d "t/repos/manifest-test", "manifest-test repo exists" or die;
chdir "t/repos/manifest-test" or die;

# Use fake_bosh_directors so deploy() can connect via with_bosh()
my @directors = fake_bosh_directors("us-common");
fake_bosh;

# ---------------------------------------------------------------------------
# deploy option-validation (director-deployed envs need BOSH director)
# ---------------------------------------------------------------------------

subtest 'deploy option validation - mutually exclusive flags' => sub {
	# --fix and --recreate are mutually exclusive
	# Note: command_usage() suppresses error message text during GENESIS_TESTING,
	# so we verify via exit code only (the usage page is displayed instead).
	my ($pass, $rc, $out) = run_fails(
		"genesis us-east-1-sandbox deploy --fix --recreate --yes",
		"deploy --fix --recreate should fail"
	);
	ok $rc != 0, "--fix and --recreate conflict causes non-zero exit (rc=$rc)";

	# --fix and --dry-run are mutually exclusive
	($pass, $rc, $out) = run_fails(
		"genesis us-east-1-sandbox deploy --fix --dry-run",
		"deploy --fix --dry-run should fail"
	);
	ok $rc != 0, "--fix and --dry-run conflict causes non-zero exit (rc=$rc)";
};

subtest 'deploy option validation - create-env restrictions' => sub {
	# create-env rejects --fix
	my ($pass, $rc, $out) = run_fails(
		"genesis create-env-sandbox deploy --fix --yes",
		"deploy --fix on create-env should fail"
	);
	matches $out, qr/cannot be specified for.*create-env/i,
		"create-env --fix rejection message";

	# create-env rejects --dry-run
	($pass, $rc, $out) = run_fails(
		"genesis create-env-sandbox deploy --dry-run",
		"deploy --dry-run on create-env should fail"
	);
	matches $out, qr/cannot be specified for.*create-env/i,
		"create-env --dry-run rejection message";

	# create-env rejects --fix-stemcells
	($pass, $rc, $out) = run_fails(
		"genesis create-env-sandbox deploy --fix-stemcells --yes",
		"deploy --fix-stemcells on create-env should fail"
	);
	matches $out, qr/cannot be specified for.*create-env/i,
		"create-env --fix-stemcells rejection message";
};

# ---------------------------------------------------------------------------
# terminate option-validation tests (extra args cause usage error)
# ---------------------------------------------------------------------------

subtest 'terminate option validation' => sub {
	my ($pass, $rc, $out) = run_fails(
		"genesis us-east-1-sandbox terminate extra-arg --yes",
		"terminate with extra positional arg should fail"
	);
	ok $rc != 0, "terminate extra-arg exits non-zero (rc=$rc)";
};

# ---------------------------------------------------------------------------
# addon -- kit must provide an addon hook
# ---------------------------------------------------------------------------

subtest 'addon without hook fails' => sub {
	# Test from manifest-test where the kit has no addon hook
	my ($pass, $rc, $out) = run_fails(
		"genesis us-east-1-sandbox do smoke-tests",
		"do on kit without addon hook should fail"
	);
	matches $out, qr/does not provide an addon hook/i,
		"addon error message when kit has no addon hook";
};

subtest 'addon with hook dispatches to script' => sub {
	my $addon_dir = workdir('addon-test');
	chdir $addon_dir or die "cannot chdir to $addon_dir: $!";

	# Bootstrap a minimal genesis repo using the fancy kit as dev/
	qx(mkdir -p .genesis);
	put_file ".genesis/config", "version: 2\ncreator_version: (development)\ndeployment_type: fancy\n";
	qx(cp -a $TOPDIR/t/src/fancy dev);
	put_file "test-env.yml", <<YAML;
---
kit:
  name: dev
  version: latest
genesis:
  env: test-env
YAML

	# addon with a named script dispatches to the kit's hooks/addon script.
	# Note: 'help' is intercepted by Genesis::Hook::Addon which scans for
	# hooks/addon-* files; the old-style hooks/addon only runs for non-help scripts.
	my ($pass, $rc, $out) = runs_ok(
		"genesis test-env do my-addon",
		"addon 'my-addon' runs successfully against fancy kit"
	);
	matches $out, qr/executing \[my-addon\]/,
		"addon output contains the script name";

	chdir $TOPDIR;
};

chdir $TOPDIR;
teardown_vault();
done_testing;
