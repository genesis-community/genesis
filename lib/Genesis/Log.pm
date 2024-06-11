package Genesis::Log;
use strict;
use warnings;

use utf8;
binmode STDOUT, 'utf8';
binmode STDERR, 'utf8';

#use open ':encoding(utf-8)';

use Genesis::State;
use Genesis::Term;

use POSIX qw/strftime/;
use Cwd ();
#use Symbol qw/qualify_to_ref/;
use Time::HiRes qw/gettimeofday/;
use Time::Piece;
use Time::Seconds;

use base 'Exporter';
our @EXPORT = qw/
	$Logger
	find_log_level
	meets_level
	get_stack
	get_scope
	log_levels
	log_styles
/;

sub new {
	my ($class) = @_;
	my $hostname =  (`type -p hostname &>/dev/null`)
		? `hostname | cut -f 1 -d.`
		: 'localhost';
	chomp(my $user = `whoami`);
	$Genesis::Log::Logger //= bless({
		buffer => [],
		logs => {},
		user => $user,
		hostname => $hostname,
		pid => $$,
		capture_stack_min_level => 2,
		version => ($Genesis::VERSION eq "(development)")
			? "0.0.0-rc.0"
			: $Genesis::VERSION #FIXME - include dirty indicator
	}, $class);
	return $Genesis::Log::Logger;
}

