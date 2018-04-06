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
				return "$_[0] is missing a key - expecting secret/<path>:<key>" unless $_[0] =~ qr(^[^:]+:[^:]+$);
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
			return "" if $allow_blank;
			$err= "#R{No default:} you must specify a non-empty string";
		} else {
			$err = &$validate($in,$err_msg) if defined($validate);
			$err = "#r{Invalid:} $err" if $err;
		}

		no warnings "numeric";
		return (($in eq $in + 0) ? $in + 0 : $in) unless $err;
		use warnings "numeric";
		error($err);
	}
}

sub __prompt_for_block {
	my ($prompt) = @_;
	$prompt = "$prompt (Enter <CTRL-D> to end)";
	(my $line = $prompt) =~ s/./-/g;
	print "\n$prompt\n$line\n";
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
		print "\n$prompt\n";
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
		$prompt .= "\n  ".($i+1).") ".$labels->[$i];
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
		print(csprintf("\033[1A%s%s > #C{%s}\n",ordify(scalar(@ll)), $line_prompt, $labels->[$v-1]));
		last if scalar(@ll) == $max;
	}
	return \@ll;

}
sub prompt_for_choice {
	my ($prompt, $choices, $default, $labels, $err_msg) = @_;

	my $default_choice;
	my $num_choices = scalar(@{$choices});
	print "\n$prompt";
	for my $i (0 .. $#$choices) {
		my $label = (ref($labels) eq 'ARRAY' &&  $labels->[$i]) ? $labels->[$i] : $choices->[$i];
		print "\n  ".($i+1).") ".$label;
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

	print(csprintf("\033[1ASelect choice > #C{%s}\n", (ref($labels) eq 'ARRAY' &&  $labels->[$c-1]) ? $labels->[$c-1] : $choices->[$c-1]));
	return $choices->[$c-1];
}

sub prompt_for_line {
	my ($prompt,$label,$default,$validation,$err_msg) = @_;
	if ($prompt) {
		print "\n$prompt";
		my $padding = ($prompt =~ /\s$/) ? "" : " ";
		print(csprintf("%s", "${padding}#g{(default: $default)}")) if defined($default);
	} elsif (defined($default) && defined($label)) {
		my $padding = ($label =~ /\s$/) ? "" : " ";
		$label .= csprintf("%s", "${padding}#g{(default: $default)}");
	}
	print "\n";
	return __prompt_for_line(defined($label) ? $label : "", $validation, $err_msg, $default);
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
