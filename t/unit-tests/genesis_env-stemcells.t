#!perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Test::Deep;
use Test::Exception;
use Test::Output;
use JSON::PP;

use Genesis;
use_ok 'Genesis::Config';
provide_rc();
use_ok 'Genesis::Top';
use_ok 'Genesis::Env';
require Service::BOSH::Director;
require Service::BOSH::Stemcell;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

sub make_env {
	my ($name) = @_;
	my $top = make_top(name => 'stemcells', no_vault => 1);
	$top->link_dev_kit('t/src/simple');
	put_file($top->path("$name.yml"), <<"EOF2");
---
kit:
  name:    dev
  version: latest
  features: []
genesis:
  env: $name
EOF2
	return $top->load_env($name);
}

# A director whose `bosh stemcells --json` rows are given verbatim, so the
# tests exercise the real Service::BOSH::Director::stemcells parsing.
sub stemcells_json {
	my (@rows) = @_;
	return JSON::PP->new->encode({Tables => [{Rows => \@rows}]});
}

my $noble_row = {
	name    => 'bosh-proxmox-kvm-ubuntu-noble-go_agent',
	os      => 'ubuntu-noble',
	version => '1.562*',
	cpi     => '',
};

# Runs $code with the env's stemcell inputs stubbed: the manifest stemcells
# block, the director rows, and the bosh.io lookup (recorded in @$finds).
sub with_stemcells {
	my ($env, $manifest_stemcells, $rows, $finds, $code) = @_;
	no warnings qw(redefine once);
	local *Genesis::Env::needed_cpis = sub { () };
	local *Genesis::Env::cpi_enabled = sub { 0 };
	local *Genesis::Env::use_create_env = sub { 0 };
	local *Genesis::Env::iaas = sub { 'pve' };
	local *Genesis::Env::partial_manifest_lookup = sub {
		my ($self, $key, $default) = @_;
		return $manifest_stemcells if $key eq 'stemcells';
		return $default;
	};
	my $json = stemcells_json(@$rows);
	local *Service::BOSH::Director::execute = sub { ($json, 0, '') };
	local *Genesis::Env::bosh = sub { bless {}, 'Service::BOSH::Director' };
	local *Service::BOSH::Stemcell::find = sub {
		my ($class, @args) = @_;
		push @$finds, [@args];
		return undef;
	};
	return $code->();
}

# ======================================================================
# _get_stemcell_status - stemcells named by `name`
# ======================================================================

subtest '_get_stemcell_status - name-only stemcell matches by name' => sub {
	my $env = make_env('sc-name-only');
	my @finds;
	my @results = with_stemcells($env,
		[{alias => 'named', name => 'bosh-proxmox-kvm-ubuntu-noble-go_agent', version => '1.562'}],
		[$noble_row], \@finds,
		sub { $env->_get_stemcell_status(1) },
	);
	is scalar(@results), 1, 'one result for one stemcell';
	ok $results[0]{found}, 'stemcell present on the director under that name is found';
	is $results[0]{os}, 'ubuntu-noble', 'os is taken from the matched director stemcell';
	is scalar(@finds), 0, 'no bosh.io lookup when the stemcell is present';
};

subtest '_get_stemcell_status - name wins over os, as it does in BOSH' => sub {
	my $env = make_env('sc-name-and-os');
	my @finds;
	my @results = with_stemcells($env,
		[{alias => 'named', name => 'bosh-proxmox-kvm-ubuntu-noble-go_agent', os => 'ubuntu-resolute', version => '1.562'}],
		[$noble_row], \@finds,
		sub { $env->_get_stemcell_status(1) },
	);
	ok $results[0]{found}, 'director matches name/version and ignores os, so the stemcell is found';
};

subtest '_get_stemcell_status - latest resolves within the named image only' => sub {
	my $env = make_env('sc-name-latest');
	my @finds;
	my @results = with_stemcells($env,
		[{alias => 'named', name => 'bosh-proxmox-kvm-ubuntu-noble-go_agent', version => 'latest'}],
		[$noble_row, {name => 'bosh-openstack-kvm-ubuntu-noble', os => 'ubuntu-noble', version => '1.600', cpi => 'openstack'}],
		\@finds,
		sub { $env->_get_stemcell_status(1) },
	);
	ok $results[0]{found}, 'latest named stemcell is found';
	is $results[0]{found}{version}, '1.562',
		'a newer image of another name with the same os is not chosen';
};

subtest '_get_stemcell_status - absent name-only stemcell never searches bosh.io with no os' => sub {
	my $env = make_env('sc-name-absent');
	my @finds;
	my @warnings;
	local $SIG{__WARN__} = sub { push @warnings, $_[0] };
	my @results = with_stemcells($env,
		[{alias => 'named', name => 'bosh-proxmox-kvm-ubuntu-resolute-go_agent', version => '0.184'}],
		[$noble_row], \@finds,
		sub { $env->_get_stemcell_status(1) },
	);
	ok !$results[0]{found}, 'stemcell is not found';
	is scalar(grep {!defined $_->[1]} @finds), 0,
		'Stemcell->find is never called with an undefined os (it would default to ubuntu-noble)';
	is_deeply \@warnings, [], 'no uninitialized-value warnings';
};

# ======================================================================
# _check_stemcells - a missing stemcell with no download source
# ======================================================================

subtest '_check_stemcells - unknown source still hands consumers a fix_data' => sub {
	my $env = make_env('sc-unknown-advise');
	my @finds;
	my $result;
	with_stemcells($env,
		[{alias => 'default', os => 'ubuntu-resolute', version => '0.999'}],
		[$noble_row], \@finds,
		sub { combined_from { $result = $env->_check_stemcells } },
	);
	is $result->{state}, 'error', 'state is error';
	ok $result->{fatal}, 'result is fatal';
	like $result->{msg}, qr/requires manual upload.*ubuntu-resolute\@0\.999/s,
		'msg names the stemcell that needs a manual upload';

	# Commands::Env deploy (no --fix-stemcells) and Env::check both pass
	# fix_data straight to _advise_stemcell_updates.
	my $advice;
	lives_ok { $advice = combined_from { $env->_advise_stemcell_updates($result->{fix_data}) } }
		'advising on a fatal result does not bail with the fix_data message';
	unlike $advice // '', qr/upload-stemcells/,
		'no upload command is advised when nothing is downloadable';

	# Commands::Env deploy --fix-stemcells passes fix_data to _fix_stemcells.
	throws_ok { $env->_fix_stemcells($result->{fix_data}, noprompt => 1) }
		qr/requires manual upload.*ubuntu-resolute\@0\.999/s,
		'fixing a fatal result bails with the manual-upload message';
};

subtest '_check_stemcells - absent name-only stemcell names it in the message' => sub {
	my $env = make_env('sc-unknown-name');
	my @finds;
	my @warnings;
	local $SIG{__WARN__} = sub { push @warnings, $_[0] };
	my $result;
	with_stemcells($env,
		[{alias => 'named', name => 'bosh-proxmox-kvm-ubuntu-resolute-go_agent', version => '0.184'}],
		[$noble_row], \@finds,
		sub { combined_from { $result = $env->_check_stemcells } },
	);
	ok $result->{fatal}, 'result is fatal';
	like $result->{msg}, qr/bosh-proxmox-kvm-ubuntu-resolute-go_agent.*0\.184/,
		'msg names the stemcell by its name and version';
	is_deeply \@warnings, [], 'no uninitialized-value warnings';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
