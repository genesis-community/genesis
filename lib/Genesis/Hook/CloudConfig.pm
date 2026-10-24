package Genesis::Hook::CloudConfig;
use v5.20;
use warnings;

use Genesis;
use Genesis::Hook::CloudConfig::LookupRef;
use Genesis::Hook::CloudConfig::LookupNetworkRef;
use Genesis::Hook::CloudConfig::LookupSubnetRef;
use IPv4;
use POSIX qw(round);

use parent qw(Genesis::Hook);

# FIXME: What happens if the subnets are restricted to a specific list of AZs in the env file.

# Constants {{{
use constant {
	VM_TYPE          => 'vm_type',
	VM_EXTENSION     => 'vm_extension',
	DISK_TYPE        => 'disk_type',
	NETWORK          => 'network',
	FIRST_SORT_TOKEN => '0000',
	LAST_SORT_TOKEN  => "zzzz",
};

# }}}

# OCFP reserved-ip target aliases - core fallback for renamed kits without an override {{{
my %OCFP_RESERVED_IP_TARGET_ALIASES = (
	openbao => 'vault',
);

# }}}
# _as_list - normalize scalar-or-arrayref into a list {{{
sub _as_list {
	my ($v) = @_;
	return () unless defined $v;
	return ref($v) eq 'ARRAY' ? @$v : ($v);
}

# }}}
# _is_neighbour_annotation - true when <target>_ip_a/_b records the address either side of <target>_ip {{{
sub _is_neighbour_annotation {
	my ($key, $value, $anchor) = @_;
	return 0 unless defined($value) && defined($anchor);
	my ($suffix) = $key =~ m/_ip_([a-z])$/;
	return 0 unless defined($suffix) && $suffix =~ /^[ab]$/;
	my ($v, $a);
	eval { $v = IPv4->address($value)->int; $a = IPv4->address($anchor)->int; 1 } or return 0;
	return $suffix eq 'a' ? ($v + 1 == $a) : ($v - 1 == $a);
}

# }}}
# ocfp_reserved_ip_target_aliases - kit hook returning alias target names {{{
sub ocfp_reserved_ip_target_aliases {
	my ($self, $target) = @_;
	return;
}

# }}}

# Class Overrides {{{
# init - Initializes the CloudConfig hook, injecting the common properties {{{

my %cloud_configs = ();

sub init {
	my ($class, %opts) = @_;
	$class->check_for_required_args(\%opts, qw/env/);
	my $env = $opts{env};
	bail(
		"Create-env environments do not have deployment cloud configs,as there is ".
		"no director to upload them to."
	) unless $class->_can_build_cloud_config($env);

	my $purpose = $opts{purpose} // $ENV{GENESIS_CLOUD_CONFIG_SUBTYPE};
	my $basename = $opts{basename} // join('.', $env->name, $env->type);
	my $id = join('@', $purpose ? ($basename, $purpose) : ($basename));
	my $az_prefix = $env->name . '-z';

	return $cloud_configs{$id} if ($cloud_configs{$id});

	my $obj = $class->SUPER::init(
		%opts, basename => $basename, id => $id, az_prefix => $az_prefix, contents => {}
	);

	$obj->{overrides} = {
		environment => $env->env_config_overrides('cloud'),
		director    => $env->director_config_overrides('cloud'),
	};

	$obj->{network} //= $obj->_get_bosh_network_data();
	if ($env->is_ocfp) {
		$obj->{ocfp_config} = $env->ocfp_config_lookup(['net','vpc']);
	}
	$obj->_validate_override_schema();

	return $cloud_configs{$id} = $obj;
}

# }}}
# done - Marks the CloudConfig hook as completed, and sets the contents {{{
sub done {
	my ($self, $contents) = @_;
	bail(
		"CloudConfig hook must return a hashref containing the cloud config - got %s",
		ref($contents) || 'scalar value'
	) unless ref($contents) eq 'HASH';

	# Strip subnet names and fold same-range subnets into LSAs for BOSH.
	# RISK: This will change the network config, so if any hook perform method
	#       does stuff with the network config after calling `done`, the subnets
	#       will have been converted to LSAs, and the hook will not be able to
	#       access the original subnets.
	$self->_process_network_subnets($contents->{networks});

	# The sort tokens pin name first and cloud_properties last in the YAML
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

	my $filename = $self->env->workdir . "/cloud-config-".$self->{id}.".yml";
	save_to_yaml_file($contents, $filename);
	$contents = slurp($filename)
		=~ s/\b${sort_name_first}:/name:/gr
		=~ s/\b${sort_cloud_properties_last}:/cloud_properties:/gr
		=~ s/\n([^ -])/\n\n$1/gmr;
	unlink($filename);
	$self->{contents} = $contents;

	return $self->SUPER::done();
}

# }}}
# results - Returns the contents of the cloud config {{{
sub results {
	trace('called results before hook completed') unless $_[0]->completed;
	return undef unless $_[0]->completed;
	return wantarray
		? ($_[0]->{contents}, $_[0]->{network})
		: {config => $_[0]->{contents}, network => $_[0]->{network}};
}

# }}}
# _can_build_cloud_config - Returns whether the cloud config can be built for the environment {{{
sub _can_build_cloud_config {
	my ($class, $env) = @_;
	!($env->use_create_env);
}

# }}}
# }}}

# Accessors {{{
sub basename { return shift->{basename}; }
sub contents { return shift->{contents}; }
sub overrides_base { return 'bosh-configs.cloud'; }

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
# for_iaas - Returns the value for a given IaaS from a map, or a default value if not found {{{
sub for_iaas {
	my ($self, $map, $default) = @_;
	my $iaas = $self->iaas;
	return $map->{$iaas} // $default;
}

# }}}
# lookup_ref - Returns a lookup reference for a given path {{{
sub lookup_ref {
	my ($self, $paths, $default) = @_;
	return Genesis::Hook::CloudConfig::LookupRef->new($paths, $default);
}

# }}}
# network_reference - Returns a reference to a network value that can be resolved later {{{
sub network_reference {
	my $self = shift;
	return Genesis::Hook::CloudConfig::LookupNetworkRef->new(@_);
}

# }}}
# subnet_reference - Returns a reference to a subnet value that can be retrived per subnet {{{
sub subnet_reference {
	my $self = shift;
	return Genesis::Hook::CloudConfig::LookupSubnetRef->new(@_);
}

# }}}
# build_cloud_config - Builds the cloud config for the environment {{{
sub build_cloud_config {
	my ($self,$config) = @_;
	$self->_add_extended_cloud_config($config);
	return $config;
}

# }}}
# build_cpi_azs - Builds the cpi-specific AZs for the environment {{{
sub build_cpi_azs {
	my ($self, %options) = @_;
	return () unless $self->env->cpi_enabled;

	my $parent_azs = $self->get_available_azs;
	my @azs = ();
	for my $az_name (sort keys %$parent_azs) {
		my $az_defn = $parent_azs->{$az_name};
		my $idx = $az_defn->{index} # This is the index of the az, we currently do not populate it
			// ($az_name =~ m/[^0-9]([0-9]*)$/)[0]
			|| ($az_defn->{name} =~ m/[^0-9]([0-9]*)$/)[0];
		my $config = $self->_az_definition_for(
			$az_defn, %options, name => $self->{az_prefix} . $idx, az_key => $az_name
		);
		push @azs, $config;
		$self->_add_cpi_to_network_az($az_name, $config->{name});
	}

	return (azs => \@azs);
}

# }}}
# cpi_name_for_az - Returns the CPI name to inject for a given AZ {{{
sub cpi_name_for_az {
	my ($self, $az_key, $az_data) = @_;
	return $self->cpi_name;
}

# }}}
# _add_cpi_to_network_az - Adds a CPI entry to a network AZ {{{
sub _add_cpi_to_network_az {
	my ($self, $az_name, $cpi_az_name) = @_;
	my $network = $self->network;
	$network->{azs}{$az_name}{for_cpi}{$self->cpi_name} = $cpi_az_name;
}

# }}}
# relinquish_networks - Relinquishes the named network(s) {{{
sub relinquish_networks {
	my ($self, @networks) = @_;
	my $network = $self->network;
	for my $target (@networks) {
		# Both keys: a kit may have claimed under either (see update_network)
		my @keys = ($target, $self->name_for('net', $target));
		delete(@{$network->{subnets}{$_}{claims}}{@keys})
			for keys %{ $network->{subnets} };
	}
}

# }}}
# network_definition - Returns the definition for a given network {{{
sub network_definition {
	my ($self, $target, %rules) = @_;
	my $strategy = delete($rules{strategy}) // 'generic';
	my $name_prefix = delete($rules{name_prefix});

	my $network_id = defined($name_prefix)
		? $name_prefix.$target
		: $self->name_for('net', $target);

	my $config = {
		name => $network_id,
		type => $strategy eq 'vip' ? 'vip' : 'manual',
	};
	return $config if ($strategy eq 'vip');

	# FIXME: Should this just die if the strategy does not match?
	if (($strategy eq 'ocfp') xor $self->env->is_ocfp) {
		# ocfp network on a non-ocfp deployment, or vice versa
		return ();
	}

	# Kit hooks may supply their own strategy builder
	my $strategy_method = "_build_${strategy}_network_definition";
	if ($self->can($strategy_method)) {
		# The builder fills $config in place; its return value is not used
		$self->$strategy_method($target, $config, %rules);
	} else {
		bail(
			'Network definition strategy %s is not supported by the cloud config hook',
			$strategy
		);
	}

	$self->update_network($target, $config, %rules);

	return $config;
}

# }}}
# _build_generic_network_definition - Builds a generic network definition {{{
sub _build_generic_network_definition {
	my ($self, $target, $config, %options) = @_;
	bug(
		"Generic network definition building is not yet implemented"
	);
}

