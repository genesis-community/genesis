package helper;
use Test::More;
use Test::Exception;
use Cwd ();
use Config;
use File::Temp qw/tempdir/;
use File::Basename qw/dirname/;
use JSON::PP;

$ENV{PERL5LIB} = "$ENV{PWD}/lib";

our $TOPDIR;
sub import {
	my ($class, @args) = @_;
	$TOPDIR = Cwd::getcwd();
	$TOPDIR =~ s|/[^/]*$|| until -f "${TOPDIR}/bin/genesis";

	$ENV{PATH} = "${TOPDIR}/bin:$ENV{PATH}";
	$ENV{OFFLINE} = 'y';

	my $caller = caller;
	for my $glob (sort keys %helper::) {
		next if not defined *{$helper::{$glob}}{CODE}
		         or $glob eq 'import';
		*{$caller . "::$glob"} = \&{"helper::$glob"};
	}
	for my $var (qw(TOPDIR)) {
		*{$caller . "::$var"} = \${"helper::$var"};
	}

	runs_ok("genesis ping") or die "`genesis ping` failed...\n";
}

our $WORKDIR = undef;
sub workdir {
	$WORKDIR ||= tempdir(CLEANUP => 1);
	return $WORKDIR unless @_;
	my $path = join '/', $WORKDIR, @_;
	qx(mkdir -p $path);
	return $path;
}

sub put_file($$) {
	local $Test::Builder::Level = $Test::Builder::Level + 1;
	my ($file, $contents) = @_;
	system("mkdir -p ".dirname($file));
	open my $fh, ">", $file
		or fail "failed to open '$file' for writing: $!";

	print $fh $contents;
	close $fh;
}

sub get_file($) {
	local $Test::Builder::Level = $Test::Builder::Level + 1;
	my ($file) = @_;
	open my $fh, "<", $file
		or fail "failed to open '$file' for reading: $!";

	my $contents = do { local $/; <$fh> };
	close $fh;
	return $contents;
}

sub semver {
	my ($v) = @_;
	if ($v && $v =~ m/^v?(\d+)(?:\.(\d+)(?:\.(\d+)(?:[\.-]rc[\.-]?(\d+))?)?)?$/i) {
		return wantarray ? ($1, $2 || 0, $3 || 0, (defined $4 ? $4 - 100000 : 0))
										 : [$1, $2 || 0, $3 || 0, (defined $4 ? $4 - 100000 : 0)];
	}
	return;
}

sub by_semver ($$) { # sort block -- needs prototype
	my ($a, $b) = @_;
	my @a = semver($a);
	my @b = semver($b);
	return 0 unless @a && @b;
	while (@a) {
		return 1 if $a[0] > $b[0];
		return -1 if $a[0] < $b[0];
		shift @a;
		shift @b;
	}
	return 0;
}

sub new_enough {
	my ($v, $min) = @_;
	return 0 unless semver($v) && semver($min);
	return by_semver($v, $min) >= 0;
}


our $BOSH_CMD;
sub bosh_cmd {
	unless ($BOSH_CMD) {
		my $best = "0.0.0";
		foreach my $boshcmd (qw(bosh2 boshv2 bosh)) {
			my ($version, undef) = qx/$boshcmd -v 2>&1 | grep version | head -n1/;
			if ($version =~ /version (\S+?)-.*/) {
				if (new_enough($1, $best)) {
					$BOSH_CMD = $boshcmd;
					$best = $1
				}
			}
		}
	}
	return $BOSH_CMD;
}

sub fake_bosh {
	local $Test::Builder::Level = $Test::Builder::Level + 1;
	my ($script) = @_;
	$script ||= <<'EOF';
#!/bin/bash
echo "bosh"
for x in "$@" ; do printf "%s\n" "$x"; done
exit 0
EOF

	my $tmp = workdir;
	put_file("$tmp/fake-bosh", $script);
	chmod(0755, "$tmp/fake-bosh");
	$ENV{GENESIS_BOSH_COMMAND} = "$tmp/fake-bosh";
}

sub spruce_fmt($$) {
	my ($yaml, $file) = @_;
	open my $fh, "|-", "spruce merge - >$file"
		or die "Failed to reformat YAML via spruce: $!\n";
	print $fh $yaml;
	close $fh;
}

sub compiled_genesis {
	my ($version) = @_;
	my ($rc, $out);
	my $tmp = workdir();

	my $cmd = "cd $TOPDIR && GENESIS_PACK_PATH=$tmp ./pack";
	$cmd .= " $version" if $version;
	$out = qx($cmd 2>&1);
	$rc = $? >> 8;
	die "Could not compile genesis: $!" if $? >> 8;
	die "Could not compile genesis: $out" unless $out =~ qr%packaged v${\($version || "2.x.x")}%;
	(my $bin = $out) =~ s/\A.* as (.*\/genesis[^\s]*).*\z/$1/sm;
	return Cwd::abs_path($bin);
}

