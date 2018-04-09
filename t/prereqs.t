#!perl
use strict;
use warnings;

use lib 't';
use helper;
use Expect;
use Cwd qw(abs_path);

my $vault_target = vault_ok;
bosh2_cli_ok;

# EXPECT DEBUGGING
my $log_expect_stdout=0;

chdir workdir;

my ($pass, $rc, $msg);
reprovision kit => 'prereqs';

$ENV{SHOULD_FAIL} = '';
runs_ok "genesis new successful-env --vault $vault_target";
ok -f "successful-env.yml",
	"environment file should be created, when prereqs passes";

$ENV{SHOULD_FAIL} = 'yes';
run_fails "genesis new failed-env --vault $vault_target", 1;
ok ! -f "failed-env.yml",
	"environment file should not be created, when prereqs fails";

$ENV{SHOULD_FAIL} = '';
reprovision kit =>'version-prereq', compiled => 1;
($pass, $rc, $msg) = runs_ok "genesis new using-dev-genesis --vault $vault_target ";
matches $msg, qr{
		.*WARNING.* Using \s+ a \s+ development \s+ version \s+ of \s+ Genesis.*
		Cannot \s+ determine \s+ .*\(v9.5.2\).* for \s+ version-prereq/1.0.0.*
	}xsi, "dev version warning should get printed";

matches $msg, qr{New environment using-dev-genesis provisioned.},
	"environment creation success message should be printed.";
ok -f "using-dev-genesis.yml",
	"environment file should be created";

my $bin = compiled_genesis "9.0.1";
($pass, $rc, $msg) = run_fails "$bin new something-new --vault $vault_target", 86;
matches $msg, qr{
		.*ERROR:.* version-prereq/1\.0\.0 \s+ requires \s+ Genesis \s+ version \s+ 9\.5\.2,.*
		but \s+ this \s+ Genesis \s+ is \s+ version \s+ 9\.0\.1.*
	}xsi, "older genesis bin should trigger the error message";

ok ! -f "something-new.yml",
	"environment file should not be created, when prereqs fails";

$bin = compiled_genesis "9.5.2";
($pass, $rc, $msg) = runs_ok "$bin new something-new --vault $vault_target";
doesnt_match $msg, qr{.*ERROR:.* please upgrade Genesis}i,
	"Genesis should be new enough";
matches $msg, qr{New environment something-new provisioned.},
	"environment creation success message should be printed.";
ok -f "something-new.yml",
	"environment file should be created, when version meets minimum";

$bin = compiled_genesis "10.0.0-rc56";
($pass, $rc, $msg) = runs_ok "$bin new something-newer --vault $vault_target";
doesnt_match $msg, qr{.*ERROR:.* please upgrade Genesis},
	"Genesis should be new enough";
matches $msg, qr{New environment something-newer provisioned.},
	"environment creation success message should be printed.";

ok -f "something-newer.yml",
	"environment file should be created, when version meets minimum";

teardown_vault;
done_testing;
