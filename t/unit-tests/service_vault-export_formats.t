#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;

# Every reader of `safe export` output goes through
# Service::Vault::normalize_export, which turns the v1, v2, and v3 export
# formats into the flat v1 shape and refuses any value that is not a
# string.  The fixtures are JSON text decoded the way the readers decode it,
# because a JSON number is told from a JSON string by how it was decoded.

use_ok 'Service::Vault';
use_ok 'Genesis::Env::Secrets::Store::Vault';
use_ok 'Genesis::Commands::Env';
use Genesis qw/load_json/;

# v2 and v3 wrap one export object in an array; the values of v3 keep the
# JSON type they were stored with.
sub versioned {
	my ($version, $data) = @_;
	return sprintf('[{"export_version":%s,"data":%s,"requires_versioning":{}}]', $version, $data);
}

my $V1 = '{"secret/myapp":{"password":"hunter2","port":"8443"},"secret/myapp/db":{"host":"localhost"}}';
my $V2 = versioned(2, '{'.
	'"secret/myapp":{"first":3,"requires_versioning":true,"versions":['.
		'{"value":{"password":"old"}},'.
		'{"value":{"password":"older-deleted"},"deleted":true},'.
		'{"value":{"password":"hunter2","port":"8443"}}]},'.
	'"secret/myapp/db":{"versions":[{"value":{"host":"localhost"}}]},'.
	'"secret/myapp/gone":{"versions":[{"value":{"x":"y"}},{"value":{"x":"z"},"deleted":true}]},'.
	'"secret/myapp/burnt":{"versions":[{"value":{"x":"y"}},{"destroyed":true}]},'.
	'"secret/myapp/empty":{"versions":[{}]},'.
	'"secret/myapp/none":{"versions":[]}'.
'}');
my $V3 = versioned(3, '{'.
	'"secret/myapp":{"versions":[{"value":{"count":42,"flag":true}},{"value":{"password":"hunter2","port":"8443"}}]},'.
	'"secret/myapp/db":{"versions":[{"value":{"host":"localhost"}}]},'.
	'"secret/myapp/gone":{"versions":[{"value":{"x":"y"},"deleted":true}]}'.
'}');
my %WANT = (
	'secret/myapp'       => {password => 'hunter2', port => '8443'},
	'secret/myapp/db'    => {host => 'localhost'},
);

subtest 'normalize_export reads every export version as v1' => sub {
	is_deeply(Service::Vault::normalize_export(load_json($V1)), \%WANT,
		'v1 comes back as it was');
	is_deeply(Service::Vault::normalize_export(load_json($V2)), {%WANT, 'secret/myapp/empty' => {}},
		'v2 gives the newest version of each path, and an empty live version as no keys');
	is_deeply(Service::Vault::normalize_export(load_json($V3)), \%WANT,
		'v3 gives the newest version, and a typed value in an older version does not matter');
	is_deeply(Service::Vault::normalize_export({}), {}, 'an empty export is empty');
	is(Service::Vault::normalize_export(undef), undef, 'no export at all stays undef');
	is_deeply(Service::Vault::normalize_export(load_json('{"secret/myapp":null,"secret/b":{"k":"v"}}')),
		{'secret/b' => {k => 'v'}}, 'a v1 path with no value is left out');
};

subtest 'normalize_export keeps strings that look like other types' => sub {
	my $data = load_json(versioned(3,
		'{"secret/a":{"versions":[{"value":{"n":"42","b":"true","z":"null","o":"{}","e":""}}]}}'));
	is_deeply(Service::Vault::normalize_export($data),
		{'secret/a' => {n => '42', b => 'true', z => 'null', o => '{}', e => ''}},
		'v3 strings come through whatever they spell');
};

subtest 'normalize_export refuses a typed value, naming its path and key' => sub {
	my %typed = (
		'a number'  => ['42',          'number'],
		'a float'   => ['1.5',         'number'],
		'a boolean' => ['true',        'boolean'],
		'a null'    => ['null',        'null'],
		'an object' => ['{"a":"b"}',   'object'],
		'a list'    => ['["a","b"]',   'list'],
	);
	plan tests => 2 * keys(%typed) + 2;
	for my $case (sort keys %typed) {
		my ($json, $type) = @{$typed{$case}};
		my $data = load_json(versioned(3,
			qq({"secret/myapp/db":{"versions":[{"value":{"host":"localhost","port":$json}}]}})));
		throws_ok { Service::Vault::normalize_export($data) }
			qr{secret/myapp/db.*\bport\b.*typed.*JSON\s+$type.*not\s+a\s+string.*Genesis}s,
			"v3 with $case dies naming the path, the key, and the type";
		ok(Service::Vault::is_export_error($@), "and is_export_error knows the $case error");
	}
	throws_ok { Service::Vault::normalize_export(load_json('{"secret/myapp":{"port":8443}}')) }
		qr{secret/myapp.*\bport\b.*typed.*JSON\s+number}s,
		'a typed value in v1 dies as well';
	throws_ok { Service::Vault::normalize_export(load_json(versioned(2,
		'{"secret/myapp":{"versions":[{"value":{"port":8443}}]}}'))) }
		qr{secret/myapp.*\bport\b.*typed.*JSON\s+number}s,
		'and in v2';
};

