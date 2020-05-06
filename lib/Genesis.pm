package Genesis;
use strict;
use warnings;
no warnings 'utf8';
use utf8;

our $VERSION = "(development)";
our $BUILD   = "";

our $GITHUB  = "https://github.com/starkandwayne/genesis";

use Data::Dumper;
use File::Basename qw/basename dirname/;
use IO::Socket;
use POSIX qw/strftime/;
use Symbol qw/qualify_to_ref/;
use Time::HiRes qw/gettimeofday/;
use Time::Piece;
use Time::Seconds;
use Cwd ();
use utf8;

$ENV{TZ} = "UTC";
POSIX::tzset();

use base 'Exporter';
our @EXPORT = qw/
	envset envdefault
	in_callback under_test

	csprintf
	explain waiting_on
	debug trace dump_var dump_stack
	error	bail bug

	vaulted
	workdir

	semver
	by_semver
	new_enough

	parse_uri
	is_valid_uri

	strfuzzytime
	ordify

	run lines bosh curl
	read_json_from
	safe_path_exists

	slurp
	mkfile_or_fail mkdir_or_fail
	chdir_or_fail chmod_or_fail
	symlink_or_fail
	copy_or_fail
	humanize_path
	humanize_bin

	load_json
	load_yaml load_yaml_file

	pushd popd

	struct_lookup
	uniq
	get_opts

	tcp_listening
/;

use File::Temp qw/tempdir/;
use JSON::PP qw//;

sub envset {
	my $var = shift;
	(defined $ENV{$var} and scalar($ENV{$var} =~ m/^(1|y|yes|true)$/i)) ? 1 : 0;
}

sub envdefault {
	my ($var, $default) = @_;
	return defined $ENV{$var} ? $ENV{$var} : $default;
}

sub in_callback {
	envset('GENESIS_IS_HELPING_YOU');
}

sub under_test {
	envset('GENESIS_TESTING');
}

sub vaulted {
	return !! Genesis::Vault->current
}

sub safe_path_exists {
	bug("Cannot verify path exists in safe without a vault being selected first")
		unless Genesis::Vault->current;
	return Genesis::Vault->current->has($_[0]);
}

my $__is_highcolour = $ENV{TERM} && $ENV{TERM} =~ /256color/;
sub _color {
	my ($fg,$bg) = @_;
	my @c = (  # NOTE: backgrounds only use the darker version unless highcolour terminal
		'Kk',    # dark grey/black)
		'Rr',    # light red/red
		'Gg',    # light green/green
		'Yy',    # yellow/amber
		'Bb',    # light blue/blue
		'MmPp',  # light magenta/magenta/light purple/purple
		'Cc',    # light cyan/dark cyan
		'Ww'     # light grey/white
	);
	my $fid = (grep {$c[$_] =~ qr/$fg/} 0..7 || ())[0] if $fg;
	my $bid = (grep {$c[$_] =~ qr/$bg/} 0..7 || ())[0] if $bg;
	return "" unless defined $fid || defined $bid;
	my @cc;
	if ($__is_highcolour) {
		push(@cc, 38, 5, $fid + ($fg eq uc($fg) ? 8 : 0)) if defined $fid;
		push(@cc, 48, 5, $bid + ($bg eq uc($bg) ? 8 : 0)) if defined $bid;
	} else {
		push @cc, "1" if $fg eq uc($fg);
		push @cc, "3$fid" if defined $fid;
		push @cc, "4$bid" if defined $bid;
	}
	return "\e[".join(";",@cc)."m";
}

