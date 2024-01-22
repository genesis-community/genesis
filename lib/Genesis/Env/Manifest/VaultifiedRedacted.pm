package Genesis::Env::Manifest::VaultifiedRedacted;

use strict;
use warnings;

use parent qw/Genesis::Env::Manifest/;

do $ENV{GENESIS_LIB}."/Genesis/Env/Manifest/_vaultify_mixin.pm";

sub redacted {$_[0]}

sub merge_environment {
	return {
		%{$_[0]->builder->full_merge_env},
		%{$_[0]->env->vault->env},
		REDACT => "yes"
	}
}

sub merge_options {
	return {
		eval => 'full',
		multidoc => 0,
		gopatch => 0
	}
}

sub _merge {
	my $self = shift;
	my $tmpfile = $self->_generate_file_name('transient');
	if ($self->vaultify($self->_get_decoupled_data ,$tmpfile)) {
		my ($data, $file, $warnings, $errors) = $self->builder->merge(
			$self,
			[$tmpfile],
			$self->merge_options,
			$self->merge_environment
		);
		unlink $tmpfile;
		return ($data,$file);
	} else {
		return ($self->builder->redacted->data, $self->builder->redacted->file)
	}
}

1;
