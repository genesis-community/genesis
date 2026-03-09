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
use File::Path qw/mkpath rmtree/;
use Time::Piece;

use Genesis;
$Genesis::VERSION = '999.999.999';
use_ok 'Genesis::Env::Deployment';

# ===========================================================================
# Helper: create a minimal deployment object by blessing directly
# (bypasses new() validation to test individual methods in isolation)
# ===========================================================================
sub make_deployment {
	my (%overrides) = @_;

	my $mock_vault = $overrides{vault} // Mock->new(
		has      => sub { return 0 },
		get      => sub { return '{"key":"val"}' },
		get_path => sub { return { key => 'val' } },
		authenticate => sub { return $_[0] },
		query    => sub { return ('', 0, '') },
	);

	my $mock_deployments = $overrides{deployments} // Mock->new(
		next_sequence_number => sub { return 1 },
		reset => sub { return 1 },
	);

	my $mock_env = Mock->new(
		vault        => sub { return $mock_vault },
		exodus_base  => $overrides{exodus_base} // '/secret/exodus/test-env',
		workpath     => sub { return "/tmp/test-$$-$_[1]" },
		deployments  => sub { return $mock_deployments },
		name         => 'test-env',
	);

	my $data = $overrides{data} // {
		action          => 'deploy',
		result          => 'success',
		reason          => 'test deployment',
		genesis_version => '3.0.0',
		started         => Time::Piece->strptime('2024-01-15 14:30:00', '%Y-%m-%d %H:%M:%S'),
		completed       => Time::Piece->strptime('2024-01-15 14:35:22', '%Y-%m-%d %H:%M:%S'),
		user            => { shell => '/bin/bash' },
		kit             => { id => 'test/1.0', name => 'test', version => '1.0',
		                     is_dev => 0, features => [] },
		manifest        => { type => 'bosh', sha2 => 'abc123' },
	};

	return bless {
		env       => $mock_env,
		timestamp => $overrides{timestamp} // '20240115143000',
		data      => $data,
		artifacts => $overrides{artifacts} // undef,
	}, 'Genesis::Env::Deployment';
}


# ===========================================================================
# FWT-723: duration() guards missing timestamps
# ===========================================================================
subtest 'FWT-723: duration() guards missing timestamps' => sub {

	subtest 'returns correct seconds with both timestamps present' => sub {
		my $d = make_deployment();
		my $duration = $d->duration();
		is($duration, 322, "duration is 5m22s = 322 seconds");
		done_testing;
	};

	subtest 'returns undef with missing started' => sub {
		my $d = make_deployment(data => {
			action => 'deploy', result => 'success', reason => 'test',
			genesis_version => '3.0.0',
			started   => undef,
			completed => Time::Piece->strptime('2024-01-15 14:35:22', '%Y-%m-%d %H:%M:%S'),
			user      => { shell => '/bin/bash' },
			kit       => { id => 'test/1.0', name => 'test', version => '1.0',
			               is_dev => 0, features => [] },
			manifest  => { type => 'bosh', sha2 => 'abc123' },
		});
		my $result;
		lives_ok { $result = $d->duration() } "duration() does not die with missing started";
		is($result, undef, "returns undef when started is missing");
		done_testing;
	};

	subtest 'returns undef with missing completed' => sub {
		my $d = make_deployment(data => {
			action => 'deploy', result => 'success', reason => 'test',
			genesis_version => '3.0.0',
			started   => Time::Piece->strptime('2024-01-15 14:30:00', '%Y-%m-%d %H:%M:%S'),
			completed => undef,
			user      => { shell => '/bin/bash' },
			kit       => { id => 'test/1.0', name => 'test', version => '1.0',
			               is_dev => 0, features => [] },
			manifest  => { type => 'bosh', sha2 => 'abc123' },
		});
		my $result;
		lives_ok { $result = $d->duration() } "duration() does not die with missing completed";
		is($result, undef, "returns undef when completed is missing");
		done_testing;
	};

	subtest 'returns undef with non-Time::Piece values' => sub {
		my $d = make_deployment(data => {
			action => 'deploy', result => 'success', reason => 'test',
			genesis_version => '3.0.0',
			started   => 'not a time::piece',
			completed => 'also not a time::piece',
			user      => { shell => '/bin/bash' },
			kit       => { id => 'test/1.0', name => 'test', version => '1.0',
			               is_dev => 0, features => [] },
			manifest  => { type => 'bosh', sha2 => 'abc123' },
		});
		my $result;
		lives_ok { $result = $d->duration() } "duration() does not die with non-Time::Piece values";
		is($result, undef, "returns undef when timestamps are not Time::Piece");
		done_testing;
	};

	done_testing;
};


