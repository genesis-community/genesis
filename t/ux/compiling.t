#!perl
use strict;
use warnings;

use lib 't';
use helper;

my $tmp = workdir();
my ($repo, $msg);

bosh2_cli_ok;

sub cleanroom($&) {
	my ($repo, $sub) = @_;
	ok -d "t/repos/$repo", "$repo repo exists" or die;
	chdir "t/repos/$repo" or die;
	qx(rm -f *.tar.gz *.tgz);

	$sub->();

	qx(rm -f *.tar.gz *.tgz ./dev/README.md);
	chdir "../../.." or die;
}

# Test Bad Development Kit
cleanroom "compile-test-deployments-bad" => sub {
	(undef, undef, $msg) = run_fails "genesis compile-kit --name custom-named-kit --version 1.0.4 --dev --force", 1;
	matches $msg, qr'Unable to compile v1.0.4 of custom-named-kit Genesis Kit', "Bad dev kit directory";
	ok ! -f "custom-named-kit-1.0.4.tar.gz", "`compile-kit' does not create the tarball if validation failed";
};

# Test Good Development Kit
cleanroom "compile-test-deployments" => sub {
	(undef, undef, $msg) = runs_ok "genesis compile-kit --version 1.0.4 --force";
	matches $msg, qr'Compiled compile-test v1.0.4 at compile-test-1.0.4.tar.gz\n', "Good dev kit directory - created release.";
	ok -f "compile-test-1.0.4.tar.gz", "genesis compile-test-kit should create the tarball";
	output_ok "tar zxf compile-test-1.0.4.tar.gz -O compile-test-1.0.4/kit.yml | spruce json | jq -r '.version'", "1.0.4", "Correct version set";
};

# Test Bad Kit Repo
cleanroom "compile-test-genesis-kit-bad" => sub {
	(undef, undef, $msg) = run_fails "genesis compile-kit --name my-kit --version 1.0.4 --force", 1;
	matches $msg, qr'Unable to compile v1.0.4 of my-kit Genesis Kit', "Bad kit directory";
	ok ! -f "my-kit-1.0.4.tar.gz", "genesis custom-named-kit should not create the tarball";
};

# Test Good Kit Repo
cleanroom "compile-test-genesis-kit" => sub {
	(undef, undef, $msg) = run_fails "genesis compile-kit --version 1.2.3 --dev --force", 1;
	matches $msg, qr'Current directory is a kit -- cannot specify dev mode\n', "Not a dev kit repo";
	ok ! -f "compile-test-kit-1.2.3.tar.gz", "genesis custom-named-kit should not create the tarball";

	# Run it properly, override name
	(undef, undef, $msg) = runs_ok "genesis compile-kit -n kickass --version 0.0.1 --force";
	matches $msg, qr'Compiled kickass v0.0.1 at kickass-0.0.1.tar.gz\n', "Good kit directory - created release.";
	doesnt_match $msg, qr'\nCannot continue.\n', "Abnormal dev kit directory - still can continue";
};

done_testing;
