#!perl
use strict;
use warnings;

use lib 't';
use helper;
use POSIX qw/mktime/;

$ENV{GENESIS_TIME_FORMAT} = "%Y-%m-%d %H:%M:%S";

my $tmp = workdir;
ok -d "t/repos/summary-test", "summary-test repo exists" or die;
chdir "t/repos/summary-test" or die;

bosh2_cli_ok;

qx(rm -f .genesis/cached/*/last);
sub last_deployed($$) {
	qx(mkdir -p .genesis/cached/$_[0]);
	put_file ".genesis/cached/$_[0]/last", "$_[1]\n";
}

last_deployed "client-aws1-preprod", mktime(13, 52, 16,  4, 0, 117); # Jan  4 2017 16:52:13
last_deployed "client-aws1-prod",    mktime(22, 14, 03, 11, 9, 116); # Oct 11 2016 03:14:22
last_deployed "client-aws1-sandbox", mktime(18, 22, 14, 15, 0, 117); # Jan 15 2017 14:22:18
# client-aws2-sandbox has never been deployed

output_ok "genesis summary", <<EOF, "summary is correct";
Environment            Kit/Version       Last Deployed
===========            ===========       =============
client-aws1-preprod    some-kit/2.0.0    2017-01-04 16:52:13
client-aws1-prod       some-kit/1.0.0    2016-10-11 03:14:22
client-aws1-sandbox    some-kit/2.0.0    2017-01-15 14:22:18

client-aws2-sandbox    some-kit/2.0.0    never
EOF


done_testing;
