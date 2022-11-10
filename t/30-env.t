#!perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::Exception;
use Test::Deep;
use Test::More;
use Test::Output;
use Test::Differences;
use Cwd qw/cwd abs_path/;

use_ok 'Genesis::Env';
use Genesis::BOSH;
use Genesis::Top;
use Genesis::Env;
use Genesis;

fake_bosh;

$ENV{GENESIS_CALLBACK_BIN} ||= abs_path('bin/genesis');
$ENV{GENESIS_LIB} ||= abs_path('lib');

subtest 'new() validation' => sub {
	quietly { throws_ok { Genesis::Env->new() }
		qr/no 'name' specified.*this is most likely a bug/is;
	};

	quietly { throws_ok { Genesis::Env->new(name => 'foo') }
		qr/no 'top' specified.*this is most likely a bug/is;
	};
};

subtest 'name validation' => sub {

	is(
		Genesis::Env::_env_name_errors("my-new-env"),
		'',
		"my-new-env is a good enough name"
	);

	like(
		Genesis::Env::_env_name_errors(""),
		qr/must not be empty/i,
		'environment name cannot be empty'
	);


	like(
		Genesis::Env::_env_name_errors("my\tnew env\n"),
		qr/must not contain whitespace/i,
		'environment name cannot contain whitespaces'
	);

	like(
		Genesis::Env::_env_name_errors("my-new-!@#%ing-env"),
		qr/can only contain lowercase letters, numbers, and hyphens/i,
		'environment name cannot contain invalid characters'
	);

	like(
		Genesis::Env::_env_name_errors("-my-new-env"),
		qr/must start with a .*letter/i,
		'environment name must start with a letter'
	);

	like(
		Genesis::Env::_env_name_errors("my-new-env-"),
		qr/must not end with a hyphen/i,
		'environment name cannot end with a hyphen'
	);

	like(
		Genesis::Env::_env_name_errors("my--new--env"),
		qr/must not contain sequential hyphens/i,
		'environment name cannot contain sequential hyphens'
	);

	for my $ok (qw(
		env1
		us-east-1-prod
		this-is-a-really-long-hyphenated-name-oh-god-why-would-you-do-this-to-yourself
		company-us_east_1-prod
	)) {
		is(
			Genesis::Env::_env_name_errors($ok),
			'',
			"$ok is a valid env name"
		);
	}
};

subtest 'loading' => sub {
	my $vault_target = vault_ok;
	Genesis::Vault->clear_all();
	my $top = Genesis::Top->create(workdir, 'thing', vault=>$VAULT_URL);
	$top->link_dev_kit('t/src/simple');
	put_file $top->path("standalone.yml"), <<EOF;
---
kit:
  name:    dev
  version: latest
  features: []

genesis:
  env: standalone
EOF

	lives_ok { $top->load_env('standalone') }
	         "should be able to load the `standalone' environment.";
	lives_ok { $top->load_env('standalone.yml') }
	         "should be able to load an environment by filename.";
	teardown_vault();
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
	my $vault_target = vault_ok;
	Genesis::Vault->clear_all();
	my $top = Genesis::Top->create(workdir, 'thing', vault=>$VAULT_URL);
	quietly { $top->download_kit('bosh/0.2.0'); };
	put_file $top->path("standalone.yml"), <<EOF;
---
kit:
  name:    bosh
  version: 0.2.0
  features:
    - vsphere
    - proto

genesis:
  env: standalone

params:
  state:   awesome
  running: yes
  false:   ~
EOF

	my $env;
	quietly { $env = $top->load_env('standalone'); };
	is($env->name, "standalone", "an environment should know its name");
	is($env->file, "standalone.yml", "an environment should know its file path");
	is($env->deployment_name, "standalone-thing", "an environment should know its deployment name");
	is($env->kit->id, "bosh/0.2.0", "an environment can ask the kit for its kit name/version");
	is($env->secrets_mount, '/secret/', "default secret mount used when none provided");
	is($env->secrets_slug, 'standalone/thing', "default secret slug generated correctly");
	is($env->secrets_base, '/secret/standalone/thing/', "default secret base path generated correctly");
	is($env->exodus_mount, '/secret/exodus/', "default exodus mount used when none provided");
	is($env->exodus_base, '/secret/exodus/standalone/thing', "correctly evaluates exodus base path");
	is($env->ci_mount, '/secret/ci/', "default ci mount used when none provided");
	is($env->ci_base, '/secret/ci/thing/standalone/', "correctly evaluates ci base path");

	put_file $top->path("standalone-with-another.yml"), <<EOF;
---
kit:
  features:
    - ((append))
    - extras

genesis:
  env:           standalone-with-another
  secrets_mount: genesis/secrets
  exodus_mount:  genesis/exodus
EOF
	local $ENV{NOCOLOR} = 'y';
	quietly { throws_ok { $env = $top->load_env('standalone-with-another.yml');}
		qr/\[ERROR\] Environment standalone-with-another.yml could not be loaded:\n\s+- kit bosh\/0.2.0 is not compatible with secrets_mount feature; check for newer kit version or remove feature.\n\s+- kit bosh\/0.2.0 is not compatible with exodus_mount feature; check for newer kit version or remove feature./ms,
		"Outdated kits bail when using v2.7.0 features";
	};

	teardown_vault();

};

subtest 'parameter lookup' => sub {
	my $vault_target = vault_ok;
	Genesis::Vault->clear_all();
	my $top = Genesis::Top->create(workdir, 'thing', vault=>$VAULT_URL);
	quietly { $top->download_kit('bosh/0.2.0'); };
	put_file $top->path("standalone.yml"), <<EOF;
---
kit:
  name:    bosh
  version: 0.2.0
  features:
    - vsphere
    - second-feature

genesis:
  env: standalone

params:
  state:   awesome
  running: yes
  false:   ~
EOF

	my $env;
	$ENV{NOCOLOR}=1;
	quietly { throws_ok { $top->load_env('enoent');   } qr/enoent.yml does not exist/; };
	quietly { throws_ok { $top->load_env('e-no-ent'); } qr/does not exist/; };

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

	cmp_deeply([$env->features], [qw[vsphere second-feature]],
		"features() returns the current features");
	ok($env->has_feature('vsphere'), "standalone env has the vsphere feature");
	ok($env->has_feature('second-feature'), "standalone env has the second-feature feature");
	ok(!$env->has_feature('xyzzy'), "standalone env doesn't have the xyzzy feature");
	throws_ok { $env->use_create_env() } qr/ERROR/;
	throws_ok { $env->use_create_env() }
		qr/\[ERROR\] This bosh environment does not use create-env \(proto\) or specify.*an alternative genesis.bosh_env/sm,
		"bosh environments without specifying bosh_env require bosh create-env";

	put_file $top->path("regular-deploy.yml"), <<EOF;
---
kit:
  name:    bosh
  version: 0.2.0
  features:
    - vsphere
    - proto

genesis:
  env:      regular-deploy
  bosh_env: parent-bosh
EOF
	lives_ok { $env = $top->load_env('regular-deploy') }
	         "Genesis::Env should be able to load the `regular-deploy' environment.";
	ok($env->has_feature('vsphere'), "regular-deploy env has the vsphere feature");
	quietly { throws_ok { $env->use_create_env() }
		qr/\[ERROR\] This bosh environment specifies an alternative bosh_env, but is\n        marked as a create-env \(proto\) environment./sm,
		"bosh environments with bosh_env can't be a protobosh, or vice versa";
	};

	# Test the parsing of the bosh env, including deployment type, alternate vault and alternate exodus mount
	my %valid_bosh_envs=(
		$env->bosh_env => ["parent-bosh", undef, undef, undef],
		"test-me/my-bosh" => ["test-me","my-bosh",undef,undef],
		"my-parent-bosh\@secret/other/exodus" => ["my-parent-bosh",undef,undef,"secret/other/exodus"],
		"big-badda-boom/special_bosh@/secret/mngt/exodus/" => ["big-badda-boom","special_bosh",undef,"secret/mngt/exodus/"],
		"bosh-env/bosh-type\@https://mngt-vault:8443/private/data" => ["bosh-env","bosh-type", "https://mngt-vault:8443", "private/data"]
	);
	for my $bosh_env (keys(%valid_bosh_envs)) {
		$env->{__params}{genesis}{bosh_env} = $bosh_env;
		cmp_deeply([$env->_parse_bosh_env], $valid_bosh_envs{$bosh_env}, "Ensuring bosh_env '$bosh_env' can be parsed correctly");
	}

	teardown_vault();
};

