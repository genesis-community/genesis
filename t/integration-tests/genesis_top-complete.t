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

plan tests => 14; # Total subtests and tests outside subtests

use_ok 'Genesis::Config';
$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");

use_ok 'Genesis::Top';
use_ok 'Genesis::Kit::Compiled';
use Genesis;
use Genesis::Commands::Kit;
my $vault_target = vault_ok();

$ENV{GENESIS_OUTPUT_COLUMNS}=80;
$Genesis::VERSION = '99.99.99'; # Avoid version_min_source warnings in tests

subtest 'init' => sub {
	plan tests => 16;

	my ($tmp, $top);

	# without a directory override
	$tmp = workdir;
	ok ! -f "$tmp/jumpbox-deployments/.genesis/config", "No .genesis/config in new Top";
	local $Genesis::VERSION = "3.1.0";
	$top = Genesis::Top->create($tmp, 'jumpbox', vault=>$VAULT_URL);
	ok -f "$tmp/jumpbox/.genesis/config", ".genesis created in correct top dir";
	ok -f $top->path('.genesis/config'), "Top->create should create a new .genesis/config";
	is $top->type, 'jumpbox', 'an initialized top has a type';
	is $top->vault->url, $VAULT_URL, 'specifies the correct vault url';

	cmp_deeply $top->config->_explicit_contents, {
		creator_version => ignore,
		version => 2,
		deployment_type => 'jumpbox',
		manifest_store => 'exodus',
		minimum_version => '3.1.0',
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
	plan tests => 4;

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

# Cached kit and repo for reuse across subtests
our $CACHED_KIT_REPO;
our $CACHED_KIT_TOP;
our $KITS_DOWNLOADED = 0; # Flag indicating both bosh kits were successfully downloaded

subtest 'kit provider info' => sub {
	plan tests => 5;

	my $tmp = workdir();
	my $top = Genesis::Top->create($tmp, 'test', vault=>$VAULT_URL);

	# Test default Genesis Community provider
	my %provider_info = $top->kit_provider_info();
	ok(%provider_info, "kit_provider_info() returns provider information");
	ok($provider_info{type}, "provider info has type");
	is($provider_info{type}, 'genesis-community', "default provider is genesis-community");
	ok($provider_info{Source}, "provider info has Source field");
	like($provider_info{Source}, qr/Genesis Community/i, "Source field contains Genesis Community");

	# Cache top for subsequent tests
	$CACHED_KIT_REPO = "$tmp/test";
	$CACHED_KIT_TOP = $top;
};

subtest 'remote kit discovery' => sub {
	plan tests => 6, skip_all => 'requires kit provider' unless $CACHED_KIT_TOP;

	my $top = $CACHED_KIT_TOP;

	# Test remote_kit_names - verify common kits are available
	my @kit_names = $top->remote_kit_names();
	ok(@kit_names > 0, "remote_kit_names() returns kit list");

	my %kits = map { $_ => 1 } @kit_names;
	ok($kits{bosh}, "bosh kit is available in remote kit list");
	ok($kits{cf}, "cf kit is available in remote kit list");
	ok($kits{vault}, "vault kit is available in remote kit list");
	ok($kits{jumpbox}, "jumpbox kit is available in remote kit list");

	# Store kit names for debugging if needed
	note("Available kits: " . join(", ", sort @kit_names));

	ok(1, "remote kit discovery completed");
};

subtest 'remote kit versions' => sub {
	plan tests => 10, skip_all => 'requires kit provider' unless $CACHED_KIT_TOP;

	my $top = $CACHED_KIT_TOP;

	# Test remote_kit_versions for bosh kit - returns array of hash refs
	my @bosh_version_info = $top->remote_kit_versions('bosh');
	ok(@bosh_version_info > 0, "remote_kit_versions() returns version list for bosh kit");

	# Verify all entries are hash refs with required fields
	ok((List::Util::all { ref($_) eq 'HASH' } @bosh_version_info),
		"all version entries are hash references");
	ok((List::Util::all { exists $_->{version} } @bosh_version_info),
		"all version entries have 'version' field");
	ok((List::Util::all { exists $_->{url} } @bosh_version_info),
		"all version entries have 'url' field");
	ok((List::Util::all { exists $_->{filename} } @bosh_version_info),
		"all version entries have 'filename' field");
	ok((List::Util::all { exists $_->{date} } @bosh_version_info),
		"all version entries have 'date' field");
	ok((List::Util::all { exists $_->{body} } @bosh_version_info),
		"all version entries have 'body' field");

	# Extract version strings and check for specific known versions
	my @bosh_versions = map { $_->{version} } @bosh_version_info;
	my %versions = map { $_ => 1 } @bosh_versions;
	ok($versions{'1.0.0'}, "bosh kit version 1.0.0 (classic) is available");
	ok($versions{'4.0.5'}, "bosh kit version 4.0.5 (new-style) is available");

	# Store versions for debugging
	note("Available bosh versions: " . join(", ", sort @bosh_versions));

	ok(scalar(@bosh_versions) >= 2, "bosh kit has multiple versions available");
};

subtest 'remote kit version info' => sub {
	plan tests => 14, skip_all => 'requires kit provider' unless $CACHED_KIT_TOP;

	my $top = $CACHED_KIT_TOP;

	# Test version info for classic kit (1.0.0) - kit_versions returns array but we filter to one
	my ($classic_info) = grep { $_->{version} eq '1.0.0' } $top->remote_kit_versions('bosh');
	ok($classic_info, "remote_kit_version_info() returns info for bosh/1.0.0");
	ok(ref($classic_info) eq 'HASH', "version info is a hash reference");
	ok($classic_info->{version}, "version info has version field");
	is($classic_info->{version}, '1.0.0', "version info matches requested version");
	ok($classic_info->{url}, "classic kit has url field");
	ok($classic_info->{filename}, "classic kit has filename field");
	ok($classic_info->{date}, "classic kit has date field");

	# Test version info for new-style kit (4.0.5)
	my ($newstyle_info) = grep { $_->{version} eq '4.0.5' } $top->remote_kit_versions('bosh');
	ok($newstyle_info, "remote_kit_version_info() returns info for bosh/4.0.5");
	ok(ref($newstyle_info) eq 'HASH', "version info is a hash reference");
	ok($newstyle_info->{version}, "version info has version field");
	is($newstyle_info->{version}, '4.0.5', "version info matches requested version");
	ok($newstyle_info->{url}, "new-style kit has url field");
	ok($newstyle_info->{filename}, "new-style kit has filename field");
	ok($newstyle_info->{date}, "new-style kit has date field");
};

subtest 'downloading kits' => sub {
	plan tests => 7, skip_all => 'requires kit provider' unless $CACHED_KIT_TOP;

	my $top = $CACHED_KIT_TOP;
	my $tmp = $CACHED_KIT_REPO;

	# Download classic kit (1.0.0)
	ok(!defined $top->local_kit_version('bosh', '1.0.0'), "bosh/1.0.0 shouldn't exist before download");
	$top->download_kit("bosh/1.0.0");
	ok(defined $top->local_kit_version('bosh', '1.0.0'), "bosh/1.0.0 exists after download");

	# Download new-style kit (4.0.5)
	ok(!defined $top->local_kit_version('bosh', '4.0.5'), "bosh/4.0.5 shouldn't exist before download");
	$top->download_kit("bosh/4.0.5");
	ok(defined $top->local_kit_version('bosh', '4.0.5'), "bosh/4.0.5 exists after download");

	# Verify both are available
	ok(defined $top->local_kit_version('bosh'), "bosh kit exists after downloads");

	# Verify we have multiple versions
	my @local_bosh_versions = grep { defined } map {
		$top->local_kit_version('bosh', $_)
	} ('1.0.0', '4.0.5');
	is(scalar(@local_bosh_versions), 2, "both bosh versions are locally available");

	# Set flag for subsequent tests
	$KITS_DOWNLOADED = (scalar(@local_bosh_versions) == 2);

	ok(1, "kit download completed successfully");
};

subtest 'load_env with downloaded kit' => sub {
	plan tests => 16, skip_all => 'requires successful kit download' unless $KITS_DOWNLOADED;

	my $top = $CACHED_KIT_TOP;
	my $tmp = $CACHED_KIT_REPO;

	# Test classic kit (1.0.0)
	mkfile_or_fail("$tmp/test-classic.yml", <<EOF);
---
kit:
  name: bosh
  version: 1.0.0

genesis:
  env: test-classic

params:
  env_type: test
EOF

	my $env_classic = $top->load_env('test-classic');
	ok($env_classic, "load_env() successfully loads environment with classic kit");
	isa_ok($env_classic, 'Genesis::Env', "load_env() returns Genesis::Env object for classic kit");
	is($env_classic->name, 'test-classic', "loaded classic environment has correct name");
	ok($env_classic->kit, "loaded classic environment has kit object");
	is($env_classic->kit->id, 'bosh/1.0.0', "loaded classic environment kit id is 'bosh/1.0.0'");

	# Test new-style kit (4.0.5)
	mkfile_or_fail("$tmp/test-newstyle.yml", <<EOF);
---
kit:
  name: bosh
  version: 4.0.5

genesis:
  env: test-newstyle

params:
  env_type: test
EOF

	my $env_newstyle = $top->load_env('test-newstyle');
	ok($env_newstyle, "load_env() successfully loads environment with new-style kit");
	isa_ok($env_newstyle, 'Genesis::Env', "load_env() returns Genesis::Env object for new-style kit");
	is($env_newstyle->name, 'test-newstyle', "loaded new-style environment has correct name");
	ok($env_newstyle->kit, "loaded new-style environment has kit object");
	is($env_newstyle->kit->id, 'bosh/4.0.5', "loaded new-style environment kit id is 'bosh/4.0.5'");

	# Test with .yml extension
	my $env2 = $top->load_env('test-classic.yml');
	ok($env2, "load_env() handles .yml extension");
	is($env2->name, 'test-classic', "load_env() strips .yml extension correctly");

	# Test that has_env returns true for both environments
	ok($top->has_env('test-classic'), "has_env() returns true for classic environment");
	ok($top->has_env('test-newstyle'), "has_env() returns true for new-style environment");

	# Verify we can load either kit version
	ok($env_classic->kit->id ne $env_newstyle->kit->id, "different environments use different kit versions");
	ok(1, "load_env completed for both classic and new-style kits");
};

subtest 'load_env with local dev kit' => sub {
	plan tests => 23, skip_all => 'requires successful kit download' unless $KITS_DOWNLOADED;

	my $top = $CACHED_KIT_TOP;
	my $tmp = $CACHED_KIT_REPO;

	# Extract a downloaded kit to use as dev kit
	my $kit_path = $top->path(".genesis/kits/bosh-4.0.5.tar.gz");
	ok(-f $kit_path, "bosh-4.0.5 kit archive exists");

	my $kit = Genesis::Kit::Compiled->new(archive => $kit_path);
	ok($kit, "loaded compiled kit from archive");

	# Extract kit to temporary location
	my $extract_dir = workdir();
	$kit->extract();
	my $kit_root = $kit->{root};
	ok(-d $kit_root, "kit extracted to temporary directory");

	# Link the extracted kit as dev
	ok(!$top->has_dev_kit(), "repo doesn't have dev kit before linking");
	$top->link_dev_kit($kit_root);
	ok($top->has_dev_kit(), "repo has dev kit after linking");
	ok(-l $top->path('dev'), "dev is a symlink");

	# Create environment using dev kit - name must be 'dev', version by convention is 'latest'
	mkfile_or_fail("$tmp/test-dev.yml", <<EOF);
---
kit:
  name: dev
  version: latest

genesis:
  env: test-dev

params:
  env_type: test
EOF

	# Test loading with name: dev, version: latest
	my $env_dev = $top->load_env('test-dev');
	ok($env_dev, "load_env() successfully loads environment with dev kit (name: dev, version: latest)");
	isa_ok($env_dev, 'Genesis::Env', "load_env() returns Genesis::Env object for dev kit");
	is($env_dev->name, 'test-dev', "loaded dev environment has correct name");
	ok($env_dev->kit, "loaded dev environment has kit object");
	is($env_dev->kit->id, 'bosh/4.0.5 (dev)', "dev kit id is 'bosh/4.0.5 (dev)' for symlinked kit");

	# Create another environment using 'dev' as version (version can be anything)
	mkfile_or_fail("$tmp/test-devver.yml", <<EOF);
---
kit:
  name: dev
  version: dev

genesis:
  env: test-devver

params:
  env_type: test
EOF

	# Test loading with name: dev, version: dev (version can be arbitrary)
	my $env_devver = $top->load_env('test-devver');
	ok($env_devver, "load_env() successfully loads environment with name 'dev' and version 'dev'");
	ok($env_devver->kit, "loaded dev version environment has kit object");
	is($env_devver->kit->id, 'bosh/4.0.5 (dev)', "dev kit id is 'bosh/4.0.5 (dev)' regardless of version in env file");

	# Now test with literal dev directory (not a symlink)
	# Remove the symlink
	unlink($top->path('dev'));
	ok(!$top->has_dev_kit(), "repo doesn't have dev kit after removing symlink");

	# Extract the other kit version (1.0.0 classic) into a literal dev directory
	my $classic_kit_path = $top->path(".genesis/kits/bosh-1.0.0.tar.gz");
	ok(-f $classic_kit_path, "bosh-1.0.0 kit archive exists");

	# Use Genesis::Commands::Kit::_decompile_kit to properly extract to dev directory
	my $dev_dir = $top->path('dev');
	Genesis::Commands::Kit::_decompile_kit($top, $classic_kit_path, $dev_dir);
	ok(-d $dev_dir, "dev directory exists as literal directory");
	ok(!(-l $dev_dir), "dev is not a symlink");
	ok(-f "$dev_dir/kit.yml", "dev directory contains kit.yml");
	ok($top->has_dev_kit(), "repo has dev kit with literal directory");

	# Load the same environment file again - should work with literal dev directory
	my $env_dev2 = $top->load_env('test-dev');
	ok($env_dev2, "load_env() works with literal dev directory");
	ok($env_dev2->kit, "environment loaded with literal dev kit has kit object");
	is($env_dev2->kit->id, 'bosh/1.0.0 (dev)', "literal dev kit id is 'bosh/1.0.0 (dev)' with classic kit");
};

subtest 'manage secrets provider' => sub {
	plan tests => 34;

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
secrets_provider:
  url: $VAULT_URL{$vault_target}
  insecure: false
  strongbox: false
  namespace: ""
  alias: $vault_target
updater_version: 99.99.99
version: 2
EOF
	cmp_deeply($top->config->_explicit_contents, {
			"deployment_type" => "test",
			"creator_version" => "99.99.99",
			"updater_version" => "99.99.99",
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
	isnt($top->config->_explicit_contents, undef, "top doesn't clears its configuration after setting a temporary vault");
	is($top->vault->{name}, $other_vault_name, "top targets the expected vault");
	yaml_is(get_file("$tmp/.genesis/config"), <<EOF, ".genesis/config contains the correct information");
---
creator_version: 99.99.99
deployment_type: test
secrets_provider:
  url: $VAULT_URL{$vault_target}
  insecure: false
  strongbox: false
  namespace: ""
  alias: $vault_target
updater_version: 99.99.99
version: 2
EOF
	cmp_deeply($top->config->_explicit_contents, {
			"deployment_type" => "test",
			"creator_version" => "99.99.99",
			"updater_version" => "99.99.99",
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
secrets_provider:
  url: $VAULT_URL{$other_vault_name}
  insecure: false
  strongbox: false
  namespace: ""
  alias: $other_vault_name
updater_version: 99.99.99
version: 2
EOF
	cmp_deeply($top->config->_explicit_contents, {
			"deployment_type" => "test",
			"creator_version" => "99.99.99",
			"updater_version" => "99.99.99",
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
	lives_ok {$new_top = Genesis::Top->new($tmp, vault => $vault_target)} "allows vault to be overridden when present in config";
	is(ref($new_top->vault), "Service::Vault::Remote", "Top vault is a vault object");
	is($new_top->vault->{url}, $VAULT_URL{$vault_target}, "Other vault is used by top");
};

teardown_vault();
done_testing;
