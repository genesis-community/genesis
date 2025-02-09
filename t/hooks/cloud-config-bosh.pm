package Genesis::Hook::CloudConfig::Bosh v3.2.0;

use strict;
use warnings;

use parent qw(Genesis::Hook::CloudConfig);

use Genesis::Hook::CloudConfig::Helpers qw/gigabytes megabytes/;

use Genesis qw//;
use JSON::PP;

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0-rc.4');
	return $obj;
}

sub perform {
	my ($self) = @_;
	return 1 if $self->completed;

	my $config = $self->build_cloud_config({
		'networks' => [
			$self->network_definition('bosh', strategy => 'ocfp',
				dynamic_subnets => {
					allocation => {
						size => 0,
						statics => 0,
					},
					cloud_properties_for_iaas => {
						openstack => {
							'net_id' => $self->network_reference('id'), # TODO: $self->subnet_reference('net_id'),
							'security_groups' => ['default'] #$self->subnet_reference('sgs', 'get_security_groups'),
						},
					},
				},
			)
		],
		'vm_types' => [
			$self->vm_type_definition('bosh',
				cloud_properties_for_iaas => {
					openstack => {
						'instance_type' => $self->for_scale({
							dev => 'm1.2',
							prod => 'm1.3'
						}, 'm1.2'),
						'boot_from_volume' => $self->TRUE,
						'root_disk' => {
							'size' => 32 # in gigabytes
						},
					},
				},
			),
		],
		'disk_types' => [
			$self->disk_type_definition('bosh',
				common => {
					disk_size => $self->for_scale({ # add $self->for_feature('internal-blobstore')
						dev => gigabytes(64),
						prod => gigabytes(128)
					}, gigabytes(96)),
				},
				cloud_properties_for_iaas => {
					openstack => {
						'type' => 'storage_premium_perf6',
					},
				},
			),
		],
	});

	$self->done($config);
}

1;
