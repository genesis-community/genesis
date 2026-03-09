package Boolean;
use v5.20;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use overload
    '!'    => sub { return $_[0]->_invert() },
    'bool' => sub { return ${$_[0]} },
    "0+"   => sub { return $_[0]->to_i() },
    '""'   => sub { return $_[0]->to_str() },
    'eq'   => sub { return $_[0]->_compare($_[1],1) },
    '=='   => sub { return $_[0]->_compare($_[1]) },
    'ne'   => sub { return !$_[0]->_compare($_[1],1) },
    '!='   => sub { return !$_[0]->_compare($_[1]) },
		fallback => 1;

# Uses read-only singletons for maximum efficiency and safety
our ($TRUE, $FALSE);
{
    my $true_val  = 1;
    my $false_val = 0;

    # Bless the references FIRST
    $TRUE  = bless \$true_val, __PACKAGE__;
    $FALSE = bless \$false_val, __PACKAGE__;

    # THEN make the scalar values read-only
    Internals::SvREADONLY($true_val, 1);
    Internals::SvREADONLY($false_val, 1);
}

### Class methods
# true/false - create the base boolean objects {{{
sub true  { return $TRUE; }
sub false { return $FALSE; }

# }}}
# of - create a Boolean object from a given value {{{
sub of {
	my ($class,$value) = _process_class_args(@_);
	my $ref = ref($value);
	return $value if $ref eq 'Boolean';

	# Array and hash refs return true if they have contents, false if empty
	if ($ref eq 'ARRAY') {
		$value = @$value ? 1 : 0;
	} elsif ($ref eq 'HASH') {
		$value = scalar(keys %$value) ? 1 : 0;

	# If it doesn't override bool, try checking if it supports these methods
	} elsif (!overload::Method($value, 'bool')) {

		# Check for common methods that return boolean-like values
		my @methods = qw/
			true !false !empty !blank count size length
			is_true !is_false !is_empty !is_blank
		/;
		foreach my $method (@methods) {
			my $invert = $method =~ s/^!//;
			next unless eval {$value->can($method)};
			$value = $value->$method();
			$value = !$value if $invert;
			last;
		}
	}
	return $value ? $class->true : $class->false;
}

# }}}
# parse - parse a value into a Boolean object {{{
sub parse {
	my ($class, @args) = _process_class_args(@_);
	die 'invalid call to Boolean::parse - only one argument allowed'
		if @args != 1;

	my $value = shift @args;

	return $class->of($value) if ref($value);
	return $class->false unless defined $value && length($value);

	if ($value =~ /^-?\d+(?:\.\d+)?$/) {
		# Numeric values: 0 is false, everything else is true
		return $value+0 ? $class->true : $class->false;
	}

	# Assume its a string...
	my ($truthy, $falsy, $is_true) = _find_boolean_pairing($value);
	return $is_true ? $class->true : $class->false if defined $truthy;
	return undef; # Technically a falsy value, but not a Boolean object, so it can be differentiated by caller
}

# }}}
# register_pair - register a custom true/false pair {{{
sub register_pair {
	my ($class, @args) = _process_class_args(@_);
	# Validate arguments
	die 'Invalid call to Boolean::register_pair - must provide two strings of non-zero length'
		unless @args == 2;

	my ($true_val, $false_val) = @args;
	die 'Invalid true value - must be a non-empty string or an object that provides a string value'
		unless defined $true_val && (!ref($true_val) || overload::Method($true_val, '""')) && length("$true_val");
	die 'Invalid false value - must be a non-empty string or an object that provides a string value'
		unless defined $false_val && (!ref($false_val) || overload::Method($false_val, '""')) && length("$false_val");

	my $_pairs = $class->_get_pairs_ref;
	$_pairs->{lc("$true_val")} = lc("$false_val");
	return 1;
}

# }}}

### Instance methods
# to_i - convert Boolean to integer representation {{{
sub to_i($self) {
	return ${$self} ? 1 : 0;
}

# }}}
# to_str - convert Boolean to string representation {{{
sub to_str($self, $tvalue='true', $fvalue=undef) {
	# Short circuit if default values are used
	return $tvalue if ${$self};
	if ($tvalue eq 'true' && ($fvalue//'false') eq 'false') {
		return 'false';
	}

	# If no false value provided, derive it from the true value
	if (!defined($fvalue)) {
		my (undef, $false_val) = _find_boolean_pairing($tvalue);
		$fvalue = $false_val if defined $false_val;
	}
	return $fvalue//'false';
}

# }}}
# to_json - convert Boolean to JSON::PP::Boolean representation {{{
sub to_json($self) {
	require JSON::PP;
	return ${$self} ? JSON::PP->true() : JSON::PP->false();
}
# }}}

# Internal functions and methods
# _process_class_args - process class and arguments for methods {{{
sub _process_class_args {
	if ($_[0] eq __PACKAGE__) {
		return @_;
	} else {
		return (__PACKAGE__, @_);
	}
}

# }}}
# _find_boolean_pairing - find a registered boolean pair {{{
sub _find_boolean_pairing($value) {
	# Default pairs (kept compact)
	my $pairs = __PACKAGE__->_get_pairs_ref;
	my $search = lc($value);
	my ($key) = grep { $_ eq $search || $pairs->{$_} eq $search} keys %$pairs;
	return unless $key;

	# Preserve the case of the original value
	my $true_val = _preserve_case($value, $key);
	my $false_val = _preserve_case($value, $pairs->{$key});

	# Return the true value, false value, and if the given value was the true value.
	return ($true_val, $false_val, ($key eq $search))
}

# }}}
# _get_pairs_ref - get the reference to the pairs hash {{{
sub _get_pairs_ref {
	# Use a package variable to store pairs, allowing for easy registration.
	# The key is the true value in lowercase, and the value is the corresponding false value.
	# This allows for case-insensitive matching and preserves the original case in the output.
	our $_pairs //= {
		qw(
			y n yes no on off t f true false
			ok error good bad pass fail up down hi lo high low
			start stop open closed enable disable enabled disabled
			active inactive show hide shown hidden verbose quiet
		)
	};
	return $_pairs;
}

# }}}
# _preserve_case - preserve the capitalization pattern of the input {{{
sub _preserve_case {
	my ($original, $target) = @_;

	# Most likely scenario and least processing - we assume the target is lowercase
	return $target if $original eq lc($original);

	# All uppercase
	return uc($target) if $original eq uc($original);

	# First letter capitalized
	return ucfirst($target) if $original eq ucfirst(lc($original));

	# Default to lowercase
	return $target;
}

# }}}
# _compare - compare this Boolean object with another value {{{
sub _compare {
	my ($self, $other, $str_context) = @_;

	# If other is a Boolean object, compare their underlying values
	return ${$self} == ${$other} if (ref($other) eq 'Boolean');

	# Compare in the correct context
	if ($str_context) {
		$other = __PACKAGE__->parse($other);
	} else {
		$other = __PACKAGE__->of($other);
	}
	return ${$self} == ${$other};
}

# }}}
# _invert - return the opposite Boolean value {{{
sub _invert {
		my ($self) = @_;
		return ${$self} ? __PACKAGE__->false : __PACKAGE__->true;
}

# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu list:
