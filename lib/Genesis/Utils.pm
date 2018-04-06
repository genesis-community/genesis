package Genesis::Utils;
use strict;
use warnings;

use File::Basename qw/basename/;
use Cwd qw//;

use base 'Exporter';
our @EXPORT = qw/
	envset envdefault

	csprintf
	explain debug trace error
	bail

	workdir

	semver
	new_enough

	parse_uri
	is_valid_uri

	ordify

	run lines bosh curl

	slurp
	mkfile_or_fail mkdir_or_fail
	chdir_or_fail chmod_or_fail
	symlink_or_fail
	copy_or_fail

	load_json
	load_yaml load_yaml_file

	pushd popd
/;

use File::Temp qw/tempdir/;
use JSON::PP qw//;

sub envset {
	my ($var) = @_;
	return (defined $ENV{$var} and $ENV{$var} =~ m/^(1|y|yes|true)$/i);
}

sub envdefault {
	my ($var, $default) = @_;
	return defined $ENV{$var} ? $ENV{$var} : $default;
}

sub _colorize {
	my ($c, $msg) = @_;
	return $msg if envset('NOCOLOR');
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
	$s =~ s/(#[KRGYBMPCW*]\{)(.*?)(\})/_colorize($1, $2)/egi;
	return $s;
}
sub explain {
	return if envset "QUIET";
	{ local $ENV{NOCOLOR} = "yes" unless -t STDOUT;
	        print csprintf(@_); }
	print "\n";
}

sub debug {
	return unless envset "GENESIS_DEBUG"
	           or envset "GENESIS_TRACE";
	print STDERR "DEBUG> ";
	{ local $ENV{NOCOLOR} = "yes" unless -t STDOUT;
	        print STDERR csprintf(@_); }
	print STDERR "\n";
}

sub trace {
	return unless envset "GENESIS_TRACE";
	print STDERR "TRACE> ";
	{ local $ENV{NOCOLOR} = "yes" unless -t STDOUT;
	        print STDERR csprintf(@_); }
	print STDERR "\n";
}

sub error {
	my @err = @_;
	unshift @err, "%s" if $#err == 0;
	print STDERR csprintf(@err) . "\n";
}

sub bail {
	my @err = @_;
	unshift @err, "%s" if $#err == 0;
	$! = 1; die csprintf(@_)."\n";
}

my $WORKDIR;
sub workdir {
	$WORKDIR ||= tempdir(CLEANUP => 1);
	return tempdir(DIR => $WORKDIR);
}

sub semver {
	my ($v) = @_;
	if ($v && $v =~ m/^v?(\d+)(?:\.(\d+)(?:\.(\d+)(?:[.-]rc[.-]?(\d+))?)?)?$/i) {
		return wantarray ? ($1, $2 || 0, $3 || 0, (defined $4 ? $4 - 100000 : 0))
		                 : [$1, $2 || 0, $3 || 0, (defined $4 ? $4 - 100000 : 0)];
	}
	return undef;
}

sub new_enough {
	my ($v, $min) = @_;
	my @v = semver($v);
	my @min = semver($min);
	while (@v) {
		return 1 if $v[0] > $min[0];
		return 0 if $v[0] < $min[0];
		shift @v;
		shift @min;
	}
	return 1;
}

our %ord_suffix = (11 => 'th', 12 => 'th', 13 => 'th', 1 => 'st', 2 => 'nd', 3 => 'rd');
sub ordify {
	return "$_[0]". ($ord_suffix{ $_[0] % 100 } || $ord_suffix{ $_[0] % 10 } || 'th')." ";
}

sub parse_uri {
	my ($uri) = @_;
	# https://tools.ietf.org/html/rfc3986
	# We use very basic validation
	$uri =~ m/^(?<uri>
		(?<scheme>[a-zA-Z][a-zA-Z0-9+.-]+):\/\/
		(?<authority>
			(?:(?<userinfo>(?<user>[^:@]+)(?::(?<password>[^@]+)))?@)?
			(?<host>[a-zA-Z0-9.\-_~]+)?
			(?::(?<port>\d+))?
		)
		(?<path>(?:[a-zA-Z0-9-._~]|[a-f0-9]|[!\$&'()*+,;=:@])+(?:\/(?:[a-zA-Z0-9-._~]|[a-f0-9]|[!\$&'()*+,;=:@])*)*|(?:\/(?:[a-zA-Z0-9-._~]|[a-f0-9]|[!\$&'()*+,;=:@])+)*)?
		(?:\?(?<query>(?:[a-zA-Z0-9-._~]|[a-f0-9]|[!\$&'()*+,;=:@]|%[A-Fa-f0-9]{2})+))?
		(?:\#(?<fragment>(?:[a-zA-Z0-9-._~]|[a-f0-9]|[!\$&'()*+,;=:@])+))?
	)$/gsx;
	return %+;
}

sub is_valid_uri {
	my %components = parse_uri($_[0]);
	return unless ($components{scheme}||"") =~ /^(https?|file)$/;
	return unless $components{authority} || ($components{scheme} eq 'file' && $components{path});
	return $components{uri};
}

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
	debug("#M{Executing:} `#C{$prog}`%s", ($opts{interactive} ? " #Y{(interactively)}" : ''));
	if (@args) {
		unshift @args, basename($shell);
		debug("#M{ - with arguments:}");
		debug("#M{%4s:} '#C{%s}'", $_, $args[$_]) for (1..$#args);
	}

	my @cmd = ($shell, "-c", $prog, @args);
	my $out;
	if ($opts{interactive}) {
		system @cmd;
	} else {
		open my $pipe, "-|", @cmd;
		$out = do { local $/; <$pipe> };
		$out =~ s/\s+$//;
		close $pipe;
	}
	my $rc = $? >>8;
	if ($rc) {
		if ($opts{onfailure}) {
			bail("#R{%s} (run failed)%s", $opts{onfailure}, defined($out) ? ":\n$out" :'');
		}
		debug("#R{==== ERROR: $rc}");
		debug("$out\n#R{==== END}") if defined($out);
	} else {
		debug("#g{Command run successfully.}");
	}
	return unless defined(wantarray);
	return
		$opts{passfail}    ? $rc == 0 :
		$opts{interactive} ? (wantarray ? (undef, $rc) : $rc) :
		$opts{onfailure}   ? $out
		                   : (wantarray ? ($out,  $rc) : $out);
}

sub lines {
	my ($out, $rc) = @_;
	return $rc ? () : split $/, $out;
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

	return run($opts, @args);
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

	my @data = lines(run('curl', '-isL', $url, @flags));

	unless (scalar(@data) && $? == 0) {
		# curl again to get stdout/err into concourse for debugging
		run({ interactive => 1 }, 'curl', '-L', $url, @flags);
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

sub slurp {
	my ($file) = @_;
	open my $fh, "<", $file
		or die "failed to open '$file' for reading: $!\n";
	my $contents = do { local $/; <$fh> };
	close $fh;
	return $contents;
}

sub mkfile_or_fail {
	my ($file, $mode, $content) = @_;
	unless (defined($content)) {
		$content = $mode;
		$mode = undef;
	}
	debug("creating file $file");
	eval {
		open my $fh, ">", $file or die $!;
		print $fh $content;
		close $fh;
	} or die "Error creating file $file: $!\n";
	chmod_or_fail($mode, $file) if defined $mode;
	return $file;
}

sub mkdir_or_fail {
	my ($dir,$mode) = @_;
	unless (-d $dir) {;
		debug("creating directory $dir/");
		run({ onfailure => "Unable to create directory $dir" },
			'mkdir -p "$1"', $dir);
	}
	chmod_or_fail($mode, $dir) if defined $mode;
	return $dir;
}
sub chdir_or_fail {
	my ($dir) = @_;
	debug("changing current working directory to $dir/");
	chdir $dir or die "Unable to change directory to $dir/: $!\n";
}

sub symlink_or_fail {
	my ($source, $dest) = @_;
	-e $source or die "$source does not exist!\n";
	-e $dest and die abs_path($dest)." already exists!";
	symlink($source, $dest) or die "Unable to link $source to $dest: $!\n";
}

sub copy_or_fail {
	my ($from, $to) = @_;
	-f $from or die "$from: $!\n";
	open my $in,  "<", $from or die "Unable to open $from for reading: $!\n";
	open my $out, ">", $to   or die "Unable to open $to for writing: $!\n";
	print $out $_ while (<$in>);
	close $in;
	close $out;
}
# chmod_or_fail 0755, $path; <-- don't quote the mode. make it an octal number.
sub chmod_or_fail {
	my ($mode, $path) = @_;
	-e $path or die "$path: $!\n";
	chmod $mode, $path
		or die "Could not change mode of $path: $!\n";
}

sub load_json {
	my ($json) = @_;
	return JSON::PP->new->allow_nonref->decode($json);
}

sub load_yaml_file {
	my ($file) = @_;
	my ($out, $rc) = run('spruce json "$1"', $file);
	return $rc ? undef : load_json($out);
}

sub load_yaml {
	my ($yaml) = @_;

	my $tmp = workdir();
	open my $fh, ">", "$tmp/json.yml"
		or die "Unable to create tempfile for YAML conversion: $!\n";
	print $fh $yaml;
	close $fh;
	return load_yaml_file("$tmp/json.yml")
}


my @DIRSTACK;
sub pushd {
	my ($dir) = @_;
	push @DIRSTACK, Cwd::cwd;
	chdir_or_fail($dir);
}
sub popd {
	@DIRSTACK or die "popd called when we don't have anything on the directory stack; please file a bug\n";
	chdir_or_fail(pop @DIRSTACK);
}

1;

=head1 NAME

Genesis::Utils

=head1 DESCRIPTION

This module contains assorted and sundry utilities that more or less stand
on their own.  All of these procedures are exported by default.

    use Genesis::Utils;
    explain("utilities are utilitous!");

=head1 FUNCTIONS

=head2 envset($var)

Returns true if the environment variable C<$var> has been set to a truthy
value, which are: 1, "y", "yes", and "true", case-insensitive.

=head2 envdefault($var, [$default])

Returns the value of the environment variable C<$var>, or the value
C<$default> if the environment variable is not set.  Note that there is a
difference between an environment variable with no value (it is still set),
and an unset variable.

=head2 csprintf($fmt, ...)

Formats a string, interpreting sequences like C<#X{...}> as ANSI colorized
regions.  The following values for C<X> are supported:

    K, k    Black
    R, r    Red
    G, g    Green
    Y, y    Yellow
    B, b    Bulue
    M, m    Magenta
    P, p    (alias for Magenta)
    C, c    Cyan
    W, w    White
    *       RAINBOW MODE

Uppercase letters indicate bold coloring, which is usually what you want.

Example:

    print csprintf("Life is #G{good}!\n");
    print csprintf("Life is #G{%s}!\n", "good");

The C<*> color format activates RAINBOW MODE, in which each printable
characters gets a different color, cycling through the sequence RGYBMC.
Try it; it's fun.

=head2 explain($fmt, ...)

Print a message to standard output, unless the C<$QUIET> environment
variable has been set to a truthy value (i.e. "yes").  Supports color
formatting codes.  A trailing newline will be added for you.

C<explain> is for normal, everyday messages, prompts, etc.

=head2 debug($fmt, ...)

Print debugging output to standard error, but only if either the
C<$GENESIS_DEBUG> or C<$GENESIS_TRACE> environment variables have been set.
Supports color formatting codes.  A trailing newline will be added for you.
Debug messages are all prefix with the string "DEBUG> ".

C<debug> is for verbose output that might help an operator troubleshoot a
configuration or environmental issue.

=head2 trace($fmt, ...)

Print trace-level debugging (super debugging) to standard error, but only if
the C<$GENESIS_TRACE> environment variable has been set.
Supports color formatting codes.  A trailing newline will be added for you.
Debug messages are all prefix with the string "TRACE> ".

C<trace> is for extra-verbose internal messages that might help a Genesis
core contributor figure out why Genesis is being bad in the wild.

=head2 error($fmt, ...)

Print an error to standard error, but do not interrupt the flow of
execution (as opposed to C<bail>).  This function does not honor C<$QUIET>.
Supports color formatting codes.  A trailing newline will be added for you.

=head2 bail($fmt, ...)

Print an error to standard error, and exit the program immediately, with an
exit code of C<1>.  This function does not honor C<$QUIET>.
Supports color formatting codes.  A trailing newline will be added for you.

=head2 workdir()

Generate a unique, temporary directory to be used for scratch space.  When
the program exits, all provisioned work directories will be cleaned up.

=head2 semver($v)

Parses a semantic version string, and returns it as an array of the major,
minor, revision, and release candidate components.  If any piece is missing
(i.e. "1.0"), inferior components are treated as '0'.  This makes "1.0"
equivalent to "1.0.0-rc.0".

The following version formats are recognized:

    1
    1.0
    1.23
    1.23.4
    1.23.4-rc2
    1.23.4-rc.2
    1.23.4-rc-2

=head2 new_enough($version, $minimum)

Returns true if C<$version> is, semantically speaking, greater than or equal
to the C<$minimum> required version.  Release candidate versions are counted
as less than their point release, so 1.0.0-rc5 is not newer than 1.0.0.


=head2 ordify($n)

Turn a number into its (English) ordinal representation, i.e. 1st for 1, 3rd
for 3rd, 13th for 13, etc.  The returned string will have a single trailing
space, for some reason.

=head2 parse_uri($uri)

Parses C<$uri> as an RFC-compliant URI.  Returns a hashref with the
following keys:

    uri       The full URI
    scheme    The scheme of the URI, i.e. "http"
    host      Hostname or IP address
    port      (optional) TCP port number
    path      Requested path
    query     Query string (everything after the '?')
    fragment  Document fragment (everything after the '#')

=head2 is_valid_uri($uri)

Returns true if C<$uri> can be parsed successfully as a URI.

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


=head2 lines($out, $rc)

Ignore C<$rc>, and split C<$out> on newlines, returning the resulting list.
This is best used with C<run()>, like this:

    my @lines = lines(run('some command'));


=head2 curl($method, $url, $headers, $data, $skip_verify, $creds)

Runs the C<curl> command, with the appropriate credentials, and returns the
status code, status line, and output data to the caller:

    my ($st, $line, $response) = curl(GET => 'https://example.com');
    if ($st != 200) {
      die "request failed: $line\n";
    }
    print "data:\n";
    print $response;


=head2 bosh(...)

Configures a custom environment for the BOSH CLI, and then delegates to
C<run()>.

=head2 slurp($path)

Opens C<$path> for reading, reads its entire contents into memory, and
returns that as a string.  Dies if it was unable to open the file.

=head2 mkfile_or_fail($path, [$mode,] $contents)

Creates a new file at C<$path>, with the given contents.
If C<$mode> is given, the file will be given those permissions, via
C<chmod_or_fail>.

=head2 mkdir_or_fail($path, $mode)

Create a new directory at C<$path>.
If C<$mode> is given, the directory will be given those permissions, via
C<chmod_or_fail>.

=head2 chdir_or_fail($path)

Changes the current working directory to C<$path>, or dies trying.

=head2 symlink_or_fail($src, $dst)

Creates a symbolic link called C<$dst>, pointing to the file or directory at
C<$src>, or dies trying.

=head2 copy_or_fail($src, $dst)

Copies the file C<$src> to the file C<$dst>, or dies trying.  This uses I/O
to copy, instead of the `cp` command.

=head2 chmod_or_fail($mode, $path)

Changes the permissions on C<$path> to C<$mode>, or dies trying.


=head2 load_json($json)

Parse C<$json> (as a JSON string) into a hashref.


=head2 load_yaml($yaml)

Convert C<$yaml> into JSON by way of a C<spruce merge>, and then parse it
into a hashref.


=head2 load_yaml_file($file)

Read C<$file> into memory, and then convert it into JSON via C<load_yaml>.


=head2 pushd($dir)

Temporarily change the current working directory to C<$dir>, until the next
paired call to C<popd>.  This is similary to shell pushd / popd builtins.


=head2 popd($dir)

Restore the current working directory to what it was immediately before the
last call to C<pushd>.  This is similarly to shell pushd / popd builtins.


=cut