subtest 'manifest generation' => sub {
	my $vault_target = vault_ok;
	Genesis::Vault->clear_all();
	write_bosh_config 'standalone';
	my $top = Genesis::Top->create(workdir, 'thing', vault=>$VAULT_URL);
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

genesis:
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
	lives_ok { $env->use_config($top->path(".cloud.yml"))->manifest; }
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
		genesis=> ignore,
		kit    => ignore,
		meta   => ignore,
		params => ignore
	}, "written manifest (unpruned) contains all the keys");

	ok $env->manifest_lookup('addons.foxtrot'), "env manifest defines addons.foxtrot";
	is $env->manifest_lookup('addons.bravo', 'MISSING'), 'MISSING',
		"env manifest doesn't define addons.bravo";

	teardown_vault();
};

subtest 'multidoc env files' => sub {
	my $vault_target = vault_ok;
	Genesis::Vault->clear_all();
	my $top = Genesis::Top->create(workdir, 'thing', vault=>$VAULT_URL);
	$top->link_dev_kit('t/src/fancy');
	put_file $top->path('standalone.yml'), <<'EOF';
---
kit:
  name:    dev
  version: latest
  features:
    - whiskey
    - tango
    - foxtrot

params:
  env:   standalone
  secret: (( vault $GENESIS_SECRETS_BASE "test:secret" ))
  network: (( grab networks[0].name ))
  junk:    ((    vault    "secret/passcode" ))

---
genesis:
  env:       (( grab params.env ))

kit:
  features:
  - (( replace ))
  - oscar
---
params:
  env:  (( prune ))

kit:
  features:
  - (( append ))
  - kilo
EOF

	my $env = $top->load_env('standalone');
	cmp_deeply([$env->params], [{
		kit => {
			features   => [ "oscar", "kilo" ],
			name       => "dev",
			version    => "latest"
		},
		genesis => {
			env        => "standalone"
		},
		params => {
			junk       => '(( vault "secret/passcode" ))',
			network    => '(( grab networks.0.name ))',
			secret     => '(( vault $GENESIS_SECRETS_BASE "test:secret" ))',
		}
	}], "env contains the parameters from all document pages");
	cmp_deeply([$env->kit_files], [qw[
		base.yml
		addons/oscar.yml
		addons/kilo.yml
	]], "env gets the correct kit yaml files to merge");
	cmp_deeply([$env->potential_environment_files], [qw[
		./standalone.yml
	]], "env formulates correct potential environment files to merge");
	cmp_deeply([$env->actual_environment_files], [qw[
		./standalone.yml
	]], "env detects correct actual environment files to merge");

	put_file $top->path('standalone.yml'), <<'EOF';
---
kit:
  name:    dev
  version: latest
  features:
    - whiskey
    - tango
    - foxtrot

params:
  env:   standalone

---
genesis:
  env:       (( grab params.env ))

kit:
  features:
  - (( replace ))
  - oscar
---
params:
  env:  (( prune ))

kit:
  features:
  - (( append ))
  - kilo
EOF

	# Get rid of the unparsable value that would prevent manifest generation
	$env = $top->load_env('standalone');

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
		meta   => ignore,
		params => ignore,
		exodus => ignore,
		genesis=> superhashof({
			env           => "standalone",
		}),
		kit    => {
			name          => ignore,
			version       => ignore,
			features      => [ "oscar", "kilo" ],
		},
	}, "written manifest (unpruned) contains all the keys");

	ok $env->manifest_lookup('addons.kilo'), "env manifest defines addons.kilo";
	is $env->manifest_lookup('addons.foxtrot', 'MISSING'), 'MISSING',
		"env manifest doesn't define addons.foxtrot";

	teardown_vault();
};

