#!perl
use strict;
use warnings;

use Test::More;
use lib 'lib';

$ENV{GENESIS_TESTING} = "yes";
$ENV{GENESIS_LIB}     ||= 'lib';

use_ok 'Genesis::CI::Provider';
use_ok 'Genesis::CI::Provider::Concourse';
use_ok 'Genesis::CI::Provider::GithubActions';
use_ok 'Genesis::CI::Provider::Manual';

### ============================================================ ###
### Factory: Genesis::CI::Provider->new
### ============================================================ ###

subtest 'Provider->new dispatches on type' => sub {
	my $c = Genesis::CI::Provider->new(type => 'concourse', target => 'myci');
	isa_ok $c, 'Genesis::CI::Provider::Concourse', 'type=concourse';

	my $g = Genesis::CI::Provider->new(type => 'github-actions', repo => 'org/repo');
	isa_ok $g, 'Genesis::CI::Provider::GithubActions', 'type=github-actions';

	my $m = Genesis::CI::Provider->new(type => 'manual');
	isa_ok $m, 'Genesis::CI::Provider::Manual', 'type=manual';

	my $def = Genesis::CI::Provider->new();  # no type → manual
	isa_ok $def, 'Genesis::CI::Provider::Manual', 'no type → manual';
};

subtest 'Provider->new rejects unknown type' => sub {
	eval { Genesis::CI::Provider->new(type => 'bogus') };
	like $@, qr/Unknown CI provider type/i, 'unknown type bails';
};

### ============================================================ ###
### Factory: Genesis::CI::Provider->init
### ============================================================ ###

subtest 'Provider->init dispatches on ci-provider opt' => sub {
	my $c = Genesis::CI::Provider->init(
		'ci-provider' => 'concourse',
		'ci-url'      => 'https://ci.example.com',
		'ci-team'     => 'main',
	);
	isa_ok $c, 'Genesis::CI::Provider::Concourse', 'ci-provider=concourse';

	my $g = Genesis::CI::Provider->init(
		'ci-provider'      => 'github-actions',
		'ci-github-repo'   => 'myorg/myrepo',
	);
	isa_ok $g, 'Genesis::CI::Provider::GithubActions', 'ci-provider=github-actions';

	my $m = Genesis::CI::Provider->init('ci-provider' => 'manual');
	isa_ok $m, 'Genesis::CI::Provider::Manual', 'ci-provider=manual';

	my $def = Genesis::CI::Provider->init();  # no ci-provider → manual
	isa_ok $def, 'Genesis::CI::Provider::Manual', 'no ci-provider → manual';
};

subtest 'Provider->init rejects unknown type' => sub {
	eval { Genesis::CI::Provider->init('ci-provider' => 'jenkins') };
	like $@, qr/Unknown CI provider type/i, 'unknown type bails';
};

### ============================================================ ###
### parse_opts - two-pass extraction
### ============================================================ ###

subtest 'parse_opts extracts --ci-provider and general args' => sub {
	my @args = ('--ci-provider', 'concourse', '--ci-target', 'myci', 'other-arg');
	my %opts;
	Genesis::CI::Provider->parse_opts(\@args, \%opts);

	is $opts{'ci-provider'}, 'concourse', 'ci-provider extracted';
	is $opts{'ci-target'},   'myci',      'ci-target extracted';
	is_deeply \@args, ['other-arg'], 'non-option arg left in @args';
};

subtest 'parse_opts stops at -- sentinel' => sub {
	my @args = ('--ci-provider', 'concourse', '--', '--ci-target', 'x');
	my %opts;
	Genesis::CI::Provider->parse_opts(\@args, \%opts);

	is $opts{'ci-provider'}, 'concourse', 'ci-provider extracted before --';
	ok !defined $opts{'ci-target'}, 'ci-target not extracted (after --)';
	is_deeply \@args, ['--', '--ci-target', 'x'], 'args after -- preserved';
};

subtest 'parse_opts handles manual (no extra opts)' => sub {
	my @args = ('--ci-provider', 'manual', 'leftover');
	my %opts;
	Genesis::CI::Provider->parse_opts(\@args, \%opts);

	is $opts{'ci-provider'}, 'manual', 'ci-provider=manual';
	is_deeply \@args, ['leftover'], 'non-option preserved';
};

subtest 'parse_opts handles github-actions flags' => sub {
	my @args = ('--ci-provider', 'github-actions',
	            '--ci-github-repo', 'acme/deploy',
	            '--ci-github-branch', 'release');
	my %opts;
	Genesis::CI::Provider->parse_opts(\@args, \%opts);

	is $opts{'ci-provider'},      'github-actions', 'ci-provider';
	is $opts{'ci-github-repo'},   'acme/deploy',    'ci-github-repo';
	is $opts{'ci-github-branch'}, 'release',        'ci-github-branch';
	is_deeply \@args, [], 'all args consumed';
};

