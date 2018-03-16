#!perl
use strict;
use warnings;

use lib 't';
use helper;

my $tmp = workdir();
my ($repo,$pass,$rc,$msg);

bosh2_cli_ok;

my $bsdtar = `tar --version | grep bsdtar`;
my $tar_parser;
if ($bsdtar) {
  $tar_parser = "awk '{print \$1, \$5, \$NF}'";
} else {
  $tar_parser = "awk '{print \$1, \$3, \$NF}'";
}

# Test Bad Development Kit
$repo = "compile-test-deployments-bad";
ok -d "t/repos/$repo", "$repo repo exists" or die;
chdir "t/repos/$repo" or die;
qx(rm -f *.tar.gz *.tgz); # just to be safe

($pass, $rc, $msg) = run_fails "genesis compile-kit --name custom-named-kit --version 1.0.4 --dev --force", 2;
matches $msg, qr'./dev does not look like a valid kit directory:', "Bad dev kit directory";
matches $msg, qr'  \* ./dev/README.md does not exist', "Bad dev kit directory - README.md does not exist";
matches $msg, qr'\nCannot continue.\n', "Bad dev kit directory - cannot continue";
$_ = $msg;
is tr/\n// + !/\n\z/, 4, "Bad dev kit directory -- no unexpected errors.";
ok ! -f "custom-named-kit-1.0.4.tar.gz", "genesis custom-named-kit should not create the tarball";

# Test warnings
qx(touch "./dev/README.md");
($pass, $rc, $msg) = runs_ok "genesis compile-kit --name custom-named-kit --version 1.0.4 --dev --force";
matches $msg, qr'Warning: ./dev has abnormal contents \(non-fatal\):', "Abnormal dev kit directory";
matches $msg, qr'  \* ./dev/hooks directory does not exist', "Abnormal dev kit directory - hooks directory does not exist";
doesnt_match $msg, qr'\nCannot continue.\n', "Abnormal dev kit directory - still can continue";
$_ = $msg;
is tr/\n// + !/\n\z/, 5, "Bad dev kit directory -- no unexpected errors or warnings.";
ok -f "custom-named-kit-1.0.4.tar.gz", "genesis custom-named-kit should not create the tarball";

# Cleanup
qx(rm -f *.tar.gz *.tgz ./dev/README.md);
chdir "../../.." or die;

# Test Good Development Kit
$repo = "compile-test-deployments";
ok -d "t/repos/$repo", "$repo repo exists" or die;
chdir "t/repos/$repo" or die;
qx(rm -f *.tar.gz *.tgz); # just to be safe

($pass, $rc, $msg) = runs_ok "genesis compile-kit --version 1.0.4 --force";
matches $msg, qr'Created compile-test-1.0.4.tar.gz\n', "Good dev kit directory - created release.";
ok -f "compile-test-1.0.4.tar.gz", "genesis compile-test-kit should create the tarball";
output_ok "tar -tzvf compile-test-1.0.4.tar.gz | $tar_parser | sort -k3", <<EOF, "tarball contents are correct";
drwxr-xr-x 0 compile-test-1.0.4/
-rw-r--r-- 112 compile-test-1.0.4/README.md
drwxr-xr-x 0 compile-test-1.0.4/base/
-rw-r--r-- 15 compile-test-1.0.4/base/params.yml
-rw-r--r-- 46 compile-test-1.0.4/base/stuff.yml
drwxr-xr-x 0 compile-test-1.0.4/hooks/
-rw-r--r-- 0 compile-test-1.0.4/hooks/params
-rw-r--r-- 40 compile-test-1.0.4/kit.yml
drwxr-xr-x 0 compile-test-1.0.4/subkits/
-rw-r--r-- 0 compile-test-1.0.4/subkits/.none
EOF

output_ok "tar zxf compile-test-1.0.4.tar.gz -O compile-test-1.0.4/kit.yml | spruce json | jq -r '.version'", "1.0.4", "Correct version set";

# Cleanup
qx(rm -f *.tar.gz *.tgz); # just to be safe
chdir "../../.." or die;

# Test Bad Kit Repo
$repo = "compile-test-genesis-kit-bad";
ok -d "t/repos/$repo", "$repo repo exists" or die;
chdir "t/repos/$repo" or die;
qx(rm -f *.tar.gz *.tgz); # just to be safe

