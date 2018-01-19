#!perl
use strict;
use warnings;

use lib 't';
use helper;

$ENV{HOME} = "$ENV{PWD}/t/tmp/home";
system "mkdir -p $ENV{HOME}";

my $dir = workdir;
chdir $dir;

bosh2_cli_ok;

system 'git config --global user.name "CI Testing"';
system 'git config --global user.email ci@starkandwayne.com';

runs_ok "genesis init new";
ok -d "new-deployments", "created initial deployments directory";
chdir "new-deployments";


reprovision kit => 'omega';
no_env 'x-y-z';
expects_ok "new-omega x-y-z --no-secrets";
have_env 'x-y-z';

run_fails "genesis new x-y-z --no-secrets",  "`genesis new` refuses to overwrite existing files";
have_env 'x-y-z', "should not be clobbered by a bad `genesis new` command";

no_env "*best*";
run_fails "genesis new *best*", "`genesis new` validates environment names";
no_env "*best*";

no_env "a--b";
run_fails "genesis new a--b",   "`genesis new` doesn't allow multi-dash environment names";
no_env "a--b";

no_env "basename";
my ($rc,$exit,$msg) = run_fails "genesis new basename", 2, "`genesis new` does not allow unhyphenated environments";
matches $msg, qr/Must be at least two levels to allow a base file for pipeline propagation\./, "`genesis new` gives error when unhyphenated env name given";
no_env "basename";

# Test base file propagation
no_env "generate";
no_env "generate-nominal";
expects_ok "simple-omega generate-nominal --no-secrets";
have_env 'generate';
have_env 'generate-nominal';
is get_file("generate.yml"), <<EOF, "environment file generated has latest kit name / version in it";
---
kit:
  name:     dev
  version:  latest
  features:
  - basic
EOF
is get_file("generate-nominal.yml"), <<EOF, "environment file generated has latest kit name / version in it";
---
params:
  env:   generate-nominal
  vault: generate/nominal/omega
EOF

no_env "generate-full";
expects_ok "new-omega generate-full --no-secrets";
have_env 'generate';
have_env 'generate-full';
is get_file("generate.yml"), <<EOF, "environment file generated has latest kit name / version in it";
---
kit:
  name:     dev
  version:  latest
  features:
  - basic
EOF
is get_file("generate-full.yml"), <<EOF, "environment file generated has latest kit name / version in it";
---
kit:
  features:
  - (( replace ))
  - cf-uaa
  - toolbelt
  - shield

params:
  env:   generate-full
  vault: generate/full/omega
EOF

open my $fh, ">", "generate.yml" or die "Could not overwrite generate.yml\n";
print $fh <<EOF;
---
kit:
  name:     omega
  version:  0.1.2
  features:
  - cf-uaa
  - toolbelt
  - shield
EOF
close $fh;

expects_ok "new-omega generate-full-2 --no-secrets";
have_env 'generate';
have_env 'generate-full-2';
is get_file("generate.yml"), <<EOF, "environment file generated has latest kit name / version in it";
---
kit:
  name:     omega
  version:  0.1.2
  features:
  - cf-uaa
  - toolbelt
  - shield
EOF
is get_file("generate-full-2.yml"), <<EOF, "environment file generated has latest kit name / version in it";
---
kit:
  name:     dev
  version:  latest

params:
  env:   generate-full-2
  vault: generate/full/2/omega
EOF

chdir $TOPDIR;
done_testing;
