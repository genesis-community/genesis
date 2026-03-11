#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Test::Deep;
use Test::Exception;

use Genesis;
$Genesis::VERSION = '999.999.999';
use_ok 'Genesis::Config';
$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");

use_ok 'Genesis::Top';
use_ok 'Genesis::Env';

$ENV{GENESIS_OUTPUT_COLUMNS}=80;
$ENV{NOCOLOR}=1;

subtest '_parse_bosh_env - simple name only' => sub {
	plan tests => 5;

	my $top = make_top(name => 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path('us-west-1-preprod.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env:      us-west-1-preprod
  bosh_env: us-west-1-preprod
EOF

	my $env = $top->load_env('us-west-1-preprod');

	# Scalar context returns hashref
	my $data = $env->_parse_bosh_env('us-west-1-preprod');
	isa_ok($data, 'HASH', '_parse_bosh_env in scalar context returns hashref');
	is($data->{name},         'us-west-1-preprod', 'name field parsed correctly');
	is($data->{dep_type},     undef,               'dep_type is undef when absent');
	is($data->{vault_url},    undef,               'vault_url is undef when absent');
	is($data->{exodus_mount}, undef,               'exodus_mount is undef when absent');
};

subtest '_parse_bosh_env - name with type' => sub {
	plan tests => 4;

	my $top = make_top(name => 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path('typed.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env:      typed
  bosh_env: typed
EOF

	my $env = $top->load_env('typed');

	my $data = $env->_parse_bosh_env('us-west-1-preprod/bosh');
	is($data->{name},         'us-west-1-preprod', 'name parsed from name/type descriptor');
	is($data->{dep_type},     'bosh',              'dep_type parsed from name/type descriptor');
	is($data->{vault_url},    undef,               'vault_url absent when not specified');
	is($data->{exodus_mount}, undef,               'exodus_mount absent when not specified');
};

subtest '_parse_bosh_env - full descriptor with URL and mount' => sub {
	plan tests => 5;

	my $top = make_top(name => 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path('full.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env:      full
  bosh_env: full
EOF

	my $env = $top->load_env('full');

	my $data = $env->_parse_bosh_env('us-west-1-preprod/bosh@https://vault.example.com/secret/exodus');
	is($data->{name},         'us-west-1-preprod',       'name parsed from full descriptor');
	is($data->{dep_type},     'bosh',                    'dep_type parsed from full descriptor');
	is($data->{vault_url},    'https://vault.example.com', 'vault_url parsed from full descriptor');
	is($data->{exodus_mount}, 'secret/exodus',           'exodus_mount parsed from full descriptor');
	is($data->{description},  'us-west-1-preprod/bosh@https://vault.example.com/secret/exodus',
		'description echoes original descriptor');
};

subtest '_parse_bosh_env - partial descriptor with mount only (no URL)' => sub {
	plan tests => 4;

	my $top = make_top(name => 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path('partial.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env:      partial
  bosh_env: partial
EOF

	my $env = $top->load_env('partial');

	my $data = $env->_parse_bosh_env('us-west-1-preprod/bosh@/secret/exodus');
	is($data->{name},         'us-west-1-preprod', 'name parsed correctly');
	is($data->{dep_type},     'bosh',              'dep_type parsed correctly');
	is($data->{vault_url},    undef,               'vault_url is undef when omitted before slash');
	is($data->{exodus_mount}, 'secret/exodus',     'exodus_mount parsed when no vault URL');
};

subtest '_parse_bosh_env - list context returns 4-element list' => sub {
	plan tests => 4;

	my $top = make_top(name => 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path('listctx.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env:      listctx
  bosh_env: listctx
EOF

	my $env = $top->load_env('listctx');

	my ($name, $dep_type, $vault_url, $exodus_mount) =
		$env->_parse_bosh_env('us-west-1-preprod/bosh@https://vault.example.com/secret/exodus');

	is($name,         'us-west-1-preprod',         'list context: name');
	is($dep_type,     'bosh',                       'list context: dep_type');
	is($vault_url,    'https://vault.example.com',  'list context: vault_url');
	is($exodus_mount, 'secret/exodus',              'list context: exodus_mount');
};

subtest '_parse_bosh_env - bails on empty or undef input' => sub {
	plan tests => 2;

	my $top = make_top(name => 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path('bail-test.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env:      bail-test
  bosh_env: bail-test
EOF

	my $env = $top->load_env('bail-test');

	throws_ok { $env->_parse_bosh_env('') }
		qr/Undefined BOSH environment description/,
		'_parse_bosh_env bails with empty string';

	throws_ok { $env->_parse_bosh_env(undef) }
		qr/Undefined BOSH environment description/,
		'_parse_bosh_env bails with undef';
};

subtest 'is_bosh_director - true for director kit' => sub {
	plan tests => 1;

	my $top = make_top(name => 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/custom-bosh');

	put_file($top->path('director.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: director
EOF

	my $env = $top->load_env('director');
	ok($env->is_bosh_director,
		'is_bosh_director returns true for kit with director service');
};

subtest 'is_bosh_director - false for non-director kit' => sub {
	plan tests => 1;

	my $top = make_top(name => 'cf', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path('regular.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: regular
EOF

	my $env = $top->load_env('regular');
	ok(!$env->is_bosh_director,
		'is_bosh_director returns false for kit without director service');
};

subtest 'bosh_env - scalar context returns hashref' => sub {
	plan tests => 5;

	my $top = make_top(name => 'cf', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path('us-west-1-preprod.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env:      us-west-1-preprod
  bosh_env: us-west-1-preprod
EOF

	my $env = $top->load_env('us-west-1-preprod');
	my $data = $env->bosh_env;

	isa_ok($data, 'HASH', 'bosh_env in scalar context returns hashref');
	is($data->{name},        'us-west-1-preprod', 'bosh_env hashref has correct name');
	ok(exists $data->{dep_type},     'bosh_env hashref has dep_type key');
	ok(exists $data->{vault_url},    'bosh_env hashref has vault_url key');
	ok(exists $data->{exodus_mount}, 'bosh_env hashref has exodus_mount key');
};

subtest 'bosh_env - list context returns values' => sub {
	plan tests => 5;

	my $top = make_top(name => 'cf', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path('us-west-1-prod.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env:      us-west-1-prod
  bosh_env: us-west-1-prod/bosh
EOF

	my $env = $top->load_env('us-west-1-prod');
	my ($name, $dep_type, $vault_url, $exodus_mount, $description) = $env->bosh_env;

	is($name,        'us-west-1-prod', 'bosh_env list: name');
	is($dep_type,    'bosh',           'bosh_env list: dep_type');
	is($vault_url,   undef,            'bosh_env list: vault_url (undef when absent)');
	is($exodus_mount, undef,           'bosh_env list: exodus_mount (undef when absent)');
	is($description, 'us-west-1-prod/bosh', 'bosh_env list: description echoes original');
};

subtest 'bosh_env - returns empty hashref for create-env environment' => sub {
	plan tests => 2;

	my $top = make_top(name => 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/custom-bosh');

	put_file($top->path('create-env-dir.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: create-env-dir
EOF

	my $env = $top->load_env('create-env-dir');

	# Director kits with no bosh_env return empty hashref (they ARE the director)
	my $data = $env->bosh_env;
	isa_ok($data, 'HASH', 'bosh_env returns hashref even for director env');
	is(scalar keys %$data, 0, 'bosh_env returns empty hashref for director with no bosh_env set');
};

subtest 'bosh_alias - returns name for standard environment' => sub {
	plan tests => 1;

	my $top = make_top(name => 'cf', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path('us-west-1-sandbox.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env:      us-west-1-sandbox
  bosh_env: us-west-1-sandbox
EOF

	my $env = $top->load_env('us-west-1-sandbox');
	is($env->bosh_alias, 'us-west-1-sandbox',
		'bosh_alias returns BOSH director name');
};

subtest 'bosh_alias - returns undef for director (create-env) environment' => sub {
	plan tests => 1;

	my $top = make_top(name => 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/custom-bosh');

	put_file($top->path('proto-bosh.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: proto-bosh
EOF

	my $env = $top->load_env('proto-bosh');
	is($env->bosh_alias, undef,
		'bosh_alias returns undef for director environment with no bosh_env');
};

subtest 'bosh_alias - uses dep_type name from parsed descriptor' => sub {
	plan tests => 1;

	my $top = make_top(name => 'cf', no_vault => 1);
	$top->link_dev_kit('t/src/simple');

	put_file($top->path('us-east-1-prod.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env:      us-east-1-prod
  bosh_env: us-east-1-bosh/bosh
EOF

	my $env = $top->load_env('us-east-1-prod');
	is($env->bosh_alias, 'us-east-1-bosh',
		'bosh_alias returns name portion when bosh_env includes a type');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
