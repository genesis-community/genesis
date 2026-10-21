#!/usr/bin/env perl
use strict;
use warnings;

# `spruce diff` exits 0 when the files match, 1 when they differ, and 2 or
# more when it cannot compare them.  Genesis runs it under script(1) so the
# diff keeps its colours, and the two script(1)s report that code
# differently.  macOS `script -e` passes the child's code through, while
# util-linux `script` without -e always exits 0 and records the real code in
# the "Script done" trailer of its typescript.
#
# The cloud config check in `genesis deploy` and the job spec comparison in
# `genesis compare-kits` used to read the code straight from script(1).  On
# macOS any cloud config change then aborted the deploy with an empty
# "Error comparing cloud configs:" message, and on Linux a spruce failure was
# shown as a set of differences.  Both now go through spruce_diff, which
# reads the real code on either platform.
#
# Fake script and spruce commands on PATH reproduce each platform's
# behaviour, so every path runs on any host.

use lib 't';
use helper;
use Test::More;
use Test::Exception;
use Test::Output;

use Genesis qw/spruce_diff/;
use_ok 'Genesis::Commands::Env';
use_ok 'Genesis::Commands::Kit';

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

my $tmp = workdir();
my $fakebin = "$tmp/fakebin";
mkdir $fakebin or die "mkdir $fakebin: $!";

# A fake script(1) that behaves like the platform named by its flags.  The
# terminal turns each newline into CR-LF, so the fake does the same.
put_file("$fakebin/script", 0755, <<'SH');
#!/bin/bash
case "$1" in
	-qeF) # macOS: run the arguments, pass the exit code through
		file="$2"; shift 2
		"$@" 2>&1 | sed 's/$/\r/' | tee "$file"
		exit "${PIPESTATUS[0]}"
		;;
	-qef) # util-linux with -e: run the -c string, record the exit code in a trailer, and return it
		file="$2"
		[[ "$3" == "-c" ]] || { echo "fake script: expected -c" >&2; exit 64; }
		printf 'Script started on 2026-10-01 12:00:00+00:00 [COMMAND="%s" TERM="xterm" TTY="/dev/pts/0" COLUMNS="80" LINES="24"]\n' "$4" > "$file"
		bash -c "$4" 2>&1 | sed 's/$/\r/' | tee -a "$file"
		rc="${PIPESTATUS[0]}"
		if [[ -n "$FAKE_SCRIPT_TRAILER" ]]; then
			printf '\nScript done on 2026-10-01 12:00:01+00:00 [%s]\n' "$FAKE_SCRIPT_TRAILER" >> "$file"
		else
			printf '\nScript done on 2026-10-01 12:00:01+00:00 [COMMAND_EXIT_CODE="%s"]\n' "$rc" >> "$file"
		fi
		exit "$rc"
		;;
esac
echo "fake script: unexpected flags $1" >&2
exit 64
SH

# A fake spruce whose diff exits with $FAKE_SPRUCE_RC.
put_file("$fakebin/spruce", 0755, <<'SH');
#!/bin/bash
[[ "$1" == "diff" ]] || { echo "fake spruce: only diff is supported" >&2; exit 64; }
case "${FAKE_SPRUCE_RC:-0}" in
	0) exit 0 ;;
	1) printf '\n\n(root level)\n  ± order changed\n\nnetworks.default.subnets\n  + one list entry added:\n    - range: 10.0.0.0/24\n\n\n'
	   exit 1 ;;
	*) echo "unable to parse data from $3: yaml: line 1: did not find expected node content" >&2
	   exit "$FAKE_SPRUCE_RC" ;;
esac
SH

put_file("$tmp/old.yml", "a: 1\n");
put_file("$tmp/new.yml", "a: 2\n");

local $ENV{PATH} = "$fakebin:$ENV{PATH}";

