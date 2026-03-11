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
use MIME::Base64 qw/encode_base64 decode_base64/;
use IO::Compress::Gzip qw/gzip $GzipError/;
use Archive::Tar;
use JSON::PP qw/encode_json decode_json/;
use Digest::SHA qw/sha256_hex/;

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
		has          => sub { return 0 },
		get          => sub { return '{"key":"val"}' },
		get_path     => sub { return { key => 'val' } },
		authenticate => sub { return $_[0] },
		query        => sub { return ('', 0, '') },
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
# Helper: mock env that passes $env->isa('Genesis::Env') for constructor tests
# ===========================================================================
{
	package Genesis::Env::_Mock;
	our @ISA = ('Mock');
	sub isa { return $_[1] eq 'Genesis::Env' ? 1 : $_[0]->SUPER::isa($_[1]) }
}

sub make_mock_env {
	my (%overrides) = @_;

	my $mock_vault = $overrides{vault} // Mock->new(
		has          => sub { return 0 },
		get          => sub { return '{"key":"val"}' },
		get_path     => sub { return { key => 'val' } },
		authenticate => sub { return $_[0] },
		query        => sub { return ('', 0, '') },
	);

	my $mock_deployments = $overrides{deployments} // Mock->new(
		next_sequence_number => sub { return 1 },
		reset => sub { return 1 },
	);

	return Genesis::Env::_Mock->new(
		vault        => sub { return $mock_vault },
		exodus_base  => $overrides{exodus_base} // '/secret/exodus/test-env',
		workpath     => sub { return "/tmp/test-$$-$_[1]" },
		deployments  => sub { return $mock_deployments },
		name         => 'test-env',
	);
}


# ===========================================================================
# Helper: create a real base64-gzipped tarball for artifact tests
# ===========================================================================
sub make_b64_gzipped_tarball {
	my (%files) = @_;
	my $tar = Archive::Tar->new;
	for my $name (keys %files) {
		$tar->add_data($name, $files{$name});
	}
	my $compressed;
	open(my $fh, '>', \$compressed);
	$tar->write(IO::Compress::Gzip->new($fh, Level => 9, Append => 0, AutoClose => 1));
	return encode_base64($compressed);
}


# ###########################################################################
#
# 2b: Class Constants
#
# ###########################################################################
subtest 'Class Constants' => sub {

	is(Genesis::Env::Deployment->action_succeeded,   'success',             'action_succeeded is success');

	is(Genesis::Env::Deployment->action_failed,       'failed',             'action_failed is failed');

	is(Genesis::Env::Deployment->action_pending,      'pending',            'action_pending is pending');

	is(Genesis::Env::Deployment->action_post_failed,  'post-failed',        'action_post_failed is post-failed');

	is(Genesis::Env::Deployment->action_assumed,      'assumed',            'action_assumed is assumed');

	is(Genesis::Env::Deployment->artifact_map_file,   '_artifact_map.json', 'artifact_map_file is _artifact_map.json');

	done_testing;
};


# ###########################################################################
#
# 2c: Class Helper Functions
#
# ###########################################################################
subtest 'is_a_successful_result' => sub {

	ok(Genesis::Env::Deployment::is_a_successful_result('success'),
		'success is a successful result');

	ok(Genesis::Env::Deployment::is_a_successful_result('post-failed'),
		'post-failed is a successful result');

	ok(!Genesis::Env::Deployment::is_a_successful_result('failed'),
		'failed is not a successful result');

	ok(!Genesis::Env::Deployment::is_a_successful_result('pending'),
		'pending is not a successful result');

	ok(!Genesis::Env::Deployment::is_a_successful_result('assumed'),
		'assumed is not a successful result');

	done_testing;
};

subtest 'is_a_failed_result' => sub {

	ok(Genesis::Env::Deployment::is_a_failed_result('failed'),
		'failed is a failed result');

	ok(!Genesis::Env::Deployment::is_a_failed_result('success'),
		'success is not a failed result');

	ok(!Genesis::Env::Deployment::is_a_failed_result('post-failed'),
		'post-failed is not a failed result');

	ok(!Genesis::Env::Deployment::is_a_failed_result('pending'),
		'pending is not a failed result');

	ok(!Genesis::Env::Deployment::is_a_failed_result('assumed'),
		'assumed is not a failed result');

	done_testing;
};

