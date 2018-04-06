#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::Exception;
use Test::Deep;

use_ok 'Genesis::Env';
use Genesis::Top;
use Genesis::Utils;

subtest 'new() validation' => sub {
	throws_ok { Genesis::Env->new() }
		qr/no 'name' specified.*this is a bug/i;

	throws_ok { Genesis::Env->new(name => 'foo') }
		qr/no 'top' specified.*this is a bug/i;
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
	my $tmp = workdir."/work";
	my $top = Genesis::Top->new($tmp);

	system("rm -rf $tmp; mkdir -p $tmp");
	put_file "$tmp/.genesis/config", <<EOF;
---
genesis:         2.6.0
deployment_type: thing
EOF

	put_file "$tmp/standalone.yml", <<EOF;
---
kit:
  name:    bosh
  version: 0.2.3
  features:
    - vsphere
    - proto

params:
  env:     standalone
  state:   awesome
  running: yes
  false:   ~
EOF

	put_file "$tmp/.genesis/kits/bosh-0.2.3.tar.gz", "not a tarball.  sorry.";

	my $env;
	lives_ok { $env = $top->load_env('standalone') }
	         "Genesis::Env should be able to load the `standalone' environment.";

	is($env->name, "standalone", "an environment should know its name");
	is($env->file, "standalone.yml", "an environment should know its file path");
	is($env->deployment, "standalone-thing", "an environment should know its deployment name");
	is($env->kit->id, "bosh/0.2.3", "an environment can ask the kit for its kit name/version");
};

subtest 'parameter lookup' => sub {
	my $tmp = workdir."/work";
	my $top = Genesis::Top->new($tmp);

	system("rm -rf $tmp; mkdir -p $tmp");
	put_file "$tmp/.genesis/config", <<EOF;
---
genesis:         2.6.0
deployment_type: thing
EOF

	put_file "$tmp/standalone.yml", <<EOF;
---
kit:
  name:    bosh
  version: 0.2.3
  features:
    - vsphere
    - proto

params:
  env:     standalone
  state:   awesome
  running: yes
  false:   ~
EOF

	put_file "$tmp/.genesis/kits/bosh-0.2.3.tar.gz", "not a tarball.  sorry.";

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

	put_file "$tmp/regular-deploy.yml", <<EOF;
---
kit:
  name:    bosh
  version: 0.2.3
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
	my $tmp = workdir."/work";
	my $top = Genesis::Top->new($tmp);

	system("rm -rf $tmp; mkdir -p $tmp");
	put_file "$tmp/.genesis/config", <<EOF;
---
genesis:         2.6.0
deployment_type: thing
EOF

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

	symlink_or_fail Cwd::abs_path("t/src/fancy"), $top->path('dev');
	ok $top->has_dev_kit, "working directory should have a dev kit now";
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


	put_file "$tmp/.cloud.yml", <<EOF;
--- {}
# not really a cloud config, but close enough
EOF
	lives_ok { $env->use_cloud_config("$tmp/.cloud.yml")->manifest; }
		"should be able to merge an env with a cloud-config";

	$env->write_manifest("$tmp/.manifest.yml");
	ok -f "$tmp/.manifest.yml", "env->write_manifest should actually write the file";
	ok -s "$tmp/.manifest.yml" > -s "$tmp/standalone.yml",
		"written manifest should be at least as big as the env file";

	ok $env->manifest_lookup('addons.foxtrot'), "env manifest defines addons.foxtrot";
	is $env->manifest_lookup('addons.bravo', 'MISSING'), 'MISSING',
		"env manifest doesn't define addons.bravo";

	cmp_deeply($env->exodus, {
			kit_name      => 'dev',
			kit_version   => 'latest',
			vault_base    => 'secret/standalone/thing',
			'addons.0'    => 'foxtrot',
			'addons.1'    => 'tango',
			'addons.2'    => 'whiskey',
			'hello.world' => 'i see you',
		}, "env manifest can provide exodus with flattened keys");

	cmp_deeply(load_yaml($env->manifest(prune => 0)),
		superhashof({
			kit => superhashof({
				name => 'dev',
			}),
		}), "unpruned manifest should have the `kit` toplevel");

	cmp_deeply(load_yaml($env->manifest(prune => 1)), {
		name   => ignore,
		fancy  => ignore,
		addons => ignore,
	}, "pruned manifest should not contain the `kit` toplevel");
};

subtest 'bosh targeting' => sub {
	my $tmp = workdir."/work";
	my $top = Genesis::Top->new($tmp);
	my $env;

	system("rm -rf $tmp; mkdir -p $tmp");
	put_file("$tmp/fake-bosh", <<EOF);
#!/bin/bash
# this is AGREEABLE BOSH...
exit 0
EOF
	chmod(0755, "$tmp/fake-bosh");
	local $ENV{GENESIS_BOSH_COMMAND} = "$tmp/fake-bosh";

	symlink_or_fail Cwd::abs_path("t/src/fancy"), $top->path('dev');

	put_file "$tmp/.genesis/config", <<EOF;
---
genesis:         2.6.0
deployment_type: thing
EOF

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
		local $ENV{GENESIS_BOSH_ENVIRONMENT} = "https://127.0.0.86:25555";
		is $env->bosh_target, "https://127.0.0.86:25555", "the \$GENESIS_BOSH_ENVIRONMENT overrides all";
	}
};

done_testing;