subtest 'manifest pruning' => sub {
	my $vault_target = vault_ok;
	Genesis::Vault->clear_all();
	my $top = Genesis::Top->create(workdir, 'thing', vault=>$VAULT_URL);
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
genesis:
  env: standalone
EOF
	my $env = $top->load_env('standalone')->use_config($top->path('.cloud.yml'));

	cmp_deeply(scalar load_yaml($env->manifest(prune => 0)), {
		name   => ignore,
		fancy  => ignore,
		addons => ignore,

		# Genesis stuff
		meta        => ignore,
		pipeline    => ignore,
		params      => ignore,
		exodus      => ignore,
		genesis     => ignore,
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

	cmp_deeply(scalar load_yaml($env->manifest(prune => 1)), {
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
	teardown_vault();
};

subtest 'manifest pruning (custom bosh create-env)' => sub {
	my $vault_target = vault_ok;
	Genesis::Vault->clear_all();
	my $top = Genesis::Top->create(workdir, 'thing', vault=>$VAULT_URL);
	$top->link_dev_kit('t/src/custom-bosh');
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
genesis:
  env: proto
EOF

	my $env = $top->load_env('proto')->use_config($top->path('.cloud.yml'));
	ok $env->use_create_env, "'proto' test env needs create-env";
	cmp_deeply(scalar load_yaml($env->manifest(prune => 0)), {
		name   => ignore,
		fancy  => ignore,
		addons => ignore,

		# Genesis stuff
		meta        => ignore,
		pipeline    => ignore,
		params      => ignore,
		exodus      => ignore,
		genesis     => ignore,
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

	cmp_deeply(scalar load_yaml($env->manifest(prune => 1)), {
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

	teardown_vault();
};

subtest 'exodus data' => sub {
	my $vault_target = vault_ok;
	Genesis::Vault->clear_all();
	my $top = Genesis::Top->create(workdir, 'thing', vault=>$VAULT_URL);
	$top->link_dev_kit('t/src/fancy');
	put_file $top->path('standalone.yml'), <<EOF;
---
kit:
  name:    dev
  version: latest
  features:
    - echo    # for pruning tests
genesis:
  env: standalone
EOF
	put_file $top->path(".cloud.yml"), <<EOF;
--- {}
# not really a cloud config, but close enough
EOF
	my $env = $top->load_env('standalone')->use_config($top->path('.cloud.yml'));
	cmp_deeply($env->exodus, {
			version        => ignore,
			dated          => re(qr/\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d/),
			deployer       => ignore,
			bosh           => 'standalone',
			is_director    => JSON::PP::false,
			use_create_env => JSON::PP::false,
			kit_name       => 'fancy',
			kit_version    => '0.0.0-rc0',
			kit_is_dev     => JSON::PP::true,
			'addons[0]'    => 'echo',
			vault_base     => '/secret/standalone/thing',
			features       => 'echo',

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
	}, "exodus data can be correctly unflattened");

	teardown_vault();
};


subtest 'cloud_config_and_deployment' => sub{
	local $ENV{GENESIS_BOSH_COMMAND};
	my ($director1) = fake_bosh_directors(
		{alias => 'standalone'},
	);
	fake_bosh;
	my $vault_target = vault_ok;
	Genesis::Vault->clear_all();
	`safe set --quiet secret/code word='penguin'`;
	`safe set --quiet secret/standalone/thing/admin password='drowssap'`;

	my $top = Genesis::Top->create(workdir, 'thing', vault=>$VAULT_URL)->link_dev_kit('t/src/fancy');
	put_file $top->path('standalone.yml'), <<EOF;
---
kit:
  name:    dev
  version: latest
genesis:
  env: standalone
EOF

	Genesis::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $env = $top->load_env('standalone');
	quietly { lives_ok { $env->download_configs('cloud@genesis-test'); }
		"download_cloud_config runs correctly";
	};

	ok -f $env->config_file('cloud','genesis-test'), "download_cloud_config created cc file";
	eq_or_diff get_file($env->config_file('cloud','genesis-test')), <<EOF, "download_config calls BOSH correctly";
{"cmd": "bosh config --type cloud --name genesis-test --json"}
EOF

	put_file $env->config_file('cloud'), <<EOF;
---
something: (( vault "secret/code:word" ))
EOF

	is($env->lookup("something","goose"), "goose", "Environment doesn't contain cloud config details");
	is($env->manifest_lookup("something","goose"), "penguin", "Manifest contains cloud config details");
	my ($manifest_file, $exists, $sha1) = $env->cached_manifest_info;
	ok $manifest_file eq $env->path(".genesis/manifests/".$env->name.".yml"), "cached manifest path correctly determined";
	ok ! $exists, "manifest file doesn't exist.";
	ok ! defined($sha1), "sha1 sum for manifest not computed.";
	my ($stdout, $stderr) = output_from {$env->deploy(canaries => 2, "max-in-flight" => 5);};
	eq_or_diff($stdout, <<EOF, "Deploy should call BOSH with the correct options");
bosh
deploy
--no-redact
--canaries=2
--max-in-flight=5
$env->{__tmp}/manifest.yml
EOF

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
	local %ENV = %ENV;
	$ENV{USER} ||= 'unknown';
	cmp_deeply($exodus, {
				dated => re(qr/\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d \+0000/),
				deployer => $ENV{USER},
				kit_name => "fancy",
				kit_version => "0.0.0-rc0",
				kit_is_dev => 1,
				features => '',
				bosh => "standalone",
				is_director => 0,
				use_create_env => 0,
				vault_base => "/secret/standalone/thing",
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
	is($env->last_deployed_lookup("genesis.env","none"), "standalone", "Cached manifest contains pruned params");
	cmp_deeply(scalar($env->exodus_lookup("",{})), {
				dated => $exodus->{dated},
				deployer => $ENV{USER},
				bosh => "standalone",
				is_director => 0,
				use_create_env => 0,
				kit_name => "fancy",
				kit_version => "0.0.0-rc0",
				kit_is_dev => 1,
				features => '',
				vault_base => "/secret/standalone/thing",
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

	$director1->stop();
	teardown_vault();
};

subtest 'bosh variables' => sub {
	local $ENV{GENESIS_BOSH_COMMAND};
	fake_bosh;

	my ($director1) = fake_bosh_directors(
		{alias => 'standalone'},
	);
	my $vault_target = vault_ok;
	Genesis::Vault->clear_all();
	Genesis::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $top = Genesis::Top->create(workdir, 'thing', vault=>$VAULT_URL)->link_dev_kit('t/src/fancy');
	put_file $top->path("standalone.yml"), <<EOF;
---
kit:
  name:    dev
  version: latest
  features: []

bosh-variables:
  something:       valueable
  cc:              (( grab cc-stuff ))
  collection:      (( join " " params.extras ))
  deployment_name: (( grab name ))

genesis:
  env: standalone

params:
  extras:
    - 1
    - 2
    - 3

EOF
	`safe set --quiet secret/standalone/thing/admin password='drowssap'`;
	my $env = $top->load_env('standalone');
	quietly { lives_ok { $env->download_configs('cloud'); }
		"download_cloud_config runs correctly";
	};

	put_file $env->config_file('cloud'), <<EOF;
---
cc-stuff: cloud-config-data
EOF

	my $varsfile = $env->vars_file();
	my ($stdout, $stderr) = output_from {eval {$env->deploy();}};
	eq_or_diff($stdout, <<EOF, "Deploy should call BOSH with the correct options, including vars file");
bosh
deploy
--no-redact
-l
$varsfile
$env->{__tmp}/manifest.yml
EOF

	eq_or_diff get_file($env->vars_file), <<EOF, "download_cloud_config calls BOSH correctly";
cc: cloud-config-data
collection: 1 2 3
deployment_name: standalone-thing
something: valueable

EOF

	teardown_vault();
};

subtest 'new env and check' => sub{
	local $ENV{GENESIS_BOSH_COMMAND};
	my $vault_target = vault_ok;
	Genesis::Vault->clear_all();

	my $name = "far-fetched";
	write_bosh_config $name;
	my $top = Genesis::Top->create(workdir, 'sample', vault=>$VAULT_URL);
	my $kit = $top->link_dev_kit('t/src/creator')->local_kit_version('dev');
	mkfile_or_fail $top->path("pre-existing.yml"), "I'm already here";

	# create the environment
	quietly {dies_ok {$top->create_env('', $kit)} "can't create a unnamed env"; };
	quietly {dies_ok {$top->create_env("nothing")} "can't create a env without a kit"; };
	quietly {dies_ok {$top->create_env("pre-existing", $kit)} "can't overwrite a pre-existing env"; };

	my $env;
	local $ENV{NOCOLOR} = "yes";
	local $ENV{PRY} = "1";
	my ($director1) = fake_bosh_directors(
		{alias => $name},
	);
	fake_bosh;
	Genesis::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $out;
	lives_ok {
		$out = combined_from {$env = $top->create_env($name, $kit, vault => $vault_target)}
	} "successfully create an env with a dev kit";

	$out =~ s/(Duration:|-) (\d+ minutes, )?\d+ seconds?/$1 XXX seconds/g;
	eq_or_diff $out, <<EOF, "creating environment provides secret generation output";
Parsing kit secrets descriptions ... done. - XXX seconds

Adding 10 secrets for far-fetched under path '/secret/far/fetched/sample/':
  [ 1/10] my-cert/ca X509 certificate - CA, self-signed ... done.
  [ 2/10] my-cert/server X509 certificate - signed by 'my-cert/ca' ... done.
  [ 3/10] ssl/ca X509 certificate - CA, self-signed ... done.
  [ 4/10] ssl/server X509 certificate - signed by 'ssl/ca' ... done.
  [ 5/10] crazy/thing:id random password - 32 bytes, fixed ... done.
  [ 6/10] crazy/thing:token random password - 16 bytes ... done.
  [ 7/10] users/admin:password random password - 64 bytes ... done.
  [ 8/10] users/bob:password random password - 16 bytes ... done.
  [ 9/10] work/signing_key RSA public/private keypair - 2048 bits, fixed ... done.
  [10/10] something/ssh SSH public/private keypair - 2048 bits, fixed ... done.
Completed - Duration: XXX seconds [10 added/0 skipped/0 errors]

EOF

	eq_or_diff get_file($env->path($env->{file})), <<EOF, "Created env file contains correct info";
---
kit:
  name:    dev
  version: latest
  features:
    - (( replace ))
    - bonus

genesis:
  env:            $name
  vault:          $VAULT_URL as $vault_target no-strongbox

params:
  static: junk
EOF

	$out = combined_from {
		ok $env->check_secrets(verbose => 1), "check_secrets shows all secrets okay"
	};
	$out =~ s/(Duration:|-) (\d+ minutes, )?\d+ seconds?/$1 XXX seconds/g;

	eq_or_diff $out, <<EOF, "check_secrets gives meaninful output on success";
Parsing kit secrets descriptions ... done. - XXX seconds
Retrieving all existing secrets ... done. - XXX seconds

Checking 10 secrets for far-fetched under path '/secret/far/fetched/sample/':
  [ 1/10] my-cert/ca X509 certificate - CA, self-signed ... found.
  [ 2/10] my-cert/server X509 certificate - signed by 'my-cert/ca' ... found.
  [ 3/10] ssl/ca X509 certificate - CA, self-signed ... found.
  [ 4/10] ssl/server X509 certificate - signed by 'ssl/ca' ... found.
  [ 5/10] crazy/thing:id random password - 32 bytes, fixed ... found.
  [ 6/10] crazy/thing:token random password - 16 bytes ... found.
  [ 7/10] users/admin:password random password - 64 bytes ... found.
  [ 8/10] users/bob:password random password - 16 bytes ... found.
  [ 9/10] work/signing_key RSA public/private keypair - 2048 bits, fixed ... found.
  [10/10] something/ssh SSH public/private keypair - 2048 bits, fixed ... found.
Completed - Duration: XXX seconds [10 found/0 skipped/0 errors]

EOF

	qx(safe export > /tmp/out.json);

	qx(safe rm -rf secret/far/fetched/sample/users);
	qx(safe rm secret/far/fetched/sample/ssl/ca:key secret/far/fetched/sample/ssl/ca:certificate);
	qx(safe rm secret/far/fetched/sample/crazy/thing:token);

	$out = combined_from {
		ok !$env->check_secrets(verbose=>1), "check_secrets shows missing secrets and keys"
	};
	$out =~ s/(Duration:|-) (\d+ minutes, )?\d+ seconds?/$1 XXX seconds/g;

	matches_utf8 $out, <<EOF,  "check_secrets gives meaninful output on failure";
Parsing kit secrets descriptions ... done. - XXX seconds
Retrieving all existing secrets ... done. - XXX seconds

Checking 10 secrets for far-fetched under path '/secret/far/fetched/sample/':
  [ 1/10] my-cert/ca X509 certificate - CA, self-signed ... found.
  [ 2/10] my-cert/server X509 certificate - signed by 'my-cert/ca' ... found.
  [ 3/10] ssl/ca X509 certificate - CA, self-signed ... missing!
          [✘ ] missing key ':certificate'
          [✘ ] missing key ':key'

  [ 4/10] ssl/server X509 certificate - signed by 'ssl/ca' ... found.
  [ 5/10] crazy/thing:id random password - 32 bytes, fixed ... found.
  [ 6/10] crazy/thing:token random password - 16 bytes ... missing!
  [ 7/10] users/admin:password random password - 64 bytes ... missing!
  [ 8/10] users/bob:password random password - 16 bytes ... missing!
  [ 9/10] work/signing_key RSA public/private keypair - 2048 bits, fixed ... found.
  [10/10] something/ssh SSH public/private keypair - 2048 bits, fixed ... found.
Failed - Duration: XXX seconds [6 found/0 skipped/4 errors]

EOF

	$director1->stop();
	teardown_vault();
};

subtest 'env_kit_overrides' => sub {
	local $ENV{GENESIS_BOSH_COMMAND};
	fake_bosh;

	my ($director1) = fake_bosh_directors(
		{alias => 'standalone'},
	);
	my $vault_target = vault_ok;
	Genesis::Vault->clear_all();
	Genesis::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $top = Genesis::Top->create(workdir, 'thing', vault=>$VAULT_URL)->link_dev_kit('t/src/creator');
	put_file $top->path("standalone.yml"), <<EOF; # Direct YAML
---
kit:
  name:    dev
  version: latest
  features:
  - bonus
  overrides:
    certificates:
      base:
        private-cert: # Additional cert signed by existing CA
          server:
            signed_by: "my-cert/ca"
            valid_for: (( defer grab certificates.base.my-cert.server.valid_for )) # Grab from kit.yml
            names: [ (( grab genesis.env )) ] # Grab from env file
      bonus: ~ # Deletion
    credentials:
      bonus:
        need-to-know:
          secret: random 32 #New
        crazy/thing:
          token: random 48 allowed-chars ABCDEF0123456789 # Update

genesis:
  env: standalone

params:
  extras:
    - 1
    - 2
    - 3

EOF
	my $env = $top->load_env('standalone');
	ok ! $env->use_create_env(), "env does not use create-env";

  # check env override count and content
	my @override_files = $env->kit->env_override_files();
	ok scalar(@override_files) == 1, "there is one environment kit override file";
	ok $override_files[0] =~ /\/env-overrides-0.yml$/, "override file is named correctly";
	eq_or_diff slurp($override_files[0]), <<EOF, "override contains expected values";
certificates:
  base:
    private-cert:
      server:
        names:
        - standalone
        signed_by: my-cert/ca
        valid_for: (( grab certificates.base.my-cert.server.valid_for ))
  bonus: null
credentials:
  bonus:
    crazy/thing:
      token: random 48 allowed-chars ABCDEF0123456789
    need-to-know:
      secret: random 32

EOF

	local $ENV{NOCOLOR} = "yes";
	my $out;
	lives_ok {
		$out = combined_from {$env->add_secrets() }
	} "successfully add secrets with environment kit overrides";

	$out =~ s/(Duration:|-) (\d+ minutes, )?\d+ seconds?/$1 XXX seconds/g;
	eq_or_diff $out, <<EOF, "environment kit overrides add the expected secrets";
Parsing kit secrets descriptions ... done. - XXX seconds

Adding 10 secrets for standalone under path '/secret/standalone/thing/':
  [ 1/10] my-cert/ca X509 certificate - CA, self-signed ... done.
  [ 2/10] my-cert/server X509 certificate - signed by 'my-cert/ca' ... done.
  [ 3/10] private-cert/server X509 certificate - signed by 'my-cert/ca' ... done.
  [ 4/10] crazy/thing:id random password - 32 bytes, fixed ... done.
  [ 5/10] crazy/thing:token random password - 48 bytes ... done.
  [ 6/10] need-to-know:secret random password - 32 bytes ... done.
  [ 7/10] users/admin:password random password - 64 bytes ... done.
  [ 8/10] users/bob:password random password - 16 bytes ... done.
  [ 9/10] work/signing_key RSA public/private keypair - 2048 bits, fixed ... done.
  [10/10] something/ssh SSH public/private keypair - 2048 bits, fixed ... done.
Completed - Duration: XXX seconds [10 added/0 skipped/0 errors]

EOF
	sleep 2; # to allow x509 certs to start
	lives_ok {
		$out = combined_from {$env->check_secrets(verbose => 1, validate => 1) }
	} "successfully check secrets with environment kit overrides";
	$out =~ s/(Duration:|-) (\d+ minutes, )?\d+ seconds?/$1 XXX seconds/g;
	$out =~ s/expires in (\d+) days \(([^\)]+)\)/expires in $1 days (<timestamp>)/g;
	matches_utf8 $out, <<EOF, "environment kit overrides create expected secrets - validation";
Parsing kit secrets descriptions ... done. - XXX seconds
Retrieving all existing secrets ... done. - XXX seconds

Validating 10 secrets for standalone under path '/secret/standalone/thing/':
  [ 1/10] my-cert/ca X509 certificate - CA, self-signed ... valid.
          [✔ ] CA Certificate
          [✔ ] Self-Signed
          [✔ ] Valid: expires in 3650 days (<timestamp>)
          [✔ ] Modulus Agreement
          [✔ ] Default CA key usage: server_auth, client_auth, crl_sign, key_cert_sign

  [ 2/10] my-cert/server X509 certificate - signed by 'my-cert/ca' ... valid.
          [✔ ] Not a CA Certificate
          [✔ ] Signed by my-cert/ca
          [✔ ] Valid: expires in 365 days (<timestamp>)
          [✔ ] Modulus Agreement
          [✔ ] Subject Name 'locker'
          [✔ ] Subject Alt Names: 'locker'
          [✔ ] Default key usage: server_auth, client_auth

  [ 3/10] private-cert/server X509 certificate - signed by 'my-cert/ca' ... valid.
          [✔ ] Not a CA Certificate
          [✔ ] Signed by my-cert/ca
          [✔ ] Valid: expires in 365 days (<timestamp>)
          [✔ ] Modulus Agreement
          [✔ ] Subject Name 'standalone'
          [✔ ] Subject Alt Names: 'standalone'
          [✔ ] Default key usage: server_auth, client_auth

  [ 4/10] crazy/thing:id random password - 32 bytes, fixed ... valid.
          [✔ ] 32 characters

  [ 5/10] crazy/thing:token random password - 48 bytes ... valid.
          [✔ ] 48 characters
          [✔ ] Only uses characters 'ABCDEF0123456789'

  [ 6/10] need-to-know:secret random password - 32 bytes ... valid.
          [✔ ] 32 characters

  [ 7/10] users/admin:password random password - 64 bytes ... valid.
          [✔ ] 64 characters

  [ 8/10] users/bob:password random password - 16 bytes ... valid.
          [✔ ] 16 characters

  [ 9/10] work/signing_key RSA public/private keypair - 2048 bits, fixed ... valid.
          [✔ ] Valid private key
          [✔ ] Valid public key
          [✔ ] Public/Private key agreement
          [✔ ] 2048 bit

  [10/10] something/ssh SSH public/private keypair - 2048 bits, fixed ... valid.
          [✔ ] Valid private key
          [✔ ] Valid public key
          [✔ ] Public/Private key Agreement
          [✔ ] 2048 bits

Completed - Duration: XXX seconds [10 validated/0 skipped/0 errors]

EOF

	put_file $top->path("c.yml"), <<EOF; # Array entry: string
---
kit:
  name:    dev
  version: latest
  features:
  - bonus
  overrides:
    - |
      genesis_version_min: 2.8.0
      use_create_env: allow
EOF

	put_file $top->path("c-env.yml"), <<EOF; # Direct YAML
---
kit:
  features:
  - ((append))
  - custom-proto
  overrides:
  - ((append))
  - provided:
      custom-proto:
        iaas:
          keys:
            access_key:
              sensitive: false
              prompt:    IaaS Access Key
            secret_key:
              prompt:    IaaS Secret Key

    certificates:
      custom-proto:
        some-ssl:
          ca: {valid_for: 2y}
          server: {names: [ "proto-ssl" ]}

    credentials:
      custom-proto:
        proto-credentials:
          token: random 24 fmt base64
          seed:  random 64 fixed

genesis:
  env: c-env
  min_version: 2.8.0
  use_create_env: yes

EOF

	$env = $top->load_env('c-env');
	ok $env->use_create_env(), "env uses create-env (v2.8.0 method)";

  # check env override count and content
	@override_files = $env->kit->env_override_files();
	ok scalar(@override_files) == 2, "there is one environment kit override file";
	ok $override_files[0] =~ /\/env-overrides-0.yml$/, "first override file is named correctly";
	eq_or_diff slurp($override_files[0]), <<EOF, "first override contains expected values";
genesis_version_min: 2.8.0
use_create_env: allow
EOF
	ok $override_files[1] =~ /\/env-overrides-1.yml$/, "second override file is named correctly";
	eq_or_diff slurp($override_files[1]), <<EOF, "first override contains expected values";
certificates:
  custom-proto:
    some-ssl:
      ca:
        valid_for: 2y
      server:
        names:
        - proto-ssl
credentials:
  custom-proto:
    proto-credentials:
      seed: random 64 fixed
      token: random 24 fmt base64
provided:
  custom-proto:
    iaas:
      keys:
        access_key:
          prompt: IaaS Access Key
          sensitive: false
        secret_key:
          prompt: IaaS Secret Key

EOF

  `safe set --quiet secret/c/env/thing/iaas access_key='knock-knock' secret_key='drowsapp'`;
	local $ENV{NOCOLOR} = "yes";
	lives_ok {
		$out = combined_from {$env->add_secrets() }
	} "successfully add secrets with environment kit overrides";

	$out =~ s/(Duration:|-) (\d+ minutes, )?\d+ seconds?/$1 XXX seconds/g;
	eq_or_diff $out, <<EOF, "environment kit overrides add the expected secrets";
Parsing kit secrets descriptions ... done. - XXX seconds

Adding 16 secrets for c-env under path '/secret/c/env/thing/':
  [ 1/16] my-cert/ca X509 certificate - CA, self-signed ... done.
  [ 2/16] my-cert/server X509 certificate - signed by 'my-cert/ca' ... done.
  [ 3/16] some-ssl/ca X509 certificate - CA, self-signed ... done.
  [ 4/16] some-ssl/server X509 certificate - signed by 'some-ssl/ca' ... done.
  [ 5/16] ssl/ca X509 certificate - CA, self-signed ... done.
  [ 6/16] ssl/server X509 certificate - signed by 'ssl/ca' ... done.
  [ 7/16] iaas:access_key user-provided - IaaS Access Key ... exists!
  [ 8/16] iaas:secret_key user-provided - IaaS Secret Key ... exists!
  [ 9/16] crazy/thing:id random password - 32 bytes, fixed ... done.
  [10/16] crazy/thing:token random password - 16 bytes ... done.
  [11/16] proto-credentials:seed random password - 64 bytes, fixed ... done.
  [12/16] proto-credentials:token random password - 24 bytes ... done.
  [13/16] users/admin:password random password - 64 bytes ... done.
  [14/16] users/bob:password random password - 16 bytes ... done.
  [15/16] work/signing_key RSA public/private keypair - 2048 bits, fixed ... done.
  [16/16] something/ssh SSH public/private keypair - 2048 bits, fixed ... done.
Completed - Duration: XXX seconds [14 added/2 skipped/0 errors]

EOF

	lives_ok {
		$out = combined_from {$env->check_secrets(verbose => 1, validate => 1) }
	} "successfully check secrets with environment kit overrides";
	$out =~ s/(Duration:|-) (\d+ minutes, )?\d+ seconds?/$1 XXX seconds/g;
	$out =~ s/expires in (\d+) days \(([^\)]+)\)/expires in $1 days (<timestamp>)/g;
	matches_utf8 $out, <<EOF, "environment kit overrides create expected secrets - validation";
Parsing kit secrets descriptions ... done. - XXX seconds
Retrieving all existing secrets ... done. - XXX seconds

Validating 16 secrets for c-env under path '/secret/c/env/thing/':
  [ 1/16] my-cert/ca X509 certificate - CA, self-signed ... valid.
          [✔ ] CA Certificate
          [✔ ] Self-Signed
          [✔ ] Valid: expires in 3650 days (<timestamp>)
          [✔ ] Modulus Agreement
          [✔ ] Default CA key usage: server_auth, client_auth, crl_sign, key_cert_sign

  [ 2/16] my-cert/server X509 certificate - signed by 'my-cert/ca' ... valid.
          [✔ ] Not a CA Certificate
          [✔ ] Signed by my-cert/ca
          [✔ ] Valid: expires in 365 days (<timestamp>)
          [✔ ] Modulus Agreement
          [✔ ] Subject Name 'locker'
          [✔ ] Subject Alt Names: 'locker'
          [✔ ] Default key usage: server_auth, client_auth

  [ 3/16] some-ssl/ca X509 certificate - CA, self-signed ... valid.
          [✔ ] CA Certificate
          [✔ ] Self-Signed
          [✔ ] Valid: expires in 730 days (<timestamp>)
          [✔ ] Modulus Agreement
          [✔ ] Default CA key usage: server_auth, client_auth, crl_sign, key_cert_sign

  [ 4/16] some-ssl/server X509 certificate - signed by 'some-ssl/ca' ... valid.
          [✔ ] Not a CA Certificate
          [✔ ] Signed by some-ssl/ca
          [✔ ] Valid: expires in 365 days (<timestamp>)
          [✔ ] Modulus Agreement
          [✔ ] Subject Name 'proto-ssl'
          [✔ ] Subject Alt Names: 'proto-ssl'
          [✔ ] Default key usage: server_auth, client_auth

  [ 5/16] ssl/ca X509 certificate - CA, self-signed ... valid.
          [✔ ] CA Certificate
          [✔ ] Self-Signed
          [✔ ] Valid: expires in 3650 days (<timestamp>)
          [✔ ] Modulus Agreement
          [✔ ] Default CA key usage: server_auth, client_auth, crl_sign, key_cert_sign

  [ 6/16] ssl/server X509 certificate - signed by 'ssl/ca' ... valid.
          [✔ ] Not a CA Certificate
          [✔ ] Signed by ssl/ca
          [✔ ] Valid: expires in 365 days (<timestamp>)
          [✔ ] Modulus Agreement
          [✔ ] Subject Name 'bonus.ci'
          [✔ ] Subject Alt Names: 'bonus.ci'
          [✔ ] Default key usage: server_auth, client_auth

  [ 7/16] iaas:access_key user-provided - IaaS Access Key ... found.

  [ 8/16] iaas:secret_key user-provided - IaaS Secret Key ... found.

  [ 9/16] crazy/thing:id random password - 32 bytes, fixed ... valid.
          [✔ ] 32 characters

  [10/16] crazy/thing:token random password - 16 bytes ... valid.
          [✔ ] 16 characters
          [✔ ] Only uses characters 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0987654321'

  [11/16] proto-credentials:seed random password - 64 bytes, fixed ... valid.
          [✔ ] 64 characters

  [12/16] proto-credentials:token random password - 24 bytes ... valid.
          [✔ ] 24 characters
          [✔ ] Formatted as base64 in ':token-base64'

  [13/16] users/admin:password random password - 64 bytes ... valid.
          [✔ ] 64 characters

  [14/16] users/bob:password random password - 16 bytes ... valid.
          [✔ ] 16 characters

  [15/16] work/signing_key RSA public/private keypair - 2048 bits, fixed ... valid.
          [✔ ] Valid private key
          [✔ ] Valid public key
          [✔ ] Public/Private key agreement
          [✔ ] 2048 bit

  [16/16] something/ssh SSH public/private keypair - 2048 bits, fixed ... valid.
          [✔ ] Valid private key
          [✔ ] Valid public key
          [✔ ] Public/Private key Agreement
          [✔ ] 2048 bits

Completed - Duration: XXX seconds [16 validated/0 skipped/0 errors]

EOF
	$director1->stop();
	teardown_vault();
};

subtest 'load environment from env vars' => sub {
	local $ENV{GENESIS_BOSH_COMMAND};
	fake_bosh;

	my ($director1) = fake_bosh_directors(
		{alias => 'standalone'},
	);
	my $vault_target = vault_ok;
	Genesis::Vault->clear_all();
	Genesis::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $top = Genesis::Top->create(workdir, 'thing', vault=>$VAULT_URL)->link_dev_kit('t/src/creator');
	put_file $top->path("base.yml"), <<'EOF'; # Direct YAML
---
kit:
  name:    dev
  version: latest
  features:
    - whiskey
    - tango
    - foxtrot

genesis:
  env: base

params:
  secret: (( vault $GENESIS_SECRETS_BASE "test:secret" ))
  network: (( grab networks[0].name ))
  junk:    ((    vault    "secret/passcode" ))

EOF

put_file $top->path("base-extended.yml"), <<'EOF'; # Direct YAML

kit:
  features:
  - (( replace ))
  - alpha
  - oscar
  - kilo

---

genesis:
  env:      base-extended
  ci_base:   (( concat "/concourse/main/" genesis.env ))
  ci_mount: "/concourse"
  root_ca_path: "company/root-ca"
  secrets_mount: /shhhh/
  credhub_env: "root_vault/credhub"

kit:
  features:
  - (( append ))
  - november

---
genesis:
  min_version: 2.8.0
  use_create_env: true

kit:
  overrides:
    genesis_version_min: 2.8.0
    use_create_env: allow
    certificates:
      base:
        private-cert: # Additional cert signed by existing CA
          server:
            signed_by: "my-cert/ca"
            valid_for: (( defer grab certificates.base.my-cert.server.valid_for )) # Grab from kit.yml
            names: [ (( grab genesis.env )) ] # Grab from env file
      bonus: ~ # Deletion
    credentials:
      bonus:
        need-to-know:
          secret: random 32 #New
        crazy/thing:
          token: random 48 allowed-chars ABCDEF0123456789 # Update

EOF

	my $env = $top->load_env('base-extended')->with_bosh()->with_vault();
	ok $env->use_create_env(), "env does use create-env";
	my %evs; ok %evs = $env->get_environment_variables(), "env can provide environment variables";

	# validate expected environment variables and values
	cmp_deeply(\%evs, {
		GENESIS_ROOT => $env->path,
		GENESIS_ENVIRONMENT => $env->name,
		GENESIS_TYPE => $top->type,
		GENESIS_CALL_BIN => Genesis::humanize_bin(),
		GENESIS_CALL => "genesis",
		GENESIS_CALL_ENV => "genesis ".$env->name,
		GENESIS_CI_BASE => "/concourse/main/".$env->name."/",
		GENESIS_CI_MOUNT => "/concourse/",
		GENESIS_CI_MOUNT_OVERRIDE => "true",
		GENESIS_CREDHUB_EXODUS_SOURCE => "root_vault/credhub",
		GENESIS_CREDHUB_EXODUS_SOURCE_OVERRIDE => "root_vault/credhub", # Shouldn't this be boolean?
		GENESIS_CREDHUB_ROOT => "root_vault-credhub/base-extended-thing",
		GENESIS_ENV_REF => $env->name,
		GENESIS_ENV_KIT_OVERRIDE_FILES => re('\/(var\/folders|tmp)\/.*\/env-overrides-0.yml'),
		GENESIS_EXODUS_BASE => "/shhhh/exodus/base-extended/thing",
		GENESIS_EXODUS_MOUNT => "/shhhh/exodus/",
		GENESIS_EXODUS_MOUNT_OVERRIDE => "",
		GENESIS_KIT_NAME => "dev",
		GENESIS_KIT_VERSION => "latest", # THIS IS NOT IDEAL
		GENESIS_MIN_VERSION => '2.8.0',
		GENESIS_MIN_VERSION_FOR_KIT => '2.8.0',
		GENESIS_REQUESTED_FEATURES => "alpha oscar kilo november",
		GENESIS_ROOT_CA_PATH => "company/root-ca",
		GENESIS_SECRETS_BASE => "/shhhh/base/extended/thing/",
		GENESIS_SECRETS_MOUNT => "/shhhh/",
		GENESIS_SECRETS_MOUNT_OVERRIDE => "true",
		GENESIS_SECRETS_PATH => "base/extended/thing",
		GENESIS_SECRETS_SLUG => "base/extended/thing",
		GENESIS_SECRETS_SLUG_OVERRIDE => "",
		GENESIS_TARGET_VAULT => $vault_target,
		GENESIS_USE_CREATE_ENV => "true",
		GENESIS_VAULT_ENV_SLUG => "base/extended",
		GENESIS_VAULT_PREFIX => "base/extended/thing",
		GENESIS_VERIFY_VAULT => "1",
		SAFE_TARGET => $vault_target,
		GENESIS_ENVIRONMENT_PARAMS => re('^{.*}$'),
		BOSH_ALIAS => undef,
		BOSH_CA_CERT => undef,
		BOSH_CLIENT => undef,
		BOSH_CLIENT_SECRET => undef,
		BOSH_DEPLOYMENT => undef,
		BOSH_ENVIRONMENT => undef
	}, "environment provides the correct environment variables and values");

	# Remove env files
	unlink $top->path($_) for (@{$env->{__actual_files}});

	local %ENV = %ENV;
	$ENV{$_} = $evs{$_} for (keys %evs);
	dies_ok {my $env_from_evs=Genesis::Env->from_envvars($top)} "cannot load environment from env vars outside of callback";

	$ENV{GENESIS_IS_HELPING_YOU} = 1;
	$ENV{GENESIS_KIT_HOOK}="addon";
	dies_ok {my $env_from_evs=Genesis::Env->from_envvars($top)} "cannot load environment from env vars during a non-new hook";

	$ENV{GENESIS_KIT_HOOK}="new";
	ok my $env_from_evs=Genesis::Env->from_envvars($top), "can load environment from env vars during a new hook";
	ok $env_from_evs->use_create_env, "env from env vars uses create env.";
	ok $env_from_evs->{is_from_envvars}, "env from env vars indicates so.";

	my @old_properties = grep {$_ !~ /^(__actual_files)$/}  keys(%$env);
	my @new_properties = grep {$_ !~ /^(__actual_files|is_from_envvars)$/} keys(%$env_from_evs);
	cmp_set(\@new_properties, \@old_properties, "original and from_envvars environments have the same properties");


	for my $property (@old_properties) {
		if ($property eq '__bosh') {
			eq_or_diff ref($env->{__bosh}), ref($env_from_evs->{__bosh}), "reconstituted correct bosh director";
		} elsif ($property eq '__params') {
			# Tweak some known acceptable differences
			$env->{__params}{genesis}{use_create_env} = $env->{__params}{genesis}{use_create_env} =~ /^(1|on|true|yes)$/i ? 'true' : 'false';
			cmp_deeply($env_from_evs->{__params},$env->{__params}, "reconstituted correct parameters");
		} elsif ($property eq '__tmp') {
			eq_or_diff dirname($env->{__tmp}), dirname($env_from_evs->{__tmp}), 'reconstituted similar tmp dirs';
		} elsif ($property eq 'kit') {
			eq_or_diff $env_from_evs->{path}, $env->{path}, 'reconstituted same kit';
			cmp_deeply($env_from_evs->{kit}{__metadata}, $env->{kit}{__metadata}, 'reconstituted same kit configuration');
		} elsif ($property eq '__features') {
			cmp_set($env_from_evs->{__features}, $env->{__features}, 'reconstituted the same features');
		} else {
			eq_or_diff $env_from_evs->{$property}, $env->{$property}, "reconstituted the correct value for $property";
		}
	}

	$director1->stop();
	teardown_vault();
};

subtest 'pre and post deploy reactions' => sub {
	local $ENV{GENESIS_BOSH_COMMAND};
	local $ENV{NOCOLOR} = "yes";
	fake_bosh(<<EOF);
	echo 'BOSH Deploy ran successfully'
	exit 0
EOF

	my ($director1) = fake_bosh_directors(
		{alias => 'reactions'},
	);

	my $vault_target = vault_ok;
	Genesis::Vault->clear_all();
	Genesis::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $top = Genesis::Top->create(workdir, 'thing', vault=>$VAULT_URL);
	# Instead of linking, copy the reactions kit so it can be modified as needed
	`cp -a t/src/reactions ${\($top->path('dev'))}`;

	# Common cloud config
	put_file $top->path(".cloud.yml"), <<EOF;
--- {}
# not really a cloud config, but close enough
EOF


	mkdir_or_fail $top->path('bin');
	put_file $top->path("bin/pass-script.sh"), 0755, <<'EOF';
echo >&2 'This script passed'
i=0
if [[ $# -gt 0 ]] ; then
  for a in "$@" ; do
    echo >&2 "Argument $((++i)): '$a'"
  done
fi
exit 0
EOF
	put_file $top->path("bin/fail-script.sh"), 0755, <<EOF;
echo >&2 'This script failed'
exit 1
EOF

	#  Test failed predeploy:
	put_file $top->path("predeploy-reaction-fail.yml"), <<EOF;
---
kit:
  name:    dev
  version: latest
  features: []

genesis:
  env:  predeploy-reaction-fail
  bosh_env: reactions
  reactions:
    pre:
    - addon: working-addon
      args: [ 'this', 'that' ]
    - script: fail-script.sh
    post:
    - script: pass-script.sh

EOF
	my $env = $top->load_env('predeploy-reaction-fail');
	$env->use_config($top->path(".cloud.yml"));

	my ($stdout,$stderr,$err) = (
		output_from {dies_ok {$env->deploy()} 'deploy exits when invalid reactions defined'},
		$@
	);
	eq_or_diff($err, <<EOF, "deploy error should specify incorrect reactions");

[ERROR] Unexpected reactions specified under genesis.reactions: post, pre
        Valid values: pre-deploy, post-deploy
EOF

	put_file $top->path("predeploy-reaction-fail.yml"), <<EOF;
---
kit:
  name:    dev
  version: latest
  features: []

genesis:
  env:  predeploy-reaction-fail
  bosh_env: reactions
  reactions:
    pre-deploy:
    - addon: working-addon
      args: [ 'this', 'that' ]
    - script: fail-script.sh
EOF
	$env = $top->load_env('predeploy-reaction-fail');
	$env->use_config($top->path(".cloud.yml"));

	run('rm "'. $env->kit->path('hooks/addon') . '"');

	($stdout,$stderr,$err) = (
		output_from {dies_ok {$env->deploy()} "deploy exits when specified addon hook doesn't exist"},
		$@
	);
	eq_or_diff($err, <<EOF, "deploy error should specify incorrect reactions");
Kit reations/in-development (dev) does not provide an addon hook!
EOF

	reset_kit($env->kit);
	($stdout,$stderr,$err) = (
		output_from {dies_ok {$env->deploy()} "deploy exits when specified addon hook fails"},
		$@
	);
	eq_or_diff($err, <<EOF, "deploy error should specify failed reactions");
[ERROR] Cannnot deploy: environment pre-deploy reaction failed!
EOF

	my $fragment = <<'EOF';
\[predeploy-reaction-fail: PRE-DEPLOY\] Running working-addon addon from kit reations/in-development \(dev\):

This addon worked, with arguments of this that

\[predeploy-reaction-fail: PRE-DEPLOY\] Running script `bin/fail-script.sh` with no arguments:

This script failed
EOF
	like($stderr, qr/$fragment/ms, "deploy output should contain the correct pre-deploy output");

	reset_kit($env->kit);
	($stdout,$stderr,$err) = (
		output_from {dies_ok {$env->deploy()} "deploy exits when specified addon hook doesn't exist"},
		$@
	);

	put_file $top->path("postdeploy-reaction-fail.yml"), <<EOF;
---
kit:
  name:    dev
  version: latest
  features: []

genesis:
  env:  postdeploy-reaction-fail
  bosh_env: reactions
  reactions:
    pre-deploy:
    - addon: working-addon
      args: [ 'this', 'that' ]
    - script: pass-script.sh
      args:
        - just a single arg with spaces
    post-deploy:
    - script: fail-script.sh
    - script: pass-script.sh
EOF

	$env = $top->load_env('postdeploy-reaction-fail');
	$env->use_config($top->path(".cloud.yml"));

	($stdout,$stderr,$err) = (
		output_from {lives_ok {$env->deploy()} "deploy runs when pre-deploy reaction passes, but post-deploy reaction fails (and doesn't run remaining reactions after first failed reaction)"},
		$@
	);

	eq_or_diff($err, "", "no fatal error");

	eq_or_diff($stderr, <<'EOF', "deploy output should contain the correct pre-deploy output");

[postdeploy-reaction-fail] reations/in-development (dev) does not define a 'check' hook; BOSH configs and environmental parameters checks will be skipped.

[postdeploy-reaction-fail] running secrets checks...

[postdeploy-reaction-fail] running manifest viability checks...

[postdeploy-reaction-fail] running stemcell checks...

[postdeploy-reaction-fail] generating manifest...

[postdeploy-reaction-fail: PRE-DEPLOY] Running working-addon addon from kit reations/in-development (dev):

This addon worked, with arguments of this that

[postdeploy-reaction-fail: PRE-DEPLOY] Running script `bin/pass-script.sh` with arguments of ["just a single arg with spaces"]:

This script passed
Argument 1: 'just a single arg with spaces'


[postdeploy-reaction-fail] all systems ok, initiating BOSH deploy...


[postdeploy-reaction-fail] Deployment successful.


[postdeploy-reaction-fail: POST-DEPLOY] Running script `bin/fail-script.sh` with no arguments:

This script failed

[WARNING] Environment post-deploy reaction failed!  Manual intervention may be needed.

[postdeploy-reaction-fail] Preparing metadata for export...

[postdeploy-reaction-fail] Done.

EOF

	($stdout,$stderr,$err) = (
		output_from {lives_ok {$env->deploy('disable-reactions' => 1)} "deploy does not run reactions when disabled"},
		$@
	);

	eq_or_diff($err, "", "no fatal error");

	eq_or_diff($stderr, <<'EOF', "deploy output should contain the correct pre-deploy output");

[postdeploy-reaction-fail] reations/in-development (dev) does not define a 'check' hook; BOSH configs and environmental parameters checks will be skipped.

[postdeploy-reaction-fail] running secrets checks...

[postdeploy-reaction-fail] running manifest viability checks...

[postdeploy-reaction-fail] running stemcell checks...

[postdeploy-reaction-fail] generating manifest...

[WARNING] Reactions are disabled for this deploy

[postdeploy-reaction-fail] all systems ok, initiating BOSH deploy...


[postdeploy-reaction-fail] Deployment successful.


[postdeploy-reaction-fail] Preparing metadata for export...

[postdeploy-reaction-fail] Done.

EOF


	teardown_vault();
};

done_testing;
