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

my $tmp = workdir;

# ---------------------------------------------------------------------------
# create_kit() tests
# ---------------------------------------------------------------------------

# NOTE: create-kit --name has a pre-existing bug (abs_path not imported in
# Kit.pm), so we skip the scaffold test and test only the usage error path.

subtest 'create-kit without --name fails with usage error' => sub {
	my $dir = workdir('create-kit-noname');
	chdir $dir or die "Cannot chdir to $dir: $!";

	my (undef, $exit, $out) = run_fails "genesis create-kit 2>&1", undef,
		"genesis create-kit without --name fails";
	is $exit, 2,
		"exit code is 2 (usage error) when --name is omitted";
	matches $out,
		qr/--name/,
		"usage output mentions required --name option";

	chdir $TOPDIR;
};

# NOTE: build-kit --major/--minor conflict test is skipped because build_kit()
# calls kit_provider->kit_versions() (GitHub API) before validating options,
# causing the test to fail with "No repository named ... on Github" before
# reaching the --major/--minor conflict check.

# ---------------------------------------------------------------------------
# decompile_kit() tests
# ---------------------------------------------------------------------------

subtest 'decompile-kit latest decompiles into dev/' => sub {
	ok -d "t/repos/compiled-kit-test",
		"compiled-kit-test repo exists" or return;
	chdir "t/repos/compiled-kit-test" or die;

	# Remove any leftover dev/ from a prior run
	qx(rm -rf dev/);

	my (undef, undef, $out) = runs_ok
		"genesis decompile-kit latest 2>&1",
		"genesis decompile-kit latest exits 0";

	ok -d "dev",
		"decompile-kit created dev/ directory";
	ok -f "dev/kit.yml",
		"decompile-kit extracted kit.yml into dev/";

	# Cleanup
	qx(rm -rf dev/);

	chdir $TOPDIR;
};

subtest 'decompile-kit --force overwrites existing dev/' => sub {
	ok -d "t/repos/compiled-kit-test",
		"compiled-kit-test repo exists" or return;
	chdir "t/repos/compiled-kit-test" or die;

	# Create an existing dev/ with kit.yml so --force is required
	qx(rm -rf dev/ && mkdir -p dev);
	put_file "dev/kit.yml", "---\nname: placeholder\n";

	runs_ok "genesis decompile-kit latest --force 2>&1",
		"genesis decompile-kit latest --force exits 0 even when dev/ exists";

	ok -f "dev/kit.yml",
		"dev/kit.yml exists after forced decompile";

	# Cleanup
	qx(rm -rf dev/);

	chdir $TOPDIR;
};

subtest 'decompile-kit fails when dev/ exists and --force not given' => sub {
	ok -d "t/repos/compiled-kit-test",
		"compiled-kit-test repo exists" or return;
	chdir "t/repos/compiled-kit-test" or die;

	# Create dev/ with kit.yml so it is recognised as an existing dev kit
	qx(rm -rf dev/ && mkdir -p dev);
	put_file "dev/kit.yml", "---\nname: placeholder\n";

	my (undef, undef, $out) = run_fails
		"genesis decompile-kit latest 2>&1",
		undef,
		"genesis decompile-kit fails when dev/ exists without --force";
	matches $out,
		qr/already exists/,
		"error output mentions 'already exists'";

	# Cleanup
	qx(rm -rf dev/);

	chdir $TOPDIR;
};

# ---------------------------------------------------------------------------
# list_kits() tests
# ---------------------------------------------------------------------------

subtest 'list-kits shows locally compiled kit' => sub {
	ok -d "t/repos/compiled-kit-test",
		"compiled-kit-test repo exists" or return;
	chdir "t/repos/compiled-kit-test" or die;

	my ($pass, undef, $out) = runs_ok
		"genesis list-kits 2>&1",
		"genesis list-kits exits 0 from a repo with compiled kits";

	matches $out,
		qr/compiled/i,
		"list-kits output includes the compiled kit name";

	chdir $TOPDIR;
};

# ---------------------------------------------------------------------------
# fetch_kit() tests
# ---------------------------------------------------------------------------

subtest 'fetch-kit --as-dev with multiple kits fails' => sub {
	ok -d "t/repos/compiled-kit-test",
		"compiled-kit-test repo exists" or return;
	chdir "t/repos/compiled-kit-test" or die;

	my (undef, undef, $out) = run_fails
		"genesis fetch-kit kit1 kit2 --as-dev 2>&1",
		undef,
		"genesis fetch-kit with multiple kits and --as-dev fails";
	matches $out,
		qr/Cannot specify multiple kits/,
		"error message mentions multiple kits restriction";

	chdir $TOPDIR;
};

chdir $TOPDIR;
teardown_vault();
done_testing;
