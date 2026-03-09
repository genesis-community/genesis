#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;
use Cwd qw/abs_path/;

use_ok "Service::BOSH::Director";
use_ok 'Genesis::Config';
$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");

use Genesis;
use Genesis::Top;
use Genesis::Env;
use Service::Vault;

# Integration tests for Service::BOSH::Director constructor patterns
# These tests require a real vault instance via vault_ok()

$ENV{GENESIS_CALLBACK_BIN} ||= abs_path('bin/genesis');
$ENV{GENESIS_LIB} ||= abs_path('lib');

# Set version to avoid "(development)" version issues in tests
local $Genesis::VERSION = '3.1.0';

fake_bosh('');
my $vault_target = vault_ok();

subtest 'Director constructor from_exodus with vault' => sub {
	plan tests => 11;

	Service::Vault->clear_all();

	# Create a test environment
	my $top = Genesis::Top->create(workdir, 'bosh-test', vault => $VAULT_URL);
	$top->link_dev_kit('t/src/simple');

	put_file $top->path("proto.yml"), <<'EOF';
---
kit:
  name: dev
  version: latest
  features: []

params:
  env: proto
EOF

	my $env = $top->load_env('proto');

	# Populate exodus data in vault for a BOSH director
	my $exodus_path = 'secret/exodus/proto/bosh';
	my $vault = Service::Vault->current;
	$vault->set_path($exodus_path, {
		url => 'https://10.128.4.4:25555',
		admin_username => 'admin',
		admin_password => 'test-password',
		ca_cert => "-----BEGIN CERTIFICATE-----\nfake-cert\n-----END CERTIFICATE-----",
		kit_name => 'bosh',
		is_director => 1,
	});

	# Test from_exodus() constructor
	my $bosh = Service::BOSH::Director->from_exodus('proto', $env,
		exodus_path => $exodus_path,
		exodus_vault => $vault
	);

	isa_ok($bosh, 'Service::BOSH::Director', 'from_exodus() creates Director');
	is($bosh->alias, 'proto', 'from_exodus() sets correct alias');
	is($bosh->url, 'https://10.128.4.4:25555', 'from_exodus() loads URL from exodus');
	is($bosh->{client}, 'admin', 'from_exodus() loads admin username');
	is($bosh->{secret}, 'test-password', 'from_exodus() loads admin password');
	is($bosh->exodus_path, $exodus_path, 'from_exodus() sets exodus_path');

	# Test vault accessors
	isa_ok($bosh->vault, 'Service::Vault', 'vault() returns Service::Vault object');
	isa_ok($bosh->exodus_vault, 'Service::Vault', 'exodus_vault() returns Service::Vault object');
	is($bosh->vault, $bosh->exodus_vault, 'vault() and exodus_vault() return same object');

	# Test env accessor
	is($bosh->env, $env, 'env() returns the Genesis::Env object');

	# Test has_director() with actual director object
	ok($bosh->has_director(), 'has_director() returns true for Director instance');

};

subtest 'Director constructor from_exodus with missing exodus data' => sub {
	plan tests => 1;

	Service::Vault->clear_all();

	my $top = Genesis::Top->create(workdir, 'bosh-test2', vault => $VAULT_URL);
	$top->link_dev_kit('t/src/simple');

	put_file $top->path("test.yml"), <<'EOF';
---
kit:
  name: dev
  version: latest
  features: []

params:
  env: test
EOF

	my $env = $top->load_env('test');
	my $vault = Service::Vault->current;

	# Don't populate exodus data - test should return undef
	my $bosh = Service::BOSH::Director->from_exodus('test', $env,
		exodus_path => 'secret/exodus/test/bosh',
		exodus_vault => $vault
	);

	is($bosh, undef, 'from_exodus() returns undef when no exodus data found');

};

