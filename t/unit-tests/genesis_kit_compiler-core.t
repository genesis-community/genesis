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

use_ok 'Genesis::Config';
$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");

use_ok 'Genesis::Kit::Compiler';
use Genesis;

$ENV{NOCOLOR}               = 'y';
$ENV{GENESIS_OUTPUT_COLUMNS} = 120;
$ENV{GIT_EDITOR}            = 'true';

# ---------------------------------------------------------------------------
# Shared temp root for all subtests. init_kit_repo() resets the default
# kit directory via rm -rf before each use; subtests run serially so
# there is no cross-test coupling.
# ---------------------------------------------------------------------------

my $tmp = workdir("KIT_COMPILER");

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# init_kit_repo - scaffold a fresh kit, add a ci/ tree, git-init and commit.
# Returns ($kitdir, $cc) so callers can use both without re-constructing.
#
# Options:
#   dir  - override the kit directory (default: "$tmp/test-genesis-kit")
#   name - kit name passed to scaffold()         (default: "test")

sub init_kit_repo {
    my (%opts) = @_;
    my $kitdir = $opts{dir}  || "$tmp/test-genesis-kit";
    my $name   = $opts{name} || "test";

    system("rm -rf $kitdir; mkdir -p $kitdir");

    my $cc = Genesis::Kit::Compiler->new($kitdir);
    $cc->scaffold($name);

    # Add a ci/ subtree that validate() / _lookup_test_params() look at.
    system("mkdir -p $kitdir/ci");
    put_file("$kitdir/ci/pipe.yml", "concourse: is fun\n");

    # Initialise a git repository so validate() can check for dirty state.
    system(join(" && ",
        "cd $kitdir",
        'git init >/dev/null 2>&1',
        'git config user.email "testing@genesisproject.io"',
        'git config user.name "Testing Genesis"',
        'git add .',
        'git commit -m "initial" >/dev/null 2>&1',
    ));

    return ($kitdir, $cc);
}

# commit_kit_changes - stage all changes and create a commit.
sub commit_kit_changes {
    my ($kitdir) = @_;
    system("(cd $kitdir && git add -A && git commit -m 'committed changes') >/dev/null 2>&1");
}

# remove - strip lines matching a regex from a file.
sub remove {
    my ($file, $re) = @_;
    open my $in,  "<", $file    or die "$file: $!";
    open my $out, ">", "$file~" or die "$file~: $!";
    while (<$in>) {
        next if $_ =~ $re;
        print $out $_;
    }
    close $in  or die "close $file: $!";
    close $out or die "close $file~: $!";
    rename "$file~", $file or die "rename $file~ -> $file: $!";
}

###############################################################################
# INTERNAL METHOD TESTS
###############################################################################

# ---------------------------------------------------------------------------
# new() - constructor
# ---------------------------------------------------------------------------
subtest 'new() - constructor' => sub {
    plan tests => 3;

    my $cc = Genesis::Kit::Compiler->new("/some/nonexistent/path");

    isa_ok $cc, 'Genesis::Kit::Compiler',
        'new() returns a blessed Genesis::Kit::Compiler object';

    is $cc->{root}, '/some/nonexistent/path',
        'new() stores the root path in {root}';

    ok defined($cc->{work}),
        'new() initialises the {work} scratch directory';
};

# ---------------------------------------------------------------------------
# _to_camel_case - name conversion
# ---------------------------------------------------------------------------
subtest '_to_camel_case - name conversion' => sub {
    plan tests => 4;

    my $cc = Genesis::Kit::Compiler->new("$tmp/_camel");

    is $cc->_to_camel_case('cf'),            'CF',
        '_to_camel_case("cf") uses the special-case mapping -> "CF"';

    is $cc->_to_camel_case('bosh'),          'BOSH',
        '_to_camel_case("bosh") uses the special-case mapping -> "BOSH"';

    is $cc->_to_camel_case('rabbitmq'),      'Rabbitmq',
        '_to_camel_case("rabbitmq") ucfirst()s an unmapped single token';

    is $cc->_to_camel_case('cf-rabbitmq'),   'CFRabbitmq',
        '_to_camel_case("cf-rabbitmq") maps "cf" -> "CF" and ucfirsts the rest';
};

