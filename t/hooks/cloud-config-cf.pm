package Genesis::Hook::CloudConfig::CF v2.6.0;

use strict;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

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

	# FIXME: Add support for other iaas types
	# TODO: Add support for env-provided matrices
	my $vm_matrix = {map {($_->[0], {type_dev => $_->[1], type_prod => $_->[2], disk_size => $_->[3]})} (
		#     Name        dev_type  prod_type  root_disk_size
		[qw[  api            c2i.4     c1a.4d              15  ]], #  c1a.4d
		[qw[  cc-worker      c2i.1     c1a.1d              15  ]], #  a1cpu_2ram_d     =  c1a.1d
		[qw[  credhub        c2i.1     c1a.1d              30  ]], #  a1cpu_2ram_d
		[qw[  diego-api      c2i.1     c1a.1d              15  ]], #  a1cpu_2ram_d
		[qw[  diego-cell      g1.4    m1a.16d             256  ]], #  a16cpu_128ram_d  =  m1a.16d
		[qw[  doppler        c2i.2     c1a.2d              15  ]], #  a2cpu_4ram_d
		[qw[  errand          c1.1       c1.1              15  ]], #
		[qw[  log-api        c2i.1     c1a.1d              15  ]], #  a1cpu_2ram_d
		[qw[  log-cache      c2i.2     c1a.2d              15  ]], #  a2cpu_4ram_d     =  c1a.2d
		[qw[  nats           c2i.1     c1a.1d              15  ]], #  a1cpu_2ram_d
		[qw[  router         c2i.4     c1a.4d              15  ]], #  c1a.4d
		[qw[  scheduler      c2i.1     c1a.1d              15  ]], #  a1cpu_2ram_d
		[qw[  tcp-router      c1.1       c1.1              10  ]], #  c1.1
		[qw[  uaa            c2i.2     c1a.2d              30  ]], #  a2cpu_4ram_d
		[qw[  database       c2i.4     g1a.8d              60  ]], #  database
		[qw[  blobstore      c2i.1     c1a.1d              60  ]], #  a1cpu_2ram_d
	)};

	delete($vm_matrix->{database})
		unless $self->wants_feature('+internal-db');

	delete($vm_matrix->{blobstore})
		unless $self->wants_feature('+internal-blobstore');

  my @networks = ();
  my $network_cloud_properties = {
    openstack => {
      'net_id' => $self->network_reference('id'), # TODO: $self->subnet_reference('net_id'),
      'security_groups' => ['default'] #$self->subnet_reference('sgs', 'get_security_groups'),
    },
  };

  if ($self->wants_feature('split-network')) {
    $self->relinquish_networks('ocf');
    @networks = (
      $self->network_definition('ocf-core', strategy => 'ocfp',
        dynamic_subnets => {
          cloud_properties_for_iaas => $network_cloud_properties,
          allocation => { size => 11, statics => 0 }
        }
      ),
      $self->network_definition('ocf-edge', strategy => 'ocfp',
        dynamic_subnets => {
          cloud_properties_for_iaas => $network_cloud_properties,
          allocation => { size => 1, statics => 0 }
        }
      ),
      $self->network_definition('ocf-tcp', strategy => 'ocfp',
        dynamic_subnets => {
          cloud_properties_for_iaas => $network_cloud_properties,
          allocation => { size => 1, statics => 0 }
        }
      ),
      $self->network_definition('ocf-db', strategy => 'ocfp',
        dynamic_subnets => {
          subnets => ['ocfp-0'],
          cloud_properties_for_iaas => $network_cloud_properties,
          allocation => { size => 1, statics => 0 }
        }
      ),
      $self->network_definition('ocf-runtime', strategy => 'ocfp',
        dynamic_subnets => {
          cloud_properties_for_iaas => $network_cloud_properties,
          allocation => { size => 40, statics => 0 } # 120 diego cell vms max
        }
      )
    );
  } else {
    $self->relinquish_networks(qw/ocf-core ocf-edge ocf-tcp ocf-runtime ocf-db/);
    @networks = $self->network_definition('ocf', strategy => 'ocfp',
				dynamic_subnets => {
          cloud_properties_for_iaas => $network_cloud_properties,
					allocation => { size => 64, statics => 8, }
				}
			)
  }

	my $config = $self->build_cloud_config({
		'networks' => \@networks,
		'vm_types' => [ (map {
			$self->vm_type_definition($_, cloud_properties_for_iaas => {
				openstack => {
					'instance_type' => $self->for_scale({
							dev  => $vm_matrix->{$_}{type_dev},
							prod => $vm_matrix->{$_}{type_prod}
						}),
					'ephemeral_disk' => {encrypted => $self->TRUE},
					'boot_from_volume' => $self->TRUE,
					'root_disk' => {size => $vm_matrix->{$_}{disk_size}+0}, # Force conversion to integer
				},
			}),
			} (sort keys %$vm_matrix)),
		],
		'vm_extensions' => [
			$self->vm_extension_definition('diego-ssh-proxy-network-properties', common => {}),
			$self->vm_extension_definition('cf-router-network-properties', common => {}),
			$self->vm_extension_definition('cf-tcp-router-network-properties', common => {}),
		],
		'disk_types' => [
			$self->disk_type_definition('database',
				common => {
					disk_size => gigabytes(10),
				},
				cloud_properties_for_iaas => {
					openstack => {
						'type' => 'storage_premium_perf6',
					},
				},
			),
			$self->disk_type_definition('blobstore',
				common => {
					disk_size => $self->for_scale({
              dev => gigabytes(100),
              prod => gigabytes(200),
            }, gigabytes(100))
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
