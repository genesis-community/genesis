#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::Exception;
use Test::Deep;
use Test::Output;
use Test::Differences;

use_ok 'Genesis::Env';
use Genesis::Top;
use Genesis;

fake_bosh;

subtest 'new() validation' => sub {
	throws_ok { Genesis::Env->new() }
		qr/no 'name' specified.*this is a bug/is;

	throws_ok { Genesis::Env->new(name => 'foo') }
		qr/no 'top' specified.*this is a bug/is;
};

subtest 'name validation' => sub {
	lives_ok { Genesis::Env->validate_name("my-new-env"); }
		"my-new-env is a good enough name";

	throws_ok { Genesis::Env->validate_name(""); }
		qr/must not be empty/i;

	throws_ok { Genesis::Env->validate_name("my\tnew env\n"); }
		qr/must not contain whitespace/i;

	throws_ok { Genesis::Env->validate_name("my-new-!@#%ing-env"); }
		qr/can only contain lowercase letters, numbers, and hyphens/i;

	throws_ok { Genesis::Env->validate_name("-my-new-env"); }
		qr/must start with a .*letter/i;
	throws_ok { Genesis::Env->validate_name("my-new-env-"); }
		qr/must not end with a hyphen/i;

	throws_ok { Genesis::Env->validate_name("my--new--env"); }
		qr/must not contain sequential hyphens/i;

	for my $ok (qw(
		env1
		us-east-1-prod
		this-is-a-really-long-hyphenated-name-oh-god-why-would-you-do-this-to-yourself
		company-us_east_1-prod
	)) {
		lives_ok { Genesis::Env->validate_name($ok); } "$ok is a valid env name";
	}
};

subtest 'loading' => sub {
	my $top = Genesis::Top->create(workdir, 'thing');
	$top->link_dev_kit('t/src/simple');
	put_file $top->path("standalone.yml"), <<EOF;
---
kit:
  name:    dev
  version: latest
  features: []

params:
  env: standalone
EOF

	lives_ok { $top->load_env('standalone') }
	         "should be able to load the `standalone' environment.";
	lives_ok { $top->load_env('standalone.yml') }
	         "should be able to load an environment by filename.";
};

subtest 'env-to-env relation' => sub {
	my $a = bless({ name => "us-west-1-preprod-a" }, 'Genesis::Env');
	my $b = bless({ name => "us-west-1-prod"      }, 'Genesis::Env');

	cmp_deeply([$a->relate($b)], [qw[
			./us.yml
			./us-west.yml
			./us-west-1.yml
			./us-west-1-preprod.yml
			./us-west-1-preprod-a.yml
		]], "(us-west-1-preprod-a)->relate(us-west-1-prod) should return correctly");

	cmp_deeply([$a->relate($b, ".cache")], [qw[
			.cache/us.yml
			.cache/us-west.yml
			.cache/us-west-1.yml
			./us-west-1-preprod.yml
			./us-west-1-preprod-a.yml
		]], "relate() should handle cache prefixes, if given");

	cmp_deeply([$a->relate($b, ".cache", "TOP/LEVEL")], [qw[
			.cache/us.yml
			.cache/us-west.yml
			.cache/us-west-1.yml
			TOP/LEVEL/us-west-1-preprod.yml
			TOP/LEVEL/us-west-1-preprod-a.yml
		]], "relate() should handle cache and top prefixes, if both are given");

	cmp_deeply([$a->relate("us-east-sandbox", ".cache", "TOP/LEVEL")], [qw[
			.cache/us.yml
			TOP/LEVEL/us-west.yml
			TOP/LEVEL/us-west-1.yml
			TOP/LEVEL/us-west-1-preprod.yml
			TOP/LEVEL/us-west-1-preprod-a.yml
		]], "relate() should take names for \$them, in place of actual Env objects");

	cmp_deeply([$a->relate($a, ".cache", "TOP/LEVEL")], [qw[
			.cache/us.yml
			.cache/us-west.yml
			.cache/us-west-1.yml
			.cache/us-west-1-preprod.yml
			.cache/us-west-1-preprod-a.yml
		]], "relate()-ing an env to itself should work (if a little depraved)");

	cmp_deeply([$a->relate(undef, ".cache", "TOP/LEVEL")], [qw[
			TOP/LEVEL/us.yml
			TOP/LEVEL/us-west.yml
			TOP/LEVEL/us-west-1.yml
			TOP/LEVEL/us-west-1-preprod.yml
			TOP/LEVEL/us-west-1-preprod-a.yml
		]], "relate()-ing to nothing (undef) should treat everything as unique");

	cmp_deeply(scalar $a->relate($b, ".cache", "TOP/LEVEL"), {
			common => [qw[
				.cache/us.yml
				.cache/us-west.yml
				.cache/us-west-1.yml
			]],
			unique => [qw[
				TOP/LEVEL/us-west-1-preprod.yml
				TOP/LEVEL/us-west-1-preprod-a.yml
			]],
		}, "relate() in scalar mode passes back a hashref");

	{
		local $ENV{PREVIOUS_ENV} = 'us-west-1-sandbox';
		cmp_deeply([$a->potential_environment_files()], [qw[
				.genesis/cached/us-west-1-sandbox/us.yml
				.genesis/cached/us-west-1-sandbox/us-west.yml
				.genesis/cached/us-west-1-sandbox/us-west-1.yml
				./us-west-1-preprod.yml
				./us-west-1-preprod-a.yml
			]], "potential_environment_files() called with PREVIOUS_ENV should leverage the Genesis cache");
		}
};

