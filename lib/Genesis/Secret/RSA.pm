package Genesis::Secret::RSA;
use strict;
use warnings;

use base "Genesis::Secret";

use Genesis qw(run);

### Construction arguments {{{
# size:  <positive integer>
# path:  <relative location in secrets-store under the base>
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
		uc($self->type)." public/private keypair",
		$self->{definition}{size} . ' bytes',
		$self->{definition}{fixed} ? 'fixed' : undef
	);
}

# }}}
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
sub _required_value_keys {
	qw/private public/
}

# }}}
# _validate_value - validate an RSA secret value {{{
sub _validate_value {
	my ($self) = @_;

	my $values = $self->value;
	my %results;

	my ($priv_modulus,$priv_rc) = run('openssl rsa -noout -modulus -in <(echo "$1")', $values->{private});
	$results{priv} = [
		!$priv_rc,
		"Valid private key"
	];

	my ($pub_modulus,$pub_rc) = run('openssl rsa -noout -modulus -in <(echo "$1") -pubin', $values->{public});
	$results{pub} = [
		!$pub_rc,
		"Valid public key"
	];

	if (!$pub_rc) {
		my ($pub_info, $pub_rc2) = run('openssl rsa -noout -text -inform PEM -in <(echo "$1") -pubin', $values->{public});
		my ($bits) = ($pub_rc2) ? () : $pub_info =~ /Key:\s*\(([0-9]*) bit\)/;
		my $size_ok = ($bits || 0) == $self->get('size');
		$results{size} = [
			$size_ok ? 'ok' : 'warn',
			sprintf("%s bit%s", $self->get('size'), $size_ok ? '' : ($bits ? " (found $bits bits)" : " (could not read size)"))
		];
		if (!$priv_rc) {
			$results{agree} = [
				$priv_modulus eq $pub_modulus,
				"Public/Private key agreement"
			];
		}
	}
	return (\%results, qw/priv pub agree size/)
}

# }}}
# __get_safe_command_for_generate - get command components to add or rotate secret {{{
sub __get_safe_command_for_generate {
	my ($self, $action, %opts) = @_;
	my @cmd = ('rsa', $self->get('size'), $self->full_path);
	push(@cmd, '--no-clobber') if $action eq 'add' || $self->get(fixed => 0);
	return @cmd;
}

sub _get_safe_command_for_add    {shift->__get_safe_command_for_generate('add',@_)}
sub _get_safe_command_for_rotate {shift->__get_safe_command_for_generate('rotate',@_)}

# }}}
# _import_from_credhub - import secret values from credhub {{{
sub _import_from_credhub {
	my ($self,$value) = @_;

	return ('error', 'expecting a hash, got a '.ref($value)//'string') if ref($value) ne 'HASH';
	my @missing = grep {!exists($value->{$_})} qw/private_key public_key/;
	return ('error', "missing keys in credhub secret: ".join(", ", @missing))
		if @missing;

	$self->set_value({
		private     => $value->{private_key},
		public      => $value->{public_key},
	});
	$self->save;

	return ('ok');
}
# }}}
# }}}

1;
# vim: fdm=marker:foldlevel=1:noet
