#!perl
use strict;
use warnings;

use lib 't';
use helper;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 120;

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

	output_ok "(genesis yamls sw-aws-east.yml --config cloud=cloud.yml 2>/dev/null)", <<EOF, "yaml ordering is correct for a middle file";
Omega/2.0.0 (dev): manifest.yml
            local: sw.yml
            local: sw-aws.yml
            local: sw-aws-east.yml
EOF

	output_ok "(genesis yamls sw-aws-east-dev --config cloud.yml 2>/dev/null)", <<EOF, "yaml ordering is correct for the end file";
Omega/2.0.0 (dev): manifest.yml
            local: sw.yml
            local: sw-aws.yml
            local: sw-aws-east.yml
            local: sw-aws-east-dev.yml
EOF

	output_ok "(genesis yamls sw-vsphere-east-dev -c cloud.yml 2>/dev/null)", <<EOF, "yaml ordering is correct for an alternative prefix";
Omega/2.0.0 (dev): manifest.yml
            local: sw.yml
            local: sw-vsphere.yml
            local: sw-vsphere-east.yml
            local: sw-vsphere-east-dev.yml
EOF

	put_file "rt.yml", "--- {}";
	output_ok "(genesis yamls sw-openstack-east-prod.yml --config runtime=rt.yml --config cloud=cloud.yml 2>/dev/null)", <<EOF, "yaml ordering os correct when there are missing intermediary yamls";
Omega/2.0.0 (dev): manifest.yml
            local: sw.yml
            local: sw-openstack-east-prod.yml
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

	output_ok "(genesis yamls c-real-env.yml -c cloud.yml 2>/dev/null)", <<EOF, "yaml ordering for explicit inheritance";
Omega/2.0.0 (dev): manifest.yml
            local: base.yml
            local: corp.yml
            local: c.yml
            local: yin.yml
            local: yang.yml
            local: c-real-env.yml
EOF
};

subtest 'genesis.inherits behaviour' => sub {
	reprovision kit => 'omega-v2.7.0';

	put_file "base.yml", "--- {}";
	put_file "adjacent.yml", "--- {}";
	put_file "intermediate.yml", "--- {genesis: {inherits: [base]}}";
	put_file "final.yml", "--- {genesis: {env: final, inherits: [adjacent, intermediate]}}";

	output_ok "(genesis yamls final.yml --config cloud=cloud.yml 2>/dev/null)", <<EOF, "yaml ordering is correct for inherited files";
Omega/2.0.0 (dev): manifest.yml
            local: adjacent.yml
            local: base.yml
            local: intermediate.yml
            local: final.yml
EOF

	put_file "multi_inherit.yml", "--- {genesis: {env: multi_inherit,inherits: [base, intermediate]}}";

	output_ok "(genesis yamls multi_inherit.yml --config cloud=cloud.yml 2>/dev/null)", <<EOF, "yaml ordering is correct for multiple inheritance";
Omega/2.0.0 (dev): manifest.yml
            local: base.yml
            local: intermediate.yml
            local: multi_inherit.yml
EOF

	put_file "circular1.yml", "--- {genesis: {env: circular1, inherits: [circular2]}}";
	put_file "circular2.yml", "--- {genesis: {env: circular2, inherits: [circular1]}}";

	output_ok "(genesis yamls circular1.yml --config cloud=cloud.yml 2>/dev/null)", <<EOF, "yaml ordering handles circular inheritance";
Omega/2.0.0 (dev): manifest.yml
            local: circular2.yml
            local: circular1.yml
EOF
};

chdir $TOPDIR;
teardown_vault;
done_testing;
