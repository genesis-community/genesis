#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::Deep;
use Test::Output;
use Cwd ();

use_ok 'Genesis::Top';
use Genesis;
my $vault_target = vault_ok();

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
	};
	my $top = Genesis::Top->new($tmp);

	$again->();
	ok(!$top->has_dev_kit, "roots without dev/ should not report having a dev kit");
	cmp_deeply($top->compiled_kits, {
			foo => {
				'0.9.5' => $top->path(".genesis/kits/foo-0.9.5.tar.gz"),
				'0.9.6' => $top->path(".genesis/kits/foo-0.9.6.tar.gz"),
				'1.0.0' => $top->path(".genesis/kits/foo-1.0.0.tar.gz"),
				'1.0.1' => $top->path(".genesis/kits/foo-1.0.1.tgz"),
			},
			bar => {
				'3.4.5' => $top->path(".genesis/kits/bar-3.4.5.tar.gz"),
			},
		}, "roots should list out all of their compiled kits");

	$again->();
	ok( defined $top->find_kit(foo => '1.0.0'), "test root dir should have foo-1.0.0 kit");
	ok(!defined $top->find_kit(foo => '9.8.7'), "test root dir should not have foo-9.8.7 kit");
	ok(!defined $top->find_kit(quxx => undef), "test root dir should not have any quux kit");
	ok( defined $top->find_kit(foo => '1.0.1'), "roots should recognize .tgz kits");
	ok( defined $top->find_kit(foo => 'latest'), "root should find latest kit versions");
	is($top->find_kit(foo => 'latest')->{version}, '1.0.1', "the latest foo kit should be 1.0.1");
	is($top->find_kit(foo => undef)->{version}, '1.0.1', "an undef version should count as 'latest'");
	ok(!defined $top->find_kit(undef => 'latest'), "kit name should be required if more than one kit exists");
	ok(!defined $top->find_kit(undef => '1.0.0'), "kit name should be requried if more than one kit exists, regardless of version uniqueness");

	$again->();
	system("rm -f $tmp/.genesis/kits/bar-*gz");
	cmp_deeply($top->compiled_kits, {
			foo => {
				'0.9.5' => $top->path(".genesis/kits/foo-0.9.5.tar.gz"),
				'0.9.6' => $top->path(".genesis/kits/foo-0.9.6.tar.gz"),
				'1.0.0' => $top->path(".genesis/kits/foo-1.0.0.tar.gz"),
				'1.0.1' => $top->path(".genesis/kits/foo-1.0.1.tgz"),
			},
		}, "root should only have `foo' kit");
	ok( defined $top->find_kit(undef, 'latest'), "root should find latest kit version of only kit");
	ok( defined $top->find_kit(undef, '0.9.6'), "root should find 0.9.6 kit version of only kit");
	is($top->find_kit(undef, 'latest')->{version}, '1.0.1', "the latest foo kit should be 1.0.1");
	is($top->find_kit(undef, 'latest')->{name}, 'foo', "the only kit should be 'foo'");
	is($top->find_kit(undef, '0.9.6')->{version}, '0.9.6', "specific version of the kit are returned");
	is($top->find_kit(undef, '0.9.6')->{name}, 'foo', "the only kit should be 'foo' (0.9.6)");
};

subtest 'init' => sub {
	my ($tmp, $top);

	# without a directory override
	$tmp = workdir;
	ok ! -f "$tmp/jumpbox-deployments/.genesis/config", "No .genesis/config in new Top";
	$top = Genesis::Top->create($tmp, 'jumpbox', vault=>$VAULT_URL);
	ok -f "$tmp/jumpbox-deployments/.genesis/config", ".genesis created in correct top dir";
	ok -f $top->path('.genesis/config'), "Top->create should create a new .genesis/config";
	is $top->type, 'jumpbox', 'an initialized top has a type';
	is $top->vault->url, $VAULT_URL, 'specifies the correct vault url';
	cmp_deeply $top->config, {
		genesis_version => ignore,
		deployment_type => 'jumpbox',
		secrets_provider => {
			url => $VAULT_URL,
			insecure => bool(0)
		}
	}, ".genesis/config contains correct information";

	# with a directory override
	$tmp = workdir;
	$top = Genesis::Top->create($tmp, 'jumpbox', directory => 'something-else', vault=>$VAULT_URL);
	ok -f Cwd::abs_path("$tmp/something-else/.genesis/config"), ".genesis created in correct top dir";
	ok -f $top->path('.genesis/config'), "Top->create should create a new .genesis/config";
	is $top->type, 'jumpbox', 'an initialized top has a type';
	is $top->vault->url, $VAULT_URL, 'specifies the correct vault url';

	# overwrite tests
	$tmp = workdir;
	lives_ok { Genesis::Top->create($tmp, 'test', vault=>$VAULT_URL) } "it should be okay to init once";
	throws_ok { Genesis::Top->create($tmp, 'test', vault=>$VAULT_URL) } qr/cowardly refusing/i,
		"it is not okay to init twice";

	# name validation
	throws_ok { Genesis::Top->create($tmp, '!@#$ing-deployments', vault=>$VAULT_URL) } qr/invalid genesis repo name/i,
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

	ok ! -f "$tmp/thing-deployments/.genesis/bin/genesis",
		"genesis bin should not be embedded by default";

	$top->embed("$tmp/not-genesis");
	ok -f "$tmp/thing-deployments/.genesis/bin/genesis",
		"genesis bin should be embedded once we call embed()";

	is qx($tmp/thing-deployments/.genesis/bin/genesis), "this is not genesis\n",
		"embed() makes the embedded copy executable";
};

