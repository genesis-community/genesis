#!perl
use strict;
use warnings;

use lib 't';
use helper;

my $tmp = workdir();

ok -d "t/repos/compile-test", "compile-test repo exists" or die;
chdir "t/repos/compile-test" or die;
qx(rm -f *.tar.gz *.tgz); # just to be safe

bosh2_cli_ok;

my $bsdtar = `tar --version | grep bsdtar`;
my $tar_parser;
if ($bsdtar) {
	$tar_parser = "awk '{print \$1, \$5, \$NF}'";
} else {
	$tar_parser = "awk '{print \$1, \$3, \$NF}'";
}

runs_ok "genesis compile-kit --name test-kit --version 1.0.4 --dev";
ok -f "test-kit-1.0.4.tar.gz", "genesis compile-kit should create the tarball";
output_ok "tar -tzvf test-kit-1.0.4.tar.gz | $tar_parser | sort -k3", <<EOF, "tarball contents are correct";
drwxr-xr-x 0 test-kit-1.0.4/
drwxr-xr-x 0 test-kit-1.0.4/base/
-rw-r--r-- 15 test-kit-1.0.4/base/params.yml
-rw-r--r-- 46 test-kit-1.0.4/base/stuff.yml
-rw-r--r-- 28 test-kit-1.0.4/kit.yml
EOF
qx(rm -f *.tar.gz *.tgz); # just to be safe

chdir ".." or die;
qx(rm -f *.tar.gz *.tgz); # just to be safe
runs_ok "genesis compile-kit --name test --version 1.0.4";
ok -f "test-1.0.4.tar.gz", "genesis compile-kit should create the tarball when not in dev mode";
output_ok "tar -tzvf test-1.0.4.tar.gz | $tar_parser | sort -k3", <<EOF, "tarball contents are correct";
drwxr-xr-x 0 test-1.0.4/
drwxr-xr-x 0 test-1.0.4/base/
-rw-r--r-- 15 test-1.0.4/base/params.yml
-rw-r--r-- 46 test-1.0.4/base/stuff.yml
-rw-r--r-- 28 test-1.0.4/kit.yml
EOF
qx(rm -f *.tar.gz *.tgz); # just to be safe
done_testing;