for my $os (qw/darwin linux/) {
	local $^O = $os;

	subtest "spruce_diff reports spruce's exit code on $os" => sub {
		local $ENV{FAKE_SPRUCE_RC} = 0;
		my ($out, $rc) = spruce_diff("$tmp/old.yml", "$tmp/new.yml");
		is($rc, 0, 'matching files give rc 0');
		is($out, '', 'matching files give no output');

		$ENV{FAKE_SPRUCE_RC} = 1;
		($out, $rc) = spruce_diff("$tmp/old.yml", "$tmp/new.yml");
		is($rc, 1, 'differing files give rc 1');
		like($out, qr/\A\(root level\).*range: 10\.0\.0\.0\/24\z/s, 'the diff is returned, trimmed');
		unlike($out, qr/Script (started|done)/, 'no script(1) header or trailer is left in the diff');

		$ENV{FAKE_SPRUCE_RC} = 2;
		($out, $rc) = spruce_diff("$tmp/old.yml", "$tmp/new.yml");
		is($rc, 2, 'a spruce failure gives rc 2');
		like($out, qr/unable to parse data from/, 'the spruce error is returned as the output');
	};

	subtest "the deploy cloud config check reads spruce's exit code on $os" => sub {
		local $ENV{FAKE_SPRUCE_RC} = 0;
		my $diff;
		lives_ok {
			$diff = Genesis::Commands::Env::_deploy_cloud_config_diff("$tmp/old.yml", "$tmp/new.yml")
		} 'matching cloud configs do not abort the deploy';
		is($diff, '', 'matching cloud configs report no differences');

		$ENV{FAKE_SPRUCE_RC} = 1;
		lives_ok {
			$diff = Genesis::Commands::Env::_deploy_cloud_config_diff("$tmp/old.yml", "$tmp/new.yml")
		} 'changed cloud configs do not abort the deploy';
		like($diff, qr/\A<root>\r?\n.*range: 10\.0\.0\.0\/24\z/s, 'the differences are returned with (root level) shown as <root>');

		$ENV{FAKE_SPRUCE_RC} = 2;
		throws_ok {
			stderr_from { Genesis::Commands::Env::_deploy_cloud_config_diff("$tmp/old.yml", "$tmp/new.yml") }
		} qr/Error comparing cloud configs:.*unable to parse data from/s,
			'a spruce failure aborts the deploy and says what spruce said';
	};

	subtest "the job spec comparison reads spruce's exit code on $os" => sub {
		local $ENV{FAKE_SPRUCE_RC} = 0;
		my ($status, $diff) = Genesis::Commands::Kit::_diff_job_specs("$tmp/old.yml", "$tmp/new.yml");
		is($status, 'unchanged', 'matching specs are unchanged');
		is($diff, '', 'matching specs have no diff');

		$ENV{FAKE_SPRUCE_RC} = 1;
		($status, $diff) = Genesis::Commands::Kit::_diff_job_specs("$tmp/old.yml", "$tmp/new.yml");
		is($status, 'changed', 'differing specs are changed');
		like($diff, qr/\A\(root level\).*range: 10\.0\.0\.0\/24\z/s, 'the diff is returned, trimmed');

		$ENV{FAKE_SPRUCE_RC} = 2;
		($status, $diff) = Genesis::Commands::Kit::_diff_job_specs("$tmp/old.yml", "$tmp/new.yml");
		is($status, 'error', 'a spruce failure is an error, not a change');
		like($diff, qr/unable to parse data from/, 'the spruce error is returned for display');
	};
}

subtest 'a linux trailer without an exit code is a failure, not a difference' => sub {
	local $^O = 'linux';
	local $ENV{FAKE_SPRUCE_RC} = 1;
	local $ENV{FAKE_SCRIPT_TRAILER} = '<terminated by signal 15>';
	my ($out, $rc) = spruce_diff("$tmp/old.yml", "$tmp/new.yml");
	cmp_ok($rc, '>', 1, 'a command that did not exit normally gives an error rc');
	like($out, qr/terminated by signal 15/, 'the output says why the command stopped');
	unlike($out, qr/Script done/, 'the trailer line itself is removed');
};

done_testing;
