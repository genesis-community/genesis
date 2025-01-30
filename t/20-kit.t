#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::Deep;

use_ok 'Genesis';
use_ok 'Genesis::Kit';
use_ok 'Genesis::Kit::Compiled';
use_ok 'Genesis::Kit::Dev';
use_ok 'Genesis::Kit::Provider::GenesisCommunity';
use_ok 'Service::Vault::Remote';

use_ok 'Genesis::Config';
$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");

use Genesis::Kit::Compiler;

package mockenv;
use Data::Dumper;

sub new {
	my ($class, @features) = @_;
	bless {
		f => \@features,
		vault => Service::Vault::Remote->new(url => "https://localhost:8999", name => "mockvault")
	}, $class;
}
sub features { @{$_[0]{f}}; }
sub name { "mock-env"; }
sub type { "mock-type"; }
sub secrets_path { "mock/env"; }
sub use_create_env { 0; }
sub lookup_bosh_target { wantarray ? ('a-bosh', 'params.bosh') : 'a-bosh'; }
sub lookup { "a-value" }
sub bosh_target { 'a-bosh'; }
sub path { "some/path/some/where".($_[1]?"/$_[1]":""); }
sub vault { $_[0]->{vault} }
sub get_environment_variables {
	my $self = shift;
	my %env;
	$env{GENESIS_ROOT}         = $self->path;
	$env{GENESIS_ENVIRONMENT}  = $self->name;
	$env{GENESIS_TYPE}         = $self->type;
	$env{GENESIS_TARGET_VAULT} = $env{SAFE_TARGET} = $self->vault->ref;
	$env{GENESIS_VERIFY_VAULT} = $self->vault->verify || "";

	$env{HOOK_ENV_VARS}='setup';
	$env{GENESIS_VAULT_PREFIX} = $env{GENESIS_SECRETS_PATH} = secrets_path;
	return %env;
}

package main;

sub kit {
	my ($name, $version, $path) = @_;
	$version ||= 'latest';
	$path ||= 't/src/simple';
	my $tmp = workdir;
	my $file;
	quietly {
		$file = Genesis::Kit::Compiler->new($path)->compile($name, $version, $tmp, force => 1);
	};

	return Genesis::Kit::Compiled->new(
		name    => $name,
		version => $version,
		archive => "$tmp/$file"
	);
}

sub decompile_kit {
	return Genesis::Kit::Dev->new(kit(@_)->path);
}

subtest 'kit utilities' => sub {
	my $kit = kit('test', '1.0.0');
	quietly { throws_ok { $kit->kit_bug('buggy behavior') }
		qr{
			buggy \s+ behavior.*
			a \s+ bug \s+ in \s+ the \s+ test/1\.0\.0 \s+ kit.*
			file \s+ an \s+ issue \s+ at .* https://github\.com/.*/issues
		}six, "kit_bug() reports the pertinent details for a compiled kit";
	};

	my $dev = decompile_kit('test', '1.0.0');
	quietly { throws_ok { $dev->kit_bug('buggy behavior') }
		qr{
			buggy \s+ behavior.*
			a \s+ bug \s+ in \s+ your \s+ dev/ \s+ kit.*
			contact .* author .* you
		}six, "kit_bug() reports the pertinent details for a dev kit";
	};
};

