package helper;
use Test::More;
use Cwd ();
use Config;
use File::Temp qw/tempdir/;

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
	my ($file, $contents) = @_;
	open my $fh, ">", $file
		or fail "failed to open '$file' for writing: $!";

	print $fh $contents;
	close $fh;
}

sub get_file($) {
	my ($file) = @_;
	open my $fh, "<", $file
		or fail "failed to open '$file' for reading: $!";

	my $contents = do { local $/; <$fh> };
	close $fh;
	return $contents;
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
	return wantarray ? (1, $exit, $err) : 1;
}

sub run_fails($$;$) {
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
	my ($cmd, $msg) = @_;
	return runs_ok "${TOPDIR}/t/expect/$cmd", $msg;
}

sub expect_fails($;$) {
	my ($cmd, $msg) = @_;
	return run_fails "${TOPDIR}/t/expect/$cmd", $msg;
}

sub output_ok($$;$) {
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
	runs_ok "bosh help", "the BOSH ruby CLI works ok"
		or die "There seems to be something wrong with your Ruby BOSH CLI.\n";
}

sub bosh2_cli_ok {
	runs_ok "bosh2 help", "the BOSH2 golang CLI works ok"
		or die "There seems to be something wrong with your bosh2 CLI.\n";
}

sub no_env($;$) {
	my ($env, $msg) = @_;
	$msg ||= "$env environment (in $env.yml) should not exist";
	ok ! -f "$env.yml", $msg;
}

sub have_env($;$) {
	my ($env, $msg) = @_;
	$msg ||= "$env environment (in $env.yml) should exist";
	ok -f "$env.yml", $msg;
}

my $VAULT_PID;
sub vault_ok {
	if (defined $VAULT_PID) {
		pass "vault already running.";
		return 1;
	}

	$ENV{HOME} = "$ENV{PWD}/t/tmp/home";
	my $pid = qx(./t/bin/vault) or do {
		fail "failed to spin a vault server in (-dev) mode.";
		die "Cannot continue\n";
	};

	chomp($pid);
	$VAULT_PID = $pid;
	kill -0, $pid or do {
		fail "failed to spin a vault server in (-dev) mode: couldn't signal pid $pid.";
		die "Cannot continue\n";
	};
	pass "vault running [pid $pid]";
	return 1;
}

sub teardown_vault {
	if (defined $VAULT_PID) {
		print STDERR "\nShutting down vault (pid: $VAULT_PID)\n";
		kill 'TERM', $VAULT_PID;
	}
}

sub no_secret($;$) {
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

sub no_secret($;$) {
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
	my ($cmd, $rc, $msg) = @_;
	$cmd->expect(300, 'eof');
	$cmd->soft_close();
	if ($rc) {
		is $cmd->exitstatus() >> 8, $rc, $msg;
	} else {
		is $cmd->exitstatus(), 0, $msg
			or diag "NOTE: exitstatus() returned from expect was not shifted, exit code 1, indicates SIGHUP, not rc 1";
	}
}

sub expect_ok {
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
sub colorize {
	my ($c, $msg) = @_;
	$c = substr $c, 1, 1;
	my %color = (
		'k'		=> "\e[30m",     #black
		'K'		=> "\e[1;30m",   #black (BOLD)
		'r'		=> "\e[31m",     #red
		'R'		=> "\e[1;31m",   #red (BOLD)
		'g'		=> "\e[32m",     #green
		'G'		=> "\e[1;32m",   #green (BOLD)
		'y'		=> "\e[33m",     #yellow
		'Y'		=> "\e[1;33m",   #yellow (BOLD)
		'b'		=> "\e[34m",     #blue
		'B'		=> "\e[1;34m",   #blue (BOLD)
		'm'		=> "\e[35m",     #magenta
		'M'		=> "\e[1;35m",   #magenta (BOLD)
		'p'		=> "\e[35m",     #purple (alias for magenta)
		'P'		=> "\e[1;35m",   #purple (BOLD)
		'c'		=> "\e[36m",     #cyan
		'C'		=> "\e[1;36m",   #cyan (BOLD)
		'w'		=> "\e[37m",     #white
		'W'		=> "\e[1;37m",   #white (BOLD)
	);

	if ($c eq "*") {
		my @rainbow = ('R','G','Y','B','M','C');
		my $i = 0;
		my $msgc = "";
		foreach my $char (split //, $msg) {
			$msgc = $msgc . "$color{$rainbow[$i%6]}$char";
			if ($char =~ m/\S/) {
				$i++;
			}
		}
		return "$msgc\e[0m";
	} else {
		return "$color{$c}$msg\e[0m";
	}
}

sub csprintf {
	my ($fmt, @args) = @_;
	return '' unless $fmt;
	my $s = sprintf($fmt, @args);
	$s =~ s/(#[KRGYBMPCW*]\{)(.*?)(\})/colorize($1, $2)/egi;
	return $s;
}

1;