subtest 'environment metadata' => sub {
	my $top = Genesis::Top->create(workdir, 'thing');
	$top->download_kit('bosh/0.2.0');
	put_file $top->path("standalone.yml"), <<EOF;
---
kit:
  name:    bosh
  version: 0.2.0
  features:
    - vsphere
    - proto

params:
  env:     standalone
  state:   awesome
  running: yes
  false:   ~
EOF

	my $env = $top->load_env('standalone');
	is($env->name, "standalone", "an environment should know its name");
	is($env->file, "standalone.yml", "an environment should know its file path");
	is($env->deployment, "standalone-thing", "an environment should know its deployment name");
	is($env->kit->id, "bosh/0.2.0", "an environment can ask the kit for its kit name/version");
};

subtest 'parameter lookup' => sub {
	my $top = Genesis::Top->create(workdir, 'thing');
	$top->download_kit('bosh/0.2.0');
	put_file $top->path("standalone.yml"), <<EOF;
---
kit:
  name:    bosh
  version: 0.2.0
  features:
    - vsphere
    - proto

params:
  env:     standalone
  state:   awesome
  running: yes
  false:   ~
EOF

	my $env;
	throws_ok { $top->load_env('enoent');   } qr/enoent.yml does not exist/;
	throws_ok { $top->load_env('e-no-ent'); } qr/does not exist/;

	lives_ok { $env = $top->load_env('standalone') }
	         "Genesis::Env should be able to load the `standalone' environment.";

	ok($env->defines('params.state'), "standalone.yml should define params.state");
	is($env->lookup('params.state'), "awesome", "params.state in standalone.yml should be 'awesome'");
	ok($env->defines('params.false'), "params with falsey values should still be considered 'defined'");
	ok(!$env->defines('params.enoent'), "standalone.yml should not define params.enoent");
	is($env->lookup('params.enoent', 'MISSING'), 'MISSING',
		"params lookup should return the default value is the param is not defined");
	is($env->lookup('params.false', 'MISSING'), undef,
		"params lookup should return falsey values if they are set");

	cmp_deeply([$env->features], [qw[vsphere proto]],
		"features() returns the current features");
	ok($env->has_feature('vsphere'), "standalone env has the vsphere feature");
	ok($env->has_feature('proto'), "standalone env has the proto feature");
	ok(!$env->has_feature('xyzzy'), "standalone env doesn't have the xyzzy feature");
	ok($env->needs_bosh_create_env(),
		"environments with the 'proto' feature enabled require bosh create-env");

	put_file $top->path("regular-deploy.yml"), <<EOF;
---
kit:
  name:    bosh
  version: 0.2.0
  features:
    - vsphere

params:
  env:     regular-deploy
EOF
	lives_ok { $env = $top->load_env('regular-deploy') }
	         "Genesis::Env should be able to load the `regular-deploy' environment.";
	ok($env->has_feature('vsphere'), "regular-deploy env has the vsphere feature");
	ok(!$env->has_feature('proto'), "regular-deploy env does not have the proto feature");
	ok(!$env->needs_bosh_create_env(),
		"environments without the 'proto' feature enabled do not require bosh create-env");
};

