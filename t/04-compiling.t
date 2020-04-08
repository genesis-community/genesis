#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::Deep;
use Test::Output;
use Test::Differences;
use Archive::Tar;

use_ok 'Genesis::Kit::Compiler';
use Genesis;

my $tmp = workdir();
my $kitdir = $tmp."/test-genesis-kit";
my $cc = Genesis::Kit::Compiler->new($kitdir);
my $out;
$ENV{NOCOLOR} = 'y';

sub again {
	system("rm -rf $kitdir; mkdir -p $kitdir");
	$cc->scaffold("test");

	# add some extra files
	system("mkdir -p $kitdir/ci");
	put_file("$kitdir/ci/pipe.yml", "concourse: is fun\n");

	# git init it
	system(join(" && ",
		"cd $kitdir",
		'git init >/dev/null 2>&1',
		'git config user.email "testing@genesisproject.io"',
		'git config user.name "Testing Genesis"',
		'git add .',
		'git commit -m "committed" > /dev/null 2>&1'
	));
}

sub commit_changes {
	system("(cd $kitdir && git add -u && git commit -m 'commited changes') >/dev/null");
}

##################################

again();
system("rm -f $kitdir/README.md");
throws_ok { $cc->scaffold; } qr/cowardly refusing/,
	"scaffold() cowardly refuses to overwrite the target directory";
ok !-f "$kitdir/README.md", "scaffold() should not have re-created missing README";

##################################

again();

my $new_hook_file = $kitdir . "/hooks/new";
ok -f $new_hook_file, "basic hooks/new script exists";
if (-f $new_hook_file) {
	my $out = qx{
		shellcheck $new_hook_file -s bash -f json \\
		| jq -cr '.[] | select(.level == "error" or .level == "warning")'
	};

	my @msg = ();
	if ($out ne "") {

		my @lines;
		open my $handle, '<', $new_hook_file;
		chomp(@lines = <$handle>);
		close $handle;

		foreach (split($/, $out)) {
			my $err   = decode_json($_);
			my $linen = $err->{line};
			my $coln  = $err->{column};
			my $line  = $lines[$linen-1];
			my $i = 0;
			while ($i < $coln) {
				if (substr($line,$i,1) eq "\t") {
					substr($line, $i, 1) = "  "; # replace tab with 2 spaces
					$i++;
					$coln -= 6; # realign column (tabs count as 8 spaces in shellcheck)
				}
				$i++;
			}

			push (@msg, sprintf(
					"[SC%s - %s] %s:\n%s\n%s^--- [line %d, column %d]",
					$err->{code}, uc($err->{level}), $err->{message},
					$line,
					" " x ($coln-1), $linen, $coln
			));
		}
	}

	ok($out eq "", "hooks/new script should not contain any errors or warnings") or
		diag "\n".join("\n\n", @msg);
}

##################################

again();

$out = combined_from {
	ok($cc->validate('test','1.2.3'), "validate should succeed when kit.yml defines all the things");
};
eq_or_diff($out, <<'EOF', "validate should provide no output on success");
EOF

##################################

again();
unlink("$kitdir/kit.yml");
commit_changes;
$out = combined_from {
	ok(!$cc->validate('test','1.2.3'), "validation should fail when kit.yml is missing");
};
eq_or_diff($out, <<'EOF', "validate should report the file kit.yml does not exist.");

[ERROR] Encountered issues while processing kit test/1.2.3:

  Kit Metadata file kit.yml:
    - does not exist.

EOF

##################################

again();
system("rm -rf $kitdir");
$out = combined_from {
  ok(!$cc->validate('test','1.2.3'), "validation should fail when the root directory is missing");
};
$out =~ s/$tmp/<tempdir>/;
eq_or_diff($out, <<'EOF', "validate should report the source directory is not found");

[ERROR] Kit source directory '<tempdir>/test-genesis-kit' not found.

EOF

##################################

again();
put_file("$kitdir/kit.yml", "---\n[]");
commit_changes;
$out = combined_from {
	ok(!$cc->validate('test','1.2.3'), "validation should fail when kit.yml is a list")
};
eq_or_diff($out, <<'EOF', "validate should report the kit.yml file is not a map.");

[ERROR] Encountered issues while processing kit test/1.2.3:

  Kit Metadata file kit.yml:
    - is not a well-formed YAML file with a map root.

EOF

##################################

again();
put_file("$kitdir/kit.yml", "---\n{}");
commit_changes;
$out = combined_from {
	ok(!$cc->validate('test','1.2.3'), "validation should fail when kit.yml is empty");
};
eq_or_diff($out, <<'EOF', "validate should report that the required keys are missing");

[ERROR] Encountered issues while processing kit test/1.2.3:

  Kit Metadata file kit.yml:
    - does not define 'name'
    - does not define 'version'
    - does not define 'code'
    - does not identify the author(s) via 'author' or 'authors'

EOF

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
for my $field (qw(name version code author)) {
	again();
	remove("$kitdir/kit.yml", qr/^$field:/);
	commit_changes;
	$out = combined_from {
		ok(!$cc->validate('test','1.2.3'), "validation should fail when $field is omitted from kit.yml");
	};
	my $test_str = $field eq 'author' ?
		"identify the author(s) via 'author' or 'authors'" :
		"define '$field'";
	eq_or_diff($out, <<"EOF", "validate should report that the required keys are missing");

[ERROR] Encountered issues while processing kit test/1.2.3:

  Kit Metadata file kit.yml:
    - does not $test_str

EOF
}

again();
put_file("$kitdir/kit.yml", <<EOF);
name:    test
version: 1.2.3
authors: [jhunt, dbell]
code:    https://www.genesisproject.io
EOF
commit_changes;
$out = combined_from {
	ok($cc->validate('test','1.2.3'), "validation should be happy with authors instead of author in kit.yml");
};
eq_or_diff($out, <<'EOF', "validate should provide no failure message when authors is used");
EOF

again();
put_file("$kitdir/kit.yml", <<EOF);
name:    test
version: 1.2.3
authors: [jhunt, dbell]
author:  ghost
code:    https://www.genesisproject.io
EOF
commit_changes;
$out = combined_from {
	ok(!$cc->validate('test','1.2.3'), "validation should fail if both author and authors in kit.yml");
};
eq_or_diff($out, <<'EOF', "validate should report when both author and authors is used");

[ERROR] Encountered issues while processing kit test/1.2.3:

  Kit Metadata file kit.yml:
    - specifies both 'author' and 'authors': pick one.

EOF

again();
put_file("$kitdir/kit.yml", <<EOF);
name:    test
version: 1.2.3
authors: |-
  jhunt
  dbell
code:    https://www.genesisproject.io
EOF
commit_changes;
$out = combined_from {
	ok(!$cc->validate('test','1.2.3'), "validation should fail if authors is not a list in kit.yml");
};
eq_or_diff($out, <<'EOF', "validate should report when authors is not a list");

[ERROR] Encountered issues while processing kit test/1.2.3:

  Kit Metadata file kit.yml:
    - expects 'authors' to be an array, not a string.

EOF

##################################

again();
put_file("$kitdir/kit.yml", <<EOF);
name:   test
version: 1.2.3
author: jhunt
code:   https://www.genesisproject.io

genesis_version_min: latest
EOF
commit_changes;
$out = combined_from {
	ok(!$cc->validate('test','1.2.3'), "validation should fail when genesis_min_version is malformed");
};
eq_or_diff($out, <<'EOF', "validate should report a non-semver-compliant genesis_min_version");

[ERROR] Encountered issues while processing kit test/1.2.3:

  Kit Metadata file kit.yml:
    - specifies minimum Genesis version 'latest', which is not a semantic version (x.y.z).

EOF

again();
put_file("$kitdir/kit.yml", <<EOF);
name:   test
version: 1.2.3
author: jhunt
code:   https://www.genesisproject.io

genesis_min_version: 2.6.0
EOF
commit_changes;
$out = combined_from {
	ok(!$cc->validate('test','1.2.3'), "validation should fail when genesis_version_min is incorrectly called genesis_min_version");
};
eq_or_diff($out, <<'EOF', "validate should report when genesis_min_version is used instead of genesis_version_min");

[ERROR] Encountered issues while processing kit test/1.2.3:

  Kit Metadata file kit.yml:
    - contains invalid top-level key: genesis_min_version;
      valid keys are: name, version, description, code, docs, author, authors, genesis_version_min, secrets_store, credentials, certificates

EOF

### secrets_store ###

again();
put_file("$kitdir/kit.yml", <<EOF);
name:          test
version:       2.0.1
author:        dbell
code:          https://www.github.com/starkandwayne/genesis/
secrets_store: credhub

credentials:
  base:
    broker:
      password: random 64

certificates:
  base: {}
EOF
commit_changes;
$out = combined_from {
	ok(!$cc->validate('test','2.0.1'), "validation should be fail when credentials or certificates are used with credhub secrets_store.");
};
eq_or_diff($out, <<'EOF', "validate should report credentials and certificate fields are not valid when using credhub");

[ERROR] Encountered issues while processing kit test/2.0.1:

  Kit Metadata file kit.yml:
    - contains invalid top-level keys: certificates, credentials;
      valid keys are: name, version, description, code, docs, author, authors, genesis_version_min, secrets_store

EOF

again();
put_file("$kitdir/kit.yml", <<EOF);
name:          test
version:       2.0.1
author:        dbell
code:          https://www.github.com/starkandwayne/genesis/
secrets_store: krypton
EOF
commit_changes;
$out = combined_from {
	ok(!$cc->validate('test','2.0.1'), "validation should fail when secrets_store has an invalid value");
};
eq_or_diff($out, <<'EOF', "validate should report when secrets_store has an invalid value");

[ERROR] Encountered issues while processing kit test/2.0.1:

  Kit Metadata file kit.yml:
    - specifies invalid secrets_store: expecting one of 'vault' or 'credhub'

EOF

##########################################

again();
put_file("$kitdir/kit.yml", <<EOF);
name:        test
version:     1.2.3
author:      jhunt
code:        https://www.github.com/starkandwayne/genesis/
docs:        https://www.genesisproject.io
description: |-
  This is a test kit to ensure that known top-level keys in kit.yml are accepted

genesis_version_min: 2.6.0
secrets_store: vault

credentials:
  base:
    broker:
      password: random 64

certificates:
  base: {}
EOF
$out = combined_from {
  ok(!$cc->validate('test','1.2.3'), "validation should fail with uncommitted changes.");
};
eq_or_diff($out, <<'EOF', "validate should report uncommitted changes.");

[ERROR] Encountered issues while processing kit test/1.2.3:

  Git repository status:
    Unstaged / uncommited changes found in working directory:
       M kit.yml

    Please either stash or commit those changes before compiling your kit.

EOF
commit_changes;
$out = combined_from {
	ok($cc->validate('test','1.2.3'), "validation should be happy with all known top-level keys.");
};
eq_or_diff($out, <<'EOF', "validate should provide no failure message when only known top-level keys are used");
EOF


again();
put_file("$kitdir/kit.yml", <<EOF);
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
commit_changes;

$out = combined_from {
	ok(!$cc->validate("test","1.2.3"), "validation should fail when there are unknown top-level keys")
};
eq_or_diff($out, <<'EOF', "validate should report when unknown top-level keys are used");

[ERROR] Encountered issues while processing kit test/1.2.3:

  Kit Metadata file kit.yml:
    - does not define 'code'
    - does not identify the author(s) via 'author' or 'authors'
    - contains invalid top-level keys: by, descriptoin, github, homepage, params, secrets, subkits;
      valid keys are: name, version, description, code, docs, author, authors, genesis_version_min, secrets_store, credentials, certificates

EOF

$out = combined_from {
  ok($cc->compile("test", "1.2.3", $tmp, force => 1), "compiling an invalid kit should be allowed with force option");
};
eq_or_diff($out, <<'EOF', "validate should report errors even when force is used");

[ERROR] Encountered issues while processing kit test/1.2.3:

  Kit Metadata file kit.yml:
    - does not define 'code'
    - does not identify the author(s) via 'author' or 'authors'
    - contains invalid top-level keys: by, descriptoin, github, homepage, params, secrets, subkits;
      valid keys are: name, version, description, code, docs, author, authors, genesis_version_min, secrets_store, credentials, certificates

EOF

##################################

again();
system("mkdir $kitdir/hooks/info");
$out = combined_from {
  ok(!$cc->validate("test","1.2.3"), "validation should fail if one of the hook scripts isn't a file");
};
eq_or_diff($out, <<'EOF', "validate should report errors even when force is used");

[ERROR] Encountered issues while processing kit test/1.2.3:

  Hook scripts:
    - hooks/info is not a regular file.

EOF
##################################

again();
system("chmod 644 $kitdir/hooks/new");
commit_changes;
$out = combined_from {
  ok(!$cc->validate("test","1.2.3"), "validation should fail if one of the hook scripts isn't executable");
};
eq_or_diff($out, <<'EOF', "validate should report errors even when force is used");

[ERROR] Encountered issues while processing kit test/1.2.3:

  Hook scripts:
    - hooks/new is not executable.

EOF

#### all the errors! ####

again();
put_file("$kitdir/kit.yml", <<EOF);
---
name:        testing
version:     bob
author:      [jhunt, dbell]
'code repo': https://www.github.com/starkandwayne/genesis/
url:         file:///etc/passwd
description:
  - This is a test kit to ensure that unknown top-level keys in kit.yml are rejected

params:
  base:
    - ask: What is the base domain
      param: base_domain
      description: |
        Domain of your base.
      example: all-your-bosh-are-belong-to-us.com

certificates:
  base:
    top-level/certs:
      root:
        is_ca: true
        names: [rootCA]
        valid_for: \${params.ca_ttl}
      server:
        names: [server, $(params.base_domain)]
        valid_for: \${params.cert_ttl}
        usage:
          - client_auth
          - server_auth
          - digital_signature
          - email_protection
          - key_agreement
          - key_cert_sign


    other/certs:
      ca:
        signed_by: top-level/certs/root
      server:
        name: [otherCert]
        usage: [client_auth, server_auth]

  errors:
    bad_chain:
      ca:
        signed_by: top-level/certs/root
        ttl: 1y
        names: [rootCA]
      server:
        valid_for: forever

    bad-params:
      master:
        is_ca: CA
        signed_by: \${params.root_ca}
        names: "this"
        usage: client_auth
      server:
        names: []
        usage: []
      client:
        names:
          - ''
        usage:
          - decipher_only
          - take_over_the_world
          - tax shelter

    bad_request: x509 issue --name bob -A secret/root_ca

credentials:
  base:
    good_ssh: ssh 2048 fixed
    passwords:
      secret: random 64

  errors:
    bad_ssh: ssh 24
    password: random 64
    'secret:passwords': random 32 fixed
    passwords:
      this: gen 64
    something: completely different


EOF
system("mkdir $kitdir/ci") unless -d "$kitdir/ci";
system("mkdir -p $kitdir/hooks/info");
put_file("$kitdir/ci/test_params.yml", <<EOF);
---
params:
  base_domain: example.com
  ca_ttl: 10y
  cert_ttl: 2y
EOF

unlink "$kitdir/hooks/new" if -f "$kitdir/hooks/new";
put_file("$kitdir/hooks/new", <<EOF);
#!/bin/bash
set -ue
echo "tada!"
EOF

put_file("$kitdir/hooks/blueprint", <<EOF);
#!/bin/bash
set -ue
echo "something.yml"
EOF

system("(cd $kitdir && git add hooks && git commit -m 'commited changes') >/dev/null");
system("(cd $kitdir && git add ci && git rm -f hooks/blueprint) >/dev/null");

put_file("$kitdir/hooks/check", <<EOF);
#!/bin/bash
set -ue
exit 1
EOF

$out = combined_from {
	ok(!$cc->validate("test","1.2.3"), "validation should error on multiple errors")
};
eq_or_diff($out, <<'EOF', "validate should report all errors in the kit");

[ERROR] Encountered issues while processing kit test/1.2.3:

  Kit Metadata file kit.yml:
    - does not define 'code'
    - specifies name 'testing', expecting 'test'
    - contains invalid top-level keys: code repo, params, url;
      valid keys are: name, version, description, code, docs, author, authors, genesis_version_min, secrets_store, credentials, certificates

  Secrets specifications in kit.yml:

    Bad X509 certificate request for bad-params/client:
      - Invalid names argument: cannot have an empty name entry
      - Invalid usage argument - unknown usage keys: 'take_over_the_world', 'tax shelter'
        Valid keys are: 'client_auth', 'code_signing', 'content_commitment', 'crl_sign', 'data_encipherment', 'decipher_only', 'digital_signature', 'email_protection', 'encipher_only', 'key_agreement', 'key_cert_sign', 'key_encipherment', 'non_repudiation', 'server_auth', 'timestamping'

    Bad X509 certificate request for bad-params/server:
      - Invalid names argument: expecting an array of one or more strings, got an empty list

    Bad X509 certificate request for bad_chain/ca:
      - CA Common Name Conflict - can't share CN 'rootCA' with signing CA

    Bad X509 certificate request for bad_chain/server:
      - Invalid valid_for argument: expecting <positive_number>[ymdh], got forever

    Bad X509 certificate request for bad-params/master:
      - Invalid names argument: expecting an array of one or more strings, got the string 'this'
      - Invalid usage argument: expecting an array of one or more strings, got the string 'client_auth'
      - Invalid is_ca argument: expecting boolean value, got 'CA'
      - Invalid signed_by argument: expecting relative vault path string, got '${params.root_ca}'

    Badly formed x509 request for bad_request:
      - expecting certificate specification in the form of a hash map

    Bad credential request for password:
      - Unrecognized request 'random 64'

    Bad crecential request for passwords:this:
      - Bad generate-password format 'gen 64'

    Bad credential request for secret:passwords:
      - Path cannot contain colons

    Bad credential request for something:
      - Unrecognized request 'completely different'

    Bad SSH request for bad_ssh:
      - Invalid size argument: expecting 1024-16384, got 24

    Some of the errors above are due to unresolved param dereferencing.  Update the
    ci/test_params.yml file in the kit directory to contain these parameters.

  Hook scripts:
    - hooks/new is not executable.
    - hooks/info is not a regular file.
    - hooks/check is not executable.

  Git repository status:
    Unstaged / uncommited changes found in working directory:
      A  ci/test_params.yml
      D  hooks/blueprint
       M kit.yml
      ?? hooks/check

    Please either stash or commit those changes before compiling your kit.

EOF

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
		'size' => -s "$kitdir/README.md",
	},
	'test-1.2.3/kit.yml' => superhashof({ 'mode' => 0644 }),

	'test-1.2.3/manifests/' => superhashof({ mode => 0755 }),
	'test-1.2.3/manifests/test.yml' => {
		'mode' => 0644,
		'size' => -s "$kitdir/manifests/test.yml",
	},

	'test-1.2.3/hooks/' => superhashof({ mode => 0755 }),
	'test-1.2.3/hooks/blueprint' => {
		'mode' => 0755,
		'size' => -s "$kitdir/hooks/blueprint",
	},
	'test-1.2.3/hooks/new' => {
		'mode' => 0755,
		'size' => -s "$kitdir/hooks/new",
	}
}, "compiled kit tarball should contain just the files we want");

my $meta;
lives_ok { $meta = load_yaml($tar->get_content('test-1.2.3/kit.yml')); }
	"compiled kit tarball should contain a valid kit.yml file";
is($meta->{version}, '1.2.3',
	"compiled kit tarball should contain the correct version in kit.yml metadata");

done_testing;