# ---------------------------------------------------------------------------
# _generate_package_name - hook package naming
# ---------------------------------------------------------------------------
subtest '_generate_package_name - hook package naming' => sub {
    plan tests => 4;

    my $cc = Genesis::Kit::Compiler->new("$tmp/_pkg");

    is $cc->_generate_package_name('new', 'CF'),
        'Genesis::Hook::New::CF',
        '_generate_package_name("new", "CF") produces regular hook package';

    is $cc->_generate_package_name('blueprint', 'BOSH'),
        'Genesis::Hook::Blueprint::BOSH',
        '_generate_package_name("blueprint", "BOSH") produces regular hook package';

    is $cc->_generate_package_name('addon-rabbitmq', 'CF'),
        'Genesis::Hook::Addon::CF::Rabbitmq',
        '_generate_package_name("addon-rabbitmq", "CF") produces addon package';

    is $cc->_generate_package_name('addon-bind-autoscaler~ba', 'CF'),
        'Genesis::Hook::Addon::CF::BindAutoscaler',
        '_generate_package_name strips tilde shortcut before generating addon name';
};

# ---------------------------------------------------------------------------
# _update_package_line - file rewriting
# ---------------------------------------------------------------------------
subtest '_update_package_line - file rewriting' => sub {
    plan tests => 5;

    my $cc       = Genesis::Kit::Compiler->new("$tmp/_pkg_line");
    my $hookfile = "$tmp/fake_hook.pm";

    put_file($hookfile, "package OldName v1.0.0;\nuse strict;\n1;\n");

    my $new_line = 'package Genesis::Hook::New::Test v2.8.0';

    my $changed = $cc->_update_package_line($hookfile, $new_line);
    is $changed, 1,
        '_update_package_line() returns 1 when it changes the package line';

    my $content = get_file($hookfile);
    like $content, qr/^\Q$new_line\E\n/m,
        '_update_package_line() rewrites the file with the new package declaration';

    my $noop = $cc->_update_package_line($hookfile, $new_line);
    is $noop, 0,
        '_update_package_line() returns 0 when the package line is already current';

    my $nopackage = "$tmp/no_package.pm";
    put_file($nopackage, "# no package line here\nuse strict;\n1;\n");

    my $nopkg_result = $cc->_update_package_line($nopackage, $new_line);
    is $nopkg_result, 0,
        '_update_package_line() returns 0 when no package line exists in the file';

    my $nopackage_content = get_file($nopackage);
    unlike $nopackage_content, qr/^\Q$new_line\E/m,
        '_update_package_line() does not inject a package line into a file that lacks one';
};

# ---------------------------------------------------------------------------
# _update_version - kit.yml version update
# ---------------------------------------------------------------------------
subtest '_update_version - kit.yml version update' => sub {
    plan tests => 2;

    my $vdir = "$tmp/_update_version";
    system("mkdir -p $vdir");

    put_file("$vdir/kit.yml", <<'YAML');
name:    test
version: 0.0.1
author:  Test Author <test@example.com>
code:    https://github.com/genesis-community/test-genesis-kit
YAML

    my $cc = Genesis::Kit::Compiler->new($vdir);
    $cc->_update_version("2.8.0");

    my $content = get_file("$vdir/kit.yml");

    like $content, qr/^version:\s*2\.8\.0$/m,
        '_update_version() writes the new version into kit.yml';

    unlike $content, qr/^version:\s*0\.0\.1$/m,
        '_update_version() removes the old version line from kit.yml';
};

# ---------------------------------------------------------------------------
# _lookup_test_params - parameter lookup
# ---------------------------------------------------------------------------
subtest '_lookup_test_params - parameter lookup' => sub {
    plan tests => 4;

    my $pdir = "$tmp/_lookup_params_with";
    system("mkdir -p $pdir/ci");
    put_file("$pdir/ci/test_params.yml", <<'YAML');
---
params:
  base_domain: example.com
  ca_ttl: 10y
YAML

    my $cc_with = Genesis::Kit::Compiler->new($pdir);

    my $got_domain = $cc_with->_lookup_test_params('params.base_domain', 'fallback');
    is $got_domain, 'example.com',
        '_lookup_test_params returns the YAML value for an existing dotted key';

    my $got_missing = $cc_with->_lookup_test_params('params.cert_ttl', 'DEFAULT_TTL');
    is $got_missing, 'DEFAULT_TTL',
        '_lookup_test_params returns the supplied default for a missing key';

    my $ndir = "$tmp/_lookup_params_without";
    system("mkdir -p $ndir");

    my $cc_without = Genesis::Kit::Compiler->new($ndir);

    my $got_nofile = $cc_without->_lookup_test_params('params.base_domain', 'MY_DEFAULT');
    is $got_nofile, 'MY_DEFAULT',
        '_lookup_test_params returns the default when ci/test_params.yml does not exist';

    my $got_cached = $cc_without->_lookup_test_params('params.base_domain', 'MY_DEFAULT');
    is $got_cached, 'MY_DEFAULT',
        '_lookup_test_params returns a consistent result on repeated calls (cached state)';
};

###############################################################################
# VALIDATION TESTS
###############################################################################

