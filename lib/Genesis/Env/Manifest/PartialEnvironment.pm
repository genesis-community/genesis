package Genesis::Env::Manifest::PartialEnvironment;

use strict;
use warnings;

use base 'Genesis::Env::Manifest';

sub source_files {
	my $self = shift;
	return [
		$self->builder->environment_files(),
	]
}

sub merge_options {
	return {
		eval => 'adaptive'
	}
}

sub merge_environment {
	return {
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
