#!/usr/bin/env perl
# How `genesis new` picks the vault for a new environment, and what it
# records in .genesis/config.  create() is run for real, with a stub kit,
# through Genesis::Env::create's handling of the vault, and stopped where
# that first asks the environment for its kit, so the vault the new
# environment file would record can be checked too.
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Output;
use Cwd ();

use Genesis qw/mkfile_or_fail/;
use_ok 'Genesis::Commands::Env';
use_ok 'Genesis::Top';
use_ok 'Service::Vault::Remote';
use_ok 'Service::Vault::Local';

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $STOP = "stopped once the environment parameters were set\n";

sub target {
	my (%args) = @_;
	return {
		name      => $args{name}      // 'ops',
		url       => $args{url}       // 'https://vault.example.com',
		verify    => $args{verify}    // JSON::PP::true,
		namespace => $args{namespace} // '',
		mount     => '/secret/',
	};
}

# A deployment repository, with or without a recorded secrets provider.
sub repo {
	my (%provider) = @_;
	my $tmp = workdir('repo-'.int(rand(1_000_000)));
	system("mkdir -p $tmp/.genesis");
	my $config = "---\nversion: 2\ncreator_version: 3.1.0\ndeployment_type: test\n";
	if (%provider) {
		$config .= "secrets_provider:\n";
		$config .= "  $_: $provider{$_}\n" for sort keys %provider;
	}
	mkfile_or_fail("$tmp/.genesis/config", $config);
	return $tmp;
}

