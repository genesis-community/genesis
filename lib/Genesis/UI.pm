package Genesis::UI;
use v5.20;
use warnings;
use strict;

use base 'Exporter';
our @EXPORT = qw/
	prompt_for_boolean
	prompt_for_choices
	prompt_for_choice
	prompt_for_line
	prompt_for_list
	prompt_for_block
	new_prompt_for_choice
/;

# FIXME: This entire module uses print instead of the logging system (output, error, etc)

use Genesis;
use Genesis::Term;

use POSIX qw//;

sub __prompt_for_line {
	my ($prompt,$validation,$err_msg,$default,$allow_blank) = @_;
	$prompt = join(' ', grep {defined($_) && $_ ne ""} ($prompt, '>')) . " ";

	# `validate` is a sub with first argument the test value, and the second
	# being an optional error message
	#
	# NOTE:  IF YOU ADD OR MODIFY A VALIDATION, YOU NEED TO ADD IT TO THE
	#        `validate_kit_metadata` routine below
	my $validate;
	if (defined($validation)) {
		if (ref($validation) eq 'CODE') {
			$validate = $validation; # Only used by internal usage of prompts
		} elsif ($validation eq "ip") {
			$validate = sub() {
				my @ipbits = split(/\./, $_[0]);
				my $msg = ($_[1] ? $_[1] :"$_[0] is not a valid IPv4 address");
				return "" if scalar(grep {$_ =~ /^\d+$/ && $_ !~ /^0./ && $_ < 256} @ipbits) == 4;
				return "$msg: octets cannot be zero-padded" if scalar(grep {$_ =~  /^0./} @ipbits);
				return $msg;
			}
		} elsif ($validation eq "url") {
			$validate = sub() {
				return "" if (is_valid_uri($_[0]));
				return ($_[1] ? $_[1] :"$_[0] is not a valid URL");
			}
		} elsif ($validation eq "port") {
			$validate = sub() {
				return "" if ( ($_[0] =~ m/^\d+$/) && ($_[0] >= 0 ) && ($_[0] <= 65535) );
				return ($_[1] ? $_[1] :"$_[0] is not a valid port");
			}
		} elsif ($validation =~ m/^(-?\d+(?:.\d+)?)(?:(\+)|-(-?\d+(?:.\d+)?))$/) {
			my ($__min,$__unbound_max,$__max) = ($1,$2,$3);
			$__unbound_max ||= "";
			$validate = sub() {
				return "" if (($_[0] =~ m/^\d+$/) && ($_[0] >= $__min ) && ($_[0] <= $__max || $__unbound_max eq "+"));
				return ($_[1] ? $_[1] : ( $__unbound_max eq "+" ? "$_[0] must be at least $__min" : "$_[0] expected to be between $__min and $__max"));
			}
		} elsif ($validation =~ m/^(!)?\/(.*)\/(i?m?s?)$/) {
			my $__vre;
			my $__negate = ($1 && $1 eq "!");
			# safe because the only thing being eval'ed is the optional i,s, or m
			eval "\$__vre = qr/\$2/$3"
				or die "Error compiling param regex: $!";
			$validate = $__negate ? sub() {
				return ($_[0] !~ $__vre ? "" : ( $_[1] ? $_[1] : "Matches exclusionary pattern"));
			} : sub() {
				return ($_[0] =~ $__vre ? "" : ( $_[1] ? $_[1] : "Does not match required pattern"));
			};
		} elsif ($validation =~ m/^(!)?\[([^,]+(,[^,]+)*)\]$/) {
			my @__vlist = split(",", $2);
			my $__negate = ($1 && $1 eq "!");
			$validate =  sub() {
				my $needle=shift;
				my @matches = grep {$_ eq $needle} @__vlist;
				return $__negate ?
					(scalar(@matches) == 0 ? "" : ($_[1] ? $_[1] : "Cannot be one of ".join(", ",@__vlist))):
					(scalar(@matches) != 0 ? "" : ($_[1] ? $_[1] : "Expecting one of ".join(", ",@__vlist)));
			}
		} elsif ($validation =~ m/^((^|,)[^,]+){2,}$/) { # Deprecated list match 2 or more
			my @__vlist = split(",", $validation);
			$validate = sub() {
				my $needle=shift;
				my @matches = grep {$_ eq $needle} @__vlist;
				return (scalar(@matches) != 0 ? "" : ($_[1] ? $_[1] : "Expecting one of ".join(", ",@__vlist)));
			}
		} elsif ($validation eq "vault_path") {
			$validate = sub() {
				return "" unless vaulted();
				return (safe_path_exists $_[0]) ? "" : ($_[1] ? $_[1] :"$_[0] not found in vault");
			}
		} elsif ($validation eq "vault_path_and_key") {
			$validate = sub() {
				# Revisit this when https://github.com/starkandwayne/safe/issues/121 is resolved; for
				# now, assume there can only be one colon separating the path from the key.
				return "$_[0] is missing a key - expecting <path>:<key>" unless $_[0] =~ qr(^[^:]+:[^:]+$);
				return "" unless vaulted();
				return (safe_path_exists $_[0]) ? "" : ($_[1] ? $_[1] :"$_[0] not found in vault");
			}
		}
	}

	while (1) {
		print STDERR csprintf("%s", $prompt);
		chomp (my $in=<STDIN>);
		if ($in eq "" && defined($default)) {
			$in = $default;
			print STDERR (csprintf("\033[1A%s#C{%s}\n",$prompt, $in));
		}
		$in =~ s/^\s+|\s+$//g;

		return "" if ($in eq "" && $allow_blank);
		my $err="";
		if ($in eq "") {
			$err= "#R{No default:} you must specify a non-empty string";
		} else {
			$err = &$validate($in,$err_msg) if defined($validate);
			$err = "#r{Invalid:} $err" if $err;
		}

		no warnings "numeric";
		return (($in eq $in + 0) ? $in + 0 : $in) unless $err; # detaint numbers
		use warnings "numeric";
		error($err);
	}
}