subtest 'downloading kits' => sub {
	my $tmp = workdir();
	my $again = sub {
		system("rm -rf $tmp/.genesis/kits; mkdir -p $tmp/.genesis/kits");
	};
	my $top = Genesis::Top->new($tmp);

	$again->();
	ok(!defined $top->find_kit('bosh'), "bosh kit shouldn't exist (before download)");
	$top->download_kit("bosh/0.2.0");
	ok( defined $top->find_kit('bosh'), "bosh kit should exist after we download");
	ok( defined $top->find_kit('bosh', '0.2.0'), "top downloaded bosh-0.2.0 as requested");
};

subtest 'manage secrets provider' => sub {
	my $tmp = workdir();

	my $reset = sub {
		system("rm -rf $tmp/.genesis; mkdir -p $tmp/.genesis");
		mkfile_or_fail("$tmp/.genesis/config", $_[0]);
	};

	$reset->(<<EOF);
---
deployment_type: test
genesis_version: 99.99.99
EOF

	# Check that top uses the system vault if no vault present in config
	my $top = Genesis::Top->new($tmp);
	ok(! $top->has_vault, "legacy top correctly identifies not having a vault");
	my $v;
	lives_ok {$v = $top->vault} "legacy top does not error when asked for a vault";
	ok(ref($v) eq "Genesis::Vault", "legacy top retuns a vault when asked");
	ok($v->name eq $vault_target, "legacy top returns the system default vault");

	my $other_vault_name = "genesis-ci-unit-tests-extra";
	my $other_vault = vault_ok($other_vault_name);
	Genesis::Vault->clear_all();

	# Check that top picks up the changed system vault if no vault present in config
	$top = Genesis::Top->new($tmp);
	ok(! $top->has_vault, "legacy top still correctly identifies not having a vault");
	lives_ok {$v = $top->vault} "legacy top still does not error when asked for a vault";
	ok(ref($v) eq "Genesis::Vault", "legacy top still retuns a vault when asked");
	ok($v->name eq $other_vault_name, "legacy top returns the new system default vault");

	# Check that you can override a vault if none present in config
	lives_ok {$top = Genesis::Top->new($tmp, vault => $other_vault_name)} "allows vault to be overridden if absent from config";
	is(ref($top->vault), "Genesis::Vault", "overridden vault is a Genesis::Vault");
	is($top->vault->{name}, $other_vault_name, "overridden vault is the expected vault");

	# Check that vault can be changed and set in config when no vault is in config
	is($top->set_vault(target => $VAULT_URL{$vault_target}), undef, "top can set its registered vault when it doesn't have one");
	is($top->{_config}, undef, "top clears its configuration after saving its new vault");
	is($top->{_vault}, undef, "top clears its vault after saving its new vault");
	is($top->vault->{name}, $vault_target, "top targets the expected vault");
	yaml_is(get_file("$tmp/.genesis/config"), <<EOF, ".genesis/config contains the correct information");
---
genesis_version: 99.99.99
deployment_type: test
secrets_provider:
  url: $VAULT_URL{$vault_target}
  insecure: false
EOF
	cmp_deeply($top->config, {
			"deployment_type" => "test",
			"genesis_version" => "99.99.99",
			"secrets_provider" => {
				"url" => $VAULT_URL{$vault_target},
				"insecure" => bool(0)
			}
		}, "repo .genesis/config contains the updated information"
	);

	# Check that vault can be temporarily changed and set in config
	is($top->set_vault(target => $VAULT_URL{$other_vault_name}, session_only => 1), undef, "top can set its registered vault when it doesn't have one");
	isnt($top->{_config}, undef, "top doesn't clears its configuration after setting a temporary vault");
	isnt($top->{_vault}, undef, "top clears its vault after saving its new vault");
	is($top->vault->{name}, $other_vault_name, "top targets the expected vault");
	yaml_is(get_file("$tmp/.genesis/config"), <<EOF, ".genesis/config contains the correct information");
---
genesis_version: 99.99.99
deployment_type: test
secrets_provider:
  url: $VAULT_URL{$vault_target}
  insecure: false
EOF
	cmp_deeply($top->config, {
			"deployment_type" => "test",
			"genesis_version" => "99.99.99",
			"secrets_provider" => {
				"url" => $VAULT_URL{$vault_target},
				"insecure" => bool(0)
			}
		}, "repo .genesis/config hasn't changed"
	);

	# Check that vault can be changed and set in config when a vault is already in config
	is($top->set_vault(target => $VAULT_URL{$other_vault_name}), undef, "top can set its registered vault when it already has one");
	is($top->{_config}, undef, "top clears its configuration after saving its new vault");
	is($top->{_vault}, undef, "top clears its vault after saving its new vault");
	is($top->vault->{name}, $other_vault_name, "top targets the expected vault");
	yaml_is(get_file("$tmp/.genesis/config"), <<EOF, ".genesis/config contains the correct information");
---
genesis_version: 99.99.99
deployment_type: test
secrets_provider:
  url: $VAULT_URL{$other_vault_name}
  insecure: false
EOF
	cmp_deeply($top->config, {
			"deployment_type" => "test",
			"genesis_version" => "99.99.99",
			"secrets_provider" => {
				"url" => $VAULT_URL{$other_vault_name},
				"insecure" => bool(0)
			}
		}, "repo .genesis/config contains the updated information"
	);

	my $new_vault;
	my ($ansi_ltred, $ansi_ltcyan, $ansi_reset) = ("\e[1;31m", "\e[1;36m", "\e[0m");
	throws_ok {$new_vault = Genesis::Top->new($tmp, vault => $other_vault_name)}
		qr"\[.*m\[ERROR\]\[0m Cannot specify \[.*m--vault ${other_vault_name}\[0m: Deployment already has an associated secrets provider",
		"does not allow vault to be overridden if present in config, and gives correct error message";
};

teardown_vault();
done_testing;