sub configure_log {
	my $self = shift;
	my $log = (scalar(@_) % 2) ? shift : '<terminal>';
	my %options = @_;
	my @valid_levels = qw/ERROR WARN DEBUG INFO TRACE/;
	my ($level_ord, $level);
	my $default_level = envset("QUIET") ? "ERROR" :  envset("GENESIS_TRACE") ? "TRACE" : envset("GENESIS_DEBUG") ? "DEBUG" : "INFO";
	my $default_output_style = defined($Genesis::RC) ? $Genesis::RC->get('output_style','plain') : 'plain';

	# Create log directory if it doesn't exist.
	if ($log ne '<terminal>') {
		require Genesis;
		my $dir = Cwd::dirname(Cwd::abs_path(Genesis::expand_path($log)));
		mkdir_or_fail $dir unless -d $dir;
	}

	unless ($self->{logs}{$log}) {
		$self->{logs}{$log} = {
			level       => $default_level,
			level_ord   => level_ord($default_level),
			show_stack  => 'none',
			timestamp   => ($log eq '<terminal>' ? 0 : 1),
			next_entry  =>  0,
			style       => $ENV{GENESIS_LOG_STYLE}//$default_output_style
		}
	}
	if ($options{level}) {
		$level = find_log_level($options{level});
		$self->{logs}{$log}{level} = $level; ;
		$self->{logs}{$log}{level_ord} = level_ord($level);
	}
	$self->{logs}{$log}{show_stack} = $options{show_stack} if defined($options{show_stack});
	$self->{logs}{$log}{timestamp} = $options{timestamp} if defined($options{timestamp});
	$self->{logs}{$log}{next_entry} = scalar(@{$self->{buffer}}) if $options{truncate};
	$self->{logs}{$log}{style} = $options{style} if $options{style};
	$self->{logs}{$log}{no_color} = $options{no_color} if defined($options{no_color});
	$self->{logs}{$log}{no_utf8} = $options{no_utf8} if defined($options{no_utf8});

	# Clean up log, unless in callback or log is STDERR
	unless ($log eq '<terminal>' || in_callback) {
		if (($options{lifespan}//'') eq 'current') {
			(my $file = $log) =~ s/^~/$ENV{HOME}/;
			open my $fh, '>', $file;
			truncate $fh, 0;
			close $fh;
		}
		# TODO: time based truncation
	}
	return $self;
}

sub setup_from_configs {
	my ($class, $log_configs) = @_;

	require Genesis;

	if (ref($log_configs) eq 'ARRAY') {
		for (@$log_configs) {
			my $file = delete($_->{file});
			$file = Cwd::getcwd ."/$file" unless $file =~ /^[~\/]/;
			$class->new->configure_log(Cwd::abs_path(Genesis::expand_path($file)), %{$_});
			# TODO: add suppress list so that we can set a level, but ingore specific output
			# TODO: support an only-log-if-an-error-occurred setting... that adds and flushes the log in END step if rc > 0
		}
	} else {
		Genesis::bail("Configuration error - logs entry must be an array");
	}
}

sub is_logging {
	my ($self,$level,$log) = @_;
	$log ||= '<terminal>';
	return meets_level($self->{logs}{$log}{level}, $level)
		if ($self->{logs}{$log} && defined($self->{logs}{$log}{level}));
	return 0;
}

sub style {
	my ($self,$log) = @_;
	$log ||= '<terminal>';
	die "invalid log: $log\n" unless defined($self->{logs}{$log});
	return $self->{logs}{$log}{style};
}

sub set_level {
	my ($self,$level,$log) = @_;
	$log ||= '<terminal>';
	die "invalid log: $log\n" unless defined($self->{logs}{$log});
	$level = find_log_level($level);
	@{$self->{logs}{$log}}{qw/level_ord level/} = (level_ord($level),$level);
	return $self;
}

sub log_styles {
	return {
		output    => {colors => "kC", pri => 6, emoji => 'printer'},
		info      => {colors => "Wc", pri => 6, emoji => 'information'},
		debug     => {colors => "Wm", emoji => 'crystal-ball'},
		warning   => {colors => "ky", pri => 4, emoji => 'warning'},
		error     => {colors => "WR", pri => 3, emoji => 'collision'},
		fatal     => {colors => "Yr", pri => 0, emoji => 'stop-sign'},
		trace     => {colors => "WG", emoji => 'detective', show_stack => 'current'},
		qtrace    => {colors => "Wg", emoji => 'detective'},
		dumpvar   => {colors => "WB", show_scope => 'current', emoji => 'magnifying-glass', raw => 1},
		dumpstack => {colors => "kY", emoji => 'pancakes', raw => 1},
	}->{$_[0]}
}

sub output  { shift->_log("OUTPUT",  log_styles('output'),  @_) }
sub info    { shift->_log("INFO",    log_styles('info'),    @_) }
sub debug   { shift->_log("DEBUG",   log_styles('debug'),   @_) }
sub warning { shift->_log("WARNING", log_styles('warning'), @_) }
sub error   { shift->_log("ERROR",   log_styles('error'),   @_) }
sub fatal   { shift->_log("FATAL",   log_styles('fatal'),   @_) }
sub trace   { shift->_log("TRACE",   log_styles('trace'),   @_); }
sub qtrace  { shift->_log("TRACE",   log_styles('qtrace'),  @_); }

sub dump_var {
	my $self = shift;
	my $options = {};
	my @args = @_;
	while (ref($_[0]) eq 'HASH') {
		my $more_options = shift @_;
		$options->{offset} = $options->{offset}||0 + delete($more_options->{offset}) if $more_options->{offset};
		@{$options}{keys %$more_options} = values %$more_options;
	}
	# TODO: Too many ways to indicate offset - old version must be fixed in
	# caller context
	my $scope = delete($options->{offset}) || 0;
	$scope += abs(shift) if (defined $_[0] && $_[0] =~ '^-?\d+$');

	require Data::Dumper;
	local $Data::Dumper::Indent  = 1; # 2-space indent
	local $Data::Dumper::Deparse = 1;
	local $Data::Dumper::Terse   = 1;
	my (%vars) = @_;
	for (keys %vars) {
		chomp (my $value = Data::Dumper::Dumper($vars{$_}));
		$self->_log("VALUE", {%{log_styles('dumpvar')}, offset => $scope}, $options, "#M{%s} = %s", $_, $value);
	}
}

sub dump_stack {
	my $self = shift;
	my $options = {};
	while (ref($_[0]) eq 'HASH') {
		my $more_options = shift @_;
		$options->{offset} = $options->{offset}||0 + delete($more_options->{offset}) if $more_options->{offset};
		@{$options}{keys %$more_options} = values %$more_options;
	}
	# TODO: Too many ways to indicate offset - old version must be fixed in
	# caller context
	my $scope = $options->{offset} || 0;
	$scope += abs(shift) if (defined $_[0] && $_[0] =~ '^-?\d+$');

	my @stack = get_stack($scope+1);
	my %sizes = (sub => 10, line => 4, file => 4);
	for my $type (keys %sizes) {
		$sizes{$type} = (sort {$b<=>$a} ($sizes{$type}, map {length($_->{$type}||'')} @stack))[0];
	}

	print STDERR "\n"; # Ensures that the header lines up at the cost of a blank line
	my $header = csprintf("#Wku{%*s}  #Wku{%-*s}  #Wku{%-*s}\n", $sizes{line}, "Line", $sizes{sub}, "Subroutine", $sizes{file}, "File");
	$self->_log("STACK", { %$options, %{log_styles('dumpstack')} }, $header.join("\n",map {
		csprintf("#w{%*s}  #Y{%-*s}  #Ki{%s}", $sizes{line}, $_->{line}, $sizes{sub}, $_->{sub}||'', $_->{file})
	} @stack));
}

sub _log {
	my ($self, $level, @contents) = @_;
	my $options = {};
	while (ref($contents[0]) eq 'HASH') {
		my $more_options = shift @contents;
		$options->{offset} = $options->{offset}||0 + delete($more_options->{offset}) if $more_options->{offset};
		@{$options}{keys %$more_options} = values %$more_options;
	}
	unshift @contents, "%s" if scalar(@contents) == 1;
	$level = $options->{level}//$level;
	my $label =  $options->{label} || $level;
	$level =~ s/ +$//g;

	my ($s,$us) = gettimeofday;
	my $ts = sprintf "%s.%03dZ", gmtime($s)->strftime("%Y-%m-%dT%H:%M:%S"), $us / 1000;

	my @stack = ($level eq 'STACK' || ! meets_level($level, $self->{capture_stack_min_level})) ? () :
		get_stack(($options->{offset}||0)+2);

	push @{$self->{buffer}}, {
		level      => $level,
		label      => $label,
		colors     => $options->{colors} // '--',
		emoji      => $options->{emoji}  // '',
		priority   => $options->{pri}    // 7,
		timestamp  => $ts,
		contents   => \@contents,
		pending    => $options->{pending},
		reset      => $options->{reset},
		show_stack => $options->{show_stack},
		stack      => \@stack,
		raw        => $options->{raw},
	};

	# Check if there are any logs for the given level
	$self->flush_logs();
	return;
}

my $flushing=0;
sub flush_logs {
	my $self = shift;
	my $last_line = $#{$self->{buffer}};

	return if $flushing; $flushing = 1;

	my ($s,$us) = gettimeofday;
	my $ms = $s * 1000 + int($us/1000);

	for my $log (keys %{$self->{logs}}) {
		my $config = $self->{logs}{$log};
		for my $line_number ($config->{next_entry}..$last_line) {
			my (
					$level, $ts,      $label, $colors, $emoji, $priority, $contents, $show_stack, $stack, $pending, $reset, $raw
			)	= @{@{$self->{buffer}}[$line_number]}{
				qw/level   timestamp label   colors   emoji   priority   contents   show_stack   stack   pending   reset   raw/
			};

			next unless meets_level($config->{level},$level);

			$reset = 1 if defined($config->{last_label}) && $config->{last_label} ne $label;

			unshift(@$contents, '' ) unless scalar(@$contents);
			unshift(@$contents, "%s") if scalar(@$contents) == 1;
			my ($template, @values) = @$contents;

			do {
				local $ENV = $ENV;
				$ENV{NOCOLOR} = $config->{no_color} if defined($config->{no_color});
				$ENV{GENESIS_NO_UTF8} = $config->{no_utf8} if defined($config->{no_utf8});
				my $columns = $log eq '<terminal>' ? terminal_width : ($config->{width} || 120);
				my ($prefix,$indent);

				if ($log eq '<terminal>' && grep {$_ eq $level} (qw(OUTPUT INFO))) {
					$prefix = '';
					$colors = '';
				} elsif ($config->{style} eq 'fun') {
					my $fg = substr($colors,1,1);
					$prefix = sprintf("#%s{[}#E{%s}#%s{%s] }",$fg,$emoji,$fg,$label);
					$prefix = "#K{$ts} $prefix" if $config->{timestamp};
				} elsif ($config->{style} eq 'plain') {
					my $fg = substr($colors,1,1);
					$prefix = "#${fg}{[$label]} ";
					$prefix = "#K{$ts} $prefix" if $config->{timestamp};
				} elsif ($config->{style} eq 'rfc-5424') {
					$priority += 8; # See https://datatracker.ietf.org/doc/html/rfc5424#section-6.2.1
					my $msgid = '-'; #FIXME: Not yet implemented
					no warnings 'once';
					my $cmd = $Genesis::Commands::COMMAND//'-';
					$prefix = sprintf(
						"<%s>1 %s %s genesis %s %s [%s v=\"%s\" c=\"%s\"] ",
						$priority, $ts, $self->{hostname}, $self->{pid}, $msgid,
						$label,
						#$self->{user},
						$self->{version}, $cmd,
						#$ENV{GENESIS_ORIGINATING_DIR}//'-',
						#$ENV{GENESIS_ROOT}//'-'
					);
					# RFC-5424 cannot wrap lines
					$pending = undef;
					$columns = 999;
					$indent = "  ";
				} else { # current default - if ($config->{style} eq 'pointer') {
					my ($gt,$gtc) = (">",$colors);
					$prefix = $label;
					unless (envset "NOCOLOR") {
						$gt = csprintf('#@{>}');
						$gtc = substr($colors||'-',1,1);
						$prefix = " $prefix " unless envset('GENESIS_NO_UTF8');
					}
					$colors = substr($colors,1,1) if envset('GENESIS_NO_UTF8');
					$prefix = "$ts $prefix" if $config->{timestamp};
					$prefix = sprintf("#%s{%s}#%s{%s} ", $colors,$prefix,$gtc,$gt)
				}

				$indent ||=  ' ' x csize($prefix);
				my $content;
				eval {
					our @trap_warnings = qw/uninitialized/;
					push @trap_warnings, qw/missing redundant/ if $^V ge v5.21.0;
					use warnings FATAL => @trap_warnings;
					$content = sprintf($template, @values);
				};
				if ($@) {
					require Data::Dumper;
					$content = "ERROR: $@\n".Data::Dumper::Dumper({template => $template, values => \@values});
					$show_stack = 'full';
					#TODO: log error without trigging another error in the log system...
				}
				my ($pre_pad, $post_pad) = ("","");
				($pre_pad, $content)  = $content =~ m/\A([\r\n]*)(.*)\z/s;
				($content, $post_pad) = $content =~ m/\A(.*?)([\r\n]*)\z/s unless $pending;

				# Swallow up pure whitespace if not on terminal
				my $last_waiting = $config->{waiting};
				$config->{waiting} = 0;
				next if ($log ne '<terminal>' && (!$last_waiting || $reset) && decolorize($content) =~ /\A\s*\z/);

				my $start_column = $last_waiting && !$reset ? $last_waiting : 0;
				my $out = wrap($content, $raw ? -1 : $columns, $colors ? $prefix : $indent, length($indent), undef, $start_column);

				# TODO: rfc-5424 may need to have newlines converted into \n strings.
				$reset = $reset && $last_waiting ? "\n" : '';
				if ($pending) {
					$config->{waiting} = (sort {$b <=> $a} (length($indent), length((split("\n",$out,-1))[-1])))[0];
				}

				# TODO: Support for logging STDOUT to all logs, not just STDOUT
				my $fh;
				if ($log eq '<terminal>') {
					$fh = ($level eq "OUTPUT") ? *STDOUT : *STDERR;
					if ($reset && $config->{waiting_fh}) {
						my $waiting_fh = $config->{waiting_fh};
						print $waiting_fh $reset;
					}
					$reset = '';
					$config->{waiting_fh} = $pending ? $fh : undef;
				} else {
					my $file = $log;
					$file =~ s/^~/$ENV{HOME}/;
					open $fh, '>>:encoding(UTF-8)', $file
						or die "Could not open $log for writing logs: $!\n";
				}
				$pre_pad =~ s/\A[\r\n]+// unless ($log eq '<terminal>' || ($last_waiting && !$reset));
				$post_pad =~ s/[\r\n]+\z// unless ($log eq '<terminal>' || $pending);
				$out .= "\n" unless $pending;
				print $fh csprintf("%s", $reset.$pre_pad.$out.$post_pad);
				$config->{last_label} = $label;

				# Deal with stack
				$show_stack = $config->{show_stack} if ($show_stack//"default") eq "default";
				$show_stack = ($pending || $show_stack eq 'none')
					? 'none'
					: (($show_stack||'') eq 'full' || ($config->{show_stack}||'') eq 'full')
					? 'full'
					: ((($show_stack||'') eq 'fatal' || ($config->{show_stack}||'') eq 'fatal') && $level eq 'FATAL')
					? 'full'
					: (($show_stack||'') eq 'current' || ($config->{show_stack}||'') eq 'current')
					? 'current'
					: 'invalid' ;

				unless ( $show_stack eq 'none' || $show_stack eq 'invalid') {
					for (@$stack) {
						my $line = sprintf("#Ki{ %s:L%d%s}", $_->{file}, $_->{line}, $_->{sub} ? " (in $_->{sub})" : " (pid: $$)");
						$out = wrap($line, $columns, $indent."#K\@{^-}");
						print $fh csprintf("%s\n", $out);
						last if $show_stack eq 'current';
					}
					print $fh "\n" if $log eq '<terminal>';
				}
				close $fh unless $log eq '<terminal>';
			}
		}
		$config->{next_entry} = $last_line+1;
	}
	$flushing = 0;
}

sub replay{
	my ($self,$level,$log) = @_;
	$log //= '<terminal>';

	my $original_level = $self->{logs}{$log}{level};
	$self->set_level($level) if $level;
	$self->{logs}{$log}{next_entry}=0;
	$self->flush_logs();
	$self->set_level($original_level) if $level;
	return
}

## Package functions

sub _log_item_level_map {
	return {
		'NONE'    => 0,
		'OUTPUT'  => 1,
		'FATAL'   => 2,
		'ERROR'   => 2,
		'WARNING' => 3,
		'INFO'    => 4,
		'DEBUG'   => 5,
		'VALUE'   => 6,
		'TRACE'   => 6,
		'STACK'   => 6,
	}
};

sub level_ord {
	return _log_item_level_map->{uc($_[0])}
}

sub log_levels {
	return (
		'NONE',
		'OUTPUT',
		'ERROR',
		'WARNING',
		'INFO',
		'DEBUG',
		'TRACE',
	);
};


# TODO: Replace this with a better call by those that call it.
sub get_scope {
	my ($scope) = @_;
	my $out = "";
	for (_get_stack($scope+1)) {
		$out .= csprintf("#K\@{^-}#Ki{ %s:L%d%s\n}", $_->{file}, $_->{line}, $_->{sub} ? " (in $_->{sub})" : '');
		last unless envset ("GENESIS_STACK_TRACE");
	}
	chomp $out;
	return $out;
}

sub get_stack {
	my ($scope) = @_;
	require Genesis; # FIXME: humanize_path should be moved to Genesis::IO or Genesis::Files

	my ($file,$line,$sub,@stack,@info);
	while (@info = caller($scope++)) {
		$sub = $info[3];
		push @stack, {line => $line, sub => $sub, file => Genesis::humanize_path($file)} if ($file);
		(undef, $file, $line) = @info;
	}
	push @stack, {line => $line, file => Genesis::humanize_path($file)};
	return @stack;
}

# This should only be used to validate user input, not internal
sub find_log_level {
	my $log_level = shift;

	$log_level = uc($log_level);
	unless (level_ord($log_level)) {
		my @log_levels = grep {$_ =~ qr/^$log_level.*/i} (log_levels());
		if (scalar(@log_levels) == 1) {
			$log_level = $log_levels[0];
		} elsif (scalar(@log_levels) > 1) {
			require Genesis;
			Genesis::bail(
				"Ambiguous log level $log_level: please specify one of ".join(", ",@log_levels)
			);
		} else {
			require Genesis;
			Genesis::bail(
				"Not a valid log level '$log_level': please specify one of ".join(", ",log_levels())
			);
		}
	}
	return $log_level;
}

sub meets_level {
	my ($level, $target) = @_;
	$level = level_ord($level) unless grep {$level eq $_} (values %{_log_item_level_map()});
	$target = level_ord($target) unless grep {$target eq $_} (values %{_log_item_level_map()});
	return $level >= $target;
}

1;