sub __prompt_for_block {
	my ($prompt) = @_;
	$prompt = "$prompt (Enter <CTRL-D> to end)";
	(my $line = $prompt) =~ s/./-/g;
	print csprintf("%s","\n$prompt\n$line\n");
	my $in;
	open($in, '<&', fileno(STDIN)) or $in = \*STDIN;
	my @data = <$in>;
	return join("", @data);
}

sub prompt_for_boolean {
	my ($prompt,$default,$invert) = @_;
	my ($t,$f) = (JSON::PP::true,JSON::PP::false);

	my $true_re = qr/^(?:y(?:es)?|t(rue)?)$/i;
	my $false_re =  qr/^(?:no?|f(alse)?)$/i;
	my $val_prompt = "[y|n]";
	if (defined $default) {
		$default = $default ? "y" : "n" if $default =~ m/^[01]$/; # standardize
		$val_prompt = $default =~ $true_re ? "[#g{Y}|n]" : "[y|#g{N}]";
	}
	chomp $prompt;
	if ($prompt =~ /\[y\|n\]/) {
		# Allow a single line boolean prompt
		$prompt =~ s/\[y\|n\]/$val_prompt/;
		$val_prompt = $prompt;
		print STDERR "\n";
	} else {
		print STDERR csprintf("%s","\n$prompt\n");
	}
	while (1) {
		my $answer = __prompt_for_line($val_prompt,undef,undef,$default,'allow_blank');
		return ($invert ? $f : $t) if $answer =~ $true_re;
		return ($invert ? $t : $f) if $answer =~ $false_re;
		error "#r{Invalid response:} you must specify y, yes, true, n, no or false";
	}
}
sub prompt_for_choices {
	my ($prompt, $choices, $min, $max, $labels, $err_msg) = @_;

	my %chosen;
	$labels ||= [];
	my $num_choices = scalar(@{$choices});
	for my $i (0 .. $#$choices) {
		$labels->[$i] ||= $choices->[$i];
		$prompt .= "\n  ".($i+1).") ".(ref($labels->[$i]) eq "ARRAY" ? $labels->[$i][0] : $labels->[$i]);
	}
	my $line_prompt = "choice";
	$min ||= 0;
	$max ||= $num_choices;
	die "Illegal list maximum count specified. Please contact your kit author for a fix.\n"
		if $max < $min;

	print csprintf($prompt."\n\nMake your selections (leave $line_prompt empty to end):\n");

	my @ll;
	while (1) {
		my $v = __prompt_for_line(
			ordify(scalar(@ll) + 1) . $line_prompt,
			"1-$num_choices",
			$err_msg || "Invalid choice - enter a number between 1 and $max",
			undef,
			'allow_blank'
		);
		if ($chosen{$v}) {
			error "#r{ERROR:} ".$choices->[$v-1]." already selected - choose another value";
			next;
		}
		if ($v eq "") {
			if (scalar(@ll) < $min) {
				error "#r{ERROR:} Insufficient items provided - at least $min required.";
				next;
			}
			last;
		}
		push @ll, $choices->[$v-1];
		$chosen{$v} = 1;
		print(csprintf("\033[1A%s%s > #C{%s}\n",ordify(scalar(@ll)), $line_prompt, (ref($labels->[$v-1]) eq "ARRAY" ? $labels->[$v-1][1] : $labels->[$v-1])));
		last if scalar(@ll) == $max;
	}
	return \@ll;

}

