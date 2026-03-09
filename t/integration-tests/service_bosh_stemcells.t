#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::More;

use_ok "Service::BOSH::Stemcell";

# Integration tests for Service::BOSH::Stemcell
# These tests make live calls to bosh.io API

subtest 'cpi_stemcell_prefix() method' => sub {
	plan tests => 8;

	# Test known IaaS mappings
	is(Service::BOSH::Stemcell->cpi_stemcell_prefix('aws'), 'aws-xen-hvm',
		'aws maps to aws-xen-hvm');
	is(Service::BOSH::Stemcell->cpi_stemcell_prefix('azure'), 'azure-hyperv',
		'azure maps to azure-hyperv');
	is(Service::BOSH::Stemcell->cpi_stemcell_prefix('google'), 'google-kvm',
		'google maps to google-kvm');
	is(Service::BOSH::Stemcell->cpi_stemcell_prefix('vsphere'), 'vsphere-esxi',
		'vsphere maps to vsphere-esxi');
	is(Service::BOSH::Stemcell->cpi_stemcell_prefix('openstack'), 'openstack-kvm',
		'openstack maps to openstack-kvm');
	is(Service::BOSH::Stemcell->cpi_stemcell_prefix('stackit'), 'openstack-kvm',
		'stackit maps to openstack-kvm');
	is(Service::BOSH::Stemcell->cpi_stemcell_prefix('warden'), 'warden-boshlite',
		'warden maps to warden-boshlite');

	# Test unknown IaaS returns empty string
	is(Service::BOSH::Stemcell->cpi_stemcell_prefix('unknown-iaas'), '',
		'unknown iaas returns empty string');
};

subtest 'Stemcell constructor and predicates' => sub {
	plan tests => 12;

	# Test light stemcell construction
	my $light_stemcell = Service::BOSH::Stemcell->new(
		iaas    => 'aws',
		os      => 'ubuntu-jammy',
		type    => 'light',
		url     => 'https://bosh.io/d/stemcells/bosh-aws-xen-hvm-ubuntu-jammy-go_agent?v=1.123',
		name    => 'bosh-aws-xen-hvm-ubuntu-jammy-go_agent',
		version => '1.123',
		sha1    => 'abc123',
	);

	isa_ok($light_stemcell, 'Service::BOSH::Stemcell', 'light stemcell constructor');
	is($light_stemcell->{iaas}, 'aws', 'iaas stored correctly');
	is($light_stemcell->{os}, 'ubuntu-jammy', 'os stored correctly');
	is($light_stemcell->{type}, 'light', 'type stored correctly');
	ok($light_stemcell->is_light(), 'is_light() returns true for light stemcell');
	ok(!$light_stemcell->is_full(), 'is_full() returns false for light stemcell');
	ok($light_stemcell->is_type('light'), 'is_type("light") returns true');
	ok(!$light_stemcell->is_local(), 'is_local() returns false for https URL');

	# Test regular stemcell construction
	my $regular_stemcell = Service::BOSH::Stemcell->new(
		iaas    => 'vsphere',
		os      => 'ubuntu-jammy',
		type    => 'regular',
		url     => '/path/to/local/stemcell.tgz',
		name    => 'bosh-vsphere-esxi-ubuntu-jammy-go_agent',
		version => '1.456',
	);

	ok($regular_stemcell->is_full(), 'is_full() returns true for regular stemcell');
	ok(!$regular_stemcell->is_light(), 'is_light() returns false for regular stemcell');
	ok($regular_stemcell->is_type('regular'), 'is_type("regular") returns true');
	ok($regular_stemcell->is_local(), 'is_local() returns true for local path');
};

