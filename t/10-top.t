#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::Deep;
use Cwd ();

use_ok 'Genesis::Top';
use Genesis;

subtest 'kit location' => sub {
	my $tmp = workdir();
	my $again = sub {
		system("rm -rf $tmp/.genesis/kits; mkdir -p $tmp/.genesis/kits");
		system("touch $tmp/.genesis/kits/$_") for (qw/
			foo-1.0.0.tar.gz
			foo-1.0.1.tgz
			foo-0.9.6.tar.gz
			foo-0.9.5.tar.gz
			bar-3.4.5.tar.gz

			not-a-kit-file
			unversioned.tar.gz
			unversioned.tgz
		/);
	};
	my $top = Genesis::Top->new($tmp);

	$again->();
	ok(!$top->has_dev_kit, "roots without dev/ should not report having a dev kit");
	cmp_deeply($top->compiled_kits, {
			foo => {
				'0.9.5' => $top->path(".genesis/kits/foo-0.9.5.tar.gz"),
				'0.9.6' => $top->path(".genesis/kits/foo-0.9.6.tar.gz"),
				'1.0.0' => $top->path(".genesis/kits/foo-1.0.0.tar.gz"),
				'1.0.1' => $top->path(".genesis/kits/foo-1.0.1.tgz"),
			},
			bar => {
				'3.4.5' => $top->path(".genesis/kits/bar-3.4.5.tar.gz"),
			},
		}, "roots should list out all of their compiled kits");

	$again->();
	ok( defined $top->find_kit(foo => '1.0.0'), "test root dir should have foo-1.0.0 kit");
	ok(!defined $top->find_kit(foo => '9.8.7'), "test root dir should not have foo-9.8.7 kit");
	ok(!defined $top->find_kit(quxx => undef), "test root dir should not have any quux kit");
	ok( defined $top->find_kit(foo => '1.0.1'), "roots should recognize .tgz kits");
	ok( defined $top->find_kit(foo => 'latest'), "root should find latest kit versions");
	is($top->find_kit(foo => 'latest')->{version}, '1.0.1', "the latest foo kit should be 1.0.1");
	is($top->find_kit(foo => undef)->{version}, '1.0.1', "an undef version should count as 'latest'");
	ok(!defined $top->find_kit(undef => 'latest'), "kit name should be required if more than one kit exists");
	ok(!defined $top->find_kit(undef => '1.0.0'), "kit name should be requried if more than one kit exists, regardless of version uniqueness");

	$again->();
	system("rm -f $tmp/.genesis/kits/bar-*gz");
	cmp_deeply($top->compiled_kits, {
			foo => {
				'0.9.5' => $top->path(".genesis/kits/foo-0.9.5.tar.gz"),
				'0.9.6' => $top->path(".genesis/kits/foo-0.9.6.tar.gz"),
				'1.0.0' => $top->path(".genesis/kits/foo-1.0.0.tar.gz"),
				'1.0.1' => $top->path(".genesis/kits/foo-1.0.1.tgz"),
			},
		}, "root should only have `foo' kit");
	ok( defined $top->find_kit(undef, 'latest'), "root should find latest kit version of only kit");
	ok( defined $top->find_kit(undef, '0.9.6'), "root should find 0.9.6 kit version of only kit");
	is($top->find_kit(undef, 'latest')->{version}, '1.0.1', "the latest foo kit should be 1.0.1");
	is($top->find_kit(undef, 'latest')->{name}, 'foo', "the only kit should be 'foo'");
	is($top->find_kit(undef, '0.9.6')->{version}, '0.9.6', "specific version of the kit are returned");
	is($top->find_kit(undef, '0.9.6')->{name}, 'foo', "the only kit should be 'foo' (0.9.6)");
};

subtest 'init' => sub {
	my ($tmp, $top);

	# without a directory override
	$tmp = workdir;
	ok ! -f "$tmp/jumpbox-deployments/.genesis/config", "No .genesis/config in new Top";
	$top = Genesis::Top->create($tmp, 'jumpbox');
	ok -f "$tmp/jumpbox-deployments/.genesis/config", ".genesis created in correct top dir";
	ok -f $top->path('.genesis/config'), "Top->create should create a new .genesis/config";
	is $top->type, 'jumpbox', 'an initialized top has a type';

	# with a directory override
	$tmp = workdir;
	$top = Genesis::Top->create($tmp, 'jumpbox', directory => 'something-else');
	ok -f Cwd::abs_path("$tmp/something-else/.genesis/config"), ".genesis created in correct top dir";
	ok -f $top->path('.genesis/config'), "Top->create should create a new .genesis/config";
	is $top->type, 'jumpbox', 'an initialized top has a type';

	# overwrite tests
	$tmp = workdir;
	lives_ok { Genesis::Top->create($tmp, 'test') } "it should be okay to init once";
	throws_ok { Genesis::Top->create($tmp, 'test') } qr/cowardly refusing/i,
		"it is not okay to init twice";

	# name validation
	throws_ok { Genesis::Top->create($tmp, '!@#$ing-deployments') } qr/invalid genesis repo name/i,
		"it is not okay to swear in genesis repo names";
};

subtest 'embedding stuff' => sub {
	my $tmp = workdir;
	my $top = Genesis::Top->create($tmp, 'thing');
	put_file("$tmp/not-genesis", <<EOF);
#!/bin/bash
echo "this is not genesis"
EOF
	system("$tmp/not-genesis 2>/dev/null");
	isnt $?, 0, "tmp/not-genesis should not be executable";

	ok ! -f "$tmp/thing-deployments/.genesis/bin/genesis",
		"genesis bin should not be embedded by default";

	$top->embed("$tmp/not-genesis");
	ok -f "$tmp/thing-deployments/.genesis/bin/genesis",
		"genesis bin should be embedded once we call embed()";

	is qx($tmp/thing-deployments/.genesis/bin/genesis), "this is not genesis\n",
		"embed() makes the embedded copy executable";
};

subtest 'downloading kits' => sub {
	my $tmp = workdir();
	my $again = sub {
		system("rm -rf $tmp/.genesis/kits; mkdir -p $tmp/.genesis/kits");
	};
	my $top = Genesis::Top->new($tmp);

	$again->();
	ok(!defined $top->find_kit('bosh'), "bosh kit shouldn't exist (before download)");
	$top->download_kit("bosh/0.2.0");
	ok( defined $top->find_kit('bosh'), "bosh kit should exist after we download");
	ok( defined $top->find_kit('bosh', '0.2.0'), "top downloaded bosh-0.2.0 as requested");
};

done_testing;