sub reprovision {
	my %opts = @_;
	my $err = qx(rm -rf *.yml .genesis/kits .genesis/cache dev/);
	if ($? != 0) {
		diag "failed to clean up workdir:";
		diag "-----------------------------------------------";
		diag $err ? $err : '(no output)';
		diag "-----------------------------------------------";
		diag "";
		exit 1;
	}

	if ($opts{kit}) {
		if (!-d "$TOPDIR/t/kits/$opts{kit}") {
			diag "unable to install kit $opts{kit} into workdir";
			diag "(no kit by that name was found in $TOPDIR/t/kits)";
			diag "";
			exit 1;
		}

		qx(mkdir -p .genesis && echo "deployment_type: $opts{kit}" > .genesis/config);

		if ($opts{compiled}) {
			$opts{version} ||= "1.0.0";
			$err = qx(cp -a $TOPDIR/t/kits/$opts{kit} $opts{kit}-$opts{version} 2>&1 && \
			          mkdir -p .genesis/kits 2>&1 && \
			          tar -czf .genesis/kits/$opts{kit}-$opts{version}.tar.gz $opts{kit}-$opts{version}/ 2>&1);
			if ($? != 0) {
				diag "failed to compile the $opts{kit}-$opts{version} kit:";
				diag "-----------------------------------------------";
				diag $err ? $err : '(no output)';
				diag "-----------------------------------------------";
				diag "";
				exit 1;
			}

		} else {
			$err = qx(cp -a $TOPDIR/t/kits/$opts{kit} dev);
			if ($? != 0) {
				diag "failed to install the $opts{kit} dev kit:";
				diag "-----------------------------------------------";
				diag $err ? $err : '(no output)';
				diag "-----------------------------------------------";
				diag "";
				exit 1;
			}
		}
	}

	pass "working directory re-provisioned for next set of tests";
}

sub runs_ok($;$) {
	local $Test::Builder::Level = $Test::Builder::Level + 1;
	my ($cmd, $msg) = @_;
	$cmd .= " 2>&1" unless $cmd =~ / 2>/;
	$msg ||= "running `$cmd`";

	my $err = qx($cmd </dev/null);
	if ($? != 0) {
		my $exit = $? >> 8;
		fail $msg;
		diag "`$cmd` exited $exit";
		diag "";
		diag "----[ output from failing command: ]-----------";
		diag $err ? $err : '(no output)';
		diag "-----------------------------------------------";
		diag "";
		return wantarray ? (0, $exit, $err) : 0;
	}
	pass $msg;
	return wantarray ? (1, 0, $err) : 1;
}

sub run_fails($$;$) {
	local $Test::Builder::Level = $Test::Builder::Level + 1;
	my ($cmd, $rc, $msg) = @_;
	$msg ||= "running `$cmd` (expecting exit code $rc)";
	if (defined $rc && $rc !~ m/^\d+$/) {
		$msg = $rc;
		$rc = undef;
	}

	my $err = qx($cmd 2>&1 </dev/null);
	my $exit = $? >> 8;
	if (defined $rc  && $exit != $rc) {
		fail $msg;
		diag "`$cmd` exited $exit (instead of $rc)";
		diag $err;
		return wantarray ? (0, $exit, $err) : 0 ;
	} elsif (!defined $rc && $exit == 0) {
		fail $msg;
		diag "`$cmd` exited $exit (instead of non-zero)";
		diag $err;
		return wantarray ? (0, $exit, $err) : 0;
	}
	pass $msg;
	return wantarray ? (1, $exit, $err) : 1;
}

sub matches($$$) {
	local $Test::Builder::Level = $Test::Builder::Level + 1;
	my ($str,$test,$msg) = @_;
	my $matches = (ref($test) eq 'Regexp') ? $str =~ $test : $str eq $test;
	if ($matches) {
		pass $msg;
	} else {
		fail $msg;
		diag "Expected:\n$test\n\nGot:\n$str\n";
	}
}

sub doesnt_match($$$) {
	local $Test::Builder::Level = $Test::Builder::Level + 1;
	my ($str,$test,$msg) = @_;
	my $matches = (ref($test) eq 'Regexp') ? $str =~ $test : $str eq $test;
	if ($matches) {
		fail $msg;
		diag "Expected to not find:\n$test\n\nGot:\n$str\n";
	} else {
		pass $msg;
	}
}

sub expects_ok($;$) {
	local $Test::Builder::Level = $Test::Builder::Level + 1;
	my ($cmd, $msg) = @_;
	return runs_ok "${TOPDIR}/t/expect/$cmd", $msg;
}

sub expect_fails($;$) {
	local $Test::Builder::Level = $Test::Builder::Level + 1;
	my ($cmd, $msg) = @_;
	return run_fails "${TOPDIR}/t/expect/$cmd", $msg;
}

sub output_ok($$;$) {
	local $Test::Builder::Level = $Test::Builder::Level + 1;
	my ($cmd, $expect, $msg) = @_;
	$msg ||= "`$cmd` ≅ '$expect'";

	my $dir = workdir;
	my $got = qx($cmd 2>&1);
	if ($? != 0) {
		my $exit = $? >> 8;
		fail $msg;
		diag "`$cmd` exited $exit";
		diag $got;
		return 0;
	}
	$got =~ s/\s+$//mg;
	$expect =~ s/\s+$//mg;

	if ($got ne $expect) {
		fail "$msg: output was different.";
		put_file "$dir/got",    "$got\n";
		put_file "$dir/expect", "$expect\n";
		diag qx(cd $dir/; diff -u expect got);
		return 0;
	}
	pass $msg;
	return 0;
}

