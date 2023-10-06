package Genesis::Log;
use strict;
use warnings;

use utf8;
#use open ':encoding(utf-8)';

use Genesis::State;
use Genesis::Term;

use POSIX qw/strftime/;
use Symbol qw/qualify_to_ref/;
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
	my ($level, $level_label);

	unless ($self->{logs}{$log}) {
		$self->{logs}{$log} = {
			level => 3,
			level_label => 'INFO',
			show_stack  => 'none',
			timestamp   => ($log eq '<terminal>' ? 0 : 1),
			next_entry  =>  0,
			style       => $ENV{GENESIS_LOG_STYLE}//'pointer'
		}
	}
	if ($options{level}) {
		my $level_label = find_log_level($options{level});
		$self->{logs}{$log}{level_label} = $level_label; ;
		$self->{logs}{$log}{level} = level($level_label);
	}
	$self->{logs}{$log}{show_stack} = $options{show_stack} if defined($options{show_stack});
	$self->{logs}{$log}{timestamp} = $options{timestamp} if defined($options{timestamp});
	$self->{logs}{$log}{next_entry} = scalar(@{$self->{buffer}}) if $options{truncate};
	$self->{logs}{$log}{style} = $options{style} if $options{style};
	$self->{logs}{$log}{no_color} = $options{no_color} if defined($options{no_color});
	$self->{logs}{$log}{no_utf8} = $options{no_utf8} if defined($options{no_utf8});

	# Clean up log, unless in callback or log is STDERR
	unless ($log eq '<terminal>' || in_callback) {
		if ($options{lifespan}//'' eq 'current') {
			(my $file = $log) =~ s/^~/$ENV{HOME}/;
			open my $fh, '>', $file;
			truncate $fh, 0;
			close $fh;
		}
		# TODO: time based truncation
	}
	return $self;
}

sub is_logging {
	my ($self,$level,$log) = @_;
	$log ||= '<terminal>';
	return meets_level($self->{logs}{$log}{level}, $level)
		if ($self->{logs}{$log} && defined($self->{logs}{$log}{level}));
	return 0;
}

sub set_level {
	my ($self,$level,$log) = @_;
	$log ||= '<terminal>';
	die "invalid log: $log\n" unless defined($self->{logs}{log});
	$level = find_log_level($level);
	@{$self->{logs}{$log}}{qw/level level_label/} = (level($level),$level);
	return $self;
}

sub info   { shift->_log("INFO ", {colors => "Wc", pri => 6, emoji => 'information'}, @_) }
sub debug  { shift->_log("DEBUG", {colors => "Wm", emoji => 'crystal-ball'}, @_) }
sub warn   { shift->_log("WARN ", {colors => "ky", pri => 4, emoji => 'warning'}, @_) }
sub error  { shift->_log("ERROR", {colors => "WR", pri => 3, emoji => 'collision'}, @_) }
sub fatal  { shift->_log("FATAL", {colors => "Yr", pri => 0, emoji => 'stop-sign', show_stack => 'full'}, @_) }
sub trace  { shift->_log("TRACE", {colors => "WG", emoji => 'detective', show_stack => 'current'}, @_); }
sub qtrace { shift->_log("TRACE", {colors => "Wg", emoji => 'detective'}, @_); }

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
	my $scope = $options->{offset} || 0;
	$scope += abs(shift) if (defined $_[0] && $_[0] =~ '^-?\d+$');

	require Data::Dumper;
	local $Data::Dumper::Deparse = 1;
	local $Data::Dumper::Terse   = 1;
	my (%vars) = @_;
	for (keys %vars) {
		chomp (my $value = Data::Dumper::Dumper($vars{$_}));
		$self->_log("VALUE", {colors => "WB", show_scope => 'current', emoji => 'magnifying-glass', offset => $scope}, "#M{%s} = %s", $_, $value);
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
	$options->{colors} = 'kY';
	$options->{emoji} = 'pancakes';
	my $header = csprintf("#Wku{%*s}  #Wku{%-*s}  #Wku{%-*s}\n", $sizes{line}, "Line", $sizes{sub}, "Subroutine", $sizes{file}, "File");
	$self->_log("STACK", $options, $header.join("\n",map {
		csprintf("#w{%*s}  #Y{%-*s}  #Ki{%s}", $sizes{line}, $_->{line}, $sizes{sub}, $_->{sub}||'', $_->{file})
	} @stack));
}

