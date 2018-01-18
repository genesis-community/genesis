#!perl
use strict;
use warnings;

use lib 't';
use helper;
use Expect;
use Cwd qw(abs_path);

# EXPECT DEBUGGING
my $log_expect_stdout=0;

my $dir = workdir;
chdir $dir;

bosh2_cli_ok;

my ($pass, $rc, $msg);
reprovision kit => 'prereqs';

$ENV{SHOULD_FAIL} = '';
runs_ok "genesis new successful-env --no-secrets";
ok -f "successful-env.yml", "Environment file should be created, when prereqs passes";

$ENV{SHOULD_FAIL} = 'yes';
run_fails "genesis new failed-env --no-secrets", 1;
ok ! -f "failed-env.yml", "Environment file should not be created, when prereqs fails";

$ENV{SHOULD_FAIL} = '';
reprovision kit =>'version-prereq', compiled => 1;
($pass, $rc, $msg) = runs_ok "genesis new using-dev-genesis --no-secrets ";
matches $msg, qr%.*WARNING.* Using a development version of Genesis.  Cannot determine if minimal Genesis version of '9.5.2' by kit 'version-prereq/1.0.0' is met.%,"Genesis dev version";
matches $msg, qr'New environment using-dev-genesis provisioned.', "Created new environment 'using-dev-genesis'";
ok -f "using.yml", "Org environment file should not be created, when prereqs fails";
ok -f "using-dev-genesis.yml", "Deployment environment file should not be created, when prereqs fails";

my $bin = compiled_genesis "9.0.1";

($pass, $rc, $msg) = run_fails "$bin new something-new", 86;
matches $msg, qr'.*ERROR:.* Kit version-prereq/1.0.0 requires Genesis version 9.5.2, but installed Genesis is only version 9.0.1.',"Genesis not new enough";
doesnt_match $msg, qr'New environment something-new provisioned.', "Did not create new environment 'something-new'";
ok ! -f "something.yml", "Org environment file should not be created, when prereqs fails";
ok ! -f "something-new.yml", "Deployment environment file should not be created, when prereqs fails";

$bin = compiled_genesis "9.5.2";
($pass, $rc, $msg) = runs_ok "$bin new something-new --no-secrets";
doesnt_match $msg, qr'.*ERROR:.* Kit version-prereq/1.0.0 requires Genesis version 9.5.2, but installed Genesis is only version 9.5.2.',"Genesis should be new enough";
matches $msg, qr'New environment something-new provisioned.', "Created new environment 'something-new'";
ok -f "something.yml", "Org environment file should be created, when version meets minimum ";
ok -f "something-new.yml", "Deployment environment file should be created, when version meets minimum";

$bin = compiled_genesis "10.0.0-rc56";
($pass, $rc, $msg) = runs_ok "$bin new something-newer --no-secrets";
doesnt_match $msg, qr'.*ERROR:.* Kit version-prereq/1.0.0 requires Genesis version 9.5.2, but installed Genesis is only version 10.0.0-r56.',"Genesis should be new enough";
matches $msg, qr'New environment something-newer provisioned.', "Created new environment 'something-new'";
ok -f "something.yml", "Org environment file should be created, when version meets minimum ";
ok -f "something-newer.yml", "Deployment environment file should be created, when version meets minimum";

reprovision kit =>'version-prereq-bad';
($pass, $rc, $msg) = run_fails "$bin new something-crazy", 255;

#
matches $msg, qr'.*ERROR:.* The following errors have been encountered validating the dev/latest kit:',"kit has errors";
matches $msg, qr% - Specified minimum Genesis version of '~>4.5' for kit is invalid.%,"kit has bad min version";
matches $msg, qr'Please contact your kit author for a fix.',"kit has bad min version - cannot continue ";
doesnt_match $msg, qr'New environment something-crazy provisioned.', "Did not create new environment 'something-crazy'";
ok ! -f "something.yml", "Org-level env file should not exist.";
ok ! -f "something-crazy.yml", "Deployment environment file should not be created, when kit min genesis version bad";

done_testing;
