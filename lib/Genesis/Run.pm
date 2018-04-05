package Genesis::Run;

use base 'Exporter';
our @EXPORT = qw/run curl/;

use Genesis::Utils;
use File::Basename qw/basename/;

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
		Genesis::Utils::debug("#M{Setting: }#B{$_}='#C{$ENV{$_}}'");
	}
	my $shell = $opts{shell} || '/bin/bash';
	$prog .= ($opts{stderr} ? " 2>$opts{stderr}" : ' 2>&1') unless ($opts{interactive});
	Genesis::Utils::debug("#M{Executing:} `#C{$prog}`%s", ($opts{interactive} ? " #Y{(interactively)}" : ''));
	if (@args) {
		unshift @args, basename($shell);
		Genesis::Utils::debug("#m{ - with arguments:}");
		Genesis::Utils::debug("#m{%4s:} '#c{%s}'", $_, $args[$_]) for (1..$#args);
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
		Genesis::Utils::debug("#R{==== ERROR: $rc}");
		Genesis::Utils::debug("$out\n#R{==== END}") if defined($out);
	} else {
		Genesis::Utils::debug("#g{Command run successfully.}");
	}
	return unless defined(wantarray);
	return
		$opts{passfail}    ? $rc == 0 :
		$opts{interactive} ? (wantarray ? (undef, $rc) : $rc)
		                   : (wantarray ? ($out,  $rc) : $out);
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

sub curl {
	my ($method, $url, $headers, $data, $skip_verify, $creds) = @_;
	my @flags = ("-X", $method);
	push @flags, "-H", "$_: $headers->{$_}" for (keys %$headers);
	push @flags, "-d", $data                if  $data;
	push @flags, "-k"                       if  ($skip_verify);
	push @flags, "-u", $creds               if  ($creds);
	push @flags, "-v"                       if  (envset('GENESIS_DEBUG'));
	my $status = "";
	my $status_line = "";
	my @data = getlines('curl', '-isL', $url, @flags);
	unless (scalar(@data) && $? == 0) {
		interact('curl', '-L', $url, @flags); # curl again to get stdout/err into concourse for debugging
		return 599, "Unable to execute curl command", "";
	}
	while (my $line = shift @data) {
		if ($line =~ m/^HTTP\/\d+\.\d+\s+((\d+)(\s+.*)?)$/) {
			$status_line = $1;
			$status = $2;
		}
		# curl -iL will output a second set of headers if following links
		if ($line =~ /^\s+$/ && $status !~ /^3\d\d$/) {
			last;
		}
	}
	return $status, $status_line, join("", @data);
}

1;

=head1 NAME

Genesis::Run

=head1 DESCRIPTION

This package provides a unified method of executing shell commands, and some
convenience methods to run them in common ways.  Only C<run> and C<curl> are
exported by default, other functions need to be referenced by
fully-qualified namespace (Genesis::Run::*)

=head1 FUNCTIONS

=head2 run([\%opts,] $command, @args)

Run a command.  This is the Swiss Army knife of command execution, with lots
of bells and whistles.

You can operate this in three modes:

    # Single string, embedded arguments
    my ($out, $rc) = run("safe read a/b/c | spruce json");

    # Pre-tokenized array of arguments
    my ($out, $rc) = run('spruce', 'merge', '--skip-eval, @files);

    # Complicated pipeline, pre-tokenized arguments
    my ($out, $rc) = run('spruce merge "$1" - "$2" < "$3.yml"',
                            $file1, $file2, $file3);

In all cases, the output of the command (including STDERR) is returned,
along with the exit code (without the other bits that normally accompany
C<$?>).

The third form is recommended as it properly encapsulates/tokenizes the
arguments to prevent accidental expansion or splitting due to quoting and
spaces.  If using it, remember to quote all variable references.

You can also pass a hash reference as the first argument to supply options
to change the behaviour of the execution.  The following options are
supported:

=over

=item interactive

If true, run the command interactively on a controlling terminal.  This uses
the perl `system` command, so capturing output cannot be done.  Returned
output will be undefined.

=item passfail

If true, returns true if exit code is 0, false otherwise.  Can work in
conjunction with interactive.

=item onfailure

An error message to bail with, in the event that the program either fails to
execute, or exits non-zero.  In non-interactive mode, the output of the
failing command will be printed (in interactive mode, it's already been
printed).

=item env

A hash defining modifications to the execution environment.  These
environment variables will only be set for the duration of the command run.

=item shell

Change the executing shell from C</bin/bash> to something else.  You
generally don't need to set this unless you are doing something strange.

=item stderr

A shell-specific redirection destination for standard error.  This gets
appended to the idiom "2>".  Normally, standard error is redirected back
into standard output.

=over

Finally, if you are not running in C<interactive> or C<passfail> mode, you
can call this in either scalar or list context.  In list context, the output
and exit code are returned in a list, otherwise just the output.

    # scalar context
    my $out = run('grep "$1" "$@"', $pattern, @files);
    my $rc = $? >> 8;

    # list contex
    my ($out, $rc) = run('spruce json "$1" | jq -r "$2"', $_, $filter);


=head2 interact(...)

This helper function sets C<interactive> and C<passfail>, to return truthy
on success.

=head2 bosh(...)

Configures a custom environment for the BOSH CLI.

=head2 interactive_bosh(...)

Works like C<bosh>, but with C<interactive> on.

=head2 check(...)

Sets C<passfail>, to be used in boolean conditions.

=head2 do_or_die($msg, ...)

Runs the command (honoring other options), and if it exits non-zero, dies
with the given error C<$msg>, printing any output that the command printed.

=head2 get(...)

Returns just the output, regardless of context (scalar or list).

=head2 getlines(...)

Like C<get>, but it splits the output on newlines and returns the list of
lines.

=cut
