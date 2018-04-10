#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::Exception;
use Test::Deep;
use Test::Output;

use_ok 'Genesis::Kit';
use Genesis::Kit::Dev;
use Genesis::Top;

my $tmp = workdir;
my $top;  # Genesis::Top
my $root; # absolute path to $top's root

# test kits from t/src/*
my $simple;
my $fancy;
my $legacy;

# test environments, created on-the-fly
my $us_west_1_prod;
my $snw_lab_dev;
my $stack_scale;

sub again {
	system("rm -rf $tmp; mkdir -p $tmp");
	$top    = Genesis::Top->create($tmp, 'thing');
	$root   = $top->path;
	$simple = Genesis::Kit::Dev->new("t/src/simple");
	$fancy  = Genesis::Kit::Dev->new("t/src/fancy");
	$legacy = Genesis::Kit::Dev->new("t/src/legacy");

	put_file "$root/dev/kit.yml", "--- {}\n";
	put_file "$root/us-west-1-prod.yml", <<EOF;
---
kit:
  name:    dev
  version: latest
EOF
	$us_west_1_prod = $top->load_env('us-west-1-prod');

	put_file "$root/snw-lab-dev.yml", <<EOF;
---
kit:
  name:    dev
  version: latest
  features:
    - alpha
    - foxtrot
    - uniform
    - charlie
    - kilo
EOF
	$snw_lab_dev = $top->load_env('snw-lab-dev');

	put_file "$root/stack-scale.yml", <<EOF;
---
kit:
  name:    dev
  version: latest
  subkits:
    - do-thing
EOF
	$stack_scale = $top->load_env('stack-scale');
}

subtest 'invalid or nonexistent hooks' => sub {
	again();

	ok $fancy->has_hook('xyzzy');
	throws_ok { $fancy->run_hook('xyzzy', env => $snw_lab_dev); }
		qr/unrecognized/i;

	ok !$simple->has_hook('info');
	throws_ok { $simple->run_hook('info', env => $us_west_1_prod); }
		qr/no 'info' hook script found/i;
};

subtest 'new hook' => sub {
	again();

	ok $simple->run_hook('new', env => $us_west_1_prod),
	   "[simple] running the 'new' hook should succeed";

	ok -f "$root/us-west-1-prod.yml",
	   "[simple] the 'new' hook should create the env yaml file";

	yaml_is get_file("$root/us-west-1-prod.yml"), <<EOF,
kit:
  name:     dev
  version:  latest
  features: []
params:
  env:   us-west-1-prod
  vault: us/west/1/prod/thing
EOF
		"[simple] the 'new' hook should populate the env yaml file properly";


	ok $fancy->run_hook('new', env => $snw_lab_dev),
	   "[fancy] running the 'new' hook should succeed";
	
	ok -f "$root/snw-lab-dev.yml",
	   "[fancy] the 'new' hook should create the env yaml file";

	yaml_is get_file("$root/snw-lab-dev.yml"), <<EOF,
kit:
  name:     dev
  version:  latest
  features: []
params:
  GENESIS_KIT_NAME:     dev
  GENESIS_KIT_VERSION:  latest
  GENESIS_ENVIRONMENT:  snw-lab-dev
  GENESIS_VAULT_PREFIX: snw/lab/dev/thing
  GENESIS_ROOT:         $root

  root:   $root
  env:    snw-lab-dev
  prefix: snw/lab/dev/thing
  extra:  (none)
EOF
		"[fancy] the 'new' hook should populate the env yaml file properly";


	{
		local $ENV{HOOK_SHOULD_FAIL} = 'yes';
		throws_ok {
			$fancy->run_hook('new',
				env => Genesis::Env->new(top => $top, name => 'env-should-fail'));
		} qr/could not create/i;

		ok ! -f "$root/env-should-fail.yml",
		   "[fancy] if the 'new' hook script exists non-zero, the env file should not get created";
	}

	{
		local $ENV{HOOK_SHOULD_CREATE_ENV_FILE} = 'no';
		throws_ok {
			$fancy->run_hook('new',
				env => Genesis::Env->new(top => $top, name => 'env-should-fail'));
		} qr/could not create/i;

		ok ! -f "$root/env-should-fail.yml",
		   "[fancy] if the 'new' hook script fails, the env file shoud be missing";
	}
};

