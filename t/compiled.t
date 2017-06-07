#!perl
use strict;
use warnings;

use lib 't';
use helper;

my $tmp = workdir;
ok -d "t/repos/compiled-kit-test", "compiled-kit-test repo exists" or die;
chdir "t/repos/compiled-kit-test" or die;

bosh_ruby_cli_ok;

runs_ok "genesis manifest -c cloud.yml test-env >$tmp/manifest.yml";
is get_file("$tmp/manifest.yml"), <<EOF, "manifest generated based on compile kit";
name: env-compiled-kit-test
version: 0.0.1

EOF

runs_ok "genesis manifest -c cloud.yml test-env-upgrade >$tmp/manifest.yml";
is get_file("$tmp/manifest.yml"), <<EOF, "manifest generated based on compile kit";
name: env-compiled-kit-test
properties:
  added: stuff
version: 0.0.2

EOF

qx(rm -f new-env.yml);
runs_ok "genesis new --no-secrets new-env> $tmp/output";
is get_file("new-env.yml"), <<EOF, "environment file generated has latest kit name / version in it";
---
kit:
  name:    compiled
  version: 0.0.2
  subkits: []

params:
  env:   new-env
  vault: new/env/compiled-kit-test
EOF
qx(rm -f new-env.yml);

done_testing;
