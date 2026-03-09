#!/usr/bin/env perl
package Genesis::Hook::CloudConfig::Bosh::Director v2.1.0;

use strict;
use warnings;

# Only needed for development
my $lib;
BEGIN {$lib = $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}
use lib $lib;

use parent qw(Genesis::Hook::CloudConfig::Director);

use Genesis::Hook::CloudConfig::Helpers qw/gigabytes megabytes/;

use Genesis qw//;
use JSON::PP;

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_, az_prefix => $ENV{GENESIS_ENVIRONMENT}.'-az');
	$obj->check_minimum_genesis_version('3.1.0-rc.4');
	return $obj;
}

sub perform {
	my ($self) = @_;
	return 1 if $self->completed;

	# Given we have:
	#   /secrets/config/<env>/<ocfp-type>/vpc/azs/<name>
	# containing records like:
	#   index: <az-index>
	#   cloud_properties: { <iaas-az-cloud-properties> } # optional
	my $config = $self->build_cloud_config({
		'azs' => [
			$self->build_az_definitions(
				virtual => $self->TRUE,
			),
		],
		'networks' => [
			$self->network_definition('compilation', strategy => 'ocfp',
				dynamic_subnets => {
					subnets => ['ocfp-1'],
					allocation => {
						size => 4,
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
			$self->vm_type_definition('compilation',
				cloud_properties_for_iaas => {
					openstack => {
						'instance_type' => 'm1.2',
						'boot_from_volume' => $self->TRUE,
						'root_disk' => {
							'size' => 30 # in gigabytes
						},
					},
				},
			),
		],
		compilation => {
			$self->compilation_definition(
				strategy => 'ocfp',
			)
		},
	});

	$self->done($config);
}
1
