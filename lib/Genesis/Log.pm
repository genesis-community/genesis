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
	$Genesis::Log::Logger //= bless({
		buffer => [],
		logs => {},
	}, $class);
	return $Genesis::Log::Logger;
}

sub configure_log {
	my ($self, $log, %options) = @_;
	my @valid_levels = qw/ERROR WARN DEBUG INFO TRACE/;
	my ($level, $level_label);

	unless ($self->{logs}{$log}) {
		$self->{logs}{$log} = {
			level => 2,
			level_label => 'WARN',
			show_stack  => 'none',
			timestamp   => ($log eq '<STDERR>' ? 0 : 1),
			next_entry  =>  0
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
	#TODO: clean up old log files based file existing and being outdated as per
	#$options->{max_log_age}; -- special age 'current' means truncate on startup
	return $self;
}

sub set_level {
	my ($self,$level,$log) = @_;
	$log ||= '<STDERR>';
	die "invalid log: $log\n" unless defined($self->{logs}{log});
	$level = find_log_level($level);
	@{$self->{logs}{$log}}{qw/level level_label/} = (level($level),$level);
	return $self;
}

sub info   { shift->_log("INFO ", "Wg", @_) }
sub debug  { shift->_log("DEBUG", "Wm", @_) }
sub warn   { shift->_log("WARN ", "kY", @_) }
sub error  { shift->_log("ERROR", "Wr", @_) }
sub fatal  { shift->_log("FATAL", "Yr", {show_stack => 'full'}, @_) }
sub trace  { shift->_log("TRACE", "Wc", {show_stack => 'current'}, @_); }
sub qtrace { shift->_log("TRACE", "Wc", @_); }

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
		$self->_log("VALUE", "Wb", {show_scope => 'current', offset => $scope}, "#M{%s} = %s", $_, $value);
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
	$self->_log("STACK", "kY", $options, $header.join("\n",map {
		csprintf("#w{%*s}  #Y{%-*s}  #Ki{%s}", $sizes{line}, $_->{line}, $sizes{sub}, $_->{sub}||'', $_->{file})
	} @stack));
}

sub _log {
	my ($self, $label, $colors, @contents) = @_;
	my $options = {};
	while (ref($contents[0]) eq 'HASH') {
		my $more_options = shift @contents;
		$options->{offset} = $options->{offset}||0 + delete($more_options->{offset}) if $more_options->{offset};
		@{$options}{keys %$more_options} = values %$more_options;
	}
	unshift @contents, "%s" if scalar(@contents) == 1;
	my $level = $options->{level} || $label;
	$level =~ s/ +$//g;

	my ($s,$us) = gettimeofday;
	my $ts = sprintf "%s.%03d", localtime($s)->strftime("%H:%M:%S"), $us / 1000;

	my $show_stack = $options->{show_stack};
	my @stack = ($level eq 'STACK') ? () :
		get_stack(($options->{offset}||0)+2);

	push @{$self->{buffer}}, [$level, $ts, $label, $colors, \@contents, $show_stack, \@stack];

	# Check if there are any logs for the given level
	$self->flush_logs();
}

sub flush_logs {
	my $self = shift;
	my $last_line = $#{$self->{buffer}};

	for my $log (keys %{$self->{logs}}) {
		my $config = $self->{logs}{$log};
		for my $line_number ($config->{next_entry}..$last_line) {
			my ($level, $ts, $label, $colors, $contents, $show_stack, $stack)
				= @{@{$self->{buffer}}[$line_number]};

			next unless meets_level($config->{level},$level);

			unshift(@$contents, "%s") unless scalar(@$contents > 1);
			my ($template, @values) = @$contents;

			do {
				local $ENV = $ENV;
				$ENV{NOCOLOR} = $config->{no_color} if defined($config->{no_color});
				$ENV{GENESIS_NO_UTF8} = $config->{no_utf8} if defined($config->{no_utf8});
				my $columns = $log eq '<STDERR>' ? terminal_width : ($config->{width} || 80);

				my ($gt,$gtc) = (">",$colors);
				unless (envset "NOCOLOR") {
					$gt = csprintf('#@{>}');
					$gtc = substr($colors||'-',1,1);
					$label = " $label " unless envset('GENESIS_NO_UTF8');
				}
				$colors = substr($colors,1,1) if envset('GENESIS_NO_UTF8');
				$label = "$ts $label" if $config->{timestamp};

				my $prompt = sprintf("#%s{%s}#%s{%s} ", $colors,$label,$gtc,$gt);
				my $blank_prompt =  ' ' x length(decolorize($prompt));
				my $content = sprintf($template, @values);
				my $out = wrap($content, $columns, $colors ? $prompt : $blank_prompt );

				# TODO: Support for logging STDOUT to all logs, not just STDOUT
				my $fh;
				if ($log eq '<STDERR>') {
					$fh = *STDERR;
					binmode STDERR, 'utf8';
				} else {
					open $fh, '>>:encoding(UTF-8)', $log
						or die "Could not open $log for writing logs\n";
				}
				printf $fh csprintf("%s\n", $out);

				# Deal with stack
				$show_stack =
					(!defined($show_stack) && !defined($config->{show_stack})) ? 'none' :
					(($show_stack||'') eq 'full' || ($config->{show_stack}||'') eq 'full') ? 'full' :
					(($show_stack||'') eq 'current' || ($config->{show_stack}||'') eq 'current') ? 'current' :
					'invalid';

				unless ( $show_stack eq 'none' || $show_stack eq 'invalid') {
					for (@$stack) {
						my $line = sprintf("#Ki{ %s:L%d%s}", $_->{file}, $_->{line}, $_->{sub} ? " (in $_->{sub})" : '');
						$out = wrap($line, $columns, $blank_prompt."#K\@{^-}");
						print $fh csprintf("%s\n", $out);
						last if $show_stack eq 'current';
					}
				}
				close $fh unless $log eq '<STDERR>';
			}
		}
		$config->{next_entry} = $last_line+1;
	}
}

## Package functions

sub _log_item_level_map {
	return {
		'NONE'  => 0,
		'OUT'   => 0, #STDOUT, primary information
		'MSG'   => 1, #STDERR, stuff that doesn't get redirected
		'FATAL' => 1,
		'ERROR' => 1,
		'WARN'  => 2,
		'INFO'  => 3,
		'DEBUG' => 4,
		'VALUE' => 5,
		'TRACE' => 5,
		'STACK' => 5,
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

$Genesis::Log::Logger ||= Genesis::Log->new();

1;
