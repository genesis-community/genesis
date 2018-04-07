#!perl
use strict;
use warnings;

use lib 't';
use helper;
use Test::Differences;

my $tmp = workdir;
ok -d "t/repos/manifest-test", "manifest-test repo exists" or die;
chdir "t/repos/manifest-test" or die;

bosh2_cli_ok;

runs_ok "genesis manifest -c cloud.yml us-east-1-sandbox >$tmp/manifest.yml";
eq_or_diff get_file("$tmp/manifest.yml"), <<EOF, "manifest generated for us-east-1/sandbox";
jobs:
- name: thing
  properties:
    domain: sb.us-east-1.example.com
    endpoint: https://sb.us-east-1.example.com:8443
  templates:
  - name: bar
    release: foo
name: sandbox-manifest-test
releases:
- name: foo
  version: 1.2.3-rc.1
EOF

runs_ok "genesis manifest -c cloud.yml us-west-1-sandbox >$tmp/manifest.yml";
eq_or_diff get_file("$tmp/manifest.yml"), <<EOF, "manifest generated for us-west-1/sandbox";
jobs:
- name: thing
  properties:
    domain: sandbox.us-west-1.example.com
    endpoint: https://sandbox.us-west-1.example.com:8443
  templates:
  - name: bar
    release: foo
name: sandbox-manifest-test
releases:
- name: foo
  version: 1.2.3-rc.1
EOF

$ENV{GENESIS_INDEX} = "no";
runs_ok "genesis manifest -c init-cloud.yml bosh-init-sandbox >$tmp/manifest.yml 2>$tmp/error.txt";
eq_or_diff get_file("$tmp/error.txt"), <<EOF, "manifest for bosh-init/create-env scenario warns that a cloud config file was provided";
\e[1;33m[Warning]\e[0m The specified cloud-config will be ignored as create-env environments do not use them.
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

runs_ok "genesis manifest -c init-cloud.yml create-env-sandbox >$tmp/manifest.yml 2>$tmp/error.txt";
eq_or_diff get_file("$tmp/error.txt"), <<EOF, "manifest for bosh-init/create-env scenario warns that a cloud config file was provided";
\e[1;33m[Warning]\e[0m The specified cloud-config will be ignored as create-env environments do not use them.
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
- name: small
vm_extensions:
- vm_ext_1
EOF

$ENV{PREVIOUS_ENV} = "us-cache-test";
runs_ok "genesis manifest -c init-cloud.yml us-west-1-sandbox >$tmp/manifest.yml";
eq_or_diff get_file("$tmp/manifest.yml"), <<EOF, "manifest is generated using cached files if PREVIOUS_ENV variable is set";
cached_value: is_present
jobs:
- name: thing
  properties:
    domain: sandbox.us-west-1.example.com
    endpoint: https://sandbox.us-west-1.example.com:8443
  templates:
  - name: bar
    release: foo
name: sandbox-manifest-test
releases:
- name: foo
  version: 1.2.3-rc.1
EOF

done_testing;
