package helper;
use lib 't';
use Test::More;
use Test::Exception;
use Test::Differences;
use Test::TCP;
use IO::Socket::IP ();
use Cwd ();
use Config;
use Encode;
use File::Temp qw/tempdir/;
use File::Basename qw/dirname/;
use JSON::PP;
unified_diff;

$ENV{GENESIS_TESTING} = "yes";

our $TOPDIR;
sub import {
	my ($class, @args) = @_;
	$TOPDIR = Cwd::getcwd();
	$TOPDIR =~ s|/[^/]*$|| until (-f "${TOPDIR}/bin/genesis" && -d "${TOPDIR}/t/")  || $TOPDIR eq "";
	unless (-f "${TOPDIR}/bin/genesis" && -d "${TOPDIR}/t/") {
		print "Could not find bin/genesis under the current directory. Cannot continue\n";
		exit 2
	}

	# Clear out t/tmp each test
	if ( -d "${TOPDIR}/t/tmp") {
		`rm -rf ${TOPDIR}/t/tmp`;
		$? eq "0" or die "Failed to clear test work directory";
	}
	`mkdir -p ${TOPDIR}/t/tmp/home`;
	$? eq "0" or die "Failed to create test work and home directory";

	$ENV{HOME} = "${TOPDIR}/t/tmp/home";
	$ENV{GENESIS_TOPDIR} = $TOPDIR;
	$ENV{PATH} = "${TOPDIR}/bin:$ENV{PATH}";
	$ENV{OFFLINE} = 'y';
	$ENV{GENESIS_LIB} = "$ENV{GENESIS_TOPDIR}/lib";

	my $caller = caller;
	for my $glob (sort keys %helper::) {
		next if not defined *{$helper::{$glob}}{CODE}
		         or $glob eq 'import';
		*{$caller . "::$glob"} = \&{"helper::$glob"};
	}
	for my $var (qw(TOPDIR VAULT_URL)) {
		*{$caller . "::$var"} = \${"helper::$var"};
	}
	for my $var (qw(VAULT_URL)) {
		*{$caller . "::$var"} = \%{"helper::$var"};
	}
	runs_ok("genesis ping") or die "`genesis ping` failed...\n";
}

sub reset_kit {
	my $kit = shift;
	$kit->{root} = undef;
	$kit->{__hook_check} = undef;
	$kit->{extract};
}

our $WORKDIR = undef;
sub workdir {
	$WORKDIR ||= tempdir(CLEANUP => 1);
	return $WORKDIR unless @_;
	my $path = join '/', $WORKDIR, @_;
	qx(mkdir -p $path);
	return $path;
}

sub mkdir_or_fail {
	my ($dir) = @_;
	unless (-d $dir) {;
		`mkdir -p "$dir"`;
		$? eq "0" or die "Failed to create directory $dir";
	}
	return $dir;
}

