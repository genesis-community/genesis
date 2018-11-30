#!perl
use strict;
use warnings;

use lib 't';
use helper;

my $tmp = workdir 'yamls-deployments';
chdir $tmp or die;

reprovision kit => 'omega';

put_file "sw.yml", "--- {}";
put_file "sw-aws.yml", "--- {}";
put_file "sw-aws-east.yml", "--- {genesis: {env: 'sw-aws-east'}}";
put_file "sw-aws-east-1.yml", "--- {}";
put_file "sw-aws-east-dev.yml", "--- {genesis: {env: 'sw-aws-east-dev'}}";
put_file "sw-aws-west.yml", "--- {}";
put_file "sw-aws-west-1.yml", "--- {}";
put_file "sw-vsphere.yml", "--- {}";
put_file "sw-vsphere-east.yml", "--- {}";
put_file "sw-vsphere-east-1.yml", "--- {}";
put_file "sw-vsphere-east-dev.yml", "--- {genesis: {env: 'sw-vsphere-east-dev'}}";
put_file "sw-vsphere-west.yml", "--- {}";
put_file "sw-vsphere-west-1.yml", "--- {}";
put_file "sw-vsphere-west-dev.yml", "--- {}";
put_file "sw-openstack-east-prod.yml", "--- {genesis: {env: 'sw-openstack-east-prod'}}";

output_ok "genesis yamls sw-aws-east.yml", <<EOF, "yaml ordering is correct for a middle file";
./sw.yml
./sw-aws.yml
./sw-aws-east.yml
EOF

output_ok "genesis yamls sw-aws-east-dev", <<EOF, "yaml ordering is correct for the end file";
./sw.yml
./sw-aws.yml
./sw-aws-east.yml
./sw-aws-east-dev.yml
EOF

output_ok "genesis yamls sw-vsphere-east-dev", <<EOF, "yaml ordering is correct for an alternative prefix";
./sw.yml
./sw-vsphere.yml
./sw-vsphere-east.yml
./sw-vsphere-east-dev.yml
EOF

output_ok "genesis yamls sw-openstack-east-prod.yml", <<EOF, "yaml ordering os correct when there are missing intermediary yamls";
./sw.yml
./sw-openstack-east-prod.yml
EOF

chdir $TOPDIR;
done_testing;