# ===========================================================================
# FWT-724: committed() handles vault errors
# ===========================================================================
subtest 'FWT-724: committed() handles vault errors' => sub {

	subtest 'returns 0 when vault throws exception' => sub {
		my $error_vault = Mock->new(
			has => sub { die "vault connection refused" },
		);
		my $d = make_deployment(vault => $error_vault);
		my $result;
		lives_ok { $result = $d->committed() } "committed() does not die on vault error";
		is($result, 0, "returns 0 when vault throws");
		done_testing;
	};

	subtest 'returns true when vault->has returns true' => sub {
		my $ok_vault = Mock->new(
			has => sub { return 1 },
		);
		my $d = make_deployment(vault => $ok_vault);
		ok($d->committed(), "returns true when vault->has returns true");
		done_testing;
	};

	subtest 'returns 0 when no timestamp' => sub {
		my $d = make_deployment(timestamp => undef);
		is($d->committed(), 0, "returns 0 when timestamp is undef");

		my $d2 = make_deployment(timestamp => '');
		is($d2->committed(), 0, "returns 0 when timestamp is empty string");
		done_testing;
	};

	done_testing;
};


# ===========================================================================
# FWT-725: _collect_secrets_from_paths validates paths
# ===========================================================================
subtest 'FWT-725: _collect_secrets_from_paths validates paths' => sub {

	subtest 'valid path:key works' => sub {
		my $mock_vault = Mock->new(
			get      => sub { return 'secret_value' },
			get_path => sub { return { key => 'val' } },
		);
		my $d = make_deployment(vault => $mock_vault);
		my $result;
		lives_ok { $result = $d->_collect_secrets_from_paths('secret/path:mykey') }
			"path:key format works";
		ok(defined $result, "returns a defined result");
		done_testing;
	};

	subtest 'valid bare path works' => sub {
		my $mock_vault = Mock->new(
			get      => sub { return 'secret_value' },
			get_path => sub { return { key => 'val' } },
		);
		my $d = make_deployment(vault => $mock_vault);
		my $result;
		lives_ok { $result = $d->_collect_secrets_from_paths('secret/path') }
			"bare path format works";
		ok(defined $result, "returns a defined result");
		done_testing;
	};

	subtest 'bails on empty string path' => sub {
		my $d = make_deployment();
		throws_ok { $d->_collect_secrets_from_paths('') }
			qr/Invalid vault path|empty or undefined/i,
			"bails on empty string path";
		done_testing;
	};

	subtest 'bails on :key (no path prefix)' => sub {
		my $d = make_deployment();
		throws_ok { $d->_collect_secrets_from_paths(':mykey') }
			qr/Malformed vault path|Invalid vault path/i,
			"bails on path starting with colon";
		done_testing;
	};

	subtest 'bails on path: (trailing colon)' => sub {
		my $d = make_deployment();
		throws_ok { $d->_collect_secrets_from_paths('secret/path:') }
			qr/Malformed vault path|Invalid vault path/i,
			"bails on path ending with colon";
		done_testing;
	};

	subtest 'empty @paths returns {}' => sub {
		my $d = make_deployment();
		my $result;
		lives_ok { $result = $d->_collect_secrets_from_paths() }
			"empty paths list does not die";
		is($result, '{}', "returns empty JSON object for no paths");
		done_testing;
	};

	done_testing;
};


# ===========================================================================
# FWT-726: extract_artifacts_to shows resolved path in errors
# ===========================================================================
subtest 'FWT-726: extract_artifacts_to shows resolved path in errors' => sub {

	subtest 'error message contains resolved absolute path' => sub {
		# Use a relative path that will be resolved to an absolute path
		# The resolved path should appear in the error, not the raw relative path
		my $d = make_deployment();

		# Set GENESIS_CALLER_DIR so absolute_path resolves against it
		local $ENV{GENESIS_CALLER_DIR} = '/tmp';

		# Use a path that doesn't exist as a directory
		my $nonexistent = "nonexistent-dir-$$";
		my $expected_resolved = "/tmp/$nonexistent";

		throws_ok { $d->extract_artifacts_to($nonexistent) }
			qr/\Q$expected_resolved\E/,
			"error message contains the resolved absolute path, not the raw relative path";
		done_testing;
	};

	done_testing;
};


