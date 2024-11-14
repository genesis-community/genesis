package Genesis::Hook::CloudConfig;
use strict;
use warnings;

use Genesis;
use Genesis::Hook::CloudConfig::LookupRef;

use parent qw(Genesis::Hook);

# Constants {{{
use constant {
	VM_TYPE => 'vm_type',
	VM_EXTENSION => 'vm_extension',
	DISK_TYPE => 'disk_type',
	NETWORK => 'network',
	FIRST_SORT_TOKEN => '0000',
	LAST_SORT_TOKEN => "zzzz",
};
# }}}

# Class Overrides {{{
# init: Initializes the CloudConfig hook, injecting the common properties {{{

my %cloud_configs = ();
sub init {
	my ($class, %opts) = @_;

	my $env = delete($opts{env}) or bail("CloudConfig hook requires an environment");
	my $purpose = $opts{purpose} // $ENV{GENESIS_CLOUD_CONFIG_PURPOSE};

	# exmple base name: c-aws-useast1-lab-vault
	my $basename = join '-', $env->name, $env->type;
	my $id = join('@', $purpose ? ($basename, $purpose) : ($basename));
	return $cloud_configs{$id} if ($cloud_configs{$id});

	my $iaas = delete($opts{cpi_iaas}) || $env->iaas;
	my $scale = delete($opts{scale}) || $env->scale;

	my $obj = $class->SUPER::init(
		env => $env, iaas => $iaas, scale => $scale, %opts, basename => $basename,
		id => $id, contents => {}, completed => 0
	);

	$obj->{overrides} = {
		environment => $env->env_config_overrides,
		director => $env->director_config_overrides,
	};

	return $cloud_configs{$id} = $obj;
}

# }}}
# done: Marks the CloudConfig hook as completed, and sets the contents {{{
sub done {
	my ($self, $contents) = @_;

	# Force name to be sorted first
	my $sort_name_first = FIRST_SORT_TOKEN.'name'.FIRST_SORT_TOKEN;
	my $sort_cloud_properties_last = LAST_SORT_TOKEN.'cloud_properties'.LAST_SORT_TOKEN;
	foreach my $k (keys %$contents) {
		my $c = $contents->{$k};
		delete($contents->{$k}) && next unless (@$c); # Remove empty arrays
		foreach my $e (@$c) {
			$e->{$sort_name_first} = delete($e->{name})
				if (ref($e) eq 'HASH' && exists $e->{name});
			$e->{$sort_cloud_properties_last} = delete($e->{cloud_properties})
				if (ref($e) eq 'HASH' && exists $e->{cloud_properties});
		}
	}
	my $filename = $self->env->workdir . "/cloud-config-$self->{id}.yml";
	save_to_yaml_file($contents, $filename);
	$self->{contents} = slurp($filename)
		=~ s/\b${sort_name_first}:/name:/gr 
		=~ s/\b${sort_cloud_properties_last}:/cloud_properties:/gr
		=~ s/\n([^ -])/\n\n$1/gmr;
	unlink($filename);
	$self->SUPER::done;
}
# }}}
# results: Returns the contents of the cloud config {{{
sub results {
	return undef unless $_[0]->completed; # Should this be an error?
	return $_[0]->{contents};
}

# }}}
# }}}

# Accessors {{{
sub iaas {shift->{iaas}}
sub scale {shift->{scale}}
sub basename { return shift->{basename}; }
sub contents { return shift->{contents}; }
# }}}

# Public Methods {{{
# name_for: Returns a name for components of the cloud config based on the basename and the provided arguments {{{
sub name_for {
	return join '-', shift->{basename}, @_;
}

# }}}
# for_scale: Returns the value for a given scale from a map, or a default value if not found {{{
sub for_scale {
	my ($self, $map, $default) = @_;
	my $scale = $self->scale;
	return $map->{$scale} // $default;
}

# }}}
# lookup_ref: Returns a lookup reference for a given path {{{
sub lookup_ref {
	my ($self, $paths, $default) = @_;
	return Genesis::Hook::CloudConfig::LookupRef->new($paths, $default);
}

