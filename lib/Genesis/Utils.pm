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

sub colorize {
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
	$s =~ s/(#[KRGYBMPCW*]\{)(.*?)(\})/colorize($1, $2)/egi;
	return $s;
}
sub explain(@) {
	return if envset "QUIET";
	my $colorize = $ENV{NOCOLOR};
	$ENV{NOCOLOR} = "true" if (! -t STDOUT);
	print csprintf(@_);
	$ENV{NOCOLOR} = $colorize;
	print "\n";
}

sub debug(@) {
	return unless envset "GENESIS_DEBUG"
	           or envset "GENESIS_TRACE";
	print STDERR "DEBUG> ";
	my $colorize = $ENV{NOCOLOR};
	$ENV{NOCOLOR} = "true" if (! -t STDERR);
	print STDERR csprintf(@_);
	$ENV{NOCOLOR} = $colorize;
	print STDERR "\n";
}

sub trace(@) {
	return unless envset "GENESIS_TRACE";
	print STDERR "TRACE> ";
	print STDERR csprintf(@_);
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