# This is a wrapper around prompt_for_choice that allows for multiple selections
# to be made.  It will return an arrayref of the selected choices.
# The $min and $max parameters are optional, and will default to 0 and the
# number of choices, respectively.
# The $labels parameter is also optional, and will default to the choices
# themselves.  The labels has to be an array ref, composed of elements that
# are either strings or array refs.  If the element is an array ref, the first
# element is the label displayed in the choice list, and the second element is
# the label displayed on the selecdtion lineafter the user has entered a value.
# If the label matches the pattern "---(.*)---", it will be treated as a
# section header, and will be displayed as such, without a selection number.
# The $err_msg parameter is optional, and will default to a generic error
# message.
# The $object_description parameter is optional, and will default to "choice".
#
sub prompt_for_choice {
	my ($prompt, $choices, $default, $labels, $err_msg, $object_description) = @_;

	my $default_choice;
	my $object = $object_description//"choice";
	my $num_choices = scalar(@{$choices});
	print csprintf("%s","\n$prompt");
	my $iw = length($#$choices + 1);
	my $section_offset = 0;
	my %selection_map=();
	for my $i (0 .. $#$choices) {
		my $label;
		while (1) {
			my $idx = $i + $section_offset;
			($label,my $selected) = (ref($labels) eq 'ARRAY' && $labels->[$idx])
				? (ref($labels->[$idx]) eq 'ARRAY'
					? @{$labels->[$idx]}
					: ($labels->[$idx],$labels->[$idx]))
				: ($choices->[$i],$choices->[$i]);

			if ($label =~ /^---(.*)---$/) {
				my $section_header = $1;
				$section_offset += 1;
				print csprintf("\n\n  %s", $section_header);
				next;
			} elsif ($label eq '---') {
				my $section_header = '';
				$section_offset += 1;
				print csprintf("\n");
				next;
			}
			$selection_map{$i} = $selected;
			last;
		}
		print csprintf("\n  %*s) %s", $iw, ($i+1), $label);
		if ($default && $default eq $choices->[$i]) {
			print csprintf(" #G{(default)}");
			$default_choice = $i+1;
		}
	}
	print "\n\n";
	my $c = __prompt_for_line(
		"Select $object",
		"1-$num_choices",
		$err_msg || "enter a number between 1 and $num_choices",
		$default_choice);

	print(csprintf("\033[1ASelect $object > #C{%s}\n", $selection_map{$c-1}));
	return $choices->[$c-1];
}

sub prompt_for_line {
	my ($prompt,$label,$default,$validation,$err_msg) = @_;
	if ($prompt) {
		print csprintf("%s","\n$prompt");
		my $padding = ($prompt =~ /\s$/) ? "" : " ";
		print(csprintf("%s", "${padding}#g{(default: $default)}")) if (defined($default) && $default ne '');
	} elsif (defined($default) && defined($label) && $default ne '') {
		my $padding = ($label =~ /\s$/) ? "" : " ";
		$label .= csprintf("%s", "${padding}#g{(default: $default)}");
	}
	print "\n";
	my $allow_blank = (defined($default) && $default eq "");
	return __prompt_for_line(defined($label) ? $label : "", $validation, $err_msg, $default, $allow_blank);
}

sub prompt_for_list {
	my ($type,$prompt,$label,$min,$max,$validation, $err_msg, $end_prompt) = @_;
	$label ||= "value";
	$min ||= 0;
	$end_prompt = "(leave $label empty to end)" unless defined($end_prompt);
	die "Illegal list maximum count specified. Please contact your kit author for a fix.\n"
		if (defined($max) and $max < 1);

	print csprintf("\n%s %s\n", $prompt, $end_prompt);

	my @ll;
	while (1) {
		my $v;
		if ($type eq 'line') {
			$v = __prompt_for_line(ordify(scalar(@ll) + 1) . $label, $validation, $err_msg, undef, 'allow_blank');
		} else {
			$v = __prompt_for_block(ordify(scalar(@ll) + 1) . $label);
		}
		if ($v eq "") {
			if (scalar(@ll) < $min) {
				error "#r{ERROR:} Insufficient items provided - at least $min required.";
				next;
			}
			last;
		}
		push @ll, $v;
		last if (defined($max) && scalar(@ll) == $max);
	}
	return \@ll;
}

sub prompt_for_block {
	printf("\n");
	return __prompt_for_block(@_);
}

# prompt_for_choice - Allows selecting a single option from a list of choices
#
# This function can be called in two ways:
#
# 1. Traditional (backwards compatibility):
#    prompt_for_choice($prompt, $choices, $default, $labels, $err_msg, $object_description)
#
# 2. Options-based:
#    prompt_for_choice(
#       header => "Header text",            # Prompt text displayed above choices
#       choices => $choices,                # Array of choices (strings or hashrefs)
#                                           # If hashrefs, expected keys:
#                                           #  - value: The return value (required, unless separator/section)
#                                           #  - label: Display text in menu (will use value if not provided)
#                                           #  - summary: Text displayed after selection (will use label if not provided)
#                                           #  - section: Section header (string - optional)
#                                           #  - separator: Separator line (boolean - optional)
#       default => $default,                # Default choice (value or index)
#       error => "Custom error message",    # Error message on invalid input
#       description => "item",              # Object type in prompt (default: "choice")
#       compact => 1,                       # Display choices in columns (default: 0)
#       paginate => 1,                      # Enable pagination with N/P commands (default: 0)
#       none => 1,                          # Allow no selection (default: 0)
#     )
#
sub new_prompt_for_choice {
	my %options = ();
	my @valid_options = qw(
		header choices default error description compact paginate
	);
	
	# Handle backward compatibility - the first argument must be one of the valid options
	# because we are expecting a hash (not a hashref)
	if (!grep {ref($_[0]) eq $_} @valid_options && ref($_[1]) eq 'ARRAY') {
		# Backwards compatibility mode
		%options = __process_legacy_prompt_for_choice_args(@_);
	} else {
		my $raw_opts = {@_};
		%options = delete($raw_opts->%{@valid_options});
		bug(
			"Invalid options passed to prompt_for_choice: %s", join(", ", keys %$raw_opts)
		) if keys %$raw_opts; # TODO: Should this be a bug report?

		# Convert choices to hashrefs if they are not already
		$options{choices} = [map {ref($_) eq 'HASH' ? $_ : {value => $_}} $options{choices}->@*];
	}
	
	# Ensure we have required parameters
	my $choices = $options{choices};
	bug("prompt_for_choice requires 'choices' parameter and it must be an arrayref") 
		unless $choices && ref($choices) eq 'ARRAY';
	
	# Set defaults for missing parameters
	$options{description} //= "choice";
	$options{header} //= sprintf("Select one of the following %s:", count_nouns(2, $options{description}, suppress_count => 1));
	$options{compact} //= 0;
	bug("prompt_for_choice compact mode is not yet implemented")
		if $options{compact};
	$options{paginate} //= 0;
	
	# Deal with default choice
	my $num_choices = scalar(@$choices);
	my $iw = length($num_choices); # max item width
	my $default_idx = undef;
	if (defined $options{default}) {
		$default_idx = $options{default} =~ m/^\d+$/
			? ($options{default} > 0 ? $options{default} : $num_choices + $options{default})
			: (grep {$choices->[$_]->{value} eq $options{default}} 0 .. $num_choices - 1)[0];
		if (defined $default_idx) {
			$choices->[$default_idx]{label} //= $choices->[$default_idx]{value};
			$choices->[$default_idx]{summary} //= $choices->[$default_idx]{label};
			$choices->[$default_idx]{label} .= " #G{(default)}";

		} else {
			bug("Invalid default choice: %s", $options{default});
		}
	}

	# Handle compact display
	# The option numbers need to go down then across, so we need to figure out how many we can get across
	# the screen.  We will use the longest label to determine how many we can fit.
	my $columns = 1;
	my $col_width = terminal_width() - 4; # 2 character padding on each side
	my @section_headers = ('');
	my $sections = {'' => []};
	if ($options{compact}) {
		my $max_label_len = 0;
		my $max_number_width = length($num_choices) + 2; #  "..#) ";
		my $max_width = terminal_width - 4; # 2 character padding on each side
		for my $choice (@$choices) {
			# Deal with section headers or separators
			# If section changes, then we need separate by sections
			if ($choice->{section}) {
				push @section_headers, $choice->{section};
				next;
			} elsif ($choice->{separator}) {
				push @section_headers, sprintf("---%s---", scalar(@section_headers)+1);
				next;
			}
			my $label = $choice->{label} // $choice->{value};
			$max_label_len = max($max_label_len, length($label)+ $max_number_width + 2); # 2 for column separator 
			push @{$sections->{$section_headers[-1] //= []}}, $choice;
		}
		$columns = int($max_width / $max_label_len);
		$col_width = int($max_width / $columns);
	}

	# Handle pagination
	# FIXME: skip for now - adding column support should be enough to reduce
	# the number of rows needed to display the choices.
	#
	# Once pagination is supported, we will reserve the first N rows + 1 for the
	# header, where N is the number of rows the header takes up, and the last
	# three rows for the footer.  The rest of the rows will be used for the
	# choices, and the number of rows will determine the pages required, as well
	# as the actual number of choices per column.  Without paginate option, we 
	# will treat the terminal as infinite size, and just display the choices
	# in the order they are given.
	#
	# Also have to deal with section headers and separators -- do we want to
	# support "Section header (continued)" or "Section header (continued 1/2)",
	# or keep separate pages for each section (if they fit on the page)?
	my $current_page = 0;
	my $page_size = 0; #$options{paginate} ? terminal_height : 0;
	my $total_pages = 1; #$options{paginate} ?  POSIX::ceil(($num_choices - 1) / $options{page_size}) : 1;

	# Display header
	my $form = $options{header}."\n";
	my %selection_map;
	my $default_choice;
	# Handle user input
	my $display_choices = sub {
		my $section_offset = 0;
		%selection_map = ();
		$default_choice = undef;

		for my $section_header (@section_headers) {
			if ($section_header) {
				if ($section_header =~ /^---\d+---$/) {
					# blank line separator
					$form .= "\n";
				} else {
					# section header
					$form .= csprintf("\n  #Wku{%s}\n", $section_header);
				}
			}
			my $section_choices = $sections->{$section_header};
		};
		
		# Calculate item ranges for pagination
		my ($start_idx, $end_idx) = (0, $num_choices - 1);
		if ($options{paginate}) {
			$start_idx = $current_page * $options{page_size};
			$end_idx = min($start_idx + $options{page_size} - 1, $num_choices - 1);
		}
		
		if ($options{compact}) {
			# Find the longest label for proper column calculation
			my $max_label_len = 0;
			for my $i ($start_idx .. $end_idx) {
				my $label = $choices->[$i]->{label} //= $choices->[$i]->{value};
				next if $label =~ /^---.*---$/;  # Skip section headers
				$max_label_len = max($max_label_len, length($label) + $iw + 4); # num) label
			}
			
			# Calculate number of columns that fit
			my $cols = max(1, int(terminal_width() / ($max_label_len + 2)));
			
			# Display items in columns
			my $col = 0;
			for my $i ($start_idx .. $end_idx) {
				my $label = $choices->[$i]->{label};
				my $value = $choices->[$i]->{value};
				
				# Handle section headers
				if ($label =~ /^---(.*)---$/) {
					my $section_header = $1;
					$section_offset += 1;
					$form .= csprintf("\n\n  %s", $section_header);
					$col = 0;
					next;
				} elsif ($label eq '---') {
					my $section_header = '';
					$section_offset += 1;
					$form .= csprintf("\n");
					$col = 0;
					next;
				}
				
				$selection_map{$i} = $choices->[$i]->{summary} && bug(
					"prompt_for_choice: selection_map needs fixing in compact mode: see traditional mode for details"
				);
				
				# Format the choice with number and optional default marker
				my $choice_text = sprintf("%*s) %s", $iw, ($i+1), $label);
				if (defined $options{default} && 
					(($options{default} eq $value) || 
					 ($options{default} == $i+1))) {
					$choice_text .= csprintf(" #G{(default)}");
					$default_choice = $i+1 && bug(
						"prompt_for_choice: default_choice needs fixing in compact mode: see traditional mode for details"
					);
				}
				
				# Start a new line if we're at the beginning of a row
				$form .= "\n  " if $col == 0;
				
				# Print the choice with proper padding
				$form .= sprintf("%-*s", $max_label_len, $choice_text);
				
				# Update column counter
				$col = ($col + 1) % $cols;
			}
		} else {
			# Traditional vertical display
			my $choice_map = {};
			for my $i ($start_idx .. $end_idx) {
				$choices->[$i]{label} //= $choices->[$i]{value};

				# Handle separator and section headers
				if ($choices->[$i]->{separator} || $choices->[$i]->{label} eq '---') {
					$section_offset += 1;
					$form .= "\n";
					next;
				}
				if ($choices->[$i]->{section} || $choices->[$i]->{label} =~ /^---(.*)---$/) {
					my $section = $choices->[$i]->{section} || $1;
					$section_offset += 1;
					$form .= csprintf("\n\n  #Wku{%s}\n", $choices->[$i]->{section});
					next;
				}

				my $choice = $i+1-$section_offset;
				$selection_map{$choice} = $choices->[$i];
				$form .= csprintf("\n  %*s) %s", $iw, $choice, $choices->[$i]{label});
				$default_choice = $choice if defined($default_idx) && $i == $default_idx;
			}
		}
		
		# Add pagination footer if enabled
		if ($options{paginate} && $total_pages > 1) {
			$form .= csprintf("\n\n  Page %d of %d [N)ext P)revious]", 
				$current_page + 1, $total_pages);
		}
		
		info("\n%s\n",$form);
		return \%selection_map;
	};
	
	# Helper function to get max value
	sub max {
		my ($a, $b) = @_;
		return $a > $b ? $a : $b;
	}
	
	# Helper function to get min value
	sub min {
		my ($a, $b) = @_;
		return $a < $b ? $a : $b;
	}
	
	# Display choices and get selection
	while (1) {
		my $selection_map = $display_choices->();
		
		my $validation = "1-$num_choices";
		if ($options{paginate}) {
			$validation = qr/^(?:[1-9][0-9]*|[nNpP])$/;
		}
		
		my $c = __prompt_for_line(
			"Select $options{description}",
			$validation,
			$options{error} || "Enter a number between 1 and $num_choices" . 
				($options{paginate} ? ", or N/P for pagination" : ""),
			$default_choice
		);

		# Handle pagination commands
		if ($options{paginate} && $c =~ /^[nNpP]$/i) {
			if ($c =~ /^[nN]$/i) {
				$current_page = ($current_page + 1) % $total_pages;
			} else {
				$current_page = ($current_page + $total_pages - 1) % $total_pages;
			}
			next;
		}
		
		# Convert input to integer for consistency
		$c = int($c);
		
		# Return the selected choice
		my $selection_summary = $selection_map->{$c}{summary} // $selection_map->{$c}{label};
		info("\e[1ASelect %s > #C{%s}\n", $options{description}, $selection_summary);
		return $selection_map->{$c}{value};
	}
}

sub __process_legacy_prompt_for_choice_args {
	my ($prompt, $old_choices, $old_default, $labels, $err_msg, $object_description) = @_;
	
	# Convert traditional arguments to options hash
	my %options = (
		header => $prompt,
		default => $old_default,
		error => $err_msg,
		description => $object_description
	);
	
	# Convert old choices and labels format to new choices format
	my $choices = [];
	my $label_offset = 0;
	for my $i (0 .. $#{$old_choices}) {
		my $choice = {
			value => $old_choices->[$i],
		};
		
		# Handle labels if provided
		if (ref($labels) eq 'ARRAY' && defined $labels->[$i]) {
			my ($label, $summary) = (ref($labels->[$i]) eq 'ARRAY')
				? @{$labels->[$i]}
				: ($labels->[$i]);
			if ($label =~ /^---(.*)---$/) {
				push @$choices, {section => $1};
				$label_offset += 1;
				redo;
			} elsif ($label eq '---') {
				push @$choices, {separator => 1};
				$label_offset += 1;
				redo;
			}
			$choice->{label} = $label;
			$choice->{summary} = $summary if defined $summary;
		}
		push @$choices, $choice;
	}
	$options{choices} = $choices;
	return %options;
}
1;