# }}}
# build_cloud_config: Builds the cloud config for the environment {{{
sub build_cloud_config {
	my ($self,$config) = @_;

	# At this point, the config is already built, so we just need to
	# populate any unprocessed overrides
	# TODO:  This is not implemented yet

	return $config;
}

# }}}
# network_definition: Returns the definition for a given network {{{
sub network_definition {
	# This one is special compared to vm_type_definition, vm_extension_definition,
	# and disk_type_definition.  It will query the exodus data of the deploying
	# BOSH director to get the network definition, as well as what is already
	# allocated, so that allocations can be grown and shrunk as needed.
	#
	# It will also determine the base containing network and subnets, to figure
	# out what is available for allocation, what AZs are available, dns, gateway,
	# etc.
	#
	# It can support a common network definition per network, or support subnets.
	#
	# It also supports definition filters for ocfp and non-ocfp deployments, which
	# generally support different networking allocations.
	#
	# Range of networks will be dynamically determined based on the master range,
	# the existing allocations, and the static values (which can be outside the
	# allocation mask-generated range(s)).
	
	my ($self, $target, %maps) = @_;
	if ($maps{ocfp} xor $self->env->is_ocfp) {
		# This is an ocfp deployment, but the network is not an ocfp network (or vice versa)
		return ();
	}

	my $config = {
		name => $self->name_for($target),
		type => 'manual',
	};

	if ($maps{subnets}) {
		# This is a subnetted network -- push off each subnet to the subnet_definition method
		# and return the network definition with the subnets array populated
		my $subnet_id = 0;
		my @subnets = map {
			my $subnet_definition = $_;
			my $subnet_name = delete($subnet_definition->{name}) // $subnet_id;
			$self->_subnet_definition($target, $subnet_name, %$_);
			$subnet_id++;
		} @{$maps{subnets}};
		$config->{subnets} = \@subnets;
	} else {
		# This is a non-subnetted network
		my $subnet = $self->_subnet_definition($target, '', $maps{common});
		$config->{subnets} = [$subnet];
	}
	return $config;

}
# }}}
# network_cloud_properties_for_iaas: Returns the cloud properties for a given network and cpi {{{
sub network_cloud_properties_for_iaas {
	return shift->_cloud_properties_for_iaas('network', @_);
}
# }}}
# calculate_subnet_rangs: Calculates the IP ranges for a given network and subnet {{{
sub calculate_subnet_ranges {
	my ($self, $network, $subnet) = @_;

	# This will calculate the IP ranges for a given network and subnet, based on
	# the existing allocations, the master range, and the static values.  It will
	# return the ranges that are available for allocation, and the ranges that are
	# already allocated.
	#
	# Given the master range and the existing allocations from the bosh exodus
	# 'networks' extended path,we can compare any existing allocations for this
	# network and subnet, and determine what is available for allocation, and what
	# is needed.  We then get a slice to meet the needs from the master range, and
	# record it back to the exodus data.
	#
	# We also need to allocate any static values that are outside the allocation
	# mask.  These can be an integer offset from the master range, or a specific
	# named value in exodus data.


}
# }}}
# vm_type_definition: Returns the definition for a given vm type {{{
sub vm_type_definition {
	return shift->_config_definition(VM_TYPE, @_);
}

# }}}
# vm_type_cloud_properties_for_iaas: Returns the cloud properties for a given vm type and cpi {{{
sub vm_type_cloud_properties_for_iaas {
	return shift->_cloud_properties_for_iaas(VM_TYPE, @_);
}

# }}}
# vm_extension_definition: Returns the definition for a given vm extension {{{
sub vm_extension_definition {
	return shift->_config_definition(VM_EXTENSION, @_);
}

# }}}
# vm_extension_cloud_properties_for_iaas: Returns the cloud properties for a given vm extension and cpi {{{
sub vm_extension_cloud_properties_for_iaas {
	return shift->_cloud_properties_for_iaas(VM_EXTENSION, @_);
}

