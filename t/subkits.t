#!perl
use strict;
use warnings;

use lib 't';
use helper;
use Test::Differences;

my $tmp = workdir;
ok -d "t/repos/subkit-test", "subkit-test repo exists" or die;
chdir "t/repos/subkit-test" or die;

bosh2_cli_ok;

runs_ok "genesis manifest -c cloud.yml use-s3 2>$tmp/manifest-errors >$tmp/manifest.yml";
eq_or_diff get_file("$tmp/manifest.yml"), <<EOF, "manifest generated with s3 subkit";
name: sandbox-subkit-test
properties:
  blobstore:
    config:
      aki: yup, we got one
      secret: haha
    type: s3

EOF
eq_or_diff get_file("$tmp/manifest-errors"), <<EOF, "errors from manifest generated with webdav subkit";

\e[1;33mDEPRICATED:\e[0m subkits are depricated in favour of features.  Please update your kit.
EOF

runs_ok "genesis manifest -c cloud.yml use-webdav 2>$tmp/manifest-errors >$tmp/manifest.yml";
eq_or_diff get_file("$tmp/manifest.yml"), <<EOF, "manifest generated with webdav subkit";
name: sandbox-subkit-test
properties:
  blobstore:
    config:
      url: https://blobstore.internal
    type: webdav

EOF
eq_or_diff get_file("$tmp/manifest-errors"), <<EOF, "errors from manifest generated with webdav subkit";

\e[1;33mDEPRICATED:\e[0m subkits are depricated in favour of features.  Please update your kit.
EOF

run_fails "genesis manifest -c cloud.yml use-the-wrong-thing >$tmp/errors 2>&1", undef;
eq_or_diff get_file("$tmp/errors"), <<EOF, "manifest generate fails with an invalid blobstore subkit";

\e[1;33mDEPRICATED:\e[0m subkits are depricated in favour of features.  Please update your kit.
No subkit 'magic' found in kit dev/latest.
EOF

run_fails "genesis manifest -c cloud.yml use-nothing >$tmp/errors 2>&1", undef;
eq_or_diff get_file("$tmp/errors"), <<EOF, "manifest generate fails without a valid blobstore subkit";

\e[1;33mDEPRICATED:\e[0m subkits are depricated in favour of features.  Please update your kit.
You must select a subkit to provide your blobstore. Should be one of 'webdav', 's3'
EOF

run_fails "genesis manifest -c cloud.yml use-too-many >$tmp/errors 2>&1", undef;
eq_or_diff get_file("$tmp/errors"), <<EOF, "manifest generate fails with too many blobstore subkits";

\e[1;33mDEPRICATED:\e[0m subkits are depricated in favour of features.  Please update your kit.
You selected too many subkits for your blobstore. Should be only one of 'webdav', 's3'
EOF

done_testing;
