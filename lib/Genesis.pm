package Genesis;
use strict;
use warnings;
no warnings 'utf8';
use utf8;

our $APP     = "genesis";
our $VERSION = "(development)";
our $BUILD   = "";

our $GITHUB  = "https://github.com/genesis-community/genesis";

use Genesis::Log;
use Genesis::Term;
use Genesis::State;

use Cwd ();
use Data::Dumper;
use File::Basename qw/basename dirname/;
use File::Find ();
use File::Temp qw/tempdir/;
use IO::Socket;
use JSON::PP ();
use POSIX qw/strftime/;
#use Symbol qw/qualify_to_ref/;
use Time::HiRes qw/gettimeofday/;
use Time::Piece;
use Time::Seconds;


use utf8;

# Timezone hackage to workaround keeping local TZ;
unless ($ENV{ORIG_TZ}) {
	POSIX::tzset();
	$ENV{ORIG_TZ}=(POSIX::tzname)[(localtime())[8]];
	$ENV{TZ} = "UTC";
	POSIX::tzset();
}

use base 'Exporter';
our @EXPORT = qw/
	in_repo_dir in_kit_dir

	logger
	error bail bug fatal warning info output success
	debug trace dump_stack dump_var qtrace

	vaulted
	workdir

	semver
	by_semver
	new_enough

	time_exec

	parse_uri
	is_valid_uri

	strfuzzytime
	pretty_duration
	ordify

	run lines curl
	read_json_from
	safe_path_exists

	slurp
	mkfile_or_fail mkdir_or_fail
	chdir_or_fail chmod_or_fail
	symlink_or_fail
	copy_or_fail
	copy_tree_or_fail
	humanize_path
	humanize_bin

	load_json load_json_file save_to_json_file
	load_yaml load_yaml_file save_to_yaml_file

	pushd popd

	struct_set_value
	struct_lookup
	in_array
	compare_arrays
	sentence_join
	uniq
	get_opts

	tcp_listening
	die_unless_controlling_terminal
/;

sub Init {
	my $version = shift // $Genesis::VERSION;
	$Genesis::RC = Genesis::Config->new($ENV{HOME}."/.genesis/config");
	Genesis::Log->setup_from_configs($Genesis::RC->get("logs",[]));

	our $USER_AGENT_STRING = "genesis/$Genesis::VERSION";

	# Config vars
	$ENV{GENESIS_SHOW_DURATION} //= $Genesis::RC->get("show_duration", 0);

	# Systems Operations
	$ENV{GENESIS_LIB}          ||= $ENV{HOME}."/.genesis/lib";
	$ENV{GENESIS_CALLBACK_BIN} ||= $ENV{HOME}."/.genesis/genesis";
	$ENV{GENESIS_VERSION}        = $version;
	$ENV{GENESIS_ORIGINATING_DIR}= Cwd::getcwd;
	$ENV{GENESIS_CALL_BIN}       = humanize_bin();
	$ENV{GENESIS_FULL_CALL}      = join(" ", map {$_ =~ / / ? "\"$_\"" : $_} ($ENV{GENESIS_CALL_BIN}, @ARGV));
}

sub in_repo_dir {
	return  -d ".genesis" && -e ".genesis/config";
}

sub in_kit_dir {
	return -f "kit.yml";
}

sub vaulted {
	return !! Service::Vault->current
}

sub safe_path_exists {
	bug("Cannot verify path exists in safe without a vault being selected first")
		unless Service::Vault->current;
	return Service::Vault->current->has($_[0]);
}

