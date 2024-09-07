package Genesis::Secret::UserProvided;
use strict;
use warnings;

use base "Genesis::Secret";

use Genesis;
use Genesis::Term;

### Construction arguments {{{
# prompt:    <user prompt>
# sensitive: <boolean, optional: will hide input, and require confirmation, if true>
# multiline: <boolean, optional: will provide multi-line input support if true>
# subtype:   <future-proofing; may alter construction or behaviour (ie for providing x509 certs) >
# fixed:     <boolean to specify if the secret can be overwritten>
# }}}

### Polymorphic Instance Methods {{{
# label - specific label for this derived class {{{
sub label {'User-provided'}

# }}}
# is_command_interactive - return true if command for action is interactive {{{
sub is_command_interactive {
	my ($self, $action) = @_;
	return scalar(grep {$action eq $_} qw/add rotate/);
}
# }}}
# vault_operator - get the vault operator string for the given key {{{
sub vault_operator {
	my ($self, $req_key) = @_;
	my ($path, $key) = split(":",$self->path,2);
	$key //= $self->default_key;
	$path .= ':'.$key;
	return $self->_assemble_vault_operator($path);
}
# }}}
# }}}

### Parent-called Support Instance Methods {{{
# _required_constructor_opts - list of required constructor properties {{{
sub _required_constructor_opts {
  qw/prompt/
}

# }}}
# _optional_constructor_opts - list of option contructor proprties {{{
sub _optional_constructor_opts {
  qw/sensitive multiline subtype fixed/
}

# }}}
# __get_safe_command_for_generate  - get command components to add or rotate secret {{{
sub __get_safe_command_for_generate {
	my ($self,$action,%opts) = @_;
	my @cmd = ();
	if (in_controlling_terminal) {
		# FIXME: don't prompt if secret is fixed and value is present when rotating
		# TODO: some method to keep existing value?
		if ($self->get('multiline')) {
			my $file=workdir().'/secret_contents';
			push (@cmd, \&prompt_for_multiline_secret, $file, $self->get('prompt'));
			push (@cmd, '--', 'set', split(':', $self->full_path."\@$file", 2));
			push (@cmd, '--no-clobber') if $action eq 'add' || $self->get('fixed');
		} else {
			my $op = $self->get('sensitive') ? 'set' : 'ask';
			push (@cmd, 'prompt', $self->get('prompt'));
			push (@cmd, '--', $op, split(':', $self->full_path));
			push (@cmd, '--no-clobber') if $action eq 'add' || $self->get('fixed');
		}
	}
	return @cmd;
}
sub _get_safe_command_for_add    {shift->__get_safe_command_for_generate('add', @_)}
sub _get_safe_command_for_rotate {shift->__get_safe_command_for_generate('rotate', @_)}

# }}}
# _description - return label and features to build describe output {{{
sub _description {
	my ($self) = @_;
	return (
		$self->label,
		$self->get('prompt')
	)
}

# }}}
# _import_from_credhub - process the credhub value in the context of this secret type {{{
sub _import_from_credhub {
	my ($self,$value) = @_;
	$self->set_value($value);
	$self->save;

	return ('ok');

}
# }}}
# }}}

sub prompt_for_multiline_secret {
	my ($file,$prompt) = @_;
	require Genesis::UI;
	#print "[2A";
	mkfile_or_fail($file,Genesis::UI::prompt_for_block($prompt));
	0;
}
1;
# vim: fdm=marker:foldlevel=1:noet