# ---------------------------------------------------------------------------
# validate() - root directory checks
# ---------------------------------------------------------------------------
subtest 'validate() - root directory does not exist' => sub {
    my ($kitdir, $cc) = init_kit_repo();
    system("rm -rf $kitdir");

    my $out = combined_from {
        local $ENV{GENESIS_OUTPUT_COLUMNS} = 999;
        ok(!$cc->validate('test', '1.2.3'),
            "validate() returns 0 when root directory does not exist");
    };
    $out =~ s/\Q$tmp\E/<tempdir>/;
    eq_or_diff($out, <<'EOF', "validate() reports source directory not found");

[ERROR] Kit source directory '<tempdir>/test-genesis-kit' not found.

EOF
};

# ---------------------------------------------------------------------------
# validate() - kit.yml presence and structure
# ---------------------------------------------------------------------------
subtest 'validate() - missing kit.yml' => sub {
    my ($kitdir, $cc) = init_kit_repo();
    unlink "$kitdir/kit.yml";
    commit_kit_changes($kitdir);

    my $out = combined_from {
        ok(!$cc->validate('test', '1.2.3'),
            "validate() returns 0 when kit.yml is missing");
    };
    eq_or_diff($out, <<'EOF', "validate() reports kit.yml does not exist");

[ERROR] Encountered issues while processing kit test/1.2.3:

        Kit Metadata file kit.yml:
        - does not exist.

EOF
};

subtest 'validate() - kit.yml is a YAML list, not a map' => sub {
    my ($kitdir, $cc) = init_kit_repo();
    put_file("$kitdir/kit.yml", "---\n[]");
    commit_kit_changes($kitdir);

    my $out = combined_from {
        ok(!$cc->validate('test', '1.2.3'),
            "validate() returns 0 when kit.yml is a YAML list");
    };
    eq_or_diff($out, <<'EOF', "validate() reports kit.yml is not a well-formed YAML map");

[ERROR] Encountered issues while processing kit test/1.2.3:

        Kit Metadata file kit.yml:
        - is not a well-formed YAML file with a map root.

EOF
};

subtest 'validate() - kit.yml is an empty map' => sub {
    my ($kitdir, $cc) = init_kit_repo();
    put_file("$kitdir/kit.yml", "---\n{}");
    commit_kit_changes($kitdir);

    my $out = combined_from {
        ok(!$cc->validate('test', '1.2.3'),
            "validate() returns 0 when kit.yml is an empty map");
    };
    eq_or_diff($out, <<'EOF', "validate() reports all required keys missing from empty kit.yml");

[ERROR] Encountered issues while processing kit test/1.2.3:

        Kit Metadata file kit.yml:
        - does not define 'name'
        - does not define 'version'
        - does not define 'code'
        - does not identify the author(s) via 'author' or 'authors'

EOF
};

# ---------------------------------------------------------------------------
# validate() - missing individual required keys
# ---------------------------------------------------------------------------
subtest 'validate() - missing individual required keys' => sub {
    for my $field (qw(name version code author)) {
        my ($kitdir, $cc) = init_kit_repo();
        remove("$kitdir/kit.yml", qr/^$field:/);
        commit_kit_changes($kitdir);

        my $out = combined_from {
            ok(!$cc->validate('test', '1.2.3'),
                "validate() returns 0 when '$field' is omitted from kit.yml");
        };

        my $expected_fragment = $field eq 'author'
            ? "identify the author(s) via 'author' or 'authors'"
            : "define '$field'";

        eq_or_diff($out, <<"EOF", "validate() reports missing '$field' key");

[ERROR] Encountered issues while processing kit test/1.2.3:

        Kit Metadata file kit.yml:
        - does not $expected_fragment

EOF
    }
};

# ---------------------------------------------------------------------------
# validate() - kit name mismatch
# ---------------------------------------------------------------------------
subtest 'validate() - kit name mismatch' => sub {
    my ($kitdir, $cc) = init_kit_repo();
    put_file("$kitdir/kit.yml", <<'EOF');
name:    wrong-name
version: 1.2.3
author:  jhunt
code:    https://www.genesisproject.io
EOF
    commit_kit_changes($kitdir);

    my $out = combined_from {
        ok(!$cc->validate('test', '1.2.3'),
            "validate() returns 0 when kit name in kit.yml does not match the expected name");
    };
    eq_or_diff($out, <<'EOF', "validate() reports name mismatch between kit.yml and argument");

[ERROR] Encountered issues while processing kit test/1.2.3:

        Kit Metadata file kit.yml:
        - specifies name 'wrong-name', expecting 'test'

EOF
};

