package Genesis::Run;

use base 'Exporter';
our @EXPORT = qw/run/;

use Genesis::Utils;
use File::Basename qw/basename/;

# This package provides a unified method of executing shell commands, and some
# convenience methods to run them in common ways.
#
# You can operate this in three modes:
#
#   1) Pass the command as a string with all the arguments in it.
#      eg: run("safe read auth/approle/role/$role_name/role-id | spruce json | jq -r .role_id | safe paste $role_p $role_k");
#
#   2) Pass the command as an array -- this only works if no pipes or redirects are involved.
#      eg: run(qw(spruce merge --skip-eval), @files)
#
#   3) Pass the command as a template, and the template args as an array
#      eg: run('safe read "$1" | spruce json | jq -r .role_id | safe paste "$2" "$3"',
#                  "auth/approle/role/$role_name/role-id",
#                  $role_p,
#                  $role_k
#          );
#
# The latter is recommended as it properly encapsulates/tokenizes the
# arguments to prevent accidental expansion or splitting due to quoting
# and spaces.  If using it, remember to quote all variable references.
#
# You can also pass a hash reference as the first argument to supply options to
# change the behaviour of the execution.  The following options are supported:
#
#   interactive: boolean - If true, run the command interactively on a
#                controlling terminal.  This uses the perl `system` command, so
#                capturing output cannot be done.  Returns exit code.
#
#   passfail:    boolean - If true, returns true if exit code is 0, false
#                otherwise.  Can work in conjunction with interactive.
#
#   onfailure:   string - Print the string on error and exit program.  If not
#                running interactively, also prints the output received.
#
#   env:         hash - Sets the env variables specified as keys in the hash to
#                the corresponding values before executing the command.
#
#   shell:       string - By default, will use /bin/bash, but if the command
#                needs a different shell, specify it with this option.
#
#   stderr:      string - By default, stderr is redirected to stdout (&1), but
#                you can use this option to redirect it to a file for later
#                use.  If you want to capture stderr but not stdout, you can
#                specify `{stderr => '&1 >/dev/null'`.  
#                Cannot use with interactive mode.
#
# Finally, if you are not running in interactive or passfail mode, you can call
# this in either scalar or list context.  If calling in list context, the output
# and exit code are returned in a list, otherwise just the output.
#
# Scalar context:
#   my $out = run('grep "$1" "$@"', $pattern, @files);
#   my $rc = $? >> 8;
#
# List context:
#   my ($out,$rc) = run('spruce json "$1" | jq -r "$2"', $_, $filter);
#
# -----------------------------------------------------------------------------
# Convenience commands:
#
# interact - sets the mode to interactive and passfail, returns 1 on success,
#            0 otherwise.
#
# bosh - sets the environment for bosh and injects the correct bosh executable
#
# interactive_bosh - same as bosh, but using interactive and passfail modes
#
# check - sets passfail mode, no output returned.
#
# do_or_die - first argument is printed along with any output received, then
#             exits non-zero (dies) if remaining argument fails execution
#
# get - returns just output (chomped), regardless of context
#
# getlines - returns output as an array of lines
#
sub run {
	my (@args) = @_;
	my %opts = %{((ref($args[0]) eq 'HASH') ? shift @args: {})};
	my $prog = shift @args;
	if ($prog !~ /\$\{?[\@0-9]/ && scalar(@args) > 0) {
		$prog .= ' "$@"'; # old style of passing in args as array, need to wrap for shell call
	}

	local %ENV = %ENV; # To get local scope for duration of this call
	for (keys %{$opts{env} || {}}) {
		$ENV{$_} = $opts{env}{$_};
		debug("#M{Setting: }#B{$_}='#C{$ENV{$_}}'");
	}
	my $shell = $opts{shell} || '/bin/bash';
	$prog .= ($opts{stderr} ? " 2>$opts{stderr}" : ' 2>&1') unless ($opts{interactive});
	debug("#M{Executing:} `#C{$prog}`%s", ($opts{interactive} ? " #Y{(interacively)}" : ''));
	if (@args) {
		unshift @args, basename($shell);
		debug("#m{ - with arguments:}");
		debug("#m{%4s:} '#c{%s}'", $_, $args[$_]) for (1..$#args);
	}

	my @cmd = ($shell, "-c", $prog, @args);
	my $out;
	if ($opts{interactive}) {
		system @cmd;
	} else {
		open my $pipe, "-|", @cmd;
		$out = do { local $/; <$pipe> };
		close $pipe;
	}
	my $rc = $? >>8;
	if ($rc) {
		if ($opts{onfailure}) {
			explain("#R{[ERROR/%d] }%s%s", $rc, $opts{onfailure}, defined($out) ? ":\n$out" :'');
			exit $rc;
		}
		debug("#R{==== ERROR: $rc}");
		debug("$out\n#R{==== END}") if defined($out);
	} else {
		debug("#g{Command run successfully.}");
	}
	return unless defined(wantarray);
	return
		$opts{passfail}    ? $rc == 0 :
		$opts{interactive} ? $rc :
		wantarray          ? ($out,$rc) :
		$out;
}

sub interact {
	my @args = @_;
	my $opts = (ref($args[0]) eq 'HASH') ? shift @args : {};
	$opts->{interactive} = 1;
	$opts->{passfail} = 1;
	return run($opts,@args);
}

sub check {
	my @args = @_;
	my $opts = (ref($args[0]) eq 'HASH') ? shift @args : {};
	$opts->{interactive} = 0;
	$opts->{passfail} = 1;
	return run($opts,@args);
}

sub bosh {
	my @args = @_;

	die "Unable to determine where the bosh CLI lives.  This is a bug, please report it.\n"
		unless $ENV{GENESIS_BOSH_COMMAND};

	my $opts = (ref($args[0]) eq 'HASH') ? shift @args : {};
	$opts->{env} ||= {};
	# Clear out the BOSH env vars unless we're under Concourse
	unless ($ENV{BUILD_PIPELINE_NAME}) {
		$opts->{env}{HTTPS_PROXY} = ''; # bosh dislikes this env var
		$opts->{env}{https_proxy} = ''; # bosh dislikes this env var
		$opts->{env}{BOSH_ENVIRONMENT}   ||= ''; # ensure using ~/.bosh/config via alias
		$opts->{env}{BOSH_CA_CERT}       ||= '';
		$opts->{env}{BOSH_CLIENT}        ||= '';
		$opts->{env}{BOSH_CLIENT_SECRET} ||= '';
	}
	if ($args[0] =~ /\$\{?[\@0-9]/ && scalar(@args) > 1) {
		$args[0] = $ENV{GENESIS_BOSH_COMMAND} ." $args[0]";
	} else {
		unshift @args, $ENV{GENESIS_BOSH_COMMAND}
	}
	return run($opts,@args);
}

sub interactive_bosh {
	my @args = @_;
	my $opts = (ref($args[0]) eq 'HASH') ? shift @args : {};
	$opts->{interactive} = 1;
	$opts->{passfail} = 1;
	return bosh($opts,@args);
}

sub do_or_die {
	my @args = @_;
	my $opts = (ref($args[0]) eq 'HASH') ? shift @args : {};
	$opts->{onfailure} = shift @args;
	run($opts,@args);
	return undef;
}

sub get {
	my @args = @_;
	my $opts = (ref($args[0]) eq 'HASH') ? shift @args : {};
	delete @{$opts}{qw/interactive passfail/};
	my ($out, undef) = run($opts,@args);
	chomp($out);
	return $out;
}

sub getlines {
	my $out = get(@_);
	return ($? >> 8) ? () : split $/, $out;
}

1;