sub _colorize {
	my ($c, $msg) = @_;
	return $msg if envset('NOCOLOR');

	my @fmt = ();
	push @fmt, 3 if $c =~ /i/i && !$ENV{TMUX}; # TMUX doesn't support italics
	push @fmt, 4 if $c =~ /u/i;
	my ($fg, $bg) = grep {$_ !~ /^[ui]$/i} split(//, $c);

  my $prefix = (@fmt) ? "\e[".join(";", @fmt)."m" : "";
	if (($fg && $fg eq "*") || ($bg && $bg eq "*")) {
		my @rainbow = ('R','G','Y','B','M','C');
		my $i = 0;
		my $msgc = "";
		foreach my $char (split //, $msg) {
			my $fr = $fg && $fg eq "*" ? $rainbow[$i%6] : $fg;
			my $br = $bg && $bg eq "*" ? $rainbow[($i+3)%6] : $bg;
			$msgc = $msgc . _color($fr,$br)."$char";
			if ($char =~ m/\S/) {
				$i++;
			}
		}
		return "$prefix$msgc\e[0m";
	} else {
		return $prefix._color($fg,$bg)."$msg\e[0m";
	}
}
sub _glyphize {
	my ($c,$glyph) = @_;
	my %glyphs = (
		'-' => "✘ ", # \x{2718}
		'+' => "✔ ", # \x{2714}
		'*' => "\x{2022}",
		' ' => '  ',
		'>' => "⮀",
		'!' => "\x{26A0} ",
	);

	$glyph = $glyphs{$glyph} if !envset('GENESIS_NO_UTF8') && defined($glyphs{$glyph});
	return $glyph unless $c;
	return _colorize($c, $glyph);
	}

my $in_csprint_debug=0;
sub csprintf {
	my ($fmt, @args) = @_;
	return '' unless $fmt;
	my $s;
	eval {
		our @trap_warnings = qw/uninitialized/;
		push @trap_warnings, qw/missing redundant/ if $^V ge v5.21.0;
		use warnings FATAL => @trap_warnings;
		$s = sprintf($fmt, @args);
	};
	if ($@) {
		die $@ unless ($@ =~ /^(Missing|Redundant) argument|Use of uninitialized value/);
		$s = sprintf($fmt, @args); # run again because the error didn't set it
		if (!$in_csprint_debug) {
			$in_csprint_debug = 1;
			debug("Got warning in csprintf: $@");
			dump_var(template => $fmt, arguments => \@args);
			dump_stack();
			$in_csprint_debug = 0;
		}
	}

	$s =~ s/#([-IUKRGYBMPCW*]{0,4})@\{([^{}]*(?:{[^}]+}[^{}]*)*)\}/_glyphize($1, $2)/egism;
	$s =~ s/#([-IUKRGYBMPCW*]{1,4})\{([^{}]*(?:{[^}]+}[^{}]*)*)\}/_colorize($1, $2)/egism;
	return $s;
}

sub explain {
	explain STDOUT @_;
}

sub waiting_on {
	waiting_on STDOUT @_;
}

sub debug {
	return unless envset("GENESIS_DEBUG") || envset("GENESIS_TRACE");
	_log("DEBUG", csprintf(@_), "Wm")
}

sub dump_var {
	return unless envset("GENESIS_DEBUG") || envset("GENESIS_TRACE");
	my $scope = 0;
	$scope = abs(shift) if ($_[0] =~ '^-?\d+$');

	local $Data::Dumper::Deparse = 1;
	local $Data::Dumper::Terse   = 1;
	my (undef, $file, $ln) = caller($scope);
	my $sub = (caller($scope+1))[3];
	my (%vars) = @_;
	_log("VALUE", csprintf("#M{$_} = ").Dumper($vars{$_}) .csprintf("#Ki{# in $sub [$file:L$ln]}"), "Wb") for (keys %vars);
}

sub dump_stack {
	return unless envset("GENESIS_DEBUG") || envset("GENESIS_TRACE");
	my $scope = 0;
	$scope = abs(shift) if ($_[0] =~ '^-?\d+$');

	my ($package,$file,$line,$sub,@stack,@info);
	my ($sub_size, $line_size, $file_size) = (10,4,4);

  while (@info = caller($scope++)) {
		$sub = $info[3];
		$sub_size  = (sort {$b <=> $a} ($sub_size, length($sub )))[0];
		if ($file) {
			push @stack, [$line,$sub,$file];
			$line_size = (sort {$b <=> $a} ($line_size,length($line)))[0];
			$file_size = (sort {$b <=> $a} ($file_size,length($file)))[0];
		}
		$file = $info[1];
		$line = $info[2];
	}

	print STDERR "\n"; # Ensures that the header lines up at the cost of a blank line
	my $header = csprintf("#Wku{%*s}  #Wku{%-*s}  #Wku{%-*s}\n", $line_size, "Line", $sub_size, "Subroutine", $file_size, "File");
	_log("STACK", $header.join("\n",map {
		csprintf("#w{%*s}  #Y{%-*s}  #Ki{%s}", $line_size, $_->[0], $sub_size, $_->[1], $_->[2])
	} @stack), "kY");
}

sub trace {
	return unless envset "GENESIS_TRACE";
	_log("TRACE", csprintf(@_), "Wc")
}

sub _log {
	my ($label, $content, $colors) = @_;
	my ($gt,$gtc) = (">",$colors);
	if (envset('GENESIS_TSTAMP')) {
		my ($s,$us) = gettimeofday;
		$label = sprintf "%s.%03d %s", localtime($s)->strftime("%H:%M:%S"), $us / 1000, $label;
	}
	unless (envset "NOCOLOR") {
		$gt = csprintf("#\@{>}");
		$gtc = substr($colors,1,1);
		$label = " $label " unless envset('GENESIS_NO_UTF8');
	}
	$colors = substr($colors,1,1) if envset('GENESIS_NO_UTF8');
	my $prompt = csprintf("#%s{%s}#%s{%s}", "$colors",$label,$gtc,$gt);
	my $out = join("\n".(" "x(length($label)+2)),split(/\n/,$content));

	printf STDERR "%s %s\n", $prompt, $out;
}

sub error {
	my @err = @_;
	unshift @err, "%s" if $#err == 0;
	print STDERR csprintf(@err) . "$/";
}

sub bail {
	my @err = @_;
	unshift @err, "%s" if $#err == 0;
	$! = 1; die csprintf(@err)."$/";
}

sub bug {
	my (@msg) = @_;

	trace "Dying due to bug: ".csprintf(@msg);
	dump_stack(1);

	if ($Genesis::VERSION =~ /dev/) {
		$! = 2; die csprintf(@msg)."\n".
		            csprintf("This is a bug in Genesis itself.\n").
		            csprintf("#Y{NOTE: This is a development build of Genesis.}\n").
		            csprintf("      Please try to reproduce this behavior with an\n").
		            csprintf("      officially-released version before submitting\n").
		            csprintf("      issues to the Genesis Github Issue Tracker.\n\n");
	}

	$! = 2; die csprintf(@msg)."\n".
	            csprintf("#R{This is a bug in Genesis itself.}\n").
	            csprintf("Please file an issue at #C{%s/issues}\n\n", $GITHUB);
}

my $WORKDIR;
sub workdir {
	$WORKDIR ||= tempdir(CLEANUP => 1);
	return tempdir(DIR => $WORKDIR);
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
	while (@a || @b) {
		$a[0] ||= 0;
		$b[0] ||= 0;
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

sub strfuzzytime {
	my ($datestring,$output_format, $input_format) = @_;
  $input_format ||= "%Y-%m-%d %H:%M:%S %z";

	my $time = Time::Piece->strptime($datestring,$input_format);
	my $delta = Time::Piece->new() - $time;
	my $fuzzy;
	my $past = ($delta >= 0);
	$delta = - $delta unless $past;

	# Adapted from rails' distance_of_time_in_words
	if ($delta->minutes < 2) {
		if ($delta->seconds < 20) {
			$fuzzy = "a few moments";
		} elsif ($delta->seconds < 40 ) {
			$fuzzy = "half a minute";
		} elsif ($delta->seconds < 60 ) {
			$fuzzy = "less than a minute" ;
		} else {
			$fuzzy = "about a minute";
		}
	} elsif ($delta->minutes < 50) {
		$fuzzy = sprintf("about %d minutes", $delta->minutes);
	} elsif ($delta->minutes < 90) {
		$fuzzy = "about an hour";
	} elsif ($delta->hours < 22) {
		$fuzzy = sprintf("about %d hours", $delta->hours);
	} elsif ($delta->hours < 42) {
		$fuzzy = "about a day";
	} elsif ($delta->days < 6) {
		$fuzzy = sprintf("about %d days", $delta->days + 0.5);
	} elsif ($delta->days < 13) {
		$fuzzy = "about a week";
		$fuzzy .= " and a half" if $delta->days >= 10;
	} elsif ($delta->days < 34) {
		my $half = (int($delta->weeks) == int($delta->weeks + 0.5)) ? "" : " and a half";
		$fuzzy = sprintf("about %d%s weeks", $delta->weeks, $half );
	} elsif ($delta->months < 1.5) {
		$fuzzy = "more than a month";
	} elsif ($delta->months < 22) {
		my $aproach = (int($delta->months) == int($delta->months + 0.5)) ? "just over" : "almost";
		$fuzzy = sprintf("%s %d months", $aproach, $delta->months + 0.5);
	} elsif ($delta->months < 25) {
		$fuzzy = "about 2 years";
	} else {
		$fuzzy = sprintf("more than %d years", $delta->years );
	}
	$fuzzy = $past ? "$fuzzy ago" : "in $fuzzy";
	if ($output_format) {
		my @lt = localtime($time->epoch); # Convert to localtime
		$fuzzy = join($fuzzy, map {strftime($_, @lt)} split(/%~/, $output_format))
	}
	return $fuzzy;
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
	$opts{stderr} = '&1' unless exists $opts{stderr};

	my $err_file = $opts{stderr} = workdir().sprintf("/run-%09d.stderr",rand(1000000000))
		if (defined($opts{stderr}) && $opts{stderr} eq '0' && !$opts{interactive});

	my $prog = shift @args;
	if ($prog !~ /\$\{?[\@0-9]/ && scalar(@args) > 0) {
		$prog .= ' "$@"'; # old style of passing in args as array, need to wrap for shell call
	}

	local %ENV = %ENV; # To get local scope for duration of this call
	for (keys %{$opts{env} || {}}) {
		$ENV{$_} = $opts{env}{$_};
		trace("#M{Setting: }#B{$_}='#C{$ENV{$_}}'");
	}
	my $shell = $opts{shell} || '/bin/bash';
	if (!$opts{interactive} && $opts{stderr}) {
		$prog .= " 2>$opts{stderr}";
	}
	trace("#M{From directory:} #C{%s}", Cwd::getcwd);
	trace("#M{Executing:} `#C{$prog}`%s", ($opts{interactive} ? " #Y{(interactively)}" : ''));
	if (@args) {
		unshift @args, basename($shell);
		trace("#M{ - with arguments:}");
		trace("#M{%4s:} '#C{%s}'", $_, $args[$_]) for (1..$#args);
	}

	my @cmd = ($shell, "-c", $prog, @args);
	my $start_time = gettimeofday();
	my $out;
	if ($opts{interactive}) {
		system @cmd;
	} else {
		open my $pipe, "-|", @cmd;
		$out = do { local $/; <$pipe> };
		$out =~ s/\s+$//;
		close $pipe;
	}
	trace("command duration: %s", Time::Seconds->new(sprintf ("%0.3f", gettimeofday() - $start_time))->pretty());

	my $err = slurp($err_file) if ($err_file && -f $err_file);
	my $rc = $? >>8;
	if ($rc) {
		trace("command exited with status %x (rc %d)", $?, $rc);
		dump_var -1, run_output => $out if (defined($out));
		dump_var -1, run_stderr => $err if (defined($err));
		bail("#R{%s} (run failed)%s%s",
		     $opts{onfailure},
		     defined($err) ? "\n\nSTDERR:\n$err" : '',
		     defined($out) ? "\n\nSTDOUT:\n$out" : ''
		) if ($opts{onfailure});
	} else {
		trace("command exited #G{0}");
		if (defined($out)) {
			if ($out =~ m/[\x00-\x08\x0b-\x0c\x0e\x1f\x7f-\xff]/) {
				trace "[".length($out)."b of binary data omited from trace]";
			} else {
				dump_var -1, run_output => $out;
			}
		}
		dump_var -1, run_stderr => $err if (defined($err));
	}

	return unless defined(wantarray);
	return ($rc == 0) if $opts{passfail};
	return (wantarray ? (undef, $rc) : $rc) if $opts{interactive};
	return $out if $opts{onfailure};
	return ($out,  $rc, $err) if wantarray;
	return ($rc > 0 && defined($err) ? $err : $out);
}

sub lines {
	my ($out, $rc, $err) = @_;
	return $rc ? () : split $/, $out;
}

sub read_json_from {
	my ($out, $rc, $err) = @_;
	local $@;
	my $json;
	unless ($rc) {
		eval {$json = load_json($out)};
		$err = $@; # previous error was non-fatal, so override
	}
	return ($json,$rc,$err) if (wantarray);
	die $err if $err && $err ne "";
	return $json;
}

sub curl {
	my ($method, $url, $headers, $data, $skip_verify, $creds) = @_;
	$headers ||= {};

	bug("No url provided to Genesis::curl") unless $url;
	bug("No methhod provided to Genesis::curl") unless $method;

	my $header_opt = "i";
	if ($method eq "HEAD") {
		$header_opt = 'I';
		$method = "GET";
	}
	my @flags = ("-X", $method);
	push @flags, "-H", "$_: $headers->{$_}" for (keys %$headers);
	push @flags, "-d", $data                if  $data;
	push @flags, "-k"                       if  ($skip_verify);
	push @flags, "-u", $creds               if  ($creds);
	push @flags, "-v"                       if  (envset('GENESIS_DEBUG'));

	my $status = "";
	my $status_line = "";

	debug 'Running cURL: `'.'curl -'.$header_opt.'sSL $url '.join(' ',@flags).'`';
	my ($out, $rc, $err) = run({ stderr => 0 }, 'curl', '-'.$header_opt.'sSL', $url, @flags);
	return (599, "Error executing curl command", $err) if ($rc);

	my @data = lines($out,$rc);
	my $in_header;
	my @header_data;
	my $line;
	while ($line = shift @data) {
		if ($line =~ m/^HTTP\/\d+(?:\.\d)?\s+((\d+)(\s+.*)?)$/) {
			$in_header = 1;
			chomp($status_line = $1);
			$status = $2;
		}
		last unless $in_header;
		push @header_data, $line;
		$in_header=0 if ($line =~ /^\s+$/);
	}
	unshift @data, $line if defined($line);

	dump_var header => join($/,@header_data);
	return  $status, $status_line, join($/, @header_data, @data)
		if ($header_opt eq 'I');
	return $status, $status_line, join($/, @data), join($/, @header_data);
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
	trace("creating file $file");

	my $dir = dirname($file);
	if ($dir && ! -d $dir) {
		trace("creating parent directories $dir");
		mkdir_or_fail($dir);
	}

	eval {
		open my $fh, ">", $file or die "Unable to open $file for writing: $!";
		print $fh $content;
		close $fh;
	} or die "Error creating file $file: $!\n";
	chmod_or_fail($mode, $file) if defined $mode;
	return $file;
}

sub mkdir_or_fail {
	my ($dir,$mode) = @_;
	unless (-d $dir) {;
		trace("creating directory $dir/");
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
	trace("creating symbolic link $source -> $dest");
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

sub humanize_path {
	my $path = shift;
	my $pwd = Cwd::abs_path($ENV{GENESIS_CALLER_DIR} || Cwd::getcwd());
	$path = "$pwd/$path" unless $path =~ /^\//;
	while ($path =~ s/\/[^\/]*\/\.\.\//\//) {};
	while ($path =~ s/\/\.\//\//) {};

	my $rel_path;
	my @path_bits = split('/',$path);
	my @pwd_bits = split('/',$pwd);
	my $i=-1; while ($i < $#path_bits && $i < $#pwd_bits && $path_bits[++$i] eq $pwd_bits[$i]) {};
	$i++ if $path_bits[$i] && $pwd_bits[$i] && $path_bits[$i] eq $pwd_bits[$i];
	$rel_path = join('/', (map {'..'} ($i .. $#pwd_bits)), @path_bits[$i .. $#path_bits]);
	$rel_path = "./$rel_path" if -x $path && ! -d $path && $rel_path !~ /(^\.|\/)/;

	my $new_path = (substr($path, 0, length($pwd) + 1) eq $pwd . '/')
		? '.' . substr($path, length($pwd))
		: (substr($path, 0, length($ENV{HOME}) + 1) eq $ENV{HOME} . '/')
		? "~" . substr($path, length($ENV{HOME})) : $path;
	while ($new_path =~ s/\/[^\/]*\/\.\.\//\//) {};
	$new_path =~ s/^\.\/\.\.\//..\//;
	($rel_path && length($rel_path) < length($new_path)) ? $rel_path : $new_path;
}

sub humanize_bin {
	return "" unless $ENV{GENESIS_CALLBACK_BIN};
	my $bin = basename($ENV{GENESIS_CALLBACK_BIN});
	chomp(my $path_bin = `which $bin`);
	debug "bin:       %s\npath_bin:  %s\nhumanized: %s",
	       $bin,          $path_bin,     humanize_path($ENV{GENESIS_CALLBACK_BIN});
	return $bin if ($path_bin && Cwd::abs_path($path_bin) eq Cwd::abs_path($ENV{GENESIS_CALLBACK_BIN}));
	return humanize_path($ENV{GENESIS_CALLBACK_BIN});
}

sub load_json {
	my ($json) = @_;
	return JSON::PP->new->allow_nonref->decode($json);
}

sub load_yaml_file {
	my ($file) = @_;
	my ($out, $rc, $err) = run({ stderr => 0 }, 'spruce json "$1"', $file);
	my $json = load_json($out) if $rc == 0;
	return (wantarray) ? ($json,$rc,$err) : $json;
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

sub tcp_listening {
	my ($host,$port) = @_;
	my $timeout = $ENV{GENESIS_NETWORK_TIMEOUT} || 10;

	# Check if host is listening on given port
	eval {
		local $SIG{ALRM} = sub {die "timeout\n"; };
		alarm $timeout;
		my $socket = IO::Socket::INET->new(PeerAddr => $host, PeerPort => $port, Proto => 'tcp');
		die "failed\n" unless $socket;
		$socket->close();
		alarm 0;
	};
	return ($@ eq "timeout\n" ? "timeout" : "failed") if ($@);
	return 'ok';
}

sub _lookup_key {
	my ($what, $key) = @_;

	return (1,$what) if $key eq '';

	for (split /[\[\.]/, $key) {
		if (/^(\d+)\]$/) {
			return (0,undef) unless ref($what) eq "ARRAY" && scalar(@$what) > $1;
			$what = $what->[$1];
		} elsif (/^(.*?)=(.*?)]$/) {
			return (0,undef) unless ref($what) eq "ARRAY";
			my $found=0;
			for (my $i = 0; $i < scalar(@$what); $i++) {
				if (ref($what->[$i]) eq 'HASH' && defined($what->[$i]{$1}) && ($what->[$i]{$1} eq $2)) {
					$what = $what->[$i];
					$found=1;
					last;
				}
			}
			return (0, undef) unless $found;
		} else {
			return (0, undef) if !exists $what->{$_};
			$what = $what->{$_};
		}
	}
	return (1, $what);
}
sub struct_lookup {
	my ($what, $keys, $default) = @_;
	$keys = [$keys] unless ref($keys) eq 'ARRAY';
	my $found = 0;
	my ($key,$value);
	for (@{$keys}) {
		($found,$value) = _lookup_key($what,$_);
		if ($found) {
			$key = $_;
			last;
		}
	}
	unless ($found) {
		$key = undef;
		$value = (ref($default) eq 'CODE') ? $default->() : $default;
	}
	return wantarray ? ($value,$key) : $value;
}

sub uniq {
	my (@items,%check);
	for (@_) {
		push @items, $_ unless $check{$_}++;
	}
	@items
}

sub get_opts {
	my ($hash_ref, @keys) = @_;
	my %slice;
	for (@keys) {
		if (exists($hash_ref->{$_})) {
			$slice{$_} = $hash_ref->{$_};
		} elsif ($_ =~ '_') {
			my $__ = _u2d($_);
			$slice{$_} = $hash_ref->{$__} if exists($hash_ref->{$__});
		}
	}
	return %slice
}

sub _u2d {
	my $str = shift;
	$str =~ s/_/-/g;
	$str
}



# Because x FH args... translates to FH->x args, it is required to monkey-patch
# IO:File to facilitate printing to different streams instead of STDOUT.  With
# this in place, the Genesis functions just become wrappers.
package IO::File;

sub explain(*;@) {
	my $self = shift;
	return if Genesis::envset "QUIET";
	print $self Genesis::csprintf(@_)."\n";
}

sub waiting_on(*;@) {
	my $self = shift;
	return if Genesis::envset "QUIET";
	print $self Genesis::csprintf(@_);
}

1;

=head1 NAME

Genesis

=head1 DESCRIPTION

This module contains assorted and sundry utilities that more or less stand
on their own.  All of these procedures are exported by default.

    use Genesis;
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

=head2 dump_var([$scope,] name=>value [, name2=value2, ...])

Dumps one or more named values to standard error if C<$GENESIS_TRACE> or
C<$GENESIS_TRACE> environment variables have been set to "truthy".  Optional
scope level will report the corresponding stack level adjustment as the
source of the output, defaults to the calling scope (can be positive or negative)

=head2 dump_stack([$scope])

Dumps the current stack to standard error if C<$GENESIS_TRACE> or
C<$GENESIS_TRACE> environment variables have been set to "truthy".  Optional
scope level will start that much below the calling scope (can be expressed as
positive or negative)

=head2 error($fmt, ...)

Print an error to standard error, but do not interrupt the flow of
execution (as opposed to C<bail>).  This function does not honor C<$QUIET>.
Supports color formatting codes.  A trailing newline will be added for you.

=head2 bail($fmt, ...)

Print an error to standard error, and exit the program immediately, with an
exit code of C<1>.  This function does not honor C<$QUIET>.
Supports color formatting codes.  A trailing newline will be added for you.

=head2 bug($fmt, ...)

Prints an error to standard error, informing the operator that the aberrant
behavior detected is in fact a bug in Genesis itself, and asking them to
please submit an issue to the project Github page.

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

=head2 by_semver($a,$b)

Sorting routine to sort by semver.  See perlops for cmp or <=> for details.

Release candidate versions are counted as less than their point release, so
1.0.0-rc5 is not newer than 1.0.0.  Otherwise, sorts by major, then minor, then
patch, then rc.

=head2 new_enough($version, $minimum)

Returns true if C<$version> is, semantically speaking, greater than or equal
to the C<$minimum> required version.  Release candidate versions are counted
as less than their point release, so 1.0.0-rc5 is not newer than 1.0.0.

=head2 strfuzzytime($timestring, [$output_format, [$input_format]])

Parses the C<$timestring>, then returns the aproximate delta from now in natural
language (eg: "a few moments ago", "in about a week and a half", "about 2 days
ago")

You can also pass in an output format, and performs C<strfdate> on the C<timestring>,
with the additional format atom of '%~' as a placeholder for the fuzzy delta.

It expects C<$timestring> to be formatted as "%Y-%m-%d %H:%M:%S %z" -- if the
source timestring is a different format, you can specify the format as per
C<strptime>.

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
    my ($out, $rc, $err) = run("safe read a/b/c | spruce json");

    # Pre-tokenized array of arguments
    my ($out, $rc, $err) = run('spruce', 'merge', '--skip-eval, @files);

    # Complicated pipeline, pre-tokenized arguments
    my ($out, $rc, $err) = run('spruce merge "$1" - "$2" < "$3.yml"',
                               $file1, $file2, $file3);

In all cases, the output of the command (including STDERR) is returned, along
with the exit code (without the other bits that normally accompany C<$?>).  If
you specify C<{stderr => 0}> as an option, the stderr will be made available
as a third returned value

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
into standard output.  If you pass this explicitly as C<undef>, standard
error will B<not> be redirected for you, at all, and will be written directly
to the terminal.

As a special case, if you specify 0 instead, stderr will be returned as a
separate third argument, assuming you call C<run> in an list context.  If you
run it in a scalar context, stderr will be retunred instead of stdout.

=over

Finally, if you are not running in C<interactive> or C<passfail> mode, you
can call this in either scalar or list context.  In list context, the output
and exit code are returned in a list, otherwise just the output.

    # scalar context
    my $out = run('grep "$1" "$@"', $pattern, @files);
    my $rc = $? >> 8;

    # list contex
    my ($out, $rc, $err) = run('spruce json "$1" | jq -r "$2"', $_, $filter);


=head2 lines($out, $rc, $err)

Ignore C<$rc>, and split C<$out> on newlines, returning the resulting list.
This is best used with C<run()>, like this:

    my @lines = lines(run('some command'));

=head2 read_json_from($out, $rc, $err)

Ignore C<$rc>, and parses C<$out> as JSON, returning the resulting structure.
It is primarily intended to wrap C<run()>, like this:

    my $data = read_json_from(run('some command that outputs json'));

If called in scalar context, it will return the json if it was parseable, or
otherwise die with whatever message JSON::PP generates when encountering
non-JSON content.

If called in list context, it will return the json (if successfully read), the
C<$rc> of the command, and any error encountered when trying to parse the json.
This is to allow the caller to handle any error in the call or the parse
themselves.

=head2 curl($method, $url, $headers, $data, $skip_verify, $creds)

Runs the C<curl> command, with the appropriate credentials, and returns the
status code, status line, and output data and headers to the caller:

    my ($st, $line, $response, $headers) = curl(GET => 'https://example.com');
    if ($st != 200) {
      die "request failed: $line\n";
    }
    print "data:\n";
    print $response;


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
