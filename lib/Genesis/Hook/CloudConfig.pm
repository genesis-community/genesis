package Genesis::Hook::CloudConfig;
use strict;
use warnings;

use Genesis;
use Genesis::Hook::CloudConfig::LookupRef;
use Genesis::Hook::CloudConfig::LookupNetworkRef;
use Genesis::Hook::CloudConfig::LookupSubnetRef;
use IP4::Range;
use IP4::MultiRange;
use POSIX qw(round);

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
# init - Initializes the CloudConfig hook, injecting the common properties {{{

my %cloud_configs = ();
sub init {
	my ($class, %opts) = @_;

	my $env = delete($opts{env}) or bail("CloudConfig hook requires an environment");
	bail(
		"Create-env environments do not have deployment cloud configs,as there is ".
		"no director to upload them to."
	) unless $class->_can_build_cloud_config($env);

	my $purpose = $opts{purpose} // $ENV{GENESIS_CLOUD_CONFIG_SUBTYPE};
	my $basename = $env->lookup('params.cloud_config_prefix', join '.', $env->name, $env->type);
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

	$obj->{network} //= $obj->_get_bosh_network_data();
	if ($env->is_ocfp) {
		$obj->{ocfp_config} = $env->ocfp_config_lookup('vpc');
	}

	return $cloud_configs{$id} = $obj;
}