subtest 'manifest generation' => sub {
	my $top = Genesis::Top->create(workdir, 'thing');
	$top->link_dev_kit('t/src/fancy');
	put_file $top->path('standalone.yml'), <<EOF;
---
kit:
  name:    dev
  version: latest
  features:
    - whiskey
    - tango
    - foxtrot

params:
  env: standalone
EOF

	my $env = $top->load_env('standalone');
	cmp_deeply([$env->kit_files], [qw[
		base.yml
		addons/whiskey.yml
		addons/tango.yml
		addons/foxtrot.yml
	]], "env gets the correct kit yaml files to merge");
	cmp_deeply([$env->potential_environment_files], [qw[
		./standalone.yml
	]], "env formulates correct potential environment files to merge");
	cmp_deeply([$env->actual_environment_files], [qw[
		./standalone.yml
	]], "env detects correct actual environment files to merge");

	dies_ok { $env->manifest; } "should not be able to merge an env without a cloud-config";


	put_file $top->path(".cloud.yml"), <<EOF;
--- {}
# not really a cloud config, but close enough
EOF
	lives_ok { $env->use_cloud_config($top->path(".cloud.yml"))->manifest; }
		"should be able to merge an env with a cloud-config";

	my $mfile = $top->path(".manifest.yml");
	my ($manifest, undef) = $env->_manifest(redact => 0);
	$env->write_manifest($mfile, prune => 0);
	ok -f $mfile, "env->write_manifest should actually write the file";
	my $mcontents;
	lives_ok { $mcontents = load_yaml_file($mfile) } 'written manifest (unpruned) is valid YAML';
	cmp_deeply($mcontents, $manifest, "written manifest (unpruned) matches the raw unpruned manifest");
	cmp_deeply($mcontents, {
		name   => ignore,
		fancy  => ignore,
		addons => ignore,
		exodus => ignore,
		kit    => ignore,
		meta   => ignore,
		params => ignore
	}, "written manifest (unpruned) contains all the keys");

	ok $env->manifest_lookup('addons.foxtrot'), "env manifest defines addons.foxtrot";
	is $env->manifest_lookup('addons.bravo', 'MISSING'), 'MISSING',
		"env manifest doesn't define addons.bravo";
};

