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
use Encode qw/decode_utf8/;
use File::Basename qw/basename dirname/;
use File::Find ();
use File::Temp qw/tempdir tempfile/;
use IO::Socket;
use JSON::PP ();
use POSIX qw/strftime/;
#use Symbol qw/qualify_to_ref/;
use Time::HiRes qw/gettimeofday/;
use Time::Piece;
use Time::Seconds;

use utf8;

BEGIN { # Enable development mode if GENESIS_DEV_MODE is set
	if ($ENV{GENESIS_DEV_MODE} && $ENV{GENESIS_DEV_MODE} =~ /^(?:1|yes|true)$/i) {
		printf STDERR "Running in development mode, using Genesis lib from %s\n",
			$ENV{GENESIS_LIB} || $ENV{HOME}.'/.genesis/lib';
		eval {require Pry; Pry->import()};
		printf STDERR "  - Pry is %s on this system\n", $@ ? 'not available' : 'available';
		eval {require Carp::Always; Carp::Always->import()};
		printf STDERR "  - Carp::Always is %s\n", $@ ? 'not available on this system' :'active';
		eval {require Smart::Comments; Smart::Comments->import()};
		printf STDERR "  - Smart::Comments is %s\n", $@ ? 'not available on this system' :'active';
	}
}

use constant {
	EXODUS_TIME_FORMAT => "%Y-%m-%d %H:%M:%S %z",
	EXODUS_TIME_FORMAT_SHORT => "%Y%m%d%H%M%S",
};

# Timezone hackage to workaround keeping local TZ;
unless ($ENV{ORIG_TZ}) {
	POSIX::tzset();
	$ENV{ORIG_TZ}=(POSIX::tzname)[(localtime())[8]];
	$ENV{TZ} = "UTC";
	POSIX::tzset();
}

use base 'Exporter';
our @EXPORT = qw/
	EXODUS_TIME_FORMAT
	EXODUS_TIME_FORMAT_SHORT

	in_repo_dir in_kit_dir

	logger
	error bail bug fatal warning info output success notice dryrun
	debug trace dump_stack dump_var qtrace

	vaulted
	workdir tmpfile

	semver
	by_semver
	new_enough

	time_exec

	parse_uri
	is_valid_uri

	strfuzzytime
	get_real_local_timezone
	local_strftime
	pretty_duration
	ordify
	count_nouns

	spruce_diff

	run lines curl fake_tty
	read_json_from
	safe_path_exists

	slurp
	mkfile_or_fail mkdir_or_fail
	chdir_or_fail chmod_or_fail
	symlink_or_fail
	copy_or_fail
	copy_tree_or_fail
	expand_path
	absolute_path
	humanize_path
	humanize_bin

	load_json load_json_file save_to_json_file
	load_yaml load_yaml_file save_to_yaml_file
	to_yaml

	pushd popd

	struct_set_value
	struct_lookup
	struct_has
	flatten
	unflatten
	deep_merge
	priority_merge
	in_array
	index_of
	compare_arrays
	delete_from_array
	sentence_join
	parse_fixed_width_table
	uniq
	get_opts

	tcp_listening
	die_unless_controlling_terminal

	validate_global_config global_config_schema
/;

