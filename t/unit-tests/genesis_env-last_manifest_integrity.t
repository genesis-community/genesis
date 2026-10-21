#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 't';
use helper;

use Test::More;
use Test::Deep;
use Test::Exception;
use File::Temp qw/tempdir/;
use Digest::SHA qw/sha1_hex/;

use Genesis;
use_ok 'Genesis::Config';
# Initialize $Genesis::RC for tests that consult global config
provide_rc();

use_ok 'Genesis::Top';
use_ok 'Genesis::Env';

# The integrity check guards `bosh create-env` against deploying with a state
# file that belongs to a different manifest than the one about to be deployed.
# It compares the sha1 recorded in exodus against the sha1 of the manifest in
# the local repository, both of which last_deployed_manifest already provides.

sub last_manifest {
	my (%overrides) = @_;
	return {
		source        => 'repository',
		manifest_sha1 => 'a' x 40,
		manifest      => {
			source => 'repository',
			path   => '/repo/.genesis/manifests/test-env.yml',
			sha1   => 'a' x 40,
		},
		state => {
			source => 'repository',
			path   => '/repo/.genesis/manifests/test-env-state.json',
			sha1   => 'b' x 40,
		},
		%overrides,
	};
}

# ===========================================================================
# _last_manifest_integrity_issue - matching sha1s raise no issue
# ===========================================================================
subtest 'matching sha1s raise no issue' => sub {
	local $ENV{GENESIS_TESTING} = 1;

	my $env = make_env_with_kit('t/src/simple', 'test-env');

	is($env->_last_manifest_integrity_issue(last_manifest()), undef,
		"no issue when the repository manifest matches the exodus sha1");

	done_testing;
};

# ===========================================================================
# _last_manifest_integrity_issue - genuine mismatch is reported
# ===========================================================================
subtest 'mismatched sha1s report a stale repository manifest' => sub {
	local $ENV{GENESIS_TESTING} = 1;

	my $env = make_env_with_kit('t/src/simple', 'test-env');

	my $manifest = last_manifest(manifest_sha1 => 'c' x 40);

	my $issue = $env->_last_manifest_integrity_issue($manifest);
	ok(defined($issue), "an issue is reported when the sha1s differ");
	like($issue, qr/does not match the manifest in the local repository/,
		"the issue names the mismatch");

	done_testing;
};

# ===========================================================================
# _last_manifest_integrity_issue - missing exodus sha1 is reported
# ===========================================================================
subtest 'missing exodus sha1 is reported' => sub {
	local $ENV{GENESIS_TESTING} = 1;

	my $env = make_env_with_kit('t/src/simple', 'test-env');

	for my $missing (undef, '') {
		my $issue = $env->_last_manifest_integrity_issue(
			last_manifest(manifest_sha1 => $missing)
		);
		ok(defined($issue), "an issue is reported when the exodus sha1 is missing");
		like($issue, qr/sha1 sum missing from exodus data/,
			"the issue names the missing sha1");
	}

	done_testing;
};

# ===========================================================================
# _last_manifest_integrity_issue - exodus-sourced manifests are not checked
#
# Deployment archives carry their own manifest, so there is no local copy
# that could have drifted.
# ===========================================================================
subtest 'exodus-sourced manifests skip the check' => sub {
	local $ENV{GENESIS_TESTING} = 1;

	my $env = make_env_with_kit('t/src/simple', 'test-env');

	my $manifest = last_manifest(
		source        => 'exodus-deployments',
		manifest_sha1 => 'c' x 40,
	);

	is($env->_last_manifest_integrity_issue($manifest), undef,
		"no issue for a manifest retrieved from the deployment archive");

	done_testing;
};

# ===========================================================================
# _last_manifest_integrity_issue - nothing to check without a local manifest
# ===========================================================================
subtest 'absent local manifest skips the check' => sub {
	local $ENV{GENESIS_TESTING} = 1;

	my $env = make_env_with_kit('t/src/simple', 'test-env');

	is($env->_last_manifest_integrity_issue({not_found => 1}), undef,
		"no issue when no previous manifest was found");
	is($env->_last_manifest_integrity_issue(undef), undef,
		"no issue when no manifest data is supplied at all");

	done_testing;
};