subtest 'parse_opts defaults to manual when no --ci-provider' => sub {
	my @args = ('other-arg');
	my %opts;
	Genesis::CI::Provider->parse_opts(\@args, \%opts);
	ok !defined $opts{'ci-provider'}, 'ci-provider undef when not supplied';
	is_deeply \@args, ['other-arg'], 'non-option preserved';
};

### ============================================================ ###
### opts_help
### ============================================================ ###

subtest 'opts_help aggregates all providers' => sub {
	my $help = Genesis::CI::Provider->opts_help();
	like $help, qr/CI PROVIDERS/,      'header present';
	like $help, qr/--ci-provider/,     'general flag documented';
	like $help, qr/concourse/,         'concourse section present';
	like $help, qr/github-actions/,    'github-actions section present';
	like $help, qr/manual/,            'manual section present';
	like $help, qr/--ci-target/,       'concourse flag in help';
	like $help, qr/--ci-github-repo/,  'gha flag in help';
};

### ============================================================ ###
### Genesis::CI::Provider::Concourse
### ============================================================ ###

subtest 'Concourse->opts returns Getopt spec' => sub {
	my @opts = Genesis::CI::Provider::Concourse->opts();
	ok grep { $_ eq 'ci-target=s' } @opts, 'ci-target=s present';
	ok grep { $_ eq 'ci-team=s'   } @opts, 'ci-team=s present';
	ok grep { $_ eq 'ci-insecure' } @opts, 'ci-insecure present';
};

subtest 'Concourse->init requires --ci-target or --ci-url+--ci-team' => sub {
	eval { Genesis::CI::Provider::Concourse->init() };
	like $@, qr/requires --ci-target/i, 'bails without ci-target or url+team';
};

subtest 'Concourse defaults team to main and insecure to 0' => sub {
	my $p = Genesis::CI::Provider::Concourse->new(type => 'concourse', target => 'ci.example.com');
	is $p->{team},    'main', 'team defaults to main';
	is $p->{insecure}, 0,     'insecure defaults to 0';
};

subtest 'Concourse->init honours all opts (new-target path)' => sub {
	my $p = Genesis::CI::Provider::Concourse->init(
		'ci-url'      => 'https://ci.example.com',
		'ci-team'     => 'platform',
		'ci-target'   => 'ci.example.com',
		'ci-insecure' => 1,
	);
	is $p->{target},   'ci.example.com', 'target set';
	is $p->{team},     'platform',       'team set';
	is $p->{insecure}, 1,                'insecure set';
};

subtest 'Concourse->config omits default team' => sub {
	my $p = Genesis::CI::Provider::Concourse->new(
		type   => 'concourse',
		target => 'myci',
	);
	my %cfg = $p->config;
	is   $cfg{type},   'concourse', 'type present';
	is   $cfg{target}, 'myci',      'target present';
	ok !exists $cfg{team},     'default team omitted';
	ok !exists $cfg{insecure}, 'insecure omitted when false';
};

subtest 'Concourse->config includes non-default team and insecure' => sub {
	my $p = Genesis::CI::Provider::Concourse->new(
		type     => 'concourse',
		target   => 'ci',
		team     => 'ops',
		insecure => 1,
	);
	my %cfg = $p->config;
	is $cfg{team},     'ops', 'non-default team in config';
	is $cfg{insecure}, 1,     'insecure in config';
};

subtest 'Concourse->label' => sub {
	my $p = Genesis::CI::Provider::Concourse->new(type => 'concourse', target => 'x');
	is $p->label, 'Concourse', 'label is Concourse';
};

subtest 'Concourse->opts_help contains required flag docs' => sub {
	my $help = Genesis::CI::Provider::Concourse->opts_help(
		valid_types => [qw(concourse)]
	);
	like $help, qr/--ci-target/,   'ci-target documented';
	like $help, qr/--ci-team/,     'ci-team documented';
	like $help, qr/--ci-insecure/, 'ci-insecure documented';
};

subtest 'Concourse->opts_help empty when not in valid_types' => sub {
	my $help = Genesis::CI::Provider::Concourse->opts_help(
		valid_types => [qw(github-actions)]
	);
	is $help, '', 'empty when concourse not in valid_types';
};

### ============================================================ ###
### Genesis::CI::Provider::GithubActions
### ============================================================ ###

