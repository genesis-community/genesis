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
use_ok 'Genesis::Kit::Compiler';

use_ok 'Genesis::Config';
$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");

use_ok 'Service::Vault::Remote';

package mockenv;
sub new {
    my ($class, @features) = @_;
    bless {
        f     => \@features,
        vault => Service::Vault::Remote->new(url => "https://localhost:8999", name => "mockvault"),
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
    my ($self, $hook) = @_;
    my %env;
    $env{GENESIS_ROOT}         = $self->path;
    $env{GENESIS_ENVIRONMENT}  = $self->name;
    $env{GENESIS_TYPE}         = $self->type;
    $env{GENESIS_TARGET_VAULT} = $env{SAFE_TARGET} = $self->vault->ref;
    $env{GENESIS_VERIFY_VAULT} = $self->vault->verify || "";
    $env{GENESIS_VAULT_PREFIX} = $env{GENESIS_SECRETS_PATH} = $self->secrets_path;
    return %env;
}
package main;

# Helper: compile the t/src/simple fixture into a Compiled kit object.
# Each call uses a fresh workdir() slot to avoid cross-test interference.
sub kit {
    my ($name, $version, $path) = @_;
    $version ||= 'latest';
    $path    ||= 't/src/simple';
    my $tmp  = workdir;
    my $file;
    quietly {
        $file = Genesis::Kit::Compiler->new($path)->compile($name, $version, $tmp, force => 1);
    };
    return Genesis::Kit::Compiled->new(
        name    => $name,
        version => $version,
        archive => "$tmp/$file",
    );
}

# ---------------------------------------------------------------------------
# new() — constructor / blessed object
# ---------------------------------------------------------------------------
subtest 'new() returns a blessed Genesis::Kit::Compiled object' => sub {
    my $kit;
    lives_ok {
        $kit = kit('mykit', '1.0.0');
    } 'new() lives with valid arguments';

    ok defined($kit),                        'new() returns a defined value';
    isa_ok $kit, 'Genesis::Kit::Compiled',   'returned object is a Genesis::Kit::Compiled';
    isa_ok $kit, 'Genesis::Kit',             'returned object inherits from Genesis::Kit';
};

# ---------------------------------------------------------------------------
# new() — archive path stored correctly
# ---------------------------------------------------------------------------
subtest 'new() stores the archive path on the object' => sub {
    my $tmp  = workdir;
    my $file;
    quietly {
        $file = Genesis::Kit::Compiler->new('t/src/simple')->compile('arch', '2.0.0', $tmp, force => 1);
    };
    my $archive_path = "$tmp/$file";

    my $kit = Genesis::Kit::Compiled->new(
        name    => 'arch',
        version => '2.0.0',
        archive => $archive_path,
    );

    is $kit->{source}, $archive_path,
        'archive path is stored in {source} field';
};

# ---------------------------------------------------------------------------
# new() — missing required parameters die
# ---------------------------------------------------------------------------
subtest 'new() dies when archive is missing' => sub {
    throws_ok {
        Genesis::Kit::Compiled->new(name => 'x', version => '1.0.0');
    } qr/Missing required option: archive/,
        'dies when archive option is absent';
};

subtest 'new() dies when archive file does not exist' => sub {
    throws_ok {
        Genesis::Kit::Compiled->new(
            name    => 'x',
            version => '1.0.0',
            archive => '/no/such/path/x-1.0.0.tar.gz',
        );
    } qr/does not exist/,
        'dies when archive file is not found on disk';
};

# ---------------------------------------------------------------------------
# new() — leading 'v' stripped from version
# ---------------------------------------------------------------------------
subtest 'new() strips leading v from version during validation' => sub {
    my $tmp  = workdir;
    my $file;
    quietly {
        $file = Genesis::Kit::Compiler->new('t/src/simple')->compile('vkit', '3.0.0', $tmp, force => 1);
    };

    # Provide the version with a leading 'v'; the validator must accept it
    # and the object must store the normalised (no-v) string.
    my $kit;
    lives_ok {
        $kit = Genesis::Kit::Compiled->new(
            name    => 'vkit',
            version => 'v3.0.0',
            archive => "$tmp/$file",
        );
    } 'new() accepts version with leading v';

    is $kit->version, '3.0.0',
        'version() returns the normalised version without leading v';
};

# ---------------------------------------------------------------------------
# id()
# ---------------------------------------------------------------------------
subtest 'id() returns name/version string' => sub {
    my $kit = kit('mykit', '1.2.3');
    is $kit->id, 'mykit/1.2.3', 'id() returns "name/version"';
};

subtest 'id() reflects the exact name and version passed to new()' => sub {
    my $kit = kit('alpha', '0.0.1');
    is $kit->id, 'alpha/0.0.1', 'id() for alpha/0.0.1';

    my $kit2 = kit('beta', '10.20.30');
    is $kit2->id, 'beta/10.20.30', 'id() for beta/10.20.30';
};

# ---------------------------------------------------------------------------
# name()
# ---------------------------------------------------------------------------
subtest 'name() returns the kit name' => sub {
    my $kit = kit('mykit', '1.0.0');
    is $kit->name, 'mykit', 'name() returns the exact name passed to new()';
};

# ---------------------------------------------------------------------------
# version()
# ---------------------------------------------------------------------------
subtest 'version() returns the kit version' => sub {
    my $kit = kit('mykit', '1.0.0');
    is $kit->version, '1.0.0', 'version() returns the exact version passed to new()';
};

subtest 'version() does not carry a leading v' => sub {
    my $tmp = workdir;
    my $file;
    quietly {
        $file = Genesis::Kit::Compiler->new('t/src/simple')->compile('vtest', '2.3.4', $tmp, force => 1);
    };
    my $kit = Genesis::Kit::Compiled->new(
        name    => 'vtest',
        version => 'v2.3.4',
        archive => "$tmp/$file",
    );
    is $kit->version, '2.3.4', 'version() strips the leading v';
    unlike $kit->version, qr/^v/, 'version() never starts with v';
};

# ---------------------------------------------------------------------------
# is_dev() — compiled kits are not dev kits
# ---------------------------------------------------------------------------
subtest 'is_dev() returns false for compiled kits' => sub {
    my $kit = kit('mykit', '1.0.0');
    ok !$kit->is_dev, 'is_dev() returns false (0) for a compiled kit';
};

# ---------------------------------------------------------------------------
# extract() — first call extracts and returns 1
# ---------------------------------------------------------------------------
subtest 'extract() performs extraction on first call' => sub {
    my $kit = kit('xkit', '1.0.0');

    my $result;
    lives_ok { $result = $kit->extract } 'extract() lives';
    is $result, 1, 'extract() returns 1 on first call';
    ok defined($kit->{root}),     'extract() sets {root} on the object';
    ok -d $kit->{root},           'extract() root is an existing directory';
};

# ---------------------------------------------------------------------------
# extract() — second call is a no-op (memoized), returns undef
# ---------------------------------------------------------------------------
subtest 'extract() is memoized — subsequent calls return undef' => sub {
    my $kit = kit('memokit', '1.0.0');
    $kit->extract;
    my $root_after_first = $kit->{root};

    my $second;
    lives_ok { $second = $kit->extract } 'second extract() call lives';
    ok !defined($second), 'second extract() call returns undef';
    is $kit->{root}, $root_after_first, 'root is unchanged after second call';
};

# ---------------------------------------------------------------------------
# extract() — expected files are present after extraction
# ---------------------------------------------------------------------------
subtest 'extract() produces expected files inside root' => sub {
    my $kit = kit('filekit', '1.0.0');
    $kit->extract;

    for my $rel (qw(kit.yml manifest.yml hooks/new hooks/blueprint)) {
        ok -f $kit->path($rel),
            "extracted file '$rel' exists";
    }
    ok -d $kit->path('hooks'), "extracted directory 'hooks/' exists";
};

# ---------------------------------------------------------------------------
# path() — works after extraction
# ---------------------------------------------------------------------------
subtest 'path() returns root directory when called with no argument' => sub {
    my $kit = kit('pkit', '1.0.0');
    $kit->extract;
    my $root = $kit->path;
    ok -d $root, 'path() with no argument returns the extracted root directory';
};

subtest 'path() appends relative path to root' => sub {
    my $kit = kit('pkit2', '1.0.0');
    $kit->extract;
    my $yml = $kit->path('kit.yml');
    like $yml, qr{kit\.yml$}, 'path("kit.yml") ends with kit.yml';
    ok -f $yml, 'path("kit.yml") resolves to an existing file';
};

subtest 'path() strips leading slashes from argument' => sub {
    my $kit = kit('pkit3', '1.0.0');
    $kit->extract;
    is $kit->path('/kit.yml'), $kit->path('kit.yml'),
        'path() with leading slash equals path() without leading slash';
};

# ---------------------------------------------------------------------------
# metadata() — returns parsed kit.yml contents
# ---------------------------------------------------------------------------
subtest 'metadata() returns a hashref with kit.yml data' => sub {
    my $kit = kit('metakit', '1.0.0');

    my $meta;
    lives_ok { $meta = $kit->metadata } 'metadata() lives';
    ok ref($meta) eq 'HASH', 'metadata() returns a hashref';
    cmp_deeply($meta, superhashof({ name => 'simple' }),
        'metadata() contains expected name key from kit.yml');
};

subtest 'metadata() is memoized — returns same hashref on repeated calls' => sub {
    my $kit = kit('metamemo', '1.0.0');
    my $first  = $kit->metadata;
    my $second = $kit->metadata;
    is $first, $second, 'metadata() returns the same reference on repeated calls';
};

# ---------------------------------------------------------------------------
# has_hook() — checks for hook existence
# ---------------------------------------------------------------------------
subtest 'has_hook() returns true for hooks that exist' => sub {
    my $kit = kit('hookkit', '1.0.0');

    ok $kit->has_hook('new'),       'has_hook("new") returns true';
    ok $kit->has_hook('blueprint'), 'has_hook("blueprint") returns true';
};

subtest 'has_hook() returns false for hooks that do not exist' => sub {
    my $kit = kit('hookkit2', '1.0.0');

    ok !$kit->has_hook('secrets'),   'has_hook("secrets") returns false';
    ok !$kit->has_hook('pre-deploy'), 'has_hook("pre-deploy") returns false';
    ok !$kit->has_hook('check'),      'has_hook("check") returns false';
};

# ---------------------------------------------------------------------------
# kit_bug() — dies with expected message content
# ---------------------------------------------------------------------------
subtest 'kit_bug() always dies' => sub {
    my $kit = kit('bugkit', '1.0.0');
    quietly {
        dies_ok { $kit->kit_bug('something went wrong') } 'kit_bug() dies';
    };
};

subtest 'kit_bug() message contains kit id' => sub {
    my $kit = kit('idkit', '1.0.0');
    quietly {
        throws_ok { $kit->kit_bug('test message') }
            qr/idkit\/1\.0\.0/,
            'kit_bug() error message contains the kit id';
    };
};

subtest 'kit_bug() message contains bug-in-kit phrase' => sub {
    my $kit = kit('phrasekit', '1.0.0');
    quietly {
        throws_ok { $kit->kit_bug('test message') }
            qr/bug .* kit/si,
            'kit_bug() error message contains "bug ... kit"';
    };
};

subtest 'kit_bug() message includes provided message text' => sub {
    my $kit = kit('msgkit', '1.0.0');
    my $custom = 'unexpected value in manifest key foo';
    quietly {
        throws_ok { $kit->kit_bug($custom) }
            qr/unexpected value in manifest key foo/i,
            'kit_bug() includes the caller-supplied message';
    };
};

subtest 'kit_bug() references GitHub issues URL for code on github' => sub {
    # The t/src/simple kit.yml has:
    #   code: https://github.com/genesis-community/simple-genesis-kit
    # so kit_bug should append the /issues link.
    my $kit = kit('githubkit', '1.0.0');
    quietly {
        throws_ok { $kit->kit_bug('some defect') }
            qr{https://github\.com/.*/issues}i,
            'kit_bug() appends GitHub issues URL when code is a GitHub repo';
    };
};

subtest 'kit_bug() sets $! to 2 (ENOENT) before dying' => sub {
    my $kit = kit('errnkit', '1.0.0');
    my $errno_val;
    quietly {
        eval { $kit->kit_bug('errno test') };
        $errno_val = 0 + $!;
    };
    is $errno_val, 2, 'kit_bug() sets $! to 2 before dying';
};

# ---------------------------------------------------------------------------
# check_prereqs() — genesis version requirement
# ---------------------------------------------------------------------------
subtest 'check_prereqs() fails when genesis version is too old' => sub {
    my $kit = kit('prereqkit', '1.0.0');
    local $Genesis::VERSION = '0.0.1';
    my $ok;
    quietly { $ok = $kit->check_prereqs };
    ok !$ok, 'check_prereqs() fails when genesis version is older than kit minimum';
};

subtest 'check_prereqs() passes when genesis version is new enough' => sub {
    my $kit = kit('prereqkit2', '1.0.0');
    local $Genesis::VERSION = '9.9.9';
    my $ok;
    quietly { $ok = $kit->check_prereqs };
    ok $ok, 'check_prereqs() passes when genesis version meets the minimum';
};

subtest 'check_prereqs() passes for dev genesis versions' => sub {
    my $kit = kit('prereqkit3', '1.0.0');
    local $Genesis::VERSION = 'dev';
    my $ok;
    quietly { $ok = $kit->check_prereqs };
    ok $ok, 'check_prereqs() passes for dev genesis versions';
};

# ---------------------------------------------------------------------------
# source_yaml_files() — returns list of YAML files for manifest generation
# ---------------------------------------------------------------------------
subtest 'source_yaml_files() returns at least one yaml file' => sub {
    my $kit  = kit('syamlkit', '1.0.0');
    my $env  = mockenv->new();
    my @files;
    lives_ok { @files = $kit->source_yaml_files($env) }
        'source_yaml_files() lives with a mock environment';
    ok scalar(@files) > 0, 'source_yaml_files() returns at least one file';
};

subtest 'source_yaml_files() returns manifest.yml for feature-less env' => sub {
    my $kit = kit('syamlkit2', '1.0.0');
    my $env = mockenv->new();
    my @files;
    quietly { @files = $kit->source_yaml_files($env) };
    cmp_deeply(
        \@files,
        [re('\bmanifest\.yml$')],
        'source_yaml_files() returns manifest.yml for a basic env'
    );
};

subtest 'source_yaml_files() is stable across calls with same features' => sub {
    my $kit = kit('stabkit', '1.0.0');
    my @f1; quietly { @f1 = $kit->source_yaml_files(mockenv->new()) };
    my @f2; quietly { @f2 = $kit->source_yaml_files(mockenv->new()) };
    cmp_deeply(\@f1, \@f2, 'source_yaml_files() returns the same result for identical inputs');
};

subtest 'source_yaml_files() ignores unknown features in simple kit' => sub {
    my $kit  = kit('ignkit', '1.0.0');
    my @base; quietly { @base = $kit->source_yaml_files(mockenv->new()) };
    my @with; quietly { @with = $kit->source_yaml_files(mockenv->new('bogus', 'unknown')) };
    cmp_deeply(\@with, \@base,
        'source_yaml_files() returns the same files regardless of unknown features');
};

# ---------------------------------------------------------------------------
# local_kits() — class method to find local kit archives
# ---------------------------------------------------------------------------
subtest 'local_kits() returns an empty hashref for an empty directory' => sub {
    my $scan_dir = workdir('local_kits_empty');
    my $result;
    lives_ok {
        $result = Genesis::Kit::Compiled->local_kits(undef, $scan_dir);
    } 'local_kits() lives with an empty directory';
    ok ref($result) eq 'HASH', 'local_kits() returns a hashref';
    is scalar(keys %$result), 0, 'local_kits() returns an empty hashref for empty dir';
};

subtest 'local_kits() finds valid kit tarballs' => sub {
    my $scan_dir = workdir('local_kits_find');
    mk_test_kit('myapp', '1.2.3', $scan_dir);

    my $result;
    lives_ok {
        $result = Genesis::Kit::Compiled->local_kits(undef, $scan_dir);
    } 'local_kits() lives with a valid kit present';

    ok exists($result->{myapp}),          'local_kits() finds kit by name';
    ok exists($result->{myapp}{'1.2.3'}), 'local_kits() finds kit by version';
    isa_ok $result->{myapp}{'1.2.3'}, 'Genesis::Kit::Compiled',
        'local_kits() entry is a Genesis::Kit::Compiled object';
};

subtest 'local_kits() finds multiple kits in the same directory' => sub {
    my $scan_dir = workdir('local_kits_multi');
    mk_test_kit('alpha', '1.0.0', $scan_dir);
    mk_test_kit('beta',  '2.0.0', $scan_dir);

    my $result = Genesis::Kit::Compiled->local_kits(undef, $scan_dir);

    ok exists($result->{alpha}{'1.0.0'}), 'local_kits() finds alpha/1.0.0';
    ok exists($result->{beta}{'2.0.0'}),  'local_kits() finds beta/2.0.0';
};

subtest 'local_kits() returns hashref structure with name => version => kit' => sub {
    my $scan_dir = workdir('local_kits_struct');
    mk_test_kit('structkit', '3.0.0', $scan_dir);

    my $result = Genesis::Kit::Compiled->local_kits(undef, $scan_dir);

    ok ref($result) eq 'HASH',                           'top level is a hashref';
    ok ref($result->{structkit}) eq 'HASH',             'name level is a hashref';
    isa_ok $result->{structkit}{'3.0.0'}, 'Genesis::Kit::Compiled',
        'version value is a Genesis::Kit::Compiled object';
};

subtest 'local_kits() skips non-matching filenames' => sub {
    my $scan_dir = workdir('local_kits_skip');
    mk_test_kit('real', '1.0.0', $scan_dir);
    put_file("$scan_dir/README.txt", "some text file");
    put_file("$scan_dir/not-a-kit", "plain file");

    my $result = Genesis::Kit::Compiled->local_kits(undef, $scan_dir);

    ok  exists($result->{real}{'1.0.0'}), 'local_kits() finds the real kit';
    ok !exists($result->{README}),        'local_kits() ignores README.txt';
};

subtest 'local_kits() strips trailing slash from path' => sub {
    my $scan_dir = workdir('local_kits_slash');
    mk_test_kit('slashkit', '1.0.0', $scan_dir);

    my $result;
    lives_ok {
        $result = Genesis::Kit::Compiled->local_kits(undef, "$scan_dir/");
    } 'local_kits() accepts path with trailing slash';
    ok exists($result->{slashkit}{'1.0.0'}),
        'local_kits() finds kit even when path has trailing slash';
};

subtest 'local_kits() skips corrupt archives and continues scanning' => sub {
    my $scan_dir = workdir('local_kits_corrupt');
    mk_test_kit('good', '1.0.0', $scan_dir);
    put_file("$scan_dir/bad-2.0.0.tar.gz",
        "<!DOCTYPE html><html><body>403</body></html>");
    mk_test_kit('also-good', '3.0.0', $scan_dir);

    my $result;
    lives_ok {
        $result = Genesis::Kit::Compiled->local_kits(undef, $scan_dir);
    } 'local_kits() does not die when a corrupt archive is present';

    ok  exists($result->{good}{'1.0.0'}),        'valid kit good/1.0.0 is found';
    ok  exists($result->{'also-good'}{'3.0.0'}), 'valid kit also-good/3.0.0 is found';
    ok !exists($result->{bad}),                  'corrupt kit bad is skipped';
};

subtest 'local_kits() defaults path to current directory when omitted' => sub {
    # We just want to ensure the method does not die when called with only
    # one argument (provider); what it actually finds is environment-dependent.
    lives_ok {
        Genesis::Kit::Compiled->local_kits(undef);
    } 'local_kits() lives when path argument is omitted';
};

# ---------------------------------------------------------------------------
# _validate_tar_archive() — internal validation
# ---------------------------------------------------------------------------
subtest '_validate_tar_archive() returns an Archive::Tar object for a valid archive' => sub {
    my $tmp = workdir('validate_ok');
    my $file = mk_test_kit('val', '1.0.0', $tmp);

    my %opts = (name => 'val', version => '1.0.0', archive => $file);
    my $tar;
    lives_ok {
        $tar = Genesis::Kit::Compiled->_validate_tar_archive(\%opts);
    } '_validate_tar_archive() lives for a valid archive';

    ok defined($tar), '_validate_tar_archive() returns a defined value';
    isa_ok $tar, 'Archive::Tar', 'returned value is an Archive::Tar object';
};

subtest '_validate_tar_archive() infers name and version when not provided' => sub {
    my $tmp = workdir('validate_infer');
    my $file = mk_test_kit('inferred', '4.5.6', $tmp);

    my %opts = (archive => $file);   # no name/version
    lives_ok {
        Genesis::Kit::Compiled->_validate_tar_archive(\%opts);
    } '_validate_tar_archive() lives without explicit name/version';

    is $opts{name},    'inferred', 'name is inferred from archive base directory';
    is $opts{version}, '4.5.6',   'version is inferred from archive base directory';
};

subtest '_validate_tar_archive() dies when name/version mismatch' => sub {
    my $tmp = workdir('validate_mismatch');
    my $file = mk_test_kit('real', '1.0.0', $tmp);

    my %opts = (name => 'wrong', version => '9.9.9', archive => $file);
    throws_ok {
        Genesis::Kit::Compiled->_validate_tar_archive(\%opts);
    } qr/does not match provided name\/version/i,
        '_validate_tar_archive() dies when name/version does not match archive';
};

done_testing;