# ===========================================================================
# _deploy_create_env - the check runs against the real deploy path
#
# These drive _deploy_create_env itself, with last_deployed_manifest stubbed
# to describe files on disk and spruce_diff stubbed to stop the deploy once it
# is past the integrity check.  By default the manifest comes from exodus, as
# it does for a hybrid manifest store without deployment archives.  The
# downloaded copy lands in a work directory, while the state file and the
# manifest that was committed with it stay in the repository.  Unless a test
# asks for one, no controlling terminal is present, so any issue the check
# raises is a bail.
# ===========================================================================
sub run_create_env_check {
	my (%opts) = @_;

	my $env = make_env_with_kit('t/src/simple', 'test-env');
	my $repo = $env->path('.genesis/manifests');
	mkdir_or_fail($repo) unless -d $repo;
	my $work = tempdir(CLEANUP => 1);

	my $manifest = "name: test-env\nfoo: bar\n";
	my $sha1 = sha1_hex($manifest);
	mkfile_or_fail("$work/test-env.yml", $manifest);

	my $repo_manifest = exists($opts{repo_manifest}) ? $opts{repo_manifest} : $manifest;
	mkfile_or_fail("$repo/test-env.yml", $repo_manifest) if defined($repo_manifest);

	my $last = {
		source        => 'exodus',
		manifest_sha1 => $sha1,
		manifest      => {source => 'exodus', path => "$work/test-env.yml", sha1 => $sha1},
	};
	$last = {
		source        => 'repository',
		manifest_sha1 => $sha1,
		manifest      => {
			source => 'repository',
			path   => "$repo/test-env.yml",
			sha1   => sha1_hex($repo_manifest),
		},
	} if $opts{repository_store};
	if ($opts{with_state}) {
		my $state = qq({"director_id":"x"}\n);
		mkfile_or_fail("$repo/test-env-state.json", $state);
		$last->{state} = {
			source => 'repository',
			path   => "$repo/test-env-state.json",
			sha1   => sha1_hex($state),
		};
	}

	my @warnings;

	no warnings qw/redefine once/;
	local *Genesis::Env::last_deployed_manifest = sub { $last };
	local *Genesis::Env::_recovered_create_env_state = sub { {} };
	local *Genesis::Env::in_controlling_terminal = sub { $opts{terminal} ? 1 : 0 };
	local *Genesis::Env::prompt_for_boolean = sub { 1 };
	local *Genesis::Env::warning = sub { push @warnings, join('', @_) };
	local *Genesis::Env::spruce_diff = sub { die "REACHED DIFF\n" };
	local *Genesis::Env::_cleanup_and_bail = sub { shift; die "CLEANUP BAIL: @_\n" };

	my $err = do { local $@; eval { $env->_deploy_create_env(noprompt => 1) }; $@ } // '';
	return ($err, \@warnings);
}

subtest 'create-env with a json state file and matching manifest proceeds' => sub {
	local $ENV{GENESIS_TESTING} = 1;

	# Regression: the check used to derive the manifest path by substituting
	# `-state.yml` for `.yml`.  create-env writes `-state.json`, so the
	# substitution never fired and the check hashed the state file instead of
	# the manifest, refusing every unattended create-env redeploy.
	my ($err) = run_create_env_check(with_state => 1);
	unlike($err, qr/does not match the manifest in the local repository/,
		"a matching manifest is not reported as stale");
	like($err, qr/^REACHED DIFF/,
		"the deploy proceeds past the integrity check");

	done_testing;
};

subtest 'create-env with no state record reports the missing state file' => sub {
	local $ENV{GENESIS_TESTING} = 1;

	# Regression: with no state record the check slurped an empty path and
	# died with "failed to open '' for reading".
	my ($err) = run_create_env_check(with_state => 0, repo_manifest => undef);
	unlike($err, qr/failed to open/,
		"the check does not try to read a missing state path");
	like($err, qr/Cannot find state file for previous deployment/,
		"the deploy stops on the missing state file");

	done_testing;
};

subtest 'a stale repository manifest is reported once before proceeding' => sub {
	local $ENV{GENESIS_TESTING} = 1;

	my ($err, $warnings) = run_create_env_check(
		with_state => 1, terminal => 1, repo_manifest => "name: test-env\nfoo: old\n"
	);
	like($err, qr/^REACHED DIFF/,
		"the operator can proceed past a stale manifest from a terminal");
	is(scalar(grep {/does not match the manifest in the local repository/} @$warnings), 1,
		"the mismatch warning is shown exactly once");

	done_testing;
};

subtest 'a stale manifest from the repository store is reported once' => sub {
	local $ENV{GENESIS_TESTING} = 1;

	# Regression: the diff step repeated the integrity warnings, so an operator
	# who chose to proceed was shown the same mismatch a second time.
	my ($err, $warnings) = run_create_env_check(
		with_state => 1, terminal => 1, repository_store => 1,
		repo_manifest => "name: test-env\nfoo: old\n"
	);
	like($err, qr/^REACHED DIFF/,
		"the operator can proceed past a stale manifest from a terminal");
	is(scalar(grep {/does not match the manifest in the local repository/} @$warnings), 1,
		"the mismatch warning is shown exactly once");

	done_testing;
};

subtest 'a stale repository manifest refuses to deploy without a terminal' => sub {
	local $ENV{GENESIS_TESTING} = 1;

	# The manifest downloaded from exodus always matches the sha1 exodus
	# recorded with it, so only the repository copy can show that the state
	# file beside it is out of date.
	my ($err) = run_create_env_check(
		with_state => 1, repo_manifest => "name: test-env\nfoo: old\n"
	);
	like($err, qr/does not match the manifest in the local repository/,
		"the mismatch is reported");
	like($err, qr/Refusing to deploy to protect integrity of the environment/,
		"the deploy is refused");

	done_testing;
};

subtest 'a repository state file without its manifest refuses to deploy' => sub {
	local $ENV{GENESIS_TESTING} = 1;

	my ($err) = run_create_env_check(with_state => 1, repo_manifest => undef);
	like($err, qr/Cannot confirm the state file in the local repository/,
		"the missing repository manifest is reported");
	like($err, qr/Refusing to deploy to protect integrity of the environment/,
		"the deploy is refused");

	done_testing;
};

done_testing;
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