# ---------------------------------------------------------------------------
# validate() - authorship variants
# ---------------------------------------------------------------------------
subtest 'validate() - authors array is accepted' => sub {
    my ($kitdir, $cc) = init_kit_repo();
    put_file("$kitdir/kit.yml", <<'EOF');
name:    test
version: 1.2.3
authors: [jhunt, dbell]
code:    https://www.genesisproject.io
EOF
    commit_kit_changes($kitdir);

    my $out = combined_from {
        ok($cc->validate('test', '1.2.3'),
            "validate() returns 1 when authors array is used instead of author");
    };
    eq_or_diff($out, '', "validate() produces no output when authors array is valid");
};

subtest 'validate() - both author and authors together are rejected' => sub {
    my ($kitdir, $cc) = init_kit_repo();
    put_file("$kitdir/kit.yml", <<'EOF');
name:    test
version: 1.2.3
authors: [jhunt, dbell]
author:  ghost
code:    https://www.genesisproject.io
EOF
    commit_kit_changes($kitdir);

    my $out = combined_from {
        ok(!$cc->validate('test', '1.2.3'),
            "validate() returns 0 when both author and authors are present");
    };
    eq_or_diff($out, <<'EOF', "validate() reports conflict between author and authors");

[ERROR] Encountered issues while processing kit test/1.2.3:

        Kit Metadata file kit.yml:
        - specifies both 'author' and 'authors': pick one.

EOF
};

subtest 'validate() - authors as a string (not array) is rejected' => sub {
    my ($kitdir, $cc) = init_kit_repo();
    put_file("$kitdir/kit.yml", <<'EOF');
name:    test
version: 1.2.3
authors: |-
  jhunt
  dbell
code:    https://www.genesisproject.io
EOF
    commit_kit_changes($kitdir);

    my $out = combined_from {
        ok(!$cc->validate('test', '1.2.3'),
            "validate() returns 0 when authors is a string rather than an array");
    };
    eq_or_diff($out, <<'EOF', "validate() reports authors must be an array");

[ERROR] Encountered issues while processing kit test/1.2.3:

        Kit Metadata file kit.yml:
        - expects 'authors' to be an array, not a string.

EOF
};

# ---------------------------------------------------------------------------
# validate() - structural field types
# ---------------------------------------------------------------------------
subtest 'validate() - exclude_paths as a string is rejected' => sub {
    my ($kitdir, $cc) = init_kit_repo();
    put_file("$kitdir/kit.yml", <<'EOF');
name:         test
version:      1.2.3
author:       jhunt
code:         https://www.genesisproject.io
exclude_paths: "ci devtools"
EOF
    commit_kit_changes($kitdir);

    my $out = combined_from {
        ok(!$cc->validate('test', '1.2.3'),
            "validate() returns 0 when exclude_paths is a string instead of an array");
    };
    eq_or_diff($out, <<'EOF', "validate() reports exclude_paths must be an array");

[ERROR] Encountered issues while processing kit test/1.2.3:

        Kit Metadata file kit.yml:
        - expects 'exclude_paths' to be an array, not a string.

EOF
};

# ---------------------------------------------------------------------------
# validate() - genesis_version_min checks
# ---------------------------------------------------------------------------
subtest 'validate() - non-semver genesis_version_min is rejected' => sub {
    my ($kitdir, $cc) = init_kit_repo();
    put_file("$kitdir/kit.yml", <<'EOF');
name:   test
version: 1.2.3
author: jhunt
code:   https://www.genesisproject.io

genesis_version_min: latest
EOF
    commit_kit_changes($kitdir);

    my $out = combined_from {
        ok(!$cc->validate('test', '1.2.3'),
            "validate() returns 0 when genesis_version_min is not a semantic version");
    };
    eq_or_diff($out, <<'EOF', "validate() reports non-semver genesis_version_min");

[ERROR] Encountered issues while processing kit test/1.2.3:

        Kit Metadata file kit.yml:
        - specifies minimum Genesis version 'latest', which is not a semantic version (x.y.z).

EOF
};

subtest 'validate() - RC genesis_version_min rejected for non-RC kit version' => sub {
    my ($kitdir, $cc) = init_kit_repo();
    put_file("$kitdir/kit.yml", <<'EOF');
name:   test
version: 1.2.3
author: jhunt
code:   https://www.genesisproject.io

genesis_version_min: 2.8.0-rc.1
EOF
    commit_kit_changes($kitdir);

    my $out = combined_from {
        ok(!$cc->validate('test', '1.2.3'),
            "validate() returns 0 when an RC genesis_version_min is used for a non-RC kit version");
    };
    like($out, qr/Can not specify rc minimum Genesis version for compiling non-rc kit versions/,
        "validate() reports RC genesis_version_min incompatibility with non-RC kit version");
};