($pass, $rc, $msg) = run_fails "genesis compile-kit --name my-kit --version 1.0.4 --force", 2;
matches $msg, qr'. does not look like a valid kit directory:', "Bad kit directory";
matches $msg, qr'  \* ./kit.yml does not exist', "Bad kit directory - README.md does not exist";
matches $msg, qr'  \* ./subkits/thingamabob/params.yml does not exist', "Bad kit directory - subkits/thingamabob/params.yml does not exist";
matches $msg, qr'\nCannot continue.\n', "Bad kit directory - cannot continue";
$_ = $msg;
is tr/\n// + !/\n\z/, 5, "Bad kit directory -- no unexpected errors.";
ok ! -f "my-kit-1.0.4.tar.gz", "genesis custom-named-kit should not create the tarball";

# Cleanup
qx(rm -f *.tar.gz *.tgz); # just to be safe
chdir "../../.." or die;

# Test Good Kit Repo
$repo = "compile-test-genesis-kit";
ok -d "t/repos/$repo", "$repo repo exists" or die;
chdir "t/repos/$repo" or die;
qx(rm -f *.tar.gz *.tgz); # just to be safe

# Try to run it in dev mode
($pass, $rc, $msg) = run_fails "genesis compile-kit --version 1.2.3 --dev --force", 2;
matches $msg, qr'Current directory is a kit -- cannot specify dev mode\n', "Not a dev kit repo";
ok ! -f "compile-test-kit-1.2.3.tar.gz", "genesis custom-named-kit should not create the tarball";
qx(rm -f *.tar.gz *.tgz); # just to be safe

# Run it properly, override name
($pass, $rc, $msg) = runs_ok "genesis compile-kit -n kickass --version 0.0.1 --force";
# [When subkits are deprecated] matches $msg, qr'Warning: . has abnormal contents \(non-fatal\):', "Kit with subkits warning";
# [When subkits are deprecated] matches $msg, qr/  \* using deprecated 'subkits' subdirectory -- use 'features' instead./, "Abnormal kit directory - using subkits";
matches $msg, qr'Created kickass-0.0.1.tar.gz\n', "Good kit directory - created release.";
doesnt_match $msg, qr'\nCannot continue.\n', "Abnormal dev kit directory - still can continue";
$_ = $msg;
is tr/\n// + !/\n\z/, 2, "Good dev kit directory -- no unexpected errors or warnings.";
# [When subkits are deprecated] is tr/\n// + !/\n\z/, 2, "Good dev kit directory -- no unexpected errors or warnings.";
ok -f "kickass-0.0.1.tar.gz", "genesis compile-test-kit should create the tarball";
output_ok "tar -tzvf kickass-0.0.1.tar.gz | $tar_parser | sort -k3", <<EOF, "tarball contents are correct";
drwxr-xr-x 0 kickass-0.0.1/
-rw-r--r-- 112 kickass-0.0.1/README.md
drwxr-xr-x 0 kickass-0.0.1/base/
-rw-r--r-- 15 kickass-0.0.1/base/params.yml
-rw-r--r-- 46 kickass-0.0.1/base/stuff.yml
drwxr-xr-x 0 kickass-0.0.1/hooks/
-rw-r--r-- 0 kickass-0.0.1/hooks/.none
-rw-r--r-- 40 kickass-0.0.1/kit.yml
drwxr-xr-x 0 kickass-0.0.1/subkits/
drwxr-xr-x 0 kickass-0.0.1/subkits/dohickey/
-rw-r--r-- 8 kickass-0.0.1/subkits/dohickey/params.yml
drwxr-xr-x 0 kickass-0.0.1/subkits/thingamabob/
-rw-r--r-- 8 kickass-0.0.1/subkits/thingamabob/params.yml
drwxr-xr-x 0 kickass-0.0.1/subkits/whatsit/
-rw-r--r-- 8 kickass-0.0.1/subkits/whatsit/params.yml
EOF
output_ok "tar zxf kickass-0.0.1.tar.gz -O kickass-0.0.1/kit.yml | spruce json | jq -r '.version'", "0.0.1", "Correct version set";

# Cleanup
qx(rm -f *.tar.gz *.tgz); # just to be safe
chdir "../../.." or die;
done_testing;
