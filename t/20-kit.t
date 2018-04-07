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
use Genesis::Kit::Compiler;

sub kit {
	my ($name, $version) = @_;
	$version ||= 'latest';
	my $tmp = workdir;
	my $file = Genesis::Kit::Compiler->new('t/src/simple')->compile($name, $version, $tmp);

	return Genesis::Kit::Compiled->new(
		name    => $name,
		version => $version,
		archive => "$tmp/$file",
	);
}

sub decompile_kit {
	my $kit = kit(@_);
	return Genesis::Kit::Dev->new($kit->path);
}

##

my $kit = kit(compiled => '0.0.1');
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

is($kit->id, "compiled/0.0.1", "compiled kits should report their ID properly");
is($kit->name, "compiled", "compiled kits should be know their own name");
is($kit->version, "0.0.1", "compiled kits should be know their own version");
for my $f (qw(kit.yml manifest.yml hooks/new hooks/blueprint)) {
	ok(-f $kit->path($f), "[compiled-0.0.1] $f file should exist in compiled kit");
}
for my $d (qw(hooks)) {
	ok(-d $kit->path($d), "[compiled-0.0.1] $d/ should exist in compiled kit");
}
ok(!$kit->has_hook('secrets'), "[compiled-0.0.1] kit should not report hooks it doesn't have");


my $dev = decompile_kit(compiled => '0.0.1');
is($dev->name, "dev", "dev kits are all named 'dev'");
is($dev->version, "latest", "dev kits are always at latest");
is($dev->id, "(dev kit)", "dev kits should report their ID as dev, all the time");
for my $f (qw(kit.yml manifest.yml hooks/new hooks/blueprint)) {
	ok(-f $dev->path($f), "[dev :: compiled-0.0.1] $f file should exist in dev kit");
}
for my $d (qw(hooks)) {
	ok(-d $dev->path($d), "[dev :: compiled-0.0.1] $d/ should exist in dev kit");
}

isnt($kit->path("kit.yml"), $dev->path("kit.yml"),
	"compiled-kit paths are not the same as dev-kit paths");

## source yaml files, based on features:
cmp_deeply([$kit->source_yaml_files()],
           [re('\bmanifest.yml$')],
           "simple kits without subkits should return base yaml files only");

cmp_deeply([$kit->source_yaml_files(['bogus', 'features'])],
           [$kit->source_yaml_files()],
           "simple kits ignore features they don't know about");


##

my ($url, $version);

lives_ok { ($url, $version) = Genesis::Kit->url('bosh') } "The BOSH kit has a valid download url";
like $url, qr{^https://github.com/genesis-community/bosh-genesis-kit/releases/download/},
	"The BOSH kit url is on Github";

lives_ok { ($url, $version) = Genesis::Kit->url('bosh', '0.2.0') } "The BOSH kit has a valid download url";
is $version, '0.2.0', 'bosh-0.2.0 is v0.2.0';
is $url, 'https://github.com/genesis-community/bosh-genesis-kit/releases/download/v0.2.0/bosh-0.2.0.tar.gz',
	"The BOSH kit url points to the 0.2.0 release";

dies_ok { Genesis::Kit->url('bosh', '0.0.781') } "Non-existent versions of kits do not have download urls";


done_testing;