subtest 'validate() - genesis_min_version misspelling rejected as invalid key' => sub {
    my ($kitdir, $cc) = init_kit_repo();
    put_file("$kitdir/kit.yml", <<'EOF');
name:   test
version: 1.2.3
author: jhunt
code:   https://www.genesisproject.io

genesis_min_version: 2.6.0
EOF
    commit_kit_changes($kitdir);

    my $out = combined_from {
        ok(!$cc->validate('test', '1.2.3'),
            "validate() returns 0 when genesis_min_version is used instead of genesis_version_min");
    };
    eq_or_diff($out, <<'EOF', "validate() reports genesis_min_version as an invalid top-level key");

[ERROR] Encountered issues while processing kit test/1.2.3:

        Kit Metadata file kit.yml:
        - contains invalid top-level key: genesis_min_version;
          valid keys are: name, version, description, code, docs, author, authors, genesis_version_min, secrets_store,
                          required_configs, exclude_paths, supports, services, credentials, certificates, provided

EOF
};

# ---------------------------------------------------------------------------
# validate() - valid and invalid top-level keys
# ---------------------------------------------------------------------------
subtest 'validate() - all known top-level keys are accepted' => sub {
    my ($kitdir, $cc) = init_kit_repo();
    put_file("$kitdir/kit.yml", <<'EOF');
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
    commit_kit_changes($kitdir);

    my $out = combined_from {
        ok($cc->validate('test', '1.2.3'),
            "validate() returns 1 when all known top-level keys are used");
    };
    eq_or_diff($out, '', "validate() produces no output when only known top-level keys are present");
};

subtest 'validate() - unknown top-level keys are rejected' => sub {
    my ($kitdir, $cc) = init_kit_repo();
    put_file("$kitdir/kit.yml", <<'EOF');
name:      test
version:   1.2.3
author:    jhunt
code:      https://www.genesisproject.io
typo_key:  oops
another:   wrong
EOF
    commit_kit_changes($kitdir);

    my $out = combined_from {
        ok(!$cc->validate('test', '1.2.3'),
            "validate() returns 0 when unknown top-level keys are present");
    };
    like($out, qr/contains invalid top-level key/,
        "validate() reports invalid top-level keys");
    like($out, qr/another.*typo_key|typo_key.*another/s,
        "validate() lists both unknown keys in the error");
};

# ---------------------------------------------------------------------------
# validate() - legacy keys rejected (CRITICAL)
# ---------------------------------------------------------------------------
subtest 'validate() - legacy keys params, subkits, features are rejected' => sub {
    my ($kitdir, $cc) = init_kit_repo();
    put_file("$kitdir/kit.yml", <<'EOF');
name:    test
version: 1.2.3
author:  tester
code:    https://example.com

params:
  base:
    - ask: What is the domain
      param: base_domain

subkits:
  - prompt: Use HA?
    subkit: ha

features:
  - name: postgres
    default: no
EOF
    commit_kit_changes($kitdir);

    my $out = combined_from {
        ok(!$cc->validate('test', '1.2.3'),
            "validate() returns 0 when legacy keys params, subkits, features are present");
    };
    like($out, qr/contains invalid top-level keys:.*features.*params.*subkits/s,
        "validate() reports all three legacy keys as invalid top-level keys");
};

# ---------------------------------------------------------------------------
# validate() - secrets specification
# ---------------------------------------------------------------------------
subtest 'validate() - vault credentials and certificates pass validation' => sub {
    my ($kitdir, $cc) = init_kit_repo();
    put_file("$kitdir/kit.yml", <<'EOF');
name:          test
version:       1.2.3
author:        jhunt
code:          https://www.genesisproject.io
secrets_store: vault

credentials:
  base:
    broker:
      password: random 64

certificates:
  base: {}
EOF
    commit_kit_changes($kitdir);

    my $out = combined_from {
        ok($cc->validate('test', '1.2.3'),
            "validate() returns 1 when vault credentials and certificates are properly specified");
    };
    eq_or_diff($out, '', "validate() produces no output for a valid vault secrets specification");
};

subtest 'validate() - credhub store rejects credentials and certificates keys' => sub {
    my ($kitdir, $cc) = init_kit_repo();
    put_file("$kitdir/kit.yml", <<'EOF');
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
    commit_kit_changes($kitdir);

    my $out = combined_from {
        ok(!$cc->validate('test', '2.0.1'),
            "validate() returns 0 when credentials or certificates are used with credhub secrets_store");
    };
    eq_or_diff($out, <<'EOF', "validate() reports credentials and certificates as invalid keys when using credhub");

[ERROR] Encountered issues while processing kit test/2.0.1:

        Kit Metadata file kit.yml:
        - contains invalid top-level keys: certificates, credentials;
          valid keys are: name, version, description, code, docs, author, authors, genesis_version_min, secrets_store,
                          required_configs, exclude_paths, supports, services

EOF
};

