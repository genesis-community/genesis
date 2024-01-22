package Genesis::Env::Manifest::Vaultified;

use strict;
use warnings;

use parent qw/Genesis::Env::Manifest/;

do $ENV{GENESIS_LIB}."/Genesis/Env/Manifest/_vaultify_mixin.pm";

sub deployable {1}

sub redacted {
	$_[0]->builder->vaultified_redacted(subset => $_[0]->{subset});
}

sub _merge {
	my $self = shift;

	if ($self->vaultify($self->_get_decoupled_data, $self->pre_merged_vaultified_file)) {
		my ($data, $file, $warnings, $errors) = $self->merge_vaultified_manifest();
		return ($data,$file);
	} else {
		return ($self->builder->unredacted->data, $self->builder->unredacted->file)
	}
}

1;