sub _log {
	my ($self, $label, @contents) = @_;
	my $options = {};
	while (ref($contents[0]) eq 'HASH') {
		my $more_options = shift @contents;
		$options->{offset} = $options->{offset}||0 + delete($more_options->{offset}) if $more_options->{offset};
		@{$options}{keys %$more_options} = values %$more_options;
	}
	unshift @contents, "%s" if scalar(@contents) == 1;
	my $colors = $options->{colors} // '--';
	(my $level = $options->{level} || $label) =~ s/^\s*(.*?)\s*$/$1/;
	my $priority = $options->{pri} // 7;
	$level =~ s/ +$//g;

	my ($s,$us) = gettimeofday;
	my $ts = sprintf "%s.%03dZ", gmtime($s)->strftime("%Y-%m-%dT%H:%M:%S"), $us / 1000;

	my $show_stack = $options->{show_stack};
	my @stack = ($level eq 'STACK') ? () :
		get_stack(($options->{offset}||0)+2);

	push @{$self->{buffer}}, [$level, $ts, $label, $colors, $options->{emoji}//'', $priority, \@contents, $show_stack, \@stack];

	# Check if there are any logs for the given level
	$self->flush_logs();
}

sub flush_logs {
	my $self = shift;
	my $last_line = $#{$self->{buffer}};

	for my $log (keys %{$self->{logs}}) {
		my $config = $self->{logs}{$log};
		for my $line_number ($config->{next_entry}..$last_line) {
			my ($level, $ts, $label, $colors, $emoji, $priority, $contents, $show_stack, $stack)
				= @{@{$self->{buffer}}[$line_number]};

			next unless meets_level($config->{level},$level);

			unshift(@$contents, "%s") unless scalar(@$contents > 1);
			my ($template, @values) = @$contents;

			do {
				local $ENV = $ENV;
				$ENV{NOCOLOR} = $config->{no_color} if defined($config->{no_color});
				$ENV{GENESIS_NO_UTF8} = $config->{no_utf8} if defined($config->{no_utf8});
				my $columns = $log eq '<terminal>' ? terminal_width : ($config->{width} || 120);
				my ($prefix,$indent);

				if ($log eq '<terminal>' && grep {$_ eq $level} (qw(OUTPUT INFO))) {
					$prefix =  '';
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
				my $content = sprintf($template, @values);
				my $out = wrap($content, $columns, $colors ? $prefix : $indent, length($indent));
				# TODO: rfc-5424 may need to have newlines converted into \n strings.

				# TODO: Support for logging STDOUT to all logs, not just STDOUT
				my $fh;
				if ($log eq '<terminal>') {
					$fh = ($level eq "OUTPUT") ? *STDOUT : *STDERR;
					binmode $fh, 'utf8';
				} else {
					my $file = $log;
					$file =~ s/^~/$ENV{HOME}/;
					open $fh, '>>:encoding(UTF-8)', $file
						or die "Could not open $log for writing logs\n";
				}
				printf $fh "%s\n", csprintf("%s", $out);

				# Deal with stack
				$show_stack =
					(!defined($show_stack) && !defined($config->{show_stack})) ? 'none' :
					(($show_stack||'') eq 'full' || ($config->{show_stack}||'') eq 'full') ? 'full' :
					(($show_stack||'') eq 'current' || ($config->{show_stack}||'') eq 'current') ? 'current' :
					'invalid';

				unless ( $show_stack eq 'none' || $show_stack eq 'invalid') {
					for (@$stack) {
						my $line = sprintf("#Ki{ %s:L%d%s}", $_->{file}, $_->{line}, $_->{sub} ? " (in $_->{sub})" : " (pid: $$)");
						$out = wrap($line, $columns, $indent."#K\@{^-}");
						print $fh csprintf("%s\n", $out);
						last if $show_stack eq 'current';
					}
				}
				close $fh unless $log eq '<terminal>';
			}
		}
		$config->{next_entry} = $last_line+1;
	}
}

## Package functions

sub _log_item_level_map {
	return {
		'NONE'   => 0,
		'OUTPUT' => 0,
		'FATAL'  => 1,
		'ERROR'  => 1,
		'WARN'   => 2,
		'INFO'   => 3,
		'DEBUG'  => 4,
		'VALUE'  => 5,
		'TRACE'  => 5,
		'STACK'  => 5,
	}
};

sub level {
	return _log_item_level_map->{uc($_[0])}
}

sub log_levels {
	return (
		'NONE',
		'ERROR',
		'WARN',
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
	unless (level($log_level)) {
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
				"No valid matchin $log_level: please specify one of ".join(", ",log_levels())
			);
		}
	}
	return $log_level;
}

sub meets_level {
	my ($level, $target) = @_;
	$level = level($level) unless grep {$level eq $_} (values %{_log_item_level_map()});
	$target = level($target) unless grep {$target eq $_} (values %{_log_item_level_map()});
	return $level >= $target;
}


1;
