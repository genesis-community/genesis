package Genesis::Env::Manifest::VaultifiedEntombed;

use strict;
use warnings;

use base 'Genesis::Env::Manifest';

sub deployable {1}

sub _source_files {
	my $self = shift;
	(
		$self->builder->initiation_file(),
		$self->builder->kit_files(),
		$self->builder->cloud_config_files(optional => 1),
		$self->builder->environment_files(),
		$self->builder->conclusion_file()
	)
}

sub _merge {
	my $self = shift;
	my ($data, $file, $warnings, $errors) = $self->builder->merge(
		$self,
		[$self->_source_files],
		eval => "partial",
	);

	# FIXME: Do something if there were errors or warnings...
	return ($data,$file);
}

1;
