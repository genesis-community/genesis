#!perl
use strict;
use warnings;

use lib 't';
use helper;
use Test::Differences;

my $vault_target = vault_ok;

my $dir = workdir;
chdir $dir;

bosh2_cli_ok;

system 'git config --global user.name "CI Testing"';
system 'git config --global user.email ci@starkandwayne.com';

runs_ok "genesis init new --vault $vault_target";
ok -d "new-deployments", "created initial deployments directory";
chdir "new-deployments";


reprovision kit => 'omega';
# Test base file propagation
no_env "generate";
no_env "generate-nominal";
expects_ok "simple-omega generate-nominal";
have_env 'generate-nominal';

eq_or_diff get_file("generate-nominal.yml"), <<EOF, "environment file generated has latest kit name / version in it";
---
kit:
  name:     dev
  version:  latest
  features:
    - (( replace ))
    - basic

params:
  env:   generate-nominal
  vault: generate/nominal/omega
EOF

no_env "generate-full";
expects_ok "new-omega generate-full";
have_env 'generate-full';
eq_or_diff get_file("generate-full.yml"), <<EOF, "environment file generated has latest kit name / version in it";
---
kit:
  name:     dev
  version:  latest
  features:
    - (( replace ))
    - cf-uaa
    - toolbelt
    - shield

params:
  env:   generate-full
  vault: generate/full/omega
EOF

expects_ok "new-omega generate-full-2";
have_env 'generate-full-2';
eq_or_diff get_file("generate-full-2.yml"), <<EOF, "environment file generated has latest kit name / version in it";
---
kit:
  name:     dev
  version:  latest
  features:
    - (( replace ))
    - cf-uaa
    - toolbelt
    - shield

params:
  env:   generate-full-2
  vault: generate/full/2/omega
EOF

chdir $TOPDIR;
teardown_vault;
done_testing;