sub bosh2_cli_ok {
	local $Test::Builder::Level = $Test::Builder::Level + 1;
	my $cmd = bosh_cmd;
	isnt $cmd, "", "A 'bosh' command was found";
	runs_ok "$cmd create-release --help", "the BOSH2 golang CLI works ok"
		or die "There seems to be something wrong with your bosh2 CLI.\n";
}

sub no_env($;$) {
	local $Test::Builder::Level = $Test::Builder::Level + 1;
	my ($env, $msg) = @_;
	$msg ||= "$env environment (in $env.yml) should not exist";
	ok ! -f "$env.yml", $msg;
}

sub have_env($;$) {
	local $Test::Builder::Level = $Test::Builder::Level + 1;
	my ($env, $msg) = @_;
	$msg ||= "$env environment (in $env.yml) should exist";
	ok -f "$env.yml", $msg;
}

my $VAULT_PID;
sub vault_ok {
	local $Test::Builder::Level = $Test::Builder::Level + 1;
	my $target = 'genesis-ci-unit-tests';
	if (defined $VAULT_PID) {
		pass "vault already running.";
		return $target;
	}

	$ENV{HOME} = "$ENV{PWD}/t/tmp/home";
	my $pid = qx(./t/bin/vault) or do {
		fail "failed to spin a vault server.";
		die "Cannot continue\n";
	};

	chomp($pid);
	$VAULT_PID = $pid;
	kill -0, $pid or do {
		fail "failed to spin a vault server: couldn't signal pid $pid.";
		die "Cannot continue\n";
	};
	pass "vault running [pid $pid]";
	return $target;
}

sub teardown_vault {
	if (defined $VAULT_PID) {
		print STDERR "\nShutting down vault (pid: $VAULT_PID)\n"
			if defined $ENV{DEBUG_TESTS} and $ENV{DEBUG_TESTS} =~ m/^(1|y|yes|true)$/i;
		kill 'TERM', $VAULT_PID;
		$VAULT_PID = undef;
	}
}

sub no_secret($;$) {
	local $Test::Builder::Level = $Test::Builder::Level + 1;
	my ($secret, $msg) = @_;
	$msg ||= "secret '$secret' should not exist";
	qx(safe exists $secret);
	if ($? == 0) {
		fail $msg;
		diag "    (safe exited $?)";
		return 0;
	}

	pass $msg;
	return 1;
}

sub have_secret($;$) {
	local $Test::Builder::Level = $Test::Builder::Level + 1;
	my ($secret, $msg) = @_;
	$msg ||= "secret '$secret' should exist";
	qx(safe exists $secret);
	my $rc = $? >> 8;
	if ($rc != 0) {
		fail $msg;
		diag "    (safe exited $rc)";
		return 0;
	}

	pass $msg;
	return 1;
}

sub secret($) {
	chomp(my $secret = qx(safe read $_[0]));
	return $secret;
}

sub yaml_is($$$) {
	local $Test::Builder::Level = $Test::Builder::Level + 1;
	my ($got, $expect, $msg) = @_;
	my $dir = workdir;
	spruce_fmt $got,    "$dir/got.yml";
	spruce_fmt $expect, "$dir/expect.yml";

	$got    = get_file "$dir/got.yml";
	$expect = get_file "$dir/expect.yml";

	if ($got eq $expect) {
		pass $msg;
		return 1;
	}
	fail "$msg: strings were different.";
	diag qx(cd $dir/; diff -u expect.yml got.yml);
	return 0;
}

sub expect_exit {
	local $Test::Builder::Level = $Test::Builder::Level + 1;
	my ($cmd, $rc, $msg) = @_;
	$cmd->expect(300, 'eof');
	$cmd->soft_close();
	if ($rc) {
		is $cmd->exitstatus() >> 8, $rc, $msg;
		diag "NOTE: exitstatus() returned from expect was not shifted, exit code 1, indicates SIGHUP, not rc 1"
			if $cmd->exitstat() != 0;
	} else {
		is $cmd->exitstatus(), 0, $msg;
	}
}

sub expect_ok {
	local $Test::Builder::Level = $Test::Builder::Level + 1;
	my $desc = shift;
	my $cmd;
	if (ref($desc) eq "Expect") {
		$cmd = $desc;
		use Data::Dumper;
		$desc = "expected questions from genesis (".Dumper(\@_).")";
	} else {
		$cmd = shift;
	}

	$cmd->expect(10, @_,
		[ timeout => sub {
				$cmd->expect(0,['eof']);
				my $remainder = $cmd->set_accum('');
				fail "Timed out waiting for $desc. Got:\n\n$remainder\n\n";
				done_testing;
				exit;
			}
		]);
}

1;
