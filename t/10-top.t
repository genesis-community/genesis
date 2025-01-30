#!perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::Deep;
use Test::Output;
use Cwd ();

use_ok 'Genesis::Config';
$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");

use_ok 'Genesis::Top';
use_ok 'Genesis::Kit::Compiled';
use Genesis;
my $vault_target = vault_ok();

$ENV{GENESIS_OUTPUT_COLUMNS}=80;

subtest 'kit location' => sub {
	my $tmp = workdir();
	my $again = sub {
		system("rm -rf $tmp/.genesis/kits; mkdir -p $tmp/.genesis/kits");
		system("touch $tmp/.genesis/kits/$_") for (qw/
			foo-1.0.0.tar.gz
			foo-1.0.1.tgz
			foo-0.9.6.tar.gz
			foo-0.9.5.tar.gz
			bar-3.4.5.tar.gz

			not-a-kit-file
			unversioned.tar.gz
			unversioned.tgz
		/);
		mkfile_or_fail("$tmp/.genesis/config", <<EOF);
---
version: 2
creator_version: 2.7.0
deployment_type: foo
EOF
	};
	my $top = Genesis::Top->new($tmp);

	$again->();
	ok(!$top->has_dev_kit, "roots without dev/ should not report having a dev kit");
	cmp_deeply($top->local_kits, {
			foo => {
				'0.9.5' => bless({
					'archive'  => $top->path(".genesis/kits/foo-0.9.5.tar.gz"),
					'name'     => 'foo',
					'version'  => '0.9.5',
					'provider' => isa("Genesis::Kit::Provider")
				}, "Genesis::Kit::Compiled"),
				'0.9.6' => bless({
					'archive'  => $top->path(".genesis/kits/foo-0.9.6.tar.gz"),
					'name'     => 'foo',
					'version'  => '0.9.6',
					'provider' => isa("Genesis::Kit::Provider")
				}, "Genesis::Kit::Compiled"),
				'1.0.0' => bless({
					'archive'  => $top->path(".genesis/kits/foo-1.0.0.tar.gz"),
					'name'     => 'foo',
					'version'  => '1.0.0',
					'provider' => isa("Genesis::Kit::Provider")
				}, "Genesis::Kit::Compiled"),
				'1.0.1' => bless({
					'archive'  => $top->path(".genesis/kits/foo-1.0.1.tgz"),
					'name'     => 'foo',
					'version'  => '1.0.1',
					'provider' => isa("Genesis::Kit::Provider")
				}, "Genesis::Kit::Compiled"),
			},
			bar => {
				'3.4.5' => bless({
					'archive'  => $top->path(".genesis/kits/bar-3.4.5.tar.gz"),
					'name'     => 'bar',
					'version'  => '3.4.5',
					'provider' => isa("Genesis::Kit::Provider")
				}, "Genesis::Kit::Compiled"),
			},
		}, "roots should list out all of their compiled kits");

	$again->();
	ok( defined $top->local_kit_version(foo => '1.0.0'), "test root dir should have foo-1.0.0 kit");
	ok(!defined $top->local_kit_version(foo => '9.8.7'), "test root dir should not have foo-9.8.7 kit");
	ok(!defined $top->local_kit_version(quxx => undef), "test root dir should not have any quux kit");
	ok( defined $top->local_kit_version(foo => '1.0.1'), "roots should recognize .tgz kits");
	ok( defined $top->local_kit_version(foo => 'latest'), "root should find latest kit versions");
	is($top->local_kit_version(foo => 'latest')->{version}, '1.0.1', "the latest foo kit should be 1.0.1");
	is($top->local_kit_version(foo => undef)->{version}, '1.0.1', "an undef version should count as 'latest'");
	ok(!defined $top->local_kit_version(undef => 'latest'), "kit name should be required if more than one kit exists");
	ok(!defined $top->local_kit_version(undef => '1.0.0'), "kit name should be requried if more than one kit exists, regardless of version uniqueness");

	$again->();
	system("rm -f $tmp/.genesis/kits/bar-*gz");
	cmp_deeply($top->local_kits, {
			foo => {
				'0.9.5' => bless({
					'archive'  => $top->path(".genesis/kits/foo-0.9.5.tar.gz"),
					'name'     => 'foo',
					'version'  => '0.9.5',
					'provider' => isa("Genesis::Kit::Provider")
				}, "Genesis::Kit::Compiled"),
				'0.9.6' => bless({
					'archive'  => $top->path(".genesis/kits/foo-0.9.6.tar.gz"),
					'name'     => 'foo',
					'version'  => '0.9.6',
					'provider' => isa("Genesis::Kit::Provider")
				}, "Genesis::Kit::Compiled"),
				'1.0.0' => bless({
					'archive'  => $top->path(".genesis/kits/foo-1.0.0.tar.gz"),
					'name'     => 'foo',
					'version'  => '1.0.0',
					'provider' => isa("Genesis::Kit::Provider")
				}, "Genesis::Kit::Compiled"),
				'1.0.1' => bless({
					'archive'  => $top->path(".genesis/kits/foo-1.0.1.tgz"),
					'name'     => 'foo',
					'version'  => '1.0.1',
					'provider' => isa("Genesis::Kit::Provider")
				}, "Genesis::Kit::Compiled"),
			},
		}, "root should only have `foo' kit");
	ok( defined $top->local_kit_version(undef, 'latest'), "root should find latest kit version of only kit");
	ok( defined $top->local_kit_version(undef, '0.9.6'), "root should find 0.9.6 kit version of only kit");
	is($top->local_kit_version(undef, 'latest')->{version}, '1.0.1', "the latest foo kit should be 1.0.1");
	is($top->local_kit_version(undef, 'latest')->{name}, 'foo', "the only kit should be 'foo'");
	is($top->local_kit_version(undef, '0.9.6')->{version}, '0.9.6', "specific version of the kit are returned");
	is($top->local_kit_version(undef, '0.9.6')->{name}, 'foo', "the only kit should be 'foo' (0.9.6)");
};

