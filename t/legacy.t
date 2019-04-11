#!perl

#TODO: Cleanup hacky assertions into diags that print if tests fail:
# - Temporary bin/genesis-v1-..... was produced (when testing CTRL-C cleanup)
# - Killed genesis process (when testing CTRL-C cleanup)
# - Temporary bin/genesis-v1-..... was produced (when testing SIGTERM cleanup)
# - Killed genesis process (when testing SIGTERM cleanup)
# - Temporary bin/genesis-v1-..... was produced (when testing parent removal cleanup)
# - Killed genesis process (when testing parent removal cleanup)
#
# Change repeated code blocks in last three specs to test_until() function
# that can be used for that repeated code.

use strict;
use warnings;

use Cwd qw(abs_path);
use Expect;
use Test::Differences;
use lib 't';
use helper;

bosh2_cli_ok;
my ($pass, $rc, $out);

# Need to run on a packed version to get v1 code
($pass, $rc, $out) = runs_ok "GENESIS_PACK_PATH=t/tmp ./pack", "`./pack runs successfully";
matches($out, qr|bin/genesis syntax OK|, "Genesis compiled correctly");
matches($out, qr|packaged v2.x.x-dev \(([a-f0-9]{10})\+?\).* as t/tmp/genesis-dev-\1|, "Genesis was packaged to the correct place");

(my $bin = $out) =~ s/\A.* as (t\/tmp\/genesis[^\s]*).*\z/\.\/$1/sm;
$bin = abs_path($bin);

# Set up legacy repo skeleton
chdir "t/tmp";
mkdir "global";
qx(touch global/deployment.yml);

mkdir "bin";
($pass, $rc, $out) = runs_ok "$bin version", "`genesis version` in legacy mode works";
matches $out, qr|^genesis v1\.x\.x \([0-9a-f]*\) - embedded in 2.*|m,"`genesis version` in legacy mode reports v1.x.x version";

# Test packaged executable in v2 mode
qx(rm global/deployment.yml && rmdir global);
($pass, $rc, $out) = runs_ok "$bin version", "`genesis version` in v2 mode works";
matches $out, qr|^Genesis v2\.x\.x-dev \([0-9a-f]*\+?\)|, "`genesis version` in v2 mode reports version";

done_testing;
