package Genesis::Env::Manifest::VaultifiedEntombed;

use strict;
use warnings;

use parent qw/Genesis::Env::Manifest/;

use File::Basename;
my $base_path = dirname(__FILE__) =~ s#^lib/##r;
do "$base_path/_entombment_mixin.pm";
do "$base_path/_vaultify_mixin.pm";

sub deployable {1}

sub source_files {
	my $self = shift;
	(
		$self->builder->initiation_file(),
		$self->builder->kit_files(),
		$self->builder->cloud_config_files(optional => 0),
		$self->builder->environment_files(),
		$self->builder->conclusion_file()
	)
}

sub redacted {
	$_[0]; #Entombed manifests don't need to be redacted - no vault secrets
}
sub manifest_lookup_target {
	$_[0]->builder->vaultified(subset => $_[0]->{subset});
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

	# vaultify to set the data to discover the vault paths.
	return ($self->builder->entombed->data, $self->builder->entombed->file)
		unless ($self->vaultify($self->_get_decoupled_data, $self->pre_merged_vaultified_file));

	$self->_entomb_secrets();
	my $transient_file = $self->pre_merged_vaultified_file;
	$self->_set_file_name($transient_file);
	my ($partially_entombed_data, undef, $p_warnings, $p_errors) = $self->builder->merge(
		$self,
		[$self->source_files],
		$self->merge_options,
		$self->merge_environment
	);
	$self->_set_file_name(undef);

	$self->vaultify($partially_entombed_data, $self->pre_merged_vaultified_file);
	$self->{notice} = undef;
	my ($data, $file, $warnings, $errors) = $self->merge_vaultified_manifest(
		merge_env =>  {
			%{$self->builder->full_merge_env}, # May not be needed
			%{$self->local_vault->env},
			REDACT => undef
		}
	);

	# FIXME: Do something if there were errors or warnings...

	$self->env->notify("Shutting down local vault after manifest merge.");
	$self->local_vault->shutdown;
	return ($data,$file);
}

sub _generate_file_name {
	my $self = shift;
	return $self->{transient_filename} || $self->SUPER::_generate_file_name();
}

sub _set_file_name {
	my ($self, $filename) = @_;
	if ($filename) {
		$self->{transient_filename} = $filename;
	} else {
		delete($self->{transient_filename});
	}
}

1;
