#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Test::Deep;
use Test::Exception;

use Genesis;
$Genesis::VERSION = '999.999.999';
use_ok 'Genesis::Config';
$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");

use_ok 'Genesis::Top';
use_ok 'Genesis::Env';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# ============================================================================
# is_ocfp() tests
# ============================================================================

subtest 'is_ocfp() - returns false when ocfp feature is absent' => sub {
	plan tests => 2;

	my $top = make_top(name => 'cf', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file $top->path('no-ocfp.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features: []
genesis:
  env: no-ocfp
EOF

	my $env = $top->load_env('no-ocfp');
	ok(!$env->is_ocfp, 'is_ocfp() returns false when features list is empty');

	put_file $top->path('other-feature.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features:
    - aws
    - s3
genesis:
  env: other-feature
EOF

	$env = $top->load_env('other-feature');
	ok(!$env->is_ocfp, 'is_ocfp() returns false when other features are active but not ocfp');
};

subtest 'is_ocfp() - returns true when ocfp feature is present' => sub {
	plan tests => 2;

	my $top = make_top(name => 'cf', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file $top->path('with-ocfp.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features:
    - ocfp
genesis:
  env: with-ocfp
EOF

	my $env = $top->load_env('with-ocfp');
	ok($env->is_ocfp, 'is_ocfp() returns true when ocfp feature is present');

	put_file $top->path('ocfp-plus.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features:
    - aws
    - ocfp
    - s3
genesis:
  env: ocfp-plus
EOF

	$env = $top->load_env('ocfp-plus');
	ok($env->is_ocfp, 'is_ocfp() returns true when ocfp is among multiple features');
};

# ============================================================================
# ocfp_type() tests
# ============================================================================

subtest 'ocfp_type() - returns empty string for non-OCFP environments' => sub {
	plan tests => 1;

	my $top = make_top(name => 'cf', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file $top->path('non-ocfp-type.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features: []
genesis:
  env: non-ocfp-type
EOF

	my $env = $top->load_env('non-ocfp-type');
	is($env->ocfp_type, '', 'ocfp_type() returns empty string when is_ocfp is false');
};

subtest 'ocfp_type() - returns mgmt for management environments' => sub {
	plan tests => 2;

	my $top = make_top(name => 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file $top->path('us-east-1-mgmt.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features:
    - ocfp
genesis:
  env: us-east-1-mgmt
EOF

	my $env = $top->load_env('us-east-1-mgmt');
	is($env->ocfp_type, 'mgmt', 'ocfp_type() returns mgmt for name ending in -mgmt');

	put_file $top->path('us-west-2-mgmt.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features:
    - ocfp
genesis:
  env: us-west-2-mgmt
EOF

	$env = $top->load_env('us-west-2-mgmt');
	is($env->ocfp_type, 'mgmt', 'ocfp_type() returns mgmt for different region ending in -mgmt');
};

subtest 'ocfp_type() - returns ocf for OCF environments' => sub {
	plan tests => 2;

	my $top = make_top(name => 'cf', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file $top->path('us-east-1-ocf.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features:
    - ocfp
genesis:
  env: us-east-1-ocf
EOF

	my $env = $top->load_env('us-east-1-ocf');
	is($env->ocfp_type, 'ocf', 'ocfp_type() returns ocf for name ending in -ocf');

	put_file $top->path('eu-central-1-ocf.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features:
    - ocfp
genesis:
  env: eu-central-1-ocf
EOF

	$env = $top->load_env('eu-central-1-ocf');
	is($env->ocfp_type, 'ocf', 'ocfp_type() returns ocf for eu region ending in -ocf');
};

subtest 'ocfp_type() - returns ocf when no type suffix matches' => sub {
	plan tests => 1;

	my $top = make_top(name => 'cf', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file $top->path('us-east-1-prod.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features:
    - ocfp
genesis:
  env: us-east-1-prod
EOF

	my $env = $top->load_env('us-east-1-prod');
	is($env->ocfp_type, 'ocf',
		'ocfp_type() returns ocf as default when name has no -mgmt/-ocf suffix');
};

# ============================================================================
# ocfp_env() tests
# ============================================================================

subtest 'ocfp_env() - converts trailing -mgmt to slash form' => sub {
	plan tests => 2;

	my $top = make_top(name => 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file $top->path('us-east-1-mgmt.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features:
    - ocfp
genesis:
  env: us-east-1-mgmt
EOF

	my $env = $top->load_env('us-east-1-mgmt');
	is($env->ocfp_env, 'us-east-1/mgmt',
		'ocfp_env() converts us-east-1-mgmt to us-east-1/mgmt');

	put_file $top->path('ap-southeast-1-mgmt.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features:
    - ocfp
genesis:
  env: ap-southeast-1-mgmt
EOF

	$env = $top->load_env('ap-southeast-1-mgmt');
	is($env->ocfp_env, 'ap-southeast-1/mgmt',
		'ocfp_env() converts ap-southeast-1-mgmt to ap-southeast-1/mgmt');
};

subtest 'ocfp_env() - converts trailing -ocf to slash form' => sub {
	plan tests => 2;

	my $top = make_top(name => 'cf', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file $top->path('us-west-2-ocf.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features:
    - ocfp
genesis:
  env: us-west-2-ocf
EOF

	my $env = $top->load_env('us-west-2-ocf');
	is($env->ocfp_env, 'us-west-2/ocf',
		'ocfp_env() converts us-west-2-ocf to us-west-2/ocf');

	put_file $top->path('eu-west-1-ocf.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features:
    - ocfp
genesis:
  env: eu-west-1-ocf
EOF

	$env = $top->load_env('eu-west-1-ocf');
	is($env->ocfp_env, 'eu-west-1/ocf',
		'ocfp_env() converts eu-west-1-ocf to eu-west-1/ocf');
};

subtest 'ocfp_env() - appends type for non-terminal mgmt/ocf segment' => sub {
	plan tests => 2;

	my $top = make_top(name => 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	# -mgmt- in the middle: ocfp-aws-mgmt-us-east-1 -> ocfp-aws-mgmt-us-east-1/mgmt
	put_file $top->path('ocfp-aws-mgmt-us-east-1.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features:
    - ocfp
genesis:
  env: ocfp-aws-mgmt-us-east-1
EOF

	my $env = $top->load_env('ocfp-aws-mgmt-us-east-1');
	is($env->ocfp_env, 'ocfp-aws-mgmt-us-east-1/mgmt',
		'ocfp_env() appends /mgmt when -mgmt- appears in middle of name');

	# mgmt- at the beginning: mgmt-production -> mgmt-production/mgmt
	put_file $top->path('mgmt-production.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features:
    - ocfp
genesis:
  env: mgmt-production
EOF

	$env = $top->load_env('mgmt-production');
	is($env->ocfp_env, 'mgmt-production/mgmt',
		'ocfp_env() appends /mgmt when mgmt- appears at start of name');
};

subtest 'ocfp_env() - appends /ocf for names with no mgmt/ocf segment' => sub {
	plan tests => 1;

	my $top = make_top(name => 'cf', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file $top->path('us-east-1-prod.yml'), <<EOF;
---
kit:
  name: dev
  version: latest
  features:
    - ocfp
genesis:
  env: us-east-1-prod
EOF

	my $env = $top->load_env('us-east-1-prod');
	is($env->ocfp_env, 'us-east-1-prod/ocf',
		'ocfp_env() appends /ocf as default when no mgmt/ocf segment found');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