subtest 'normalize_export refuses a format it does not know' => sub {
	my %bad = (
		'an unknown export_version' => [versioned(4, '{}'),                      qr/export_version\s+4.*1,\s+2,\s+and\s+3/s],
		'no export_version'         => ['[{"data":{}}]',                          qr/export_version\s+\(none\)/s],
		'two exports in the array'  => ['['.versioned(2,'{}').','.versioned(2,'{}').']', qr/one\s+export.*holds\s+2/s],
		'an array of a string'      => ['["nope"]',                               qr/one\s+export/s],
		'a bare string'             => ['"nope"',                                 qr/not\s+an\s+object\s+or\s+an\s+array/s],
		'a v1 path that is a list'  => ['{"secret/a":["x"]}',                     qr{secret/a.*not\s+an\s+object\s+of\s+keys}s],
		'versions that are not a list' => [versioned(2, '{"secret/a":{"versions":{}}}'), qr{secret/a.*versions.*not\s+a\s+list}s],
		'a value that is not an object' => [versioned(3, '{"secret/a":{"versions":[{"value":"x"}]}}'), qr{secret/a.*not\s+an\s+object\s+of\s+keys}s],
	);
	plan tests => 2 * keys %bad;
	for my $case (sort keys %bad) {
		my ($json, $error) = @{$bad{$case}};
		my $data = load_json($json);
		throws_ok { Service::Vault::normalize_export($data) } qr/Cannot\s+use\s+the\s+safe\s+export.*$error/s,
			"$case dies clearly";
		ok(Service::Vault::is_export_error($@), "and is_export_error knows it");
	}
};

subtest 'is_export_error ignores other errors' => sub {
	ok(!Service::Vault::is_export_error("Could not read secret/myapp from vault\n"), 'a failed read is not one');
	ok(!Service::Vault::is_export_error(''), 'nor is no error');
	ok(!Service::Vault::is_export_error(undef), 'nor undef');
};

subtest 'get_path and get_path_strict read every export version' => sub {
	my $v = Service::Vault->new('https://vault.example.com:8200', 'test-vault', 1, '', undef, '/secret/');
	my %tree = (password => 'hunter2', port => '8443', db => {host => 'localhost'});
	for my $case (['v1', $V1, \%tree], ['v2', $V2, {%tree, empty => {}}], ['v3', $V3, \%tree]) {
		my ($label, $json, $want) = @$case;
		no warnings 'redefine';
		local *Service::Vault::query = sub { return ($json, 0, '') };
		use warnings 'redefine';
		is_deeply($v->get_path('/secret/myapp'), $want, "get_path reads $label");
		is_deeply($v->get_path_strict('/secret/myapp'), $want, "get_path_strict reads $label");
	}

	my $typed = versioned(3, '{"secret/myapp/db":{"versions":[{"value":{"port":5432}}]}}');
	no warnings 'redefine';
	local *Service::Vault::query = sub { return ($typed, 0, '') };
	use warnings 'redefine';
	throws_ok { $v->get_path('/secret/myapp') } qr{secret/myapp/db.*\bport\b.*typed}s,
		'get_path dies on a typed value rather than returning it';
	throws_ok { $v->get_path_strict('/secret/myapp') } qr{secret/myapp/db.*\bport\b.*typed}s,
		'and so does get_path_strict';
};

{
	package ExportMockEnv;
	sub new    { bless {}, shift }
	sub name   { 'my-org-my-env' }
	sub type   { 'bosh' }
	sub lookup { undef }
	sub exists { 0 }
}

subtest 'store_data reads every export version' => sub {
	for my $case (['v1', $V1, \%WANT], ['v2', $V2, {%WANT, 'secret/myapp/empty' => {}}], ['v3', $V3, \%WANT]) {
		my ($label, $json, $want) = @$case;
		my $store = Genesis::Env::Secrets::Store::Vault->new(
			ExportMockEnv->new,
			service => Mock->new(query => sub { ($json, 0, '') }),
			mount_override => '/secret/',
			slug_override  => 'myapp',
		);
		is_deeply($store->store_data, $want, "store_data reads $label");
		is_deeply([sort $store->store_paths], [sort keys %$want], "and store_paths lists its live paths");
	}

	my $typed = versioned(3, '{"secret/myapp":{"versions":[{"value":{"ca":{"pem":"x"}}}]}}');
	my $store = Genesis::Env::Secrets::Store::Vault->new(
		ExportMockEnv->new,
		service => Mock->new(query => sub { ($typed, 0, '') }),
		mount_override => '/secret/',
			slug_override  => 'myapp',
	);
	throws_ok { $store->store_data } qr{secret/myapp.*\bca\b.*typed.*JSON\s+object}s,
		'store_data dies on a typed value';
	ok(!exists $store->{__data}, 'and caches nothing');
};

subtest 'pipeline callers of get_path surface an export error' => sub {
	my $error = do { local $@; eval { Service::Vault::normalize_export({'secret/x' => {k => 1}}) }; $@ };
	ok(Service::Vault::is_export_error($error), 'the fixture error is an export error');

	my $vault = Mock->new(get_path => sub { die $error });
	my $env = Mock->new(
		exodus_mount => '/secret/exodus/',
		type         => 'bosh',
		name         => 'my-env',
		vault        => $vault,
	);
	throws_ok { Genesis::Commands::Env::_assert_prior_env_deployed($env, 'prior-env') }
		qr{secret/x.*\bk\b.*typed}s,
		'the prior-env check reports the export error, not a missing deploy';
	throws_ok { Genesis::Commands::Env::_get_source_sha_for_pull($env, 'prior-env', Mock->new(sha => 'abc123')) }
		qr{secret/x.*\bk\b.*typed}s,
		'the pull source lookup reports it rather than falling back to control HEAD';
};

done_testing;
