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
# lookup() -- key lookup, defaults, --defined, --entombed + --exodus
# ──────────────────────────────────────────────────────────────────────────────

subtest 'lookup key from env YAML' => sub {
	my ($ok, $rc, $out) = runs_ok(
		"genesis us-east-1-sandbox lookup genesis.env",
		"lookup genesis.env exits 0"
	);
	matches $out, qr/us-east-1-sandbox/,
		"lookup genesis.env: output contains 'us-east-1-sandbox'";
};

subtest 'lookup with default for missing key' => sub {
	my ($ok, $rc, $out) = runs_ok(
		"genesis us-east-1-sandbox lookup params.nonexistent_key my-default",
		"lookup with default exits 0"
	);
	matches $out, qr/my-default/,
		"lookup with default: output contains 'my-default'";
};

subtest 'lookup --defined for existing key exits 0' => sub {
	runs_ok(
		"genesis us-east-1-sandbox lookup --defined genesis.env",
		"lookup --defined with existing key exits 0"
	);
};

subtest 'lookup --defined for missing key exits 4' => sub {
	run_fails(
		"genesis us-east-1-sandbox lookup --defined params.nonexistent_key",
		4,
		"lookup --defined with missing key exits 4"
	);
};

subtest 'lookup --entomb with --exodus is rejected' => sub {
	my ($ok, $rc, $out) = run_fails(
		"genesis us-east-1-sandbox lookup --entomb --exodus some.key",
		undef,
		"lookup --entomb --exodus is rejected (exits non-zero)"
	);
	matches $out, qr/Cannot use --entomb/i,
		"lookup --entomb --exodus: error message mentions 'Cannot use --entomb'";
};

# ──────────────────────────────────────────────────────────────────────────────
# yamls() -- list, --view existing, --view missing
# ──────────────────────────────────────────────────────────────────────────────

subtest 'yamls basic listing' => sub {
	my ($ok, $rc, $out) = runs_ok(
		"genesis yamls us-east-1-sandbox 2>/dev/null",
		"yamls exits 0"
	);
	matches $out, qr/\.yml/,
		"yamls: output lists yaml files (contains .yml)";
};

subtest 'yamls --view existing env file' => sub {
	my ($ok, $rc, $out) = runs_ok(
		"genesis yamls us-east-1-sandbox --view us-east-1-sandbox.yml 2>/dev/null",
		"yamls --view of existing file exits 0"
	);
	matches $out, qr/us-east-1-sandbox/,
		"yamls --view: output contains env content";
};

subtest 'yamls --view missing file exits non-zero with error' => sub {
	my ($ok, $rc, $out) = run_fails(
		"genesis yamls us-east-1-sandbox --view nonexistent.yml",
		undef,
		"yamls --view of nonexistent file exits non-zero"
	);
	matches $out, qr/not found/i,
		"yamls --view missing: error message mentions 'not found'";
};

# ──────────────────────────────────────────────────────────────────────────────
# vault_paths() -- basic listing
# ──────────────────────────────────────────────────────────────────────────────

subtest 'vault-paths basic' => sub {
	runs_ok(
		"genesis vault-paths us-east-1-sandbox 2>/dev/null",
		"vault-paths exits 0"
	);
};

# ──────────────────────────────────────────────────────────────────────────────
# environments() -- basic invocation from within a deployment repo
# ──────────────────────────────────────────────────────────────────────────────

subtest 'environments basic' => sub {
	runs_ok(
		"genesis environments 2>/dev/null",
		"environments command exits 0 from within manifest-test repo"
	);
};

# ──────────────────────────────────────────────────────────────────────────────
# deployments() -- not yet implemented
# ──────────────────────────────────────────────────────────────────────────────

subtest 'deployments bails as not yet implemented' => sub {
	my ($ok, $rc, $out) = run_fails(
		"genesis us-east-1-sandbox deployments",
		undef,
		"deployments command exits non-zero (not yet implemented)"
	);
	matches $out, qr/not yet fully implemented/i,
		"deployments: error message mentions 'not yet fully implemented'";
};

# ──────────────────────────────────────────────────────────────────────────────
# info() -- basic invocation
# ──────────────────────────────────────────────────────────────────────────────

subtest 'info basic' => sub {
	# info attempts exodus lookup; with vault running this exits 0 even with no
	# prior deployment (falls back to synthesized record from empty exodus data)
	runs_ok(
		"genesis us-east-1-sandbox info 2>/dev/null",
		"info command exits 0"
	);
};

chdir $TOPDIR;
teardown_vault();
done_testing;