subtest 'validate() - invalid secrets_store value is rejected' => sub {
    my ($kitdir, $cc) = init_kit_repo();
    put_file("$kitdir/kit.yml", <<'EOF');
name:          test
version:       2.0.1
author:        dbell
code:          https://www.github.com/starkandwayne/genesis/
secrets_store: krypton
EOF
    commit_kit_changes($kitdir);

    my $out = combined_from {
        ok(!$cc->validate('test', '2.0.1'),
            "validate() returns 0 when secrets_store has an unrecognized value");
    };
    eq_or_diff($out, <<'EOF', "validate() reports invalid secrets_store value");

[ERROR] Encountered issues while processing kit test/2.0.1:

        Kit Metadata file kit.yml:
        - specifies invalid secrets_store: expecting one of 'vault' or 'credhub'

EOF
};

# ---------------------------------------------------------------------------
# validate() - hook scripts
# ---------------------------------------------------------------------------
subtest 'validate() - hook as directory is rejected' => sub {
    my ($kitdir, $cc) = init_kit_repo();
    system("mkdir -p $kitdir/hooks/info");

    my $out = combined_from {
        ok(!$cc->validate('test', '1.2.3'),
            "validate() returns 0 when a hook path is a directory rather than a file");
    };
    eq_or_diff($out, <<'EOF', "validate() reports that the hook is not a regular file");

[ERROR] Encountered issues while processing kit test/1.2.3:

        Hook scripts:
        - hooks/info is not a regular file.

EOF
};

subtest 'validate() - non-executable bash hook is rejected' => sub {
    my ($kitdir, $cc) = init_kit_repo();
    system("chmod 644 $kitdir/hooks/new");
    commit_kit_changes($kitdir);

    my $out = combined_from {
        ok(!$cc->validate('test', '1.2.3'),
            "validate() returns 0 when a bash hook script is not executable");
    };
    eq_or_diff($out, <<'EOF', "validate() reports that the hook script is not executable");

[ERROR] Encountered issues while processing kit test/1.2.3:

        Hook scripts:
        - hooks/new is not executable.

EOF
};

subtest 'validate() - missing required hook (new) is rejected' => sub {
    my ($kitdir, $cc) = init_kit_repo();
    system("rm -f $kitdir/hooks/new");
    commit_kit_changes($kitdir);

    my $out = combined_from {
        ok(!$cc->validate('test', '1.2.3'),
            "validate() returns 0 when the required 'new' hook is missing");
    };
    eq_or_diff($out, <<'EOF', "validate() reports that the required new hook is missing");

[ERROR] Encountered issues while processing kit test/1.2.3:

        Hook scripts:
        - hooks/new is missing - this hook is not optional.

EOF
};

# ---------------------------------------------------------------------------
# validate() - git working tree cleanliness
# ---------------------------------------------------------------------------
subtest 'validate() - uncommitted changes cause failure' => sub {
    my ($kitdir, $cc) = init_kit_repo();
    put_file("$kitdir/kit.yml", <<'EOF');
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

    my $out = combined_from {
        ok(!$cc->validate('test', '1.2.3'),
            "validate() returns 0 when there are uncommitted changes in the working tree");
    };
    eq_or_diff($out, <<'EOF', "validate() reports uncommitted working tree changes");

[ERROR] Encountered issues while processing kit test/1.2.3:

        Git repository status:
        - Unstaged / uncommited changes found in working directory:
             M kit.yml

          Please either stash or commit those changes before compiling your kit.

EOF
};

subtest 'validate() - committed changes pass git working tree check' => sub {
    my ($kitdir, $cc) = init_kit_repo();
    put_file("$kitdir/kit.yml", <<'EOF');
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
    commit_kit_changes($kitdir);

    my $out = combined_from {
        ok($cc->validate('test', '1.2.3'),
            "validate() returns 1 after all changes are committed");
    };
    eq_or_diff($out, '', "validate() produces no output when working tree is clean");
};

