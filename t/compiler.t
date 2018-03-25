#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::Deep;
use Archive::Tar;

use Genesis::IO;
use_ok 'Genesis::Kit::Compiler';

my $tmp = workdir();
sub again {
	system("rm -rf $tmp/test-genesis-kit; mkdir -p $tmp/test-genesis-kit/hooks");
	system("mkdir -p $tmp/test-genesis-kit/ci");
put_file("$tmp/test-genesis-kit/ci/pipe.yml", <<EOF);
---
concourse: is fun
EOF
	put_file("$tmp/test-genesis-kit/NOTES", <<EOF);
these are notes
EOF
	put_file("$tmp/test-genesis-kit/kit.yml", <<EOF);
---
name:   test
author: jhunt
code:   https://github.com/genesis-community/test-genesis-kit

genesis_min_version: 2.5.2
EOF
	put_file("$tmp/test-genesis-kit/hooks/new", <<'EOF');
#!/bin/bash
set -eu
echo "--- {}" > $1/$2.yml
EOF
	put_file("$tmp/test-genesis-kit/hooks/blueprint", <<'EOF');
#!/bin/bash
set -eu
echo "manifests/test.yml"
EOF
	system("chmod 755 $tmp/test-genesis-kit/hooks/*");
	put_file("$tmp/test-genesis-kit/.gitignore", <<EOF);
*.tar.gz
NOTES
EOF
	system("cd $tmp/test-genesis-kit && git init &>/dev/null && git add .");
}

my $cc = Genesis::Kit::Compiler->new("$tmp/test-genesis-kit");

sub quietly(&) {
	local *STDERR;
	open(STDERR, '>', '/dev/null') or die "failed to quiet stderr!";
	return $_[0]->();
}

##################################

again();
ok($cc->validate, "validate should succeed when kit.yml defines all the things");

##################################

again();
unlink("$tmp/test-genesis-kit/kit.yml");
quietly { ok(!$cc->validate, "validation should fail when kit.yml is missing") };

##################################

again();
system("rm -rf $tmp/test-genesis-kit");
quietly { ok(!$cc->validate, "validation should fail when the root directory is missing") };

##################################

again();
put_file("$tmp/test-genesis-kit/kit.yml", "---\n[]");
quietly { ok(!$cc->validate, "validation should fail when kit.yml is a list") };

##################################

again();
put_file("$tmp/test-genesis-kit/kit.yml", "---\n{}");
quietly { ok(!$cc->validate, "validation should fail when kit.yml is empty") };

##################################

sub remove {
	my ($file, $re) = @_;
	open my $in,  "<", $file    or die "$file: $!";
	open my $out, ">", "$file~" or die "$file~: $!";

	while (<$in>) {
		next if $_ =~ $re;
		print $out $_;
	}

	close $in;
	close $out;

	rename "$file~", $file;
}
for my $field (qw(name code author)) {
	again();
	remove("$tmp/test-genesis-kit/kit.yml", qr/^$field:/);
	quietly { ok(!$cc->validate, "validation should fail when $field is omitted from kit.yml") };
}

again();
put_file("$tmp/test-genesis-kit/kit.yml", <<EOF);
name:    test
authors: [jhunt, dbell]
code:    https://www.genesisproject.io
EOF
ok($cc->validate, "validation should be happy with authors instead of author in kit.yml");

##################################

again();
put_file("$tmp/test-genesis-kit/kit.yml", <<EOF);
name:   test
author: jhunt
code:   https://www.genesisproject.io

genesis_min_version: latest
EOF
quietly { ok(!$cc->validate, "validation should fail when genesis_min_version is malformed") };

##################################

again();
system("mkdir $tmp/test-genesis-kit/hooks/info");
quietly { ok(!$cc->validate, "validation should fail if one of the hook scripts isn't a file") };

##################################

again();
system("chmod 644 $tmp/test-genesis-kit/hooks/new");
quietly { ok(!$cc->validate, "validation should fail if one of the hook scripts isn't executable") };

##################################

again();
lives_ok { $cc->_prepare('test-1.2.3'); } "kit source prep should work on the default test kit";

my $root = "$cc->{work}/$cc->{relpath}";
ok(!-d "$root/ci", "ci/ directory should be removed from prepared kit source");
ok(!-f "$root/NOTES", ".gitignore'd NOTES files should removed from prepared kit source");


##################################

again();
lives_ok { $cc->compile("test", "1.2.3", $tmp) } "kit compilation should work ";
ok(-f "$tmp/test-1.2.3.tar.gz", "kit compilation should produce a tarball in \$tmp");

my $tar = Archive::Tar->new("$tmp/test-1.2.3.tar.gz");
my %files = map { delete $_->{name} => $_ } $tar->list_files([qw[name size mode]]);
cmp_deeply(\%files, {
	'test-1.2.3/' => superhashof({ mode => 0755 }),
	'test-1.2.3/kit.yml' => {
		'mode' => 0644,
		# '7' arrived at through rigorous scientific research
		'size' => 7 + -s "$tmp/test-genesis-kit/kit.yml",
	},

	'test-1.2.3/hooks/' => superhashof({ mode => 0755 }),
	'test-1.2.3/hooks/blueprint' => {
		'mode' => 0755,
		'size' => -s "$tmp/test-genesis-kit/hooks/blueprint",
	},
	'test-1.2.3/hooks/new' => {
		'mode' => 0755,
		'size' => -s "$tmp/test-genesis-kit/hooks/new",
	}
}, "compiled kit tarball should contain just the files we want");

my $meta;
lives_ok { $meta = Load($tar->get_content('test-1.2.3/kit.yml')) } "compiled kit tarball should contain a valid kit.yml file";
is($meta->{version}, '1.2.3', "compiled kit tarball should contain the correct version in kit.yml metadata");


done_testing;