subtest 'blueprint hook' => sub {
	again();

	cmp_deeply([$simple->run_hook('blueprint', features => [$us_west_1_prod->features])], [qw[
			manifest.yml
		]], "[simple] blueprint hook should return the relative manifest file paths");

	cmp_deeply([$fancy->run_hook('blueprint', features => [$snw_lab_dev->features])], [qw[
			base.yml
			addons/alpha.yml
			addons/foxtrot.yml
			addons/uniform.yml
			addons/charlie.yml
			addons/kilo.yml
			addons/bravo.yml
		]], "[fancy] blueprint hook should return the relative manifest file paths");

	{
		local $ENV{HOOK_SHOULD_FAIL} = 'yes';
		throws_ok { $fancy->run_hook('blueprint', features => [$snw_lab_dev->features]); }
			qr/could not determine which yaml files/i;
	}

	{
		local $ENV{HOOK_NO_BLUEPRINT} = 'yes';
		throws_ok { $fancy->run_hook('blueprint', features => [$snw_lab_dev->features]); }
			qr/could not determine which yaml files/i;
	}

	{
		local $ENV{HOOK_SHOULD_BE_AIRY} = 'yes';
		cmp_deeply([$fancy->run_hook('blueprint', features => [$snw_lab_dev->features])], [qw[
				base.yml
				addons/alpha.yml
				addons/foxtrot.yml
				addons/uniform.yml
				addons/charlie.yml
				addons/kilo.yml
				addons/bravo.yml
			]], "[fancy] blueprint hook should ignore whitespace");
	}
};

subtest 'secrets hook' => sub {
	my ($rc, $s, $value);

	again();
	vault_ok();

	## secrets check
	qx(safe rm secret/snw/lab/dev/thing/args secret/snw/lab/dev/thing/env);
	stdout_is(sub { $rc = $fancy->run_hook('secrets', env => $snw_lab_dev,
	                                                  action => 'check') }, <<EOF,
[admin:password] is missing
EOF
		"[fancy] 'secrets check' hook output should be correct");
	ok !$rc, "[fancy] running the 'secrets check' hook should return failure if anything is missing";

	$s = 'secret/snw/lab/dev/thing/args';
	is secret("$s:all"), '{}', "'secrets check' hook should get no arguments";

	$s = 'secret/snw/lab/dev/thing/env';
	is secret("$s:GENESIS_KIT_NAME"),      'dev',               'check:GENESIS_KIT_NAME';
	is secret("$s:GENESIS_KIT_VERSION"),   'latest',            'check:GENESIS_KIT_VERISON';
	is secret("$s:GENESIS_ROOT"),          $top->path,          'check:GENESIS_ROOT';
	is secret("$s:GENESIS_ENVIRONMENT"),   'snw-lab-dev',       'check:GENESIS_ENVIRONMENT';
	is secret("$s:GENESIS_VAULT_PREFIX"),  'snw/lab/dev/thing', 'check:GENESIS_VAULT_PREFIX';
	is secret("$s:GENESIS_SECRET_ACTION"), 'check',             'check:GENESIS_SECRET_ACTION';


	## secrets add
	qx(safe rm secret/snw/lab/dev/thing/args secret/snw/lab/dev/thing/env);
	stdout_is(sub { $rc = $fancy->run_hook('secrets', env => $snw_lab_dev,
	                                                  action => 'add') }, <<EOF,
[admin:password] generating new administrator password
EOF
		"[fancy] 'secrets add' hook output should be correct");
	ok $rc, "[fancy] running the 'secrets add' hook should succeed";

	$s = 'secret/snw/lab/dev/thing/args';
	is secret "$s:all", '{}', "'secrets add' hook should get no arguments";

	$s = 'secret/snw/lab/dev/thing/env';
	is secret("$s:GENESIS_KIT_NAME"),      'dev',               'add:GENESIS_KIT_NAME';
	is secret("$s:GENESIS_KIT_VERSION"),   'latest',            'add:GENESIS_KIT_VERISON';
	is secret("$s:GENESIS_ROOT"),          $top->path,          'add:GENESIS_ROOT';
	is secret("$s:GENESIS_ENVIRONMENT"),   'snw-lab-dev',       'add:GENESIS_ENVIRONMENT';
	is secret("$s:GENESIS_VAULT_PREFIX"),  'snw/lab/dev/thing', 'add:GENESIS_VAULT_PREFIX';
	is secret("$s:GENESIS_SECRET_ACTION"), 'add',               'add:GENESIS_SECRET_ACTION';

	## secrets check (after an add)
	stdout_is(sub { $rc = $fancy->run_hook('secrets', env => $snw_lab_dev,
	                                                  action => 'check') }, <<EOF,
all secrets and certs present!
EOF
		"[fancy] 'secrets check' hook output should be correct");
	ok $rc, "[fancy] running the 'secrets check' hook should succeed if all secrets are present";


	## secrets rotate
	stdout_is(sub { $rc = $fancy->run_hook('secrets', env => $snw_lab_dev,
	                                                  action => 'rotate') }, <<EOF,
[admin:password] rotating administrator password
EOF
		"[fancy] 'secrets rotate' hook should succeed");

	$s = 'secret/snw/lab/dev/thing/args';
	is secret "$s:all", '{}', "'secrets rotate' hook should get no arguments";

	$s = 'secret/snw/lab/dev/thing/env';
	is secret("$s:GENESIS_KIT_NAME"),      'dev',               'rotate:GENESIS_KIT_NAME';
	is secret("$s:GENESIS_KIT_VERSION"),   'latest',            'rotate:GENESIS_KIT_VERISON';
	is secret("$s:GENESIS_ROOT"),          $top->path,          'rotate:GENESIS_ROOT';
	is secret("$s:GENESIS_ENVIRONMENT"),   'snw-lab-dev',       'rotate:GENESIS_ENVIRONMENT';
	is secret("$s:GENESIS_VAULT_PREFIX"),  'snw/lab/dev/thing', 'rotate:GENESIS_VAULT_PREFIX';
	is secret("$s:GENESIS_SECRET_ACTION"), 'rotate',            'rotate:GENESIS_SECRET_ACTION';

	teardown_vault();
};