subtest 'manifest pruning' => sub {
	my $top = Genesis::Top->create(workdir, 'thing');
	$top->link_dev_kit('t/src/fancy');
	put_file $top->path(".cloud.yml"), <<EOF;
---
resource_pools: { from: 'cloud-config' }
vm_types:       { from: 'cloud-config' }
disk_pools:     { from: 'cloud-config' }
disk_types:     { from: 'cloud-config' }
networks:       { from: 'cloud-config' }
azs:            { from: 'cloud-config' }
vm_extensions:  { from: 'cloud-config' }
compilation:    { from: 'cloud-config' }
EOF

	put_file $top->path('standalone.yml'), <<EOF;
---
kit:
  name:    dev
  version: latest
  features:
    - papa    # for pruning tests
params:
  env: standalone
EOF
	my $env = $top->load_env('standalone')->use_cloud_config($top->path('.cloud.yml'));

	cmp_deeply(load_yaml($env->manifest(prune => 0)), {
		name   => ignore,
		fancy  => ignore,
		addons => ignore,

		# Genesis stuff
		meta        => ignore,
		pipeline    => ignore,
		params      => ignore,
		exodus      => ignore,
		kit         => superhashof({ name => 'dev' }),

		# cloud-config
		resource_pools => ignore,
		vm_types       => ignore,
		disk_pools     => ignore,
		disk_types     => ignore,
		networks       => ignore,
		azs            => ignore,
		vm_extensions  => ignore,
		compilation    => ignore,

	}, "unpruned manifest should have all the top-level keys");

	cmp_deeply(load_yaml($env->manifest(prune => 1)), {
		name   => ignore,
		fancy  => ignore,
		addons => ignore,
	}, "pruned manifest should not have all the top-level keys");

	my $mfile = $top->path(".manifest.yml");
	my ($manifest, undef) = $env->_manifest(redact => 0);
	$env->write_manifest($mfile);
	ok -f $mfile, "env->write_manifest should actually write the file";
	my $mcontents;
	lives_ok { $mcontents = load_yaml_file($mfile) } 'written manifest is valid YAML';
	cmp_deeply($mcontents, subhashof($manifest), "written manifest content matches unpruned manifest for values that weren't pruned");
	cmp_deeply($mcontents, {
		name   => ignore,
		fancy  => ignore,
		addons => ignore,
	}, "written manifest doesn't contain the pruned keys (no cloud-config)");
};

subtest 'manifest pruning (bosh create-env)' => sub {
	my $top = Genesis::Top->create(workdir, 'thing');
	$top->link_dev_kit('t/src/fancy');
	put_file $top->path(".cloud.yml"), <<EOF;
---
ignore: cloud-config
EOF

	# create-env
	put_file $top->path('proto.yml'), <<EOF;
---
kit:
  name:    dev
  version: latest
  features:
    - papa     # for pruning tests
    - proto
params:
  env: proto
EOF
	my $env = $top->load_env('proto')->use_cloud_config($top->path('.cloud.yml'));
	ok $env->needs_bosh_create_env, "'proto' test env needs create-env";

	cmp_deeply(load_yaml($env->manifest(prune => 0)), {
		name   => ignore,
		fancy  => ignore,
		addons => ignore,

		# Genesis stuff
		meta        => ignore,
		pipeline    => ignore,
		params      => ignore,
		exodus      => ignore,
		kit         => superhashof({ name => 'dev' }),

		# BOSH stuff
		compilation => ignore,

		# "cloud-config"
		resource_pools => ignore,
		vm_types       => ignore,
		disk_pools     => ignore,
		disk_types     => ignore,
		networks       => ignore,
		azs            => ignore,
		vm_extensions  => ignore,

	}, "unpruned proto-style manifest should have all the top-level keys");

	cmp_deeply(load_yaml($env->manifest(prune => 1)), {
		name   => ignore,
		fancy  => ignore,
		addons => ignore,

		# "cloud-config"
		resource_pools => ignore,
		vm_types       => ignore,
		disk_pools     => ignore,
		disk_types     => ignore,
		networks       => ignore,
		azs            => ignore,
		vm_extensions  => ignore,
	}, "pruned proto-style manifest should retain 'cloud-config' keys, since create-env needs them");

	my $mfile = $top->path(".manifest-create-env.yml");
	my ($manifest, undef) = $env->_manifest(redact => 0);
	$env->write_manifest($mfile);
	ok -f $mfile, "env->write_manifest should actually write the file";
	my $mcontents;
	lives_ok { $mcontents = load_yaml_file($mfile) } 'written manifest for bosh-create-env is valid YAML';
	cmp_deeply($mcontents, subhashof($manifest), "written manifest for bosh-create-env content matches unpruned manifest for values that weren't pruned");
	cmp_deeply($mcontents, {
		name   => ignore,
		fancy  => ignore,
		addons => ignore,

		# "cloud-config"
		resource_pools => ignore,
		vm_types       => ignore,
		disk_pools     => ignore,
		disk_types     => ignore,
		networks       => ignore,
		azs            => ignore,
		vm_extensions  => ignore,
	}, "written manifest for bosh-create-env doesn't contain the pruned keys (includes cloud-config)");
};

