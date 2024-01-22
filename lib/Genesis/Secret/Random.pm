package Genesis::Secret::Random;
use strict;
use warnings;

use base "Genesis::Secret";

use Genesis::Term qw(checkbox);

### Construction arguments {{{
# size:        <positive integer>
# valid_chars: <optional, specify a subset of characters that can be used to generate the value>
# format:      <optional: alternative format - one of base64, bcrypt, crypt-md5, crypt-sha256, or crypt-sha512
# destination: <optional, only legal if format specified: path relative to secrets-store base to store the formatted value>
# fixed:       <boolean to specify if the secret can be overwritten>
# }}}

### Instance Methods {{{
# format_key - the key used to store the formatted version of the secret {{{
sub format_key {
	my $self = shift;
	my $format = $self->get('format');
	return undef unless $format;
	my $key = (split(":",$self->path,2))[1];
	$self->get(destination => $key.'-'.$format);
}

# }}}
# format_path - the relative path and key to the formatted version of the secret {{{
sub format_path {
	my $self = shift;
	my $format_key = $self->format_key;
	return unless $format_key;
	return (split(':',$self->path,2))[0].':'.$format_key;
}

#}}}
# set_format_value {{{
sub set_format_value {
	my ($self, $value, %opts) = @_;
	$self->{format_value} = $value;
	$self->{stored_format_value} = delete($self->{format_value}) if ($opts{in_sync});
}

# }}}
# format_value - the value of the formatted value -- IT DOES NOT FORMAT THE VALUE {{{
sub format_value {$_[0]->{format_value}||$_[0]->{stored_format_value}}

# }}}
# has_format_value - true if format_value is present locally or in store {{{
sub has_format_value {exists($_[0]->{format_value})||exists($_[0]->{stored_format_value})}

#}}}
# TODO: add calc_format_key if we ever want to be able to write new formatted value based on unformatted value

# vault_operator - get the vault operator string for the given key {{{
sub vault_operator {
	my ($self, $req_key) = @_;
	my ($path, $key) = split(":",$self->path,2);
	$key //= $self->default_key;
	$path .= ':'.$key;
	return $self->_assemble_vault_operator($path);
}
# }}}
#}}}

### Polymorphic Instance Methods {{{
# default_key - default key to use if no key given {{{
sub default_key {
	'value'
}
# }}}
# check_value - check that the secret is present (and its formatted version if applicable) {{{
sub check_value {
	my $self = shift;
	return ('missing') unless defined($self->value);
	return ('ok') unless $self->format_key && !defined($self->format_value);
	return ('missing', sprintf(
		"%smissing %s formatted value under %s key",
		checkbox(0), $self->get('format'),$self->format_key
	));
}

sub promote_value_to_stored {
	my $self = shift;
	$self->{stored_value} = delete($self->{value});
	$self->{stored_format_value} = delete($self->{format_value}) if $self->format_path;
}

# }}}
sub all_paths {
	grep {$_} ($_[0]->path,$_[0]->format_path);
}

# }}}

### Parent-called Support Instance Methods {{{
# _description - return label and features to build describe output {{{
sub _description {
	my ($self, $alternative) = @_;
	return (defined($alternative) && $alternative eq 'format') 
	? (
			$self->label,
			$self->{definition}{format} . ' formatted value of '.$self->path,
		)
	: (
			$self->label,
			$self->{definition}{size} . ' bytes',
			$self->{definition}{fixed} ? 'fixed' : undef
		);
}

#}}}
# _validate_constructor_opts - make sure secret definition is valid {{{
sub _validate_constructor_opts {
  my ($self,$path,%opts) = @_;

  my @errors;
  my %orig_opts = %opts;
  my $args = {};
  $args->{size} = delete($opts{size}) or 
    push @errors, "Requires a non-zero positive integer for 'size'";
  if ($args->{format} = delete($opts{format})) {
    $args->{destination} = delete($opts{destination}) if defined($opts{destination});
  }
  $args->{valid_chars} = delete($opts{valid_chars}) if defined($opts{valid_chars});
  $args->{fixed} = !!delete($opts{fixed});

  push(@errors, "Invalid '$_' argument specified") for grep {defined($opts{$_})} keys(%opts);
  return @errors
    ? (\%orig_opts, \@errors)
    : ($args)

}

# }}}
# _validate_value - validate randomly generated string secret value {{{
sub _validate_value {
	my $self = shift;
	my $value = $self->value;
	my %results;

	my $length_ok =  $self->get('size') == length($value);
	$results{length} = [
		$length_ok ? 'ok' : 'warn',
		sprintf("%s characters%s",  $self->get('size'), $length_ok ? '' : " - got ". length($value))
	];

	if ($self->get('valid_chars')) {
		(my $valid_chars = $self->get('valid_chars')) =~ s/^\^/\\^/;
		my $valid_chars_ok = $value =~ /^[$valid_chars]*$/;
		$results{valid_chars} = [
			$valid_chars_ok ? 'ok' : 'warn',
			sprintf("Only uses characters '%s'%s", $valid_chars,
				$valid_chars_ok ? '' : " (found invalid characters in '$value')"
			)
		];
	}

	if ($self->format_key) {
		my ($secret_path,$secret_key) = split(":", $self->path,2);
		my $format_key = $self->get('destination') ? $self->get('destination') : $secret_key.'-'.$self->get('format');
		$results{formatted} = [
			defined($self->format_value),
			sprintf("Formatted as %s in ':%s'%s", $self->get('format'), $format_key,
				defined($self->format_value) ? '' : " ( not found )"
			)
		];
	}

	return (\%results, qw/length valid_chars formatted/);
}

# }}}

# _get_safe_command_for_remove - get command components to remove secret {{{
sub _get_safe_command_for_remove {
	my ($self) = @_;
	my @cmd = ('rm', '-f', $self->full_path);
	if ($self->get('format')) {
		push @cmd, '--', 'rm', '-f', $self->format_path;
	}
	return @cmd;
}

# }}}
# __get_safe_command_for_generate - get command components to add or rotate secret {{{{
sub __get_safe_command_for_generate {
	my ($self, $action, %opts) = @_;
	my @cmd = ('gen', $self->get('size'),);
	my ($path, $key) = split(':',$self->path);
	push(@cmd, '--policy', $self->get('valid_chars')) if $self->get('valid_chars');
	push(@cmd, $self->base_path.$path, $key);
	push(@cmd, '--no-clobber') if $action eq 'add' || $self->get(fixed => 0);
	if ($self->get('format')) {
		push(@cmd, '--', 'fmt', $self->get('format'), $self->base_path.$path, $key, $self->format_key);
		push(@cmd, '--no-clobber') if $action eq 'add' || $self->get(fixed => 0);
	}
	return @cmd;
}
sub _get_safe_command_for_add    {shift->__get_safe_command_for_generate('add',@_)}
sub _get_safe_command_for_rotate {shift->__get_safe_command_for_generate('rotate',@_)}

# }}}
sub _import_from_credhub {
	my ($self,$value) = @_;
	# TODO: Do we need to check if the ca cert is the ca cert associated?
	$self->set_value($value);
	$self->save;

	return ('ok');
	
}
#}}}

1;
# vim: fdm=marker:foldlevel=1:noet
