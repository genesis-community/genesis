#!perl
use strict;
use warnings;

use lib 't';
use helper;

vault_ok();

my $tmp = workdir 'yamls-deployments';
chdir $tmp or die;

subtest 'hierarchical inheritance' => sub {
	reprovision kit => 'omega-v2.7.0';

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
	put_file "cloud.yml", "--- {}";

	output_ok "genesis yamls sw-aws-east.yml --config cloud=cloud.yml", <<EOF, "yaml ordering is correct for a middle file";
./sw.yml
./sw-aws.yml
./sw-aws-east.yml
EOF

	output_ok "genesis yamls sw-aws-east-dev --config cloud.yml", <<EOF, "yaml ordering is correct for the end file";
./sw.yml
./sw-aws.yml
./sw-aws-east.yml
./sw-aws-east-dev.yml
EOF

	output_ok "genesis yamls sw-vsphere-east-dev -c cloud.yml", <<EOF, "yaml ordering is correct for an alternative prefix";
./sw.yml
./sw-vsphere.yml
./sw-vsphere-east.yml
./sw-vsphere-east-dev.yml
EOF

	put_file "rt.yml", "--- {}";
	output_ok "genesis yamls sw-openstack-east-prod.yml --config runtime=rt.yml --config cloud=cloud.yml", <<EOF, "yaml ordering os correct when there are missing intermediary yamls";
./sw.yml
./sw-openstack-east-prod.yml
EOF
};

# TODO: Add support for v2 config tests, using hypen-terminated yml filenames.

subtest 'explicit inheritance' => sub {
	put_file "c.yml", "--- {genesis: {inherits: [ base, corp]}}";
	put_file "base.yml", "--- {}";
	put_file "corp.yml", "--- {}";
	put_file "yin.yml", "--- {genesis: {inherits: [yang]}}";
	put_file "yang.yml", "--- {genesis: {inherits: [yin]}}";
	put_file "c-real-env.yml", "--- {genesis: {env: 'c-real-env', inherits: [yin]}}";

	output_ok "genesis yamls c-real-env.yml -c cloud.yml", <<EOF, "yaml ordering for explicit inheritance";
./base.yml
./corp.yml
./c.yml
./yang.yml
./yin.yml
./c-real-env.yml
EOF
};

chdir $TOPDIR;
teardown_vault;
done_testing;
