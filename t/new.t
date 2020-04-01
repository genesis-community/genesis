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

genesis:
  env: generate-nominal

params: {}
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

genesis:
  env: generate-full

params: {}
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

genesis:
  env: generate-full-2

params: {}
EOF

reprovision kit => 'omega-v2.7.0';
# Test base file propagation
no_env "generate";
no_env "generate-nominal";

expects_ok "omega-v2.7.0 generate-full-3 --bosh-env master-bosh --secrets-path super-prod --secrets-mount secret/genesis-stuff";
have_env 'generate-full-3';
eq_or_diff get_file("generate-full-3.yml"), <<EOF, "environment file generated with Genesis v2.7.0 options";
---
kit:
  name:     dev
  version:  latest
  features:
    - (( replace ))
    - cf-uaa
    - toolbelt
    - shield

genesis:
  env:                generate-full-3
  bosh_env:           master-bosh
  min_version:        2.7.0
  secrets_path:       super-prod
  secrets_mount:      /secret/genesis-stuff/

params: {}

EOF
chdir $TOPDIR;
teardown_vault;
done_testing;