# }}}
# _available_ocfp_network_models - Returns the available OCFP network models {{{
sub _available_ocfp_network_models {
	return qw(dynamic_subnets subnets greedy_subnets);
}

# }}}
# _build_ocfp_network_definition - Builds an OCFP network definition {{{
sub _build_ocfp_network_definition {
	my ($self, $target, $config, %options) = @_;
	my $strategy = 'ocfp';

	my @requested_network_models = grep {exists $options{$_}} $self->_available_ocfp_network_models;
	bail(
		'Network definition for %s can only have one network model, but found %d: %s',
		$target, scalar(@requested_network_models), join(', ', @requested_network_models)
	) if (scalar(@requested_network_models) > 1);
	bail(
		'Network definition for %s must have one of the following network models: %s',
		$target, join(', ', $self->_available_ocfp_network_models)
	) unless @requested_network_models;

	my $network_model_builder = "_build_${strategy}_network_model_"
		. $requested_network_models[0];
	bug(
		"Network model %s is not supported for OCFP network definitions",
		$requested_network_models[0]
	) unless $self->can($network_model_builder);

	return $self->$network_model_builder(
		$target, $config, %options
	);
}

# }}}
# _build_ocfp_network_model_greedy_subnets - Builds an OCFP network definition with greedy allocation {{{
sub _build_ocfp_network_model_greedy_subnets {
	my ($self, $target, $config, %options) = @_;
	my $strategy = 'ocfp:greedy_subnets';
	my $definition = $options{greedy_subnets};
	my $network_id = $config->{name};
	my $subnets = $self->_filter_subnets($definition->{subnets});
	$config->{subnets} = [];

	# We only use the ocfp-* subnets for the network definition
	my $ocfp_subnet_prefix = $self->env->ocfp_subnet_prefix;
	my @ocfp_subnet_names = sort grep {/^${ocfp_subnet_prefix}(?:-|$)/} keys %$subnets;
	bail(
		'No ocfp-* subnets found in the ocfp configuration for network %s',
		$target
	) unless @ocfp_subnet_names;

	# Get existing allocations from exodus data
	my $existing_allocations = $self->get_allocated_networks;
	# A claim recorded by an earlier release under the prefixed name is ours too.
	my @own_claim_keys = ($network_id, $self->name_for('net', $target));
	for my $subnet_name (@ocfp_subnet_names) {
		my $subnet = $subnets->{$subnet_name};
		my $full_range = IPv4->new($subnet->{cidr_block});
		my ($available, $reserved) = $self->_get_subnet_ranges($subnet);

		# Remove existing allocations from available range that are not for the
		# target network
		for my $claiming_network (keys %$existing_allocations) {
			next if grep {$_ eq $claiming_network} @own_claim_keys;
			my $alloc = $existing_allocations->{$claiming_network}{$subnet_name}{allocated};
			$available -= $alloc if ($alloc);
		}

		# Find any existing allocations, but ignore those explicitly reserved
		my $existing = IPv4->new();
		for my $key (@own_claim_keys) {
			my $claim = $existing_allocations->{$key}{$subnet_name}{allocated};
			$existing += $claim if $claim;
		}
		$existing -= $reserved if $existing && $reserved;

		my $allocated_range = $available - $existing - $reserved;
		$reserved += $full_range->subtract($allocated_range);

		my $fields = {
			az => $self->lookup_az($subnet->{az}), # TODO: Needs to change if we support multiple AZs
			range => $self->_standardized_subnet_cidr($subnet, $subnet_name, $target),
			gateway => $subnet->{gateway},
			dns => ref($subnet->{dns}) eq 'ARRAY' ? $subnet->{dns} : [$subnet->{dns}],
			reserved => [map {$_->range} $reserved->simplify->spans],
			cloud_properties_for_iaas	=> $definition->{cloud_properties_for_iaas} // {},
		};

		my $subnet_config = $self->_subnet_definition(
			$target, $subnet_name, $fields, $strategy
		);

		push @{$config->{subnets}}, $subnet_config if $full_range->size > $reserved->size;
	}
}