subtest 'check hook' => sub {
	again();

	my $rc;
	stdout_is(sub { $rc = $fancy->run_hook('check', env => $snw_lab_dev) }, <<EOF,
everything checks out!
EOF
		"[fancy] check hook output should be correct");
	ok $rc, "[fancy] running the 'check' hook should succeed";

	{
		local $ENV{HOOK_SHOULD_FAIL} = 'yes';
		throws_ok { $fancy->run_hook('check', env => $snw_lab_dev) }
			qr/could not run 'check' hook/i;
	}
};

subtest 'addon hook' => sub {
	again();

	my $rc;
	stdout_is(sub {
			$rc = $fancy->run_hook('addon', env => $snw_lab_dev,
			                                script => 'stooge',
			                                args => [qw[larry curly moe]]);
		}, <<EOF,
fancy:>> executing [stooge]
  - [larry]
  - [curly]
  - [moe]
EOF
		"[fancy] addon hook output should be correct");
	ok $rc, "[fancy] running the 'addon' hook should succeed";

	stdout_is(sub {
			$rc = $fancy->run_hook('addon', env => $snw_lab_dev,
			                                script => 'stooge');
		}, <<EOF,
fancy:>> executing [stooge]
EOF
		"[fancy] addon hook output should be correct (without args)");
	ok $rc, "[fancy] running the 'addon' hook should succeed (without args)";
};

subtest 'info hook' => sub {
	again();

	my $rc;
	stdout_is(sub { $rc = $fancy->run_hook('info', env => $snw_lab_dev); }, <<EOF,
===[ your HOOK deployment ]======================

   env name  : snw-lab-dev
   deploying : dev/latest
   from      : $root
   vault at  : snw/lab/dev/thing

   arguments : [(none)]

=================================================
EOF
		"[fancy] info hook output should be correct");
	ok $rc, "[fancy] running the 'info' hook should succeed";

	{
		local $ENV{HOOK_SHOULD_FAIL} = 'yes';
		throws_ok { $fancy->run_hook('info', env => $snw_lab_dev) }
			qr/could not run 'info' hook/i;
	}
};

subtest 'LEGACY prereqs hook' => sub {
	ok 1;
};

subtest 'LEGACY subkit hook' => sub {
	again();

	cmp_deeply([$legacy->run_hook('subkit', features => [$stack_scale->features])], [qw[
			do-thing
			forced-subkit
		]], "[legacy] the 'subkit' hook can force new subkits");

	{
		local $ENV{HOOK_SHOULD_FAIL} = 'yes';
		throws_ok { $legacy->run_hook('subkit', features => [$stack_scale->features]); }
			qr/could not determine which auxiliary subkits/i;
	}

	{
		local $ENV{HOOK_NO_SUBKITS} = 'yes';
		cmp_deeply([$legacy->run_hook('subkit', features => [$stack_scale->features])], [],
			"[legacy] the 'subkit' hook can remove all subkits");
	}

	{
		local $ENV{HOOK_SHOULD_BE_AIRY} = 'yes';
		cmp_deeply([$legacy->run_hook('subkit', features => [$stack_scale->features])], [qw[
				do-thing
			]], "[legacy] the 'subkit' hook ignores whitespace");
	}
};

done_testing;