subtest 'available_stemcells() live API call' => sub {
	plan tests => 11;

	# Test fetching available stemcells from bosh.io for aws/ubuntu-jammy
	my $stemcells = Service::BOSH::Stemcell->available_stemcells(
		iaas => 'aws',
		os   => 'ubuntu-jammy',
	);

	isa_ok($stemcells, 'ARRAY', 'available_stemcells returns array reference');
	ok(scalar(@$stemcells) > 0, 'available_stemcells returns at least one stemcell');

	# Check structure of first stemcell
	my $first = $stemcells->[0];
	isa_ok($first, 'Service::BOSH::Stemcell', 'first result is Stemcell object');
	ok(defined($first->{iaas}), 'stemcell has iaas field');
	ok(defined($first->{os}), 'stemcell has os field');
	ok(defined($first->{type}), 'stemcell has type field');
	ok(defined($first->{url}), 'stemcell has url field');
	ok(defined($first->{name}), 'stemcell has name field');
	ok(defined($first->{version}), 'stemcell has version field');

	# Verify type is valid
	ok($first->{type} eq 'light' || $first->{type} eq 'regular',
		'stemcell type is light or regular');

	# Verify stemcells are sorted by version (newest first)
	if (scalar(@$stemcells) > 1) {
		my $version_comparison = Service::BOSH::Stemcell::by_semver(
			$stemcells->[0]->{version},
			$stemcells->[1]->{version}
		);
		ok($version_comparison >= 0, 'stemcells sorted by version (newest first)');
	} else {
		pass('only one stemcell available, skipping sort check');
	}
};

subtest 'available_stemcells() with type filter' => sub {
	plan tests => 3;

	# Test fetching only light stemcells
	my $light_stemcells = Service::BOSH::Stemcell->available_stemcells(
		iaas => 'aws',
		os   => 'ubuntu-jammy',
		type => 'light',
	);

	ok(scalar(@$light_stemcells) > 0, 'available_stemcells with type=light returns results');

	# Verify all results are light stemcells
	my $all_light = 1;
	for my $sc (@$light_stemcells) {
		$all_light = 0 unless $sc->{type} eq 'light';
	}
	ok($all_light, 'all stemcells have type=light when filtered');

	# Test fetching only regular stemcells
	my $regular_stemcells = Service::BOSH::Stemcell->available_stemcells(
		iaas => 'vsphere',
		os   => 'ubuntu-jammy',
		type => 'regular',
	);

	my $all_regular = 1;
	for my $sc (@$regular_stemcells) {
		$all_regular = 0 unless $sc->{type} eq 'regular';
	}
	ok($all_regular, 'all stemcells have type=regular when filtered');
};

subtest 'find() method with live API' => sub {
	plan tests => 6;

	# First get available stemcells to find a valid version
	my $stemcells = Service::BOSH::Stemcell->available_stemcells(
		iaas => 'aws',
		os   => 'ubuntu-jammy',
	);

	skip_all('no stemcells available for testing') unless @$stemcells;

	my $latest_version = $stemcells->[0]->{version};

	# Test finding by exact version
	my $found = Service::BOSH::Stemcell->find('aws', 'ubuntu-jammy', $latest_version);
	ok(defined($found), 'find() returns stemcell for valid version');
	is($found->{version}, $latest_version, 'found stemcell has correct version');

	# Test finding latest
	my $found_latest = Service::BOSH::Stemcell->find('aws', 'ubuntu-jammy', 'latest');
	ok(defined($found_latest), 'find() with "latest" returns stemcell');
	is($found_latest->{version}, $latest_version, 'latest matches newest version');

	# Test finding by major version
	my ($major) = $latest_version =~ /^(\d+)\./;
	my $found_major_latest = Service::BOSH::Stemcell->find('aws', 'ubuntu-jammy', "$major.latest");
	ok(defined($found_major_latest), 'find() with "major.latest" returns stemcell');
	like($found_major_latest->{version}, qr/^$major\./, 'major.latest matches correct major version');
};

subtest 'available_stemcells() with different IaaS' => sub {
	plan tests => 6;

	# Test different IaaS providers to ensure API compatibility
	for my $iaas (qw/aws vsphere google/) {
		my $stemcells = Service::BOSH::Stemcell->available_stemcells(
			iaas => $iaas,
			os   => 'ubuntu-jammy',
		);
		ok(scalar(@$stemcells) > 0, "available_stemcells returns results for $iaas");
		like($stemcells->[0]->{name}, qr/bosh-.*-ubuntu-jammy-go_agent/,
			"stemcell name matches expected pattern for $iaas");
	}
};

done_testing;