# }}}
# _build_ocfp_network_model_dynamic_subnets - Builds an OCFP network definition with dynamic subnets {{{
sub _build_ocfp_network_model_dynamic_subnets {
	my ($self, $target, $config, %options) = @_;

	my $definition = $options{dynamic_subnets};
	my $strategy = 'ocfp:dynamic_subnets';
	my $network_id = $config->{name};
	my $subnets = $self->_filter_subnets($definition->{subnets});
	$config->{subnets} = [];

	# We only use the ocfp-* subnets for the network definition
	my $ocfp_subnet_prefix = $self->env->ocfp_subnet_prefix;
	my @ocfp_subnet_names = sort grep {/^${ocfp_subnet_prefix}(?:-|$)/} keys %$subnets;
	bail(
		'No ocfp-* subnets found in the ocfp configuration for network %s',
		$target
	) unless @ocfp_subnet_names;

	my $allocation = delete($definition->{allocation});
	# Check for allocation overrides
	my $network_overrides = $self->env->lookup($self->overrides_base.'.networks.'.$target);
	$allocation->{total_size} = $network_overrides->{allocation}{total_size}
		if (defined $network_overrides->{allocation}{total_size});
	$allocation->{vms_per_subnet} = $network_overrides->{allocation}{vms_per_subnet}
		if (defined $network_overrides->{allocation}{vms_per_subnet});
	$allocation->{size} = $network_overrides->{allocation}{size}
		if (defined $network_overrides->{allocation}{size});

	# Assign VMs per subnet based on allocation strategy
	# FIXME: Really should know used and free ips, so we can properly balance
	#        allocations across subnets, but this is a good start.
	my %vms_per_subnet = ();
	my $allocation_source; # how the per-subnet count was derived, for diagnostics
	if (defined $allocation->{total_size}) {
		my $vm_count = $allocation->{total_size};
		my $total_subnets = scalar(@ocfp_subnet_names);
		my $per_subnet_count = round($vm_count / $total_subnets);
		my $remaining = $vm_count % $total_subnets;
		for my $subnet_name (@ocfp_subnet_names) {
			$vms_per_subnet{$subnet_name} = $per_subnet_count;
			$vms_per_subnet{$subnet_name}++ if $remaining-- > 0;
		}
		$allocation_source = sprintf(
			"allocation.total_size of %d spread across %d subnets",
			$vm_count, $total_subnets
		);
	} elsif (defined $allocation->{vms_per_subnet}) {
		for my $subnet_name (@ocfp_subnet_names) {
			$vms_per_subnet{$subnet_name} = $allocation->{vms_per_subnet}{$subnet_name} // 0;
		}
		$allocation_source = "allocation.vms_per_subnet";
	} else {
		my $vm_count = $allocation->{size} // 0;
		$vm_count = 2**(32 - $1) if $vm_count =~ m#^/(\d+)$#;
		for my $subnet_name (@ocfp_subnet_names) {
			$vms_per_subnet{$subnet_name} = $vm_count;
		}
		$allocation_source = defined($allocation->{size})
			? sprintf("allocation.size of %s", $allocation->{size})
			: "no allocation given";
	}
	# Statics are the first addresses of the claim as BOSH sees it, which takes
	# in the target's own reserved-ips records inside the band; records with
	# <target>_static set (the default) join the static list on top of these
	my $statics = $allocation->{statics} // 0;

	# Get existing allocations from exodus data
	my $existing_allocations = $self->get_allocated_networks;
	# A claim recorded by an earlier release under the prefixed name is ours too.
	my @own_claim_keys = ($network_id, $self->name_for('net', $target));

	for my $subnet_name (@ocfp_subnet_names) {
		my $subnet = $subnets->{$subnet_name};
		my $vm_count = $vms_per_subnet{$subnet_name} // 0;
		my $full_range = IPv4->new($subnet->{cidr_block});
		my ($available, $reserved) = $self->_get_subnet_ranges($subnet);
		my $preset_reserved_size = $reserved->size;
		my $unclaimed_size = $available->size;

		# The subnet's available band, before any claim is taken out of it
		my $band = IPv4->range($available);

		# Other networks' claims, kept per network so a conflict can name it
		my %other_claims_by_network;
		my $other_claims = IPv4->new();
		for my $claiming_network (sort keys %$existing_allocations) {
			next if grep {$_ eq $claiming_network} @own_claim_keys;
			my $alloc = $existing_allocations->{$claiming_network}{$subnet_name}{allocated};
			next unless $alloc;
			$other_claims_by_network{$claiming_network} = IPv4->range($alloc);
			$other_claims += $alloc;
		}
		$available -= $other_claims if $other_claims->size;
		my $other_claims_size = $unclaimed_size - $available->size;

		# Reserved-ips records: this target's own (with its aliases), and every
		# other target's, which this network may never take
		my ($own_records, $reserved_static) = $self->_get_reserved_allocation($target, $subnet);
		$own_records = IPv4->range($own_records);
		my %other_records_by_owner;
		my $other_records = IPv4->new();
		my $all_other_records = $self->_all_reserved_ip_records($subnet, $target);
		for my $owner (keys %$all_other_records) {
			my $records = IPv4->range($all_other_records->{$owner});
			$records -= $own_records if $own_records->size;
			next unless $records->size;
			$other_records_by_owner{$owner} = IPv4->range($records);
			$other_records += $records;
		}
		$other_records = IPv4->range($other_records);
		my $own_in_band = _intersection($own_records, $band);

		# This network's saved claim, less the subnet-reserved range
		my $existing = IPv4->new();
		for my $key (@own_claim_keys) {
			my $claim = $existing_allocations->{$key}{$subnet_name}{allocated};
			$existing += $claim if $claim;
		}
		$existing = IPv4->range($existing);
		$existing -= $reserved if $existing->size && $reserved->size;

		# A saved claim holding another target's reserved address stops the
		# build, unless the network is exempt; an exempt network loses it
		$self->_prune_claim_of_reserved_records(
			$target, $network_id, $subnet_name, $existing, \%other_records_by_owner
		);
		$existing -= $other_records if $existing->size && $other_records->size;

		# Own records are added back below, so what is left is the dynamic part
		$existing -= $own_records if $existing->size && $own_records->size;

		# Two dynamic claims over the same addresses, with no record to say
		# which network owns them
		$self->_bail_on_claim_clash(
			$network_id, $subnet_name, $existing, \%other_claims_by_network
		);

		# The pool excludes every other claim and every reserved-ips record, and
		# own records inside the band count toward this network's size
		my $pool = IPv4->range($available);
		$pool -= $other_records if $pool->size && $other_records->size;
		$pool -= $own_records   if $pool->size && $own_records->size;
		my $dynamic_count = $vm_count - $own_in_band->size;
		$dynamic_count = 0 if $dynamic_count < 0;

		# Compare existing and desired allocations, and adjust as needed
		my $allocated_range = $self->_calculate_subnet_allocation(
			$target,
			$pool,
			$existing,
			$dynamic_count
		);
		$reserved += $full_range->subtract($allocated_range);

		# Statics come from the front of the claim as BOSH sees it, which
		# includes the own records inside the band
		my $static_source = IPv4->new($allocated_range);
		$static_source += $own_in_band if $own_in_band->size;
		my $static_range = $self->_calculate_static_allocation(
			$target, $subnet_name, IPv4->range($static_source), $statics, $vm_count
		);

		# An own record inside another network's claim stays with this network;
		# the other network gives it up when it is next built
		$self->_warn_own_records_in_other_claims(
			$target, $network_id, $subnet_name, $subnet, $own_records, \%other_claims_by_network
		);

		# Own reserved-ips records come out of the reserved range and go into
		# the static list, or into the dynamic range if <target>_static is 0
		my $reserved_ips = IPv4->new($own_records);

		# Lexical loop variable: a bare while(<>) would assign to the global $_,
		# which is read-only when a kit calls us from map/for over constants.
		while (defined(my $ip = <$reserved_ips>)) {
			$reserved_static ? $static_range += $ip : $allocated_range += $ip;
			$reserved     -= $ip;
		}

		my $fields = {
			az => $self->lookup_az($subnet->{az}), # TODO: Needs to change if we support multiple AZs
			range => $self->_standardized_subnet_cidr($subnet, $subnet_name, $target),
			gateway => $subnet->{gateway},
			dns => ref($subnet->{dns}) eq 'ARRAY' ? $subnet->{dns} : [$subnet->{dns}],
			reserved => [map {$_->range} $reserved->spans],
			cloud_properties_for_iaas => $definition->{cloud_properties_for_iaas},
			($static_range->size
				? (static => [map {$_->range} $static_range->spans])
				: ()
			)
		};

		my $subnet_config = $self->_subnet_definition(
			$target, $subnet_name, $fields, $strategy
		);

		if ($full_range->size > $reserved->size) {
			push @{$config->{subnets}}, $subnet_config;
		} elsif ($allocated_range->size || $static_range->size) {
			# Still fully reserved despite being handed addresses, so those
			# addresses (a claim or a reserved-ips record) lie outside the subnet
			my $outside = IPv4->new($allocated_range)->add($static_range)->simplify;
			warning(
				"Dropping subnet #C{%s} from network #C{%s}: the %d address%s ".
				"allocated to it (%s) fall outside the subnet range %s, so the ".
				"subnet would have no usable addresses.  Check the reserved-ips ".
				"records for target '%s' in subnet %s and the network claims ".
				"recorded in the director's exodus data for network %s.",
				$subnet_name, $network_id, $outside->size,
				($outside->size == 1 ? '' : 'es'), $outside->range,
				$subnet->{cidr_block}, $target, $subnet_name, $network_id
			);
		} else {
			# Nothing allocated here and no reserved-ips record lands inside
			warning(
				"Dropping subnet #C{%s} from network #C{%s}: it would have no ".
				"usable addresses.  The subnet range %s holds %d addresses, with ".
				"%d reserved by the subnet definition and %d claimed by other ".
				"networks, leaving %d available, but the allocation for this ".
				"network (%s) requests %d address%s in this subnet and no ".
				"reserved-ips records for target '%s' (keys %s_a/%s_b or %s_ip, ".
				"or those of an alias target) fall inside it.  To keep the ".
				"subnet, give network %s a non-zero allocation under ".
				"#C{%s.networks.%s.allocation} (size, total_size, or ".
				"vms_per_subnet), or add reserved-ips records for '%s' to ".
				"subnet %s.",
				$subnet_name, $network_id, $subnet->{cidr_block},
				$full_range->size, $preset_reserved_size, $other_claims_size,
				$available->size, $allocation_source, $vm_count,
				($vm_count == 1 ? '' : 'es'), $target, $target, $target,
				$target, $network_id, $self->overrides_base, $target, $target,
				$subnet_name
			);
		}
	}

	return 1;
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
	my ($self, $target, $config, %options) = @_;

	# Keyed by the name that reaches the cloud config; the legacy prefixed key
	# is cleared too so an older claim is adopted, not orphaned (see POD)
	my $network = $config->{name} // $self->name_for('net', $target);
	my @stale_keys = grep {$_ ne $network} ($self->name_for('net', $target));
	delete(@{$_->{claims}}{$network, @stale_keys}) for (values %{$self->network->{subnets}});

	return if exists($options{greedy_subnets}); # greedy networks record no claims

	for my $subnet (@{$config->{subnets}}) {
		my $subnet_id = $subnet->{name};
		my $range     = $subnet->{range};
		$self->network->{subnets}{$subnet_id}{claims}{$network} = IPv4
			->new($range)
			->subtract(@{$subnet->{reserved}})
			->range;
	}
}

# }}}
# get_allocated_networks - Returns the allocated networks for the environment {{{
sub get_allocated_networks {
	my ($self) = @_;
	my $subnets = $self->network->{subnets};
	my $network_allocations = {};
	for my $subnet (keys %$subnets) {
		for my $network (keys %{$subnets->{$subnet}{claims}}) {
			$network_allocations->{$network}{$subnet} = {
				allocated => $subnets->{$subnet}{claims}{$network},
				az => $subnets->{$subnet}{az}
			};
		}
	}
	return $network_allocations;
}

# }}}
# get_network_security_groups - Returns the network security groups for the environment {{{
sub get_network_security_groups {
	my ($self, $type, @names) = @_;
	return $self->network_reference('sgs', sub {
		my ($self, $network_data, $ref, $type, @names) = @_;
		my $sgs = $network_data->{sgs} || {};
		$type //= 'id';
		my @values = uniq sort map {
			$sgs->{$_}{$type}
		} grep {
			!@names || in_array($sgs->{$_}{name}, @names)
		} keys %$sgs;
		return \@values;
	}, $type, @names);
}

# }}}
# lookup_az - resolve an availability zone definition by name {{{
sub lookup_az {
	my ($self, $az) = @_;
	my $az_data = $self->network->{azs}{$self->_find_az_key($az)};
	my $cpi_az  = $self->cpi_enabled ? $az_data->{for_cpi}{$self->cpi_name} : undef;
	return $cpi_az // $az_data->{name}; # Director cpi is default
}

# }}}
# az_cloud_properties - Returns the decoded cloud properties of an availability zone {{{
sub az_cloud_properties {
	my ($self, $az) = @_;
	my $base_az = $self->_find_az_key($az);
	my $encoded = $self->network->{azs}{$base_az}{cloud_properties};
	return {} unless defined($encoded) && length($encoded);

	my $json = JSON::PP->new;
	$encoded = $json->encode($encoded) if ref($encoded) eq 'HASH';
	my $cloud_properties = eval {$json->decode($encoded)};
	bail(
		"Invalid JSON in the cloud properties for availability zone %s: %s",
		$az, $@
	) if $@;
	bail(
		"Cloud properties for availability zone %s must be a JSON object, got %s",
		$az, ref($cloud_properties) || 'a scalar'
	) unless ref($cloud_properties) eq 'HASH';
	return $cloud_properties;
}

