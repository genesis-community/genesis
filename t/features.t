#!perl
use strict;
use warnings;

use lib 't';
use helper;

my $tmp = workdir;
ok -d "t/repos/feature-test", "feature-test repo exists" or die;
chdir "t/repos/feature-test" or die;

bosh2_cli_ok;

runs_ok "genesis manifest -c cloud.yml use-s3 >$tmp/manifest.yml";
is get_file("$tmp/manifest.yml"), <<EOF, "manifest generated with s3 feature";
name: sandbox-feature-test
properties:
  blobstore:
    config:
      aki: yup, we got one
      secret: haha
    type: s3
EOF

runs_ok "genesis manifest -c cloud.yml use-webdav >$tmp/manifest.yml";
is get_file("$tmp/manifest.yml"), <<EOF, "manifest generated with webdav feature";
name: sandbox-feature-test
properties:
  blobstore:
    config:
      url: https://blobstore.internal
    type: webdav
EOF
run_fails "genesis manifest -c cloud.yml use-the-wrong-thing >$tmp/errors 2>&1", undef;
is get_file("$tmp/errors"), <<EOF, "manifest generate fails with an invalid blobstore feature";
You must select a feature to provide your blobstore. Should be one of 'webdav', 's3'
EOF

run_fails "genesis manifest -c cloud.yml use-nothing >$tmp/errors 2>&1", undef;
is get_file("$tmp/errors"), <<EOF, "manifest generate fails without a valid blobstore feature";
You must select a feature to provide your blobstore. Should be one of 'webdav', 's3'
EOF

run_fails "genesis manifest -c cloud.yml use-too-many >$tmp/errors 2>&1", undef;
is get_file("$tmp/errors"), <<EOF, "manifest generate fails with too many blobstore features";
You selected too many features for your blobstore. Should be only one of 'webdav', 's3'
EOF

# Testing using hooks/blueprint 

done_testing;
