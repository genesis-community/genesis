package Genesis::Term;
use strict;
use warnings;
no warnings 'utf8';
use utf8;

use Genesis::State;

use Data::Dumper;
use File::Basename qw/basename dirname/;
use File::Find ();
use IO::Socket;
use POSIX qw/strftime/;
use Symbol qw/qualify_to_ref/;
use Time::HiRes qw/gettimeofday/;
use Time::Piece;
use Time::Seconds;
use Cwd ();

use base 'Exporter';
our @EXPORT = qw/
	terminal_width
	wrap
	in_controlling_terminal
	csprintf csize
	bullet
	decolorize
/;

my $has_tput = $ENV{TERM} ? undef : 0; # tput doesn't work if $TERM isn't defined
sub terminal_width {
	return $ENV{GENESIS_OUTPUT_COLUMNS} if $ENV{GENESIS_OUTPUT_COLUMNS};
	unless (defined($has_tput)) {
		my $out = `type -p tput`;
		my $rc = $? >> 8;
		$has_tput = ($rc == 0) ? 1 : 0;
	}

	return ($ENV{GENESIS_OUTPUT_COLUMNS} || 80) unless $has_tput;
	return (grep {/^[0-9]*$/} split("\n",`tput cols`))[0] || $ENV{GENESIS_OUTPUT_COLUMNS} || 80;
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
	return "" unless $msg;
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
		'-'   => "✘ ", # \x{2718}
		'+'   => "✔ ", # \x{2714}
		'*'   => "\x{2022}",
		' '   => '  ',
		'>'   => "⮀",
		'!'   => "\x{26A0} ",
		'^-'  => "\x{2B11} ",
		'O'   => "\x{25C7}",
		'@'   => "\x{25C6}",
		'[ ]' => "\x{25FB}",
		'[x]' => "\x{25FC}",
		'X'   => "\x{25FC}",
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
		require Carp;
		$Carp::Verbose=1;
		Carp::confess($@) unless ($@ =~ /^(Missing|Redundant) argument|Use of uninitialized value/);
		Carp::cluck(@_) if ($ENV{GENESIS_DEV_MODE} || $ENV{GENESIS_TESTING});

		$s = sprintf($fmt, @args); # run again because the error didn't set it
		if (!$in_csprint_debug) {
			$in_csprint_debug = 1;
			require Genesis::Log;
			$Genesis::Log::Logger->debug("Got warning in csprintf: $@");
			$Genesis::Log::Logger->dump_var(template => $fmt, arguments => \@args);
			$Genesis::Log::Logger->dump_stack();
			$in_csprint_debug = 0;
		}
	}
	$s =~ s/#([-IUKRGYBMPCW*]{0,4})@\{([^{}]*(?:{[^}]+}[^{}]*)*)\}/_glyphize($1, $2)/egism;
	$s =~ s/#([-IUKRGYBMPCW*]{1,4})\{([^{}]*(?:{[^}]+}[^{}]*)*)\}/_colorize($1, $2)/egism;
	return $s;
}

sub decolorize {
	my ($s) = @_;
	$s =~ s/#([-IUKRGYBMPCW*]{1,4})\@\{([^{}]*(?:{[^}]+}[^{}]*)*)\}/"#${1}{"._glyphize('',$2)."}"/egism;
	$s =~ s/#([-IUKRGYBMPCW*]{1,4})\{([^{}]*(?:{[^}]+}[^{}]*)*)\}/$2/gism;
	$s =~ s/\e[[0-9;]*m//g; # remove any already converted to ansi colors
	return $s
}

sub csize {
	my $str = shift;
	my $size = length(decolorize($str)) + length(join('', (map {'  '} $str =~ m/#E\{[^\}]+}/g)));
}

sub wrap {
	my ($str, $width, $prefix, $indent, $continue_prefix) = @_;
	$prefix ||= '';
	$indent ||= csize($prefix);
	$continue_prefix ||= '';
	my $continue_length =csize($continue_prefix);

	my $results = "";
	my $prefix_length;
	$prefix_length = csize($prefix);
	my $sep = $prefix;
	$sep .= ' ' x ($indent - $prefix_length) if $indent > $prefix_length;
	my ($sub_indent, $sub_prefix);
	for my $block (split("\n", $str, -1)) {
		if ($block =~ /^\[\[(.*?)>>(.*)$/) {
			$sep = $sep . $1;
			$sub_indent = csize($1);
			$block = $2;
		} else {
			$sub_indent = 0;
		}
		my @block_bits = split(/(\s+)/, $block);
		my ($word, $next_sep);
		my $line = "";
		while (@block_bits) {
			($word, $next_sep, @block_bits) = @block_bits;
			if (csize($line . $sep . $word) > $width && $line) {
				$results .= $line . "\n";
				$line = $continue_prefix . ' ' x ($indent + $sub_indent - $continue_length);
				$sep = '';
			}
			$line .= $sep . $word;
			$sep = $next_sep;
		}
		$results .= "$line\n";
		$sep = ' ' x $indent;
	}
	chop $results;
	return $results;
}


sub bullet { # [type,] msg, [{option: value, ...}]
	my $msg = shift;
	(my $type, $msg) = ($msg, shift) if (scalar(@_) % 2 > 0);
	my (%opts) = @_;

	$type ||= '';
	$opts{symbol} ||= $type eq 'good'  ? '#@{+}' :
	                  $type eq 'bad'   ? '#@{-}' :
	                  $type eq 'warn'  ? '#@{!}' :
	                  $type eq 'empty' ? '#@{ }' :
                                       '#@{*}' ;

	$opts{color}  ||= $type eq 'good'  ? 'G' :
	                  $type eq 'bad'   ? 'R' :
	                  $type eq 'warn'  ? 'Y' :
	                                     '-'  ;

	$opts{indent} = 2 unless exists($opts{indent});
	my ($lbox,$rbox) = !$opts{box} ? ('','') :
		(ref($opts{box}) eq 'ARRAY' ? @{$opts{box}} : ('[',']'));

	my $out=sprintf('%*.*s%s#%s{%s}%s %s',
	                 $opts{indent},$opts{indent},'',
	                       $lbox,
	                          $opts{color},
	                             $opts{symbol},
	                                $rbox,
	                                   $msg);
	return $out if ($opts{inline});
	explain $out;
	1;
}

sub in_controlling_terminal {
	-t STDIN && -t STDOUT;
}

1;
