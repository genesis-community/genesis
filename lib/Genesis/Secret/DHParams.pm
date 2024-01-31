package Genesis::Secret::DHParams;
use strict;
use warnings;

use base "Genesis::Secret";

use Genesis qw/run/;

### Construction arguments {{{
# size: <positive integer>
# path: <relative location in secrets-store under the base>
# fixed: <boolean to specify if the secret can be overwritten>
# }}}

### Polymorphic Instance Methods {{{
# label - specific label for this derived class {{{
sub label {'RSA key pair'}
# }}}
# }}}

### Parent-called Support Instance Methods {{{
# _description - return label and features to build describe output {{{
sub _description {
	my $self = shift;

	return (
		"Diffie-Hellman key exchange parameters",
		$self->{definition}{size} . ' bytes',
		$self->{definition}{fixed} ? 'fixed' : undef
	);
}

#}}}
# _required_constructor_opts - list of required constructor properties {{{
sub _required_constructor_opts {
  qw/size/
}

# }}}
# _optional_constructor_opts - list of option contructor proprties {{{
sub _optional_constructor_opts {
  qw/fixed/
}

# }}}
# _required_value_keys - list of required keys in value store {{{
sub _required_value_keys	{
	qw/dhparam-pem/
}

# }}}
# _validate_value - validate an DHParams secret value {{{
sub _validate_value {
	my ($self) = @_;
	my $values = $self->value;

	my $pem  = $values->{'dhparam-pem'};
	my $pemInfo = run('openssl dhparam -in <(echo "$1") -text -check -noout', $pem);
	my ($size) = $pemInfo =~ /DH Parameters: \((\d+) bit\)/;
	my $pem_ok = $pemInfo =~ /DH parameters appear to be ok\./;
	my $size_ok = $size == $self->get('size');

	return ({
		valid => [$pem_ok, "Valid"],
		size  => [$size_ok, sprintf("%s bits%s", $self->get('size'), $size_ok ? '' : " (found $size bits)" )]
	}, qw/valid size/);
}

# }}}
# __get_safe_command_for_generate - get command components to add or rotate secret {{{{
sub __get_safe_command_for_generate {
	my ($self, $action, %opts) = @_;
	my @cmd = ('dhparam', $self->get('size'), $self->full_path);
	push(@cmd, '--no-clobber') if $action eq 'add' || $self->get(fixed => 0);
	return @cmd;
}

sub _get_safe_command_for_add    {shift->__get_safe_command_for_generate('add',@_)}
sub _get_safe_command_for_rotate {shift->__get_safe_command_for_generate('rotate',@_)}

sub process_command_output {
	my ($self, $action, $out, $rc, $err) = @_;
	return ($out, $rc, $err) unless $action eq 'add';
	if ($out =~ /Generating DH parameters,.*\+\+\*\+\+\*\s*$/s) {
		$out = '';
	}
	return ($out, $rc, $err);
}
# }}}

# }}}
# }}}

1;
# vim: fdm=marker:foldlevel=1:noet