sub put_file {
	local $Test::Builder::Level = $Test::Builder::Level + 1;
	my ($file, $mode, $contents) = @_;
	if (! defined($contents)) {
		$contents = $mode;
		$mode = undef;
	}
	system("mkdir -p ".dirname($file));
	open my $fh, ">", $file
		or fail "failed to open '$file' for writing: $!";

	print $fh $contents;
	close $fh;
	chmod $mode, $file if defined($mode);
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
			if ($version =~ /version (\S+?)(-.*)?/) {
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
  unless ($script) {
    my $contents = '{"cmd": "<<<$@>>>"}\n';
    $contents =~ s/\n/\\n/g;
    $contents =~ s/\r/\\r/g;
    $contents =~ s/'/'\\''/g;
    $contents =~ s/"/\\"/g;
    my $json=<<EOF;
{
  "Tables": [
      {
          "Content": "config",
          "Header": {
              "content": "Content",
              "created_at": "Created At",
              "id": "ID",
              "name": "Name",
              "type": "Type"
          },
          "Rows": [
              {
                  "content": "$contents",
                  "created_at": "2020-06-10 16:50:02 UTC",
                  "id": "18",
                  "name": "default",
                  "type": "cloud"
              }
          ],
          "Notes": []
      }
  ],
  "Blocks": null,
  "Lines": [
      "Succeeded"
  ]
}
EOF
    my $json_printout = join("\n", map {(my $l = $_) =~ s/'/'\\''/g; "    echo '$l'"} split("\n", $json));
    $script=<<EOF;
#!/bin/bash
args="\$(echo "bosh \$*" | sed -e 's/"/"\\""/g')"
if [[ \$args =~ \\ --json(\\ |\$) ]] ; then
  (
$json_printout
  ) | sed -e "s/<<<\\\$@>>>/\$args/"
else
  echo "bosh"
  for x in "\$@" ; do printf "%s\\n" "\$x"; done
fi
  exit 0
EOF
  }

	my $tmp = workdir;
	put_file("$tmp/fake-bosh", $script);
	chmod(0755, "$tmp/fake-bosh");
	$ENV{GENESIS_BOSH_COMMAND} = "$tmp/fake-bosh";
}

sub bosh_runs_as {
	my ($expect, $output,%vars) = @_;
	$output = $output ? join("\n", map {"echo '$_'"} split("\n", $output)) : "";
	my $var_checks = '';
	for $var (keys %vars) {
		my $val = $vars{$var};
		$var_checks .= (<<EOF);
if [[ "\$$var" != "$val" ]] ; then
	varfail=1
	echo >&2 "$var: want '$val, got '\$$var'"
fi
EOF
	}
	fake_bosh(<<EOF);
$output
varfail=0
$var_checks
[[ "\$@" == "$expect" && \$varfail == 0 ]] && exit 0;
if [[  "\$@" == "$expect" ]] ; then
  echo >&2 "Output:"
  echo >&2 "got  '\$@\'"
  echo >&2 "want '$expect'"
fi
exit 2
EOF
}

sub bosh_outputs_json {
	my ($cmd,$contents) = @_;
	$contents = '{"cmd": "<<<$@>>>"}\n' unless defined($contents);
	$contents =~ s/\n/\\n/g;
	$contents =~ s/\r/\\r/g;
	$contents =~ s/'/'\\''/g;
	$contents =~ s/"/\\"/g;
	$cmd =~ s/"/\\"/g;
	my $json=<<EOF;
{
    "Tables": [
        {
            "Content": "config",
            "Header": {
                "content": "Content",
                "created_at": "Created At",
                "id": "ID",
                "name": "Name",
                "type": "Type"
            },
            "Rows": [
                {
                    "content": "$contents",
                    "created_at": "2020-06-10 16:50:02 UTC",
                    "id": "18",
                    "name": "default",
                    "type": "cloud"
                }
            ],
            "Notes": []
        }
    ],
    "Blocks": null,
    "Lines": [
        "Ran as '<<<\$@>>>'",
        "Expected '$cmd'",
        "Succeeded"
    ]
}
EOF
	$output=<<EOF;
	args="\$(echo "\$*" | sed -e 's/"/"\\""/g' | set -e 's#/#\/#g')"
EOF
	$output.="(\n";
	$output.= join("\n", map {(my $l = $_) =~ s/'/'\\''/g; "echo '$l'"} split("\n", $json));
	$output.="\n) | sed -e \"s/<<<\\\$@>>>/\$args/\"";
	fake_bosh($output);
}

sub write_bosh_config {
	my $orig_home=`echo ~\$USER`;
	my $config="";
	my @args = (@_);
	for my $info (@args) {
		if (ref($info) ne "HASH") {
			$info = {
				alias => $info
			};
		}
		my $url = sprintf("%s://%s%s",
			($info->{schema} || "https"),
			($info->{host}   || "127.0.0.1"),
			(defined($info->{port}) ? ':'.$info->{port} : '')
		);
		if ($info->{config_type} eq 'file' || !defined($VAULT_URL)) {
			$config .= "- url: $url\n".
			           "  ca_cert: |-\n" .
			           "    -----BEGIN CERTIFICATE-----\n".
			           "    MIIExxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n".
			          ("    xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n" x 24).
			           "    xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=\n".
			           "    -----END CERTIFICATE-----\n".
			           "  alias: ".$info->{alias}."\n".
			           "  username: ".($info->{username} || 'noname')."\n".
			           "  password: ".($info->{password} || 'nopassword')."\n";
		} else {
			# Store config in exodus data
			my $exodus->{"secret/exodus/$info->{alias}/bosh"} = {
				kit_name => 'bosh',
				url => $url,
				admin_username => ($info->{username} || 'noname'),
				admin_password => ($info->{password} || 'nopassword'),
				ca_cert => 
					"-----BEGIN CERTIFICATE-----\n".
					"MIIExxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n".
					("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n" x 24).
					"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=\n".
					"-----END CERTIFICATE-----"
			};
			{
				my @cmd = ('/bin/bash', "-c", 'echo "$1" | jq -r . | safe import 2>&1', 'bash', JSON::PP::encode_json($exodus));
				open my $pipe, "-|", @cmd;
				$out = do { local $/; <$pipe> };
				$out =~ s/\s+$//;
				close $pipe;
			}
		}
	}
	if ($config) {
		if ($ENV{HOME} eq $orig_home) {
			die 'Refusing to over-write real .bosh/config!';
		}
		mkdir_or_fail("$ENV{HOME}/.bosh");
		put_file( "$ENV{HOME}/.bosh/config","environments:\n$config");
	}
}


sub fake_bosh_directors {
	write_bosh_config(@_);
	my @directors = ();
	my @args = (@_);
	my $last_port=25555;
	for my $info (@args) {
		if (ref($info) ne "HASH") {
			$info = {
				alias => $info
			};
		}
		push @directors, Test::TCP->new(
			listen => 0,
			auto_start => 1,
			port => $info->{port} || ($last_port++),
			code => sub {
				my $port = shift;
				my $sock =  IO::Socket::IP->new(
					LocalPort => $port,
					LocalAddr => $info->{host} || "127.0.0.1",
					Proto     => 'tcp',
					Listen    => 5,
					Type      => IO::Socket::IP::SOCK_STREAM,
					V6Only    => 1,
					(($^O eq 'MSWin32') ? () : (ReuseAddr => 1)),
				) or die "Cannot open server socket: $!";

				while (my $remote = $sock->accept) {
					while (my $line = <$remote>) {
						note "new request";
						my ($remote, $line, $sock) = @_;
						print {$remote} $line;
						exit 0 if $line eq "quit\n";
					}
				}

				undef $sock;
			}
		);
	}
	return @directors;
}
sub fake_bosh_director {
	my ($director) = fake_bosh_directors({alias => $_[0], port => $_[1]});
	return $director;
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

sub matches_utf8 {
	local $Test::Builder::Level = $Test::Builder::Level + 1;
	my ($output, $expected, $msg) = @_;

	return eq_or_diff $output, encode_utf8($expected), $msg;
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

sub quietly(&) {
	local *STDERR;
	open(STDERR, '>', '/dev/null') or die "failed to quiet stderr!";
	return $_[0]->();
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

my %VAULT_PID;
our %VAULT_URL;
our $VAULT_URL;
sub vault_ok {
	my $target = shift || "genesis-ci-unit-tests";
	local $Test::Builder::Level = $Test::Builder::Level + 1;
	if (defined $VAULT_PID{$target}) {
		pass "vault already running.";
		return $target;
	}

	my $pid = qx(SAFE_TARGET= $ENV{GENESIS_TOPDIR}/t/bin/vault $target);
	my $rc = $? >> 8;
	if ($rc > 0 || $pid eq "") {
		fail "failed to spin a vault server: pid='$pid' rc=$rc";
		die "Cannot continue\n";
	};
	fail "expected numeric value for Vault pid, but got this:\n$pid\n" unless $pid =~ /^[0-9]+$/;

	chomp($pid);
	$VAULT_PID{$target} = $pid;
	kill -0, $pid or do {
		fail "failed to spin a vault server: couldn't signal pid $pid.";
		die "Cannot continue\n";
	};
	pass "vault running [pid $pid]";
	chomp($VAULT_URL = `SAFE_TARGET=$target safe env --json | jq -r '.VAULT_ADDR'`);
	$VAULT_URL{$target} = $VAULT_URL;  # track the latest
	return $target;
}

sub teardown_vault {
	my @targets = @_ || keys %VAULT_PID;
	for my $target (@targets) {
		if (defined $VAULT_PID{$target}) {
			print STDERR "\nShutting down vault '$target' (pid: $VAULT_PID{$target})\n"
			if defined $ENV{DEBUG_TESTS} and $ENV{DEBUG_TESTS} =~ m/^(1|y|yes|true)$/i;
			kill 'TERM', $VAULT_PID{$target};
			$VAULT_PID{$target} = undef;
			$VAULT_URL{$target} = undef;
			$VAULT_URL = undef;
		}
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
	my ($cmd, $expected_rc, $msg) = @_;
	$cmd->expect(300, 'eof');
	$cmd->soft_close();
	my ($rc,$sig) = ref($expected_rc) eq 'ARRAY' ? @{$expected_rc} : ($expected_rc||0,0);
	my $real_sig = $cmd->exitstatus() & 255;
	my $real_rc  = $cmd->exitstatus() >> 8;
	is $real_rc,  $rc,  $msg;
	is $real_sig, $sig, sprintf("%s (Got signal %s with %s coredump)",$msg, $real_sig & 127, $real_sig & 128 ? '' : 'no');
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
