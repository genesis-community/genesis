#!perl
# set_vault(vault => ...) takes what a descriptor lookup resolved, and that
# lookup is driven by whatever the operator typed after --vault.  Anything
# but a remote safe target used to fall through to bug(), which blamed
# Genesis for an operator's descriptor and said nothing about what it was
# given.
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::More;

use Genesis qw/mkfile_or_fail/;

use_ok 'Genesis::Config';
provide_rc();
use_ok 'Genesis::Top';
use_ok 'Service::Vault::Remote';
use_ok 'Service::Vault::Local';

$ENV{GENESIS_OUTPUT_COLUMNS} = 200;
$ENV{NOCOLOR} = 1;

sub repo {
	my $tmp = workdir();
	system("mkdir -p $tmp/.genesis");
	mkfile_or_fail("$tmp/.genesis/config", <<EOF);
---
version: 2
creator_version: 3.1.0
deployment_type: test
secrets_provider:
  url: https://old.example.com
  insecure: true
  namespace: ""
  alias: old-target
EOF
	return Genesis::Top->new($tmp, no_vault => 1);
}

subtest 'an unresolved vault bails instead of reporting a Genesis bug' => sub {
	plan tests => 3;

	my $top = repo();
	my $err;
	quietly { eval { $top->set_vault(vault => undef); 1 } or $err = $@ };
	like($err, qr/Cannot use an unresolved vault as the secrets provider/,
		'the bail says what it was given');
	unlike($err, qr/bug in Genesis/i, 'and does not blame Genesis');
	is($top->config->get('secrets_provider.url'), 'https://old.example.com',
		'the recorded provider is left alone');
};

subtest 'a local vault is named and refused' => sub {
	plan tests => 2;

	my $top = repo();
	my $local = bless(
		Service::Vault->new('http://127.0.0.1:8201', 'local-scratch', 0, '', undef, '/secret/'),
		'Service::Vault::Local'
	);
	my $err;
	quietly { eval { $top->set_vault(vault => $local); 1 } or $err = $@ };
	like($err, qr/vault local-scratch at http:\/\/127\.0\.0\.1:8201/,
		'the bail names the vault it refused');
	like($err, qr/only a remote safe target can be one/,
		'and says what would be accepted');
};

subtest 'a remote vault is still recorded' => sub {
	plan tests => 1;

	my $top = repo();
	$top->set_vault(vault => Service::Vault::Remote->new(
		'https://new.example.com', 'new-target', 1, '', undef, '/secret/'
	));
	is($top->config->get('secrets_provider.url'), 'https://new.example.com',
		'the new url is written');
};

done_testing;