subtest 'init' => sub {
	my ($tmp, $top);

	# without a directory override
	$tmp = workdir;
	ok ! -f "$tmp/jumpbox-deployments/.genesis/config", "No .genesis/config in new Top";
	$top = Genesis::Top->create($tmp, 'jumpbox', vault=>$VAULT_URL);
	ok -f "$tmp/jumpbox/.genesis/config", ".genesis created in correct top dir";
	ok -f $top->path('.genesis/config'), "Top->create should create a new .genesis/config";
	is $top->type, 'jumpbox', 'an initialized top has a type';
	is $top->vault->url, $VAULT_URL, 'specifies the correct vault url';

	cmp_deeply $top->config->_contents, {
		creator_version => ignore,
		version => 2,
		deployment_type => 'jumpbox',
		manifest_store => ignore,
		secrets_provider => {
			url => $VAULT_URL,
			insecure => bool(0),
			strongbox => bool(0),
			namespace => "",
			alias => $vault_target
		}
	}, ".genesis/config contains correct information";

	# with a directory override
	$tmp = workdir;
	my $dir = "être_réel.my-dep";
	$ENV{NOCOLOR} = 1;
	throws_ok {Genesis::Top->create($tmp, 'jumpbox', directory => '../bad', vault=>$VAULT_URL)} qr/\[FATAL\] Repository directory name must only contain alpha-numeric characters,\n *periods, hyphens and underscores/, "Doesn't accept slashes in directory names";
	throws_ok {Genesis::Top->create($tmp, 'jumpbox', directory => 'also bad', vault=>$VAULT_URL)} qr/\[FATAL\] Repository directory name must only contain alpha-numeric characters,\n *periods, hyphens and underscores/, "Doesn't accept spaces in directory names";
	lives_ok  {$top = Genesis::Top->create($tmp, 'jumpbox', directory => $dir, vault=>$VAULT_URL)} "Accepts underscore, period, dashes and accents in directory name";
	ok -f Cwd::abs_path("$tmp/$dir/.genesis/config"), ".genesis created in correct top dir";
	ok -f $top->path('.genesis/config'), "Top->create should create a new .genesis/config";
	is $top->type, 'jumpbox', 'an initialized top has a type';
	is $top->vault->url, $VAULT_URL, 'specifies the correct vault url';

	# overwrite tests
	$tmp = workdir;
	lives_ok { Genesis::Top->create($tmp, 'test', vault=>$VAULT_URL) } "it should be okay to init once";
	throws_ok { Genesis::Top->create($tmp, 'test', vault=>$VAULT_URL) } qr/\[FATAL\] Cannot create new deployments repository `test': already exists!/,
		"it is not okay to init twice";

	# name validation
	throws_ok { Genesis::Top->create($tmp, '!@#$ing-deployments', vault=>$VAULT_URL) } qr/invalid Genesis deployment repository name '!@#\$ing'/i,
		"it is not okay to swear in genesis repo names";
};

subtest 'embedding stuff' => sub {
	my $tmp = workdir;
	my $top = Genesis::Top->create($tmp, 'thing', vault=>$VAULT_URL);
	put_file("$tmp/not-genesis", <<EOF);
#!/bin/bash
echo "this is not genesis"
EOF
	system("$tmp/not-genesis 2>/dev/null");
	isnt $?, 0, "tmp/not-genesis should not be executable";

	ok ! -f "$tmp/thing/.genesis/bin/genesis",
		"genesis bin should not be embedded by default";

	$top->embed("$tmp/not-genesis");
	ok -f "$tmp/thing/.genesis/bin/genesis",
		"genesis bin should be embedded once we call embed()";

	is qx($tmp/thing/.genesis/bin/genesis), "this is not genesis\n",
		"embed() makes the embedded copy executable";
};

subtest 'downloading kits' => sub {
	my $tmp = workdir();
	my $again = sub {
		system("rm -rf $tmp/.genesis/kits; mkdir -p $tmp/.genesis/kits");
	};
	my $top = Genesis::Top->new($tmp);

	$again->();
	ok(!defined $top->local_kit_version('bosh'), "bosh kit shouldn't exist (before download)");
	$top->download_kit("bosh/0.2.0");
	ok( defined $top->local_kit_version('bosh'), "bosh kit should exist after we download");
	ok( defined $top->local_kit_version('bosh', '0.2.0'), "top downloaded bosh-0.2.0 as requested");
};

subtest 'manage secrets provider' => sub {
	my $tmp = workdir();

	my $reset = sub {
		system("rm -rf $tmp/.genesis; mkdir -p $tmp/.genesis");
		mkfile_or_fail("$tmp/.genesis/config", $_[0]);
	};

	$reset->(<<EOF);
---
version: 2
deployment_type: test
creator_version: 99.99.99
EOF

	# Check that top uses the system vault if no vault present in config
	my $top = Genesis::Top->new($tmp);
	ok(! $top->has_vault, "legacy top correctly identifies not having a vault");
	my $v;
	lives_ok {$v = $top->vault} "legacy top does not error when asked for a vault";
	ok(ref($v) eq "Service::Vault::Remote", "legacy top retuns a vault when asked");
	ok($v->name eq $vault_target, "legacy top returns the system default vault");

	my $other_vault_name = "genesis-ci-unit-tests-extra";
	my $other_vault = vault_ok($other_vault_name);
	Service::Vault->clear_all();

	# Check that top picks up the changed system vault if no vault present in config
	$top = Genesis::Top->new($tmp);
	ok(! $top->has_vault, "legacy top still correctly identifies not having a vault");
	lives_ok {$v = $top->vault} "legacy top still does not error when asked for a vault";
	ok(ref($v) eq "Service::Vault::Remote", "legacy top still retuns a vault when asked");
	ok($v->name eq $other_vault_name, "legacy top returns the new system default vault");

	# Check that you can override a vault if none present in config
	lives_ok {$top = Genesis::Top->new($tmp, vault => $other_vault_name)} "allows vault to be overridden if absent from config";
	is(ref($top->vault), "Service::Vault::Remote", "overridden vault is a Service::Vault::Remote");
	is($top->vault->{name}, $other_vault_name, "overridden vault is the expected vault");

	# Check that vault can be changed and set in config when no vault is in config
	is($top->set_vault(target => $VAULT_URL{$vault_target}), undef, "top can set its registered vault when it doesn't have one");
	is($top->config->get('secrets_provider.url'),$VAULT_URL{$vault_target} , "top updates its configuration after saving its new vault");
	is(ref($top->{__vault}), "Service::Vault::Remote", "top has a vault after saving its new vault");
	is($top->{__vault}->url, $VAULT_URL{$vault_target}, "top has the correct vault after saving its new vault");
	is($top->vault->{name}, $vault_target, "top targets the expected vault");
	yaml_is(get_file("$tmp/.genesis/config"), <<EOF, ".genesis/config contains the correct information");
---
creator_version: 99.99.99
deployment_type: test
manifest_store: hybrid
secrets_provider:
  url: $VAULT_URL{$vault_target}
  insecure: false
  strongbox: false
  namespace: ""
  alias: $vault_target
updater_version: (development)
version: 2
EOF
	cmp_deeply($top->config->_contents, {
			"deployment_type" => "test",
			"manifest_store"  => "hybrid",
			"creator_version" => "99.99.99",
			"updater_version" => "(development)",
			"version" => 2,
			"secrets_provider" => {
				"url" => $VAULT_URL{$vault_target},
				"insecure" => bool(0),
				"strongbox" => bool(0),
				"namespace" => "",
				"alias" => $vault_target,
			}
		}, "repo .genesis/config contains the updated information"
	);

	# Check that vault can be temporarily changed and set in config
	is($top->set_vault(target => $VAULT_URL{$other_vault_name}, session_only => 1), undef, "top can set its registered vault when it doesn't have one");
	isnt($top->config->_contents, undef, "top doesn't clears its configuration after setting a temporary vault");
	is($top->vault->{name}, $other_vault_name, "top targets the expected vault");
	yaml_is(get_file("$tmp/.genesis/config"), <<EOF, ".genesis/config contains the correct information");
---
creator_version: 99.99.99
deployment_type: test
manifest_store: hybrid
secrets_provider:
  url: $VAULT_URL{$vault_target}
  insecure: false
  strongbox: false
  namespace: ""
  alias: $vault_target
updater_version: (development)
version: 2
EOF
	cmp_deeply($top->config->_contents, {
			"deployment_type" => "test",
			"manifest_store"  => "hybrid",
			"creator_version" => "99.99.99",
			"updater_version" => "(development)",
			"version" => 2,
			"secrets_provider" => {
				"url" => $VAULT_URL{$vault_target},
				"insecure" => bool(0),
				"strongbox" => bool(0),
				"namespace" => "",
				"alias" => $vault_target
			}
		}, "repo .genesis/config hasn't changed"
	);

	# Check that vault can be changed and set in config when a vault is already in config
	is($top->set_vault(target => $VAULT_URL{$other_vault_name}), undef, "top can set its registered vault when it already has one");
	is($top->config->get('secrets_provider.url'),$VAULT_URL{$other_vault_name} , "top updates its configuration after saving its new vault");
	is(ref($top->{__vault}), "Service::Vault::Remote", "top has a vault after saving its new vault");
	is($top->{__vault}->url, $VAULT_URL{$other_vault_name}, "top has the correct vault after saving its new vault");
	is($top->vault->{name}, $other_vault_name, "top targets the expected vault");
	yaml_is(get_file("$tmp/.genesis/config"), <<EOF, ".genesis/config contains the correct information");
---
creator_version: 99.99.99
deployment_type: test
manifest_store: hybrid
secrets_provider:
  url: $VAULT_URL{$other_vault_name}
  insecure: false
  strongbox: false
  namespace: ""
  alias: $other_vault_name
updater_version: (development)
version: 2
EOF
	cmp_deeply($top->config->_contents, {
			"deployment_type" => "test",
			"manifest_store"  => "hybrid",
			"creator_version" => "99.99.99",
			"updater_version" => "(development)",
			"version" => 2,
			"secrets_provider" => {
				"url" => $VAULT_URL{$other_vault_name},
				"insecure" => bool(0),
				"strongbox" => bool(0),
				"namespace" => "",
				"alias" => $other_vault_name
			}
		}, "repo .genesis/config contains the updated information"
	);

	my $new_top;
	my ($ansi_ltred, $ansi_ltcyan, $ansi_reset) = ("\e[1;31m", "\e[1;36m", "\e[0m");
	lives_ok {$new_top = Genesis::Top->new($tmp, vault => $vault_target)};
	is(ref($new_top->vault), "Service::Vault::Remote", "Top vault is a vault object");
	is($new_top->vault->{url}, $VAULT_URL{$vault_target}, "Other vault is used by top");
};

teardown_vault();
done_testing;
