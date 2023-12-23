package Genesis::Env::Manifest::Unevaluated;

use strict;
use warnings;

use base 'Genesis::Env::Manifest';

sub source_files {
	my $self = shift;
	return [
		$self->builder->initiation_file(),
		$self->builder->kit_files(),
		$self->builder->cloud_config_files(optional => 1),
		$self->builder->environment_files(),
		$self->builder->conclusion_file()
	]
}

sub merge_options {
	return {
		eval => 'no'
	}
}

sub merge_environment {
	return {
		%{$_[0]->builder->full_merge_env},
		%{$_[0]->env->vault->env},
		REDACT => undef
	}
}

sub _merge {
	my $self = shift;
	my ($data, $file, $warnings, $errors) = $self->builder->merge(
		$self,
		$self->source_files,
		$self->merge_options,
		$self->merge_environment
	);

	# FIXME: Do something if there were errors or warnings...
	return ($data,$file);
}
1;