subtest 'Director constructor from_exodus with invalid exodus data' => sub {
	plan tests => 2;

	Service::Vault->clear_all();

	my $top = Genesis::Top->create(workdir, 'bosh-test3', vault => $VAULT_URL);
	$top->link_dev_kit('t/src/simple');

	put_file $top->path("invalid.yml"), <<'EOF';
---
kit:
  name: dev
  version: latest
  features: []

params:
  env: invalid
EOF

	my $env = $top->load_env('invalid');
	my $vault = Service::Vault->current;

	# Test with missing required keys
	my $exodus_path = 'secret/exodus/invalid/bosh';
	$vault->set_path($exodus_path, {
		url => 'https://10.128.4.5:25555',
		# Missing: admin_username, admin_password, ca_cert, kit_name
	});

	my $bosh = Service::BOSH::Director->from_exodus('invalid', $env,
		exodus_path => $exodus_path,
		exodus_vault => $vault
	);

	is($bosh, undef, 'from_exodus() returns undef when exodus data missing required keys');

	# Test with wrong kit type
	$vault->set_path($exodus_path, {
		url => 'https://10.128.4.5:25555',
		admin_username => 'admin',
		admin_password => 'password',
		ca_cert => 'cert',
		kit_name => 'vault',  # Wrong kit type
	});

	$bosh = Service::BOSH::Director->from_exodus('invalid', $env,
		exodus_path => $exodus_path,
		exodus_vault => $vault
	);

	is($bosh, undef, 'from_exodus() returns undef when exodus data is not for BOSH');

};
teardown_vault($vault_target);

subtest 'Director constructor from_alias with BOSH config' => sub {
	plan tests => 5;

	# Create a test environment
	my $top = Genesis::Top->create(workdir, 'bosh-test4', vault => $VAULT_URL);
	$top->link_dev_kit('t/src/simple');

	put_file $top->path("alias-test.yml"), <<'EOF';
---
kit:
  name: dev
  version: latest
  features: []

params:
  env: alias-test
EOF

	my $env = $top->load_env('alias-test');

	# Create a temporary BOSH config file
	my $tmp = workdir;
	my $config_file = "$tmp/bosh-config";
	put_file($config_file, <<'EOF');
---
environments:
- alias: my-bosh
  url: https://192.168.50.6:25555
  ca_cert: |
    -----BEGIN CERTIFICATE-----
    fake-cert-data
    -----END CERTIFICATE-----
- alias: other-bosh
  url: https://10.10.10.10:25555
  ca_cert: other-cert
EOF

	# Test successful alias lookup
	my $bosh = Service::BOSH::Director->from_alias('my-bosh', $env, config_home => $config_file);
	isa_ok($bosh, 'Service::BOSH::Director', 'from_alias() creates Director for valid alias');
	is($bosh->url, 'https://192.168.50.6:25555', 'from_alias() sets correct URL');
	is($bosh->alias, 'my-bosh', 'from_alias() sets correct alias');
	ok($bosh->{use_local_config}, 'from_alias() sets use_local_config flag');

	# Test non-existent alias
	my $not_found = Service::BOSH::Director->from_alias('nonexistent', $env, config_home => $config_file);
	is($not_found, undef, 'from_alias() returns undef for non-existent alias');
};

subtest 'Director constructor from_environment' => sub {
	plan tests => 6;

	# Test construction from environment variables (URL-based)
	local %ENV;
	$ENV{BOSH_ENVIRONMENT} = 'https://10.0.0.5:25555';
	$ENV{BOSH_CLIENT} = 'test-client';
	$ENV{BOSH_CLIENT_SECRET} = 'test-secret';
	$ENV{BOSH_CA_CERT} = 'test-ca-cert';
	$ENV{BOSH_DEPLOYMENT} = 'test-dep';
	$ENV{BOSH_ALIAS} = 'env-director';

	my $bosh = Service::BOSH::Director->from_environment();
	isa_ok($bosh, 'Service::BOSH::Director', 'from_environment() with URL creates Director');
	is($bosh->url, 'https://10.0.0.5:25555', 'from_environment() sets correct URL');
	is($bosh->alias, 'env-director', 'from_environment() sets alias from BOSH_ALIAS');
	is($bosh->{client}, 'test-client', 'from_environment() sets client');
	is($bosh->{secret}, 'test-secret', 'from_environment() sets secret');
	is($bosh->deployment, 'test-dep', 'from_environment() sets deployment');
};

done_testing;