sub logger     {$Genesis::Log::Logger//Genesis::Log->new()->configure_log()}
sub output     {logger->output({offset => 1},@_);}
sub fatal      {logger->fatal({offset => 1},@_);}
sub error      {logger->error({offset => 1},@_);}
sub warning    {logger->warning({offset => 1},@_);}
sub success    {logger->warning({offset => 1, emoji => 'tada', colors => 'kg', label => 'DONE'}, @_);}
sub info       {logger->info({offset => 1},@_);}
sub debug      {logger->debug({offset => 1},@_);}
sub trace      {logger->trace({offset => 1},@_);}
sub qtrace     {logger->trace({show_stack => 'none', offset => 1},@_);}
sub dump_var   {logger->dump_var({offset => 1},@_);}
sub dump_stack {logger->dump_stack({offset => 1},@_);}

sub bail {
	# Get any prefix options (sent as hash references)
	my $options = {};
	while (ref($_[0]) eq 'HASH') {
		my $more_options = shift;
		$options->{offset} = $options->{offset}||0 + delete($more_options->{offset}) if $more_options->{offset};
		@{$options}{keys %$more_options} = values %$more_options;
	}

	my $msg = fix_wrap(@_)."\n";

	# Make sure there's a stderr log running and its level is at least fatal
	logger->configure_log(level => "FATAL") unless (logger->is_logging("FATAL"));

	if ($^S && !envset("GENESIS_IGNORE_EVAL")) {
		# die if in an eval;
		logger->trace("Fatal exception caught: $msg");
		die "\n".csprintf("%s",wrap($msg,terminal_width,"#r{[FATAL]} "))."\n";
	}

	# log a fatal message and exit
	my $rc = delete($options->{exitcode}) // 1;
	logger->fatal({offset=>1},$options, "\n".$msg);
	exit $rc;
}

sub bug {

	# Get any prefix options (sent as hash references)
	my $options = {};
	while (ref($_[0]) eq 'HASH') {
		my $more_options = shift;
		$options->{offset} = $options->{offset}||0 + delete($more_options->{offset}) if $more_options->{offset};
		@{$options}{keys %$more_options} = values %$more_options;
	}
	my $msg = fix_wrap(@_);

	$msg .= "\n\n".
					"#R{This is most likely a bug in Genesis itself.}  ".
					"Please file an issue on #Bu{$GITHUB/issues/new} with the following ".
					"stack info:\n";
	$msg .= csprintf("  #Ki{%s:L%d%s\n}", $_->{file}||'', $_->{line}, $_->{sub} ? " (in $_->{sub})" : '')
		for (Genesis::Log::get_stack(1));

	if ($Genesis::VERSION =~ /dev/) {
		$msg .= "\n".
			"[[#Y{NOTE:} >>This is a development build of Genesis, not an official ".
			              "release.  Please try to reproduce this behavior with an ".
			              "officially-released version before submitting issues to ".
			              "the Genesis Github repository.\n"
	}

	if ($^S && !envset("GENESIS_IGNORE_EVAL")) {
		# die if in an eval;
		logger->trace("Bug caught: $msg");
		die "\n".csprintf("%s",wrap($msg,terminal_width,"#r{[FATAL]} ")."\n\n");
	}

	# Make sure there's a stderr log running and its level is at least fatal
	logger->configure_log(level => "FATAL") unless (logger->is_logging("FATAL"));

	my $rc = delete($options->{exitcode}) // 1;
	logger->fatal({offset=>1, show_stack => 'none'},$options, "\n".$msg."\n");
	exit $rc;
}

sub fix_wrap {
	my @msg = @_;
	my $fmt = "%s";
	$fmt = shift(@msg) if $#msg > 0;

	my $msg = sprintf($fmt,@msg);
	$msg =~ s/^(\n*)(.*?)\n*\z/$2/s;
	my $blanks = $1 || "\n";

	my ($c, $prefix,$sub_msg);
	if (($c,$prefix,$sub_msg) = $msg =~ m/^#([^\{]*)\{(\[[A-Z]*\])} (.*)/s) {
		my $indent = ' ' x (length($prefix)+1);
		$msg = $sub_msg;
		$msg =~ s/\n$indent([^ ])/ $1/sg;
		$msg =~ s/\n /\n\n/g;
	}

	return $msg;
}

my $WORKDIRS = {};
sub workdir {
	my $suffix = shift // '';
	$suffix =~ s/^(.+)$/_\U$1/;
	if ($suffix) {
		$WORKDIRS->{$suffix} //= $ENV{"GENESIS_WORKDIR$suffix"} if $ENV{"GENESIS_WORKDIR$suffix"};
		if (defined($WORKDIRS->{$suffix})) {
			trace "Reusing temporary directory %s specified by \$GENESIS_WORKDIR%s", $WORKDIRS->{$suffix}, $suffix;
			return $WORKDIRS->{$suffix} ;
		}
	}
	# Provide a temporary directory inside of the autocleaning temporary
	# directory so that the inside directory can be deleted and recreated
	my $workdir = tempdir(DIR => tempdir(CLEANUP => 1));
	trace "Provided temporary directory $workdir, which will be removed when this process ends";
	return $workdir unless $suffix;
	return $ENV{"GENESIS_WORKDIR$suffix"} = $WORKDIRS->{$suffix} = $workdir;
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
	return unless defined($_[0]);
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
	my $tracemsg = "";
	if (scalar(keys %{$opts{env} || {}})) {
		$tracemsg = "#M{Setting environment values:}";
		for (keys %{$opts{env} || {}}) {
			if (defined($opts{env}{$_})) {
				$ENV{$_} = $opts{env}{$_};
				$tracemsg .= csprintf("\n#B{%s}='#C{%s}'",$_,$ENV{$_});
			} else {
				my $was = delete $ENV{$_};
				$tracemsg .= csprintf("\n#B{%s} unset - was '#C{%s}' ",$_,$was) if defined($was);
			}
		}
		$tracemsg .= "\n\n";
	}
	my $shell = $opts{shell} || '/bin/bash';
	if (!$opts{interactive} && $opts{stderr}) {
		$prog .= " 2>$opts{stderr}";
	}
	pushd($opts{dir}) if ($opts{dir});

	unshift @args, basename($shell) if @args;

	my @trace_args;
	my @cmd_args;
	for (my $i = 0; $i < scalar(@args); $i++) {
		my $cmd_arg = $args[$i];
		my $trace_arg = undef;
		if (ref($cmd_arg) eq 'HASH' && (scalar(keys %{$cmd_arg}) eq 1) && defined($cmd_arg->{redact})) {
			$trace_arg = "<redacted>";
			$cmd_arg = $cmd_arg->{redact};
		}
		$cmd_arg =~ s/(?<!\\)\$(?:{([^}]+)}|([A-Za-z0-9_]*))/my $v = $ENV{$1||$2}; defined($v) ? $v : ""/eg;

		# Normal flow, assume arg is string-equivalent as before
		push(@trace_args, $trace_arg//$cmd_arg);
		push(@cmd_args,   $cmd_arg)
	}

	$tracemsg .= csprintf("#M{From directory:} #C{%s}\n", Cwd::getcwd);
	$tracemsg .= csprintf("#M{Executing:} `#C{%s}`%s", $prog, ($opts{interactive} ? " #Y{(interactively)}" : ''));
	if (@trace_args) {
		$tracemsg .= csprintf("\n#M{ - with arguments:}");
		$tracemsg .= csprintf("\n#M{%4s:} '#C{%s}'", $_, $trace_args[$_]) for (1..$#trace_args);
	}
	trace("%s",$tracemsg);

	my @cmd = ($shell, "-c", $prog, @cmd_args);
	my $start_time = gettimeofday();
	my $out;
	if ($opts{interactive}) {
		system @cmd;
	} else {
		open my $pipe, "-|", @cmd
		  or bail("Could not open pipe to run #C{%s}", join(' ',@cmd));
		$out = do { local $/; <$pipe> };
		$out =~ s/\s+$//;
		close $pipe;
	}
	qtrace("command duration: %s", Time::Seconds->new(sprintf ("%0.3f", gettimeofday() - $start_time))->pretty());

	my $err = slurp($err_file) if ($err_file && -f $err_file);
	my $rc = $? >>8;
	if (defined($out)) {
		if ($out =~ m/[\x00-\x08\x0b-\x0c\x0e\x1f\x7f-\xff]/) {
			qtrace "[%sb of binary data omitted from debug]", length($out);
		} elsif ($opts{redact_output}) {
			qtrace "[%sb of redacted data omitted from debug]", length($out);
		} else {
			dump_var -1, run_output => $out;
		}
	}
	dump_var -1, run_stderr => $err if (defined($err));
	if ($rc) {
		bail({raw => 1}, "#R{%s} (run failed)%s%s",
		     $opts{onfailure},
		     defined($err) ? "\n\nSTDERR:\n$err" : '',
		     defined($out) ? "\n\nSTDOUT:\n".($opts{redact_output}?"<redacted>":$out) : ''
		) if ($opts{onfailure});
		trace("command exited with status %x (rc %d)", $?, $rc);
	} else {
		trace("command exited #G{0}");
	}
	popd() if ($opts{dir});

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
	bail($err) if $err && $err ne "";
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
	if ($creds) {
		if ($creds =~ "^Bearer ") {
			push @flags, "-H", "Authorization: $creds"
		} else {
			push @flags, "-u", $creds
		}
	}
	push @flags, "-v"                       if  (envset('GENESIS_DEBUG'));

	my $status = "";
	my $status_line = "";

	trace 'Running cURL: `'.'curl -'.$header_opt.'sSL $url '.join(' ',@flags).'`';
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
		or bail "failed to open '$file' for reading: $!\n";
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
		open my $fh, ">", $file or bail "Unable to open $file for writing: $!";
		print $fh $content;
		close $fh;
	} or bail "Error creating file $file: $@";
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
	chdir $dir or bail "Unable to change directory to $dir/: $!";
}

sub symlink_or_fail {
	my ($source, $dest) = @_;
	-e $source or bail "$source does not exist!";
	-e $dest and bail abs_path($dest)." already exists!";
	trace("creating symbolic link $source -> $dest");
	symlink($source, $dest) or bail "Unable to link $source to $dest: $!\n";
}

sub copy_or_fail {
	my ($from, $to) = @_;
	-f $from or bail "$from: $!\n";
	$to.=($to =~ /\/$/?'':'/').basename($from) if -d $to;
	trace("copying $from to $to");
	open my $in,  "<", $from or bail "Unable to open $from for reading: $!";
	open my $out, ">", $to   or bail "Unable to open $to for writing: $!";
	print $out $_ while (<$in>);
	close $in;
	close $out;
}

sub copy_tree_or_fail {
	my ($from, $to, $trim) = @_;
	-e $from or bail "$from: No such file or directory";
	(-d $to || ! -e $to) or bail "$to: Exists and is not a directory";
	mkdir_or_fail $to unless -d $to;
	my @subfiles;
	$trim = '' unless defined($trim);
	File::Find::find({wanted => sub {push @subfiles, $File::Find::name}},$from);
	for (grep {$_ ne '.'} @subfiles) {
		(my $src = $_) =~ s#^\./##;
		(my $dst = $_) =~ s ^$trim / ; #using nulls to mitigate trim character collition
		$dst = "$to/$dst";
		$dst =~ s#//#/#g;
		if (-d $src) {
			mkdir_or_fail "$dst"
		} else {
			copy_or_fail($src,$dst);
		}
	}
}

# chmod_or_fail 0755, $path; <-- don't quote the mode. make it an octal number.
sub chmod_or_fail {
	my ($mode, $path) = @_;
	-e $path or bail "$path: $!";
	chmod $mode, $path
		or bail "Could not change mode of $path: $!";
}

sub humanize_path {
	my $path = shift;
	my $pwd = Cwd::abs_path($ENV{GENESIS_CALLER_DIR} || Cwd::getcwd());
	$path = $ENV{HOME}.substr($path,1) if substr($path,0,1)  eq '~';
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

my $humanized_bin;
sub humanize_bin {
	return "" unless $ENV{GENESIS_CALLBACK_BIN};
	return $humanized_bin if $humanized_bin;

	my $bin = basename($ENV{GENESIS_CALLBACK_BIN});
	my $rel_bin = humanize_path($ENV{GENESIS_CALLBACK_BIN});
	chomp(my $path_bin = `which $bin`);
	trace "bin:       %s\npath_bin:  %s\nhumanized: %s",
	       $bin,          $path_bin,     $rel_bin;
	$humanized_bin =
		($path_bin && Cwd::abs_path($path_bin) eq Cwd::abs_path($ENV{GENESIS_CALLBACK_BIN}))
		? $bin
		: $rel_bin;
	return $humanized_bin;
}

sub time_exec {
	my ($cmd, $args) = @_;
	my @results = ();
	my $start = gettimeofday();
	eval { $cmd->($args); };
	my $end = gettimeofday();
	trace "\nTIME RUN: %0.6f\n\n", $end-$start;
	my $err = @$;
	die $err if $err;
	return $end-$start;
}

# Data handling

sub load_json {
	my ($json) = @_;
	return JSON::PP->new->allow_nonref->decode($json);
}

sub load_json_file {
	my ($file) = @_;
	my $json = undef;
	eval {
		$json = load_json(slurp($file));
	};
	return (wantarray) ? ($json,$@ ? 1 : 0, $@) : $json
}

sub load_yaml_file {
	my ($file) = @_;
	my ($out, $rc, $err) = run({ stderr => 0 }, 'spruce json < "$1"', $file);
	my $json = load_json($out) if $rc == 0;
	return (wantarray) ? ($json,$rc,$err) : $json;
}

sub load_yaml {
	my ($yaml) = @_;

	my $tmp = workdir();
	open my $fh, ">", "$tmp/json.yml"
		or bail "Unable to create tempfile for YAML conversion: $!";
	print $fh $yaml;
	close $fh;
	return load_yaml_file("$tmp/json.yml")
}

sub save_to_json_file {
	my ($data, $file) = @_;
	mkfile_or_fail($file, 0644, JSON::PP->new->allow_nonref->encode($data));
}

sub save_to_yaml_file {
	my ($data, $file) = @_;
	my $i=1; while (-f "$file.$i.json") {$i++};
	my $tmpfile = "$file.$i.json";
	save_to_json_file($data,$tmpfile);
	run('spruce merge --skip-eval "$1" | perl -I$GENESIS_LIB -MGenesis -e \'my $c=do{local $/;<STDIN>};$c=~s/\s*\z/\n/ms;print $c\' > $2; rm "$1"', $tmpfile, $file);
}

my @DIRSTACK;
sub pushd {
	my ($dir) = @_;
	push @DIRSTACK, Cwd::cwd;
	chdir_or_fail($dir);
}
sub popd {
	@DIRSTACK or bug "popd called when we don't have anything on the directory stack";
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

sub die_unless_controlling_terminal {
	return if in_controlling_terminal;
	trace("Terminating due to not being in a controlling terminal");
	dump_stack(1);
	bail(@_ ? @_ : (
		"Method #C{%s} was called from a non-controlling terminal but it requires user input.",
		(caller(1))[3]||'main'
	));
}



sub _lookup_key {
	my ($what, $key) = @_;

	return (1,$what) if $key eq '';

	$key =~ s/\.\./.\0/;
	for (split /[\[\.]+/, $key) {
		if (ref($what) eq 'ARRAY') {
			my ($k, $v) = (/^(?:(.*?)=)?(.*?)]?$/);
			if ($v =~ /^(\d+)$/ && !defined($k) && eval {exists($what->[$v])}) {
				$what = $what->[$v]
			} else {
				my @possible_keys = defined($k) ? ($k) : qw/name key id/;
				my $found=0;
				for my $k (@possible_keys) {
					for (my $i = 0; $i < scalar(@$what); $i++) {
						if (ref($what->[$i]) eq 'HASH' && defined($what->[$i]{$k}) && ($what->[$i]{$k} eq $v)) {
							$what = $what->[$i];
							$found=1;
							last;
						}
					}
					last if $found;
				}
				return (0, undef) unless $found;
			}
		} else {
			my $k = $_ eq "\0" ? "." : $_;
			return (0, undef) unless eval {exists $what->{$k}};
			$what = $what->{$k};
		}
	}
	return (1, $what);
}
sub struct_set_value {
	my ($what, $key, $value, $clear) = @_;

	$key =~ s/\.\./.\0/;
	my @bits = split(/[\[\.]+/, $key);
	my $path;

	while (@bits) {
		my $bit = shift(@bits);
		if ($bit =~ /^(\d+)\]$/) {
			my $idx = $1;
			$path .="[$idx]";
			bail(
				"Type Mismatch: expected array at %s, got %s",
				$path, lc(ref($what) || "scalar")
			) unless ref($what) eq 'ARRAY';
			if (@bits) {
				$what->[$idx] = ($bits[0] =~ /^\d+\]$/) ? [] : {}
					unless exists($what->[$idx]);
				$what=$what->[$idx];
			} elsif ($clear) {
				#return delete $what->[$idx];
			} else {
				return $what->[$idx] = $value;
			}
		} else {
			$path .= ($path ? "." : "") . $bit;
			bail(
				"Type Mismatch: expected hash at %s, got %s",
				$path, lc(ref($what) || "scalar")
			) unless ref($what) eq 'HASH';
			if (@bits) {
				$what->{$bit} = ($bits[0] =~ /^\d+\]$/) ? [] : {}
					unless exists($what->{$bit});
				$what=$what->{$bit};
			} elsif ($clear) {
				#return delete $what->{$bit};
			} else {
				return $what->{$bit} = $value;
			}
		}
	}
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

# flatten - convert deep structure to single sequence of key:value {{{
sub flatten {
	my ($final, $key, $val) = @_;

	if (ref $val eq 'ARRAY') {
		for (my $i = 0; $i < @$val; $i++) {
			flatten($final, $key ? "${key}[$i]" : "$i", $val->[$i]);
		}

	} elsif (ref $val eq 'HASH') {
		for (keys %$val) {
			flatten($final, $key ? "$key.$_" : "$_", $val->{$_})
		}

	} else {
		$final->{$key} = $val;
	}

	return $final;
}

# }}}
# unflatten - convert a flattened hashmap to a deep structure {{{
sub unflatten {
	my ($data, $branch) = @_;

	return $data unless ref($data) eq 'HASH'; # Catchall for scalar data coming in.

	# Data must represent all array elements or all hash keys.
	my ($elements, $keys) = ([],[]);
	push @{($_ =~ /^\[\d+\](?:\.|\[|$)/) ? $elements : $keys}, $_ for (sort keys %$data);
	die("Cannot unflatten data that contains both array elements and hash keys at same level "
		 . ($branch ? "(at $branch)" : "(top level)") ."\n") if @$elements && @$keys;

	if (@$elements) {
		my @a_data;
		for my $k (sort keys %$data) {
			my ($i, $sk) = $k =~ /^\[(\d+)\](?:\.)?([^\.].*)?$/;
			if (defined $sk) {
				die "Array cannot have scalar and non-scalar values (at ${branch}[$i])"
					if defined $a_data[$i] && ref($a_data[$i]) ne 'HASH';
				$a_data[$i]->{$sk} = delete $data->{$k};
			} else {
				die "Array cannot have scalar and non-scalar values (at ${branch}[$i])"
					if defined $a_data[$i];
				$a_data[$i] = delete $data->{$k};
			}
		}
		for my $i (0..$#a_data) {
			$a_data[$i] = unflatten($a_data[$i], ($branch||"")."[$i]");
		}
		return [@a_data];
	} else {
		my %h_data;
		for my $k (sort keys %$data) {
			my ($pk, $sk) = $k =~ /^([^\[\.]*)(?:\.)?([^\.].*?)?$/;
			if (defined $sk) {
				die "Hash cannot have scalar and non-scalar values (at ".join('.', grep $_, ($branch, "pk")).")"
					if defined $h_data{$pk} && ref($h_data{$pk}) ne 'HASH';
				$h_data{$pk}->{$sk} = delete $data->{$k};
			} else {
				die "Hash cannot have scalar and non-scalar values (at ".join('.', grep $_, ($branch, "pk")).")"
					if defined $h_data{$pk};
				$h_data{$pk} = delete $data->{$k};
			}
		}
		for my $k (sort keys %h_data) {
			$h_data{$k} = unflatten($h_data{$k}, join('.', grep $_, ($branch, "$k")));
		}
		return {%h_data}
	}
}

# }}}

sub uniq {
	my (@items,%check);
	for (@_) {
		push @items, $_ unless $check{$_}++;
	}
	@items
}

sub in_array {
	my ($item, @arr) = @_;
	return !!scalar(grep {$item eq $_} (@arr));
}

sub compare_arrays {
	my ($arr1, $arr2) = @_;

	my %matrix = ();
	$matrix{$_} -=1 for @$arr1;
	$matrix{$_} +=1 for @$arr2;

	my @results;
	for (@$arr1, @$arr2) { # This is On, probably a better way to do it.
		next unless defined($matrix{$_});
		push(@{$results[delete($matrix{$_})+1]}, $_);
	}
	return wantarray ? @results : \@results;
}

sub sentence_join {
  join(' and ', grep {$_} (join(", ",@_[0...scalar(@_)-2]), @_[scalar(@_)-1]))
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

sub pretty_duration {
	my ($duration, $good, $bad, $wrap, $prefix, $style) = @_;
	return '' unless $ENV{GENESIS_SHOW_DURATION};
	$wrap //= '()';
	$prefix //= ' ';
	$style //= '-';
	my ($fmt, @values)
		= $duration < 0.001
		? ('%d µs', $duration * 1000000)
		: $duration < 2
		? ('%d ms', $duration * 1000)
		: $duration < 10
		? ('%0.1f s', $duration)
		: $duration < 60
		? ('%d s', $duration)
		: $duration < 3600
		? ('%d m %d s', $duration / 60, $duration % 60)
		: ('%d h %d m', $duration / 3600, $duration / 60 % 60);
	my $color = $good && $duration <= $good
		? $style =~ s/^[\*kwrgbcmyp-]?/g/ir
		: $bad && $duration >= $bad
		? $style =~ s/^[\*kwrgbcmyp-]?/r/ir
		: $style;

	my ($start,$end) = (substr($wrap,0,1),substr($wrap, length($wrap)-1, 1));
	return sprintf(
		"#%s{%s%s}#%s{$fmt}#%s{%s}",
		$style, $prefix, $start, $color, @values, $style, $end
	);
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
# vim: fdm=marker:foldlevel=1:noet
