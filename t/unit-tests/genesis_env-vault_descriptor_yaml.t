#!/usr/bin/env perl
# A new environment's genesis.vault is written into its YAML by one of two
# helpers: Genesis::Env->genesis_config_block, or the bash
# genesis_config_block that kit `new` hooks call.  A descriptor built for a
# safe target carries the target's name as its alias, and a name such as
# '#ops' or 'ops:' is not safe as a plain YAML scalar, so the file must
# still read back as the descriptor that was written, and that descriptor
# must still resolve to the target.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::More;

use Genesis qw/load_yaml/;
use_ok 'Genesis::Env';
use_ok 'Genesis::Helpers';
use_ok 'Service::Vault::Remote';
use_ok 'Service::Vault::Local';

$ENV{GENESIS_OUTPUT_COLUMNS} = 200;
$ENV{NOCOLOR} = 1;

my $URL = 'https://vault.example.com';

sub target {
	my ($name) = @_;
	return {name => $name, url => $URL, verify => JSON::PP::true, namespace => '', mount => '/secret/'};
}

sub descriptor_for {
	my ($name) = @_;
	local $ENV{GENESIS_TRACE};
	return Service::Vault::Remote->new($URL, $name, 1, '', undef, '/secret/')->build_descriptor;
}

# The block Genesis::Env writes, for an environment with nothing else set.
sub perl_block {
	my ($descriptor) = @_;
	my $env = bless({name => 'child'}, 'Genesis::Env');
	no warnings qw/redefine once/;
	local *Genesis::Env::bosh_env       = sub {{description => ''}};
	local *Genesis::Env::use_create_env = sub {0};
	local *Genesis::Env::root_ca_path   = sub {''};
	local *Genesis::Env::lookup = sub {
		my ($self, $key, $default) = @_;
		return $key eq 'genesis.vault' ? $descriptor : $default;
	};
	for my $where (qw/secrets_slug secrets_mount exodus_mount ci_mount/) {
		no strict 'refs';
		*{"Genesis::Env::$where"}           = sub {$where};
		*{"Genesis::Env::default_$where"}   = sub {$where};
	}
	return $env->genesis_config_block;
}

# The block a kit's `new` hook writes with the bash helper.
my $helpers = workdir('helpers').'/helpers.sh';
Genesis::Helpers->write($helpers);
sub bash_block {
	my ($descriptor) = @_;
	local $ENV{GENESIS_ENVIRONMENT} = 'child';
	local $ENV{GENESIS_ENV_VAULT_DESCRIPTOR} = $descriptor;
	local @ENV{qw/GENESIS_USE_CREATE_ENV BOSH_ALIAS GENESIS_MIN_VERSION
	              GENESIS_SECRETS_SLUG_OVERRIDE GENESIS_SECRETS_MOUNT_OVERRIDE
	              GENESIS_EXODUS_MOUNT_OVERRIDE GENESIS_CI_MOUNT_OVERRIDE
	              GENESIS_ROOT_CA_PATH GENESIS_CREDHUB_EXODUS_SOURCE_OVERRIDE/};
	open my $fh, '-|', 'bash', '-c',
		'source "$1"; use_create_env() { return 1; }; genesis_config_block', '_', $helpers
		or die "cannot run bash: $!";
	my $block = do {local $/; <$fh>};
	close $fh;
	return $block;
}

# What genesis.vault resolves to when the environment is read back.
sub resolve {
	my ($descriptor, $name) = @_;
	my $home = workdir('home-'.int(rand(1_000_000)));
	local $ENV{HOME} = $home;
	local $ENV{GENESIS_TRACE};
	local @ENV{qw/VAULT_ROLE_ID VAULT_SECRET_ID VAULT_AUTH_TOKEN
	              VAULT_USERNAME VAULT_PASSWORD VAULT_GITHUB_TOKEN/};
	open my $fh, '>', "$home/.saferc" or die "cannot write test .saferc: $!";
	print $fh "version: 1\nvaults: {}\n";
	close $fh;

	no warnings qw/redefine once/;
	local *Service::Vault::read_json_from = sub {[target($name)]};
	local *Service::Vault::run = sub {('', 0, '')};
	local *Service::Vault::Local::valid_local_vault = sub {0};
	local *Service::Vault::Remote::connect_and_validate = sub {$_[0]};
	use warnings 'redefine';

	Service::Vault->clear_all;
	my $vault = eval {Service::Vault->get_vault_from_descriptor($descriptor)};
	my $err = $@;
	Service::Vault->clear_all;
	return ($vault, $err);
}

for my $writer (['Genesis::Env' => \&perl_block], ['the bash helper' => \&bash_block]) {
	my ($label, $write) = @$writer;
	subtest "the vault $label writes reads back as the target it names" => sub {
		for my $name ('ops', '#ops', 'ops:', 'ops #west', "o'ps", 'o"ps', 'o\\ps', '$PICK') {
			my $descriptor = descriptor_for($name);
			my $block = $write->($descriptor);
			my $yaml = load_yaml("---\n$block");
			is(ref($yaml) && $yaml->{genesis}{vault}, $descriptor,
				"'$name' is written as its descriptor, '$descriptor'")
				or diag $block;
			my ($vault, $err) = resolve($yaml && $yaml->{genesis}{vault}, $name);
			is(ref($vault) && $vault->name, $name, "and resolves back to '$name'")
				or diag $err;
		}
	};

	subtest "$label writes an ordinary descriptor as it always has" => sub {
		plan tests => 1;
		like($write->(descriptor_for('ops')), qr{^  vault: +\Qhttps://vault.example.com as ops\E$}m,
			'unquoted');
	};
}

done_testing;
