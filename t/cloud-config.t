#!perl
use strict;
use warnings;

use lib 't';
use helper;

ok -d "t/repos/cloud-config-test", "cloud-config-test repo exists" or die;
chdir "t/repos/cloud-config-test" or die;

bosh2_cli_ok;

run_fails "genesis manifest test-env", 1;
runs_ok "genesis manifest -c cloud.yml test-env";
output_ok "genesis manifest -c cloud.yml test-env", <<EOF, "with cloud-config, we get the networking details";
jobs:
- instances: 1
  name: thing
  networks:
  - name: default
    static_ips:
    - 10.244.123.34
  properties:
    domain: sb.us-east-1.example.com
    endpoint: https://sb.us-east-1.example.com:8443
  templates:
  - name: bar
    release: foo
name: sandbox-cloud-config-test
releases:
- name: foo
  version: 1.2.3-rc.1
EOF


done_testing;
