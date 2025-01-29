package Genesis::Env::Manifest::Entombed;

use strict;
use warnings;

use parent qw/Genesis::Env::Manifest/;
require File::Basename;
do((File::Basename::dirname(__FILE__) =~ s#^lib/##r) . "/_entombment_mixin.pm");

sub deployable {1}

sub redacted {
	$_[0]; #Entombed manifests don't need to be redacted - no vault secrets
}

sub manifest_lookup_target {
	$_[0]->builder->unredacted(subset => $_[0]->{subset});
}

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

sub merge_options {
	return {}
}

sub remote_vault_merge_environment {
	return {
		%{$_[0]->builder->full_merge_env},
		%{$_[0]->env->vault->env},
		REDACT => undef
	}
}
sub local_vault_merge_environment {
	return {
		%{$_[0]->builder->full_merge_env},
		%{$_[0]->local_vault->env},
		REDACT => undef
	}
}

sub _merge {
	my $self = shift;
	my $src_files = $self->source_files; # For logging order purposes

	my $entombed = $self->_entomb_secrets();
	my ($data, $file, $warnings, $errors) = $self->builder->merge(
		$self,
		$src_files,
		$self->merge_options,
		$entombed ? $self->local_vault_merge_environment : $self->remote_vault_merge_environment
	);

	# FIXME: Do something if there were errors or warnings...

	if ($entombed) {
		$self->env->notify("Shutting down local vault after manifest merge.");
		$self->local_vault->shutdown;
	}

	return ($data,$file);
}

1;