# ---------------------------------------------------------------------------
# validate() - comprehensive multi-category error reporting
# ---------------------------------------------------------------------------
subtest 'validate() - multiple error categories all appear in output' => sub {
    my ($kitdir, $cc) = init_kit_repo();

    put_file("$kitdir/kit.yml", <<'EOF');
name:    testing
version: 1.2.3
author:  jhunt
code:    https://www.genesisproject.io
bogus_key: not-valid
EOF

    system("chmod 644 $kitdir/hooks/new");

    my $out = combined_from {
        ok(!$cc->validate('test', '1.2.3'),
            "validate() returns 0 when there are errors across multiple categories");
    };

    like($out, qr/Kit Metadata file kit\.yml/,
        "validate() output includes the Kit Metadata file section");
    like($out, qr/specifies name 'testing', expecting 'test'/,
        "validate() output includes the name mismatch error");
    like($out, qr/contains invalid top-level key/,
        "validate() output includes the invalid key error");
    like($out, qr/Hook scripts/,
        "validate() output includes the Hook scripts section");
    like($out, qr/hooks\/new is not executable/,
        "validate() output includes the non-executable hook error");
    like($out, qr/Git repository status/,
        "validate() output includes the Git repository status section");
    like($out, qr/Unstaged \/ uncommited changes/,
        "validate() output includes the uncommitted changes message");
};

# ---------------------------------------------------------------------------
# _select_files - file exclusion
# ---------------------------------------------------------------------------
subtest '_select_files() - ci/ directory and .gitignore entries are excluded' => sub {
    my ($kitdir, $cc) = init_kit_repo();

    my @selected;
    lives_ok { @selected = $cc->_select_files() }
        "_select_files() lives without error on a scaffolded kit";

    ok(!(grep { $_ =~ m{^ci(?:/|$)} } @selected),
        "_select_files() excludes the ci/ directory and its contents");

    ok(!(grep { $_ eq '.gitignore' } @selected),
        "_select_files() excludes the .gitignore file");

    ok((grep { $_ eq 'kit.yml' } @selected),
        "_select_files() includes kit.yml");
    ok((grep { $_ eq 'hooks/new' } @selected),
        "_select_files() includes hooks/new");
    ok((grep { $_ eq 'hooks/blueprint' } @selected),
        "_select_files() includes hooks/blueprint");
};

###############################################################################
# COMPILE TESTS
###############################################################################

# ---------------------------------------------------------------------------
# compile() - version validation
# ---------------------------------------------------------------------------
subtest 'compile() - version validation' => sub {
    plan tests => 1;
    my ($kitdir, $cc) = init_kit_repo();
    my $out = combined_from {
        throws_ok { $cc->compile("test", "not-a-version", workdir("compile-badver")) }
            qr/Version.*not-a-version.*is not semantic-compliant/i,
            "compile() dies with non-semver version";
    };
};

# ---------------------------------------------------------------------------
# compile() - successful compilation
# ---------------------------------------------------------------------------
subtest 'compile() - successful compilation' => sub {
    plan tests => 3;
    my ($kitdir, $cc) = init_kit_repo();
    my $outdir = workdir("compile-success");
    my $result;
    my $out = combined_from {
        lives_ok { $result = $cc->compile("test", "1.2.3", $outdir, 'skip-version-updates' => 1) }
            "compile() succeeds on a valid kit";
    };
    is($result, "test-1.2.3.tar.gz",
        "compile() returns the expected tarball filename");
    ok(-f "$outdir/test-1.2.3.tar.gz",
        "compile() produces a tarball in the output directory");
};

# ---------------------------------------------------------------------------
# compile() - validation failure without force
# ---------------------------------------------------------------------------
subtest 'compile() - validation failure without force' => sub {
    plan tests => 1;
    my ($kitdir, $cc) = init_kit_repo();
    put_file("$kitdir/kit.yml", "---\nname: test\nversion: 1.2.3\nauthor: tester\n");
    commit_kit_changes($kitdir);
    my $result;
    my $out = combined_from {
        $result = $cc->compile("test", "1.2.3", workdir("compile-novalid"));
    };
    ok(!defined $result,
        "compile() returns undef when validation fails and force is not set");
};

# ---------------------------------------------------------------------------
# compile() - force option bypasses validation failure
# ---------------------------------------------------------------------------
subtest 'compile() - force option bypasses validation failure' => sub {
    plan tests => 2;
    my ($kitdir, $cc) = init_kit_repo();
    put_file("$kitdir/kit.yml", "---\nname: test\nversion: 1.2.3\nauthor: tester\n");
    commit_kit_changes($kitdir);
    my $outdir = workdir("compile-force");
    my $result;
    my $out = combined_from {
        $result = $cc->compile("test", "1.2.3", $outdir,
            force => 1, 'skip-version-updates' => 1);
    };
    ok(defined $result,
        "compile() with force => 1 returns a result despite validation failure");
    SKIP: {
        skip "no result returned, cannot check tarball file", 1
            unless defined $result;
        ok(-f "$outdir/$result",
            "compile() with force => 1 produces a tarball file");
    }
};

# ---------------------------------------------------------------------------
# compile() - tarball structure
# ---------------------------------------------------------------------------
subtest 'compile() - tarball structure' => sub {
    my ($kitdir, $cc) = init_kit_repo();
    my $outdir = workdir("compile-tarball");
    my $out = combined_from {
        lives_ok { $cc->compile("test", "1.2.3", $outdir, 'skip-version-updates' => 1) }
            "compile() succeeds for tarball structure test";
    };

    my $tarball = "$outdir/test-1.2.3.tar.gz";
    SKIP: {
        skip "tarball not created, skipping structure checks", 4
            unless -f $tarball;

        my $tar = Archive::Tar->new($tarball);
        my %files = map { $_->full_path => { mode => $_->mode, size => $_->size } }
                        $tar->get_files();

        cmp_deeply(\%files, {
            'test-1.2.3'                    => superhashof({}),
            'test-1.2.3/README.md'          => { mode => 0644,
                                                  size => -s "$kitdir/README.md" },
            'test-1.2.3/kit.yml'            => superhashof({ mode => 0644 }),
            'test-1.2.3/manifests'          => superhashof({ mode => 0755 }),
            'test-1.2.3/manifests/test.yml' => { mode => 0644,
                                                  size => -s "$kitdir/manifests/test.yml" },
            'test-1.2.3/hooks'              => superhashof({ mode => 0755 }),
            'test-1.2.3/hooks/blueprint'    => { mode => 0755,
                                                  size => -s "$kitdir/hooks/blueprint" },
            'test-1.2.3/hooks/new'          => { mode => 0755,
                                                  size => -s "$kitdir/hooks/new" },
        }, "tarball contains expected files with correct modes and sizes");

        ok(!(grep { m{^test-1\.2\.3/(?:ci|\.git|spec|devtools)/} } keys %files),
            "tarball excludes ci/, .git/, spec/, and devtools/ directories");

        my $meta;
        lives_ok { $meta = load_yaml($tar->get_content('test-1.2.3/kit.yml')) }
            "kit.yml inside tarball is valid YAML";
        # With skip-version-updates, kit.yml retains the scaffold version (0.0.1)
        is($meta->{version}, '0.0.1',
            "kit.yml inside tarball retains original version when skip-version-updates is set");
    }
};

###############################################################################
# SCAFFOLD TESTS
###############################################################################

# ---------------------------------------------------------------------------
# scaffold() - new kit generation
# ---------------------------------------------------------------------------
subtest 'scaffold() - new kit generation' => sub {
    plan tests => 11;
    my $scaffolddir = workdir("scaffold-new");
    system("rm -rf $scaffolddir");
    my $cc = Genesis::Kit::Compiler->new($scaffolddir);

    quietly { $cc->scaffold("my-kit") };

    ok(-f "$scaffolddir/.gitignore",            ".gitignore is created");
    ok(-f "$scaffolddir/kit.yml",               "kit.yml is created");
    ok(-f "$scaffolddir/README.md",             "README.md is created");
    ok(-f "$scaffolddir/manifests/my-kit.yml",  "manifests/my-kit.yml is created");
    ok(-f "$scaffolddir/hooks/new",             "hooks/new is created");
    ok(-f "$scaffolddir/hooks/blueprint",       "hooks/blueprint is created");

    ok(-x "$scaffolddir/hooks/new",             "hooks/new is executable");
    ok(-x "$scaffolddir/hooks/blueprint",       "hooks/blueprint is executable");

    my $kit_yml = get_file("$scaffolddir/kit.yml");
    like($kit_yml, qr/version:\s*0\.0\.1/,
        "kit.yml has version 0.0.1");
    like($kit_yml, qr/genesis_version_min:\s*2\.7\.0/,
        "kit.yml has genesis_version_min 2.7.0");
    like($kit_yml, qr/name:\s+my-kit/,
        "kit.yml has the correct kit name");
};

# ---------------------------------------------------------------------------
# scaffold() - refuses to overwrite existing kit
# ---------------------------------------------------------------------------
subtest 'scaffold() - refuses to overwrite existing kit' => sub {
    plan tests => 3;
    my $scaffolddir = workdir("scaffold-overwrite");
    system("rm -rf $scaffolddir; mkdir -p $scaffolddir");
    my $cc = Genesis::Kit::Compiler->new($scaffolddir);

    quietly { $cc->scaffold("test-kit") };

    ok(-f "$scaffolddir/kit.yml",
        "kit.yml exists after initial scaffold");

    unlink "$scaffolddir/README.md";

    my $out = combined_from {
        throws_ok { $cc->scaffold("test-kit") }
            qr/cowardly refusing/,
            "scaffold() refuses to overwrite when kit.yml already exists";
    };

    ok(!-f "$scaffolddir/README.md",
        "scaffold() did not re-create README.md when refusing to overwrite");
};

done_testing;