# }}}
# done - Marks the CloudConfig hook as completed, and sets the contents {{{
sub done {
	my ($self, $contents) = @_;

	# Force name to be sorted first
	my $sort_name_first = FIRST_SORT_TOKEN.'name'.FIRST_SORT_TOKEN;
	my $sort_cloud_properties_last = LAST_SORT_TOKEN.'cloud_properties'.LAST_SORT_TOKEN;

	my $flat_contents = flatten({}, '', $contents);
	foreach my $k (keys %$flat_contents) {
		if ($k =~ /\.name$/) {
			$flat_contents->{$k =~ s/name$/$sort_name_first/r} = delete($flat_contents->{$k});
		} elsif ($k =~ /\.cloud_properties\./) {
			$flat_contents->{$k =~ s/\.cloud_properties\./.$sort_cloud_properties_last./r} = delete($flat_contents->{$k});
		}
	}
	$contents = unflatten($flat_contents);

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
# results - Returns the contents of the cloud config {{{
sub results {
	return undef unless $_[0]->completed; # Should this be an error?
	return wantarray
		? ($_[0]->{contents}, $_[0]->{network})
		: {config => $_[0]->{contents}, network => $_[0]->{network}};
}

# }}}
# _can_build_cloud_config - Returns whether the cloud config can be built for the environment {{{
sub _can_build_cloud_config {
	my ($class, $env) = @_;
	!($env->use_create_env)

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
# name_for - Returns a name for components of the cloud config based on the basename and the provided arguments {{{
sub name_for {
	return join '.', shift->{basename}, join('-', @_);
}

# }}}
# for_scale - Returns the value for a given scale from a map, or a default value if not found {{{
sub for_scale {
	my ($self, $map, $default) = @_;
	my $scale = $self->scale;
	return $map->{$scale} // $default;
}

# }}}
# lookup_ref - Returns a lookup reference for a given path {{{
sub lookup_ref {
	my ($self, $paths, $default) = @_;
	return Genesis::Hook::CloudConfig::LookupRef->new($paths, $default);
}

# }}}
# subnet_reference - Returns a reference to a subnet value that can be retrived per subnet {{{
sub network_reference {
	my ($self, $property, $lookup_method) = @_;
	return Genesis::Hook::CloudConfig::LookupNetworkRef->new(
		$property, $lookup_method//undef
	);
}

# }}}
# subnet_reference - Returns a reference to a subnet value that can be retrived per subnet {{{
sub subnet_reference {
	my ($self, $property, $lookup_method) = @_;
	return Genesis::Hook::CloudConfig::LookupSubnetRef->new(
		$property, $lookup_method//undef
	);
}

# }}}
# build_cloud_config - Builds the cloud config for the environment {{{
sub build_cloud_config { 
	my ($self,$config) = @_;
	# this is just a wrapper as the config is already assembled, but is included
	# so that if post-processing is needed, it can be done here without changing
	# the kits.
	return $config;
}

# }}}
# network_definition - Returns the definition for a given network {{{
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
	
	my ($self, $target, %options) = @_;
	my $strategy = delete($options{strategy}) // 'generic';

	if (($strategy eq 'ocfp') xor $self->env->is_ocfp) {
		# This is an ocfp deployment, but the network is not an ocfp network (or vice versa)
		return ();
	}

	my $network_id = $self->name_for('net', $target);
	my $config = {
		name => $network_id,
		type => 'manual',
	};

	if ($options{dynamic_subnets}) {
		bail(
			'Dynamic subnets are not supported for network definitions using the %s '.
			'strategy.  Consult the kit documentation or author.',
			$strategy
		) if ($strategy ne 'ocfp');

		my $definition = $options{dynamic_subnets};

		# OCFP Network Range Calculations
		# *-mgmt - 
		#   - Owns .0 to .31 of each subnet
		#   - bosh is deployed to 5th
		#   - vault is deployed to 6th
		#   - jumpbox is deployed to 7th
		#   - concourse web is 8th ip
		#   - prometheus is 9th ip
		#   - shield is 10th ip
		#   - doomsday/ocfp-ui is 11th ip
		#   - everything else is dynamic
		#
		#   To Facilitate this, we need the following in ocfp config:
		#   - vpc.subnets.<subnet>.reserved-offsets ie '0-5,7-10'
		#   - vpc.subnets.<subnet>.available-offsets: ie '12-254' or '31-n' n means
		#     last in cidr block -- if not supplied, will assume all available
		#     that are not reserved (generally we do NOT want this)
		#     we technically only need one of these, but both are supported
		#
		# *-ocfp - Owns .32 to .last of each subnet

		# This option assumes ocfp, and will dynamically determine the subnets based
		# on the ocfp configuration in vault, under
		# /secrets/{params.ocfp_config_path}.{env-name}/{mgmt|ocfp}/bosh/iaas/subnets/<name>/<id>
		# with `...ips.[mgmt|ocfp].reserved` for the reserved list.
		
		my $subnets = $self->subnets;
		if (defined(my $subnet_filter = $definition->{subnets})) {
			$subnet_filter = [$subnet_filter] unless ref $subnet_filter eq 'ARRAY';
			my $selected_subnets = {};
			for my $filter (grep {defined $_} @$subnet_filter) {
				if (ref $filter eq 'Regexp') {
					for my $subnet (keys %$subnets) {
						$selected_subnets->{$subnet} = $subnets->{$subnet} if $subnet =~ $filter;
					}
				} elsif (ref($filter)) {
					bail("Invalid subnet filter type: %s", ref($filter));

				# Beyond here, everything is a string/number
				} elsif (defined($subnets->{$filter})) {
					$selected_subnets->{$filter} = $subnets->{$filter};
				} else {
					bail("Invalid subnet name: %s", $filter);
				}
			}
			$subnets = $selected_subnets;
		}

		$config->{subnets} = [];

		my $allocation = delete($definition->{allocation});

		my $vm_count = $allocation->{size} // 0;
		$vm_count = 2 ** (32 - $1) if $vm_count =~ m#^/(\d+)$#;
		my $statics = $allocation->{statics} // 0; # Does not include the reserved ips
		$statics = 2 ** (32 - $1) if $statics =~ m#^/(\d+)$#;

		bail(
			'More static IPs requested (%d) than the allocation for the subnet for '.
			'network %s allows (%d)',
			$statics, $target, $vm_count
		) if ($statics > $vm_count);

		# Get existing allocations from exodus data
		my $existing_allocations = $self->_get_existing_allocations(); # Different for director and non-drector deployments; prototyping in director

		# We only use the ocfp-* subnets for the network definition
		my $ocfp_subnet_prefix = $self->env->ocfp_subnet_prefix;
		my @ocfp_subnet_names = sort grep {/^${ocfp_subnet_prefix}-/} keys %$subnets;
		bail(
			'No ocfp-* subnets found in the ocfp configuration for network %s',
			$target
		) unless @ocfp_subnet_names;

		for my $subnet_name (@ocfp_subnet_names) {
			my $subnet = $subnets->{$subnet_name};
			my ($available) = $self->_get_subnet_ranges($subnet);

			# Remove existing allocations from available range that are not for the
			# target network
			for my $claiming_network (keys %$existing_allocations) {
				next if ($network_id eq $claiming_network);
				my $alloc = $existing_allocations->{$claiming_network}{$subnet_name};
				$available = $available->subtract($alloc) if ($alloc);
			}

			# Compare existing and desired allocations, and adjust as needed
			my $allocated_range = $self->_calculate_subnet_allocation(
				$target,
				$available,
				$existing_allocations->{$network_id}{$subnet_name} // IP4::MultiRange->new(),
				$vm_count,
			);

			my $full_range = IP4::Range->new($subnet->{cidr_block});
			my $reserved = $full_range->subtract($allocated_range);

			# TODO: We currently just shove statics into the front of the range, but
			# this doesn't account for ips already in use.  We can either actively
			# check for ips in the network range against the bosh deployments, or we
			# allow users to override the statics with a list of offsets to use
			# rather than just a count or mask.(ie 0-3,9) maybe even negative for
			# adding to the end? (-1--3)
			my $static_range = $self->_calculate_static_allocation(
				$target,
				$allocated_range,
				$statics,
			);

			# Check for reserved_ips and "unreserve" them from the reserved range
			# and put them into the static list
			my $reserved_ips = IP4::MultiRange->new(
				map {$subnet->{'reserved-ips'}{$_}}
				grep {$_ =~ m/${target}_ip/}
				keys %{$subnet->{'reserved-ips'}//{}}
			);
			if ($reserved_ips->size) {
				$static_range = $static_range->add(@$reserved_ips);
				$reserved = $reserved->subtract(@$reserved_ips);
			}

			my $fields = {
				az => $self->lookup_az($subnet->{az}), # TODO: Needs to change if we support multiple AZs
				range => $subnet->{cidr_block},
				gateway => $subnet->{gateway},
				dns => [$subnet->{dns}], # TODO: Support multiple DNS servers
				reserved => [map {$_->range} $reserved->ranges],
				cloud_properties_for_iaas => $definition->{cloud_properties_for_iaas},
				($static_range->size ? (static => [map {$_->range} $static_range->ranges]) : ())
			};
			my $subnet_config = $self->_subnet_definition($target, $subnet_name, $fields, $strategy);

			# TODO: Apply overrides to the subnet config
			push @{$config->{subnets}}, $subnet_config if $full_range->size > $reserved->size;
		}
	} elsif ($options{subnets}) {
		bug(
			"Subnets are not implemented for network definitions using the %s strategy",
			$strategy
		)
	} else {
		# This is a non-subnetted network
		bug(
			"Single Subnet is not implemented for network definitions using the %s strategy",
			$strategy
		);
	}

	#TODO: Before we return, we must store a local copy in the object for
	#reference to build other parts of the cloud config.
	$self->update_network($target, $config);

	return $config;

}
# }}}
# network - Returns the network definitions for the environment {{{
sub network {
	my ($self) = @_;
	# TODO: Do we need to build an adapter between the raw exodus data and the
	# network data structure we use internally?  Ideally, we don't want to do
	# that.
	$self->{network} //= $self->_get_bosh_network_data();
}

# }}}
# update_network - Updates the network definitions for the environment {{{
sub update_network {
	my ($self, $target, $config) = @_;
	my $network = $self->name_for('net', $target);

	# clear out any existing allocations for this network
	delete($_->{claims}{$network}) for (values %{$self->network->{subnets}});

	# Calculate and store the new allocations
	for my $subnet (@{$config->{subnets}}) {
		my $subnet_id = delete($subnet->{name});
		my $range = $subnet->{range};
		$self->network->{subnets}{$subnet_id}{claims}{$network} =
		IP4::Range->new($range)
			->subtract(IP4::MultiRange->new(@{$subnet->{reserved}}))
			->range;
	}
}

# }}}
# get_allocated_networks - Returns the allocated networks for the environment {{{
sub get_allocated_networks {
	my ($self) = @_;
	my $network_allocations = {};
	for my $subnet (keys %{$self->network->{subnets}}) {
		my $subnet_az = $self->network->{subnets}{$subnet}{az};
		for my $network (keys %{$self->network->{subnets}{$subnet}{claims}}) {
			$network_allocations->{$network}{$subnet} = {
				allocated => $self->network->{subnets}{$subnet}{claims}{$network},
				az => $subnet_az
			}
		}
	}
	return $network_allocations;
}


sub lookup_az {
	my ($self, $az) = @_;
	bail(
		"No availability zones available; you may need to run a deploy on the ".
		"#M{%s} BOSH director to update its network information.",
		$self->env->bosh->alias
	) unless keys %{$self->network->{azs}};
	return $self->network->{azs}{$az}{name};
}

# }}}
# get_available_azs - Returns the available AZs for network namespace {{{
#
sub get_available_azs {
	return $_[0]->network->{azs};
}

# }}}
# get_available_azs_in_network - Returns the available AZs for a given network {{{
sub get_available_azs_in_network {
	my ($self, $target) = @_;
	my $allocated_subnets = $self->get_allocated_networks->{$self->name_for('net',$target)};
	return [(uniq sort map {$allocated_subnets->{$_}{az}} keys %$allocated_subnets)];
}

# }}}
# get_network_size - Returns the size of the network for the given target {{{
sub get_network_size {
	my ($self, $target, @filters) = @_;

	my $network = $self->get_allocated_networks->{$self->name_for('net',$target)};
	my $size = 0;
	my %valid_azs = ();

	if (@filters) {
		for my $az (@filters) {
			$valid_azs{$az} = 1;
			$valid_azs{$self->lookup_az($az)} = 1 if $self->lookup_az($az);
		}
	} else {
		$valid_azs{$network->{$_}{az}} = 1 for keys %$network;
	}

	for my $subnet (values %{$network}) {
		$size += IP4::Range->new($subnet->{allocated})->size if $valid_azs{$subnet->{az}};
	}
	return $size;
}

# }}}
# subnets - Returns the subnets for the network {{{
sub subnets {
	my ($self) = @_;
	return $self->{subnets} ||= $self->env->ocfp_config_lookup('vpc.subnets');
}

# }}}
# network_cloud_properties_for_iaas - Returns the cloud properties for a given network and cpi {{{
sub network_cloud_properties_for_iaas {
	return shift->_cloud_properties_for_iaas('network', @_);
}

# }}}
# vm_type_definition - Returns the definition for a given vm type {{{
sub vm_type_definition {
	return shift->_config_definition(VM_TYPE, 'vm', @_);
}

# }}}
# vm_extension_definition - Returns the definition for a given vm extension {{{
sub vm_extension_definition {
	return shift->_config_definition(VM_EXTENSION, 'vmx', @_);
}

# }}}
# disk_type_definition - Returns the definition for a given disk type {{{
sub disk_type_definition {
	return shift->_config_definition(DISK_TYPE, 'disk', @_);
}

# }}}
# }}}
#
# Private Methods {{{
# _config_definition - Returns the definition for a given config type {{{
sub _config_definition {
	my ($self, $type, $prefix, $target, %maps) = @_;

	$self->_validate_definition($type, $target, %maps);
	my %config = %{$maps{common}//{}};
	$config{name} = $self->name_for($prefix, $target);
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
	} elsif ($type eq VM_EXTENSION) {
		return {%config}; # VM Extensions can be empty
	} else {
		return ();
	}
}

# }}}
# _subnet_definition - Returns the definition for a given subnet {{{
sub _subnet_definition {
	my ($self, $target, $subnet_id, $fields, $strategy) = @_;

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
		name => $subnet_id, # Not actually a valid property, but we need it for reference?
		range => $self->_get_network_subnet_property($target, $subnet_id, $fields, 'range', required => 1),
		reserved => $self->_get_network_subnet_property($target, $subnet_id, $fields, 'reserved', required => 1),
	};

	if ($fields->{az}) {
		$base_config->{az} = $self->_get_network_subnet_property($target, $subnet_id, $fields, 'az');
	} elsif ($fields->{azs}) {
		$base_config->{azs} = $self->_get_network_subnet_property($target, $subnet_id, $fields, 'azs');
	} else {
		bail("No availability zone(s) specified for network %s subnet %s", $target, $subnet_id);
	}
	my $gateway = $self->_get_network_subnet_property($target, $subnet_id, $fields, 'gateway')
	  // IP4::Range->($base_config->{range})->start->add(1)->address;
	my $dns = $self->_get_network_subnet_property($target, $subnet_id, $fields, 'dns')
	  // [$gateway, '1.1.1.1'];
	$base_config->{gateway} = $gateway;
	$base_config->{dns} = $dns;
	$base_config->{static} = $self->_get_network_subnet_property($target, $subnet_id, $fields, 'static')
		if exists $fields->{static};

	if (exists $fields->{cloud_properties_for_iaas}) {
		my $cloud_properties = flatten({},'',$fields->{cloud_properties_for_iaas});
		for my $key (keys %$cloud_properties) {
			my $value = $cloud_properties->{$key};
			if (ref($value) eq "Genesis::Hook::CloudConfig::LookupSubnetRef") {
				my $data = $strategy eq 'ocfp'
					? scalar $self->env->ocfp_config_lookup("vpc.subnets.$subnet_id")
					: bail "LookupSubnetRef not implemented for strategy $strategy";
				$cloud_properties->{$key} = $value->resolve($self, $data);
			} elsif (ref($value) eq "Genesis::Hook::CloudConfig::LookupNetworkRef") {
				my $data = $strategy eq 'ocfp'
					? scalar $self->env->ocfp_config_lookup('vpc')
					: bail "LookupNetworkRef not implemented for strategy $strategy";
				$cloud_properties->{$key} = $value->resolve($self, $data);
			}
		}
		$base_config->{cloud_properties} = $self->_network_cloud_properties_for_iaas(
			$target, $subnet_id, %{unflatten($cloud_properties)}
		);
	}

	# After any overrides, we need to make sure there is a configuration to set
	# Return an empty list if there is no configuration.
	delete($base_config->{cloud_properties}) unless keys %{$base_config->{cloud_properties}};
	return $base_config;
}

# }}}
# _get_network_subnet_property - Returns the value for a given property for a network or subnet {{{
sub _get_network_subnet_property {
	my ($self, $target, $subnet_id, $fields, $property, %opts) = @_;
	my $value = $fields->{$property};

	# Check for overrides from the environment, and the bosh exodus data
	my $target_path = "networks.$target.subnet";
	my $override= $self->_process_config_overrides(
		$target_path, $subnet_id, $value, "subnets.$subnet_id.$property"
	);
	$override = $self->_process_config_overrides(
		'network_defaults.subnet', $subnet_id, $value, "subnet_defaults.$property"
	) unless defined($override);
	$value = $override if defined($override);

	if (!defined($value) && $opts{required}) {
		bail("No %s specified for network %s subnet %s", $property, $target, $subnet_id);
	}
	return $value;
}
# }}}
# _network_cloud_properties_for_iaas - Returns the cloud properties for a given network and cpi {{{
sub _network_cloud_properties_for_iaas {
	my ($self, $target, $subnet_id, %map) = @_;
	my $config = $self->_cloud_properties_for_iaas('network_defaults.subnet', $subnet_id, %map);
	return $self->_process_config_overrides(
		"networks.$target.subnet", $subnet_id, $config, 'cloud_properties'
	);
}

# }}}
# _cloud_properties_for_iaas - Returns the cloud properties for a given type and cpi {{{
sub _cloud_properties_for_iaas {
	my ($self, $type, $target, %map) = @_;
	my $map_key = (grep {$_ eq $self->iaas} keys %map)[0]
		// (grep {$_ =~ /(?:^|\|)$self->iaas(?:\||$)/} keys %map)[0]
		// '*';
	my $cloud_properties = $map{$map_key}; #TODO: allow glob-style matching
	$self->env->kit->kit_bug(
		"No Cloud Config for IaaS type %s defined in %s",
		$self->iaas, $self->env->kit->id
	) unless ($cloud_properties);

	return $self->_process_config_overrides(
		$type, $target, $cloud_properties, 'cloud_properties'
	);
}

# }}}
# _process_config_overrides - Applies overrides to a given config based on the environment and bosh {{{
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
			"bosh-configs.cloud." . count_nouns(2,$type, suppress_count => 1).".$target.$path",
			"bosh-configs.cloud.${type}_defaults.$path"
		]);

		# Unimplemented in upstream deployments so far, so disabling for now
		#($override, $src) = $self->_bosh_exodus_lookup( # This will be cached so don't fetch exodus data for each lookup
		#	"/configs/cloud/$type/$path" =~ s/\./\//gr,
		#) unless defined($override);

		if ($override) {
			trace(
				"Applying override for %s %s %s: %s (from %s)",
				$type, $target, $path, JSON::PP->new->allow_nonref->encode($override), $src
			);
			$config = $override;
		}
	}
	return $config;
}

