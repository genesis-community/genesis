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
	ok($env->has_feature('vsphere'));
	ok($env->has_feature('proto'));
	ok(!$env->has_feature('xyzzy'));
	ok($env->needs_bosh_create_env(),
		"environments with the 'proto' feature enabled required bosh create-env");
};

done_testing;
