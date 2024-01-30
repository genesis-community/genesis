# Mixin to provide entombment functionality - require to use;

use Genesis  qw/bail flatten struct_set_value save_to_yaml_file tmpfile uniq/;
use JSON::PP qw/decode_json encode_json/;


sub get_vault_paths {
	my ($self, %opts) = @_;
	my $vault_paths = $self->SUPER::get_vault_paths(%opts);
	my @vaultify_path_args = $self->{vaultified_file}
		? (file => $self->{vaultified_file})
		: $self->{vaultified_data}
		? (data => $self->{vaultified_data})
		: ();
	unless (@vaultify_path_args) {
		my $data = {%{$self->builder->partial(no_notification => 1)->data}};
		@vaultify_path_args = (data => $data)
			if $self->vaultify($data);
	}
	return $vault_paths unless @vaultify_path_args;
	my $vaultified_paths = $self->builder->vault_paths(@vaultify_path_args);
	return {
		%$vault_paths,
		%$vaultified_paths
	};
}

# _get_decoupled_data -  deep copy because we're going to modify the values
sub _get_decoupled_data {
	my ($self, $source) = @_;
	$source //='unredacted';
	return decode_json(encode_json(
		$self->builder->$source->data
	));
}

sub vaultify {
	my ($self,$data,$file) = @_;
	if (my $var_defs = delete($data->{variables})) { # TODO: This may be insufficient for credhub values not defined by variables
		my $flat_data = flatten({}, undef, $data);
		my %vars_map;
		push(@{$vars_map{$_->[1]}}, $_->[0]) for
			grep {$_->[1] && $_->[1] =~/\(\(.*\)\)/}
			map {[$_,$flat_data->{$_}]}
			keys %$flat_data;

		my %ch_path_lookup = (
			map {$_->from_manifest ? ($_->var_name, $_) : ()}
			$self->env->get_secrets_plan->secrets
		);

		for my $var_ref (sort keys %vars_map) {
			if ($var_ref =~ /^\(\(([^\) ]+)\)\)$/) { # is it a single variable reference?
				my $var = $1;
				next if $var =~ /^genesis-entombed\//; #entombed vault data from previous phase
				next if $data->{'bosh-variables'}{$var}; # its a bosh variable
				my ($path, $key) = ($var =~ /^(.*?)(?:\.(.*))?$/);
				my $secret = $ch_path_lookup{$var} || $ch_path_lookup{$path};
				if ($secret) {
					my $vault_operator = $secret->vault_operator($key);
					bail("Could not find vault lookup operator") unless $vault_operator;
					struct_set_value($data,$_,$vault_operator) for @{$vars_map{$var_ref}};
				} else {
					warning("Could not find definition for variable $var - leaving as-is");
				}
			} else { # or is it an embedded variable reference (multiple?)
				my @bits = split(/\(\(([^\) ]*)\)\)/, $var_ref);
				my %meta_vaultification = ();
				my @concat = ();
				while (@bits) {
					(my $prefix, my $var, @bits) = @bits;
					push @concat, '"'.$prefix.'"' if $prefix;
					next unless $var;
					if ($data->{'bosh-variables'}{$var}) {
						push @concat,"\"(($var))\"";
					} else {
						my ($path, $key) = ($var =~ /^(.*?)(?:\.(.*))?$/);
						my $secret = $ch_path_lookup{$var} || $ch_path_lookup{$path};
						if ($secret) {
							my $vault_operator = $secret->vault_operator($key);
							bail(
								'Cannot use a compound credhub reference inside a string in %s',
								@{$vars_map{$var_ref}}[0]
							) if ref($vault_operator);
							my $vault_ref = ($var =~ s/\./+/gr);
							$meta_vaultification{$vault_ref} = $vault_operator;
							push @concat, 'meta.__vaultified.'.$vault_ref;
						} else {
							warning("Could not find definition for variable $var - leaving as-is");
							push @concat,"\"(($var))\"";
						}
					}
				}
				my $value = "";
				if (keys %meta_vaultification) { # only need to replace if one or more vault values created
					$data->{meta}{__vaultified}{$_} = $meta_vaultification{$_} for (keys %meta_vaultification);
					my $value = join(' ', '((', 'concat', @concat, '))');
					struct_set_value $data, $_, $value for @{$vars_map{$var_ref}};
				}
			}
		}
		$self->{vaultified_data} = $data;
		$self->{vaultified_file} = $file;
		save_to_yaml_file($data,$file) if $file;
		return 1
	} else {
		return 0
	}
}

sub vaultify_merge_environment {
	return {
		%{$_[0]->builder->full_merge_env}, # May not be needed
		%{$_[0]->env->vault->env},
		REDACT => undef
	}
}

sub vaultify_merge_options {
	return {
		eval => 'full',
		multidoc => 0,
		gopatch => 0
	}
}

sub pre_merged_vaultified_file {
	my $self = shift;
	$self->{__pre_merged_vaultified_file} //= tmpfile(
		template => 'pre-merged-vaultified-manifest-XXXXXXXXXXXX',
		ext => '.yml',
		dir => $self->env->workpath()
	);
}

sub merge_vaultified_manifest {
	my ($self, %opts) = @_;
	my ($data, $file, $errors, $warnings) = $self->builder->merge(
		$self,
		[$self->pre_merged_vaultified_file],
		$opts{merge_ops} // $self->vaultify_merge_options,
		$opts{merge_env} // $self->vaultify_merge_environment
	);
	return ($data, $file, $errors, $warnings);
}

1;
