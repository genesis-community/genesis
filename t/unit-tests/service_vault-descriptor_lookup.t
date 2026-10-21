#!/usr/bin/env perl
# A vault descriptor must resolve the same target whichever command reads it.
#
# `genesis new --vault` resolved its descriptor through
# get_vault_from_descriptor, which turned every parsed field into an exact
# match against `safe targets`.  The environment file resolves the same
# descriptor through Service::Vault::Remote->attach, which compares verify
# only for TLS, namespace as stated, and never strongbox.  So a descriptor
# that worked in genesis.vault found nothing on the command line, and the
# undef it returned reached Genesis::Top->set_vault as a Genesis bug.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::More;

use_ok 'Service::Vault';
use_ok 'Service::Vault::Remote';
use_ok 'Service::Vault::Local';

$ENV{GENESIS_OUTPUT_COLUMNS} = 200;
$ENV{NOCOLOR} = 1;

# Resolve a descriptor against fixed `safe targets --json` output and a
# matching ~/.saferc, capturing the result, any death, and any warnings.
sub resolve {
	my ($descriptor, $targets, $rc_vaults) = @_;

	my $home = workdir('home-'.int(rand(1_000_000)));
	local $ENV{HOME} = $home;
	local @ENV{qw/VAULT_ROLE_ID VAULT_SECRET_ID VAULT_AUTH_TOKEN
	              VAULT_USERNAME VAULT_PASSWORD VAULT_GITHUB_TOKEN/};
	open my $fh, '>', "$home/.saferc" or die "cannot write test .saferc: $!";
	print $fh "version: 1\nvaults:\n";
	for my $name (sort keys %$rc_vaults) {
		print $fh "  $name:\n";
		print $fh "    $_: $rc_vaults->{$name}{$_}\n" for sort keys %{$rc_vaults->{$name}};
	}
	close $fh;

	no warnings qw/redefine once/;
	local *Service::Vault::read_json_from = sub {$targets};
	local *Service::Vault::run = sub {('', 0, '')};
	local *Service::Vault::Local::valid_local_vault = sub {0};
	local *Service::Vault::Remote::connect_and_validate = sub {$_[0]};
	use warnings 'redefine';

	Service::Vault->clear_all;
	my @warnings;
	local $SIG{__WARN__} = sub {push @warnings, @_};
	my $vault = eval {Service::Vault->get_vault_from_descriptor($descriptor, '--vault option')};
	my $err = $@;
	Service::Vault->clear_all;
	return ($vault, $err, \@warnings);
}

sub target {
	my (%args) = @_;
	return {
		name      => $args{name}      // 'ops',
		url       => $args{url}       // 'https://vault.example.com',
		verify    => $args{verify}    // JSON::PP::true,
		namespace => $args{namespace} // '',
		strongbox => $args{strongbox} // JSON::PP::false,
		mount     => '/secret/',
	};
}

sub resolves_to {
	my ($name, $descriptor, $targets, $rc, $label) = @_;
	my ($vault, $err, $warnings) = resolve($descriptor, $targets, $rc);
	subtest $label => sub {
		plan tests => 3;
		is($err, '', 'does not die');
		is(ref($vault) && $vault->name, $name, "resolves to target '$name'");
		is_deeply($warnings, [], 'emits no warnings');
	};
}

subtest 'the descriptor from the report resolves its target' => sub {
	plan tests => 1;

	# safe v1.20.0+ omits strongbox from ~/.saferc when it is off, so the
	# target states nothing while the descriptor states no-strongbox.
	resolves_to('ocfp-lab-wayneeseguin-mgmt',
		'https://10.108.20.5 as ocfp-lab-wayneeseguin-mgmt no-verify no-strongbox',
		[target(name => 'ocfp-lab-wayneeseguin-mgmt', url => 'https://10.108.20.5',
		        verify => JSON::PP::false)],
		{'ocfp-lab-wayneeseguin-mgmt' => {url => 'https://10.108.20.5', skip_verify => 'true'}},
		'no-strongbox against a target that never stated strongbox');
};

subtest 'strongbox never excludes a target' => sub {
	plan tests => 2;

	resolves_to('ops', 'https://vault.example.com as ops strongbox',
		[target()], {ops => {url => 'https://vault.example.com'}},
		'strongbox clause, target silent');

	resolves_to('ops', 'https://vault.example.com as ops',
		[target(strongbox => JSON::PP::true)],
		{ops => {url => 'https://vault.example.com', strongbox => 'true'}},
		'no strongbox clause, target states strongbox: true');
};

subtest 'verify defaults resolve the targets they describe' => sub {
	plan tests => 2;

	# build_descriptor writes no verify clause for a verified TLS target, so
	# this is also the shape every ancestor env file carries.
	resolves_to('ops', 'https://vault.example.com as ops',
		[target()], {ops => {url => 'https://vault.example.com'}},
		'https with no verify clause, target verifies');

	resolves_to('dev', 'http://10.0.0.1:8200 as dev',
		[target(name => 'dev', url => 'http://10.0.0.1:8200', verify => JSON::PP::false)],
		{dev => {url => 'http://10.0.0.1:8200'}},
		'http with no verify clause');
};

subtest 'a path after the host is a namespace, port or no port' => sub {
	plan tests => 2;

	resolves_to('ops', 'https://vault.example.com/ as ops',
		[target()], {ops => {url => 'https://vault.example.com'}},
		'trailing slash');

	resolves_to('ops', 'https://vault.example.com/ns1 as ops',
		[target(namespace => 'ns1')],
		{ops => {url => 'https://vault.example.com', namespace => 'ns1'}},
		'namespace without a port');
};

subtest 'a descriptor with no matching target bails readably' => sub {
	plan tests => 3;

	my ($vault, $err) = resolve('https://nowhere.example.com as gone',
		[target()], {ops => {url => 'https://vault.example.com'}});
	ok(!defined($vault), 'returns nothing');
	like($err, qr/nowhere\.example\.com/, 'names the URL it could not find');
	like($err, qr/safe target/i, 'tells the operator how to add a target');
};

done_testing;
