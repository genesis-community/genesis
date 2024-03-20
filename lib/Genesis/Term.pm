package Genesis::Term;
use strict;
use warnings;
use feature 'state';
no warnings 'utf8';
use utf8;

use Genesis::State;

use Data::Dumper;
use File::Basename qw/basename dirname/;
use File::Find ();
use IO::Socket;

use base 'Exporter';
our @EXPORT = qw/
	terminal_width
	wrap fix_wrap
	in_controlling_terminal
	csprintf csize
	bullet checkbox
	decolorize
	boxify
	build_markdown_table
	process_markdown_block
	render_markdown
	elipses
/;

my $has_tput = $ENV{TERM} ? undef : 0; # tput doesn't work if $TERM isn't defined
sub terminal_width {
	return $ENV{GENESIS_OUTPUT_COLUMNS} if $ENV{GENESIS_OUTPUT_COLUMNS};
	unless (defined($has_tput)) {
		my $out = `/bin/bash -c "type -p tput"`;
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
	return "" unless length($msg);
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
		'x'   => "\x{2620} ",
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

sub _emojify {
	my $emoji = shift;
	my %emojis = (
		'crystal-ball' => "\x{1F52E}",
		'stop-sign' => "\x{1F6D1}",
		'collision' => "\x{1F4A5}",
		'information' => "\x{2139}\x{FE0F} ",
		'fire' => "\x{1F525}",
		'magnifying-glass' => "\x{1F50E}",
		'detective' => "\x{1F575}\x{FE0F} ",
		'warning' => "\x{26A0}\x{FE0F} ",
		'pancakes' => "\x{1F95E}",
		'tap' => "\x{1F6B0}",
		'memo' => "\x{1F4DD}",
		'notes' => "\x{1F5D2}\x{FE0F} ",
		'printer' => "\x{1F5A8}\x{FE0F} ",
		'tada' => "\x{1F389}"
	);
	return '' if envset('GENESIS_NO_UTF8');
	return $emojis{$emoji} // '';
}

sub boxify {
	my ($line,$position) = @_;
	return '' unless $line =~ /^(top|line|mid|bot)$/ && $position =~ /^(left|right|span|div)$/;

	my %box_glyphs;
	if (envset('GENESIS_NO_UTF8') || envset('GENESIS_NO_BOXES')) {
		%box_glyphs = (
			top  => ["+", "+", "-", "+"],
			line => ["|", "|", " ", "|"],
			mid  => ["+", "+", "-", "+"],
			bot  => ["+", "+", "-", "+"],
		);
	} else {
		%box_glyphs = (
			top  => ["\x{250F}", "\x{2513}", "\x{2501}", "\x{2533}"], # ┏ ┓ ━ ┳
			line => ["\x{2503}", "\x{2503}", " ",        "\x{2503}"], # ┃ ┃   ┃
			mid  => ["\x{2523}", "\x{252B}", "\x{2501}", "\x{254B}"], # ┣ ┫ ━ ╋
			bot  => ["\x{2517}", "\x{251B}", "\x{2501}", "\x{253B}"], # ┗ ┛ ━ ┻
		);
	}
	return $box_glyphs{$line}[{left=>0,right=>1,span=>2,div=>3}->{$position}];
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
	$s =~ s/#E\{([^\}]*)\}/_emojify($1)/egism;
	return $s;
}

sub decolorize {
	my ($s) = @_;
	$s =~ s/#([-IUKRGYBMPCW*]{1,4})\@\{([^{}]*(?:{[^}]+}[^{}]*)*)\}/"#${1}{"._glyphize('',$2)."}"/egism;
	$s =~ s/#([-IUKRGYBMPCW*]{1,4})\{([^{}]*(?:{[^}]+}[^{}]*)*)\}/$2/gism;
	$s =~ s/#E\{[^\}]+}//g; # remove any emojis
	$s =~ s/\e[[0-9;]*m//g; # remove any already converted to ansi colors
	return $s
}

sub csize {
	my $str = shift;
	my $size = length(decolorize($str)) + length(join('', (map {'  '} $str =~ m/#E\{[^\}]+}/g)));
}

sub wrap {
	my ($str, $width, $prefix, $indent, $continue_prefix, $init_col) = @_;
	$prefix ||= '';
	$indent ||= csize($prefix);
	$continue_prefix ||= '';
	my $continue_length =csize($continue_prefix);

	my $results = "";
	my $prefix_length;
	$prefix_length = csize($prefix);
	my $sep = $prefix;
	$sep .= ' ' x ($indent - $prefix_length) if $indent > $prefix_length;
	$sep = ' ' x ($init_col) if $init_col;
	my ($sub_indent, $sub_prefix);
	my @blocks = split(/\r?\n/, $str, -1);
	push @blocks, '' unless @blocks; # '' doesn't split
	for my $block (@blocks) {
		if ($width < 0) {
			# Raw mode, just indent on newlines...
			$results .= $sep . $block . "\n";
			$sep = ' ' x $indent;
			next
		}

		$block =~ s/^\[\[(.*?)>>\[\[(.*?)>>/\[\[$1$2>>/
			while $block =~ m/^\[\[(.*?)>>\[\[(.*?)>>/;
		if ($block =~ /^\[\[(.*?)>>(.*)$/) {
			$sep = $sep . $1;
			$sub_indent = csize($1);
			$block = $2;
		} else {
			$sub_indent = 0;
		}
		my @block_bits = split(/(\s+)/, $block, -1);
		push(@block_bits, '','') unless @block_bits;
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
		$line = '' if $line eq (' ' x $indent);
		$results .= "$line\n";
		$sep = ' ' x $indent;
	}
	chop $results;
	$results = substr($results,$init_col) if $init_col;
	return $results;
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

	if ($opts{symbol} =~ m/^#\@\{([^\}]+)\}$/) {
		$opts{symbol} = '#'.$opts{color}.'@{'.$1.'}';
	} else {
		$opts{symbol} = '#'.$opts{color}.'{'.$opts{symbol}.'}';
	}

	my $out=sprintf('%*.*s%s%s%s %s',
	                 $opts{indent},$opts{indent},'',
	                       $lbox,
	                           $opts{symbol},
	                              $rbox,
	                                 $msg);
	return $out;
	1;
}
# checkbox - make a checkbox (convencience bullet subset) {{{
sub checkbox {
	return bullet($_[0] eq 'warn' ? 'warn' : ($_[0] && $_[0] ne 'error' ? 'good' : 'bad'), '', box => 1, inline => 1, indent => 0);
}
# }}}

sub in_controlling_terminal {
	-t STDIN && -t STDOUT;
}

sub build_markdown_table {
	# Convert a markdown table to a table with automatic column widths
	# and alignment.
	
	# First, we need to parse the markdown table into a data structure
	# that we can work with.  We'll use a regex to do this.
	my ($table, %opts) = @_;
	my $rows = [
		map {s/^\s*\|\s*//r =~ s/\s*\|\s*$//r}
		split(/\n/, $table)
	];
	my @headers = ();
	my @col_align = ();
	my $blank_rows = 0;
	while (@$rows && $rows->[0] =~ m/^\s*$/) {
		shift @$rows;
		$blank_rows++;
	}
	if ($rows->[1] =~ m/^:?---+/) {
		@headers = split(/ *\| */, shift @$rows, -1);
		@col_align = map {m/^:-/ ? (m/-+:$/ ? 'c' : 'l' ) : (m/-:$/ ? 'r' : 'l')} split(/\s*\|\s*/, shift @$rows, -1);
	}
	my @data = map {[split(/ *\| */,$_,-1)]} @$rows;
	my @col_min_widths = map {length($_)} @headers;
	my @col_max_widths = @col_min_widths;
	for my $row (@data) {
		for my $i (0..$#$row) {
			# Determine the minimum width of each column by the length of the longest word
			# in each column.
			my $longest_word = (sort {length($b) <=> length($a)} split(/\s+/, $row->[$i]//''))[0] // 0;
			$col_min_widths[$i] = length($longest_word) if length($longest_word) > ($col_min_widths[$i]//0);

			# Determine the total width of each column by the length of the longest line
			$col_max_widths[$i] = length($row->[$i]) if length($row->[$i]) > ($col_max_widths[$i]//0);
		}
	}

	# Next, we'll determine the maximum width of each column as a percentage of the
	# total width of the table.
	my $total_width = ($opts{width}//terminal_width());
	my $total_content_width = $total_width - scalar(@headers) * 3 - 1;
	my $min_row_width = 0;
	my $max_row_width = 0;
	$min_row_width += $_ for @col_min_widths;
	$max_row_width += $_ for @col_max_widths;
	my @col_widths = ();
	if ($min_row_width > $total_content_width) {
		$total_content_width = $min_row_width;
		@col_widths = @col_min_widths;
	} elsif ($max_row_width > $total_content_width) {
		my $extra_width = $total_content_width - $min_row_width;
		@col_widths = map {
			int($col_min_widths[$_] + $extra_width * ($col_max_widths[$_] - $col_min_widths[$_]) / ($max_row_width - $min_row_width))
		} 0..$#col_min_widths;
		my $total_col_widths = 0;
		$total_col_widths += $_ for @col_widths;
		my $diff = $total_content_width - $total_col_widths;
		my $index_of_longest_col = (sort {$col_widths[$b] <=> $col_widths[$a]} 0..$#col_widths)[0];
		$col_widths[$index_of_longest_col] += $diff;

	} elsif ($opts{expand}) {
		my $extra_width = $total_content_width - $max_row_width;
		@col_widths = map {
			$col_max_widths[$_] + int($extra_width * ($col_max_widths[$_] - $col_min_widths[$_]) / ($max_row_width - $min_row_width))
		} 0..$#col_max_widths;
		my $total_col_widths = 0;
		$total_col_widths += $_ for @col_widths;
		my $diff = $total_content_width - $total_col_widths;
		my $index_of_shortest_col = (sort {$col_widths[$a] <=> $col_widths[$b]} 0..$#col_widths)[0];
		$col_widths[$index_of_shortest_col] += $diff;
	} else {
		@col_widths = @col_max_widths;
	}
	
	# Finally, we'll render each row of the table with the appropriate column widths
	# and alignment.
	return "\n" x $blank_rows .
		# Top line
		boxify(top => 'left') .
		join(boxify(top => 'div'), map {
			boxify(top => 'span') x (2 + $col_widths[$_])
		} 0..$#headers) .
		boxify(top => 'right')."\n" .
		# Header line
		boxify(line => 'left') .
		join(boxify(line => 'div'), map {
			csprintf("[1;7m ")._align($headers[$_], $col_widths[$_], $col_align[$_]).csprintf(" [0m")
		} 0..$#headers) .
		boxify(line => 'right')."\n" .
		# Content lines
		join("", map {
			boxify(mid => 'left') .
			join(boxify(mid => 'div'), map {
				boxify(mid => 'span') x (2+ $col_widths[$_])
			} 0..$#headers) .
			boxify(mid => 'right')."\n" .
			_multiline_row($_, \@col_widths, \@col_align)
		} @data) .
		# Bottom line
		boxify(bot => 'left') .
		join(boxify(bot => 'div'), map {
			boxify(bot => 'span') x (2+ $col_widths[$_])
		} 0..$#headers) .
		boxify(bot => 'right')."\n";
}

my $last_indent = -1;
my $last_block = '';
my $last_num = 0;
sub build_markdown_list {
	# Render a markdown list to the terminal, wrapping it to the terminal width.
	# It will detect if the list is ordered or unordered and render it as such.
	my ($type, $block, %opts) = @_;
	my $width = $opts{width} // terminal_width();
	my @li = ();
	my $indicator = $type eq 'list' ? '[-+\*]' : '\d+\.';
	my @lines = split(/\n/, $block);
	while (@lines) {
		my $line = shift @lines;
		if ($line =~ m/^(\s*)(${indicator})\s+(.*?)\s*$/) {
			my ($item, $point, $indent) = ($3, $2, length($1)+2);
			$last_num = $last_num + 1
				if ($type eq 'numbered_list');
			$point = $type eq 'numbered_list' 
				? sprintf('%2d. >>', $last_num)
				: bullet($point, '>>', indent => 0);
			push @li, '[['.(' 'x ($indent - 2)).$point.$item;
			$li[-1] = "\n" . $li[-1] if scalar(@li) > 1; # Separate multiple lists in the same block
			$last_indent = $indent;
		} elsif (!@li) {
			# Handle code blocks in list items
			if ($line =~ m/\A\s*```+\s*$/) {
				while (@lines && $line !~ m/.+^\s*```\z/m) {
					$line .= "\n" . shift @lines;
					last if $line =~ m/^\s*```+\z/m;
				}
				my $codeblock_indent = $line =~ m/\A( \s)/ ? $1 : '';
				# Strip the indent from the code block
				$line =~ s/^${codeblock_indent}//gm;
				push @li, build_markdown_codeblock($line, %opts, indent => length($codeblock_indent), padding => 0);
			} else {
				# Continuation of previous list item from previous block
				push @li, '[['.(' 'x ($last_indent)).'>>'.$line =~ s/^\s+//r;
			}
		} else {
			# Continuation of previous list item in this block
			# TODO: do we need to track the previous indent level?
			$li[-1] .= $line =~ s/^\s+/ /r;
		}
	}
	$last_block = $type;
	return wrap(join("\n", @li), $width);
}

sub build_markdown_codeblock {
	# Render a markdown code block to the terminal, wrapping it to the terminal width.
	my ($block, %opts) = @_;
	my $width = $opts{width} // terminal_width();
	my $indent = $opts{indent} // 0;
	my $padding = $opts{padding} // 4;
	my $code_width = $width - $indent - ($padding * 2);
	my $prefix = ' ' x $indent;
	my $rendered_block = '';
	$block =~ s/^\s*```.*\n//;
	$block =~ s/\n\s*```.*\n?$//;
	return join("\n", map {
		csprintf("%s%s#kK{%-*.*s}", $prefix, ' ' x $padding, $code_width, $code_width, elipses($_, $code_width))
	} split(/\n/, $block))."\n";
}

sub build_markdown_paragraph {
	# Render a markdown paragraph to the terminal, wrapping it to the terminal width.
	# The current code will takes any prefix padding from the first line of the 
	# paragraph and apply it to the rest of the lines, regardless of the prefix
	# padding of the rest of the lines.  This simplification may be altered in the
	# future if it becomes a problem.
	my ($block, %opts) = @_;
	my $width = $opts{width} // terminal_width();
	my $prefix = $opts{indent} 
		? ' ' x $opts{indent} 
		: $opts{prefix} 
		? $opts{prefix}
		: $block =~ m/\A(\s+)/ ? $1 : '';
	$block =~ s/\A\s+//;
	my @sub_blocks = split(/\n{2,}/, $block);
	return join("\n$prefix\n", map {wrap(
		$_ =~ s/\s+/ /gr =~ s/\. ([^ ])/.  $1/gr,
		$width - length($prefix),
		$prefix
	)} @sub_blocks);
}

sub build_markdown_blockquote {
	# Render a markdown blockquote to the terminal, wrapping it to the terminal width.
	my ($block, %opts) = @_;
	my $width = $opts{width} // terminal_width();
	my $indent = $opts{indent} // 2;
	my $rendered_block = '';
	$block =~ s/^\s*>\s*//;
	$block =~ s/\n\s*>\s*//g;
	return wrap($block, $width, ' ' x $indent, $indent);
	return wrap($block =~ s/^\s*>\s*//gmr, $width, boxify('line', 'left').' ');
}

sub process_markdown_block {
	# Render a markdown block to the terminal, wrapping it to the terminal width.
	# It will detect if the block is a table and render it as such.
	# It will also render inline formatting such as bold, italic, and code.
	my ($block, %opts) = @_;
	my $width = $opts{width} // terminal_width();

	# Check for embedded links
	my $links = $opts{links};
	$block =~ s/\[([^\]]+)\]\(## "(.*?)"\)/$1 [#i{$2}]/g;
	while ($block =~ s/\[([^\]]+)\](?:\((.*?)\)|(\[\d+\]))/"#Bu{$1}".superscript(scalar(@$links)+1)/e) {
		push @$links, [$1, $2||$3];
	}

	while ($block =~ m/(^\s*(\[\d+\]): (.*?)(?:\n|$))/) { # Footnote link references
		my $line = $1;
		my $ref = $2;
		my $link = $3;
		for my $i (0..$#$links) {
			if ($links->[$i][1] eq $ref) {
				$links->[$i][1] = $link;
			}
		}
		$block =~ s/\Q$line\E//;
		return '' unless $block =~ m/\S/;
	}

	# Check for inline formatting (except for code blocks)
	unless ($block =~ m/^\s*```/) {
		$block =~ s/\*\*([^ \*][^\*]*)\*\*/[1;36m$1[0m/gs unless envset('GENESIS_NOCOLOR');
		$block =~ s/\*([^ \*][^\*]*)\*/[3m$1[0m/gs unless envset('GENESIS_NOCOLOR');
		$block =~ s/([^`])`([^ `][^`]*)`/$1#kK{$2}/gs unless envset('GENESIS_NOCOLOR');
		$block =~ s/~~(.*?)~~/[9m$1[0m/gs unless envset('GENESIS_NOCOLOR');
	}

	if ($block =~ m/^(\s*)[-+\*] / || ($last_block eq 'list' && $block =~ m/^(\s*)\S/ && $last_indent == length($1))) {
		# Unordered list
		return build_markdown_list('list', $block, %opts);
	} elsif ($block =~ m/^\s[1-9]\d*\.\s/ || ($last_block eq 'numbered_list' && $block =~ m/^(\s*)\S/ && $last_indent == length($1))) {
		# Numbered list
		return build_markdown_list('numbered_list', $block, %opts);
	}

	$last_indent = -1;
	$last_block = '';
	$last_num = 0;
	if ($block =~ m/^\s*```/) {
		# Code block
		return build_markdown_codeblock($block, %opts);
	} elsif ($block =~ s/^\s*(#+)\s//) {
		# Header
		my $block_level = length($1);
		if ($block_level == 1) {
			# TODO: wrap to terminal width instead of truncating
			$block = sprintf("#Ck{%s\n%-*.*s\n%s}", '=' x $width, $width, $width, decolorize($block), '=' x $width);
		} elsif ($block_level == 2) {
			$block = sprintf("#G{%s\n%s}", decolorize($block), '-' x length($block));
		} elsif ($block_level == 3) {
			$block = sprintf("#Yu{%s}", $block);
		} elsif ($block_level == 4) {
			$block = sprintf("#Mi{%s}", $block);
		}
		return wrap($block, $width);
	} elsif ($block =~ m/^\s*>\s*/) {
		# Blockquote
		return build_markdown_blockquote($block, %opts);
	} elsif ($block =~ m/^\|? ?:?---+:? ?\|/m) {
		# Table
		# TODO: support headerless tables
		return build_markdown_table($block, %opts);
	} else {
		# Paragraph
		return build_markdown_paragraph($block, %opts);
	} 
}

sub render_markdown {
	my ($md, %opts) = @_;
	$last_indent = -1;
	$last_block = '';
	$last_num = 0;
	my $links = [];
	my @blocks = split(/\n{2,}/, $md =~ s/\r\n/\n/gr);

	# TODO: instead of preemptively joining fractured blocks, it might be better
	#       to pass in all the remaining blocks and let each block processor
	#       decide if it should join with the next block or not.
	#
	#       Design considerations:
	#       - Global replacements for formatting can be done per sub-block, which
	#         is important for things like code blocks embedded in lists.

	# Join any fractured code blocks
	my $i = 0;
	while ($i < @blocks) {
		if ($blocks[$i] =~ m/\A\s*```/m && $blocks[$i] !~ m/^\s*```\z/m) {
			my $j = $i+1;
			while ($j < @blocks) {
				$blocks[$i] .= "\n\n".$blocks[$j];
				splice(@blocks, $j, 1);
				last if $blocks[$i] =~ m/^\s*```\z/m;
			}
		}
		$i++;
	}

	# Ensure blockquote blocks are actually blockquotes
	$i = 0;
	while ($i < @blocks) {
		if ($blocks[$i] =~ m/^\s*```/m) {
			$i++;
			next;
		}
		if ($blocks[$i] =~ m/^\s*>\s/m) {
			my @sub_blocks = ();
			my $in_blockquote = 0;
			my $blockquote_lines = split(/\n/, $blocks[$i]);
			my $sub_block = '';
			for my $line (split(/\n/, $blocks[$i])) {
				if ($line =~ m/^\s*>\s/) {
					push @sub_blocks, $sub_block if $sub_block && !$in_blockquote;
					$in_blockquote = 1;
					$sub_block .= $line."\n";
				} else {
					push @sub_blocks, $sub_block if $sub_block && $in_blockquote;
					$in_blockquote = 0;
					$sub_block = $line."\n";
				}
			}
			push @sub_blocks, $sub_block if $sub_block;
			splice(@blocks, $i, 1, @sub_blocks)
				if (scalar(@sub_blocks));
			$i += scalar(@sub_blocks) - 1;
		}
		$i++;
	}

	my $output = csprintf("%s\n",
		join("\n\n", map {
			process_markdown_block($_, %opts, links => $links)
		} @blocks)
	);
	if (scalar(@$links)) {
		$output .= process_markdown_block("### Links", %opts);
		$output .= "\n" . join("\n", map {
			"[".($_+1)."] ".$links->[$_][1]
		} 0..$#$links) . "\n";
	}
	return $output;
}

sub _align {
	my ($str, $width, $align) = @_;
	my $len = csize($str);
	return $str if $len >= $width;
	my $pad = $width - $len;
	return $align eq 'l' 
	? $str . ' ' x $pad
	: $align eq 'r'
	? ' ' x $pad . $str
	: ' ' x int($pad/2) . $str . ' ' x int($pad/2 + $pad % 2);
}

sub _multiline_row {
	# TODO: alternate row colors
	#       wrap cells to minimize total row height
	my ($row, $col_widths, $col_align) = @_;
	my @cells = map {[
		split(/\n|<br>/,
			wrap($row->[$_], $col_widths->[$_]) # TODO: support for inline formatting
		)
	]} 0..$#$row;
	my $num_lines = (sort {$b <=> $a} map {scalar(@$_)} @cells)[0] || 1;
	my $rendered_row = '';
	for my $i (0..$num_lines-1) {
		$rendered_row .= 
			boxify(line => 'left') .
			join(boxify(line => 'div'), map {
				" ".
				_align($cells[$_][$i] // '', $col_widths->[$_], $col_align->[$_]) .
				" "
			} 0..$#cells) .
			boxify(line => 'right')."\n";
	}
	return $rendered_row;
}

sub superscript {
	return "[#i{*".shift."}]" if envset('GENESIS_NO_UTF8');
	my $superscript = {
		'0' => "\x{2070}",
		'1' => "\x{00B9}",
		'2' => "\x{00B2}",
		'3' => "\x{00B3}",
		'4' => "\x{2074}",
		'5' => "\x{2075}",
		'6' => "\x{2076}",
		'7' => "\x{2077}",
		'8' => "\x{2078}",
		'9' => "\x{2079}",
	};
	return join('', map {$superscript->{$_}} split(//, shift));
}

sub elipses {
	my ($str, $len) = @_;
	return $str if length($str) <= $len;
	return substr($str, 0, $len-3) . '...';
}

# TODO:
# - paint:
#   - takes a string that contains color codes and allows the uncolored
#     sections to be colorized with the given color.
#   - paint("This is #C{very} important", "w") => "#w{This is }#C{very}#w{ important}"
#
#   - To be determined:
#     - Does it paint over dashes (default color) -- ie with "#C{}" become
#       "#CY{}" if painted with '-Y' or 'kY'
#     - Can you apply italic and underline with it
#
#   Motive: To be able to paint blocks of output that may already contain
#           stylizing, such as alternating color of table rows
#
# - markdown (DONE):
#   - render markdown document
#   - support for bullets, tables, numbering, headers, blockquotes
#   - H1 is double underlined, bold
#   - H2 is single underlined, bold
#   - H3 is bold
#   - H4 is italicized
#
#   - blockquotes are indented and italicized
#   - inline bold and italics supported with ** and * respectively (not __ and _)
#   - bullets use +, -, and *
#   - code is indented 4 spaces and rendered as light grey on a dark grey
#     background
#
#   - Paragraphs are separated with blank lines, and will be rerendered wrapped
#     to terminal width. Internal <br> will be replaced with a newline without
#     needing blank lines <- TODO the last part
#
#   Motive: render help docs and release notes created in markdown, needed for
#           help refactor phase 2

1;
