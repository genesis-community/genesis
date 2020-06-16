#!perl
use strict;
use warnings;

use lib 't';
use helper;
use Test::Differences;

my $vault_target = vault_ok;

my $tmp = workdir;
ok -d "t/repos/compiled-kit-test", "compiled-kit-test repo exists" or die;
chdir "t/repos/compiled-kit-test" or die;

bosh2_cli_ok;

runs_ok "genesis manifest -c cloud.yml test-env >$tmp/manifest.yml";
eq_or_diff get_file("$tmp/manifest.yml"), <<EOF, "manifest generated based on compile kit";
name: test-env-compiled-kit-test
version: 0.0.1
EOF

runs_ok "genesis manifest -c cloud.yml test-env-upgrade >$tmp/manifest.yml";
eq_or_diff get_file("$tmp/manifest.yml"), <<EOF, "manifest generated based on compile kit";
name: test-env-upgrade-compiled-kit-test
properties:
  added: stuff
version: 0.0.2
EOF

qx(rm -f new-env.yml);
runs_ok "genesis new new-env -c cloud.yml";
eq_or_diff get_file("new-env.yml"), <<EOF, "environment file is correctly generated";
---
kit:
  name:     compiled
  version:  0.0.2
  features:
    - (( replace ))

genesis:
  env: new-env

params: {}
EOF
qx(rm -f new.yml new-env.yml);

chdir $TOPDIR;
teardown_vault;

done_testing;
