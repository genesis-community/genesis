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

# ---------------------------------------------------------------------------
# check --no-config validation: rejected unless --no-manifest is also given
# ---------------------------------------------------------------------------

subtest 'check --no-config without --no-manifest fails' => sub {
	my ($pass, $rc, $out) = run_fails(
		"genesis us-east-1-sandbox check --no-config",
		"check --no-config without --no-manifest should fail"
	);
	matches $out, qr/Cannot specify --no-config without also specifying --no-manifest/,
		"error message mentions --no-config and --no-manifest";
};

# ---------------------------------------------------------------------------
# check --no-manifest --no-config: skips both checks, should succeed
# ---------------------------------------------------------------------------

subtest 'check --no-manifest --no-config succeeds' => sub {
	my ($pass, $rc, $out) = runs_ok(
		"genesis us-east-1-sandbox check --no-manifest --no-config",
		"check with both manifest and config checks disabled succeeds"
	);
	# With nothing to check, all checks pass
	matches $out, qr/All Checks Succeeded/i,
		"output confirms all checks succeeded when no checks enabled";
};

# ---------------------------------------------------------------------------
# check with --no-manifest only: skips manifest, succeeds
# ---------------------------------------------------------------------------

subtest 'check --no-manifest skips manifest generation' => sub {
	my ($pass, $rc, $out) = runs_ok(
		"genesis us-east-1-sandbox check --no-manifest",
		"check --no-manifest runs successfully"
	);
	doesnt_match $out, qr/generating.*manifest/i,
		"--no-manifest suppresses manifest generation output";
	matches $out, qr/All Checks Succeeded/i,
		"check --no-manifest reports success";
};

# ---------------------------------------------------------------------------
# check with --secrets: adds secrets validation (no secrets in manifest-test,
# so it reports success for having no secrets to validate)
# ---------------------------------------------------------------------------

subtest 'check --no-manifest --no-config --secrets succeeds' => sub {
	my ($pass, $rc, $out) = runs_ok(
		"genesis us-east-1-sandbox check --no-manifest --no-config --secrets",
		"check --secrets flag is accepted"
	);
	matches $out, qr/All Checks Succeeded/i,
		"check --secrets passes when no secret errors present";
};

# ---------------------------------------------------------------------------
# check with --stemcells: adds stemcell availability check via fake_bosh
# ---------------------------------------------------------------------------

subtest 'check --no-manifest --no-config --stemcells succeeds' => sub {
	my ($pass, $rc, $out) = runs_ok(
		"genesis us-east-1-sandbox check --no-manifest --no-config --stemcells",
		"check --stemcells flag is accepted"
	);
	matches $out, qr/All Checks Succeeded/i,
		"check --stemcells passes with fake bosh director";
};

# ---------------------------------------------------------------------------
# check default (manifest check): generates manifest and validates it.
# Requires cloud config, which cloud.yml provides via -c.
# The manifest-test dev kit does not have a 'check' hook so genesis falls
# back to manifest validation alone.
# ---------------------------------------------------------------------------

subtest 'check default runs manifest validation' => sub {
	my ($pass, $rc, $out) = runs_ok(
		"genesis us-east-1-sandbox check -c cloud.yml",
		"check default (manifest) succeeds with cloud config"
	);
	matches $out, qr/All Checks Succeeded/i,
		"default check reports all checks succeeded";
};

chdir $TOPDIR;
teardown_vault();
done_testing;