# Run create for env 'child' in $repo with the given options, against the
# given safe targets.  Returns the death, the combined output, the vault
# the repository is left using for the rest of the command, and the
# genesis.vault the new environment would record.
sub create_in {
	my ($repo, $options, $targets, %stub) = @_;
	local @ENV{keys %{$stub{env} // {}}} = values %{$stub{env} // {}};

	my $home = workdir('home-'.int(rand(1_000_000)));
	local $ENV{HOME} = $home;
	local $ENV{GENESIS_TRACE};
	local @ENV{qw/VAULT_ROLE_ID VAULT_SECRET_ID VAULT_AUTH_TOKEN
	              VAULT_USERNAME VAULT_PASSWORD VAULT_GITHUB_TOKEN/};
	open my $fh, '>', "$home/.saferc" or die "cannot write test .saferc: $!";
	print $fh "version: 1\nvaults: {}\n";
	close $fh;

	my ($top, $recorded);
	my $kit = mock 'Mock::CreateVault::Kit' => {id => 'test/1.0.0', check_prereqs => 1};
	no warnings qw/redefine once/;
	# `safe targets` lists the targets; `safe target` names no default.
	local *Service::Vault::run = sub {(join(' ', grep {!ref} @_), 0, '')};
	local *Service::Vault::read_json_from = sub {$_[0] =~ /targets/ ? $targets : {name => ''}};
	local *Service::Vault::Local::valid_local_vault = sub {0};
	local *Service::Vault::Remote::connect_and_validate = sub {$_[0]};
	local *Genesis::Top::get_ancestral_vault = sub {$stub{ancestral}};
	local *Genesis::Top::local_kit_version = sub {$top = $_[0]; $kit};
	local *Genesis::Env::new = sub {
		my ($class, %opts) = @_;
		return bless({%opts, file => "$opts{name}.yml"}, $class);
	};
	local *Genesis::Env::kit = sub {$recorded = $_[0]->{__params}{genesis}{vault}; die $STOP};
	use warnings 'redefine';
	local $Genesis::Commands::COMMAND_OPTIONS = {%$options};

	my $cwd = Cwd::getcwd();
	chdir $repo or die "cannot chdir to $repo: $!";
	Service::Vault->clear_all;
	my $err;
	my ($out, $errout) = output_from {
		eval {Genesis::Commands::Env::create('child'); 1} or $err = $@;
	};
	chdir $cwd;
	my $vault = $top && $top->{__vault};
	Service::Vault->clear_all;
	return ($err // '', $out.$errout, $vault, $recorded);
}

sub provider {
	my ($repo) = @_;
	return Genesis::Config->new("$repo/.genesis/config")->get('secrets_provider');
}

subtest 'a bare target name is accepted by --vault' => sub {
	plan tests => 4;

	my $repo = repo();
	my ($err, $out, $vault) = create_in($repo, {vault => 'ops'}, [target()]);
	like($err, qr/^\Q$STOP\E/, 'reaches the environment parameters');
	unlike($err.$out, qr/Unknown clause/, 'is not read as a descriptor clause');
	is($vault && $vault->name, 'ops', 'uses the named target');
	is((provider($repo) // {})->{url}, 'https://vault.example.com',
		'records it for a repository that had no secrets provider');
};

subtest 'an unknown target name says so' => sub {
	plan tests => 3;

	my $repo = repo();
	my ($err, $out) = create_in($repo, {vault => 'nosuch'}, [target()]);
	like($err.$out, qr/Safe target 'nosuch' .*not found/, 'names the missing target');
	unlike($err.$out, qr/Unknown clause/, 'is not read as a descriptor clause');
	ok(!defined(provider($repo)), 'records nothing');
};

subtest "an ancestor's genesis.vault still has to be a descriptor" => sub {
	plan tests => 2;

	my $repo = repo();
	my ($err, $out) = create_in($repo, {}, [target()], ancestral => 'ops');
	like($err.$out, qr/Unknown clause in genesis\.vault: 'ops'/,
		'a bare name inherited from an ancestor is an unknown clause');
	ok(!defined(provider($repo)), 'records nothing');
};

subtest 'the new environment records the vault that was resolved' => sub {
	plan tests => 6;

	my ($err, $out, $vault, $recorded) = create_in(repo(), {vault => '  ops '}, [target()]);
	like($err, qr/^\Q$STOP\E/, 'a name with surrounding whitespace gets through');
	is($recorded, 'https://vault.example.com as ops',
		'a name is recorded as its target\'s descriptor');

	($err, $out, $vault, $recorded) = create_in(repo(),
		{vault => 'https://vault.example.com as ops strongbox'}, [target()]);
	like($err, qr/^\Q$STOP\E/, 'a descriptor gets through');
	is($recorded, 'https://vault.example.com as ops strongbox',
		'a descriptor is recorded as it was given');

	($err, $out, $vault, $recorded) = create_in(repo(), {vault => 'nosuch'}, [target()]);
	like($err.$out, qr/Safe target 'nosuch' .*not found/, 'an unknown name stops');
	ok(!defined($recorded), 'before anything is recorded');
};

subtest "a target named '0' is a target name like any other" => sub {
	plan tests => 4;

	my $repo = repo();
	my ($err, $out, $vault, $recorded) = create_in($repo, {vault => '0'},
		[target(), target(name => '0', url => 'https://zero.example.com')],
		ancestral => 'https://vault.example.com as ops');
	like($err, qr/^\Q$STOP\E/, 'reaches the environment parameters');
	is($vault && $vault->name, '0', "uses target '0', not the ancestor's vault");
	is($recorded, 'https://zero.example.com as 0', 'and records it for the environment');
	is((provider($repo) // {})->{alias}, '0', 'and for the repository, which had none');
};

subtest 'a name the descriptor cannot carry is recorded without its alias' => sub {
	plan tests => 3;

	my ($err, $out, $vault, $recorded) = create_in(repo(), {vault => '$PICK'},
		[target(name => '$PICK'), target(name => 'beta', url => 'https://beta.example.com')],
		env => {PICK => 'beta'});
	like($err, qr/^\Q$STOP\E/, 'reaches the environment parameters');
	is($vault && $vault->name, '$PICK', 'uses the target named $PICK');
	is($recorded, 'https://vault.example.com',
		'records its URL, which only it has, rather than an alias read as a variable');
};

subtest 'a name whose URL another target shares stops before anything is written' => sub {
	plan tests => 3;

	my $repo = repo();
	my ($err, $out, $vault, $recorded) = create_in($repo, {vault => 'beta'},
		[target(name => 'alpha'), target(name => 'beta')]);
	like($err.$out, qr/shares its URL https:\/\/vault\.example\.com with alpha/, 'says why');
	ok(!defined(provider($repo)), 'records nothing for the repository');
	ok(!defined($recorded), 'or for the environment');
};

done_testing;