subtest 'GithubActions->opts returns Getopt spec' => sub {
	my @opts = Genesis::CI::Provider::GithubActions->opts();
	ok grep { $_ eq 'ci-github-repo=s'   } @opts, 'ci-github-repo=s present';
	ok grep { $_ eq 'ci-github-branch=s' } @opts, 'ci-github-branch=s present';
};

subtest 'GithubActions->init requires --ci-github-repo' => sub {
	eval { Genesis::CI::Provider::GithubActions->init() };
	like $@, qr/requires --ci-github-repo/i, 'bails without ci-github-repo';
};

subtest 'GithubActions->init validates org/repo format' => sub {
	eval { Genesis::CI::Provider::GithubActions->init('ci-github-repo' => 'invalid-no-slash') };
	like $@, qr/org\/repo/i, 'bails on bad format';
};

subtest 'GithubActions->init defaults branch to main' => sub {
	my $p = Genesis::CI::Provider::GithubActions->init('ci-github-repo' => 'acme/deploy');
	is $p->{branch}, 'main', 'branch defaults to main';
};

subtest 'GithubActions->config omits default branch' => sub {
	my $p = Genesis::CI::Provider::GithubActions->new(
		type => 'github-actions',
		repo => 'acme/deploy',
	);
	my %cfg = $p->config;
	is   $cfg{type}, 'github-actions', 'type present';
	is   $cfg{repo}, 'acme/deploy',    'repo present';
	ok !exists $cfg{branch}, 'default branch omitted';
};

subtest 'GithubActions->config includes non-default branch' => sub {
	my $p = Genesis::CI::Provider::GithubActions->new(
		type   => 'github-actions',
		repo   => 'acme/deploy',
		branch => 'release',
	);
	my %cfg = $p->config;
	is $cfg{branch}, 'release', 'non-default branch in config';
};

subtest 'GithubActions->label' => sub {
	my $p = Genesis::CI::Provider::GithubActions->new(
		type => 'github-actions', repo => 'acme/x'
	);
	is $p->label, 'GitHub Actions', 'label is GitHub Actions';
};

### ============================================================ ###
### Genesis::CI::Provider::Manual
### ============================================================ ###

subtest 'Manual->opts returns empty list' => sub {
	my @opts = Genesis::CI::Provider::Manual->opts();
	is scalar @opts, 0, 'Manual has no opts';
};

subtest 'Manual->init returns Manual object' => sub {
	my $m = Genesis::CI::Provider::Manual->init();
	isa_ok $m, 'Genesis::CI::Provider::Manual', 'Manual->init returns Manual';
};

subtest 'Manual->config returns only type' => sub {
	my $m = Genesis::CI::Provider::Manual->new(type => 'manual');
	my %cfg = $m->config;
	is_deeply \%cfg, { type => 'manual' }, 'config is {type => manual}';
};

subtest 'Manual->label' => sub {
	my $m = Genesis::CI::Provider::Manual->new(type => 'manual');
	is $m->label, 'Manual', 'label is Manual';
};

### ============================================================ ###
### check_prereqs
### ============================================================ ###

subtest 'check_prereqs: base Provider always returns 1' => sub {
	# Base class has no prereqs; all three concrete providers inherit this
	# as a no-op default except where they override it.
	my $m = Genesis::CI::Provider::Manual->new(type => 'manual');
	ok $m->check_prereqs(), 'Manual->check_prereqs returns 1';

	my $g = Genesis::CI::Provider::GithubActions->new(
		type => 'github-actions', repo => 'acme/x'
	);
	ok $g->check_prereqs(), 'GithubActions->check_prereqs returns 1';
};

subtest 'check_prereqs: Concourse returns 1 when fly is in PATH' => sub {
	# Only run if fly is actually installed in this environment.
	my $fly = `which fly 2>/dev/null`;
	chomp $fly;
	if ($fly) {
		my $p = Genesis::CI::Provider::Concourse->new(
			type => 'concourse', target => 'test'
		);
		ok $p->check_prereqs(), 'check_prereqs returns 1 when fly is present';
	} else {
		pass 'skipped: fly not installed in this environment';
	}
};

subtest 'check_prereqs: Concourse returns 0 when fly is absent' => sub {
	# Temporarily shadow PATH so fly cannot be found.
	local $ENV{PATH} = '/nonexistent';
	my $p = Genesis::CI::Provider::Concourse->new(
		type => 'concourse', target => 'test'
	);
	my $result = $p->check_prereqs();
	ok !$result, 'check_prereqs returns 0 when fly is not in PATH';
};

subtest 'check_prereqs: Concourse min_fly_version satisfied' => sub {
	my $fly = `which fly 2>/dev/null`;
	chomp $fly;
	unless ($fly) {
		pass 'skipped: fly not installed in this environment';
		return;
	}
	# Require a minimum of 0.0.1 — any real fly version will satisfy this.
	my $p = Genesis::CI::Provider::Concourse->new(
		type           => 'concourse',
		target         => 'test',
		min_fly_version => '0.0.1',
	);
	ok $p->check_prereqs(), 'check_prereqs passes with trivially low min version';
};

