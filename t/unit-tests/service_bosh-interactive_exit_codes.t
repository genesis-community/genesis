#!/usr/bin/env perl
use strict;
use warnings;

# An interactive bosh command runs under script(1), so that bosh still sees a
# terminal while Genesis keeps a copy of its output.  macOS script(1) always
# exits with the child's code.  util-linux script(1) exits 0 whatever the
# child did unless it is given -e (--return), and records the child's code
# in a "Script done" trailer of its typescript either way.
#
# Without -e on Linux, run() saw script's 0, so an onfailure message never
# fired, and run_errand(), which relied on onfailure alone and returned 1,
# reported every failed errand as a success.  run_errand() now acts on the
# exit code that execute() returns.
#
# A fake script(1) on PATH reproduces each platform's behaviour, so every
# path runs on any host.

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Exception;

use Genesis;
use_ok 'Service::BOSH';
use_ok 'Service::BOSH::Director';

my $tmp = workdir();
my $fakebin = "$tmp/fakebin";
mkdir $fakebin or die "mkdir $fakebin: $!";

# A fake script(1) for the platform named by FAKE_SCRIPT_OS.  It writes the
# typescript only, so nothing reaches the TAP stream.
put_file("$fakebin/script", 0755, <<'SH');
#!/bin/bash
if [[ "$FAKE_SCRIPT_OS" == darwin ]]; then
	# BSD form: script [-aeFkqr] file command...; the code always passes through
	while [[ "$1" == -* ]]; do shift; done
	file="$1"; shift
	"$@" > "$file" 2>&1
	exit $?
fi

# util-linux form: options in any position, -c runs a shell string, and the
# child's code is returned only under -e/--return.
ret=0; file=; cmd=
while [[ $# -gt 0 ]]; do
	case "$1" in
		-c|--command) cmd="$2"; shift 2 ;;
		-e|--return)  ret=1; shift ;;
		--*)          shift ;;
		-*)           [[ "$1" == *e* ]] && ret=1
		              if [[ "$1" == *c ]]; then cmd="$2"; shift; fi
		              shift ;;
		*)            file="$1"; shift ;;
	esac
done
[[ -n "$cmd" && -n "$file" ]] || { echo "fake script: expected a file and -c" >&2; exit 64; }
printf 'Script started on 2026-10-21 12:00:00+00:00 [COMMAND="%s" TERM="xterm" TTY="/dev/pts/0" COLUMNS="80" LINES="24"]\n' "$cmd" > "$file"
bash -c "$cmd" >> "$file" 2>&1
rc=$?
printf '\nScript done on 2026-10-21 12:00:01+00:00 [COMMAND_EXIT_CODE="%s"]\n' "$rc" >> "$file"
[[ $ret == 1 ]] && exit "$rc"
exit 0
SH

fake_bosh(<<'SH');
echo "Running errand '$3':"
exit "${FAKE_BOSH_RC:-0}"
SH

sub director {
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	Service::BOSH::Director->new('an-env',
		url => 'https://127.0.0.1', ca_cert => 'ca_cert', client => 'admin',
		secret => 'password', exodus_path => 'secret/exodus',
		deployment => 'some-deployment'
	);
}

local $ENV{PATH} = "$fakebin:$ENV{PATH}";

for my $os (qw/darwin linux/) {
	local $^O = $os;
	local $ENV{FAKE_SCRIPT_OS} = $os;

	subtest "an interactive bosh command keeps its exit code on $os" => sub {
		local $ENV{FAKE_BOSH_RC} = 3;
		my ($out, $rc) = director->execute({interactive => 1}, '-n', 'run-errand', 'smoke-tests');
		is($rc, 3, 'a bosh command that exits 3 reports rc 3');
		like($out, qr/Running errand 'smoke-tests':/, 'the output is read back from the typescript');
		unlike($out, qr/Script (started|done)/, 'no script(1) header or trailer is left in the output');
	};

	subtest "an interactive bosh command honours onfailure on $os" => sub {
		local $ENV{FAKE_BOSH_RC} = 3;
		quietly { throws_ok {
			director->execute({interactive => 1, onfailure => 'the errand blew up'}, '-n', 'run-errand', 'smoke-tests');
		} qr/the errand blew up/, 'a failing bosh command bails with the onfailure message'; };

		$ENV{FAKE_BOSH_RC} = 0;
		lives_ok {
			director->execute({interactive => 1, onfailure => 'the errand blew up'}, '-n', 'run-errand', 'smoke-tests');
		} 'a passing bosh command does not bail';
	};

	subtest "run_errand fails when the errand fails on $os" => sub {
		local $ENV{FAKE_BOSH_RC} = 1;
		quietly { throws_ok {
			director->run_errand('smoke-tests');
		} qr/Failed to run errand 'smoke-tests'/, 'a failing errand bails'; };

		$ENV{FAKE_BOSH_RC} = 0;
		my $result;
		lives_ok { $result = director->run_errand('smoke-tests') } 'a passing errand does not bail';
		is($result, 1, 'a passing errand returns 1');
	};

	subtest "fake_tty keeps the wrapped command's exit code on $os" => sub {
		my (undef, $rc) = run({stderr => 0}, fake_tty("$tmp/fake-tty-$os.out", 'bash', '-c', 'exit 3'));
		is($rc, 3, 'a command that exits 3 under fake_tty reports rc 3');
	};
}

# run_errand must not lean on the wrapper alone: execute() recovers the code
# from the typescript when script(1) hides it, and run_errand has to act on
# what execute() returns.
subtest 'run_errand acts on the exit code execute returns' => sub {
	no warnings qw(redefine once);
	local *Service::BOSH::Director::execute = sub { return wantarray ? ("Exit code 1", 1) : 1 };
	use warnings qw(redefine once);

	quietly { throws_ok {
		director->run_errand('smoke-tests');
	} qr/Failed to run errand 'smoke-tests'.*bosh\s+exited\s+1/s, 'a nonzero code from execute makes run_errand bail'; };
};

done_testing;
