package Genesis::Env::Manifest::Entombed;

use strict;
use warnings;

use base 'Genesis::Env::Manifest';
require Genesis::Env::Manifest::_entombment_mixin;

sub deployable {1}

sub source_files {
	my $self = shift;
	return [
		$self->builder->initiation_file(),
		$self->builder->kit_files(),
		$self->builder->cloud_config_files(optional => 0),
		$self->builder->environment_files(),
		$self->builder->conclusion_file()
	]
}

sub redacted {
	$_[0]; #Entombed manifests don't need to be redacted - no vault secrets
}

sub merge_options {
	return {}
}

sub merge_environment {
	return {
		%{$_[0]->builder->full_merge_env},
		%{$_[0]->local_vault->env},
		REDACT => undef
	}
}

sub _merge {
	my $self = shift;
	my $src_files = $self->source_files; # For logging order purposes

	$self->_entomb_secrets();
	my ($data, $file, $warnings, $errors) = $self->builder->merge(
		$self,
		$src_files,
		$self->merge_options,
		$self->merge_environment
	);

	# FIXME: Do something if there were errors or warnings...
	return ($data,$file);
}

1;