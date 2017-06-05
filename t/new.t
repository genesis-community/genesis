#!perl
use strict;
use warnings;

use lib 't';
use helper;

my $dir = workdir;
chdir $dir;

bosh_ruby_cli_ok;

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

chdir $TOPDIR;
done_testing;
