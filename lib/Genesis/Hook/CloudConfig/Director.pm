package Genesis::Hook::CloudConfig::Director;
use v5.20;
use warnings;

use Genesis;
use Genesis::Hook::CloudConfig::LookupSubnetRef;
use Genesis::Hook::CloudConfig::LookupNetworkRef;

use IPv4;
use JSON::PP;

use parent qw(Genesis::Hook::CloudConfig);

# Class Overrides {{{
# init - Initializes the CloudConfig hook, injecting the common properties {{{

my %cloud_configs = ();
sub init {
	my ($class, %opts) = @_;
	bail(
		"Purpose must be 'director' - %s",
		$opts{purpose} ? "got '$opts{purpose}'" : "no purpose provided"
	) unless ($opts{purpose}//'') eq 'director';
	my $obj = $class->SUPER::init(%opts, network => {});

	# Set the azs and subnets
	# FIXME: Check if az prefix set in environment config
	$obj->_set_network_azs();
	$obj->_set_network_subnets();

	return $obj;
}

# }}}
# _can_build_cloud_config - Returns whether the cloud config can be built for the environment {{{
sub _can_build_cloud_config {
	my ($class, $env) = @_;
	1; # Director cloud config can always be built

}
# }}}
# }}}

# Public Methods {{{
# build_az_definitions - Builds the availability zone definitions for known AZs {{{
sub build_az_definitions {
	my ($self, %options) = @_;

	# This will build the availability zone definitions for all available AZs in
	# the config provided in vault under $ENV{GENESIS_OCFP_CONFIG_MOUNT}, with
	# the relative path of '<env>/<ocfp-type>/(net|vpc)/azs/<name> for each named AZ.
	# The keys that will be available under each AZ are:
	# - index: The index of the AZ in the list of AZs
	# - id (optional): The id of the AZ in the cloud provider
	# - cloud_properties: The cloud properties for the AZ in json format.
	#
	# It will take the following options:
	# - strategy:
	#     The strategy to use for building the AZ definitions.  This can be
	#     'generic' or 'ocfp'.  The default is 'generic', however only 'ocfp' is
	#     supported at this time.
	# - prefix: The prefix to use for the AZ name.
	#
	# The AZ definitions will be built based on the strategy, and the prefix
	# will be used to build the name of the AZ along with the index of the AZ
	# in the list of AZs.

	my $prefix = delete($options{prefix}) // '';

	my @azs = ();
	my $azs = $self->get_available_azs;
	for my $az (keys %$azs) {
		next unless $azs->{$az}{name};
		my $config = $self->_az_definition_for($azs->{$az}, %options);
		push @azs, $config;
	}
	my @results = uniq sort {$a->{name} cmp $b->{name}} @azs;
	return wantarray ? @results : \@results;
}

# }}}
# complilation_definition - Returns the compilation definition for the environment {{{
sub compilation_definition {
	my ($self, %options) = @_;

	# This will return the compilation definition for the environment, based on the
	# target and options provided.  The compilation definition will include the
	# network, the vm type, the disk type, and the availability zone.  It will also
	# include the cloud properties for the compilation, and the resource pool
	# configuration.
	#
	# The compilation definition will be built based on the target, and the options
	# provided.  The target will be the name of the compilation network, and the
	# options will include the vm type, disk type, and availability zone.
	#
	# The compilation definition will be built based on the strategy, and the prefix
	# will be used to build the name of the compilation network along with the index
	# of the compilation network in the list of compilation networks.

	my $strategy = delete($options{strategy}) // 'generic';

	bail(
		'Unsupported strategy for building compilation definitions: %s',
		$strategy
	) unless ($strategy eq 'ocfp');

	# TODO: Enable overrides for the compilation definition in bosh-configs
	# section of the environment configuration.
	my $network = $self->name_for('net','compilation');
	my $vm_type = $self->name_for('vm','compilation');
	my $azs = $self->get_available_azs_in_network('compilation');
	my $workers = $self->get_network_size('compilation',$azs->[0]);
	my $reuse_compilation_vms = $self->env->lookup(
		'bosh-configs.director_cloud.compilation.reuse_vms'
	)//$self->TRUE;

	my $config = {
		network => $network,
		vm_type => $vm_type,
		az => $azs->[0],
		workers => $workers,
		reuse_compilation_vms => $reuse_compilation_vms,
	};
	return %$config;
}

# }}}
# overrides_base - Returns the base path for overrides in the environment configuration {{{
sub overrides_base {
	return 'bosh-configs.director_cloud';
}

# }}}
# }}}

# Private Methods {{{
# _set_network_azs - Set (and validate?) the network azs for the environment {{{
sub _set_network_azs {
	my ($self, %opts) = @_;
	if ($self->env->is_ocfp) {
		my $prefix = $self->{az_prefix};
		my $azs = $self->env->ocfp_config_lookup(['net.azs','vpc.azs']);
		my %azs = map {
			my $az_name = $_;
			my $data = $azs->{$az_name};
			my $idx = $data->{index} // ($az_name =~ m/[^0-9]([0-9]*)$/)[0];
			my $cloud_properties = $data->{cloud_properties};
			if ($cloud_properties) {
				eval {JSON::PP->new->decode($cloud_properties)};
				bug(
					"Invalid json in cloud properties for AZ %s: %s",
					$az_name, $@
				) if ($@);
			} else {
				$cloud_properties = '{}';
			}
			($az_name, {
					index => $idx,
					name  => $prefix . $idx,
					cloud_properties => $cloud_properties,
			});
		} sort keys %{scalar $azs};

		# We need to check if there's already network data for the environment and
		# if so, we need to preserve the for_cpi data (that's the only thing that is
		# added outside of the director hook)
		my $network_data = $self->_get_bosh_network_data;
		if ($network_data && ref($network_data) eq 'HASH' && exists $network_data->{azs}) {
			my $existing_azs = $network_data->{azs};
			for my $az_name (keys %azs) {
				if (exists $existing_azs->{$az_name}) {
					$azs{$az_name}{for_cpi} = $existing_azs->{$az_name}{for_cpi};
				}
			}
		}
		$self->{network}{azs} = \%azs;

	} else {
		bug(
			"NYI: Unsupported environment for setting AZs: only environments using ".
			"#C{ocfp} feature is supported at this time"
		);
	}
}

# }}}
# _set_network_subnets - Set (and validate?) the network subnets for the environment {{{
sub _set_network_subnets {
	my ($self) = @_;
	if ($self->env->is_ocfp) {
		my $subnets = $self->env->ocfp_config_lookup(['net.subnets','vpc.subnets']);
		my %subnets = map {
			my $subnet_name = $_;
			my $data = $subnets->{$subnet_name};
			($subnet_name,
				{
					range => IPv4->new($data->{cidr_block})->range,
					az => $self->lookup_az($data->{az}),
				}
			);
		} sort grep {$_ =~ /^ocfp-/} keys %{scalar $subnets};

		# We need to check if there's already network subnet data for the environment,
		# and if so, we need to preserve the existing claims data (that's the only
		# thing that is added outside of the director hook)
		my $network_data = $self->_get_bosh_network_data;
		if ($network_data && ref($network_data) eq 'HASH' && exists $network_data->{subnets}) {
			my $existing_subnets = $network_data->{subnets};
			for my $subnet_name (keys %subnets) {
				if (exists $existing_subnets->{$subnet_name} && $existing_subnets->{$subnet_name}{claims}) {
					$subnets{$subnet_name}{claims} = $existing_subnets->{$subnet_name}{claims};
				}
			}
		}
		$self->{network}{subnets} = \%subnets;
	} else {
		bug(
			"NYI: Unsupported environment for setting subnets: only environments using ".
			"#C{ocfp} feature is supported at this time"
		);
	}
}
# }}}
# _get_bosh_network_data - Returns the network data for the BOSH director (self) {{{
sub _get_bosh_network_data {
	return $_[0]->env->exodus_lookup('/network:.');
}

# }}}
1;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