# ===========================================================================
# FWT-727: _build_artifacts_file rejects empty tar
# ===========================================================================
subtest 'FWT-727: _build_artifacts_file rejects empty tar' => sub {

	subtest 'bails when no artifacts would be added' => sub {
		my $d = make_deployment();

		# Provide artifact files that don't exist on disk — tar will have nothing
		my $tmpfile = "/tmp/test-artifacts-$$-empty.tgz.b64";
		throws_ok {
			$d->_build_artifacts_file(
				$tmpfile,
				manifest => "/nonexistent/path/to/manifest-$$",
				log      => "/nonexistent/path/to/log-$$",
			)
		} qr/No artifacts to archive|missing or empty/i,
			"bails when all artifact files are missing";
		unlink $tmpfile if -f $tmpfile;
		done_testing;
	};

	subtest 'succeeds when at least one artifact file exists' => sub {
		my $d = make_deployment();
		my $tmpdir = tempdir(CLEANUP => 1);
		my $artifact_file = "$tmpdir/artifacts.tgz.b64";

		# Create a real artifact file
		my $manifest_file = "$tmpdir/test-env.yml";
		open my $fh, '>', $manifest_file or die "Cannot create $manifest_file: $!";
		print $fh "---\nname: test-env\n";
		close $fh;

		lives_ok {
			$d->_build_artifacts_file(
				$artifact_file,
				manifest => $manifest_file,
			)
		} "succeeds with at least one real artifact file";
		ok(-f $artifact_file, "artifact file was created");
		done_testing;
	};

	done_testing;
};


# ===========================================================================
# FWT-728: commit() cleans up temp files on failure
# ===========================================================================
subtest 'FWT-728: commit() cleans up temp files on failure' => sub {

	subtest 'temp artifact file cleaned up after successful commit' => sub {
		my $tmpdir = tempdir(CLEANUP => 1);
		my $manifest_file = "$tmpdir/test-env.yml";
		open my $fh, '>', $manifest_file or die "Cannot create: $!";
		print $fh "---\nname: test-env\n";
		close $fh;

		# Use Mock::ReferencedValue for query to return list correctly
		# (Mock AUTOLOAD forces scalar context on CODE refs)
		my $ok_vault = Mock->new(
			has          => sub { return 0 },  # not yet committed
			authenticate => sub { return $_[0] },
			query        => Mock::ReferencedValue->new(['', 0, '']),  # success
		);
		my $mock_deployments = Mock->new(
			next_sequence_number => sub { return 1 },
			reset => sub { return 1 },
		);
		my $artifact_path;
		my $d = make_deployment(
			vault       => $ok_vault,
			deployments => $mock_deployments,
			artifacts   => {
				format => 'local-file-hash',
				data   => { manifest => $manifest_file },
			},
		);
		# Override workpath to track the temp file location
		$d->{env}->{workpath} = sub {
			$artifact_path = "$tmpdir/$_[1]";
			return $artifact_path;
		};
		lives_ok { $d->commit() } "commit succeeds";
		ok(!-f $artifact_path, "temp artifact file cleaned up after success")
			if defined $artifact_path;
		done_testing;
	};

	subtest 'temp artifact file cleaned up after vault error' => sub {
		my $tmpdir = tempdir(CLEANUP => 1);
		my $manifest_file = "$tmpdir/test-env.yml";
		open my $fh, '>', $manifest_file or die "Cannot create: $!";
		print $fh "---\nname: test-env\n";
		close $fh;

		# Use Mock::ReferencedValue for query to return list correctly
		my $fail_vault = Mock->new(
			has          => sub { return 0 },
			authenticate => sub { return $_[0] },
			query        => Mock::ReferencedValue->new(['vault error output', 1, 'connection refused']),
		);
		my $mock_deployments = Mock->new(
			next_sequence_number => sub { return 1 },
			reset => sub { return 1 },
		);
		my $artifact_path;
		my $d = make_deployment(
			vault       => $fail_vault,
			deployments => $mock_deployments,
			artifacts   => {
				format => 'local-file-hash',
				data   => { manifest => $manifest_file },
			},
		);
		$d->{env}->{workpath} = sub {
			$artifact_path = "$tmpdir/$_[1]";
			return $artifact_path;
		};
		# commit will bail in scalar context on vault failure
		dies_ok { $d->commit() } "commit dies on vault error";
		ok(!-f $artifact_path, "temp artifact file cleaned up after failure")
			if defined $artifact_path;
		done_testing;
	};

	done_testing;
};


done_testing;
# vim: set ts=2 sw=2 sts=2 noet:
