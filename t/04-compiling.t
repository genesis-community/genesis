#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::Deep;
use Test::Output;
use Archive::Tar;

use_ok 'Genesis::Kit::Compiler';
use Genesis;

my $tmp = workdir();
my $cc = Genesis::Kit::Compiler->new("$tmp/test-genesis-kit");

sub again {
	system("rm -rf $tmp/test-genesis-kit; mkdir -p $tmp/test-genesis-kit/hooks");
	$cc->scaffold("test");

	# add some extra files
	system("mkdir -p $tmp/test-genesis-kit/ci");
	put_file("$tmp/test-genesis-kit/ci/pipe.yml", "concourse: is fun\n");

	# git init it
	system("cd $tmp/test-genesis-kit && git init >/dev/null 2>&1 && git add .");
}

sub quietly(&) {
	local *STDERR;
	open(STDERR, '>', '/dev/null') or die "failed to quiet stderr!";
	return $_[0]->();
}

##################################

again();
system("rm -f $tmp/README.md");
throws_ok { $cc->scaffold; } qr/cowardly refusing/,
	"scaffold() cowardly refuses to overwrite the target directory";
ok !-f "$tmp/README.md", "scaffold() should not have re-created missing README";

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

again();
put_file("$tmp/test-genesis-kit/kit.yml", <<EOF);
name:    test
authors: [jhunt, dbell]
author:  ghost
code:    https://www.genesisproject.io
EOF
quietly { ok(!$cc->validate, "validation should fail if both author and authors in kit.yml") };

again();
put_file("$tmp/test-genesis-kit/kit.yml", <<EOF);
name:    test
authors: |-
  jhunt
  dbell
code:    https://www.genesisproject.io
EOF
quietly { ok(!$cc->validate, "validation should fail if authors is not a list in kit.yml") };

##################################

again();
put_file("$tmp/test-genesis-kit/kit.yml", <<EOF);
name:    test
authors: [jhunt, dbell]
code:    https://www.genesisproject.io
EOF
ok($cc->validate, "validation should be happy with authors instead of author in kit.yml");

again();
put_file("$tmp/test-genesis-kit/kit.yml", <<EOF);
name:   test
author: jhunt
code:   https://www.genesisproject.io

genesis_version_min: latest
EOF
quietly { ok(!$cc->validate, "validation should fail when genesis_min_version is malformed") };

again();
put_file("$tmp/test-genesis-kit/kit.yml", <<EOF);
name:   test
author: jhunt
code:   https://www.genesisproject.io

genesis_min_version: 2.6.0
EOF
quietly { ok(!$cc->validate, "validation should fail when genesis_version_min is incorrectly called genesis_min_version") };

##################################
#
again();
put_file("$tmp/test-genesis-kit/kit.yml", <<EOF);
name:        test
version:     1.2.3
author:      jhunt
code:        https://www.github.com/starkandwayne/genesis/
docs:        https://www.genesisproject.io
description: |-
  This is a test kit to ensure that known top-level keys in kit.yml are accepted

genesis_version_min: 2.6.0

credentials:
  base:
    broker:
      password: random 64

certificates:
  base: {}
EOF
ok($cc->validate, "validation should be happy with all known top-level keys.");


again();
put_file("$tmp/test-genesis-kit/kit.yml", <<EOF);
name:        test
version:     1.2.3
by:          jhunt
github:      https://www.github.com/starkandwayne/genesis/
homepage:    https://www.genesisproject.io
descriptoin: |-
  This is a test kit to ensure that unknown top-level keys in kit.yml are rejected

subkits:
  # Needs to go first so that it blobstore job is deleted properly
  - prompt: Are you deploying on Azure?
    subkit: azure
    default: no

  - prompt: What database backend will you use for uaadb, ccdb, and diegob?
    type: database backend
    choices:
      - subkit: db-external-mysql
        label: An MySQL databases (e.g. RDS)
      - subkit: db-external-postgres
        label: A Postgres databases deployed externally (e.g. RDS)
      - subkit: db-internal-postgres
        label: Please give me a single-point-of-failure Postgres

params:
  base:
    - ask: What is the base domain
      param: base_domain
      description: |
        Domain of your base.
      example: all-your-bosh-are-belong-to-us.com

secrets:
  base:
    broker:
      password: random 64

EOF

stderr_like {
		ok(!$cc->validate, "validation should fail when there are unknown top-level keys")
	}
	qr/.*Kit Metadata file kit.yml contains invalid top-level keys: by, descriptoin, github, homepage, params, secrets, subkits\n  Valid keys are: name, version, description, code, docs, author, authors, genesis_version_min, certificates, credentials\n/sm,
	"invalid top-level keys should be reported";
ok($cc->compile("test", "1.2.3", $tmp, force => 1), "compiling an invalid kit should be allowed with force option");

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
	'test-1.2.3/README.md' => {
		'mode' => 0644,
		'size' => -s "$tmp/test-genesis-kit/README.md",
	},
	'test-1.2.3/kit.yml' => superhashof({ 'mode' => 0644 }),

	'test-1.2.3/manifests/' => superhashof({ mode => 0755 }),
	'test-1.2.3/manifests/test.yml' => {
		'mode' => 0644,
		'size' => -s "$tmp/test-genesis-kit/manifests/test.yml",
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
lives_ok { $meta = load_yaml($tar->get_content('test-1.2.3/kit.yml')); }
	"compiled kit tarball should contain a valid kit.yml file";
is($meta->{version}, '1.2.3',
	"compiled kit tarball should contain the correct version in kit.yml metadata");

done_testing;
