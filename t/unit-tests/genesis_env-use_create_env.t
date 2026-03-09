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
$Genesis::VERSION = '999.999.999'; # force dev mode for testing
use_ok 'Genesis::Config';
$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");

use_ok 'Genesis::Top';
use_ok 'Genesis::Env';
use_ok 'Genesis::Kit';

$ENV{GENESIS_OUTPUT_COLUMNS}=80;
$ENV{NOCOLOR}=1;

# This test file comprehensively tests the use_create_env accessor method,
# which has complex logic based on:
# - Kit's genesis_version_min
# - Kit's use_create_env setting (yes/no/allowed/unspecified)
# - Kit's is_bosh_director flag
# - Environment's genesis.use_create_env setting
# - Environment's genesis.bosh_env presence
# - Environment's features (proto, bosh-init, create-env)

subtest 'kit requires use_create_env: yes' => sub {
	plan tests => 4;

	# Test with both boolean yes and string "yes" to ensure they work identically
	for my $kit_name ('kit-uce-yes-bool', 'kit-uce-yes-string') {
		my $top = Genesis::Top->create(workdir(), 'bosh', no_vault => 1);
		$top->link_dev_kit("t/src/$kit_name");

		# Test 1: Kit forces create-env, env has no settings
		put_file($top->path('default.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: default
EOF

		my $env = $top->load_env('default');
		ok($env->use_create_env, "$kit_name: kit requires create-env, env defaults to true");

		# Test 2: Kit forces create-env, env specifies bosh_env (should error)
		put_file($top->path('conflict.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env:      conflict
  bosh_env: parent-bosh
EOF

		throws_ok { $top->load_env('conflict')->use_create_env }
			qr/only allows create-env.*bosh_env/ims,
			"$kit_name: kit requires create-env, env with bosh_env throws error";
	}
};

subtest 'kit prohibits use_create_env: no' => sub {
	plan tests => 4;

	# Test with both boolean no and string "no" to ensure they work identically
	for my $kit_name ('kit-uce-no-bool', 'kit-uce-no-string') {
		my $top = Genesis::Top->create(workdir(), 'bosh', no_vault => 1);
		$top->link_dev_kit("t/src/$kit_name");

		# Test 1: Kit prohibits create-env, env provides bosh_env
		put_file($top->path('normal.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env:      normal
  bosh_env: parent-bosh
EOF

		my $env = $top->load_env('normal');
		ok(!$env->use_create_env, "$kit_name: kit prohibits create-env, returns false");

		# Test 2: Kit prohibits create-env, env has no bosh_env (should error)
		put_file($top->path('no-target.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: no-target
EOF

		throws_ok { $top->load_env('no-target')->use_create_env }
			qr/must specify.*bosh_env/is,
			"$kit_name: kit prohibits create-env, no bosh_env throws error";
	}
};

subtest 'kit allows user choice: allow' => sub {
	plan tests => 10;

	my $top = Genesis::Top->create(workdir(), 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/kit-uce-allow');

	# Test 1: Explicit use_create_env: true
	put_file($top->path('explicit-true.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env:            explicit-true
  use_create_env: true
EOF

	my $env = $top->load_env('explicit-true');
	ok($env->use_create_env, 'allowed kit: env explicitly sets use_create_env: true');

	# Test 2: Explicit use_create_env: false with bosh_env
	put_file($top->path('explicit-false.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env:            explicit-false
  use_create_env: false
  bosh_env:       parent-bosh
EOF

	$env = $top->load_env('explicit-false');
	ok(!$env->use_create_env, 'allowed kit: env explicitly sets use_create_env: false');

	# Test 3: No explicit setting, no bosh_env (2.8.0+ defaults to true for BOSH)
	put_file($top->path('default-no-bosh.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: default-no-bosh
EOF

	$env = $top->load_env('default-no-bosh');
	ok($env->use_create_env, 'allowed kit: 2.8.0+ BOSH defaults to create-env without bosh_env');

	# Test 4: No explicit setting, with bosh_env (defaults to false)
	put_file($top->path('default-with-bosh.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env:      default-with-bosh
  bosh_env: parent-bosh
EOF

	$env = $top->load_env('default-with-bosh');
	ok(!$env->use_create_env, 'allowed kit: 2.8.0+ with bosh_env defaults to not create-env');

	# Test 5: proto feature forces create-env
	put_file($top->path('proto.yml'), <<EOF);
---
kit:
  name:     dev
  version:  latest
  features:
    - proto
genesis:
  env: proto
EOF

	$env = $top->load_env('proto');
	ok($env->use_create_env, 'allowed kit: proto feature forces create-env');

	# Test 6: proto feature with bosh_env (should error)
	put_file($top->path('proto-conflict.yml'), <<EOF);
---
kit:
  name:     dev
  version:  latest
  features:
    - proto
genesis:
  env:      proto-conflict
  bosh_env: parent-bosh
EOF

	throws_ok { $top->load_env('proto-conflict')->use_create_env }
		qr/bosh_env.*create-env.*proto/is,
		'allowed kit: proto feature with bosh_env throws error';

	# Test 7: Conflicting use_create_env: true and bosh_env
	put_file($top->path('conflict.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env:            conflict
  use_create_env: true
  bosh_env:       parent-bosh
EOF

	throws_ok { $top->load_env('conflict')->use_create_env }
		qr/bosh_env.*create-env/is,
		'allowed kit: explicit use_create_env: true with bosh_env throws error';

	# Test 8: String "yes" treated as truthy
	put_file($top->path('string-yes.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env:            string-yes
  use_create_env: 'yes'
EOF

	$env = $top->load_env('string-yes');
	ok($env->use_create_env, 'allowed kit: use_create_env: "yes" (string) is truthy');

	# Test 9: YAML boolean no
	put_file($top->path('bool-no.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env:            bool-no
  use_create_env: no
  bosh_env:       parent-bosh
EOF

	$env = $top->load_env('bool-no');
	ok(!$env->use_create_env, 'allowed kit: use_create_env: no (YAML boolean) is falsy');

	# Test 10: String "no" should be treated as string (truthy in Perl)
	put_file($top->path('string-no.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env:            string-no
  use_create_env: 'no'
EOF

	$env = $top->load_env('string-no');
	ok($env->use_create_env, 'allowed kit: use_create_env: "no" (string) is truthy');
};

subtest 'kit with no use_create_env specified (2.8.0+)' => sub {
	plan tests => 6;

	# Test 1: BOSH director kit with no use_create_env, no bosh_env
	my $top = Genesis::Top->create(workdir(), 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/kit-uce-blank-bosh');

	put_file($top->path('default.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: default
EOF

	my $env = $top->load_env('default');
	ok($env->use_create_env, 'blank kit (BOSH): defaults to create-env without bosh_env');

	# Test 2: BOSH director kit with no use_create_env, with bosh_env
	put_file($top->path('with-bosh.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env:      with-bosh
  bosh_env: parent-bosh
EOF

	$env = $top->load_env('with-bosh');
	ok(!$env->use_create_env, 'blank kit (BOSH): with bosh_env defaults to not create-env');

	# Test 3: BOSH director kit, explicit use_create_env: true
	put_file($top->path('explicit-true.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env:            explicit-true
  use_create_env: true
EOF

	$env = $top->load_env('explicit-true');
	ok($env->use_create_env, 'blank kit (BOSH): env can explicitly set use_create_env: true');

	# Test 4: Non-BOSH kit with no use_create_env
	my $top2 = Genesis::Top->create(workdir(), 'cf', no_vault => 1);
	$top2->link_dev_kit('t/src/kit-uce-blank-nonbosh');

	put_file($top2->path('cf-env.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: cf-env
EOF

	$env = $top2->load_env('cf-env');
	ok(!$env->use_create_env, 'blank kit (non-BOSH): defaults to not create-env');

	# Test 5: Non-BOSH kit with explicit use_create_env: true
	put_file($top2->path('cf-create.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env:            cf-create
  use_create_env: true
EOF

	$env = $top2->load_env('cf-create');
	ok($env->use_create_env, 'blank kit (non-BOSH): env can explicitly set use_create_env: true');

	# Test 6: Non-BOSH kit with explicit use_create_env: false
	put_file($top2->path('cf-deploy.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env:            cf-deploy
  use_create_env: false
  bosh_env:       parent-bosh
EOF

	$env = $top2->load_env('cf-deploy');
	ok(!$env->use_create_env, 'blank kit (non-BOSH): env can explicitly set use_create_env: false');
};

subtest 'legacy kits (pre-2.8.0)' => sub {
	plan tests => 8;
	local $Genesis::VERSION = '2.7.9'; # simulate legacy version

	# Test 1: Legacy BOSH kit with proto feature
	my $top = Genesis::Top->create(workdir(), 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/kit-legacy-bosh');

	put_file($top->path('proto.yml'), <<EOF);
---
kit:
  name:     dev
  version:  latest
  features:
    - proto
genesis:
  env: proto
EOF

	my $env = $top->load_env('proto');
	ok($env->use_create_env, 'legacy BOSH kit: proto feature uses create-env');

	# Test 2: Legacy BOSH kit with bosh-init feature
	put_file($top->path('bosh-init.yml'), <<EOF);
---
kit:
  name:     dev
  version:  latest
  features:
    - bosh-init
genesis:
  env: bosh-init
EOF

	$env = $top->load_env('bosh-init');
	ok($env->use_create_env, 'legacy BOSH kit: bosh-init feature uses create-env');

	# Test 3: Legacy BOSH kit with create-env feature
	put_file($top->path('create-env.yml'), <<EOF);
---
kit:
  name:     dev
  version:  latest
  features:
    - create-env
genesis:
  env: create-env
EOF

	$env = $top->load_env('create-env');
	ok($env->use_create_env, 'legacy BOSH kit: create-env feature uses create-env');

	# Test 4: Legacy BOSH kit with no create-env features or bosh_env (should error)
	put_file($top->path('no-features.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: no-features
EOF

	throws_ok { $top->load_env('no-features')->use_create_env }
		qr/proto.*bosh_env|bosh_env.*proto/is,
		'legacy BOSH kit: no proto feature and no bosh_env throws error';

	# Test 5: Legacy BOSH kit with proto + bosh_env (should error)
	put_file($top->path('proto-conflict.yml'), <<EOF);
---
kit:
  name:     dev
  version:  latest
  features:
    - proto
genesis:
  env:      proto-conflict
  bosh_env: parent-bosh
EOF

	throws_ok { $top->load_env('proto-conflict')->use_create_env }
		qr/bosh_env.*create-env.*proto/is,
		'legacy BOSH kit: proto + bosh_env throws error';

	# Test 6: Legacy non-BOSH kit always returns false
	my $top2 = Genesis::Top->create(workdir(), 'cf', no_vault => 1);
	$top2->link_dev_kit('t/src/kit-legacy-nonbosh');

	put_file($top2->path('cf.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: cf
EOF

	$env = $top2->load_env('cf');
	ok(!$env->use_create_env, 'legacy non-BOSH kit: always returns false');

	# Test 7: Legacy non-BOSH kit with proto feature (still false)
	put_file($top2->path('cf-proto.yml'), <<EOF);
---
kit:
  name:     dev
  version:  latest
  features:
    - proto
genesis:
  env: cf-proto
EOF

	$env = $top2->load_env('cf-proto');
	ok(!$env->use_create_env, 'legacy non-BOSH kit: proto feature has no effect (not BOSH)');

	# Test 8: Legacy BOSH kit with bosh_env
	put_file($top->path('with-bosh.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env:      with-bosh
  bosh_env: parent-bosh
EOF

	$env = $top->load_env('with-bosh');
	ok(!$env->use_create_env, 'legacy BOSH kit: with bosh_env returns false');
};

subtest 'edge cases and validation' => sub {
	plan tests => 25;

	my $top = Genesis::Top->create(workdir(), 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/kit-uce-allow');

	# Test 1: use_create_env with various truthy values
	my $counter = 0;
	for my $value (1, 'true', 'yes', 'YES', 'True', 'TRUE','"true"', '"yes"', '"YES"', '"1"', '"TRUE"') {
		$counter++;
		my $env_name = "truthy-$counter";
		put_file($top->path("$env_name.yml"), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env:            $env_name
  use_create_env: $value
EOF

		my $env = $top->load_env($env_name);
		ok($env->use_create_env, "use_create_env: $value is treated as truthy");
	}

	# Test 2: use_create_env with various falsy values (with bosh_env)
	$counter = 0;
	for my $value (0, 'false', 'False', 'FALSE', 'no', 'NO', 'No', '"0"', "'false'", "'no'", '"FALSE"') {
		$counter++;
		my $env_name = "falsy-$counter";
		put_file($top->path("$env_name.yml"), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env:            $env_name
  use_create_env: $value
  bosh_env:       parent-bosh
EOF

		my $env = $top->load_env($env_name);
		ok(!$env->use_create_env, "use_create_env: $value is treated as falsy");
	}

	# Test 3: Memoization - calling use_create_env multiple times returns same result
	put_file($top->path('memoize.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: memoize
EOF

	my $env = $top->load_env('memoize');
	my $result1 = $env->use_create_env;
	my $result2 = $env->use_create_env;
	my $result3 = $env->use_create_env;
	is($result1, $result2, 'use_create_env is memoized (call 1 == call 2)');
	is($result2, $result3, 'use_create_env is memoized (call 2 == call 3)');

	# Test 4: Invalid value caught at load time
	put_file($top->path('invalid.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env:            invalid
  use_create_env: maybe
EOF

	throws_ok { $top->load_env('invalid') }
		qr/Invalid value.*use_create_env.*yes.*no.*true.*false/is,
		'Invalid use_create_env value caught at load time';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
