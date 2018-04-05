package Genesis::Utils;
#use strict;
#use warnings;

use Genesis::Run;

use base 'Exporter';
our @EXPORT = qw/
	envset envdefault

	csprintf
	explain debug trace error
	bail

	workdir

	is_semver

	parse_uri
	is_valid_uri

	ordify

	get_file
	mkfile_or_fail mkdir_or_fail
	chdir_or_fail chmod_or_fail
	symlink_or_fail
	copy_or_fail
/;

use File::Temp qw/tempdir/;

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
sub explain(@) {
	return if envset "QUIET";
	{ local $ENV{NOCOLOR} = "yes" unless -t STDOUT;
	        print csprintf(@_); }
	print "\n";
}

sub debug(@) {
	return unless envset "GENESIS_DEBUG"
	           or envset "GENESIS_TRACE";
	print STDERR "DEBUG> ";
	{ local $ENV{NOCOLOR} = "yes" unless -t STDOUT;
	        print STDERR csprintf(@_); }
	print STDERR "\n";
}

sub trace(@) {
	return unless envset "GENESIS_TRACE";
	print STDERR "TRACE> ";
	{ local $ENV{NOCOLOR} = "yes" unless -t STDOUT;
	        print STDERR csprintf(@_); }
	print STDERR "\n";
}

sub error(@) {
	my @err = @_;
	unshift @err, "%s" if $#err == 0;
	print STDERR csprintf(@err) . "\n";
}

sub bail(@) {
	unshift @err, "%s" if $#err == 0;
	$! = 1; die csprintf(@_)."\n";
}

my $WORKDIR;
sub workdir {
	$WORKDIR ||= tempdir(CLEANUP => 1);
	return tempdir(DIR => $WORKDIR);
}

sub is_semver {
	return $_[0] =~ m/^(\d+)(?:\.(\d+)(?:\.(\d+)(?:[.-]rc[.-]?(\d+))?)?)?$/;
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

sub get_file {
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
		open my $fh, ">", $file;
		print $fh $content;
		close $fh;
	} or die "Error creating file $file: $!\n";
	chmod_or_fail($mode, $file) if defined $mode;
	return $file;
}

# mkdir_or_fail $dir;
sub mkdir_or_fail {
	my ($dir,$mode) = @_;
	unless (-d $dir) {;
		debug("creating directory $dir/");
		Genesis::Run::do_or_die(
			"Unable to create directory $dir",
			'mkdir -p "$1"', $dir
		);
	}
	chmod_or_fail($mode, $dir) if defined $mode;
	return $dir;
}
# chdir_or_fail $dir;
sub chdir_or_fail {
	my ($dir) = @_;
	debug("changing current working directory to $dir/");
	chdir $dir or die "Unable to change directory to $dir/: $!\n";
}

# symlink_or_fail $source $dest;
sub symlink_or_fail {
	my ($source, $dest) = @_;
	-e $source or die "$source does not exist!\n";
	-e $dest and die abs_path($dest)." already exists!";
	symlink($source, $dest) or die "Unable to link $source to $dest: $!\n";
}

# copy_or_fail $from, $to;
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

=head2 is_semver($v)

Returns true if C<$v> looks like a semantic version number.  This handles
the following formats:

    1
    1.0
    1.23
    1.23.4
    1.23.4-rc2
    1.23.4.rc
    1.23.4-rc.2
    1.23.4-rc-2

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

=head2 get_file($path)

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

=cut