# }}}
# _validate_definition - Validates the definition for a given vm type {{{
sub _validate_definition {
	my ($self, $type, $target, %maps) = @_;

	# Vaidate that %maps contains the only common and cloud_properties_for_iaas keys
	my @extra_keys = grep {$_ !~ m/^(common|cloud_properties_for_iaas)$/} keys %maps;
	$self->env->kit->kit_bug(
		"Unexpected Cloud Config keys in %s %s in %s: %s\n".
		"Expected: common, cloud_properties_for_iaas",
		$target, $self->env->kit->id, $type, join(", ", @extra_keys)
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
# _bosh_exodus_lookup - Returns the value for a given path in the bosh exodus data {{{
sub _bosh_exodus_lookup {
	my ($self, $path) = @_;
	return undef if $self->env->use_create_env;

	# This will return the value for a given path in the exodus data for the bosh
	# director that is deploying the environment. This will be used to get the
	# overrides if present.
	return $self->env->director_exodus_lookup("$path");
}

# }}}
# _subnet_ranges - Returns the reserved and available IP ranges for a given subnet {{{
sub _get_subnet_ranges {
	my ($self, $subnet) = @_;
	my $range = IP4::Range->new($subnet->{cidr_block});
	my @reserved_ip_pairs = @{$subnet->{'reserved-ips'}}{sort grep {$_ =~ /^reserved/} keys %{$subnet->{'reserved-ips'}}};
	my @available_ip_pairs = @{$subnet->{'reserved-ips'}}{sort grep {$_ =~ /^available/} keys %{$subnet->{'reserved-ips'}}};

	@available_ip_pairs = ($range->start->address, $range->end->address)
		unless @reserved_ip_pairs || @available_ip_pairs;
	@reserved_ip_pairs = (
		$range->start->address, $range->start->add(4)->address,
		$range->end->address, $range->end->address,
	) unless @reserved_ip_pairs;

	# We only need reserved or available, with available being the default
	my $reserved_range = IP4::MultiRange->new();
	$reserved_range = $reserved_range->add(
		IP4::Range->new([splice(@reserved_ip_pairs,0,2)])
	) while @reserved_ip_pairs;
	my $available_range = IP4::MultiRange->new();
	$available_range = $available_range->add(
		IP4::Range->new([splice(@available_ip_pairs,0,2)])
	) while @available_ip_pairs;

	$available_range = $range->subtract($reserved_range) if (!@$available_range);
	$available_range = $available_range->subtract($reserved_range) if (@$reserved_range);

	return ($available_range, $reserved_range);
}

# }}}
# _get_existing_allocations - Returns the existing allocations for a given network {{{
sub _get_existing_allocations {
	my ($self) = @_;
	my $data = $self->network;
	
	my $ranges = {};
	for my $subnet (keys %{$data->{subnets}}) {
		for my $network (keys %{$data->{subnets}{$subnet}{claims}}) {
			$ranges->{$network}{$subnet} = IP4::MultiRange->new($data->{subnets}{$subnet}{claims}{$network});
		}
	}

	return $ranges;
}

# }}}
# _calculate_subnet_allocation - Calculates the IP range for a given subnet and network {{{
sub _calculate_subnet_allocation {
	my ($self, $target, $available, $existing, $count) = @_;
	my $needed = $count - $existing->size();

	# FIXME: We currently don't check if the current allocation is within
	# the available range.  This is an oversight that needs to be corrected,
	# but for MVP, we will assume that the existing allocations are within
	# the available range.

	if ($needed > 0) {
		bail(
			'Not enough available IPs in the subnet for the network \'%s\' allocation: (has %d, needs %d)',
			$target, $available->size(), $needed
		) if ($available->size() < $needed);
		my ($additional, $still_needed) = $available->slice($needed);
		bug("Failed to allocate available range for network '%s' allocation", $target) if $still_needed;
		return IP4::MultiRange->new($existing)->add($additional);
	}
	return $existing if $needed == 0;
	return ($existing->slice($count))[0];
}

# }}}
# _calculate_static_allocation - Calculates the static IP range for a given subnet and network {{{
sub _calculate_static_allocation {
	my ($self, $target, $allocated, $count) = @_;
	if ($count =~ m#^(\d+)%#) {
		$count = round($allocated->size() * ($1 / 100));
	}
	# TODO: Support offsets for static IPs instead of just a counts
	my $static_range = IP4::MultiRange->new();
	if ($count > 0) {
		($static_range) = $allocated->slice($count);
	}
	return $static_range;
}

# }}}
# _get_bosh_network_data - Returns the network data for the BOSH director (self) {{{
sub _get_bosh_network_data {
	return $_[0]->env->director_exodus_lookup('/network');
}

# }}}
# }}}
1;

# vim - fdm=marker:foldlevel=1:ts=2:sts=2:sw=2:noet
