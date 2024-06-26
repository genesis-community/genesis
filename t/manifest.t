#!perl
use strict;
use warnings;

use lib 't';
use helper;
use Test::Differences;

$ENV{GENESIS_CONFIG_AUTOMATIC_UPGRADE} = 'silent';
vault_ok();

my $tmp = workdir;
ok -d "t/repos/manifest-test", "manifest-test repo exists" or die;
chdir "t/repos/manifest-test" or die;
bosh2_cli_ok;
write_bosh_config "us-common";
$ENV{NOCOLOR} = 1;

runs_ok "genesis manifest -c cloud.yml -t unredacted -s pruned us-east-1-sandbox >$tmp/manifest.yml";
eq_or_diff get_file("$tmp/manifest.yml"), <<EOF, "manifest generated for us-east-1/sandbox";

[us-east-1-sandbox/manifest-test] generating unredacted manifest...

[us-east-1-sandbox/manifest-test] determining manifest fragments for merging...done

jobs:
- name: thing
  properties:
    domain: sb.us-east-1.example.com
    endpoint: https://sb.us-east-1.example.com:8443
  templates:
  - name: bar
    release: foo
name: us-east-1-sandbox-manifest-test
releases:
- name: foo
  version: 1.2.3-rc.1
EOF

runs_ok "genesis manifest -c cloud.yml -t unredacted -s pruned us-west-1-sandbox >$tmp/manifest.yml";
eq_or_diff get_file("$tmp/manifest.yml"), <<EOF, "manifest generated for us-west-1/sandbox";

[us-west-1-sandbox/manifest-test] generating unredacted manifest...

[us-west-1-sandbox/manifest-test] determining manifest fragments for merging...done

jobs:
- name: thing
  properties:
    domain: us-west-1-sandbox.us-west-1.example.com
    endpoint: https://us-west-1-sandbox.us-west-1.example.com:8443
  templates:
  - name: bar
    release: foo
name: us-west-1-sandbox-manifest-test
releases:
- name: foo
  version: 1.2.3-rc.1
EOF

$ENV{GENESIS_INDEX} = "no";
$ENV{TERM} = "xterm";
runs_ok "genesis manifest -c init-cloud.yml -t unredacted -s pruned bosh-init-sandbox >$tmp/manifest.yml 2>$tmp/error.txt";
eq_or_diff get_file("$tmp/error.txt"), <<EOF, "manifest for bosh-init/create-env scenario warns that a cloud config file was provided";

[WARNING] The provided configs will be ignored, as create-env environments do
          not use them:
          - cloud

[bosh-init-sandbox/manifest-test] generating unredacted manifest...

[bosh-init-sandbox/manifest-test] determining manifest fragments for merging...done

EOF
eq_or_diff get_file("$tmp/manifest.yml"), <<EOF, "manifest for bosh-init/create-env scenario ignores provided cloud config file, and doesn't prune cloud-y datastructures";
azs:
- name: z1
disk_pools:
- name: pool-1
disk_types:
- name: persistent-1
jobs:
- name: thing
  properties:
    domain: bosh-init.example.com
    endpoint: https://bosh-init.example.com:8443
  templates:
  - name: bar
    release: foo
name: bosh-init-sandbox-manifest-test
networks:
- name: mynet
releases:
- name: foo
  version: 1.2.3-rc.1
resource_pools:
- name: small
vm_extensions:
- vm_ext_1
EOF

runs_ok "genesis manifest -c init-cloud.yml -t unredacted -s pruned create-env-sandbox >$tmp/manifest.yml 2>$tmp/error.txt";
eq_or_diff get_file("$tmp/error.txt"), <<EOF, "manifest for bosh-init/create-env scenario warns that a cloud config file was provided";

[WARNING] The provided configs will be ignored, as create-env environments do
          not use them:
          - cloud

[create-env-sandbox/manifest-test] generating unredacted manifest...

[create-env-sandbox/manifest-test] determining manifest fragments for merging...done

