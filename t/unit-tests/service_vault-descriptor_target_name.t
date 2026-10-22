#!/usr/bin/env perl
# `genesis new --vault` is documented as taking the name of a safe target,
# but the resolver only understood descriptors, so a bare name died as an
# "Unknown clause".  A caller that accepts names now says so, and a single
# token with no URL scheme is then looked up as a target name.  Everything
# else is still a descriptor, and genesis.vault, which must stay portable
# between machines, still accepts descriptors alone.
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

# Resolve against fixed `safe targets --json` output and an empty
# ~/.saferc, capturing the result, any death, and any warnings.
sub resolve {
	my ($descriptor, $targets, %opts) = @_;

	my $home = workdir('home-'.int(rand(1_000_000)));
	local $ENV{HOME} = $home;
	# parse_vault_descriptor turns tracing on before it bails.
	local $ENV{GENESIS_TRACE};
	local @ENV{qw/VAULT_ROLE_ID VAULT_SECRET_ID VAULT_AUTH_TOKEN
	              VAULT_USERNAME VAULT_PASSWORD VAULT_GITHUB_TOKEN/};
	open my $fh, '>', "$home/.saferc" or die "cannot write test .saferc: $!";
	print $fh "version: 1\nvaults: {}\n";
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
	my $vault = eval {
		my $found = Service::Vault->get_vault_from_descriptor($descriptor, '--vault option', %opts);
		# What the new environment would record, read back as genesis.vault is.
		$found = Service::Vault->get_vault_from_descriptor($found->build_descriptor)
			if $opts{round_trip};
		$found;
	};
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
		mount     => '/secret/',
	};
}

sub names_ok {
	my ($name, $input, $targets, $label) = @_;
	my ($vault, $err, $warnings) = resolve($input, $targets, target_name => 1);
	subtest $label => sub {
		plan tests => 3;
		is($err, '', 'does not die');
		is(ref($vault) && $vault->name, $name, "resolves to target '$name'");
		is_deeply($warnings, [], 'emits no warnings');
	};
}

subtest 'a bare target name resolves to that target' => sub {
	plan tests => 2;

	names_ok('ops', 'ops', [target()], 'plain name');
	names_ok('dev', 'dev',
		[target(), target(name => 'dev', url => 'http://10.0.0.1:8200', verify => JSON::PP::false)],
		'name of an http target among others');
};

subtest 'a name whose URL another target shares is refused' => sub {
	plan tests => 6;

	# safe resolves a target given by URL only when one target has it, and
	# Genesis hands vaults to safe and to hooks by URL.
	for my $twin (target(name => 'alpha'), target(name => 'alpha', namespace => 'team1')) {
		my ($vault, $err) = resolve('beta', [$twin, target(name => 'beta')], target_name => 1);
		ok(!defined($vault), 'returns nothing');
		like($err, qr/Safe target 'beta' shares its URL https:\/\/vault\.example\.com with alpha/,
			'names the target, the URL, and the other target');
		like($err, qr/one safe target per URL/, 'says what Genesis needs');
	}
};

subtest 'names that look like parts of a descriptor are still names' => sub {
	plan tests => 5;

	names_ok('lab:ops', 'lab:ops', [target(name => 'lab:ops')], 'a colon');
	names_ok('lab/ops', 'lab/ops', [target(name => 'lab/ops')], 'a slash');
	names_ok('verify', 'verify', [target(name => 'verify')], 'the verify keyword');
	names_ok('no-strongbox', 'no-strongbox', [target(name => 'no-strongbox')],
		'the no-strongbox keyword');
	names_ok('ops', '  ops ', [target()], 'surrounding whitespace');
};

subtest 'an unknown name bails with the name, not as a clause' => sub {
	plan tests => 4;

	my ($vault, $err) = resolve('nosuch', [target()], target_name => 1);
	ok(!defined($vault), 'returns nothing');
	like($err, qr/Safe target 'nosuch' .*not found/, 'names the missing target');
	like($err, qr/--vault option/, 'names where the name came from');
	unlike($err, qr/Unknown clause/, 'is not reported as a descriptor clause');
};

subtest 'an unknown keyword-shaped name says a descriptor needs a URL' => sub {
	plan tests => 2;

	my ($vault, $err) = resolve('no-verify', [target()], target_name => 1);
	like($err, qr/Safe target 'no-verify' .*not found/, 'names the missing target');
	like($err, qr/is also a descriptor clause, but a descriptor needs a URL/, 'explains the keyword reading');
};

subtest 'descriptors are unchanged when names are accepted' => sub {
	plan tests => 5;

	names_ok('ops', 'https://vault.example.com as ops', [target()], 'URL and alias');
	names_ok('ops', 'https://vault.example.com', [target()], 'URL alone');

	my ($vault, $err) = resolve('HTTPS://vault.example.com', [target()], target_name => 1);
	like($err, qr/Unknown clause in --vault option: 'HTTPS:\/\/vault\.example\.com'/,
		'a token with any URL scheme is parsed as a descriptor');

	($vault, $err) = resolve('ops as ops', [target()], target_name => 1);
	like($err, qr/Unknown clause in --vault option: 'ops'/,
		'more than one token is parsed as a descriptor');

	($vault, $err) = resolve('ops no-verify', [target()], target_name => 1);
	like($err, qr/Unknown clause in --vault option: 'ops'/,
		'a name with clauses is parsed as a descriptor');
};

subtest 'callers that do not accept names still get the descriptor errors' => sub {
	plan tests => 2;

	my ($vault, $err) = resolve('ops', [target()]);
	like($err, qr/Unknown clause in --vault option: 'ops'/,
		'a bare name is an unknown clause');

	($vault, $err) = resolve('verify', [target(name => 'verify')]);
	like($err, qr/Missing connect clause in --vault option/,
		'a lone keyword is a descriptor with no URL');
};

subtest 'a name is taken literally, never as an environment variable' => sub {
	plan tests => 2;

	local $ENV{PICK} = 'beta';
	names_ok('$PICK', '$PICK',
		[target(name => '$PICK'), target(name => 'beta', url => 'https://beta.example.com')],
		'a name starting with $');
	names_ok('0', '0', [target(), target(name => '0', url => 'https://zero.example.com')],
		"a name Perl would read as false");
};

subtest 'the descriptor recorded for a target resolves back to it' => sub {
	plan tests => 4;

	local $ENV{PICK} = 'beta';
	my @others = (target(name => 'beta', url => 'https://beta.example.com'));
	for my $name ('ops', '$PICK', 'lab:ops', '0') {
		my ($vault, $err) = resolve($name, [target(name => $name), @others],
			target_name => 1, round_trip => 1);
		is(ref($vault) && $vault->name, $name, "'$name' comes back as itself")
			or diag $err;
	}
};

subtest 'build_descriptor leaves out an alias it cannot write literally' => sub {
	plan tests => 4;

	local $ENV{GENESIS_TRACE};
	my $vault = sub {Service::Vault::Remote->new('https://vault.example.com', $_[0], 1, '', undef, '/secret/')};
	is($vault->('ops')->build_descriptor, 'https://vault.example.com as ops', 'a plain name');
	is($vault->('$PICK')->build_descriptor, 'https://vault.example.com',
		'a leading $, which attach would read as an environment variable');
	is($vault->('ops west')->build_descriptor, 'https://vault.example.com',
		'whitespace, which ends the alias early');
	is(Service::Vault->parse_vault_descriptor($vault->('ops west')->build_descriptor)->{url},
		'https://vault.example.com', 'and what is left still parses');
};

done_testing;
