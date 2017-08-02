#!perl
use strict;
use warnings;

use Cwd qw(abs_path);
use Expect;
use Test::Differences;
use lib 't';
use helper;

bosh2_cli_ok;
my ($pass, $rc, $out);

qx(rm -rf t/tmp; mkdir -p t/tmp);
# Need to run on a packed version to get v1 code
($pass, $rc, $out) = runs_ok "GENESIS_PACK_PATH=t/tmp ./pack", "`./pack runs successfully";
matches($out, qr(bin/genesis syntax OK), "Genesis compiled correctly");
matches($out, qr(packaged v2.x.x \(devel-([a-f0-9]{10})\+?\) as t/tmp/genesis-\1), "Genesis was packaged to the correct place");

(my $bin = $out) =~ s/\A.* as (t\/tmp\/genesis[^\s]*).*\z/\.\/$1/sm;
$bin = abs_path($bin);

# Set up legacy repo skeleton 
chdir "t/tmp";
mkdir "global";
qx(touch global/deployment.yml);

($pass, $rc, $out) = run_fails "$bin version", 2, "`genesis` in legacy mode needs bin directory";
matches $out, "Missing bin directory in the genesis deployment root -- required to run genesis v1\n",
              "`genesis` error states bin directory must exist";

mkdir "bin";
($pass, $rc, $out) = runs_ok "$bin version", "`genesis version` in legacy mode works";
matches $out, qr(^genesis v1\.x\.x \([0-9a-f]*\) - embedded in 2.*),"`genesis version` in legacy mode reports v1.x.x version";

# Test that extracted v1 executable gets cleaned up normally
runs_ok "$bin help new env", "`genesis help` works in v1 mode ";
ok ! glob("bin/genesis-v1-*"), "Temporary bin/genesis-v1-..... file is cleaned up";

# Test that extracted v1 executable gets cleaned up when killed with Cmd-C (SIGINT)
SKIP: {
  skip "needs pgrep", 1 unless system('which pgrep >/dev/null') >> 8 == 0;

  qx($bin help new env& sleep 1 && pgrep -P \$! | xargs kill -SIGINT);
  ok ! glob("bin/genesis-v1-*"), "Temporary bin/genesis-v1-..... file is cleaned up when CTRL-C encountered.";
}

# Test that extracted v1 executable gets cleaned up when killed with SIGTERM
SKIP: {
  skip "needs pgrep", 1 unless system('which pgrep >/dev/null') >> 8 == 0;

  qx($bin help new env& sleep 1 && pgrep -P \$! | xargs kill -SIGTERM);
  ok ! glob("bin/genesis-v1-*"), "Temporary bin/genesis-v1-..... file is cleaned up when prematurely terminated";
}

# Test that extracted v1 executable gets cleaned up when parent is killed.
SKIP: {
  skip "needs pgrep", 1 unless system('which pgrep >/dev/null') >> 8 == 0;

  qx($bin help new env 1>/dev/null 2>&1& sleep 1 && kill %);
  ok ! glob("bin/genesis-v1-*"), "Temporary bin/genesis-v1-..... file is cleaned up when prematurely terminated";
}
# Test packaged executable in v2 mode
qx(rm global/deployment.yml && rmdir global);
($pass, $rc, $out) = runs_ok "$bin version", "`genesis version` in v2 mode works";
matches $out, qr(^Genesis v2\.x\.x \(devel-[0-9a-f]*\+?\)), "`genesis version` in v2 mode reports version";

done_testing;
