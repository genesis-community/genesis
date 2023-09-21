package Genesis::UI;

use base 'Exporter';
our @EXPORT = qw/
	prompt_for_boolean
	prompt_for_choices
	prompt_for_choice
	prompt_for_line
	prompt_for_list
	prompt_for_block
/;

use Genesis;
use Genesis::Term;

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
		print csprintf("%s", $prompt);
		chomp (my $in=<STDIN>);
		if ($in eq "" && defined($default)) {
			$in = $default;
			print(csprintf("\033[1A%s#C{%s}\n",$prompt, $in));
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
	my @data = <STDIN>;
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
		print "\n";
	} else {
		print csprintf("%s","\n$prompt\n");
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
sub prompt_for_choice {
	my ($prompt, $choices, $default, $labels, $err_msg) = @_;

	my $default_choice;
	my $num_choices = scalar(@{$choices});
	print csprintf("%s","\n$prompt");
	for my $i (0 .. $#$choices) {
		my $label = (ref($labels) eq 'ARRAY' && $labels->[$i]) ? (ref($labels->[$i]) eq 'ARRAY' ? $labels->[$i][0] : $labels->[$i]) : $choices->[$i];
		print csprintf("%s","\n  ".($i+1).") ".$label);
		if ($default && $default eq $choices->[$i]) {
			print csprintf(" #G{(default)}");
			$default_choice = $i+1;
		}
	}
	print "\n\n";
	my $c = __prompt_for_line(
		"Select choice",
		"1-$num_choices",
		$err_msg || "enter a number between 1 and $num_choices",
		$default_choice);

	print(csprintf("\033[1ASelect choice > #C{%s}\n", (ref($labels) eq 'ARRAY' &&  $labels->[$c-1]) ? (ref($labels->[$c-1]) eq 'ARRAY' ? $labels->[$c-1][1] : $labels->[$c-1]) : $choices->[$c-1]));
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



1;

=head1 NAME

Genesis::UI

=head1 DESCRIPTION

This module provides utilities for the text user interfaces used by C<Genesis>
and its C<hooks/*> scripts.

=head1 FUNCTIONS

=head2 prompt_for_boolean($prompt,$default,$invert);

Provides the user with the given C<$prompt> on one line, then a `[y|n] >`
prompt on the following line.  If the given prompt contains `[y|n]` in it,
then just the given prompt will be diplayed on a single line.

Whether provided or appended, the [y|n] will be modified to make the default
value capitalized and colored green, if a default was given.

It will accept yes, no, true, or false as valid input, or just the initial
characters of each, and case is ignored.

If the C<$invert> flag is true, it will return the inverted value of the
response given.  This is useful when the question is easier to pose in the
positive, but is stored in the negative.

Reads the contents of C<$path>, interprets it as YAML, and parses it into a
Perl hashref structure.  This leverages C<spruce>, so it can only be used on
YAML documents with top-level maps.  In practice, this limitation is hardly
a problem.

=head2 prompt_for_choices($prompt, $choices, $min, $max, $labels, $err_msg)

Provides the user with a numerical list of choices to choose from, a preample
prompt above it and accepts a variable number of selections.  The user will
select the number corresponding to their desired choices, and enter a blank
line when they're finished (or it will auto-conclude if the maximum number of
selections has been reached).

Required arguments are the prompt and a reference to a list of choices that
can be chosen.  By default, the labels for the choices will the same as the
value of the choices, the minimum selection is 0 and the maximum is all of
them.

If your C<$choices> are not strings, or if you want to provide the user with
more human-friendly representation (colors, additional details, etc), you can
provide alternative label strings for each choice in C<$labels>, associated by
corresponding index number.  Furthermore, you can provide each label as an
array of two labels: first one is the one displayed on the choice list, and
the second one is what gets displayed on the select line after the user has
entered a value.  This is useful for when you are displaying complex strings
(ie tabular data) that you don't want displayed on the select line.

Specifying C<$min> and or C<$max> can allow you to present choices for
scenarios such as optionally picking one of a selection ($max = 1), or
choosing at least one but allowing for additional selection ($min = 1).

By default, if you choose an invalid value, a generic message of "Invalid
choice - enter a number between 1 and $max" will be displayed.  You can
customize this by providing C<$err_msg>.

=head2 prompt_for_choice($prompt, $choices, $default, $labels, $err_msg)

Similar to C<prompt_for_choices>, but limited to a single choice.  For that
trade-off, it gains the ability to specify a default value on the user
entering a blank choice.

If your C<$choices> are not strings, or if you want to provide the user with
more human-friendly representation (colors, additional details, etc), you can
provide alternative label strings for each choice in C<$labels>, associated by
corresponding index number.  Furthermore, you can provide each label as an
array of two labels: first one is the one displayed on the choice list, and
the second one is what gets displayed on the select line after the user has
entered a value.  This is useful for when you are displaying complex strings
(ie tabular data) that you don't want displayed on the select line.

The C<$default> value is specified as the choice, not the label, so if you're
specifying alternative labels, be wary of that distinction.  The label of the
default will have a green '(default)' appended to it.

=head2 prompt_for_line($prompt,$label,$default,$validation,$err_msg)

Provides a way to prompt your users for a line can can be validated before
returning an acceptable value, reprompting on error.

The output text is comprised of the C<$prompt> and the C<$label> contents.
The prompt is printed once at the top, but the label is printed inline at each
user entry.  This allows you to facilitate either a large explanatory prompt
with a simple '> ' on the user entry line (C<$label> is C<undef>), or a short
prompt that is repeated each time (C<$prompt> is C<undef>).

If a default value is desired, it will be returned if the user enters a blank
line.  The default will be displayed to the user at the end of the prompt if
one was given, or otherwise at the end of the label if it was given.  The user
entering a blank line would be reprompted to enter a value if C<$default> is
undefined. If default is empty string, the default prompt will not be
displayed, but will allow an empty response as valid.

The most powerful aspect of this function is the ability to validate the input
against several known formats:

=over

=item C<ip>

Ensures that the entry is a valid IP address: 4-octets between 0-255,
non-zero-padded joined by periods.

=item C<url>

Ensures that the entry is a valid URL.

=item C<port>

Ensures that the entry is a numeric value between 0 and 65535.
Deprecated: use bounded numeric value validation of "0-65535".

=item bounded numeric value

Ensures that the entry is numeric and falls under optional bounded ranges:
"n-m": value must be between n and m
"n+":  value must be n or greater

n and m can either be integer or floating-point values and can be positive or
negative.

=item regular expression

Ensures that the entry matches (or doesn't match) a given regular expression.
This uses a string format of a perl-style regular expression, and supports
C<i>, C<m> and C<s> flags.  To indicate exclusion of match, prefix with a
C<!>.  For example, "!/(apple|orange)s?/i" would exclude any value that
contains singular or plural apples and oranges.

=item explicit list

Ensures that the entry is (or isn't) in a list of known values.  This takes
the form of a comma-separated list of values, enclosed in brackets, with an
optional C<!> in front to negate (similar to regular expression validation
above).

Examples:

"[fire,earth,air,water]"          - only allow classic Grecian elements
"![password,123456,qwerty,admin]" - don't allow the worst passwords

=item C<vault_path>

Ensure that the entry is a valid vault path.

=item C<vault_path_and_key>

Ensure that the entry is a valid vault path and that the key exists under that
path.

=item code

This is the last resort and should only be used if another validation type
cannot be.  Unlike the others that are all strings, you can actually pass in a
function ref to be run against the entry to check if it's valid.  The function
takes the value as the first argument, and an optional error message as the
second argument.

The reason that code is not preferred even though it is much more flexable is
that the primary source of the validation is being passed in by data file or
bash script calls, so in those cases it is not viable.

=back

=head2 prompt_for_block($prompt)

Prompts user to enter a block of text that may contain numerous newlines.
Entry is completed by pressing C<Ctrl-D>. (This information is appended to the
end of the prompt).

=head2 prompt_for_list($type,$prompt,$label,$min,$max,$validation, $err_msg, $end_prompt)

This is basically a wrapper for C<prompt_for_line> for collecting multiple
entries, with support for specifying C<$min> and C<$max> entry counts.

The entry C<$type> can be either 'line', or 'block' -- see above for details
on those prompt_for_* functionality. Lists are completed either automatically
when the max entries are met, or by the user entering a blank line for
line-type lists, or by entering C<Ctrl-D> in an empty block in block-type
lists.  (This information is provided to the user at the end of each label).

Validation is only applicable to line-type lists, and uses the same validation
as C<prompt_for_line>.

=head2 bullet([type,] msg, [%options])

Provides a bulleted or checkbox line item

Called with just a message, this will result in a the message being indented
by two spaces, a bullet character and another space.

The build-in bullet types are good and bad, which changes the bullet to a
green checkbox or a red X respectively.  There is also an empty type, but this
is only used with the box option (see below).

Advanced funtionality provided through an option hash allows the user to
over-ride the color, symbol, indention level and conversion to a checkbox.

Options:

=over

=item symbol

Specify the symbol to use for the bullet. Defaults to unicode C<2022> (bullet), but automaticaly switches to C<2714> (check) and a space for C<good> type, C<2718> (X) and a space for C<bad> type, and two spaces for C<empty> type.

=item color

Specify the color for the bullet -- uses C<csprintf> color codes.  Defaults to green for C<good> type and red for C<bad> type, unspecified for anything else.

=item indent

Specify the number of characters to indent the line.  Defaults to 2

=item box

Set to true to place a [  ] around the symbol - used to represent checkbox bullets

=back

=cut
