#!perl
use strict;
use warnings;

use Expect;
use Test::Differences;
use lib 't';
use helper;

bosh_ruby_cli_ok;

my $dir = workdir 'kitvalidation-deployments';
chdir $dir;

reprovision kit => 'invalid-kit';

run_fails "genesis new failures-galore > errors 2>&1", 255, "Invalid kits fail to validate";
eq_or_diff get_file("errors"), <<EOF, "Invalid kits generate expected error messages";
Generating new environment failures-galore...

Using dev/ (development version) kit...

The following errors have been encountered validating the dev/latest kit:
 - params.base[0] has an invalid attribute: 'rapams'
 - params.base[0] has an invalid attribute: 'ska'
 - params.base[0] does not specify 'vault', 'param', or 'params'
 - params.base[0] does not have a 'description'
 - params.base[1] does not specify 'vault', 'param', or 'params'
 - params.base[2] does not specify 'vault', 'param', or 'params'
 - params.base[2] specifies 'ask', but does not have a corresponding 'vault' or 'param'
 - params.base[3] specifies both 'params' and 'ask'
 - params.base[3] specifies 'ask', but does not have a corresponding 'vault' or 'param'
 - params.base[4] specifies both 'param' and 'params'
 - params.base[5] specifies both 'param' and 'vault'
 - params.base[6] specifies both 'params' and 'vault'
 - params.base[6] specifies 'vault' but does not have a corresponding 'ask'
 - params.base[7] does not have a 'description'
 - params.base[7] specifies 'vault' but does not have a corresponding 'ask'
 - params.more-bad-params[0] specifies 'params', but it is not an array
 - params.more-bad-params[1] specifies 'param', but it is not a string
 - params.more-bad-params[2] does not specify 'vault', 'param', or 'params'
 - params.more-bad-params[2] does not have a 'description'
 - params.more-bad-params[3] does not specify 'vault', 'param', or 'params'
 - params.more-bad-params[3] does not have a 'description'
 - params.more-bad-params[4] does not specify 'vault', 'param', or 'params'
 - params.more-bad-params[4] specifies 'ask', but does not have a corresponding 'vault' or 'param'
Please contact your kit author for a fix.
EOF

chdir $TOPDIR;
done_testing;