subtest 'check_prereqs: Concourse min_fly_version not satisfied' => sub {
	my $fly = `which fly 2>/dev/null`;
	chomp $fly;
	unless ($fly) {
		pass 'skipped: fly not installed in this environment';
		return;
	}
	# Require an impossibly high minimum — should fail.
	my $p = Genesis::CI::Provider::Concourse->new(
		type            => 'concourse',
		target          => 'test',
		min_fly_version => '9999.0.0',
	);
	my $result = $p->check_prereqs();
	ok !$result, 'check_prereqs returns 0 when fly version too old';
};

### ============================================================ ###
### validate_config — per-provider field validation
### ============================================================ ###

subtest 'validate_config: Manual always passes' => sub {
	my $m = Genesis::CI::Provider::Manual->new(type => 'manual');
	my @errors = $m->validate_config;
	is scalar @errors, 0, 'Manual has no required fields';
};

subtest 'validate_config: Concourse passes with target' => sub {
	my $p = Genesis::CI::Provider::Concourse->new(
		type => 'concourse', target => 'my-ci',
	);
	my @errors = $p->validate_config;
	is scalar @errors, 0, 'no errors when target is present';
};

subtest 'validate_config: Concourse fails without target' => sub {
	my $p = Genesis::CI::Provider::Concourse->new(type => 'concourse');
	my @errors = $p->validate_config;
	ok scalar @errors > 0, 'errors returned when target missing';
	like $errors[0], qr/target.*required/i, 'error mentions target';
};

subtest 'validate_config: Concourse passes with target and valid url' => sub {
	my $p = Genesis::CI::Provider::Concourse->new(
		type   => 'concourse',
		target => 'my-ci',
		url    => 'https://ci.example.com',
	);
	my @errors = $p->validate_config;
	is scalar @errors, 0, 'no errors with target and valid https url';
};

subtest 'validate_config: Concourse rejects malformed url' => sub {
	my $p = Genesis::CI::Provider::Concourse->new(
		type   => 'concourse',
		target => 'my-ci',
		url    => 'not-a-url',
	);
	my @errors = $p->validate_config;
	ok scalar @errors > 0, 'error returned for malformed url';
	like $errors[0], qr/url.*http/i, 'error mentions url format';
};

subtest 'validate_config: GithubActions passes with valid repo' => sub {
	my $p = Genesis::CI::Provider::GithubActions->new(
		type => 'github-actions', repo => 'acme/deploy',
	);
	my @errors = $p->validate_config;
	is scalar @errors, 0, 'no errors when repo is valid';
};

subtest 'validate_config: GithubActions fails without repo' => sub {
	my $p = Genesis::CI::Provider::GithubActions->new(type => 'github-actions');
	my @errors = $p->validate_config;
	ok scalar @errors > 0, 'errors returned when repo missing';
	like $errors[0], qr/repo.*required/i, 'error mentions repo';
};

subtest 'validate_config: GithubActions fails on bad repo format' => sub {
	my $p = Genesis::CI::Provider::GithubActions->new(
		type => 'github-actions', repo => 'noslash',
	);
	my @errors = $p->validate_config;
	ok scalar @errors > 0, 'errors returned for bad repo format';
	like $errors[0], qr/org.repo/i, 'error mentions org/repo format';
};

subtest 'Provider->new bails when validate_config returns errors' => sub {
	# Concourse with no target should be rejected by the factory
	eval { Genesis::CI::Provider->new(type => 'concourse') };
	like $@, qr/Invalid CI provider configuration/i, 'factory bails on invalid config';
	like $@, qr/target.*required/i, 'bail message includes field-level error';
};

subtest 'Provider->new accepts valid Concourse config' => sub {
	my $p = Genesis::CI::Provider->new(type => 'concourse', target => 'prod');
	isa_ok $p, 'Genesis::CI::Provider::Concourse', 'valid Concourse config accepted';
};

subtest 'Provider->new bails on invalid GithubActions config' => sub {
	eval { Genesis::CI::Provider->new(type => 'github-actions') };
	like $@, qr/Invalid CI provider configuration/i, 'factory bails on missing repo';
};

subtest 'Provider->new accepts valid GithubActions config' => sub {
	my $p = Genesis::CI::Provider->new(type => 'github-actions', repo => 'org/repo');
	isa_ok $p, 'Genesis::CI::Provider::GithubActions', 'valid GHA config accepted';
};

done_testing;