subtest 'compiled kits' => sub {
	my $kit = kit(test => '0.0.1');
	# drwxr-xr-x  0 jhunt  staff       0 Apr  7 14:53 ./
	# -rw-r--r--  0 jhunt  staff     307 Apr  7 14:53 ./kit.yml
	# drwxr-xr-x  0 jhunt  staff       0 Apr  4 23:31 ./hooks/
	# -rw-r--r--  0 jhunt  staff      24 Apr  4 20:47 ./manifest.yml
	# -rwxr-xr-x  0 jhunt  staff     194 Apr  4 20:46 ./hooks/new
	# -rwxr-xr-x  0 jhunt  staff      40 Apr  4 20:47 ./hooks/blueprint

	cmp_deeply($kit->metadata, superhashof({
			name => 'simple',
		}), "a kit should be able to parse its metadata");
	cmp_deeply($kit->metadata, $kit->metadata,
		"subsequent calls to kit->metadata should return the same metadata");

	is($kit->id, "test/0.0.1", "compiled kits should report their ID properly");
	is($kit->name, "test", "compiled kits should be know their own name");
	is($kit->version, "0.0.1", "compiled kits should be know their own version");
	for my $f (qw(kit.yml manifest.yml hooks/new hooks/blueprint)) {
		ok(-f $kit->path($f), "[test-0.0.1] $f file should exist in compiled kit");
	}
	for my $d (qw(hooks)) {
		ok(-d $kit->path($d), "[test-0.0.1] $d/ should exist in compiled kit");
	}
	ok(!$kit->has_hook('secrets'), "[test-0.0.1] kit should not report hooks it doesn't have");
};

subtest 'dev kits' => sub {
	my $kit = kit(test => '0.0.1');
	my $dev = decompile_kit(test => '0.0.1');
	is($dev->name, "dev", "dev kits are all named 'dev'");
	is($dev->version, "latest", "dev kits are always at latest");
	is($dev->id, "simple/in-development (dev)", "dev kits should report their ID as dev, all the time");
	for my $f (qw(kit.yml manifest.yml hooks/new hooks/blueprint)) {
		ok(-f $dev->path($f), "[dev :: test-0.0.1] $f file should exist in dev kit");
	}
	for my $d (qw(hooks)) {
		ok(-d $dev->path($d), "[dev :: test-0.0.1] $d/ should exist in dev kit");
	}

	isnt($kit->path("kit.yml"), $dev->path("kit.yml"),
		"compiled-kit paths are not the same as dev-kit paths");

	## source yaml files, based on features:
	cmp_deeply(
		[$kit->source_yaml_files(mockenv->new())],
		[re('\bmanifest.yml$')],
		"simple kits without subkits should return base yaml files only"
	);

	cmp_deeply(
		[$kit->source_yaml_files(mockenv->new('bogus', 'features'))],
		[$kit->source_yaml_files(mockenv->new())],
		"simple kits	ignore features	they don't know	about"
	);
};

subtest 'genesis-community kit provider configuration' => sub {
	my (%info);

	my $kit_provider = Genesis::Kit::Provider::GenesisCommunity->init();
	cmp_deeply({$kit_provider->config()}, {
			type => 'genesis-community',
		}, "GenesisCommunity kit provider has correct config");
	lives_ok { %info = $kit_provider->status() } "GenesisCommunity kit provider is reachable";
	cmp_deeply({%info}, {
		'type'   => 'genesis-community',
		'Source' => "Genesis Community organization on Github",
		'extras' => ['Source'],
		'kits'   => supersetof(qw/bosh cf jumpbox vault/),
		'status' => "ok"
	}, "GenesisCommunity kit provider contains correct provider status information");

	$kit_provider = Genesis::Kit::Provider->init();
	cmp_deeply({$kit_provider->config()}, {
			type => 'genesis-community',
		}, "Default kit provider is the GenesisCommunity kit provider");

};

subtest 'kit urls' => sub {
	my ($kit, $url, $version);
	my $provider = Genesis::Kit::Provider->init();

	lives_ok { $kit = $provider->kit_version_info('bosh') } "The latest BOSH kit can be found";
	lives_ok { $url = $kit->{url} } "The BOSH kit has a download url";
	like $url, qr{^https://github.com/genesis-community/bosh-genesis-kit/releases/download/},
		"The BOSH kit url is on Github";

	lives_ok { $kit = $provider->kit_version_info('bosh', '0.2.0') } "The BOSH kit v0.2.0 can be found";
	lives_ok { $url = $kit->{url} } "The BOSH kit has a download url";
	lives_ok { $version = $kit->{version} } "The BOSH kit has a download url";
	is $version, '0.2.0', 'bosh-0.2.0 is v0.2.0';
	is $url, 'https://github.com/genesis-community/bosh-genesis-kit/releases/download/v0.2.0/bosh-0.2.0.tar.gz',
		"The BOSH kit url points to the 0.2.0 release";

	dies_ok { $provider->kit_version_info('bosh', '0.0.781')->{url} } "Non-existent versions of kits do not exists";
};

subtest 'available kits' => sub {
	my (@kits,@expected);

	my $kit_provider = Genesis::Kit::Provider::GenesisCommunity->init();

	lives_ok { @kits = $kit_provider->kit_names } "Can get a list of downloadable kits from Github";
	@expected = qw(blacksmith bosh cf concourse jumpbox shield vault);
	cmp_deeply(\@kits, supersetof(@expected),
		"Downloadable kits includes at least the core kits known at the time of this writing.");
	
	lives_ok { @kits = $kit_provider->kit_names('^b.*h$') } "Can filter on a regex pattern";
	@expected = qw(bosh blacksmith);
	cmp_deeply(\@kits, supersetof(@expected), "Can filter on anchors to get bosh and blacksmith");
	my @bad = grep {$_ !~ /^b.*h$/} @kits;
	ok scalar(@bad) == 0, "No erroneous element were found in the filter";

	lives_ok { @kits = $kit_provider->kit_names('^cf$') } "Can filter on explicit name";
	ok @kits == 1 && $kits[0] eq 'cf', "Found one and only one match to 'cf' genesis kit";
};

subtest 'kit versions' => sub {
	my (@version_info,@versions);

	my $kit_provider = Genesis::Kit::Provider::GenesisCommunity->init();

	lives_ok { @version_info = $kit_provider->kit_versions('jumpbox') } "The Jumpbox kit has versions";
	@versions = map {$_->{version}} @version_info;
	my @bad = grep {$_ !~ /^(\d+)(?:\.(\d+)(?:\.(\d+)(?:[\.-]rc[\.-]?(\d+))?)?)?/} @versions;
	ok scalar(@versions) > 0 && scalar(@bad) == 0, "Returned good semver versions and no bad ones";

	my %struct = (body       => ignore(),
	              date       => re('\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ'),
	              draft      => re('^1?$'),
	              prerelease => re('^1?$'),
	              version    => re('^(\d+)(?:\.(\d+)(?:\.(\d+)(?:[\.-]rc[\.-]?(\d+))?)?)?'),
	              url        => re('https://github.com/genesis-community/jumpbox-genesis-kit/releases/download/[^/]*/jumpbox-[^/]*.tar.gz'),
	              filename   => re('jumpbox-[^/]*.tar.gz')
	             );
	cmp_deeply( [@version_info], array_each(\%struct), "Each version contains desired details");

	my @latest_two = (reverse sort by_semver @versions)[0..1];
	lives_ok { @version_info = $kit_provider->kit_versions('jumpbox',latest => 2) } "get the latest 2 versions";
	@versions = map {$_->{version}} @version_info;
	cmp_bag(\@versions, \@latest_two);
	
};

subtest 'version requirements' => sub {
	my $kit = kit(test => '1.2.3');
	local $Genesis::VERSION;

	$Genesis::VERSION = '0.0.1';
	quietly {ok !$kit->check_prereqs, 'v0.0.1 is too old for the t/src/simple kit prereq of 2.6.0';};

	$Genesis::VERSION = '9.9.9';
	ok $kit->check_prereqs, 'v9.9.9 is new enough for the t/src/simple kit prereq of 2.6.0';

	$Genesis::VERSION = "dev";
	ok $kit->check_prereqs, 'dev versions are new enough for any kit prereq';
};

done_testing;
