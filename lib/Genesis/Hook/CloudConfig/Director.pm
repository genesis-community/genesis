package Genesis::Hook::CloudConfig::Director;
use strict;
use warnings;

use Genesis;
use Genesis::Hook::CloudConfig::LookupSubnetRef;
use Genesis::Hook::CloudConfig::LookupNetworkRef;
use JSON::PP;

use parent qw(Genesis::Hook::CloudConfig);

# Class Overrides {{{
# init - Initializes the CloudConfig hook, injecting the common properties {{{

my %cloud_configs = ();
sub init {
	my ($class, %opts) = @_;
	my $az_prefix = delete($opts{az_prefix}) // 'z';
	my $obj = $class->SUPER::init(%opts, network => {});
	
	# Set the azs and subnets
	# FIXME: Check if az prefix set in environment config
	$obj->_set_network_azs(prefix => $az_prefix);
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
	# the relative path of '/<env>/<ocfp-type>/vpc/azs/<name> for each named AZ.
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
		my $config = {};
		$config->{name} = $azs->{$az}{name};
		$config->{cloud_properties} = JSON::PP->new->decode($azs->{$az}{cloud_properties})
			unless ($options{virtual});
		push @azs, $config;
	}
	return sort {$a->{name} cmp $b->{name}} @azs;
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

	unless ($strategy eq 'ocfp') {
		debug(
			'Unsupported strategy for building compilation definitions: %s',
			$strategy
		);
		return ();
	}
	
	# TODO: Enable overrides for the compilation definition in bosh-configs
	# section of the environment configuration.
	my $network = $self->name_for('net','compilation');
	my $vm_type = $self->name_for('vm','compilation');
	my $azs = $self->get_available_azs_in_network('compilation');
	my $workers = $self->get_network_size('compilation',$azs->[0]);
	my $reuse_compilation = $self->env->lookup(
		'bosh-configs.director_cloud.reuse_compilation'
	)//$self->TRUE;

	my $config = {
		network => $network,
		vm_type => $vm_type,
		az => $azs->[0],
		workers => $workers,
		reuse_compilation => $reuse_compilation,
	};
	my $disk_type = (exists $options{persistent_disk_type})
	? $options{persistent_disk_type}
	: 'compilation';
	$config->{disk_type} = $self->name_for('disk',$disk_type) if $disk_type;
	return %$config;
}

# }}}
# }}}

# Private Methods {{{
## _get_bosh_network_data - Returns the network data for the BOSH director (self) {{{
#sub _get_bosh_network_data {
#	my ($self) = @_;
#	my $data = $self->env->vault->get_path($self->env->exodus_mount.join('/',
#		$self->env->name,
#		$self->env->type,
#		'networks',
#	));
#	return $data;
#}
#
# }}}
# _set_network_azs - Set (and validate?) the network azs for the environment {{{
sub _set_network_azs {
	my ($self, %opts) = @_;
	if ($self->env->is_ocfp) {
		my $azs = $self->env->ocfp_config_lookup('vpc.azs');
		my %azs = map {
			my $az_name = $_;
			my $data = $azs->{$az_name};
			my $idx = $data->{index} // ($az_name =~ m/-([0-9]*)$/)[0];
			($az_name,
				{
					name => $opts{prefix} . $idx,
					cloud_properties => $data->{cloud_properties} // '{}',
				}
			);
		} sort keys %{scalar $azs};

		# FIXME: What if this has changed (ie there is already network data)?
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
		my $subnets = $self->env->ocfp_config_lookup('vpc.subnets');
		my %subnets = map {
			my $subnet_name = $_;
			my $data = $subnets->{$subnet_name};
			($subnet_name,
				{
					range => IP4::Range->new($data->{cidr_block})->range,
					az => $self->lookup_az($data->{az}),
				}
			);
		} sort grep {$_ =~ /^ocfp-/} keys %{scalar $subnets};
		
		# FIXME: Validate the subnets against any existing definitions
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

# vim - fdm=marker:foldlevel=1:ts=2:sts=2:sw=2:noet