# }}}
# _find_az_key - Resolves an availability zone identifier to its key in the network AZ data {{{
sub _find_az_key {
	my ($self, $az) = @_;
	bail(
		"No availability zones available; you may need to run a deploy on the ".
		"#M{%s} BOSH director to update its network information.",
		$self->env->bosh->alias
	) unless keys %{$self->network->{azs}};

	my $azs = $self->network->{azs};
	return $az if exists $azs->{$az};

	# By rendered name
	my ($base_az) = grep {
		($azs->{$_}{name}//'') eq $az
	} sort keys %$azs;

	# By cpi-specific name
	($base_az) = grep {
		($azs->{$_}{for_cpi}{$self->cpi_name}//'') eq $az
	} sort keys %$azs if !$base_az && $self->cpi_enabled;

	# By short form zN, matched on index so any rendered prefix holds
	if (!$base_az && $az =~ m/^z([0-9]+)$/) {
		my $idx = $1;
		($base_az) = grep {
			my $az_idx = $azs->{$_}{index} // (($azs->{$_}{name}//'') =~ m/([0-9]+)$/)[0];
			defined($az_idx) && $az_idx eq $idx
		} sort keys %$azs;
	}

	bail(
		"Availability zone %s not found in the available AZs for the network",
		$az
	) unless $base_az;

	return $base_az;
}

# }}}
# get_available_azs - Returns the available AZs for network namespace {{{
sub get_available_azs {
	return $_[0]->network->{azs};
}

# }}}
# get_available_azs_in_network - Returns the available AZs for a given network {{{
sub get_available_azs_in_network {
	my ($self, $target) = @_;
	my $allocated_subnets = $self
		->get_allocated_networks
		->{$self->name_for('net',$target)};
	return [
		(uniq sort map {$allocated_subnets->{$_}{az}//($allocated_subnets->{$_}{azs}->@*)} keys %$allocated_subnets)
	];
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
			my $full_az_name = $self->lookup_az($az);
			$valid_azs{$full_az_name} = 1 if $full_az_name;
		}
	} else {
		$valid_azs{$network->{$_}{az}} = 1 for keys %$network;
	}

	for my $subnet (values %{$network}) {
		$size += IPv4->new($subnet->{allocated})->size if $valid_azs{$subnet->{az}};
	}
	return $size;
}

# }}}
# subnets - Returns the subnets for the network {{{
sub subnets {
	my ($self) = @_;
	return $self->{subnets} ||= $self->env->ocfp_config_lookup(['net.subnets','vpc.subnets']);
}

# }}}
# vm_type_definition - Returns the definition for a given vm type {{{
sub vm_type_definition {
	return shift->_config_definition(VM_TYPE, 'vm', @_);
}

# }}}
# vm_extension_definition - Returns the definition for a given vm extension {{{
# FIXME: We want prefixes for vm extensions (name_for('vmx', $name)), but we will
# need to update any existing references to them in deployments.  For now, we
# just use the name as-is.
sub vm_extension_definition {
	my ($self, $name, $data) = @_;

	my $_data = $data->{cloud_properties_for_iaas} // $data;
	my ($cloud_properties, $found) = $self->_cloud_properties_for_iaas( %$_data);
	return () unless $found; # No cloud properties for this IaaS, so no vm extension

	my $config = {
		name => $name,
		cloud_properties => $cloud_properties,
	};

	$config = $self->_process_config_overrides(VM_EXTENSION, $name, $config);
	delete($config->{cloud_properties}) if (
		exists $config->{cloud_properties} && ! keys %{$config->{cloud_properties}}
	);

	return $config
}

# }}}
# disk_type_definition - Returns the definition for a given disk type {{{
sub disk_type_definition {
	return shift->_config_definition(DISK_TYPE, 'disk', @_);
}

# }}}
# }}}

# Private Methods {{{
# _validate_override_schema - Validates the structure of bosh-configs override definitions {{{
sub _validate_override_schema {
	my ($self) = @_;
	my $overrides_base = $self->overrides_base;
	my $config = $self->env->lookup($overrides_base, {});

	return unless ref($config) eq 'HASH' && keys %$config;

	my @valid_types = qw(vm_type vm_extension disk_type network);
	my @valid_type_defaults = map { $_ . '_defaults' } @valid_types;
	my @valid_types_plural = map { _plural_of($_) } @valid_types;
	# TODO: admit matching_networks once the subnet lookups apply it
	my @valid_matching_types = map { "matching_$_" } grep { $_ ne 'networks' } @valid_types_plural;
	my @valid_root_keys = (
		@valid_type_defaults,
		@valid_types_plural,
		@valid_matching_types
	);

	my @errors = ();

	push(@errors, sprintf(
		"#y{%s.matching_networks} is not yet supported; use ".
		"networks.<target>.subnet_defaults or networks.<target>.subnets.<subnet> instead",
		$overrides_base
	)) if exists $config->{matching_networks};

	# Validate root keys
	my @invalid_root_keys = ();
	for my $key (grep { $_ ne 'matching_networks' } keys %$config) {
		push(@invalid_root_keys, $key) unless in_array($key, @valid_root_keys);
	}
	push(@errors, sprintf(
		"Invalid override keys in #y{%s}: %s",
		$overrides_base, join(', ', @invalid_root_keys)
	)) if @invalid_root_keys;

	# Validate defaults sections
	my @invalid_defaults_content = grep {
		ref($config->{$_}) ne 'HASH'
	} grep { /_defaults$/ } keys %$config;
	push(@errors, sprintf(
		"Invalid defaults sections in #y{%s} (must be hashmaps): %s",
		$overrides_base, join(', ', @invalid_defaults_content)
	)) if @invalid_defaults_content;

	# Ensure defaults contents don't use meta-keys like <based-on> or <explicit-name>
	for my $defaults_key (grep { /_defaults$/ } keys %$config) {
		my @invalid_meta_keys = grep { /^<.*>$/ } keys %{$config->{$defaults_key}};
		push(@errors, sprintf(
			"Invalid meta-keys in #C{%s.%s}: %s",
			$overrides_base, $defaults_key, join(', ', @invalid_meta_keys)
		)) if @invalid_meta_keys;
	}

	# Validate matching sections
	for my $matching_key (grep { /^matching_/ } keys %$config) {
		my $rules = $config->{$matching_key};
		if (ref($rules) ne 'ARRAY') {
			push(@errors, sprintf(
				"#C{%s.%s} must be an array of hashmaps, each containing conditions and properties keys",
				$overrides_base, $matching_key
			));
			next;
		}

		for my $rule_idx (0..$#{$rules}) {
			my $rule = $rules->[$rule_idx];
			if (ref($rule) ne 'HASH' || !exists $rule->{conditions} || ref($rule->{conditions}) ne 'ARRAY'
			|| !exists $rule->{properties} || ref($rule->{properties}) ne 'HASH') {
				push(@errors, sprintf(
					"Rule #%d in #C{%s.%s} must be a hashmap with 'conditions' array and 'properties' hashmap",
					$rule_idx+1, $overrides_base, $matching_key
				));
				next;
			}

			# Validate each condition set
			for my $j (0..$#{$rule->{conditions}}) {
				my $condition_set = $rule->{conditions}->[$j];
				push(@errors, sprintf(
					"Condition set #%d in rule #%d of #C{%s.%s} must be a hashmap of field patterns",
					$j+1, $rule_idx+1, $overrides_base, $matching_key
				)) unless defined $condition_set;
			}

			# Ensure properties contents don't use meta-keys like <based-on> or <explicit-name>
			my @invalid_meta_keys = grep { /^<.*>$/ } keys %{$rule->{properties}};
			push(@errors, sprintf(
				"Invalid meta-keys in properties of rule #%d in #C{%s.%s}: %s",
				$rule_idx+1, $overrides_base, $matching_key, join(', ', @invalid_meta_keys)
			)) if @invalid_meta_keys;
		}
	}

	# Validate specific type sections
	for my $type_key (grep { in_array($_, @valid_types_plural) } keys %$config) {
		if (ref($config->{$type_key}) ne 'HASH') {
			push(@errors, sprintf(
				"#C{%s.%s} must be a hashmap of named configurations",
				$overrides_base, $type_key
			));
			next;
		}
		my @invalid_explicit_type_contents = grep {
			ref($config->{$type_key}{$_}) ne 'HASH'
		} keys %{$config->{$type_key}};
		push(@errors, sprintf(
			"Invalid configurations in #C{%s.%s} (must be hashmaps): %s",
			$overrides_base, $type_key, join(', ', @invalid_explicit_type_contents)
		)) if @invalid_explicit_type_contents;
	}

	# Assemble and report errors if any
	bail(
		"Errors found in cloud config overrides:\n%s",
		join("\n", map {"[[  - >>$_"} @errors)
	) if @errors;

	return 1;
}

# }}}
# _add_extended_cloud_config - Adds extended cloud config from environment to the given config {{{
sub _add_extended_cloud_config {
	my ($self, $config) = @_;
	my $extended_config = $self->env->lookup($self->overrides_base, {});
	my @groups = grep {$_ !~ m/(^matching_|_defaults$)/} keys %$extended_config;
	my %type_mapping = (
		vm_type => {prefix => 'vm' },
		vm_extension => {prefix => 'vmx', explicit_name => 1 }, # FIXME: See comment in vm_extension_definition
		disk_type => {prefix => 'disk' },
		network => {prefix => 'net' }
	);
	my %singular = map {(_plural_of($_), $_)} keys %type_mapping;
	for my $group_label (@groups) {
		bail(
			"Invalid cloud config definition '#R{%s}' in #C{%s} environment file",
			$group_label, $self->env->name
		) unless $singular{$group_label};
		my $type = $singular{$group_label};

		my $prefix = $type_mapping{$type}{prefix};
		my @targets = (keys %{$extended_config->{$group_label}});
		while (my $target = shift @targets) {
			# A copy: the meta-keys come off it, not off the environment's config
			my $defn = {%{$extended_config->{$group_label}{$target} // {}}};
			my $explicit_name = delete($defn->{'<explicit-name>'});
			my $name = ($explicit_name || $type_mapping{$type}{explicit_name}) ? $target : $self->name_for($prefix, $target);
			# Bare target matches too: a kit may register under that name (see POD)
			next if (exists $config->{$group_label} && grep { $_->{name} eq $name || $_->{name} eq $target } @{$config->{$group_label}});

			# Additional networks aren't supported yet
			if ($type eq 'network') {
				bail(
					"Extended cloud config network definitions are not supported yet: '%s' in #C{%s} environment file",
					$target, $self->env->name
				);
			}

			# If we haven't processed it, check if we can base it on an existing target
			if (my $src_target = delete($defn->{'<based-on>'})) {
				# The source may be registered under its bare or its prefixed name
				my @candidates = $type_mapping{$type}{explicit_name}
					? ($src_target, $self->name_for($prefix, $src_target))
					: ($self->name_for($prefix, $src_target), $src_target);
				my @registered = map {$_->{name}} @{$config->{$group_label} // []};
				my ($src_name) = grep {in_array($_, @registered)} @candidates;

				if (!$src_name) {
					# FIXME: Check for both explicit and env-prefixed names for the source target?
					my $group = $extended_config->{$group_label};
					bail(
						"The %s target '%s' depends on '%s' in environment #C{%s} %s ".
						"definition, but it does not exist",
						$type, $target, $src_target, $self->env->name, $self->overrides_base
					) unless exists $group->{$src_target};

					# Walk the <based-on> chain before deferring; a name seen twice is a cycle
					my %seen = ($target => 1);
					for (my $link = $src_target; defined($link) && exists $group->{$link}; $link = $group->{$link}{'<based-on>'}) {
						bail(
							"Cyclic dependency detected for target '%s' in extended cloud config for type '%s'",
							$target, $type
						) if $seen{$link}++;
					}

					push(@targets, $target); # retry once the source has been built
					next;
				}
				# Find the source definition and merge with it
				my ($src_defn) = grep { $_->{name} eq $src_name } @{$config->{$group_label}};
				if ($src_defn) {
					$defn = deep_merge($src_defn, $defn);
				}
			}

			$config->{$group_label} //= [];
			push @{$config->{$group_label}}, {%$defn, name => $name};
		}
	}

	return $config;
}

# }}}
# _config_definition - Returns the definition for a given config type {{{
sub _config_definition {
	my ($self, $type, $prefix, $target, %maps) = @_;

	$self->_validate_definition($type, $target, %maps);
	my %config = %{$maps{common}//{}};
	$config{name} = $self->name_for($prefix, $target);
	$config{cloud_properties} = $self->_cloud_properties_for_iaas(
		$maps{cloud_properties_for_iaas}->%*
	) if ref($maps{cloud_properties_for_iaas}) eq 'HASH';

	%config = $self->_process_config_overrides($type, $target, \%config)->%*;

	delete($config{cloud_properties}) if (
		exists $config{cloud_properties} && ! keys %{$config{cloud_properties}}
	);

	return {%config} if (grep {$_ !~ m/^(name)$/} keys %config);
	return ();
}

# }}}
# _subnet_definition - Returns the definition for a given subnet {{{
sub _subnet_definition {
	my ($self, $target, $subnet_id, $fields, $strategy) = @_;

	my $base_config = {
		name => $subnet_id, # stripped again by _process_network_subnets
		range => $self->_get_network_subnet_property(
			$target, $subnet_id, $fields, 'range'
		),
		reserved => $self->_get_network_subnet_property(
			$target, $subnet_id, $fields, 'reserved', no_defaults => 1
		),
	};

	if ($fields->{az}) {
		$base_config->{az} = $self->_get_network_subnet_property(
			$target, $subnet_id, $fields, 'az', optional => 1
		);
	} elsif ($fields->{azs}) {
		$base_config->{azs} = $self->_get_network_subnet_property(
			$target, $subnet_id, $fields, 'azs', optional => 1
		);
		# FIXME: What if the fields specify azs but user overrides specify az, or vice versa?
	} else {
		bail(
			"No availability zone(s) specified for network %s subnet %s",
			$target, $subnet_id
		);
	}

	my $gateway = $self->_get_network_subnet_property(
		$target, $subnet_id, $fields, 'gateway'
	)	// IPv4->new($base_config->{range})->start->add(1)->address;
	my $dns = $self->_get_network_subnet_property(
		$target, $subnet_id, $fields, 'dns', optional => 1
	) // [$gateway, '1.1.1.1'];
	$base_config->{gateway} = $gateway;
	$base_config->{dns}     = $dns;
	$base_config->{static}  = $self->_get_network_subnet_property(
		$target, $subnet_id, $fields, 'static', optional => 1, no_defaults => 1
	) if exists $fields->{static};

	if (exists $fields->{cloud_properties_for_iaas}) {
		my $cloud_properties = flatten(
			$fields->{cloud_properties_for_iaas}{$self->iaas} //
			# TODO: Support glob-style matching for IaaS
			$fields->{cloud_properties_for_iaas}{'*'} //
			{}
		);
		for my $key (keys %$cloud_properties) {
			my $value = $cloud_properties->{$key};
			if (ref($value) eq "Genesis::Hook::CloudConfig::LookupSubnetRef") {
				my $data = $strategy =~ /^ocfp(:.*)?$/
					? scalar $self->env->ocfp_config_lookup(["net.subnets.$subnet_id","vpc.subnets.$subnet_id"])
					: bail "LookupSubnetRef not implemented for strategy $strategy";
				$cloud_properties->{$key} = $value->resolve($self, $data);
			} elsif (ref($value) eq "Genesis::Hook::CloudConfig::LookupNetworkRef") {
				my $data = $strategy =~ /^ocfp(:.*)?$/
					? scalar $self->env->ocfp_config_lookup(['net','vpc'])
					: bail "LookupNetworkRef not implemented for strategy $strategy";
				$cloud_properties->{$key} = $value->resolve($self, $data);
			}
		}
		$base_config->{cloud_properties} = $self->_network_cloud_properties_for_iaas(
			$target, $subnet_id, $fields, $self->iaas => unflatten($cloud_properties)
		);
	}

	delete($base_config->{cloud_properties}) unless keys %{$base_config->{cloud_properties}};
	return $base_config;
}

# }}}
# _get_network_subnet_property - Returns the value for a given property for a network or subnet {{{
sub _get_network_subnet_property {
	my ($self, $target, $subnet_id, $fields, $property, %opts) = @_;
	my $source = 'cloud-config definition';
	my @sources = ();

	my $overrides_base = $self->overrides_base;
	unless ($opts{no_defaults}) {
		push @sources, "$overrides_base.network_defaults.subnets.$property";
		# TODO: push @sources, "$overrides_base.matching_networks";
		push @sources, "$overrides_base.networks.$target.subnet_defaults.$property";
	}
	push @sources, "$overrides_base.networks.$target.subnets.$subnet_id.$property";

	my $value = $fields->{$property};
	for my $source_path (@sources) {
		my ($override, $found) = $self->env->lookup($source_path);
		if (defined($found)) {
			$value = $override;
			$source = $source_path;
		}
	}

	bail(
		"No %s specified for network %s subnet %s (source: %s)",
		$property, $target, $subnet_id, $source
	) if (!defined($value) && !$opts{optional});

	return $value;
}

# }}}
# _network_cloud_properties_for_iaas - Returns the cloud properties for a given network and cpi {{{
sub _network_cloud_properties_for_iaas {
	my ($self, $target, $subnet_id, $fields, %map) = @_;
	my $config = $self->_cloud_properties_for_iaas(%map);

	my $source = 'cloud-config definition';
	my @sources = ();
	my $overrides_base = $self->overrides_base;
	push @sources, "$overrides_base.network_defaults.subnets.cloud_properties";
	# TODO: push @sources, "$overrides_base.matching_networks";
	push @sources, "$overrides_base.networks.$target.subnet_defaults.cloud_properties";
	push @sources, "$overrides_base.networks.$target.subnets.$subnet_id.cloud_properties";

	for my $source_path (@sources) {
		my ($override, $found) = $self->env->lookup($source_path);
		if (defined($found)) {
			$config = {%$config, flatten($override)->%*};
			$source = $source_path;
		}
	}

	return $config if $source eq 'cloud-config definition'; # no overrides

	my $flat_config = flatten($config);
	for my $key (keys %$flat_config) {
		delete($flat_config->{$key}) unless defined($flat_config->{$key});
	}
	$config = unflatten($flat_config);

	return $config;
}

# }}}
# _cloud_properties_for_iaas - Returns the cloud properties for a given type and cpi {{{
sub _cloud_properties_for_iaas {
	my ($self, %map) = @_;
	my $iaas = $self->iaas;
	my $map_key = (grep {$_ eq $iaas} keys %map)[0]
		// (grep {$_ =~ /(?:^|\|)${iaas}(?:\||$)/} keys %map)[0]
		// '*';

	my $cloud_properties = $map{$map_key} // {}; #TODO: allow glob-style matching
	return wantarray ? ($cloud_properties, exists($map{$map_key})) : $cloud_properties;
}

# }}}
# _process_config_overrides - Applies overrides to a given config based on the environment and bosh {{{
sub _process_config_overrides {
	my ($self, $type, $target, $config) = @_;

	# FIXME: What do we do if the config is not a hashref?  Is this possible?
	$config = flatten($config);

	# Resolve deferred values (coderefs and LookupRefs) first
	for my $key (keys %$config) {
		my $value = $config->{$key};
		if (ref($value) eq 'CODE') {
			$config->{$key} = $value->($self, $type, $target, $key, unflatten($config));
		} elsif (ref($value) eq 'Genesis::Hook::CloudConfig::LookupRef') {
			$config->{$key} = $value->resolve($self->env->params);
		}
	}
	$config = flatten(unflatten($config)); # a deferred value may have returned a structure

	my $plural_type = _plural_of($type);
	my $overrides_base = $self->overrides_base;

	# TODO: exodus overrides under <bosh-exodus>/configs/cloud/${type} are not implemented

	# Step 1: environment defaults
	my $overrides = $self->env->lookup("${overrides_base}.${type}_defaults");
	if ($overrides && ref($overrides) eq 'HASH' && scalar(keys %$overrides)) {
		$config = { %$config, flatten($overrides)->%* };
	}

	# Step 2: conditional overrides
	my $match_rules = $self->env->lookup("${overrides_base}.matching_${plural_type}", []);
	if (ref($match_rules) eq 'ARRAY' && scalar(@$match_rules)) {
		foreach my $rule (@$match_rules) {
			next unless ref($rule) eq 'HASH';
			my $overrides = $self->_evaluate_matching_rule(
				$target,
				$rule,
				$config,
			);
			$config = { %$config, flatten($overrides)->%* } if keys %$overrides;
		}
	}

	# Step 3: specific overrides
	$overrides = $self->env->lookup("${overrides_base}.${plural_type}.$target");
	if ($overrides && ref($overrides) eq 'HASH' && scalar(keys %$overrides)) {
		# Meta-keys declare a new entry; on a kit-defined one they are a contradiction
		my @meta = grep {exists $overrides->{$_}} ('<based-on>', '<explicit-name>');
		bail(
			"The %s '%s' override in #C{%s.%s.%s} carries %s, but the kit already ".
			"defines '%s'; meta-keys apply only to entries the kit does not define",
			$type, $target, $overrides_base, $plural_type, $target, join(' and ', @meta), $target
		) if @meta;
		$config = { %$config, flatten($overrides)->%* };
	}
	return unflatten($config);
}

# }}}
# _evaluate_matching_rule - Evaluates matching rule's conditions for config overrides {{{
sub _evaluate_matching_rule {
	my ($self, $target, $rule, $config) = @_;

	# $config is already flat; OR between condition sets, AND within one
	SET: foreach my $condition_set (@{$rule->{conditions}}) {
		next unless ref($condition_set) eq 'HASH';

		foreach my $field (keys %$condition_set) {
			my $patterns = $condition_set->{$field};
			bail(
				"Matching rule condition for %s must name a flattened config key, ".
				"not a nested map; write it as %s.<subkey>",
				$field, $field
			) if ref($patterns) eq 'HASH';
			my $field_value = $config->{$field};
			my $field_matches = 0;

			$patterns = [$patterns] unless ref($patterns) eq 'ARRAY';
			for my $test (@$patterns) {
				if (!defined($field_value)) {
					next unless !defined($test); # only a null pattern matches undef
					$field_matches = 1;
					last;
				}

				if (defined($test) && $test =~ /^(?:([!=])~)?\/(.+)\/([gimsx]*)$/) {
					my ($op, $regex, $flags) = ($1, $2, $3);
					$op //= '=';
					my $compiled_regex = $flags ? qr/(?$flags)$regex/ : qr/$regex/;
					my $re_match = $field_value =~ /$compiled_regex/;
					if (($op eq '!') eq !$re_match) { # '!' and no match, or '=' and match
						$field_matches = 1;
						last;
					}
				} elsif (defined($test) && $field_value eq $test) {
					$field_matches = 1;
					last;
				}
			}
			next SET unless $field_matches;
		}
		return $rule->{properties} // {}; # every field in this set matched
	}
	return {};
}

# }}}
# _validate_definition - Validates the definition for a given vm type {{{
sub _validate_definition {
	my ($self, $type, $target, %maps) = @_;

	my @extra_keys = grep {$_ !~ m/^(common|cloud_properties_for_iaas)$/} keys %maps;
	$self->env->kit->kit_bug(
		"Unexpected Cloud Config keys in %s %s in %s: %s\n".
		"Expected: common, cloud_properties_for_iaas",
		$target, $self->env->kit->id, $type, join(", ", @extra_keys)
	) if @extra_keys;

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
# _get_subnet_ranges - Returns the available and reserved IP ranges for a given subnet {{{
sub _get_subnet_ranges {
	my ($self, $subnet) = @_;
	my $range = IPv4->new($subnet->{cidr_block});

	my @reserved_ip_pairs = @{$subnet->{'reserved-ips'}}{
		sort grep {$_ =~ /^reserved/} keys %{$subnet->{'reserved-ips'}}
	};
	my @available_ip_pairs = @{$subnet->{'reserved-ips'}}{
		sort grep {$_ =~ /^available/ } keys %{$subnet->{'reserved-ips'}}
	};

	my $explicit_availability = scalar(@available_ip_pairs) > 0;

	# Defaults when the subnet declares nothing: the whole range is available,
	# and the first five addresses and the last one are reserved
	@available_ip_pairs = ($range->start->address, $range->end->address)
		unless @reserved_ip_pairs || @available_ip_pairs;
	@reserved_ip_pairs = (
		$range->start->address, $range->start->add(4)->address,
		$range->end->address,   $range->end->address,
	) unless @reserved_ip_pairs;

	my $reserved_range = IPv4->new();
	$reserved_range += [splice(@reserved_ip_pairs, 0, 2)]
		while @reserved_ip_pairs;

	my $available_range = IPv4->new();
	$available_range += [splice(@available_ip_pairs, 0, 2)]
		while @available_ip_pairs;

	# Explicit availability reserves everything else
	if ($explicit_availability) {
		$reserved_range += ($range - $available_range);
	}

	$available_range = $range unless $available_range > 0;
	$available_range -= $reserved_range if $reserved_range > 0;

	return ($available_range->simplify, $reserved_range->simplify);
}

# }}}
# _calculate_subnet_allocation - Calculates the IP range for a given subnet and network {{{
sub _calculate_subnet_allocation {
	my ($self, $target, $available, $existing, $count) = @_;
	my $needed = $count - $existing->size();

	# The caller has already checked the existing claim against other claims
	# and reserved-ips records, so it is taken as valid here.

	bail(
		"The allocation for network '%s' must not be negative (got %d)",
		$target, $count
	) if $count < 0;
	return $existing if $needed == 0;

	# Shrink: keep the lowest addresses of the claim, releasing from the top
	return $existing->slice($count)->simplify if $needed < 0;

	# Grow: keep the claim and take the shortfall from the pool, never
	# counting the claim's own addresses as free
	my $pool = IPv4->range($available);
	$pool -= $existing if $pool->size && $existing->size;
	bail(
		'Not enough available IPs in the subnet for the network \'%s\' allocation: '.
		' (has %d, needs %d)',
		$target, $pool->size, $needed
	) if ($pool->size < $needed);
	return IPv4->new($existing)->add($pool->slice($needed))->simplify;
}

# }}}
# _calculate_static_allocation - Takes the static IPs from the front of a subnet's allocation {{{
sub _calculate_static_allocation {
	my ($self, $target, $subnet_name, $allocated, $statics, $vm_count) = @_;
	my $count = $statics =~ m#^/(\d+)$#  ? 2**(32 - $1)
	          : $statics =~ m#^(\d+)%$#  ? round($vm_count * $1 / 100)
	          :                            $statics;

	# TODO: We currently just shove statics into the front of the range, but
	# this doesn't account for ips already in use.  We can either actively
	# check for ips in the network range against the bosh deployments, or we
	# allow users to override the statics with a list of offsets to use
	# rather than just a count or mask.(ie 0-3,9) maybe even negative for
	# adding to the end? (-1--3)
	bail(
		'More static IPs requested (%d) than the allocation for the %s subnet for '.
		'network %s allows (%d)',
		$count, $subnet_name, $target, $vm_count
	) if $count > $vm_count;
	return $allocated->slice($count);
}

# }}}
# _get_reserved_allocation - Returns the reserved IP allocation for a given target and subnet {{{
sub _get_reserved_allocation {
	my ($self, $target, $subnet) = @_;
	my $reserved_ips = $subnet->{'reserved-ips'} // {};
	my @candidates = $self->_reserved_ip_targets($target);

	# Ranges (<target>_a/_b, then _c/_d) and single addresses (<target>_ip,
	# and director_ip or a bare ip for bosh) each come from the first
	# candidate that records them, through the parser every owner shares
	my $parsed = _parse_reserved_ip_records($reserved_ips, known => \@candidates);
	my $allocation = IPv4->new();
	for my $candidate (@candidates) {
		my $rec = $parsed->{$candidate} or next;
		next unless $rec->{ranges}->size;
		$allocation += $rec->{ranges};
		last;
	}

	# Anchored and quoted: ocfp_bosh_ip must not answer for bosh
	for my $candidate (@candidates) {
		my $rec = $parsed->{$candidate} or next;

		# <target>_ip_a/_b beside <target>_ip are scheme_version 2 neighbour
		# notes, not reservations; any other _ip_<x> key is malformed and named
		my @unexplained = grep {
			!_is_neighbour_annotation($_, $reserved_ips->{$_}, $rec->{anchor})
		} @{$rec->{malformed}};
		warning(
			"Ignoring malformed reserved-ip key%s %s: use #C{%s_ip} for a ".
			"single address or #C{%s_a}/#C{%s_b} for a range, not both.",
			(@unexplained > 1 ? 's' : ''),
			join(', ', map {"#Y{$_}"} sort @unexplained),
			$candidate, $candidate, $candidate
		) if @unexplained;

		next unless $rec->{ips}->size;
		$allocation += $rec->{ips};
		last;
	}

	my $static;
	for my $candidate (@candidates) {
		next unless exists $reserved_ips->{$candidate."_static"};
		$static = $reserved_ips->{$candidate."_static"};
		last;
	}
	$static //= 1;

	return ($allocation->simplify, $static);
}

# }}}
# _reserved_ip_targets - Returns a target and the aliases whose reserved-ips records it owns {{{
sub _reserved_ip_targets {
	my ($self, $target) = @_;

	# A defined kit answer owns the aliases (an empty list opts out);
	# the module map is the fallback.  Target first, then aliases, per lookup.
	my $kit_aliases = $self->ocfp_reserved_ip_target_aliases($target);
	my @aliases = defined($kit_aliases)
		? _as_list($kit_aliases)
		: _as_list($OCFP_RESERVED_IP_TARGET_ALIASES{$target});
	my %seen;
	return grep { !$seen{$_}++ } ($target, @aliases);
}

# }}}
# _intersection - Returns the addresses two IPv4 sets share {{{
sub _intersection {
	my ($x, $y) = @_;
	return IPv4->range() unless $x && $y && $x->size && $y->size;
	# The IPv4 library has no intersect; a - (a - b) is the same set.  Both go
	# through range() first, because a simplified single address subtracts as
	# an integer rather than as a set.
	my $rx = IPv4->range($x);
	return IPv4->range($rx->subtract(IPv4->range($x)->subtract(IPv4->range($y))));
}

# }}}
# _all_reserved_ip_records - Returns every other target's reserved-ips records on a subnet, by owner {{{
sub _all_reserved_ip_records {
	my ($self, $subnet, $target) = @_;

	# The asking target and its aliases are not other owners
	my %own = defined($target) ? (map {($_ => 1)} $self->_reserved_ip_targets($target)) : ();

	my $parsed = _parse_reserved_ip_records(
		$subnet->{'reserved-ips'} // {}, known => [keys %own]
	);
	my %by_owner;
	for my $owner (keys %$parsed) {
		next if $own{$owner};
		my $set = IPv4->range($parsed->{$owner}{ranges}, $parsed->{$owner}{ips});
		$by_owner{$owner} = $set if $set->size;
	}
	return \%by_owner;
}

# }}}
# _parse_reserved_ip_records - Reads a subnet's reserved-ips records into per-owner addresses, the one reader both own and other records use {{{
sub _parse_reserved_ip_records {
	my ($reserved_ips, %opts) = @_;
	my %owners;
	my $rec = sub {
		my ($owner) = @_;
		# director_ip and a bare ip both name the director's address
		$owner = 'bosh' if $owner eq 'director' || $owner eq '';
		return $owners{$owner} //= {
			ranges    => IPv4->range(),
			ips       => IPv4->range(),
			malformed => [],
			anchor    => undef,
		};
	};

	# A key like <owner>_ip_smoke cannot say where its owner's name ends, so
	# the owners that other keys name settle it: <owner>_ip, <owner>_ip_a/_b
	# and <owner>_a each name an owner without doubt, and so does the target
	# the caller asks for.  The longest of those that the key starts with is
	# its owner, so my_ipsec_ip_smoke goes to my_ipsec beside my_ipsec_ip, not
	# to my.  A key that no known owner explains splits at the first _ip.
	my %known = map {($_ => 1)} @{$opts{known} // []};
	for my $key (keys %$reserved_ips) {
		next if $key =~ /^(?:reserved|available)(?:_|$)/ || $key eq 'scheme_version' || $key =~ /_static$/;
		$known{$1} = 1 if $key =~ /^(.+)_ip(?:_[a-z])?$/ || $key =~ /^(.+)_a$/;
	}
	my @known = sort {length($b) <=> length($a) || $a cmp $b} keys %known;

	for my $key (sort keys %$reserved_ips) {
		next if $key =~ /^(?:reserved|available)(?:_|$)/;
		next if $key eq 'scheme_version' || $key =~ /_static$/;
		my $value = $reserved_ips->{$key};
		if ($key =~ /^(.+)_ip_[a-z]$/) {
			# scheme 2 neighbour notes, or malformed; the caller decides which
			push @{$rec->($1)->{malformed}}, $key;
			next;
		}
		# An address, a comma list, a dash range or a CIDR, as IPv4 reads them
		next unless defined($value) && !ref($value) && $value =~ /^\s*\d[\d.,\/\-\s]*$/;
		# IPv4 reads only the first address of a dash range that has spaces
		# around its dash, and refuses a value that starts with a space or has
		# one before a comma
		(my $addresses = $value) =~ s/^\s+|\s+$//g;
		$addresses =~ s/\s*([-,])\s*/$1/g;
		# <owner>_a and _b bound a range even when the owner's name holds _ip,
		# as my_ipsec_a does, so they are not read as suffixed _ip keys of my
		my ($bounded, $letter) = $key =~ /^(.+)_([a-z])$/ ? ($1, $2) : ();
		undef $bounded unless defined($bounded) && exists $reserved_ips->{$bounded.'_a'} && exists $reserved_ips->{$bounded.'_b'};
		next if defined($bounded) && $letter ne 'a';
		if ($key eq 'ip') {
			$rec->('')->{ips} += IPv4->range($addresses);
		} elsif ($key =~ /^(.+)_ip$/) {
			my $r = $rec->($1);
			$r->{ips} += IPv4->range($addresses);
			$r->{anchor} = $addresses;
		} elsif (!defined($bounded) && $key =~ /^(.+?)_ip.+$/) {
			# <owner>_ip_smoke, _ips, _ip2 and the like add to the owner's addresses
			my ($owner) = grep {$key =~ /^\Q$_\E_ip./} @known;
			$rec->($owner // $1)->{ips} += IPv4->range($addresses);
		} elsif ($key =~ /^(.+)_a$/) {
			# <owner>_a/_b, then _c/_d and so on, each the range between the two
			my $owner = $1;
			my $idx = 'a';
			while (exists $reserved_ips->{$owner."_$idx"}) {
				my $start_key = $owner."_".$idx++;
				my $end_key   = $owner."_".$idx++;
				last unless exists $reserved_ips->{$end_key};
				my ($start, $end) = map {IPv4->address(s/^\s+|\s+$//gr)} @{$reserved_ips}{$start_key, $end_key};
				$start += 1;
				$end   -= 1;
				# Bounds that are reversed or adjacent leave nothing between them
				$rec->($owner)->{ranges} += $start->to($end) if $start->int <= $end->int;
			}
		}
	}

	# Settle each owner's sets, and drop owners with nothing but a note
	for my $owner (keys %owners) {
		$owners{$owner}{$_} = IPv4->range($owners{$owner}{$_}) for qw(ranges ips);
	}
	return \%owners;
}

# }}}
# _prune_claim_of_reserved_records - Stops, or warns for an exempt network, when a saved claim holds another target's reserved address {{{
sub _prune_claim_of_reserved_records {
	my ($self, $target, $network_id, $subnet_name, $existing, $other_records_by_owner) = @_;
	return unless $existing->size;
	my @lost = map {
		my $hit = _intersection($existing, $other_records_by_owner->{$_});
		$hit->size ? ([$_, $hit]) : ()
	} sort keys %$other_records_by_owner;
	return unless @lost;

	my $addresses = IPv4->range(map {$_->[1]} @lost)->range;
	my $owners = join(', ', map {sprintf("%s (%s)", $_->[0], $_->[1]->range)} @lost);
	my %allowed = map {$_ => 1} grep {length} split(/\s*,\s*/, $ENV{GENESIS_ALLOW_CLAIM_PRUNE} // '');
	my $compilation = $target eq 'compilation' && $self->isa('Genesis::Hook::CloudConfig::Director');

	if ($compilation || $allowed{$network_id}) {
		warning(
			"Network #C{%s} on subnet #C{%s} had %s in its saved claim, but those ".
			"addresses are reserved-ips records for %s.  Genesis has dropped them ".
			"from this network's claim and will take replacements from the free ".
			"pool, %s.  This usually means the claim was saved by a Genesis build ".
			"that did not check reserved addresses, or the record was written after ".
			"the claim.",
			$network_id, $subnet_name, $addresses, $owners,
			($compilation
				? "because compilation VMs exist only during a deploy"
				: "because #C{GENESIS_ALLOW_CLAIM_PRUNE} names this network")
		);
		return;
	}
	bail(
		"Network #C{%s} on subnet #C{%s} has %s in its saved claim, but those ".
		"addresses are reserved-ips records for %s.  Dropping them would move any ".
		"VM of this network that holds one, so Genesis has stopped without ".
		"changing anything.  This usually means the claim was saved by a Genesis ".
		"build that did not check reserved addresses, or the record was written ".
		"after the claim.  Check with #C{bosh vms} that no VM on #C{%s} holds %s, ".
		"then re-run with #C{GENESIS_ALLOW_CLAIM_PRUNE=%s} set for that one run to ".
		"accept the change.",
		$network_id, $subnet_name, $addresses, $owners, $network_id, $addresses, $network_id
	);
}

# }}}
# _bail_on_claim_clash - Stops when this network's dynamic claim overlaps another network's claim {{{
sub _bail_on_claim_clash {
	my ($self, $network_id, $subnet_name, $existing, $other_claims_by_network) = @_;
	return unless $existing->size;
	for my $other (sort keys %$other_claims_by_network) {
		my $clash = _intersection($existing, $other_claims_by_network->{$other});
		next unless $clash->size;
		bail(
			"Network #C{%s} and network #C{%s} both claim %s on subnet #C{%s}, and ".
			"no reserved-ips record names an owner for those addresses.  Genesis has ".
			"stopped without changing either claim.  This usually means two deploys ".
			"saved claims without holding the network claims lock, or the director's ".
			"network exodus was edited by hand.  Check which deployment's VMs sit on ".
			"those addresses with #C{bosh vms}, remove the wrong claim from the ".
			"director's exodus #C{network} record, and run this again.",
			$network_id, $other, $clash->range, $subnet_name
		);
	}
}

# }}}
# _warn_own_records_in_other_claims - Warns when another network's claim holds this target's reserved address {{{
sub _warn_own_records_in_other_claims {
	my ($self, $target, $network_id, $subnet_name, $subnet, $own_records, $other_claims_by_network) = @_;
	return unless $own_records->size;
	my $by_owner;
	for my $other (sort keys %$other_claims_by_network) {
		my $hit = _intersection($own_records, $other_claims_by_network->{$other});
		next unless $hit->size;

		# Name the record's owner as well as the target, when an alias owns it
		$by_owner //= $self->_all_reserved_ip_records($subnet);
		my @owners = grep {
			$by_owner->{$_} && _intersection($hit, $by_owner->{$_})->size
		} $self->_reserved_ip_targets($target);
		my $record_for = (!@owners || (@owners == 1 && $owners[0] eq $target))
			? "target '$target'"
			: sprintf("%s (target '%s')", join(', ', @owners), $target);

		# A director's compilation network is rebuilt from the director's own
		# cloud config, so name the command for that one
		my $rebuild = $other =~ /^(.+)\.([^.]+)\.net-compilation$/
			? sprintf(
				"'%s' is the compilation network of director #C{%s}, so run ".
				"#C{genesis bosh-configs upload --type cloud --name %s.%s.director -y} ".
				"against that director's environment.",
				$other, $1, $1, $2)
			: sprintf(
				"Rebuild the cloud config of the deployment that owns '%s'.  For a ".
				"director's compilation network, that is #C{genesis bosh-configs upload ".
				"--type cloud --name <env>.<type>.director -y} run against the ".
				"director's environment.",
				$other);
		warning(
			"Address %s on subnet #C{%s} is a reserved-ips record for %s, so network ".
			"#C{%s} keeps it, but network #C{%s} also claims it.  Until #C{%s} is ".
			"rebuilt, both networks list the address and the director could hand it ".
			"out twice.  %s",
			$hit->range, $subnet_name, $record_for, $network_id, $other, $other, $rebuild
		);
	}
}

# }}}
# _get_bosh_network_data - Returns the network data for the BOSH director (self) {{{
sub _get_bosh_network_data {
	return $_[0]->env->director_exodus_lookup('/network');
}

# }}}
# _filter_subnets - Filters and validates subnets based on provided filter criteria {{{
sub _filter_subnets {
	my ($self, $subnet_filter) = @_;

	my $subnets = $self->subnets;
	return $subnets unless defined($subnet_filter);

	$subnet_filter = [$subnet_filter] unless ref $subnet_filter eq 'ARRAY';
	my $selected_subnets = {};

	for my $filter (grep {defined $_} @$subnet_filter) {
		if (ref $filter eq 'Regexp') {
			for my $subnet (keys %$subnets) {
				$selected_subnets->{$subnet} = $subnets->{$subnet} if $subnet =~ $filter;
			}
		} elsif (ref($filter)) {
			bail("Invalid subnet filter type: %s", ref($filter));
		} elsif (defined($subnets->{$filter})) {
			$selected_subnets->{$filter} = $subnets->{$filter};
		} else {
			debug("Invalid subnet name in filter: %s", $filter);
		}
	}

	return $selected_subnets;
}

# }}}

# _az_definition_for - Returns the definition for a given availability zone {{{
sub _az_definition_for {
	my ($self, $az, %options) = @_;
	my $az_key = delete($options{az_key});
	my $config = {
		name => $options{name} // $az->{name}, # Support CPI Shadow naming
	};
	$config->{cloud_properties} = JSON::PP->new->decode($az->{cloud_properties}) unless $options{virtual};
	$config->{cpi} = $self->cpi_name_for_az($az_key, $az) if ($self->cpi_enabled);
	return $config;
}

# }}}
# _process_network_subnets - Processes the network subnets to match what BOSH needs {{{
sub _process_network_subnets {
	my ($self, $networks) = @_;
	return unless ref($networks) eq 'ARRAY';

	for my $network (@$networks) {
		next if ($network->{type}//'') eq 'vip';
		bail(
			"Network definition is not a hashref: %s", $network
		) unless ref($network) eq 'HASH' && exists $network->{subnets};

		my $subnets = delete($network->{subnets});
		my %subnets_by_range = ();
		push(@{ $subnets_by_range{$_->{range}} }, $_) for (@$subnets);

		my @lsa_subnets = ();
		my %processed_ranges = ();

		# Walk in original order so the output keeps it
		for my $subnet (@$subnets) {
			my $range = $subnet->{range};
			next if $processed_ranges{$range};

			$processed_ranges{$range} = 1;
			my @subnet_configs = @{$subnets_by_range{$range}};

			if (@subnet_configs > 1) {
				my $lsa = $self->_build_logical_subnet_amalgamation(
					$network->{name}, \@subnet_configs
				);
				push @lsa_subnets, $lsa if $lsa;
			} else {
				delete($subnet_configs[0]->{name});
				push @lsa_subnets, $subnet_configs[0];
			}
		}
		$network->{subnets} = \@lsa_subnets;
	}
	return 1;
}
# }}}
# _build_logical_subnet_amalgamation - Builds a logical subnet amalgamation for subnets with the same range {{{
sub _build_logical_subnet_amalgamation {
	my ($self, $target, $subnet_configs) = @_;
	return $subnet_configs->[0] unless ref($subnet_configs) eq 'ARRAY' && @$subnet_configs > 1;

	my @subnet_names = sort map {$_->{name}} @$subnet_configs;
	my %subnet_configs_hash = map {$_->{name} => $_} @$subnet_configs;

	my (%ranges, %gateways) = ();
	for my $subnet_name (@subnet_names) {
		push @{ $ranges{$subnet_configs_hash{$subnet_name}->{range}} }, $subnet_name;
		push @{ $gateways{$subnet_configs_hash{$subnet_name}->{gateway}} }, $subnet_name;
	}
	bail(
		"Cannot create LSA for subnets with different ranges:\n%s",
		join("\n", map { sprintf("%s: %s", $_, join(', ', @{$ranges{$_}})) } keys %ranges)
	) if keys(%ranges) > 1;
	bail(
		"Cannot create LSA for subnets with different gateways:\n%s",
		join("\n", map { sprintf("%s: %s", $_, join(', ', @{$gateways{$_}})) } keys %gateways)
	) if keys(%gateways) > 1;

	my ($range) = keys %ranges;
	my ($gateway) = keys %gateways;

	# A child carries az or azs depending on which _subnet_definition branch
	# built it; reading az alone contributes an undef for the other shape
	my @azs = uniq sort grep {defined} map {
		$_->{azs} ? $_->{azs}->@* : $_->{az}
	} @$subnet_configs;
	my @dns_servers = uniq sort map { @{$_->{dns} // []} } @$subnet_configs;

	my $lsa_config = {
		range => $range,
		gateway => $gateway,
		azs => \@azs,
		dns => \@dns_servers,
	};

	# Merged reserved = the range minus the union of each child's available
	my $range_span = IPv4->span($range);
	my $reserved = $range_span - IPv4->new(
		map {$range_span - IPv4->new($_->{reserved}->@*)} @$subnet_configs
	);
	$lsa_config->{reserved} = [map {"$_"} $reserved->spans];

	# Statics are unique across children, so concatenation is the merge
	$lsa_config->{static} = [
		map {($_->{static}->@*)} grep {$_->{static}} @$subnet_configs
	];

	# Children must agree on cloud properties (one hash serves every AZ in a
	# BOSH subnet); compared flat so the message can name the differing leaf
	my %flat_cloud_properties = map {
		$_ => flatten($subnet_configs_hash{$_}{cloud_properties} // {})
	} @subnet_names;

	my @cloud_property_differences = ();
	for my $property (uniq sort map {keys %$_} values %flat_cloud_properties) {
		my %carriers = ();
		for my $subnet_name (@subnet_names) {
			my $flat = $flat_cloud_properties{$subnet_name};
			my $value = $flat->{$property};
			my $signature =
				!exists($flat->{$property}) ? '(not set)' :
				!defined($value)            ? '(null)'    :
				ref($value) eq 'ARRAY'      ? '(empty list)' :
				ref($value) eq 'HASH'       ? '(empty map)'  :
				                              "'$value'";
			push @{ $carriers{$signature} }, $subnet_name;
		}
		next if keys(%carriers) == 1;
		push @cloud_property_differences, sprintf(
			"  %s: %s", $property, join('; ', map {
				sprintf("%s on %s", $_, join(', ', @{$carriers{$_}}))
			} sort keys %carriers)
		);
	}

	bail(
		"Cannot create LSA for subnets with different cloud properties in ".
		"network #C{%s}:\n%s\n".
		"Subnets that share a range and a gateway are describing one wire, and ".
		"a BOSH subnet applies its cloud properties to every AZ in it, so ".
		"these subnets cannot be merged.  Either give every subnet in the ".
		"range the same cloud properties, or put them on separate ranges.  ".
		"Per-subnet overrides live under ".
		"#C{%s.networks.<target>.subnets.<subnet>.cloud_properties}.",
		$target, join("\n", @cloud_property_differences), $self->overrides_base
	) if @cloud_property_differences;

	# All children agree; take the first by name, and leave an empty hash off
	$lsa_config->{cloud_properties} = $subnet_configs_hash{$subnet_names[0]}{cloud_properties}
		if keys %{$flat_cloud_properties{$subnet_names[0]}};

	return $range_span->size > $reserved->size ? $lsa_config : undef;
}

# }}}
# _standardized_subnet_cidr - Returns a standardized CIDR range for a given subnet {{{
sub _standardized_subnet_cidr {
	my ($self, $subnet, $name, $target) = @_;
	my $range = IPv4->new($subnet->{cidr_block});
	my @spans = $range->spans;
	bail(
		"Subnet %s for network %s is not a single CIDR block, but has multiple ranges: %s",
		$name, $target, join(', ', map {"$_"} @spans)
	) if @spans > 1;
	my @cidrs = $spans[0]->cidrs;
	bail(
		"Subnet %s for network %s is not a single CIDR block, but has multiple CIDRs: %s",
		$name, $target, join(', ', map {"$_"} @cidrs)
	) if @cidrs > 1;
	return $cidrs[0];
}

# }}}
# _plural_of - Returns the plural form of a given noun {{{
sub _plural_of {
	return count_nouns(2, $_[0], suppress_count => 1);
}

# }}}
# }}}

1;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