sub Init {
	my $version = shift // $Genesis::VERSION;
	$Genesis::RC = Genesis::Config->new($ENV{HOME}."/.genesis/config");
	# FIXME: If command is ping, don't error out, but print validation errors
	validate_global_config($Genesis::RC);
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

sub deployment_roots_map {
	# Returns a list of deployment root labels, and a hash of label => path.
	my @extras = @_;
	my @roots = @{$Genesis::RC->get("deployment_roots", [])};
	my @expanded_roots;

	# Humanize in the extras list
	@extras = map {[$_->[0], expand_path($_->[1])]} @extras;

	# Process the roots list, validating root labels and expanding paths.
	for my $root (@roots) {
		if (ref($root) eq 'ARRAY') {
			my ($label, $path) = @$root;
			bail(
				"Deployment root labels cannot start with a '\@' character.  This is ".
				"reserved for Genesis internal use.  Please check your configuration ".
				"file or GENSIS_DEPLOYMENT_ROOTS environment variable."
			) if $label =~ /^@/;
			$path = expand_path($path);
			push @expanded_roots, { label => $label, path => $path };
		} else {
			# Check if unlabeled roots are in the extras list
			my $path = expand_path($root);
			my ($extra_label) = map {$_->[0]} grep {$_->[1] eq $path} @extras;
			my $label = $extra_label // $path;
			push @expanded_roots, { label => $label, path => $path };
		}
	}

	# Check for any duplicate labels
	my @labels;
	my %deployment_roots = ();
	# FIXME: This should process the labels as a pool, not a first-come-first-serve
	# manner, so that each path using the same label is equally expressive.  As it
	# is now, the third path will get the original label, while the first two are
	# modified to be expanded based on their unique path components.
	for my $root (@expanded_roots) {
		my $label = $root->{label};
		if ($deployment_roots{$label}) {
			bail("Duplicate deployment root label '%s' found", $label);

			# TODO: Come up with another unique label based on the existing path using that label
			my ($first_label, $second_label) = unique_path_diff($label, $deployment_roots{$label}, $root->{path});
			unless ($first_label eq $label) {
				$deployment_roots{$first_label} = delete($deployment_roots{$label});
				$labels[index_of($label, @labels)] = $first_label;
			}
			$label = $second_label;
		}
		push @labels, $label;
		$deployment_roots{$label} = $root->{path};
	}

	# Add any unused extras to the list
	my ($missing_extras) = compare_arrays(
		[map {$_->[1]} @extras ],
		[values %deployment_roots]
	);
	for my $extra (@$missing_extras) {
		my ($label) = map {$_->[0]} grep {$_->[1] eq $extra} @extras;
		push @labels, $label;
		$deployment_roots{$label} = $extra;
	}

	return wantarray ? (\@labels, \%deployment_roots) : {
		labels => \@labels,
		roots  => \%deployment_roots
	}
}

sub expand_path {
	my ($path, $base_path) = @_;
	return undef unless defined $path;

	# Expand tilde patterns
	if ($path =~ /^~/) {
		if ($path eq '~' || $path =~ m{^~/}) {
			$path =~ s{^~}{$ENV{HOME}};
		} elsif ($path =~ m{^~([^/]+)}) {
			# Handle ~username expansion
			my $user_home = (getpwnam($1))[7];
			bail("Unknown user '$1' in path expansion") unless $user_home;
			$path =~ s{^~[^/]+}{$user_home};
		}
	}

	# Expand environment variables
	while ($path =~ s#\$(?:\{([A-Za-z0-9_]+)\}|([A-Za-z0-9_]+))#$ENV{$1//$2}||$&#e) {
		bail(
			"Environment variable '%s' is not set in path %s", $1//$2, $path
		) unless defined $ENV{$1//$2};
	}

	# Convert to absolute path and resolve symlinks (abs_path does both)
	pushd($base_path) if ($base_path);
	$path = Cwd::abs_path($path);
	popd() if ($base_path);

	return $path;
}

# Legacy alias for backward compatibility
sub absolute_path {
	return expand_path(@_);
}

sub in_repo_dir {
	return  -d ".genesis" && -e ".genesis/config" && slurp(".genesis/config") =~ m/^deployment_type:/m;
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
sub success    {logger->warning({offset => 1, emoji => 'tada', colors => 'gk', label => 'DONE'}, @_);}
sub dryrun     {logger->warning({offset => 1, emoji => 'noentry', colors => 'Wg', label => 'DRYRUN'}, @_);}
sub notice     {logger->notice({offset => 1}, @_);}
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
	print STDERR $ansi_show_cursor; # restore cursor visibility, just in case
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
		print STDERR $ansi_show_cursor; # restore cursor visibility, just in case
		die "\n".csprintf("%s",wrap($msg,terminal_width,"#r{[FATAL]} ")."\n\n");
	}

	# Make sure there's a stderr log running and its level is at least fatal
	logger->configure_log(level => "FATAL") unless (logger->is_logging("FATAL"));

	my $rc = delete($options->{exitcode}) // 1;
	logger->fatal({offset=>1, show_stack => 'none'},$options, "\n".$msg."\n");
	print STDERR $ansi_show_cursor; # restore cursor visibility, just in case
	exit $rc;
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

sub tmpfile {
	my (%opts) = @_;
	my $dir = $opts{dir} // workdir;
	my $ext = $opts{ext} // '';
	my $template = $opts{template} // 'tmp_XXXXXXXXXX';
	my (undef, $filename) = tempfile($template, DIR => $dir, SUFFIX => $ext, OPEN => 0);
	return $filename;
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
	$input_format //= ref($datestring) eq 'Time::Seconds'
		? 'seconds'
		: "%Y-%m-%d %H:%M:%S %z";

	my ($delta,$fuzzy,$past,$time);
	if ($input_format eq 'seconds') {
		if (ref($datestring) eq 'Time::Seconds') {
			$delta = $datestring;
			$time = $delta->seconds;
		} elsif ($datestring->can('seconds')) {
			$time = $datestring->seconds;
			$delta = Time::Seconds->new($time);
		} elsif (ref($datestring) eq '' && $datestring =~ /^\d+$/) {
			$time = $datestring;
			$delta = Time::Seconds->new($datestring);
		} else {
			bug("Invalid input for 'seconds' format: %s", ref($datestring) || $datestring);
		}
	} else {
		$time = ref($datestring) eq 'Time::Piece'
			? $datestring
			: Time::Piece->strptime($datestring, $input_format);
		$delta = Time::Piece->new() - $time;
		$past = ($delta >= 0);
		$delta = - $delta unless $past;
	}

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
		my $approach = (int($delta->months) == int($delta->months + 0.5)) ? "just over" : "almost";
		$fuzzy = sprintf("%s %d months", $approach, $delta->months + 0.5);
	} elsif ($delta->months < 25) {
		$fuzzy = "about 2 years";
	} else {
		my $half = (int($delta->years) == int($delta->years + 0.5)) ? "" : " and a half";
		$fuzzy = sprintf("more than %d%s years", $delta->years, $half );
	}
	if ($input_format eq 'seconds') {
		$fuzzy = sprintf(
			# ie "%s seconds - %~"
			join($fuzzy, split(/%~/, $output_format)),
			$time
		) if $output_format;
	} else {
		$fuzzy = $past ? "$fuzzy ago" : "in $fuzzy";
		if ($output_format) {
			my @lt = localtime($time->epoch); # Convert to localtime
			$fuzzy = join($fuzzy, map {strftime($_, @lt)} split(/%~/, $output_format))
		}
	}
	return $fuzzy;
}

sub get_real_local_timezone {
	my $tz = $ENV{ORIG_TZ};
	if (-l '/etc/localtime') {
		($tz = readlink '/etc/localtime') =~ s#.*zoneinfo/##;
	} elsif (-f '/etc/timezone') {
		$tz = `cat /etc/timezone`
	}
	$tz
}

sub local_strftime {
	my $time = shift;
	$ENV{TZ} = get_real_local_timezone();
	POSIX::tzset();
	my $out = localtime($time)->strftime(@_);
	$ENV{TZ} = "UTC";
	POSIX::tzset();
	return $out;
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
		$prog .= ' "${@}"'; # old style of passing in args as array, need to wrap for shell call
	}

	local %ENV = %ENV; # To get local scope for duration of this call
	my $tracemsg = "";
	if (scalar(keys %{$opts{env} || {}})) {
		$tracemsg = "#M{Setting environment values:}";
		for (sort keys %{$opts{env} || {}}) {
			if (defined($opts{env}{$_})) {
				$ENV{$_} = $opts{env}{$_};
				$tracemsg .= $opts{redact_env} # FIXME: This should also allow for a hash of keys to redact for fine-grained control
					? csprintf("\n#B{%s}='#Ci{<redacted>}'",$_)
					: csprintf("\n#B{%s}='#C{%s}'",$_,$ENV{$_});
			} else {
				my $was = delete $ENV{$_};
				$tracemsg .= ($opts{redact_env}
					? csprintf("\n#B{%s} unset - was '#Ci{<redacted>}'",$_)
					: csprintf("\n#B{%s} unset - was '#C{%s}' ",$_,$was)
				) if defined($was);
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
			my $size = length($cmd_arg->{redact}//'');
			$trace_arg = "<redacted:$size bytes>";
			$cmd_arg = $cmd_arg->{redact};
		}
		# FIXME: How to handle undefined values
		$cmd_arg =~ s/(?<!\\)\$(?:{([^\}]+)}|([A-Za-z0-9_]*))/my $v = $ENV{$1||$2}; defined($v) ? $v : ""/eg;

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

	# Handle STDIN redirection if requested
	set_stdin($opts{stdin}) if ($opts{stdin});

	eval {
		if ($opts{interactive}) {
			system @cmd;
		} else {
			open my $pipe, "-|", @cmd
				or bail("Could not open pipe to run #C{%s}", join(' ',@cmd));
			$out = do { local $/; <$pipe> };
			$out =~ s/\s+$//;
			close $pipe;
		}
	};
	my $eval_err = $@;

	# Always reset STDIN if it was redirected
	reset_stdin() if ($opts{stdin});

	# Re-throw any errors after STDIN cleanup
	die $eval_err if $eval_err;

my $duration = gettimeofday() - $start_time;
qtrace("command duration: %s", pretty_duration($duration, undef,undef,'','',undef,1));

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

# Wrap the command in an OS-specific script call to fake being in a tty terminal.
sub fake_tty {
	my ($file, @cmd) = @_;
	my $OS = "$^O";
	if ($OS eq 'darwin') {
		unshift @cmd, 'script', '-qeF', $file
	} elsif ($OS eq 'linux') {
		# Sometimes gnu just sucks...
		# TODO: more rigorous wrapping of subcmd to deal with quotes and pipes
		my $subcmd = join(" ", map {$_ =~ m/\s/ ? "\"$_\"" : $_} @cmd);
		@cmd = ("script -qf '$file' -c '$subcmd'");
	}
	return @cmd
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
	my ($url, $args);
	if (ref($_[0]) eq 'HASH') {
		($args, $url) = @_;
		$args->{method} ||= 'GET';
		$args->{headers} ||= {};
	} else {
		$args = {};
		$args->{method} = shift // 'GET';
		$url = shift;
		$args->{headers} = shift || {};
		$args->{data} = shift if @_;
		$args->{skip_verify} = shift if @_;
		$args->{creds} = shift if @_;
	}

	# TODO: Validate args to ensure invalid keys are not passed


	bug(
		"Internal error: \$args is not a hash reference, got %s", ref($args) || 'scalar'
	)	unless (ref($args) eq 'HASH');

	my ($method, $headers, $data, $skip_verify, $creds, $file) = $args->@{qw/method headers data skip_verify creds file/};

	bug("No url provided to Genesis::curl") unless $url;
	bug("No method provided to Genesis::curl") unless $method;
	bail(
		"Invalid method '%s' provided to Genesis::curl.  Must be one of GET, POST, PUT, DELETE, HEAD",
		$method
	) unless !ref($method) && $method =~ m/^(GET|POST|PUT|DELETE|HEAD)$/i;

	my $header_opt = "";
	my @flags = ("-X", $method);
	if ($method eq "HEAD") {
		$header_opt = 'I';
	}
	push (@flags, "-D", "/dev/stderr")      if  $method ne "HEAD";
	push @flags, qw/--post301 --post302/    if  $method eq "POST";
	push @flags, "-H", "$_: $headers->{$_}" for (keys %$headers);
	push @flags, "-d", $data                if  $data;
	push @flags, "-k"                       if  $skip_verify;
	if ($creds) {
		if ($creds =~ "^Bearer ") {
			push @flags, "-H", "Authorization: $creds"
		} else {
			push @flags, "-u", $creds
		}
	}
	push @flags, "-v"                       if  (envset('GENESIS_DEBUG'));
	push @flags, "-o", $file                if  $file;

	my $status = "";
	my $status_line = "";

	trace 'Running cURL: `'.'curl -'.$header_opt.'sSL $url '.join(' ',@flags).'`';
	my ($out, $rc, $err) = run({ stderr => 0 }, 'curl', '-'.$header_opt.'sSL', $url, @flags);
	return (599, "Error executing curl command", $err) if ($rc);

	my @data = lines($out, $rc);
	my @err_data = lines($err, $rc);
	my $in_header;
	my @header_data;
	my $line;

	my $header_src = $method eq 'HEAD' ? \@data : \@err_data;
	while ($line = shift @$header_src) {
		if ($line =~ m/^HTTP\/\d+(?:\.\d)?\s+((\d+)(\s+.*)?)$/) {
			$in_header = 1;
			$status = $2;
			$status_line = $1 =~ s/[\r\n]+$//r; # Strip off line endings
		}
		last unless $in_header;
		push @header_data, $line;
		$in_header = 0 if ($line =~ /^\s+$/);
	}
	unshift @$header_src, $line if defined($line);

	dump_var header => join($/,@header_data);
	return  $status, $status_line, join($/, @header_data, @data, @err_data)
		if ($header_opt eq 'I');
	return $status, $status_line, $file ? $file : join($/, @data), join($/, @header_data), join($/, @err_data);
}

# spruce_diff - diff two yaml files, and return the diff as a colored string.
sub spruce_diff {
	my ($first, $second) = @_;
	bug("spruce diff requires two files") unless @_ == 2;

	my $scratchdir = workdir('spruce-diff');

	# Helper function to process arguments consistently
	my $process_arg = sub {
		my ($arg, $arg_id) = @_;

		# If the argument is a file, just return it
		return $arg if (ref($arg) eq '' && $arg && -f $arg);

		if (ref($arg) eq 'HASH') {
			bug(
				"Can only specify one of 'file', 'object', or 'content' in the %s argument hashref",
				$arg_id
			) if (grep {in_array($_, qw/file object content/)} keys %$arg) > 1;

			# If we have a file and no label, just use the given file directly
			return $arg->{file} if ($arg->{file} && !$arg->{label});

			# Sanitize the label to make sure it is a valid file name
			my $label = $arg->{label} // "spruce-diff-$arg_id";
			$label =~ s/[^\w]+/_/g; # replace non-word characters with underscores
			my $tmpfile;
			while (1) {
				$tmpfile = sprintf(
					"%s/%s-%06.6d.yml",
					$scratchdir,
					$label,
					int(rand(1000000))
				);
				last unless -e $tmpfile; # make sure the file does not already exist
			}
			trace("Creating temporary file %s for %s argument", $tmpfile, $arg_id);

			copy_or_fail($arg->{file}, $tmpfile) if $arg->{file};
			save_to_yaml_file($arg->{object}, $tmpfile) if $arg->{object};
			mkfile_or_fail($tmpfile, 0644, $arg->{content}) if $arg->{content};

			return $tmpfile if -f $tmpfile;
			bug("$arg_id argument hashref must contain a 'file', 'object', or 'content' key");
		}

		bug(
			"Invalid %s argument type '%s', expected a file path, or a hashref with 'file', 'object', or 'content' key, or a string",
			$arg_id, ref($arg) ? lc(ref($arg)) : defined $arg ? 'scalar' : 'undef'
		)
	};

	# Process both arguments using the helper function
	$first = $process_arg->($first, "first");
	$second = $process_arg->($second, "second");

	my $out_file = "$scratchdir/out.diff";
	my (undef,$rc,$err) = run({redact => 1}, fake_tty($out_file, "spruce", "diff", $first, $second));
	my $out = slurp($out_file);
	if ($out =~ s/\nScript done.*\[COMMAND_EXIT_CODE="(.*)"]$//m) {
		$rc = $1;  # Linux stores command exit code in the script output
	}
	$out =~ s/^Script [^\n]+\n//m; # remove script header (linux)

	# FIXME: diff between failed diff vs diff with differences
	$out = decode_utf8($out) =~ s/\A\s*(.*?)\s*\z/$1/smr;
	return ($out, $rc, $err);
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
	open IN,  "<", $from or bail "Unable to open $from for reading: $!";
	open OUT, ">", $to   or bail "Unable to open $to for writing: $!";

	my $blksize = (stat IN)[11] || 16384; # preferred block size?
	my ($len, $written, $buf, $offset);
	while ($len = sysread IN, $buf, $blksize) {
		if (!defined $len) {
			next if $! =~ /^Interrupted/;       # ^Z and fg
			die "System read error: $!\n";
		}
		$offset = 0;
		while ($len) { # Handle partial writes.
			defined($written = syswrite OUT, $buf, $len, $offset)
				or die "System write error: $!\n";
			$len    -= $written;
			$offset += $written;
		};
	}

	close(IN);
	close(OUT);
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

our %path_cache = ();
sub humanize_path {
	my ($path, %opts) = @_;

	#TODO: cache paths better
	my $pwd = $opts{base_dir} || Cwd::abs_path($ENV{GENESIS_CALLER_DIR} || Cwd::getcwd());
	return $path_cache{"$path\@$pwd"}
		if ($path =~ m{^/} && defined($path_cache{"$path\@$pwd"}));

	$path = $ENV{HOME}.substr($path,1) if substr($path,0,1)  eq '~';
	$path = "$pwd/$path" unless $path =~ /^\//;
	while ($path =~ s/\/[^\/]*\/\.\.\//\//) {};
	while ($path =~ s/\/\.\//\//) {};

	if (defined $opts{root_map}) {
		my %root_map = %{$opts{root_map}{roots}};
		my %path_lookup = map {($root_map{$_}, $_)} keys %root_map;
		for my $root (sort {length($b) <=> length($a)} keys %path_lookup) {
			next if ($root eq $path_lookup{$root}); # skip unnamed roots
			if (substr($path,0,length($root)) eq $root) {
				$path = "[Deployment Root '$path_lookup{$root}']:".substr($path,length($root)+1);
				return $path;
			}
		}
	}

	my $rel_path;
	unless ($opts{absolute}) {
		my @path_bits = split('/',$path);
		my @pwd_bits = split('/',$pwd);
		my $i=-1; while ($i < $#path_bits && $i < $#pwd_bits && $path_bits[++$i] eq $pwd_bits[$i]) {};
		$i++ if $path_bits[$i] && $pwd_bits[$i] && $path_bits[$i] eq $pwd_bits[$i];
		$rel_path = join('/', (map {'..'} ($i .. $#pwd_bits)), @path_bits[$i .. $#path_bits]);
		$rel_path .= '/' if $path =~ m{/$};
		$rel_path = "./$rel_path" if -x $path && ! -d $path && $rel_path !~ /(^\.|\/)/;
	}

	my $new_path = (substr($path, 0, length($pwd) + 1) eq $pwd . '/')
		? '.' . substr($path, length($pwd))
		: (substr($path, 0, length($ENV{HOME}) + 1) eq $ENV{HOME} . '/')
		? "~" . substr($path, length($ENV{HOME})) : $path;
	while ($new_path =~ s/\/[^\/]*\/\.\.\//\//) {};
	$new_path =~ s/^\.\/\.\.\//..\//;
	$rel_path = undef if ($rel_path//'') =~ m{^(\.\./){3,}};
	$path_cache{"$path\@$pwd"} = ($rel_path && length($rel_path) < length($new_path)) ? $rel_path : $new_path;
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
	$cmd->($args);
	my $err = @$;
	my $end = gettimeofday();
	trace "\nTIME RUN: %0.6f\n\n", $end-$start;
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
	run('spruce merge --skip-eval "$1" | perl -e \'my $c=do{local $/;<STDIN>};$c=~s/\s*\z/\n/ms;print $c\' > $2; rm "$1"', $tmpfile, $file);

	# Fix orphaned ')) on new lines - join them with previous line
	my $content = slurp($file);
	my @lines = split /\n/, $content;
	my @fixed_lines;

	for my $i (0 .. $#lines) {
		my $line = $lines[$i];

		# If this line is just whitespace + )), join it with the previous line
		if ($line =~ /^\s*\)\)\s*$/ && @fixed_lines) {
			$fixed_lines[-1] .= ' ))';
		} else {
			push @fixed_lines, $line;
		}
	}

	mkfile_or_fail($file, join("\n", @fixed_lines) . "\n");
}

sub to_yaml {
	my ($data) = @_;
	my $json = JSON::PP->new->allow_nonref->encode($data);
	my $tmp = tempfile;
	mkfile_or_fail($tmp, 0644, $json);
	my ($out,$rc,$err) = run({ stderr => 0 }, qw/spruce merge --skip-eval/, $tmp);
	bail("Error converting data to YAML: $err") if $rc;
	return $out if $out;
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

	$key =~ s/\.\./\0/g;
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
			(my $k = $_) =~ s/\0/./g;
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
		} elsif ($bit && $bit =~ /([^=]+)=(.*)/) {
			# This is a search for a hash in an array, e.g. "name=unique-identifier"
			# lets find the index of the hash, and use that as the 'what'.
			my ($k, $v) = ($1, $2);
			bail(
				"Type Mismatch: expected array of hashes at %s, got %s",
				$path, lc(ref($what) || "scalar")
			) unless ref($what) eq 'ARRAY';
			my $idx = 0; $idx += 1
				while $idx < scalar(@{$what}) && ref($what->[$idx]) eq 'HASH' && $what->[$idx]{$k} ne $v;
			if ($idx >= scalar(@{$what})) {
				# If not found, and no more path bits, push the new value as the result;
				if (!@bits) {
					return undef if $clear;
					bail(
						"Cannot append new entry to array of hashes, as it is not a hash with %s set to %s",
						$k, $v
					) unless ref($value) eq 'HASH' && exists($value->{$k}) && $value->{$k} eq $v;
					push @{$what}, $value;
					return undef;
				}
				bail(
					"Could not find hash with key '%s' and value '%s' at %s",
					$k, $v, $path
				);
			}

			bail(
				"Type Mismatch: expected array of hashes at %s, got %s at position %d",
				$path, lc(ref($what->[$idx]) || "scalar"), $idx
			) unless ref($what->[$idx]) eq 'HASH';
			if (@bits) {
				$what=$what->[$idx];
			} elsif ($clear) {
				my $old = $what->[$idx];
				splice(@$what, $idx, 1);
				return $old;
			} else {
				my $old = $what->[$idx];
				$what->[$idx] = $value;
				return $old;
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
				return delete $what->{$bit};
			} else {
				my $old = $what->{$bit};
				$what->{$bit} = $value;
				return $old;
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

# struct_has - return true if the given key exists in the structure {{{
sub struct_has {
	my ($what, $keys) = @_;
	my (undef, $found) = struct_lookup($what, $keys, undef);
	return defined $found;
}
# }}}

# flatten - convert deep structure to single sequence of key:value {{{
sub flatten {
	my ($final, $key, $val) = (@_ == 1 ) ? ({},'', $_[0]) : @_;

	if (ref $val eq 'ARRAY') {
		if (@$val == 0) {
			# Preserve empty arrays by storing the array ref itself
			# Skip if top-level (key is empty string from initial call)
			$final->{$key} = [] if defined($key) && length($key);
		} else {
			for (my $i = 0; $i < @$val; $i++) {
				flatten($final, $key ? "${key}[$i]" : "$i", $val->[$i]);
			}
		}

	} elsif (ref $val eq 'HASH') {
		if (keys %$val == 0) {
			# Preserve empty hashes by storing the hash ref itself
			# Skip if top-level (key is empty string from initial call)
			$final->{$key} = {} if defined($key) && length($key);
		} else {
			for (keys %$val) {
				my $leaf_key = $_ =~ s/\./~/gr;
				flatten($final, $key ? "$key.$leaf_key" : "$leaf_key", $val->{$_})
			}
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
			$pk =~ s/~/./g;
			if (defined $sk) {
				# If $h_data{$pk} is an array ref,
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
			my $nk = $k =~ s/~/./gr;
			$h_data{$nk} = unflatten($h_data{$nk}, join('.', grep $_, ($branch, "$k")));
		}
		return {%h_data}
	}
}

# }}}
# deep_merge - merge hash references {{{
sub deep_merge {
	my ($base, @overlays) = @_;
	my $flatten = 0;
	my $flat_base = flatten($base);
	for my $removed_key (grep {! defined $flat_base->{$_}} keys %$flat_base) {
		delete $flat_base->{$removed_key};
	}
	# FIXME: This doesn't handle arrays of hashes properly -- it just overwrites them in position order.
	while (my $overlay = shift @overlays) {
		if (ref($overlay) eq 'HASH') {
			my $flat_overlay = flatten($overlay);
			for my $removed_key (grep {not defined $flat_overlay->{$_}} keys %$flat_overlay) {
				delete $flat_base->{$removed_key};
				delete $flat_overlay->{$removed_key};
			}
			$flat_base = { %$flat_base, %$flat_overlay };
		} elsif (ref($overlay) eq '') {
			if (!defined($overlay)) {
				$flatten = 1;
			} elsif($overlay =~ /^(un)?flatten(ed)?$/) {
				$flatten = defined($1) ? 0 : 1;
			} elsif($overlay =~ /^(?:flatten=)?([01])$/) {
				$flatten = $1;
			} else {
				bug("deep_merge: unknown overlay value: %s - expecting either '(un)flatten(ed)' or 'flattened=1|0'", $overlay);
			}
		} else {
			bug("deep_merge: unknown overlay type: %s", ref($overlay));
		}
	}
	return $flatten ? $flat_base : unflatten($flat_base);
}

# }}}
# priority_merge - priority-aware merge with conflict detection {{{
sub priority_merge {
	my @structures = @_;  # In priority order, highest first
	my $merged = {};
	my $blocked = {};  # Ancestors blocked because descendants exist

	for my $structure (@structures) {
		my $flat = flatten($structure);

		for my $key (keys %$flat) {
			# Don't add keys if there are deeper keys already present
			next if grep {$_ =~ /^\Q$key\E(\.|[\[]|$)/} keys %$merged;

			# Don't add keys if any ancestor is already present
			next if grep {$key =~ /^\Q$_\E(\.|[\[]|$)/} keys %$merged;

			# No conflict - add the key and block all its ancestors
			$merged->{$key} = $flat->{$key};
		}
	}

	return unflatten($merged);
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
	return !!scalar(grep {defined($_) ? (defined($item) && $item eq $_) : !defined($item)} (@arr));
}

sub index_of {
	my ($item, @arr) = @_;
	for (my $i = 0; $i < scalar(@arr); $i++) {
		return $i if $arr[$i] eq $item;
	}
	return undef;
}

sub compare_arrays {
	my ($arr1, $arr2) = @_;

	# Create sets for presence checking
	my %in_arr1 = map { $_ => 1 } @$arr1;
	my %in_arr2 = map { $_ => 1 } @$arr2;

	my @results = ([], [], []);
	my %processed = ();

	# Process arr1 first to preserve its order for "only in arr1" and "in both"
	for my $item (@$arr1) {
		next if $processed{$item}++; # Skip duplicates - treat as sets
		push(@{$results[$in_arr1{$item} && $in_arr2{$item} ? 1 : 0]}, $item)
	}

	# Process arr2 for "only in arr2" items
	for my $item (@$arr2) {
		next if $processed{$item}++; # Skip duplicates and already processed items
		push(@{$results[2]}, $item) if ($in_arr2{$item} && !$in_arr1{$item})
	}
	return wantarray ? @results : \@results;
}

sub delete_from_array {
	my ($arr_ref, @search_terms) = @_;

	my %index_matches;
	for my $i (0 .. $#{$arr_ref}) {
		for my $term (@search_terms) {
			if ($arr_ref->[$i] =~ $term) {
				$index_matches{$i} = 1;
				last;  # Stop checking other terms if a match is found
			}
		}
	}
	return () unless keys %index_matches;

	my @removed = ();
	my @kept = ();

	for my $idx (0 .. $#{$arr_ref}) {
		if (exists $index_matches{$idx}) {
			push @removed, $arr_ref->[$idx];
		} else {
			push @kept, $arr_ref->[$idx];
		}
	}
	@$arr_ref = @kept;
	return @removed;
}

sub sentence_join {
  return '' unless @_;
  return $_[0] if scalar(@_) == 1;
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
	my ($duration, $good, $bad, $wrap, $prefix, $style, $force) = @_;
	return '' unless $ENV{GENESIS_SHOW_DURATION} || $force;
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
	return csprintf(
		"#%s{%s%s}#%s{$fmt}#%s{%s}",
		$style, $prefix, $start, $color, @values, $style, $end
	);
}

my $pluralize_exceptions = {
};
sub count_nouns {
	my ($count, $noun, %opts) = @_;
	my $value = defined $opts{prefix}
		? $opts{prefix}[($count == 1) ? 0 : 1] . ' '
		: '';
	$value .= "$count " unless $opts{suppress_count};
	return "$value$noun" if $count == 1;
	return "$value".$pluralize_exceptions->{$noun} if $pluralize_exceptions->{$noun};
	return "$value${noun}es" if $noun =~ /(ch|sh|x|ss)$/; # we will not be counting oxen...
	return "$value${noun}$1es" if $noun =~ /[aeiou]([sz])$/;
	return "$value${1}ies" if $noun =~ /^(.*[^aeiou])y$/;
	return "$value${noun}s";
}

sub parse_fixed_width_table {
	my ($header, @rows) = @_;

	my $opts = {};
	if (ref($header) eq 'HASH') {
		$opts = $header;
		$header = shift @rows;
	}

	return wantarray ? () : [] unless $header;

	# Get column names and their positions
	my @cols = split(/\s{2,}/, $header);
	my @positions = (0);
	push @positions, pos($header)
		while ($header =~ /(?:\S+)(\s{2,})/g);

	# Create array of column ranges
	my @ranges = map {
		[$positions[$_], $positions[$_+1] - $positions[$_]]
	} (0..$#cols-1);
	push @ranges,	[$positions[$#cols], 999999]; # RISK: 999999 allows for a wide table, but not infinite

	# Parse each row into a hash
	my @results;
	for my $row (@rows) {
		my %hash;
		$row = sprintf("%-*s", $positions[-1], $row); # Make sure row is long enough
		$hash{$cols[$_]} =
			substr($row, $ranges[$_][0], $ranges[$_][1]) =~ s/^\s+|\s+$//gr
				for (0..$#cols);
		push @results, ($opts->{array_rows} ? [@hash{@cols}] : \%hash);
	}
	unshift @results, \@cols if $opts->{array_rows};
  return wantarray ? @results : \@results;
}

# validate_global_config - validate global configuration {{{
sub validate_global_config {
	my ($config_obj) = @_;
	$config_obj->validate(global_config_schema());
}

# }}}
# global_config_schema - return the global configuration validation schema {{{
sub global_config_schema {
	return {
		default_bosh_target => {
			type          => 'enum',
			default       => 'ask',
			values        => [qw/ask self parent/],
			envvar        => 'GENESIS_DEFAULT_BOSH_TARGET',
			description   => 'Default BOSH target selection behavior'
		},
		legacy_repo_suffix => {
			type          => 'boolean',
			default       => 0,
			envvar        => 'GENESIS_LEGACY_REPO_SUFFIX',
			description   => 'Use legacy "-deployments" suffix for new repositories'
		},
		embedded_genesis => {
			type          => 'enum',
			default       => 'ignore',
			values        => [qw/ignore check warn/],
			description   => 'How to handle embedded genesis versions'
		},
		output_style => {
			type          => 'enum',
			default       => 'plain',
			values        => [qw/plain fun pointer/],
			description   => 'CLI output style'
		},
		show_duration => {
			type          => 'boolean',
			default       => 0,
			envvar        => 'GENESIS_SHOW_DURATION',
			description   => 'Show command execution duration'
		},
		automatic_config_upgrade => {
			type          => 'enum',
			default       => 'no',
			values        => [qw/no yes silent/],
			envvar        => 'GENESIS_CONFIG_AUTOMATIC_UPGRADE',
			description   => 'Automatically upgrade configuration files'
		},
		fix_on_deploy => {
			type          => 'enum',
			default       => 'never',
			values        => [qw/always ask never/],
			envvar        => 'GENESIS_FIX_ON_DEPLOY',
			description   => 'Automatically fix issues during deployment'
		},
		confirm_release_overrides => {
			type          => 'enum',
			values        => [qw/always outdated never/],
			envvar        => 'GENESIS_CONFIRM_RELEASE_OVERRIDES',
			description   => 'Confirm release overrides'
		},
		spec_cache_dir => {
			type          => 'string',
			default       => "",
			envvar        => 'GENESIS_SPEC_CACHE_DIR',
			description   => 'Directory for caching kit specifications'
		},
		bosh_logs_path => {
			type          => 'string',
			default       => "<DEPLOYMENT_ROOT>/bosh_logs",
			envvar        => 'GENESIS_DEPLOYMENT_LOGS_PATH',
			description   => 'Path for storing BOSH logs'
		},
		deployment_roots  => {
			type          => 'array',
			default       => [],
			subtype       => 'string||hasharray', # Can be a string or a hash of label => path
			envvar        => 'GENESIS_DEPLOYMENT_ROOTS', # Comma-separated list of path strings or label=path pairs
			envsplit      => ':',
			envconvert    => [
			                   { type => 'hasharray', pair_split => ';', kv_split => '=', key_type => 'string', value_type => 'string' },
			                   { type => 'string' }
			],
			str_format    => \*Genesis::deployment_roots_str_format,
			description   => 'List of deployment root directories',
		},
		kits_path => {
			type          => 'string',
			description   => 'Path for storing kit files. Defaults to deployment repository\'s config settings.',
		},

		suppress_warnings => {
			type   => 'hash',
			schema => {
				oversized_secrets => { type => 'boolean', default => 0 , envvar => 'GENESIS_SUPRESS_OVERSIZED_SECRETS_WARNING'},
				bosh_target =>       { type => 'boolean', default => 0 , envvar => 'GENESIS_SUPPRESS_BOSH_TARGET_WARNING'},
			}
		},

		ui => {
			type    => 'hash',
			default => {},
			schema  => {
				colors => {
					type    => 'hash',
					default => {},
					schema  => {
						code => {
							type        => 'string',
							default     => 'Yb', # Yellow on dark blue
							envvar      => 'GENESIS_UI_COLOR_CODE',
							description => 'Color for code blocks in the UI'
						},
						warning_alert => {
							type        => 'string',
							default     => 'kYi', # Black on yellow header, yellow text
							envvar      => 'GENESIS_UI_COLOR_WARNING',
							description => 'Color for warning messages in the UI'
						},
					}
				}
			}
		},

		logs => {
			type => 'array',
			subtype => 'hash',
			schema => {
				file => {
					type        => 'string',
					required    => 1,
					description => 'File path for the log file'
				},
				level => {
					type => 'enum',
					default => 'INFO',
					values => [qw/TRACE DEBUG INFO WARN ERROR OUTPUT/],
					description => 'Log level for the file'
				},
				show_stack => {
					type => 'enum',
					default => 'default',
					values => [qw/default none full current fatal/],
					description => 'Stack trace visibility',
				},
				truncate => {
					type => 'boolean',
					default => 1,
					description => 'Truncate the log file on startup',
				},
				style => {
					type => 'enum',
					default => 'plain',
					values => [qw/plain fun pointer rfc-5424/],
					description => 'Log output style',
				},
				lifespan => {
					type => 'enum',
					default => 'current',
					values => [qw/forever current/],
					description => 'Log file lifespan',
				},
				timestamp => {
					type => 'boolean',
					default => 0,
					description => 'Include timestamps in log entries',
				},
			}
		}
	};
}

# }}}
# deployment_roots_str_format - format for deployment roots in config {{{
sub deployment_roots_str_format {
	my ($root) = @_;
	return $root unless ref($root);
	return "#Y[$root->{label}] #m{$root->{path}}";
}

# }}}
1;
# vim: fdm=marker:foldlevel=1:noet