subtest 'exodus data' => sub {
	my $top = Genesis::Top->create(workdir, 'thing');
	$top->link_dev_kit('t/src/fancy');
	put_file $top->path('standalone.yml'), <<EOF;
---
kit:
  name:    dev
  version: latest
  features:
    - echo    # for pruning tests
params:
  env: standalone
EOF
	put_file $top->path(".cloud.yml"), <<EOF;
--- {}
# not really a cloud config, but close enough
EOF

	my $env = $top->load_env('standalone')->use_cloud_config($top->path('.cloud.yml'));
	cmp_deeply($env->exodus, {
			version       => ignore,
			dated         => re(qr/\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d/),
			deployer      => ignore,
			kit_name      => 'dev',
			kit_version   => 'latest',
			'addons[0]'    => 'echo',
			vault_base    => 'secret/standalone/thing',

			'hello.world' => 'i see you',

			# we allow multi-level arrays now
			'multilevel.arrays[0]' => 'so',
			'multilevel.arrays[1]' => 'useful',

			# we allow multi-level maps now
			'three.levels.works'            => 'now',
			'three.levels.or.more.is.right' => 'on, man!',
		}, "env manifest can provide exodus with flattened keys");

	my $good_flattened = {
		key => "value",
		another_key => "another value",

		# flattened hash
		'this.is.a.test' => '100%',
		'this.is.a.dog'  => 'woof',
		'this.is.sparta' => 300,

		# flattened array
		'matrix[0][0]' => -2,
		'matrix[0][1]' =>  4,
		'matrix[1][0]' =>  2,
		'matrix[1][1]' => -4,

		# flattened array of hashes
		'network[0].name' => 'default',
		'network[0].subnet' => '10.0.0.0/24',
		'network[1].name' => 'super-special',
		'network[1].subnet' => '10.0.1.0/24',
		'network[2].name' => 'secret',
		'network[2].subnet' => '10.0.2.0/24',
	};


	cmp_deeply(Genesis::Env::_unflatten($good_flattened), {
		key => "value",
		another_key => "another value",
		this => {
			is => {
				a => {
					test => '100%',
					dog  => 'woof',
				},
				sparta => 300,
			}
		},
		matrix => [
			[-2, 4],
			[ 2,-4]
		],
		network => [
			{
				name => 'default',
				subnet => '10.0.0.0/24',
			}, {
				name => 'super-special',
				subnet => '10.0.1.0/24',
			}, {
				name => 'secret',
				subnet => '10.0.2.0/24',
			}
		]
	}, "exodus data can be correctly unflattened")
};

subtest 'bosh targeting' => sub {
	local $ENV{GENESIS_BOSH_COMMAND};
	fake_bosh;

	my $env;
	my $top = Genesis::Top->create(workdir, 'thing')->link_dev_kit('t/src/fancy');
	put_file $top->path('standalone.yml'), <<EOF;
---
kit:
  name:    dev
  version: latest
params:
  env: standalone
EOF

	$env = $top->load_env('standalone');
	is $env->bosh_target, "standalone", "without a params.bosh, params.env is the BOSH target";

	put_file $top->path('standalone.yml'), <<EOF;
---
kit:
  name:    dev
  version: latest
params:
  env: standalone
  bosh: override-me
EOF

	$env = $top->load_env('standalone');
	is $env->bosh_target, "override-me", "with a params.bosh, it becomes the BOSH target";

	{
		$env = $top->load_env('standalone');
		local $ENV{GENESIS_BOSH_ENVIRONMENT} = "https://127.0.0.86:25555";
		$env = $top->load_env('standalone'); # reload otherwise its cached by the previous call
		is $env->bosh_target, "https://127.0.0.86:25555", "the \$GENESIS_BOSH_ENVIRONMENT overrides all";
	}
};

