#!perl
use strict;
use warnings;

use lib 't';
use helper;

my $dir = workdir;
chdir $dir;


bosh_ruby_cli_ok;

reprovision kit => 'prereqs';

$ENV{SHOULD_FAIL} = '';
runs_ok "genesis new successful-env --no-secrets";
ok -f "successful-env.yml", "Environment file should be created, when prereqs passes";

$ENV{SHOULD_FAIL} = 'yes';
run_fails "genesis new failed-env --no-secrets", 1;
ok ! -f "failed-env.yml", "Environment file should not be created, when prereqs fails";

done_testing;