# }}}
# disk_type_definition: Returns the definition for a given disk type {{{
sub disk_type_definition {
	return shift->_config_definition(DISK_TYPE, @_);
}

# }}}
# disk_type_cloud_properties_for_iaas: Returns the cloud properties for a given disk type and cpi {{{
sub disk_type_cloud_properties_for_iaas {
	return shift->_cloud_properties_for_iaas(DISK_TYPE, @_);
}

# }}}
# }}}
#
# Private Methods {{{
# _config_definition: Returns the definition for a given config type {{{
sub _config_definition {
	my ($self, $type, $target, %maps) = @_;

	$self->_validate_definition($type, $target, %maps);
	my %config = %{$maps{common}//{}};
	$config{name} = $self->name_for($target);
	$config{cloud_properties} = $self->_cloud_properties_for_iaas(
		$type, $target, %{$maps{cloud_properties_for_iaas}//{}}
	) if exists $maps{cloud_properties_for_iaas};

	$self->_process_config_overrides(
		$type, $target, \%config, 'definition'
	);

	# After any overrides, we need to make sure there is a configuration to set
	# Return an empty list if there is no configuration.
	if (exists $config{cloud_properties} && ! keys %{$config{cloud_properties}}) {
		delete($config{cloud_properties})
	}
	if (grep {$_ !~ m/^(name)$/} keys %config) {
		return {%config};
	} else {
		return ();
	}
}

# }}}
# _cloud_properties_for_iaas: Returns the cloud properties for a given type and cpi {{{
sub _cloud_properties_for_iaas {
	my ($self, $type, $target, %map) = @_;
	my $cloud_properties = $map{$self->iaas} || $map{'*'}; #TODO: allow glob-style matching
	$self->env->kit->kit_bug(
		"No Cloud Config for IaaS type %s defined in %s",
		$self->iaas, $self->env->kit->id
	) unless ($cloud_properties);

	return $self->_process_config_overrides(
		$type, $target, $cloud_properties, 'cloud_properties'
	);
}

# }}}
# _subnet_definition: Returns the definition for a given subnet {{{
sub _subnet_definition {
	my ($self, $target, %maps) = @_;

	# $target is for named subnets, purely a genesis addition.  It can also be
	# an integer offset of the subnet, or undefined for no subnet (the network 
	# base configuration).  The kit can define either a common configuration
	# for a single subnet, or a list of 1 or more subnets, each with their own
	# configuration.  The network_definition method will call this method for
	# either the network base configuration, or for each subnet in the network,
	# providing the map as 'common' for the network base, and target relating
	# to its source.
	#
	# The user's environment can override can specify both a default at the
	# network layer as well as a subnet array for specific over- rides.  The bosh
	# exodus network data will contain common and/or subnet defaults, as well as
	# the existing network allocations, which can be used to determine what is
	# available for allocation, and what is already allocated.
	
	my $base_config = {
		range => $self->get_network_subnet_property($target,'range', required => 1),
		azs => $self->get_network_subnet_property($target, 'azs', required => 1),
	};
	$base_config->{gateway} = $self->_get_network_subnet_property($target, 'gateway')
	// $self->get_ip_from_range($base_config->{range}, 1);

	$base_config->{dns} = $self->_get_network_subnet_property($target, 'dns')
	// [$base_config->{gateway}, '1.1.1.1'];

	# TODO: Need to process the specifiable and the calulatable cloud properties
	#	$config{cloud_properties} = $self->_cloud_properties_for_iaas(
	#		'subnet', $target, %{$maps{cloud_properties_for_iaas}//{}}
	#);


	# After any overrides, we need to make sure there is a configuration to set
	# Return an empty list if there is no configuration.
	delete($base_config->{cloud_properties}) unless keys %{$base_config->{cloud_properties}};
}

# }}}
# _process_config_overrides: Applies overrides to a given config based on the environment and bosh {{{
sub _process_config_overrides {
	my ($self, $type, $target, $config, $path) = @_;

	# Recursively process each key or array element in the config, keeping track
	# of the path to determine where the overrides can be found.  Locations for
	# the overides are:
	# - environment file:
	#  - bosh-configs.cloud.${type}_defaults.${path}
	#  - bosh-configs.cloud.${type}s.$name.${path}
	# - exodus:
	#   /secret/<bosh-env-name>/<bosh-type>/configs/cloud/${type}/${path} TODO:  This is not implemented yet
	#
	# If the key is an array reference, the key is the first element, and the
	# lookup path is the second element.
	#
	# FIXME:  This only detects overrides for known config properties.  We need
	# to track the overrides that aren't applied, and just apply them at the end.
	# Alternatively, we lookup all the overrides first, and apply them as we go
	# for any matching paths.
	if (ref($config) eq 'HASH') {
		foreach my $key (keys %$config) {
			my $value = delete($config->{$key});
			my $new_path = $path ? "$path.$key" : $key;

			$config->{$key} = $self->_process_config_overrides($type, $target, $value, $new_path);
			delete($config->{$key}) unless defined($config->{$key});
		}
		# Apply overrides for non-processed items here...
	} elsif (ref($config) eq 'ARRAY') {
		foreach my $i (0..$#{$config}) {
			my $element = $config->[$i];
			my $new_path = $path ? "${path}[$i]" : ".[$i]";
			$config->[$i] = $self->_process_config_overrides($type, $target, $element, $new_path);
		}
		# Apply overrides for non-processed items here... (not likely to happen for arrays)
	} elsif (ref($config) eq 'Genesis::Hook::CloudConfig::LookupRef') {
		# This is a lookup referrence, with optional defaults
		$config = $config->default;
	} else {

		my ($override,$src) = $self->env->lookup([
			"bosh-configs.cloud.".count_nouns(2,$type, suppress_count => 1).".$target.$path",
			"bosh-configs.cloud.${type}_defaults.$path"
		]);
		$override //= $self->_bosh_exodus_lookup( # This will be cached so don't fetch exodus data for each lookup
			"configs/cloud/$type/$path",
		);
		if ($override) {
			trace(
				"Applying override for %s %s %s: %s",
				$type, $target, $path, JSON::PP->new->allow_nonref->encode($override)
			);
			$config = $override;
		}
	}
	return $config;
}

# }}}
# _validate_definition: Validates the definition for a given vm type {{{
sub _validate_definition {
	my ($self, $type, $target, %maps) = @_;

	# Vaidate that %maps contains the only common and cloud_properties_for_iaas keys
	my @extra_keys = grep {$_ !~ m/^(common|cloud_properties_for_iaas)$/} keys %maps;
	$self->env->kit->kit_bug(
		"Unexpected Cloud Config keys in %s %s in %s: %s",
		$target, $self->env->kit->id, join(", ", @extra_keys)
	) if @extra_keys;

	# Make sure we have at least one of common and cloud_properties_for_iaas keys
	$self->env->kit->kit_bug(
		"No Cloud Config definition for common or cloud_properties_for_iaas for %s %s in %s",
		$target, $self->env->kit->id
	) unless ($maps{cloud_properties_for_iaas} || $maps{common});

	$self->env->kit->kit_bug(
		"Cloud Config common definition for %s %s in %s is not a hashmap",
		$target, $self->env->kit->id
	) unless !defined($maps{common}) || ref($maps{common}) eq 'HASH';

	$self->env->kit->kit_bug(
		"Cloud Config cloud_properties_for_iaas for %s %s in %s is not a hashmap",
		$target, $self->env->kit->id
	) unless !defined($maps{cloud_properties_for_iaas}) || ref($maps{cloud_properties_for_iaas}) eq 'HASH';

	return 1;
}

# }}}
# _bosh_exodus_lookup: Returns the value for a given path in the bosh exodus data {{{
# }}}
1;

# vim: fdm=marker:foldlevel=1:ts=2:sts=2:sw=2:noet