subtest 'cloud_config_and_deployment' => sub{
	local $ENV{GENESIS_BOSH_COMMAND};
	fake_bosh;
	my $vault_target = vault_ok;
	`safe set --quiet secret/code word='penguin'`;

	my $env;
	my $top = Genesis::Top->create(workdir, 'thing')->link_dev_kit('t/src/fancy');
	put_file $top->path('standalone.yml'), <<EOF;
---
kit:
  name:    dev
  version: latest
params:
  env: standalone
EOF

	$env = $top->load_env('standalone');
	
	lives_ok { $env->download_cloud_config(); }
		"download_cloud_config runs correctly";

	ok -f $env->{ccfile}, "download_cloud_config created cc file";
	eq_or_diff get_file($env->{ccfile}), <<EOF, "download_cloud_config calls BOSH correctly";
bosh
-e
standalone
cloud-config
EOF

	put_file $env->{ccfile}, <<EOF;
---
something: (( vault "secret/code:word" ))
EOF

	is($env->lookup("something","goose"), "goose", "Environment doesn't contain cloud config details");
	is($env->manifest_lookup("something","goose"), "penguin", "Manifest contains cloud config details");
	my ($manifest_file, $exists, $sha1) = $env->cached_manifest_info;
	ok $manifest_file eq $env->path(".genesis/manifests/".$env->name.".yml"), "cached manifest path correctly determined";
	ok ! $exists, "manifest file doesn't exist.";
	ok ! defined($sha1), "sha1 sum for manifest not computed.";
	stdout_is(sub {$env->deploy()}, <<EOF,
bosh
-e
standalone
-d
standalone-thing
deploy
$env->{__tmp}/manifest.yml
--no-redact
EOF
		"Deploy should call BOSH with the correct options");

	($manifest_file, $exists, $sha1) = $env->cached_manifest_info;
	ok $manifest_file eq $env->path(".genesis/manifests/".$env->name.".yml"), "cached manifest path correctly determined";
	ok $exists, "manifest file should exist.";
	ok $sha1 =~ /[a-f0-9]{40}/, "cached manifest calculates valid SHA-1 checksum";
	ok -f $manifest_file, "deploy created cached redacted manifest file";

	# Compare the raw exodus data
	#
	runs_ok('safe exists "secret/exodus/standalone/thing"', 'exodus entry created in vault');
	my ($pass, $rc, $out) = runs_ok('safe get "secret/exodus/standalone/thing" | spruce json #');
	my $exodus = load_json($out);
	cmp_deeply($exodus, {
				dated => re(qr/\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d \+0000/),
				deployer => $ENV{USER},
				kit_name => "dev",
				kit_version => "latest",
				bosh => "standalone",
				vault_base => "secret/standalone/thing",
				version => '(development)',
				manifest_sha1 => $sha1,
				'hello.world' => 'i see you',
				'multilevel.arrays[0]' => 'so',
				'multilevel.arrays[1]' => 'useful',
				'three.levels.or.more.is.right' => 'on, man!',
				'three.levels.works' => 'now'
			}, "exodus data was written by deployment");

	is($env->last_deployed_lookup("something","goose"), "REDACTED", "Cached manifest contains redacted vault details");
	is($env->last_deployed_lookup("fancy.status","none"), "online", "Cached manifest contains non-redacted params");
	is($env->last_deployed_lookup("params.env","none"), "standalone", "Cached manifest contains pruned params");
	cmp_deeply($env->exodus_lookup("",{}), {
				dated => $exodus->{dated},
				deployer => $ENV{USER},
				bosh => "standalone",
				kit_name => "dev",
				kit_version => "latest",
				vault_base => "secret/standalone/thing",
				version => '(development)',
				manifest_sha1 => $sha1,
				hello => {
					world => 'i see you'
				},
				multilevel => {
					arrays => ['so','useful']
				},
				three => {
					levels => {
						'or'    => { more => {is => {right => 'on, man!'}}},
						'works' => 'now'
					}
				}
			}, "exodus data was written by deployment");

	teardown_vault();
};

done_testing;