EOF
eq_or_diff get_file("$tmp/manifest.yml"), <<EOF, "manifest for bosh-int/create-env scenario ignores provided cloud config file, and doesn't prune cloud-y datastructures";
azs:
- name: z1
disk_pools:
- name: pool-1
disk_types:
- name: persistent-1
jobs:
- name: thing
  properties:
    domain: create-env.example.com
    endpoint: https://create-env.example.com:8443
  templates:
  - name: bar
    release: foo
name: create-env-sandbox-manifest-test
networks:
- name: mynet
releases:
- name: foo
  version: 1.2.3-rc.1
resource_pools:
- name: huge
vm_extensions:
- vm_ext_1
EOF

$ENV{PREVIOUS_ENV} = "us-cache-test";
runs_ok "genesis manifest -c init-cloud.yml -t unredacted -s pruned us-west-1-sandbox >$tmp/manifest.yml";
eq_or_diff get_file("$tmp/manifest.yml"), <<EOF, "manifest is generated using cached files if PREVIOUS_ENV variable is set";

[us-west-1-sandbox/manifest-test] generating unredacted manifest...

[us-west-1-sandbox/manifest-test] determining manifest fragments for merging...done

cached_value: is_present
jobs:
- name: thing
  properties:
    domain: us-west-1-sandbox.us-west-1.example.com
    endpoint: https://us-west-1-sandbox.us-west-1.example.com:8443
  templates:
  - name: bar
    release: foo
name: us-west-1-sandbox-manifest-test
releases:
- name: foo
  version: 1.2.3-rc.1
EOF

# Test -C option
my $alt_dir =  $tmp."/elsewhere";
mkdir $alt_dir;
chdir $alt_dir;
my $configdir = "$TOPDIR/t/repos/manifest-test";

runs_ok "genesis -C $configdir manifest -c init-cloud.yml -t unredacted -s pruned create-env-sandbox >manifest.yml 2>error.txt";
eq_or_diff get_file("error.txt"), <<EOF, "manifest for bosh-init/create-env scenario warns that a cloud config file was provided (-C option) ";

[WARNING] The provided configs will be ignored, as create-env environments do
          not use them:
          - cloud

[create-env-sandbox/manifest-test] generating unredacted manifest...

[create-env-sandbox/manifest-test] determining manifest fragments for merging...done

EOF
eq_or_diff get_file("manifest.yml"), <<EOF, "manifest for bosh-int/create-env scenario ignores provided cloud config file, and doesn't prune cloud-y datastructures (-C option)";
azs:
- name: z1
disk_pools:
- name: pool-1
disk_types:
- name: persistent-1
jobs:
- name: thing
  properties:
    domain: create-env.example.com
    endpoint: https://create-env.example.com:8443
  templates:
  - name: bar
    release: foo
name: create-env-sandbox-manifest-test
networks:
- name: mynet
releases:
- name: foo
  version: 1.2.3-rc.1
resource_pools:
- name: huge
vm_extensions:
- vm_ext_1
EOF

$ENV{PREVIOUS_ENV} = "us-cache-test";
runs_ok "genesis -C $configdir/us-west-1-sandbox.yml manifest -c init-cloud.yml -t unredacted -s pruned  >manifest.yml";
eq_or_diff get_file("manifest.yml"), <<EOF, "manifest is generated using cached files if PREVIOUS_ENV variable is set (-C option with yml)";

[us-west-1-sandbox/manifest-test] generating unredacted manifest...

[us-west-1-sandbox/manifest-test] determining manifest fragments for merging...done

cached_value: is_present
jobs:
- name: thing
  properties:
    domain: us-west-1-sandbox.us-west-1.example.com
    endpoint: https://us-west-1-sandbox.us-west-1.example.com:8443
  templates:
  - name: bar
    release: foo
name: us-west-1-sandbox-manifest-test
releases:
- name: foo
  version: 1.2.3-rc.1
EOF
chdir $TOPDIR;
teardown_vault();
done_testing;
