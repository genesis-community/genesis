#!perl
use strict;
use warnings;

use lib 't';
use helper;

bosh_ruby_cli_ok;

qx(rm -rf t/tmp; mkdir -p t/tmp);
chdir "t/tmp";

run_fails "genesis init %thing", "`genesis init` doesn't like malformed repo names";
ok ! -d "#1-thing-deployments", "`genesis init` refused to create #1-thing-deployments/ directory";

runs_ok "genesis init random";
ok -d "random-deployments",                      "`genesis init` created the random-deployments/ directory";
ok -d "random-deployments/.genesis",             "`genesis init` created the .genesis/ sub-directory";
ok -f "random-deployments/.genesis/config",      "`genesis init` created the .genesis/config file";
ok -d "random-deployments/.genesis/bin",         "`genesis init` created the .genesis/bin sub-directory";
ok -f "random-deployments/.genesis/bin/genesis", "`genesis init` embedded a copy of the calling `genesis` script in .genesis/bin";
ok ! -d "random-deployments/dev",                "`genesis init` did not create the dev/ directory, since --dev was not given";

qx(rm -rf *-deployments/);
runs_ok "genesis init --dev random";
ok -d "random-deployments",                 "`genesis init` created the random-deployments/ directory";
ok -d "random-deployments/.genesis",        "`genesis init` created the .genesis/ sub-directory";
ok -f "random-deployments/.genesis/config", "`genesis init` created the .genesis/config file";
ok -d "random-deployments/dev",             "`genesis init` created the dev/ directory, since --dev was given";

done_testing;