subtest 'user_colorized_legend' => sub {

	subtest 'no args returns all 5 roles' => sub {
		my $legend = Genesis::Env::Deployment::user_colorized_legend();
		like($legend, qr/#y\{shell\}/, 'contains shell in yellow');
		like($legend, qr/#B\{bosh\}/,  'contains bosh in bold blue');
		like($legend, qr/#m\{vault\}/, 'contains vault in magenta');
		like($legend, qr/#r\{repo\}/,  'contains repo in red');
		like($legend, qr/#c\{concourse\}/, 'contains concourse in cyan');
		done_testing;
	};

	subtest 'specific roles returns only those' => sub {
		my $legend = Genesis::Env::Deployment::user_colorized_legend('shell', 'vault');
		like($legend, qr/#y\{shell\}/, 'contains shell');
		like($legend, qr/#m\{vault\}/, 'contains vault');
		unlike($legend, qr/bosh/,  'does not contain bosh');
		unlike($legend, qr/repo/,  'does not contain repo');
		unlike($legend, qr/concourse/, 'does not contain concourse');
		done_testing;
	};

	subtest 'unknown roles are filtered out' => sub {
		my $legend = Genesis::Env::Deployment::user_colorized_legend('shell', 'nonexistent');
		like($legend, qr/#y\{shell\}/, 'contains shell');
		unlike($legend, qr/nonexistent/, 'does not contain nonexistent');
		done_testing;
	};

	done_testing;
};


# ###########################################################################
#
# 2d: Constructor new()
#
# ###########################################################################
subtest 'Constructor new()' => sub {

	subtest 'valid deploy construction' => sub {
		my $env = make_mock_env();
		my $d;
		lives_ok {
			$d = Genesis::Env::Deployment->new($env,
				action          => 'deploy',
				result          => 'success',
				reason          => 'test deployment',
				genesis_version => '3.0.0',
				user            => { shell => '/bin/bash' },
				kit             => { id => 'test/1.0', name => 'test', version => '1.0',
				                     is_dev => 0, features => [] },
				manifest        => { type => 'bosh', sha2 => 'abc123' },
			);
		} 'deploy construction succeeds';
		isa_ok($d, 'Genesis::Env::Deployment');
		is($d->action, 'deploy',  'action is deploy');
		is($d->result, 'success', 'result is success');
		ok(defined $d->timestamp, 'timestamp is set');
		done_testing;
	};

	subtest 'valid terminate construction - no kit/manifest required' => sub {
		my $env = make_mock_env();
		my $d;
		lives_ok {
			$d = Genesis::Env::Deployment->new($env,
				action          => 'terminate',
				result          => 'success',
				reason          => 'decommission',
				genesis_version => '3.0.0',
				user            => { shell => '/bin/bash' },
			);
		} 'terminate construction succeeds without kit/manifest';
		is($d->action, 'terminate', 'action is terminate');
		done_testing;
	};

	subtest 'missing required field: action' => sub {
		my $env = make_mock_env();
		# Note: C-1 known issue - action accessed before @missing check, so this
		# may produce a warning before the bug() throws
		throws_ok {
			Genesis::Env::Deployment->new($env,
				result          => 'success',
				reason          => 'test',
				genesis_version => '3.0.0',
				user            => { shell => '/bin/bash' },
			);
		} qr/Missing required fields|Argument.*isn't numeric|uninitialized/i,
			'missing action throws';
		done_testing;
	};

	subtest 'missing required field: result' => sub {
		my $env = make_mock_env();
		throws_ok {
			Genesis::Env::Deployment->new($env,
				action          => 'terminate',
				reason          => 'test',
				genesis_version => '3.0.0',
				user            => { shell => '/bin/bash' },
			);
		} qr/Missing required fields.*result/s,
			'missing result throws';
		done_testing;
	};

	subtest 'missing required field: genesis_version' => sub {
		my $env = make_mock_env();
		throws_ok {
			Genesis::Env::Deployment->new($env,
				action          => 'terminate',
				result          => 'success',
				reason          => 'test',
				user            => { shell => '/bin/bash' },
			);
		} qr/Missing required fields.*genesis_version/s,
			'missing genesis_version throws';
		done_testing;
	};

	subtest 'missing required field: reason' => sub {
		my $env = make_mock_env();
		throws_ok {
			Genesis::Env::Deployment->new($env,
				action          => 'terminate',
				result          => 'success',
				genesis_version => '3.0.0',
				user            => { shell => '/bin/bash' },
			);
		} qr/Missing required fields.*reason/s,
			'missing reason throws';
		done_testing;
	};

	subtest 'missing required field: user' => sub {
		my $env = make_mock_env();
		throws_ok {
			Genesis::Env::Deployment->new($env,
				action          => 'terminate',
				result          => 'success',
				reason          => 'test',
				genesis_version => '3.0.0',
			);
		} qr/Missing required fields.*user/s,
			'missing user throws';
		done_testing;
	};

	subtest 'missing user.shell throws' => sub {
		my $env = make_mock_env();
		throws_ok {
			Genesis::Env::Deployment->new($env,
				action          => 'terminate',
				result          => 'success',
				reason          => 'test',
				genesis_version => '3.0.0',
				user            => { repo => '/home/user/cf' },
			);
		} qr/Missing required fields.*user\.shell/s,
			'missing user.shell throws';
		done_testing;
	};

	subtest 'missing kit for deploy throws' => sub {
		my $env = make_mock_env();
		throws_ok {
			Genesis::Env::Deployment->new($env,
				action          => 'deploy',
				result          => 'success',
				reason          => 'test',
				genesis_version => '3.0.0',
				user            => { shell => '/bin/bash' },
				manifest        => { type => 'bosh', sha2 => 'abc123' },
			);
		} qr/Missing required fields.*kit/s,
			'missing kit for deploy throws';
		done_testing;
	};

	subtest 'missing kit subfields for deploy throws' => sub {
		my $env = make_mock_env();
		throws_ok {
			Genesis::Env::Deployment->new($env,
				action          => 'deploy',
				result          => 'success',
				reason          => 'test',
				genesis_version => '3.0.0',
				user            => { shell => '/bin/bash' },
				kit             => { id => 'test/1.0' },
				manifest        => { type => 'bosh', sha2 => 'abc123' },
			);
		} qr/Missing required fields.*kit\./s,
			'missing kit subfields for deploy throws';
		done_testing;
	};

	subtest 'missing manifest for deploy throws' => sub {
		my $env = make_mock_env();
		throws_ok {
			Genesis::Env::Deployment->new($env,
				action          => 'deploy',
				result          => 'success',
				reason          => 'test',
				genesis_version => '3.0.0',
				user            => { shell => '/bin/bash' },
				kit             => { id => 'test/1.0', name => 'test', version => '1.0',
				                     is_dev => 0, features => [] },
			);
		} qr/Missing required fields.*manifest/s,
			'missing manifest for deploy throws';
		done_testing;
	};

	subtest 'missing manifest subfields for deploy throws' => sub {
		my $env = make_mock_env();
		throws_ok {
			Genesis::Env::Deployment->new($env,
				action          => 'deploy',
				result          => 'success',
				reason          => 'test',
				genesis_version => '3.0.0',
				user            => { shell => '/bin/bash' },
				kit             => { id => 'test/1.0', name => 'test', version => '1.0',
				                     is_dev => 0, features => [] },
				manifest        => { type => 'bosh' },
			);
		} qr/Missing required fields.*manifest\.sha2/s,
			'missing manifest.sha2 for deploy throws';
		done_testing;
	};

	subtest 'kit and manifest NOT required for terminate' => sub {
		my $env = make_mock_env();
		lives_ok {
			Genesis::Env::Deployment->new($env,
				action          => 'terminate',
				result          => 'success',
				reason          => 'decommission',
				genesis_version => '3.0.0',
				user            => { shell => '/bin/bash' },
			);
		} 'terminate does not require kit or manifest';
		done_testing;
	};

	subtest 'invalid action throws' => sub {
		my $env = make_mock_env();
		throws_ok {
			Genesis::Env::Deployment->new($env,
				action          => 'explode',
				result          => 'success',
				reason          => 'test',
				genesis_version => '3.0.0',
				user            => { shell => '/bin/bash' },
			);
		} qr/Invalid action 'explode'.*must be one of/s,
			'invalid action throws with expected message';
		done_testing;
	};

	subtest 'invalid result throws' => sub {
		my $env = make_mock_env();
		throws_ok {
			Genesis::Env::Deployment->new($env,
				action          => 'terminate',
				result          => 'banana',
				reason          => 'test',
				genesis_version => '3.0.0',
				user            => { shell => '/bin/bash' },
			);
		} qr/Invalid result 'banana'.*must be one of/s,
			'invalid result throws with expected message';
		done_testing;
	};

	subtest 'non-Genesis::Env object throws' => sub {
		my $not_env = Mock->new(name => 'fake');
		throws_ok {
			Genesis::Env::Deployment->new($not_env,
				action          => 'deploy',
				result          => 'success',
				reason          => 'test',
				genesis_version => '3.0.0',
				user            => { shell => '/bin/bash' },
				kit             => { id => 'test/1.0', name => 'test', version => '1.0',
				                     is_dev => 0, features => [] },
				manifest        => { type => 'bosh', sha2 => 'abc123' },
			);
		} qr/Expected Genesis::Env object/,
			'non-Genesis::Env env throws';
		done_testing;
	};

	subtest 'undef env throws' => sub {
		throws_ok {
			Genesis::Env::Deployment->new(undef,
				action          => 'deploy',
				result          => 'success',
				reason          => 'test',
				genesis_version => '3.0.0',
				user            => { shell => '/bin/bash' },
			);
		} qr/Expected Genesis::Env object.*undefined/s,
			'undef env throws';
		done_testing;
	};

	subtest 'invalid artifacts format (arrayref) throws' => sub {
		my $env = make_mock_env();
		throws_ok {
			Genesis::Env::Deployment->new($env,
				action          => 'terminate',
				result          => 'success',
				reason          => 'test',
				genesis_version => '3.0.0',
				user            => { shell => '/bin/bash' },
				artifacts       => ['not', 'a', 'hashref'],
			);
		} qr/Invalid artifacts format/,
			'arrayref artifacts throws';
		done_testing;
	};

	subtest 'invalid artifacts format (non-gzip string) throws' => sub {
		my $env = make_mock_env();
		throws_ok {
			Genesis::Env::Deployment->new($env,
				action          => 'terminate',
				result          => 'success',
				reason          => 'test',
				genesis_version => '3.0.0',
				user            => { shell => '/bin/bash' },
				artifacts       => 'just a plain string that is not gzipped data',
			);
		} qr/Invalid artifacts format/,
			'non-gzip string artifacts throws';
		done_testing;
	};

	subtest 'legacy state conversion: deployed' => sub {
		my $env = make_mock_env();
		my $d;
		lives_ok {
			$d = Genesis::Env::Deployment->new($env,
				state  => 'deployed',
				reason => 'legacy import',
			);
		} 'legacy deployed state construction succeeds';
		is($d->action, 'deploy',  'state deployed maps to action deploy');
		is($d->result, 'success', 'legacy state sets result to success');
		done_testing;
	};

	subtest 'legacy state conversion: terminated' => sub {
		my $env = make_mock_env();
		my $d;
		lives_ok {
			$d = Genesis::Env::Deployment->new($env,
				state  => 'terminated',
				reason => 'legacy import',
			);
		} 'legacy terminated state construction succeeds';
		is($d->action, 'terminate', 'state terminated maps to action terminate');
		done_testing;
	};

	subtest 'optional started/completed as Time::Piece preserved' => sub {
		my $env = make_mock_env();
		my $started   = Time::Piece->strptime('2024-06-01 10:00:00', '%Y-%m-%d %H:%M:%S');
		my $completed = Time::Piece->strptime('2024-06-01 10:05:00', '%Y-%m-%d %H:%M:%S');
		my $d = Genesis::Env::Deployment->new($env,
			action          => 'terminate',
			result          => 'success',
			reason          => 'test',
			genesis_version => '3.0.0',
			user            => { shell => '/bin/bash' },
			started         => $started,
			completed       => $completed,
		);
		isa_ok($d->started,   'Time::Piece', 'started is Time::Piece');
		isa_ok($d->completed, 'Time::Piece', 'completed is Time::Piece');
		done_testing;
	};

	subtest 'artifacts as hashref stored as local-file-hash format' => sub {
		my $env = make_mock_env();
		my $d = Genesis::Env::Deployment->new($env,
			action          => 'terminate',
			result          => 'success',
			reason          => 'test',
			genesis_version => '3.0.0',
			user            => { shell => '/bin/bash' },
			artifacts       => { manifest => '/tmp/some-file.yml' },
		);
		is($d->{artifacts}{format}, 'local-file-hash', 'hashref artifacts stored as local-file-hash');
		done_testing;
	};

	subtest 'artifacts as b64-gzipped string stored correctly' => sub {
		my $env = make_mock_env();
		my $b64 = make_b64_gzipped_tarball('test.txt' => 'hello world');
		my $d = Genesis::Env::Deployment->new($env,
			action          => 'terminate',
			result          => 'success',
			reason          => 'test',
			genesis_version => '3.0.0',
			user            => { shell => '/bin/bash' },
			artifacts       => $b64,
		);
		is($d->{artifacts}{format}, 'b64-gzipped', 'b64-gzipped artifacts stored correctly');
		done_testing;
	};

	subtest 'all result types accepted' => sub {
		my $env = make_mock_env();
		for my $result (qw/success failed pending post-failed assumed/) {
			lives_ok {
				Genesis::Env::Deployment->new($env,
					action          => 'terminate',
					result          => $result,
					reason          => 'test',
					genesis_version => '3.0.0',
					user            => { shell => '/bin/bash' },
				);
			} "result '$result' is accepted";
		}
		done_testing;
	};

	done_testing;
};


# ###########################################################################
#
# 2e: Instance Methods - Basic Accessors
#
# ###########################################################################
subtest 'action()' => sub {

	my $d1 = make_deployment(data => {
		action => 'deploy', result => 'success', reason => 'test',
		genesis_version => '3.0.0',
		user => { shell => '/bin/bash' },
		kit => { id => 'test/1.0', name => 'test', version => '1.0', is_dev => 0, features => [] },
		manifest => { type => 'bosh', sha2 => 'abc123' },
	});
	is($d1->action, 'deploy', 'action returns deploy');

	my $d2 = make_deployment(data => {
		action => 'terminate', result => 'success', reason => 'test',
		genesis_version => '3.0.0',
		user => { shell => '/bin/bash' },
	});
	is($d2->action, 'terminate', 'action returns terminate');

	done_testing;
};

subtest 'result()' => sub {

	for my $result (qw/success failed pending post-failed assumed/) {
		my $d = make_deployment(data => {
			action => 'terminate', result => $result, reason => 'test',
			genesis_version => '3.0.0',
			user => { shell => '/bin/bash' },
		});
		is($d->result, $result, "result returns '$result'");
	}

	done_testing;
};

subtest 'succeeded()' => sub {

	my $d_success = make_deployment(data => {
		action => 'deploy', result => 'success', reason => 'test',
		genesis_version => '3.0.0',
		user => { shell => '/bin/bash' },
		kit => { id => 'test/1.0', name => 'test', version => '1.0', is_dev => 0, features => [] },
		manifest => { type => 'bosh', sha2 => 'abc123' },
	});
	ok($d_success->succeeded, 'succeeded returns true for success');

	my $d_post = make_deployment(data => {
		action => 'deploy', result => 'post-failed', reason => 'test',
		genesis_version => '3.0.0',
		user => { shell => '/bin/bash' },
		kit => { id => 'test/1.0', name => 'test', version => '1.0', is_dev => 0, features => [] },
		manifest => { type => 'bosh', sha2 => 'abc123' },
	});
	ok($d_post->succeeded, 'succeeded returns true for post-failed');

	my $d_failed = make_deployment(data => {
		action => 'deploy', result => 'failed', reason => 'test',
		genesis_version => '3.0.0',
		user => { shell => '/bin/bash' },
		kit => { id => 'test/1.0', name => 'test', version => '1.0', is_dev => 0, features => [] },
		manifest => { type => 'bosh', sha2 => 'abc123' },
	});
	ok(!$d_failed->succeeded, 'succeeded returns false for failed');

	my $d_pending = make_deployment(data => {
		action => 'deploy', result => 'pending', reason => 'test',
		genesis_version => '3.0.0',
		user => { shell => '/bin/bash' },
		kit => { id => 'test/1.0', name => 'test', version => '1.0', is_dev => 0, features => [] },
		manifest => { type => 'bosh', sha2 => 'abc123' },
	});
	ok(!$d_pending->succeeded, 'succeeded returns false for pending');

	my $d_assumed = make_deployment(data => {
		action => 'deploy', result => 'assumed', reason => 'test',
		genesis_version => '3.0.0',
		user => { shell => '/bin/bash' },
		kit => { id => 'test/1.0', name => 'test', version => '1.0', is_dev => 0, features => [] },
		manifest => { type => 'bosh', sha2 => 'abc123' },
	});
	ok(!$d_assumed->succeeded, 'succeeded returns false for assumed');

	done_testing;
};

subtest 'has_error() and error()' => sub {

	subtest 'with error set' => sub {
		my $d = make_deployment(data => {
			action => 'deploy', result => 'failed', reason => 'test',
			genesis_version => '3.0.0',
			user => { shell => '/bin/bash' },
			kit => { id => 'test/1.0', name => 'test', version => '1.0', is_dev => 0, features => [] },
			manifest => { type => 'bosh', sha2 => 'abc123' },
			error => 'vault connection refused',
		});
		ok($d->has_error, 'has_error returns true when error is set');
		is($d->error, 'vault connection refused', 'error returns the error message');
		done_testing;
	};

	subtest 'without error set' => sub {
		my $d = make_deployment();
		ok(!$d->has_error, 'has_error returns false when no error');
		is($d->error, '', 'error returns empty string when no error');
		done_testing;
	};

	subtest 'with undef error' => sub {
		my $d = make_deployment(data => {
			action => 'deploy', result => 'success', reason => 'test',
			genesis_version => '3.0.0',
			user => { shell => '/bin/bash' },
			kit => { id => 'test/1.0', name => 'test', version => '1.0', is_dev => 0, features => [] },
			manifest => { type => 'bosh', sha2 => 'abc123' },
			error => undef,
		});
		ok(!$d->has_error, 'has_error returns false for undef error');
		is($d->error, '', 'error returns empty string for undef');
		done_testing;
	};

	done_testing;
};

subtest 'started() and completed()' => sub {

	subtest 'returns Time::Piece objects' => sub {
		my $d = make_deployment();
		isa_ok($d->started,   'Time::Piece', 'started returns Time::Piece');
		isa_ok($d->completed, 'Time::Piece', 'completed returns Time::Piece');
		done_testing;
	};

	subtest 'formatted with strftime' => sub {
		my $d = make_deployment();
		is($d->started('%Y-%m-%d %H:%M:%S'),   '2024-01-15 14:30:00', 'started formats correctly');
		is($d->completed('%Y-%m-%d %H:%M:%S'),  '2024-01-15 14:35:22', 'completed formats correctly');
		done_testing;
	};

	subtest 'bail on format with non-Time::Piece started' => sub {
		my $d = make_deployment(data => {
			action => 'deploy', result => 'success', reason => 'test',
			genesis_version => '3.0.0',
			started => 'not-a-time-piece',
			completed => Time::Piece->strptime('2024-01-15 14:35:22', '%Y-%m-%d %H:%M:%S'),
			user => { shell => '/bin/bash' },
			kit => { id => 'test/1.0', name => 'test', version => '1.0', is_dev => 0, features => [] },
			manifest => { type => 'bosh', sha2 => 'abc123' },
		});
		throws_ok { $d->started('%Y-%m-%d') }
			qr/Cannot format started timestamp/,
			'bails when formatting non-TP started';
		done_testing;
	};

	subtest 'bail on format with non-Time::Piece completed' => sub {
		my $d = make_deployment(data => {
			action => 'deploy', result => 'success', reason => 'test',
			genesis_version => '3.0.0',
			started => Time::Piece->strptime('2024-01-15 14:30:00', '%Y-%m-%d %H:%M:%S'),
			completed => 'not-a-time-piece',
			user => { shell => '/bin/bash' },
			kit => { id => 'test/1.0', name => 'test', version => '1.0', is_dev => 0, features => [] },
			manifest => { type => 'bosh', sha2 => 'abc123' },
		});
		throws_ok { $d->completed('%Y-%m-%d') }
			qr/Cannot format completed timestamp/,
			'bails when formatting non-TP completed';
		done_testing;
	};

	subtest 'returns raw value without format arg' => sub {
		my $d = make_deployment(data => {
			action => 'deploy', result => 'success', reason => 'test',
			genesis_version => '3.0.0',
			started => 'just-a-string',
			completed => undef,
			user => { shell => '/bin/bash' },
			kit => { id => 'test/1.0', name => 'test', version => '1.0', is_dev => 0, features => [] },
			manifest => { type => 'bosh', sha2 => 'abc123' },
		});
		is($d->started, 'just-a-string', 'started returns raw value without format');
		is($d->completed, undef, 'completed returns undef without format');
		done_testing;
	};

	done_testing;
};

subtest 'duration()' => sub {

	subtest 'correct calculation' => sub {
		my $d = make_deployment();
		is($d->duration, 322, 'duration is 322 seconds (5m22s)');
		done_testing;
	};

	subtest 'undef when started missing' => sub {
		my $d = make_deployment(data => {
			action => 'deploy', result => 'success', reason => 'test',
			genesis_version => '3.0.0',
			started => undef,
			completed => Time::Piece->strptime('2024-01-15 14:35:22', '%Y-%m-%d %H:%M:%S'),
			user => { shell => '/bin/bash' },
			kit => { id => 'test/1.0', name => 'test', version => '1.0', is_dev => 0, features => [] },
			manifest => { type => 'bosh', sha2 => 'abc123' },
		});
		is($d->duration, undef, 'duration returns undef when started is missing');
		done_testing;
	};

	subtest 'undef when completed missing' => sub {
		my $d = make_deployment(data => {
			action => 'deploy', result => 'success', reason => 'test',
			genesis_version => '3.0.0',
			started => Time::Piece->strptime('2024-01-15 14:30:00', '%Y-%m-%d %H:%M:%S'),
			completed => undef,
			user => { shell => '/bin/bash' },
			kit => { id => 'test/1.0', name => 'test', version => '1.0', is_dev => 0, features => [] },
			manifest => { type => 'bosh', sha2 => 'abc123' },
		});
		is($d->duration, undef, 'duration returns undef when completed is missing');
		done_testing;
	};

	subtest 'undef when timestamps are not Time::Piece' => sub {
		my $d = make_deployment(data => {
			action => 'deploy', result => 'success', reason => 'test',
			genesis_version => '3.0.0',
			started => 'string-not-tp',
			completed => 'string-not-tp',
			user => { shell => '/bin/bash' },
			kit => { id => 'test/1.0', name => 'test', version => '1.0', is_dev => 0, features => [] },
			manifest => { type => 'bosh', sha2 => 'abc123' },
		});
		is($d->duration, undef, 'duration returns undef when timestamps are strings');
		done_testing;
	};

	done_testing;
};

subtest 'reason() and has_reason()' => sub {

	subtest 'real reason' => sub {
		my $d = make_deployment();
		is($d->reason, 'test deployment', 'reason returns the reason string');
		ok($d->has_reason, 'has_reason is true for real reason');
		done_testing;
	};

	subtest 'no reason defaults to unknown' => sub {
		my $d = make_deployment(data => {
			action => 'deploy', result => 'success',
			genesis_version => '3.0.0',
			user => { shell => '/bin/bash' },
			kit => { id => 'test/1.0', name => 'test', version => '1.0', is_dev => 0, features => [] },
			manifest => { type => 'bosh', sha2 => 'abc123' },
		});
		is($d->reason, 'unknown', 'reason returns unknown when not set');
		done_testing;
	};

	subtest 'placeholder reasons are not meaningful' => sub {
		for my $placeholder ('unknown', '<unspecified>', 'none', 'null') {
			my $d = make_deployment(data => {
				action => 'deploy', result => 'success', reason => $placeholder,
				genesis_version => '3.0.0',
				user => { shell => '/bin/bash' },
				kit => { id => 'test/1.0', name => 'test', version => '1.0', is_dev => 0, features => [] },
				manifest => { type => 'bosh', sha2 => 'abc123' },
			});
			is($d->has_reason, 0, "has_reason is 0 for placeholder '$placeholder'");
		}
		done_testing;
	};

	subtest 'undef reason' => sub {
		my $d = make_deployment(data => {
			action => 'deploy', result => 'success', reason => undef,
			genesis_version => '3.0.0',
			user => { shell => '/bin/bash' },
			kit => { id => 'test/1.0', name => 'test', version => '1.0', is_dev => 0, features => [] },
			manifest => { type => 'bosh', sha2 => 'abc123' },
		});
		is($d->has_reason, 0, 'has_reason is 0 for undef reason');
		done_testing;
	};

	done_testing;
};

subtest 'lookup()' => sub {

	my $d = make_deployment();

	is($d->lookup('kit.name'),    'test',      'lookup kit.name');
	is($d->lookup('kit.version'), '1.0',       'lookup kit.version');
	is($d->lookup('user.shell'),  '/bin/bash',  'lookup user.shell');
	is($d->lookup('manifest.type'), 'bosh',    'lookup manifest.type');
	is($d->lookup('action'),      'deploy',    'lookup action (top-level)');
	is($d->lookup('nonexistent'), undef,       'lookup nonexistent returns undef');

	done_testing;
};

subtest 'timestamp()' => sub {

	my $d = make_deployment();
	is($d->timestamp, '20240115143000', 'timestamp returns the EXODUS_TIME_FORMAT_SHORT string');

	my $d2 = make_deployment(timestamp => '20250301120000');
	is($d2->timestamp, '20250301120000', 'timestamp returns custom value');

	done_testing;
};

subtest 'sequence()' => sub {

	subtest 'returns value when set' => sub {
		my $d = make_deployment(data => {
			action => 'deploy', result => 'success', reason => 'test',
			genesis_version => '3.0.0',
			user => { shell => '/bin/bash' },
			kit => { id => 'test/1.0', name => 'test', version => '1.0', is_dev => 0, features => [] },
			manifest => { type => 'bosh', sha2 => 'abc123' },
			sequence => 42,
		});
		is($d->sequence, 42, 'sequence returns the stored value');
		done_testing;
	};

	subtest 'returns undef when not set' => sub {
		my $d = make_deployment();
		is($d->sequence, undef, 'sequence returns undef when not set');
		done_testing;
	};

	done_testing;
};

subtest 'user_description()' => sub {

	subtest 'shell only' => sub {
		my $d = make_deployment();
		is($d->user_description, '/bin/bash', 'shell-only description');
		done_testing;
	};

	subtest 'shell with additional roles' => sub {
		my $d = make_deployment(data => {
			action => 'deploy', result => 'success', reason => 'test',
			genesis_version => '3.0.0',
			user => {
				shell => '/bin/zsh',
				repo  => '/home/user/cf',
				vault => 'https://vault.example.com',
			},
			kit => { id => 'test/1.0', name => 'test', version => '1.0', is_dev => 0, features => [] },
			manifest => { type => 'bosh', sha2 => 'abc123' },
		});
		my $desc = $d->user_description;
		like($desc, qr{^/bin/zsh \[}, 'description starts with shell');
		like($desc, qr{repo: /home/user/cf}, 'description includes repo');
		like($desc, qr{vault: https://vault\.example\.com}, 'description includes vault');
		done_testing;
	};

	subtest 'tmux session info stripped' => sub {
		my $d = make_deployment(data => {
			action => 'deploy', result => 'success', reason => 'test',
			genesis_version => '3.0.0',
			user => { shell => '/bin/bash (tmux(1234)session-name)' },
			kit => { id => 'test/1.0', name => 'test', version => '1.0', is_dev => 0, features => [] },
			manifest => { type => 'bosh', sha2 => 'abc123' },
		});
		is($d->user_description, '/bin/bash', 'tmux info stripped from description');
		done_testing;
	};

	subtest 'unknown roles excluded' => sub {
		my $d = make_deployment(data => {
			action => 'deploy', result => 'success', reason => 'test',
			genesis_version => '3.0.0',
			user => { shell => '/bin/bash', repo => 'unknown' },
			kit => { id => 'test/1.0', name => 'test', version => '1.0', is_dev => 0, features => [] },
			manifest => { type => 'bosh', sha2 => 'abc123' },
		});
		is($d->user_description, '/bin/bash', 'unknown repo excluded from description');
		done_testing;
	};

	done_testing;
};

subtest 'user_colorized_roles()' => sub {

	subtest 'scalar context returns role string' => sub {
		my $d = make_deployment(data => {
			action => 'deploy', result => 'success', reason => 'test',
			genesis_version => '3.0.0',
			user => { shell => '/bin/bash', repo => '/home/user/cf' },
			kit => { id => 'test/1.0', name => 'test', version => '1.0', is_dev => 0, features => [] },
			manifest => { type => 'bosh', sha2 => 'abc123' },
		});
		my $roles = $d->user_colorized_roles;
		like($roles, qr/#y\{\/bin\/bash\}/, 'contains yellow shell');
		like($roles, qr/#r\{\/home\/user\/cf\}/, 'contains red repo');
		done_testing;
	};

	subtest 'list context returns role string and role names' => sub {
		my $d = make_deployment(data => {
			action => 'deploy', result => 'success', reason => 'test',
			genesis_version => '3.0.0',
			user => { shell => '/bin/bash', vault => 'https://vault.example.com' },
			kit => { id => 'test/1.0', name => 'test', version => '1.0', is_dev => 0, features => [] },
			manifest => { type => 'bosh', sha2 => 'abc123' },
		});
		my ($role_str, @role_names) = $d->user_colorized_roles;
		like($role_str, qr/#y\{/, 'role string contains yellow markup');
		ok(scalar(grep { $_ eq 'shell' } @role_names), 'role names include shell');
		ok(scalar(grep { $_ eq 'vault' } @role_names), 'role names include vault');
		done_testing;
	};

	subtest 'unknown fallback when no roles' => sub {
		my $d = make_deployment(data => {
			action => 'deploy', result => 'success', reason => 'test',
			genesis_version => '3.0.0',
			user => {},
			kit => { id => 'test/1.0', name => 'test', version => '1.0', is_dev => 0, features => [] },
			manifest => { type => 'bosh', sha2 => 'abc123' },
		});
		my $roles = $d->user_colorized_roles;
		is($roles, '#ki{unknown}', 'returns #ki{unknown} when no roles found');
		done_testing;
	};

	subtest 'tmux stripped from colorized roles' => sub {
		my $d = make_deployment(data => {
			action => 'deploy', result => 'success', reason => 'test',
			genesis_version => '3.0.0',
			user => { shell => '/bin/bash (tmux(5678)mysession)' },
			kit => { id => 'test/1.0', name => 'test', version => '1.0', is_dev => 0, features => [] },
			manifest => { type => 'bosh', sha2 => 'abc123' },
		});
		my $roles = $d->user_colorized_roles;
		like($roles, qr/#y\{\/bin\/bash\}/, 'tmux info stripped');
		unlike($roles, qr/tmux/, 'no tmux in colorized output');
		done_testing;
	};

	done_testing;
};

subtest 'env()' => sub {

	my $d = make_deployment();
	my $env = $d->env;
	ok(defined $env, 'env returns defined value');
	is($env->name, 'test-env', 'env returns the mock env object');

	done_testing;
};


# ###########################################################################
#
# 2f: committed() and commit()
#
# ###########################################################################
subtest 'committed()' => sub {

	subtest 'vault->has true returns true' => sub {
		my $ok_vault = Mock->new(
			has => sub { return 1 },
		);
		my $d = make_deployment(vault => $ok_vault);
		ok($d->committed, 'committed returns true when vault->has is true');
		done_testing;
	};

	subtest 'vault->has false returns 0' => sub {
		my $no_vault = Mock->new(
			has => sub { return 0 },
		);
		my $d = make_deployment(vault => $no_vault);
		is($d->committed, 0, 'committed returns 0 when vault->has is false');
		done_testing;
	};

	subtest 'vault throws returns 0' => sub {
		my $error_vault = Mock->new(
			has => sub { die "vault connection refused" },
		);
		my $d = make_deployment(vault => $error_vault);
		my $result;
		lives_ok { $result = $d->committed() } 'committed does not die on vault error';
		is($result, 0, 'committed returns 0 when vault throws');
		done_testing;
	};

	subtest 'no timestamp returns 0' => sub {
		my $d = make_deployment(timestamp => undef);
		is($d->committed, 0, 'committed returns 0 when timestamp is undef');
		done_testing;
	};

	subtest 'empty timestamp returns 0' => sub {
		my $d = make_deployment(timestamp => '');
		is($d->committed, 0, 'committed returns 0 when timestamp is empty');
		done_testing;
	};

	done_testing;
};

subtest 'commit()' => sub {

	subtest 'scalar context returns 1 on success' => sub {
		my $ok_vault = Mock->new(
			has          => sub { return 0 },
			authenticate => sub { return $_[0] },
			query        => Mock::ReferencedValue->new(['', 0, '']),
		);
		my $mock_deployments = Mock->new(
			next_sequence_number => sub { return 1 },
			reset => sub { return 1 },
		);
		my $d = make_deployment(vault => $ok_vault, deployments => $mock_deployments);
		my $result;
		lives_ok { $result = $d->commit() } 'commit succeeds in scalar context';
		is($result, 1, 'commit returns 1 in scalar context');
		done_testing;
	};

	subtest 'list context returns ($out, $rc, $err)' => sub {
		my $ok_vault = Mock->new(
			has          => sub { return 0 },
			authenticate => sub { return $_[0] },
			query        => Mock::ReferencedValue->new(['output-data', 0, '']),
		);
		my $mock_deployments = Mock->new(
			next_sequence_number => sub { return 2 },
			reset => sub { return 1 },
		);
		my $d = make_deployment(vault => $ok_vault, deployments => $mock_deployments);
		my ($out, $rc, $err) = $d->commit();
		is($rc, 0, 'commit returns rc=0 in list context');
		is($out, 'output-data', 'commit returns out in list context');
		is($err, '', 'commit returns err in list context');
		done_testing;
	};

	subtest 'already committed throws' => sub {
		my $committed_vault = Mock->new(
			has => sub { return 1 },
		);
		my $d = make_deployment(vault => $committed_vault);
		throws_ok { $d->commit() }
			qr/Cannot commit a deployment that already exists/s,
			'commit throws when already committed';
		done_testing;
	};

	subtest 'vault error in scalar context throws' => sub {
		my $fail_vault = Mock->new(
			has          => sub { return 0 },
			authenticate => sub { return $_[0] },
			query        => Mock::ReferencedValue->new(['vault error output', 1, 'connection refused']),
		);
		my $mock_deployments = Mock->new(
			next_sequence_number => sub { return 1 },
			reset => sub { return 1 },
		);
		my $d = make_deployment(vault => $fail_vault, deployments => $mock_deployments);
		throws_ok { $d->commit() }
			qr/Failed to set deployment audit data in exodus/s,
			'commit throws in scalar context on vault error';
		done_testing;
	};

	subtest 'handles local-file-hash artifacts' => sub {
		my $tmpdir = tempdir(CLEANUP => 1);
		my $manifest_file = "$tmpdir/test-env.yml";
		open my $fh, '>', $manifest_file or die "Cannot create $manifest_file: $!";
		print $fh "---\nname: test-env\n";
		close $fh;

		my $ok_vault = Mock->new(
			has          => sub { return 0 },
			authenticate => sub { return $_[0] },
			query        => Mock::ReferencedValue->new(['', 0, '']),
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
		$d->{env}->{workpath} = sub {
			$artifact_path = "$tmpdir/$_[1]";
			return $artifact_path;
		};
		lives_ok { $d->commit() } 'commit succeeds with local-file-hash artifacts';
		ok(!-f $artifact_path, 'temp artifact file cleaned up')
			if defined $artifact_path;
		done_testing;
	};

	subtest 'cleans up temp files on failure' => sub {
		my $tmpdir = tempdir(CLEANUP => 1);
		my $manifest_file = "$tmpdir/test-env.yml";
		open my $fh, '>', $manifest_file or die "Cannot create: $!";
		print $fh "---\nname: test-env\n";
		close $fh;

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
		dies_ok { $d->commit() } 'commit dies on vault error';
		ok(!-f $artifact_path, 'temp artifact file cleaned up after failure')
			if defined $artifact_path;
		done_testing;
	};

	done_testing;
};


# ###########################################################################
#
# 2g: Artifact Methods
#
# ###########################################################################

# Create a shared b64-gzipped tarball for artifact tests
my $test_manifest_content = "---\nname: test-env\nreleases:\n  - name: test\n";
my $test_log_content = "Deploying test-env...\nDone.\n";
my $test_artifact_map = {
	manifest => 'test-env.yml',
	log      => 'test-env-output.log',
};
my $b64_tarball = make_b64_gzipped_tarball(
	'test-env.yml'        => $test_manifest_content,
	'test-env-output.log' => $test_log_content,
	'_artifact_map.json'  => encode_json($test_artifact_map),
);

sub make_artifact_deployment {
	my (%overrides) = @_;
	return make_deployment(
		artifacts => $overrides{artifacts} // {
			format => 'b64-gzipped',
			data   => $b64_tarball,
		},
		%overrides,
	);
}

subtest 'artifact_types()' => sub {

	subtest 'sorted list of types' => sub {
		my $d = make_artifact_deployment();
		my @types = $d->artifact_types;
		is_deeply(\@types, ['log', 'manifest'], 'artifact_types returns sorted list');
		done_testing;
	};

	subtest 'empty when no artifacts' => sub {
		my $d = make_deployment();
		my @types = $d->artifact_types;
		is(scalar @types, 0, 'artifact_types is empty with no artifacts');
		done_testing;
	};

	done_testing;
};

subtest 'artifact_filenames()' => sub {

	subtest 'sorted list of filenames' => sub {
		my $d = make_artifact_deployment();
		my @filenames = $d->artifact_filenames;
		is_deeply(\@filenames, ['test-env-output.log', 'test-env.yml'],
			'artifact_filenames returns sorted list');
		done_testing;
	};

	subtest 'empty when no artifacts' => sub {
		my $d = make_deployment();
		my @filenames = $d->artifact_filenames;
		is(scalar @filenames, 0, 'artifact_filenames is empty with no artifacts');
		done_testing;
	};

	done_testing;
};

subtest 'artifact()' => sub {

	subtest 'by type' => sub {
		my $d = make_artifact_deployment();
		my $content = $d->artifact('manifest');
		is($content, $test_manifest_content, 'artifact by type returns correct content');
		done_testing;
	};

	subtest 'by filename' => sub {
		my $d = make_artifact_deployment();
		my $content = $d->artifact('test-env-output.log');
		is($content, $test_log_content, 'artifact by filename returns correct content');
		done_testing;
	};

	subtest 'missing artifact throws' => sub {
		my $d = make_artifact_deployment();
		throws_ok { $d->artifact('nonexistent') }
			qr/Invalid artifacts requested|artifact.*not found/,
			'missing artifact throws';
		done_testing;
	};

	subtest 'no arg throws' => sub {
		my $d = make_artifact_deployment();
		throws_ok { $d->artifact('') }
			qr/Artifact name is required/,
			'empty artifact name throws';
		throws_ok { $d->artifact(undef) }
			qr/Artifact name is required/,
			'undef artifact name throws';
		done_testing;
	};

	done_testing;
};

subtest 'artifacts()' => sub {

	subtest 'all artifacts' => sub {
		my $d = make_artifact_deployment();
		my $all = $d->artifacts;
		ok(ref($all) eq 'HASH', 'artifacts returns hashref');
		is($all->{manifest}, $test_manifest_content, 'manifest content correct');
		is($all->{log}, $test_log_content, 'log content correct');
		done_testing;
	};

	subtest 'subset of artifacts' => sub {
		my $d = make_artifact_deployment();
		my $subset = $d->artifacts('manifest');
		ok(exists $subset->{manifest}, 'subset contains manifest');
		ok(!exists $subset->{log}, 'subset does not contain log');
		done_testing;
	};

	subtest 'empty when no artifacts' => sub {
		my $d = make_deployment();
		my $result = $d->artifacts;
		is_deeply($result, {}, 'artifacts returns {} when no artifacts');
		done_testing;
	};

	subtest 'invalid artifact throws' => sub {
		my $d = make_artifact_deployment();
		throws_ok { $d->artifacts('nonexistent') }
			qr/Invalid artifacts requested/,
			'invalid artifact name throws';
		done_testing;
	};

	done_testing;
};

subtest 'details_for_artifacts()' => sub {

	subtest 'list context returns list' => sub {
		my $d = make_artifact_deployment();
		my @details = $d->details_for_artifacts('manifest');
		is(scalar @details, 1, 'one detail returned');
		is($details[0]->{type}, 'manifest', 'type is manifest');
		is($details[0]->{filename}, 'test-env.yml', 'filename is test-env.yml');
		is($details[0]->{size}, length($test_manifest_content), 'size matches content length');
		is($details[0]->{content}, $test_manifest_content, 'content matches');
		ok(defined $details[0]->{sha2}, 'sha2 is defined for non-empty content');
		is($details[0]->{sha2}, sha256_hex($test_manifest_content), 'sha2 matches expected hash');
		done_testing;
	};

	subtest 'scalar context returns arrayref' => sub {
		my $d = make_artifact_deployment();
		my $details = $d->details_for_artifacts('manifest');
		is(ref($details), 'ARRAY', 'scalar context returns arrayref');
		is(scalar @$details, 1, 'one element in arrayref');
		done_testing;
	};

	subtest 'all artifacts when no args' => sub {
		my $d = make_artifact_deployment();
		my @details = $d->details_for_artifacts;
		is(scalar @details, 2, 'two details returned for all artifacts');
		done_testing;
	};

	subtest 'sha2 is undef for empty content' => sub {
		my $empty_tarball = make_b64_gzipped_tarball(
			'empty.txt'          => '',
			'_artifact_map.json' => encode_json({ empty => 'empty.txt' }),
		);
		my $d = make_deployment(artifacts => {
			format => 'b64-gzipped',
			data   => $empty_tarball,
		});
		my @details = $d->details_for_artifacts('empty');
		is($details[0]->{sha2}, undef, 'sha2 is undef for empty content');
		is($details[0]->{size}, 0, 'size is 0 for empty content');
		done_testing;
	};

	done_testing;
};

subtest 'extract_artifacts_to()' => sub {

	subtest 'success - extracts artifacts to directory' => sub {
		my $d = make_artifact_deployment();
		my $tmpdir = tempdir(CLEANUP => 1);
		local $ENV{GENESIS_CALLER_DIR} = $tmpdir;

		my $files;
		lives_ok { $files = $d->extract_artifacts_to($tmpdir) }
			'extract_artifacts_to succeeds';
		ok(ref($files) eq 'HASH', 'returns hashref');
		ok(-f "$tmpdir/test-env.yml", 'manifest file extracted');
		ok(-f "$tmpdir/test-env-output.log", 'log file extracted');
		done_testing;
	};

	subtest 'invalid directory throws' => sub {
		my $d = make_artifact_deployment();
		local $ENV{GENESIS_CALLER_DIR} = '/tmp';
		throws_ok { $d->extract_artifacts_to("/tmp/nonexistent-dir-$$") }
			qr/is not a directory/,
			'invalid directory throws';
		done_testing;
	};

	subtest 'path separator in filename throws' => sub {
		# Create a tarball with a path separator in a mapped filename
		my $evil_tarball = make_b64_gzipped_tarball(
			'some/evil.txt'      => 'evil content',
			'_artifact_map.json' => encode_json({ evil => 'some/evil.txt' }),
		);
		my $d = make_deployment(artifacts => {
			format => 'b64-gzipped',
			data   => $evil_tarball,
		});
		my $tmpdir = tempdir(CLEANUP => 1);
		local $ENV{GENESIS_CALLER_DIR} = $tmpdir;
		throws_ok { $d->extract_artifacts_to($tmpdir) }
			qr/cannot contain path separators/s,
			'path separator in filename throws';
		done_testing;
	};

	subtest 'no artifacts returns empty hashref' => sub {
		my $d = make_deployment();
		my $tmpdir = tempdir(CLEANUP => 1);
		local $ENV{GENESIS_CALLER_DIR} = $tmpdir;
		my $files = $d->extract_artifacts_to($tmpdir);
		is_deeply($files, {}, 'no artifacts returns {}');
		done_testing;
	};

	subtest 'error message contains resolved path (FWT-726)' => sub {
		my $d = make_deployment();
		local $ENV{GENESIS_CALLER_DIR} = '/tmp';
		my $nonexistent = "nonexistent-dir-$$";
		my $expected_resolved = "/tmp/$nonexistent";
		throws_ok { $d->extract_artifacts_to($nonexistent) }
			qr/\Q$expected_resolved\E/,
			'error contains resolved absolute path';
		done_testing;
	};

	done_testing;
};


# ###########################################################################
#
# 2h: Package Variables
#
# ###########################################################################
subtest 'Package Variables' => sub {

	subtest '$user_color_map has correct mappings' => sub {
		my $map = $Genesis::Env::Deployment::user_color_map;
		is($map->{shell},     'y', 'shell maps to y (yellow)');
		is($map->{repo},      'r', 'repo maps to r (red)');
		is($map->{vault},     'm', 'vault maps to m (magenta)');
		is($map->{concourse}, 'c', 'concourse maps to c (cyan)');
		is($map->{bosh},      'B', 'bosh maps to B (bold blue)');
		done_testing;
	};

	subtest '@sorted_roles has correct order' => sub {
		is_deeply(
			\@Genesis::Env::Deployment::sorted_roles,
			[qw/shell bosh vault repo concourse/],
			'sorted_roles has correct order',
		);
		done_testing;
	};

	done_testing;
};


# ###########################################################################
#
# 2i: Internal Methods
#
# ###########################################################################
subtest '_is_base64_gzipped()' => sub {

	subtest 'valid gzip returns true' => sub {
		my $b64 = make_b64_gzipped_tarball('test.txt' => 'hello');
		ok(Genesis::Env::Deployment::_is_base64_gzipped($b64),
			'valid b64-gzipped data returns true');
		done_testing;
	};

	subtest 'plain text returns false' => sub {
		ok(!Genesis::Env::Deployment::_is_base64_gzipped('This is just plain text, not gzip'),
			'plain text returns false');
		done_testing;
	};

	subtest 'short string returns false' => sub {
		ok(!Genesis::Env::Deployment::_is_base64_gzipped('short'),
			'short string returns false');
		done_testing;
	};

	subtest 'empty/undef returns false' => sub {
		ok(!Genesis::Env::Deployment::_is_base64_gzipped(''),
			'empty string returns false');
		ok(!Genesis::Env::Deployment::_is_base64_gzipped(undef),
			'undef returns false');
		done_testing;
	};

	done_testing;
};

subtest '_get_ts_string()' => sub {

	subtest 'Time::Piece input' => sub {
		my $tp = Time::Piece->strptime('2024-01-15 14:30:00', '%Y-%m-%d %H:%M:%S');
		my $ts = Genesis::Env::Deployment::_get_ts_string($tp);
		is($ts, '20240115143000', 'Time::Piece converts to EXODUS_TIME_FORMAT_SHORT');
		done_testing;
	};

	subtest 'ISO string input without timezone' => sub {
		my $ts = Genesis::Env::Deployment::_get_ts_string('2024-01-15T14:30:00');
		is($ts, '20240115143000', 'ISO string without timezone converts correctly');
		done_testing;
	};

	subtest '+0000 suffix stripped' => sub {
		my $ts = Genesis::Env::Deployment::_get_ts_string('2024-01-15 14:30:00 +0000');
		is($ts, '20240115143000', 'space +0000 suffix stripped');
		done_testing;
	};

	subtest 'Z+0000 suffix stripped' => sub {
		my $ts = Genesis::Env::Deployment::_get_ts_string('2024-01-15T14:30:00Z+0000');
		is($ts, '20240115143000', 'Z+0000 suffix stripped');
		done_testing;
	};

	subtest 'compact format without separators' => sub {
		my $ts = Genesis::Env::Deployment::_get_ts_string('20240115143000');
		is($ts, '20240115143000', 'compact 14-digit format passes through');
		done_testing;
	};

	subtest 'invalid throws' => sub {
		throws_ok {
			Genesis::Env::Deployment::_get_ts_string('not-a-timestamp-at-all');
		} qr/Invalid timestamp format/,
			'invalid timestamp throws';
		done_testing;
	};

	subtest 'undef defaults to current time' => sub {
		my $ts;
		lives_ok { $ts = Genesis::Env::Deployment::_get_ts_string(undef) }
			'undef defaults to current time without error';
		like($ts, qr/^\d{14}$/, 'returns 14-digit timestamp string');
		done_testing;
	};

	done_testing;
};


# ###########################################################################
#
# Additional internal method tests
#
# ###########################################################################
subtest '_artifact_map()' => sub {

	subtest 'returns undef when no artifacts' => sub {
		my $d = make_deployment();
		is($d->_artifact_map, undef, '_artifact_map returns undef with no artifacts');
		done_testing;
	};

	subtest 'builds map from b64-gzipped with embedded map file' => sub {
		my $d = make_artifact_deployment();
		my $map = $d->_artifact_map;
		is(ref($map), 'HASH', '_artifact_map returns hashref');
		is($map->{manifest}, 'test-env.yml', 'manifest maps to test-env.yml');
		is($map->{log}, 'test-env-output.log', 'log maps to test-env-output.log');
		done_testing;
	};

	subtest 'builds map from b64-gzipped without map file using regex' => sub {
		# Create a tarball without _artifact_map.json
		my $tarball_no_map = make_b64_gzipped_tarball(
			'test-env.yml'        => "---\nname: test-env\n",
			'test-env-output.log' => "Deploying...\n",
		);
		my $d = make_deployment(artifacts => {
			format => 'b64-gzipped',
			data   => $tarball_no_map,
		});
		my $map = $d->_artifact_map;
		is($map->{manifest}, 'test-env.yml', 'manifest matched by regex');
		is($map->{log}, 'test-env-output.log', 'log matched by regex');
		done_testing;
	};

	subtest 'builds map from local-file-hash (existing files only)' => sub {
		my $tmpdir = tempdir(CLEANUP => 1);
		my $manifest_file = "$tmpdir/test-env.yml";
		open my $fh, '>', $manifest_file or die "Cannot create: $!";
		print $fh "---\nname: test-env\n";
		close $fh;

		my $d = make_deployment(artifacts => {
			format => 'local-file-hash',
			data   => {
				manifest => $manifest_file,
				log      => "$tmpdir/nonexistent.log",
			},
		});
		my $map = $d->_artifact_map;
		is($map->{manifest}, 'test-env.yml', 'existing file included in map');
		ok(!exists $map->{log}, 'nonexistent file excluded from map');
		done_testing;
	};

	done_testing;
};

subtest '_is_artifact_type() and _is_artifact_filename()' => sub {

	my $d = make_artifact_deployment();

	ok($d->_is_artifact_type('manifest'), 'manifest is an artifact type');
	ok($d->_is_artifact_type('log'), 'log is an artifact type');
	ok(!$d->_is_artifact_type('nonexistent'), 'nonexistent is not an artifact type');
	ok(!$d->_is_artifact_type('test-env.yml'), 'filename is not a type');

	ok($d->_is_artifact_filename('test-env.yml'), 'test-env.yml is an artifact filename');
	ok($d->_is_artifact_filename('test-env-output.log'), 'test-env-output.log is a filename');
	ok(!$d->_is_artifact_filename('nonexistent.txt'), 'nonexistent.txt is not a filename');
	ok(!$d->_is_artifact_filename('manifest'), 'type name is not a filename');

	done_testing;
};

subtest '_get_artifact_type() and _get_artifact_filename()' => sub {

	my $d = make_artifact_deployment();

	is($d->_get_artifact_type('manifest'), 'manifest', 'type name returns itself');
	is($d->_get_artifact_type('test-env.yml'), 'manifest', 'filename resolves to type');

	is($d->_get_artifact_filename('manifest'), 'test-env.yml', 'type resolves to filename');
	is($d->_get_artifact_filename('test-env.yml'), 'test-env.yml', 'filename returns itself');

	done_testing;
};

subtest '_get_artifact_tarball()' => sub {

	subtest 'returns Archive::Tar for b64-gzipped' => sub {
		my $d = make_artifact_deployment();
		my $tar = $d->_get_artifact_tarball;
		isa_ok($tar, 'Archive::Tar', 'returns Archive::Tar object');
		done_testing;
	};

	subtest 'caches result' => sub {
		my $d = make_artifact_deployment();
		my $tar1 = $d->_get_artifact_tarball;
		my $tar2 = $d->_get_artifact_tarball;
		is($tar1, $tar2, 'same object returned on second call (cached)');
		done_testing;
	};

	subtest 'throws without compressed artifacts' => sub {
		my $d = make_deployment();
		throws_ok { $d->_get_artifact_tarball }
			qr/Cannot get artifact tarball.*without compressed artifacts/s,
			'throws when no compressed artifacts';
		done_testing;
	};

	done_testing;
};


done_testing;
# vim: set ts=2 sw=2 sts=2 noet:
