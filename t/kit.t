#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::Deep;

use_ok 'Genesis::Kit';
use_ok 'Genesis::Kit::Compiled';
use_ok 'Genesis::Kit::Dev';

sub kit {
	my ($name, $version) = @_;
	$version ||= 'latest';

	return Genesis::Kit::Compiled->new(
		name    => $name,
		version => $version,
		archive => "t/data/kits/$name-$version.tar.gz",
	);
}

sub decompile_kit {
	my $kit = kit(@_);
	return Genesis::Kit::Dev->new($kit->path);
}

##

my $kit = kit(compiled => '0.0.1');
# $ tar -tzvf t/data/kits/compiled-0.0.1.tar.gz
# drwxr-xr-x  0 jhunt  staff       0 Mar  6  2017 compiled-0.0.1/
# drwxr-xr-x  0 jhunt  staff       0 Dec 18  2016 compiled-0.0.1/base/
# -rw-r--r--  0 jhunt  staff      72 Dec 16  2016 compiled-0.0.1/kit.yml
# -rwxr-xr-x  0 jhunt  staff     217 Mar  6  2017 compiled-0.0.1/setup
# -rw-r--r--  0 jhunt  staff      15 Dec 18  2016 compiled-0.0.1/base/params.yml
# -rw-r--r--  0 jhunt  staff      19 Dec 18  2016 compiled-0.0.1/base/stuff.yml

cmp_deeply($kit->metadata, {
		name => 'Compiled Kit Test',
		vault => ignore,
	}, "a kit should be able to parse its metadata");
cmp_deeply($kit->metadata, $kit->metadata,
	"subsequent calls to kit->metadata should return the same metadata");

is($kit->id, "compiled/0.0.1", "compiled kits should report their ID properly");
is($kit->name, "compiled", "compiled kits should be know their own name");
is($kit->version, "0.0.1", "compiled kits should be know their own version");
ok(-d $kit->path("base"),  "[compiled-0.0.1] base/ should exist in compiled kit");
ok(-f $kit->path("setup"), "[compiled-0.0.1] the setup file should exist in compiled kit");

ok(!$kit->has_hook('new'), "[compiled-0.0.1] kit should not report hooks it doesn't have");

my $dev = decompile_kit(compiled => '0.0.1');
is($dev->name, "dev", "dev kits are all named 'dev'");
is($dev->version, "latest", "dev kits are always at latest");
is($dev->id, "(dev kit)", "dev kits should report their ID as dev, all the time");
ok(-d $dev->path("base"),  "[dev :: compiled-0.0.1] base/ should exist in compiled kit");
ok(-f $dev->path("setup"), "[dev :: compiled-0.0.1] the setup file should exist in compiled kit");

isnt($kit->path("base"), $dev->path("base"), "compiled-kit paths are not the same as dev-kit paths");

## source yaml files, based on features:
cmp_deeply([$kit->source_yaml_files()],
           [re('.*/base/params.yml$'),
            re('.*/base/stuff.yml$')],
           "simple kits without subkits should return base yaml files only");

cmp_deeply([$kit->source_yaml_files('bogus', 'features')],
           [$kit->source_yaml_files()],
           "simple kits ignore features they don't know about");


##

my ($url, $version);

$kit = kit('bosh');
lives_ok { ($url, $version) = $kit->url } "The BOSH kit has a valid download url";
like $url, qr{^https://github.com/genesis-community/bosh-genesis-kit/releases/download/},
	"The BOSH kit url is on Github";

$kit = kit('bosh', '0.2.0');
lives_ok { ($url, $version) = $kit->url } "The BOSH kit has a valid download url";
is $version, '0.2.0', 'bosh-0.2.0 is v0.2.0';
is $url, 'https://github.com/genesis-community/bosh-genesis-kit/releases/download/v0.2.0/bosh-0.2.0.tar.gz',
	"The BOSH kit url points to the 0.2.0 release";

$kit = kit('bosh', '0.0.781');
dies_ok { $kit->url } "Non-existent versions of kits do not have download urls";


done_testing;
