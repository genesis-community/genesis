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
my @directors = fake_bosh_directors("us-common");
fake_bosh;

# ──────────────────────────────────────────────────────────────────────────────
# bosh() -- passthrough and no-args
# ──────────────────────────────────────────────────────────────────────────────

subtest 'bosh passthrough' => sub {
	my ($ok, $rc, $out) = runs_ok(
		"genesis us-east-1-sandbox bosh deployments",
		"bosh passthrough: 'genesis us-east-1-sandbox bosh deployments' exits 0"
	);
	# fake_bosh intercepts the call; output includes the args
	matches $out, qr/bosh/i,
		"bosh passthrough: output contains 'bosh'";
};

subtest 'bosh no args triggers usage' => sub {
	run_fails(
		"genesis us-east-1-sandbox bosh",
		1,
		"bosh with no args exits with code 1 (command_usage)"
	);
};

# ──────────────────────────────────────────────────────────────────────────────
# credhub() -- blocked commands and no-args
# ──────────────────────────────────────────────────────────────────────────────

subtest 'credhub login is blocked' => sub {
	my ($ok, $rc, $out) = run_fails(
		"genesis us-east-1-sandbox credhub login",
		undef,
		"credhub login is blocked (exits non-zero)"
	);
	matches $out, qr/not allowed/i,
		"credhub login: error message mentions 'not allowed'";
};

subtest 'credhub api is blocked' => sub {
	my ($ok, $rc, $out) = run_fails(
		"genesis us-east-1-sandbox credhub api",
		undef,
		"credhub api is blocked (exits non-zero)"
	);
	matches $out, qr/not allowed/i,
		"credhub api: error message mentions 'not allowed'";
};

subtest 'credhub logout is blocked' => sub {
	my ($ok, $rc, $out) = run_fails(
		"genesis us-east-1-sandbox credhub logout",
		undef,
		"credhub logout is blocked (exits non-zero)"
	);
	matches $out, qr/not allowed/i,
		"credhub logout: error message mentions 'not allowed'";
};

subtest 'credhub no args triggers usage' => sub {
	run_fails(
		"genesis us-east-1-sandbox credhub",
		1,
		"credhub with no args exits with code 1 (command_usage)"
	);
};

# ──────────────────────────────────────────────────────────────────────────────
# logs() -- create-env bail and normal director
# ──────────────────────────────────────────────────────────────────────────────

subtest 'logs bails for create-env environments' => sub {
	my ($ok, $rc, $out) = run_fails(
		"genesis create-env-sandbox logs",
		undef,
		"logs command bails for create-env environment"
	);
	matches $out, qr/create-env/i,
		"logs create-env: error message mentions 'create-env'";
};

subtest 'logs runs for director-deployed environment' => sub {
	# fake_bosh intercepts bosh logs; expect exit 0
	runs_ok(
		"genesis us-east-1-sandbox logs",
		"logs runs without error for a director-deployed environment"
	);
};

# ──────────────────────────────────────────────────────────────────────────────
# bosh_configs() -- validation and stub actions
# ──────────────────────────────────────────────────────────────────────────────

subtest 'bosh-configs invalid action' => sub {
	my ($ok, $rc, $out) = run_fails(
		"genesis us-east-1-sandbox bosh-configs invalid",
		undef,
		"bosh-configs with invalid action exits non-zero"
	);
	matches $out, qr/Invalid action/i,
		"bosh-configs invalid action: error message mentions 'Invalid action'";
};

subtest 'bosh-configs too many args' => sub {
	my ($ok, $rc, $out) = run_fails(
		"genesis us-east-1-sandbox bosh-configs upload extra",
		undef,
		"bosh-configs with extra args exits non-zero"
	);
	matches $out, qr/Too many arguments/i,
		"bosh-configs too many args: error message mentions 'Too many arguments'";
};

subtest 'bosh-configs stub actions exit non-zero' => sub {
	for my $action (qw(upload list view compare delete summary)) {
		my ($ok, $rc, $out) = run_fails(
			"genesis us-east-1-sandbox bosh-configs $action",
			undef,
			"bosh-configs $action is a stub that exits non-zero"
		);
		matches $out, qr/TO BE IMPLEMENTED/i,
			"bosh-configs $action: output mentions 'TO BE IMPLEMENTED'";
	}
};

subtest 'bosh-configs default action (no action given) is upload stub' => sub {
	my ($ok, $rc, $out) = run_fails(
		"genesis us-east-1-sandbox bosh-configs",
		undef,
		"bosh-configs with no action defaults to upload stub (exits non-zero)"
	);
	matches $out, qr/bosh_configs_upload.*TO BE IMPLEMENTED/i,
		"bosh-configs default: upload stub message in output";
};

chdir $TOPDIR;
teardown_vault();
done_testing;
