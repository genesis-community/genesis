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
# bosh() and credhub() no-args: trigger usage without vault interaction
# ──────────────────────────────────────────────────────────────────────────────

subtest 'bosh no args triggers usage' => sub {
	run_fails(
		"genesis us-east-1-sandbox bosh",
		1,
		"bosh with no args exits with code 1 (command_usage)"
	);
};

subtest 'credhub no args triggers usage' => sub {
	run_fails(
		"genesis us-east-1-sandbox credhub",
		1,
		"credhub with no args exits with code 1 (command_usage)"
	);
};

# ──────────────────────────────────────────────────────────────────────────────
# logs() -- create-env bail
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

# ──────────────────────────────────────────────────────────────────────────────
# bosh() -- passthrough
# NOTE: manifest-test kit has is_bosh_director: true, so --parent is required
# to target the deploying BOSH director (us-common).
# ──────────────────────────────────────────────────────────────────────────────

subtest 'bosh passthrough' => sub {
	my ($ok, $rc, $out) = runs_ok(
		"genesis us-east-1-sandbox bosh --parent deployments",
		"bosh --parent passthrough exits 0"
	);
	matches $out, qr/bosh/i,
		"bosh passthrough: output contains 'bosh'";
};

# ──────────────────────────────────────────────────────────────────────────────
# credhub() -- blocked commands
# NOTE: --parent required for BOSH director environments to resolve the
# deploying director before the blocked-command check is reached.
# ──────────────────────────────────────────────────────────────────────────────

subtest 'credhub blocked commands' => sub {
	for my $cmd (qw(login api logout)) {
		my ($ok, $rc, $out) = run_fails(
			"genesis us-east-1-sandbox credhub --parent $cmd",
			undef,
			"credhub $cmd is blocked (exits non-zero)"
		);
		matches $out, qr/not allowed/i,
			"credhub $cmd: error message mentions 'not allowed'";
	}
};

# NOTE: logs for director-deployed environment is skipped because fake_bosh
# does not produce a valid log tarball for the extraction step.

# NOTE: bosh-configs tests are skipped due to a pre-existing dispatch bug:
# bin/genesis registers as Genesis::Commands::BOSH::bosh_configs but the
# package is Genesis::Commands::Bosh (case mismatch).

chdir $TOPDIR;
teardown_vault();
done_testing;
