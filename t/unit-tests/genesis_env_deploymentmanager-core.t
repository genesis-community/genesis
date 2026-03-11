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
use Time::Piece;
use Time::Seconds qw/ONE_DAY/;

use Genesis;
$Genesis::VERSION = '999.999.999';
use_ok 'Genesis::Env::Deployment';
use_ok 'Genesis::Env::DeploymentManager';

# ===========================================================================
# Helper: Mock package that passes Genesis::Env isa check
# ===========================================================================
{
	package Genesis::Env::_Mock;
	our @ISA = ('Mock');
	sub isa { return $_[1] eq 'Genesis::Env' ? 1 : $_[0]->SUPER::isa($_[1]) }
}

# ===========================================================================
# Helper: create a mock environment object
# ===========================================================================
sub make_mock_env {
	my (%overrides) = @_;
	my $mock_vault = $overrides{vault} // Mock->new(
		has      => sub { return 0 },
		get      => sub { return '{"key":"val"}' },
		get_path => sub { return {} },
		authenticate => sub { return $_[0] },
		query    => sub { return ('', 0, '') },
	);
	return Genesis::Env::_Mock->new(
		vault          => sub { return $mock_vault },
		exodus_base    => $overrides{exodus_base} // '/secret/exodus/test-env',
		workpath       => sub { return "/tmp/test-$$-$_[1]" },
		name           => $overrides{name} // 'test-env',
		exodus_lookup  => $overrides{exodus_lookup} // sub { return {} },
	);
}

# ===========================================================================
# Helper: create a deployment object by blessing directly (bypass new() validation)
# ===========================================================================
sub make_deployment {
	my (%overrides) = @_;
	my $mock_env = $overrides{env} // Genesis::Env::_Mock->new(
		vault       => sub { Mock->new(has => sub { 0 }) },
		exodus_base => '/secret/exodus/test-env',
		workpath    => sub { "/tmp/test-$$-$_[1]" },
		name        => 'test-env',
	);
	my $data = {
		action          => $overrides{action}  // 'deploy',
		result          => $overrides{result}  // 'success',
		reason          => $overrides{reason}  // 'test deployment',
		genesis_version => $overrides{genesis_version} // '3.0.0',
		started         => $overrides{started}   // Time::Piece->strptime('2024-01-15 14:30:00', '%Y-%m-%d %H:%M:%S'),
		completed       => $overrides{completed} // Time::Piece->strptime('2024-01-15 14:35:22', '%Y-%m-%d %H:%M:%S'),
		user            => $overrides{user} // { shell => '/bin/bash' },
		kit             => $overrides{kit}  // { id => 'test/1.0', name => 'test', version => '1.0', is_dev => 0, features => [] },
		manifest        => $overrides{manifest} // { type => 'bosh', sha2 => 'abc123' },
		($overrides{sequence} ? (sequence => $overrides{sequence}) : ()),
	};
	return bless {
		env       => $mock_env,
		timestamp => $overrides{timestamp} // '20240115143000',
		data      => $data,
		artifacts => undef,
	}, 'Genesis::Env::Deployment';
}

# ===========================================================================
# Helper: create a DeploymentManager with pre-injected deployments
# ===========================================================================
sub make_manager {
	my (%overrides) = @_;
	my $env = $overrides{env} // make_mock_env(%overrides);
	my $mgr = bless {
		env                => $env,
		__all_deployments  => $overrides{deployments},
	}, 'Genesis::Env::DeploymentManager';
	return $mgr;
}

# ===========================================================================
# Helper: generate N deployments with sequential timestamps, sorted newest-first
# ===========================================================================
sub make_deployment_set {
	my ($count, %options) = @_;
	my $base_ts = $options{base_timestamp} // '20240101120000';
	my $env = $options{env};
	my @deployments;
	for my $i (0 .. $count - 1) {
		my $ts = sprintf("%014d", $base_ts + ($i * 10000)); # ~1 hour each
		push @deployments, make_deployment(
			timestamp => $ts,
			action    => $options{actions}  ? $options{actions}[$i]  : ($options{action}  // 'deploy'),
			result    => $options{results}  ? $options{results}[$i]  : ($options{result}  // 'success'),
			sequence  => $options{sequences} ? $options{sequences}[$i] : ($i + 1),
			($env ? (env => $env) : ()),
		);
	}
	# Sort newest-first (reverse chronological)
	return [ reverse @deployments ];
}


# ===========================================================================
# Section 3b: Constructor & Basic
# ===========================================================================
subtest 'Constructor and basic accessors' => sub {

	subtest 'new() creates manager with undef cache' => sub {
		my $env = make_mock_env();
		my $mgr = Genesis::Env::DeploymentManager->new($env);
		isa_ok($mgr, 'Genesis::Env::DeploymentManager');
		is($mgr->{__all_deployments}, undef, '__all_deployments starts as undef');
		done_testing;
	};

	subtest 'env() returns environment object' => sub {
		my $env = make_mock_env(name => 'my-env');
		my $mgr = Genesis::Env::DeploymentManager->new($env);
		is($mgr->env, $env, 'env() returns the env passed to constructor');
		is($mgr->env->name, 'my-env', 'env object has correct name');
		done_testing;
	};

	subtest 'reset() clears the cache' => sub {
		my $deployments = make_deployment_set(3);
		my $mgr = make_manager(deployments => $deployments);
		ok(defined $mgr->{__all_deployments}, 'cache is populated before reset');
		$mgr->reset();
		is($mgr->{__all_deployments}, undef, 'cache is undef after reset');
		done_testing;
	};

	subtest 'reset() is idempotent' => sub {
		my $mgr = make_manager(deployments => undef);
		$mgr->reset();
		is($mgr->{__all_deployments}, undef, 'reset on already-undef cache is fine');
		$mgr->reset();
		is($mgr->{__all_deployments}, undef, 'second reset still undef');
		done_testing;
	};

	subtest 'new() then env() round-trip' => sub {
		my $env = make_mock_env();
		my $mgr = Genesis::Env::DeploymentManager->new($env);
		is(ref($mgr->env), 'Genesis::Env::_Mock', 'env is correct type');
		done_testing;
	};

	done_testing;
};


# ===========================================================================
# Section 3c: all()
# ===========================================================================
subtest 'all() method' => sub {

	subtest 'returns list of Deployment objects' => sub {
		my $deployments = make_deployment_set(3);
		my $mgr = make_manager(deployments => $deployments);
		my @all = $mgr->all();
		is(scalar @all, 3, 'all() returns 3 deployments');
		isa_ok($all[0], 'Genesis::Env::Deployment');
		done_testing;
	};

	subtest 'returns cached results on second call' => sub {
		my $deployments = make_deployment_set(2);
		my $mgr = make_manager(deployments => $deployments);
		my @first  = $mgr->all();
		my @second = $mgr->all();
		is(scalar @first, scalar @second, 'same count on repeated calls');
		is($first[0], $second[0], 'same object references (cached)');
		done_testing;
	};

	subtest 'sorted newest-first' => sub {
		my $deployments = make_deployment_set(4);
		my $mgr = make_manager(deployments => $deployments);
		my @all = $mgr->all();
		for my $i (0 .. $#all - 1) {
			cmp_ok($all[$i]->timestamp, 'ge', $all[$i+1]->timestamp,
				"deployment $i >= deployment " . ($i+1) . " by timestamp");
		}
		done_testing;
	};

	subtest 'empty deployments returns empty list' => sub {
		my $mgr = make_manager(deployments => []);
		my @all = $mgr->all();
		is(scalar @all, 0, 'empty array returns empty list');
		done_testing;
	};

	subtest 'reset causes re-fetch on next all()' => sub {
		my $deployments = make_deployment_set(2);
		my $mgr = make_manager(deployments => $deployments);
		my @before = $mgr->all();
		is(scalar @before, 2, 'initially 2 deployments');

		$mgr->reset();
		# After reset, __all_deployments is undef; inject new data
		$mgr->{__all_deployments} = make_deployment_set(5);
		my @after = $mgr->all();
		is(scalar @after, 5, 'after reset and re-inject, 5 deployments');
		done_testing;
	};

	done_testing;
};


# ===========================================================================
# Section 3d: find()
# ===========================================================================
subtest 'find() method' => sub {

	subtest 'default: only successful deployments returned' => sub {
		my $deployments = make_deployment_set(5,
			results => ['success', 'failed', 'success', 'pending', 'success'],
		);
		my $mgr = make_manager(deployments => $deployments);
		my @found = $mgr->find();
		is(scalar @found, 3, 'only 3 successful deployments returned');
		for my $d (@found) {
			ok($d->succeeded, 'each result is a success');
		}
		done_testing;
	};

	subtest 'post-failed counts as successful' => sub {
		my $deployments = make_deployment_set(3,
			results => ['success', 'post-failed', 'failed'],
		);
		my $mgr = make_manager(deployments => $deployments);
		my @found = $mgr->find();
		is(scalar @found, 2, 'success and post-failed both returned');
		done_testing;
	};

	subtest 'action filter: deploy only' => sub {
		my $deployments = make_deployment_set(4,
			actions => ['deploy', 'terminate', 'deploy', 'deploy'],
		);
		my $mgr = make_manager(deployments => $deployments);
		my @found = $mgr->find(action => 'deploy');
		is(scalar @found, 3, '3 deploy actions');
		for my $d (@found) {
			is($d->action, 'deploy', 'action is deploy');
		}
		done_testing;
	};

	subtest 'action filter: terminate only' => sub {
		my $deployments = make_deployment_set(4,
			actions => ['deploy', 'terminate', 'deploy', 'terminate'],
		);
		my $mgr = make_manager(deployments => $deployments);
		my @found = $mgr->find(action => 'terminate');
		is(scalar @found, 2, '2 terminate actions');
		for my $d (@found) {
			is($d->action, 'terminate', 'action is terminate');
		}
		done_testing;
	};

	subtest 'result filter implies all (includes failed)' => sub {
		my $deployments = make_deployment_set(4,
			results => ['success', 'failed', 'success', 'failed'],
		);
		my $mgr = make_manager(deployments => $deployments);
		my @found = $mgr->find(result => 'failed');
		is(scalar @found, 2, '2 failed deployments returned');
		for my $d (@found) {
			is($d->lookup('result'), 'failed', 'result is failed');
		}
		done_testing;
	};

	subtest 'all => 1 includes failed and pending' => sub {
		my $deployments = make_deployment_set(4,
			results => ['success', 'failed', 'pending', 'success'],
		);
		my $mgr = make_manager(deployments => $deployments);
		my @found = $mgr->find(all => 1);
		is(scalar @found, 4, 'all 4 deployments returned with all => 1');
		done_testing;
	};

	subtest 'timestamps_only returns strings' => sub {
		my $deployments = make_deployment_set(3);
		my $mgr = make_manager(deployments => $deployments);
		my @found = $mgr->find(timestamps_only => 1);
		is(scalar @found, 3, '3 timestamps returned');
		for my $ts (@found) {
			ok(!ref($ts), 'timestamp is a plain string, not an object');
			like($ts, qr/^\d{14}$/, 'timestamp is 14 digits');
		}
		done_testing;
	};

	subtest 'limit => N returns at most N results' => sub {
		my $deployments = make_deployment_set(10);
		my $mgr = make_manager(deployments => $deployments);
		my @found = $mgr->find(limit => 3);
		is(scalar @found, 3, 'limit => 3 returns 3 deployments');
		# Most recent should be first
		cmp_ok($found[0]->timestamp, 'ge', $found[1]->timestamp,
			'first is newer than second');
		done_testing;
	};

	subtest 'limit larger than result set returns all' => sub {
		my $deployments = make_deployment_set(2);
		my $mgr = make_manager(deployments => $deployments);
		my @found = $mgr->find(limit => 100);
		is(scalar @found, 2, 'returns all when limit exceeds count');
		done_testing;
	};

	subtest 'range: single integer index (via find)' => sub {
		my $deployments = make_deployment_set(5);
		my $mgr = make_manager(deployments => $deployments);
		# Note: range => '0' is Perl-falsy, so we use '0...0' instead
		my @found = $mgr->find(range => '0...0');
		is(scalar @found, 1, 'single index returns 1 deployment');
		# Index 0 is oldest in chronological order (reversed from newest-first)
		is($found[0]->timestamp, $deployments->[-1]->timestamp,
			'index 0 is the oldest deployment');
		done_testing;
	};

	subtest 'range: integer range N...M (ascending)' => sub {
		my $deployments = make_deployment_set(5);
		my $mgr = make_manager(deployments => $deployments);
		my @found = $mgr->find(range => '1...3');
		is(scalar @found, 3, 'range 1...3 returns 3 deployments');
		# Result is newest-first within the selected range
		cmp_ok($found[0]->timestamp, 'ge', $found[1]->timestamp,
			'result is newest-first');
		done_testing;
	};

	subtest 'range: negative index' => sub {
		my $deployments = make_deployment_set(5);
		my $mgr = make_manager(deployments => $deployments);
		my @found = $mgr->find(range => '-1...-1');
		is(scalar @found, 1, 'negative index -1 returns 1 deployment');
		is($found[0]->timestamp, $deployments->[0]->timestamp,
			'-1 is the newest deployment');
		done_testing;
	};

	subtest 'range: reverse order M...N where M > N' => sub {
		my $deployments = make_deployment_set(5);
		my $mgr = make_manager(deployments => $deployments);
		my @found = $mgr->find(range => '3...1');
		is(scalar @found, 3, 'range 3...1 returns 3 deployments');
		# Reverse deferred range: [3,2,1] reversed = [1,2,3], applied to
		# reversed (chronological) array then reversed back
		# The result ordering preserves the deferred range direction
		ok(scalar @found == 3, 'got 3 deployments from reverse range');
		done_testing;
	};

	subtest 'range: timestamp comparison >' => sub {
		# Deployments with timestamps 20240101120000 through 20240101160000
		my $deployments = make_deployment_set(5,
			base_timestamp => '20240101120000',
		);
		my $mgr = make_manager(deployments => $deployments);
		# Only those after 20240101130000 (indices 2,3,4 of the original)
		my @found = $mgr->find(range => '>20240101130000');
		ok(scalar @found >= 2, 'got deployments after the cutoff');
		for my $d (@found) {
			cmp_ok($d->timestamp, 'gt', '20240101130000',
				'each deployment is after cutoff');
		}
		done_testing;
	};

	subtest 'range: timestamp comparison <' => sub {
		my $deployments = make_deployment_set(5,
			base_timestamp => '20240101120000',
		);
		my $mgr = make_manager(deployments => $deployments);
		my @found = $mgr->find(range => '<20240101150000');
		ok(scalar @found >= 2, 'got deployments before the cutoff');
		for my $d (@found) {
			cmp_ok($d->timestamp, 'lt', '20240101150000',
				'each deployment is before cutoff');
		}
		done_testing;
	};

	subtest 'range: timestamp comparison >=' => sub {
		my $deployments = make_deployment_set(5,
			base_timestamp => '20240101120000',
		);
		my $mgr = make_manager(deployments => $deployments);
		my @found = $mgr->find(range => '>=20240101120000');
		# The >= with min-fill adjusts to just before, so should include the exact match
		ok(scalar @found >= 1, 'got deployments at or after the cutoff');
		done_testing;
	};

	subtest 'range: timestamp comparison <=' => sub {
		my $deployments = make_deployment_set(5,
			base_timestamp => '20240101120000',
		);
		my $mgr = make_manager(deployments => $deployments);
		my @found = $mgr->find(range => '<=20240101160000');
		ok(scalar @found >= 1, 'got deployments at or before the cutoff');
		done_testing;
	};

	subtest 'range: between strict' => sub {
		my $deployments = make_deployment_set(5,
			base_timestamp => '20240101120000',
		);
		my $mgr = make_manager(deployments => $deployments);
		my @found = $mgr->find(range => '20240101120000<x<20240101160000');
		for my $d (@found) {
			cmp_ok($d->timestamp, 'gt', '20240101120000', 'after low bound');
			cmp_ok($d->timestamp, 'lt', '20240101160000', 'before high bound');
		}
		done_testing;
	};

	subtest 'range: between inclusive' => sub {
		my $deployments = make_deployment_set(5,
			base_timestamp => '20240101120000',
		);
		my $mgr = make_manager(deployments => $deployments);
		my @found = $mgr->find(range => '20240101120000<=x<=20240101160000');
		ok(scalar @found >= 3, 'inclusive range captures boundaries');
		done_testing;
	};

	subtest 'range: partial timestamp (year only)' => sub {
		my $deployments = make_deployment_set(3,
			base_timestamp => '20240601120000',
		);
		my $mgr = make_manager(deployments => $deployments);
		my @found = $mgr->find(range => '>2023');
		is(scalar @found, 3, 'all 2024 deployments are after 2023');
		done_testing;
	};

	subtest 'range: partial timestamp (year-month)' => sub {
		my $deployments = make_deployment_set(3,
			base_timestamp => '20240601120000',
		);
		my $mgr = make_manager(deployments => $deployments);
		my @found = $mgr->find(range => '>2024-05');
		is(scalar @found, 3, 'all June deployments are after May');
		done_testing;
	};

	subtest 'invalid options throws' => sub {
		my $mgr = make_manager(deployments => make_deployment_set(1));
		throws_ok { $mgr->find(bogus => 1) }
			qr/Invalid options:.*bogus/,
			'unknown option throws with message';
		done_testing;
	};

	subtest 'multiple invalid options listed' => sub {
		my $mgr = make_manager(deployments => make_deployment_set(1));
		throws_ok { $mgr->find(foo => 1, bar => 2) }
			qr/Invalid options:/,
			'multiple unknown options throw';
		done_testing;
	};

	subtest 'empty deployments returns empty list' => sub {
		my $mgr = make_manager(deployments => []);
		my @found = $mgr->find();
		is(scalar @found, 0, 'no deployments yields empty list');
		done_testing;
	};

	subtest 'combined: action + limit' => sub {
		my $deployments = make_deployment_set(6,
			actions => ['deploy', 'deploy', 'terminate', 'deploy', 'deploy', 'deploy'],
		);
		my $mgr = make_manager(deployments => $deployments);
		my @found = $mgr->find(action => 'deploy', limit => 2);
		is(scalar @found, 2, 'combined action + limit returns 2');
		for my $d (@found) {
			is($d->action, 'deploy', 'all are deploy actions');
		}
		done_testing;
	};

	subtest 'combined: action + timestamps_only' => sub {
		my $deployments = make_deployment_set(4,
			actions => ['deploy', 'terminate', 'deploy', 'deploy'],
		);
		my $mgr = make_manager(deployments => $deployments);
		my @found = $mgr->find(action => 'deploy', timestamps_only => 1);
		is(scalar @found, 3, '3 deploy timestamps');
		for my $ts (@found) {
			ok(!ref($ts), 'each is a plain string');
		}
		done_testing;
	};

	done_testing;
};


# ===========================================================================
# Section 3e: at(), latest(), latest_successful()
# ===========================================================================
subtest 'at() method' => sub {

	subtest 'exact timestamp match returns deployment' => sub {
		my $deployments = make_deployment_set(3);
		my $mgr = make_manager(deployments => $deployments);
		my $target_ts = $deployments->[1]->timestamp;
		my $d = $mgr->at($target_ts);
		ok(defined $d, 'found a deployment at exact timestamp');
		is($d->timestamp, $target_ts, 'timestamp matches');
		done_testing;
	};

	subtest 'no match returns undef' => sub {
		my $deployments = make_deployment_set(3);
		my $mgr = make_manager(deployments => $deployments);
		my $d = $mgr->at('99999999999999');
		is($d, undef, 'undef for non-existent timestamp');
		done_testing;
	};

	subtest 'empty deployments returns undef' => sub {
		my $mgr = make_manager(deployments => []);
		my $d = $mgr->at('20240101120000');
		is($d, undef, 'undef when no deployments exist');
		done_testing;
	};

	done_testing;
};

subtest 'latest() method' => sub {

	subtest 'returns most recent non-failed deployment' => sub {
		my $deployments = make_deployment_set(4,
			results => ['success', 'success', 'failed', 'success'],
		);
		my $mgr = make_manager(deployments => $deployments);
		my $d = $mgr->latest();
		ok(defined $d, 'got a deployment');
		# Newest is index 0 (highest timestamp), result 'success'
		is($d->timestamp, $deployments->[0]->timestamp,
			'latest non-failed is the newest successful');
		done_testing;
	};

	subtest 'skips failed by default' => sub {
		# Chronological order (oldest-first via index): success, success, failed
		# Newest-first: [failed(ts=140000), success(ts=130000), success(ts=120000)]
		my $deployments = make_deployment_set(3,
			results => ['success', 'success', 'failed'],
		);
		my $mgr = make_manager(deployments => $deployments);
		my $d = $mgr->latest();
		ok(defined $d, 'got a deployment');
		isnt($d->lookup('result'), 'failed', 'skipped the failed one');
		is($d->timestamp, $deployments->[1]->timestamp,
			'returned second-newest (first non-failed)');
		done_testing;
	};

	subtest 'include_failed returns even failed deployments' => sub {
		# Chronological: success, success, failed
		# Newest-first: [failed, success, success]
		my $deployments = make_deployment_set(3,
			results => ['success', 'success', 'failed'],
		);
		my $mgr = make_manager(deployments => $deployments);
		my $d = $mgr->latest(include_failed => 1);
		ok(defined $d, 'got a deployment');
		is($d->timestamp, $deployments->[0]->timestamp,
			'newest deployment (failed) is returned');
		done_testing;
	};

	subtest 'action filter' => sub {
		# Chronological: deploy, deploy, deploy, terminate
		# Newest-first: [terminate(ts=150000), deploy, deploy, deploy]
		my $deployments = make_deployment_set(4,
			actions => ['deploy', 'deploy', 'deploy', 'terminate'],
		);
		my $mgr = make_manager(deployments => $deployments);
		my $d = $mgr->latest(action => 'terminate');
		ok(defined $d, 'got a terminate deployment');
		is($d->action, 'terminate', 'action is terminate');
		is($d->timestamp, $deployments->[0]->timestamp,
			'newest terminate returned');
		done_testing;
	};

	subtest 'result filter' => sub {
		my $deployments = make_deployment_set(3,
			results => ['failed', 'post-failed', 'success'],
		);
		my $mgr = make_manager(deployments => $deployments);
		my $d = $mgr->latest(result => 'post-failed');
		ok(defined $d, 'got a deployment');
		is($d->lookup('result'), 'post-failed', 'result matches filter');
		done_testing;
	};

	subtest 'undef when no deployments' => sub {
		my $mgr = make_manager(deployments => []);
		my $d = $mgr->latest();
		is($d, undef, 'undef when no deployments');
		done_testing;
	};

	subtest 'undef when none match action filter' => sub {
		my $deployments = make_deployment_set(3,
			actions => ['deploy', 'deploy', 'deploy'],
		);
		my $mgr = make_manager(deployments => $deployments);
		my $d = $mgr->latest(action => 'terminate');
		is($d, undef, 'undef when no terminates exist');
		done_testing;
	};

	subtest 'undef when all are failed and include_failed is off' => sub {
		my $deployments = make_deployment_set(3,
			results => ['failed', 'failed', 'failed'],
		);
		my $mgr = make_manager(deployments => $deployments);
		my $d = $mgr->latest();
		is($d, undef, 'undef when all are failed');
		done_testing;
	};

	done_testing;
};

subtest 'latest_successful() method' => sub {

	subtest 'returns latest successful deploy' => sub {
		# Chronological: success, failed, success, failed
		# Newest-first: [failed, success, failed, success]
		my $deployments = make_deployment_set(4,
			results => ['success', 'failed', 'success', 'failed'],
		);
		my $mgr = make_manager(deployments => $deployments);
		my $d = $mgr->latest_successful();
		ok(defined $d, 'got a deployment');
		ok($d->succeeded, 'result is successful');
		# Newest successful is index 1 (second from top)
		is($d->timestamp, $deployments->[1]->timestamp,
			'newest successful deployment returned');
		done_testing;
	};

	subtest 'post-failed counts as successful' => sub {
		# Chronological: success, post-failed, failed
		# Newest-first: [failed, post-failed, success]
		my $deployments = make_deployment_set(3,
			results => ['success', 'post-failed', 'failed'],
		);
		my $mgr = make_manager(deployments => $deployments);
		my $d = $mgr->latest_successful();
		ok(defined $d, 'got a deployment');
		ok($d->succeeded, 'post-failed is a success');
		is($d->lookup('result'), 'post-failed', 'result is post-failed');
		done_testing;
	};

	subtest 'undef when no successful deployments' => sub {
		my $deployments = make_deployment_set(3,
			results => ['failed', 'failed', 'failed'],
		);
		my $mgr = make_manager(deployments => $deployments);
		my $d = $mgr->latest_successful();
		is($d, undef, 'undef when all are failed');
		done_testing;
	};

	subtest 'undef when no deployments' => sub {
		my $mgr = make_manager(deployments => []);
		my $d = $mgr->latest_successful();
		is($d, undef, 'undef with empty deployments');
		done_testing;
	};

	subtest 'respects action filter' => sub {
		# Chronological: deploy, terminate, deploy, deploy
		# Newest-first: [deploy, deploy, terminate, deploy]
		my $deployments = make_deployment_set(4,
			actions => ['deploy', 'terminate', 'deploy', 'deploy'],
		);
		my $mgr = make_manager(deployments => $deployments);
		my $d = $mgr->latest_successful(action => 'terminate');
		ok(defined $d, 'got a terminate deployment');
		is($d->action, 'terminate', 'action is terminate');
		done_testing;
	};

	done_testing;
};


# ===========================================================================
# Section 3f: current_state()
# ===========================================================================
subtest 'current_state() method' => sub {

	subtest 'deployed when latest successful is deploy' => sub {
		my $deployments = make_deployment_set(3, action => 'deploy');
		my $mgr = make_manager(deployments => $deployments);
		is($mgr->current_state(), 'deployed', 'state is deployed');
		done_testing;
	};

	subtest 'terminated when latest successful is terminate' => sub {
		# Chronological: deploy, deploy, terminate
		# Newest-first: [terminate, deploy, deploy]
		my $deployments = make_deployment_set(3,
			actions => ['deploy', 'deploy', 'terminate'],
		);
		my $mgr = make_manager(deployments => $deployments);
		is($mgr->current_state(), 'terminated', 'state is terminated');
		done_testing;
	};

	subtest 'undeployed when no deployments and no exodus data' => sub {
		my $env = make_mock_env(
			exodus_lookup => sub { return {} },
		);
		my $mgr = make_manager(env => $env, deployments => []);
		is($mgr->current_state(), 'undeployed', 'state is undeployed');
		done_testing;
	};

	subtest 'deployed when no deployments but exodus data exists (legacy)' => sub {
		my $env = make_mock_env(
			exodus_lookup => sub { return { kit_name => 'cf', version => '2.0' } },
		);
		my $mgr = make_manager(env => $env, deployments => []);
		is($mgr->current_state(), 'deployed', 'state is deployed (legacy exodus)');
		done_testing;
	};

	subtest 'deployed after failed deploy atop successful deploy' => sub {
		# Chronological: success, success, failed
		# Newest-first: [failed, success, success]
		# find() returns only successful, so newest successful is deploy
		my $deployments = make_deployment_set(3,
			actions => ['deploy', 'deploy', 'deploy'],
			results => ['success', 'success', 'failed'],
		);
		my $mgr = make_manager(deployments => $deployments);
		is($mgr->current_state(), 'deployed', 'still deployed despite recent failure');
		done_testing;
	};

	done_testing;
};


# ===========================================================================
# Section 3g: build() & next_sequence_number()
# ===========================================================================
subtest 'build() method' => sub {

	subtest 'build with result=assumed returns Deployment object' => sub {
		my $env = make_mock_env();
		my $mgr = Genesis::Env::DeploymentManager->new($env);
		# Use 'terminate' action since 'deploy' requires kit/manifest fields
		# that _base_deployment_content skips for result='assumed'
		my $d = $mgr->build('terminate', 'assumed',
			reason => 'backfill',
			user   => { shell => 'test-user' },
		);
		isa_ok($d, 'Genesis::Env::Deployment');
		is($d->action, 'terminate', 'action is terminate');
		is($d->lookup('result'), 'assumed', 'result is assumed');
		done_testing;
	};

	subtest 'build merges caller options over base' => sub {
		my $env = make_mock_env();
		my $mgr = Genesis::Env::DeploymentManager->new($env);
		my $d = $mgr->build('terminate', 'assumed',
			reason => 'manual termination',
			user   => { shell => 'admin-user' },
		);
		is($d->reason, 'manual termination', 'caller reason overrides base');
		is($d->action, 'terminate', 'action is terminate');
		done_testing;
	};

	subtest 'build sets genesis_version from Genesis::VERSION' => sub {
		my $env = make_mock_env();
		my $mgr = Genesis::Env::DeploymentManager->new($env);
		my $d = $mgr->build('terminate', 'assumed',
			reason => 'test',
			user   => { shell => 'test-user' },
		);
		is($d->lookup('genesis_version'), '999.999.999',
			'genesis_version comes from $Genesis::VERSION');
		done_testing;
	};

	subtest 'build deploy with assumed provides kit/manifest in options' => sub {
		my $env = make_mock_env();
		my $mgr = Genesis::Env::DeploymentManager->new($env);
		my $d = $mgr->build('deploy', 'assumed',
			reason   => 'backfill deploy',
			user     => { shell => 'test-user' },
			kit      => { id => 'cf/1.0', name => 'cf', version => '1.0', is_dev => 0, features => '' },
			manifest => { type => 'bosh', sha2 => 'abc123' },
		);
		isa_ok($d, 'Genesis::Env::Deployment');
		is($d->action, 'deploy', 'action is deploy');
		is($d->lookup('kit.name'), 'cf', 'caller-provided kit merged in');
		done_testing;
	};

	done_testing;
};

subtest 'next_sequence_number() method' => sub {

	subtest 'no deployments returns 1' => sub {
		my $mgr = make_manager(deployments => []);
		is($mgr->next_sequence_number(), 1, 'first sequence is 1');
		done_testing;
	};

	subtest 'latest has no sequence field: count + 1' => sub {
		my $deployments = make_deployment_set(3);
		# Remove sequence from all deployments
		for my $d (@$deployments) {
			delete $d->{data}{sequence};
		}
		my $mgr = make_manager(deployments => $deployments);
		is($mgr->next_sequence_number(), 4, 'fallback: count(3) + 1 = 4');
		done_testing;
	};

	subtest 'normal: latest sequence + 1' => sub {
		my $deployments = make_deployment_set(3,
			sequences => [1, 2, 3],
		);
		my $mgr = make_manager(deployments => $deployments);
		# Newest deployment (index 0) has sequence 3
		is($mgr->next_sequence_number(), 4, 'sequence 3 + 1 = 4');
		done_testing;
	};

	subtest 'skips failed when finding latest' => sub {
		# Chronological: success(seq=1), success(seq=2), failed(seq=3)
		# Newest-first: [failed(seq=3), success(seq=2), success(seq=1)]
		# latest() skips failed, finds sequence=2
		my $deployments = make_deployment_set(3,
			results   => ['success', 'success', 'failed'],
			sequences => [1, 2, 3],
		);
		my $mgr = make_manager(deployments => $deployments);
		is($mgr->next_sequence_number(), 3, 'uses non-failed latest: 2 + 1 = 3');
		done_testing;
	};

	subtest 'all failed: returns 1 (latest returns undef)' => sub {
		my $deployments = make_deployment_set(3,
			results => ['failed', 'failed', 'failed'],
		);
		my $mgr = make_manager(deployments => $deployments);
		is($mgr->next_sequence_number(), 1, 'all failed: returns 1');
		done_testing;
	};

	done_testing;
};


# ===========================================================================
# Section 3h: synthesize_from_exodus()
# ===========================================================================
subtest 'synthesize_from_exodus() method' => sub {

	subtest 'synthesizes deployment from exodus data' => sub {
		my $env = make_mock_env();
		my $mgr = Genesis::Env::DeploymentManager->new($env);
		my $exodus_data = {
			dated         => '2024-01-15 10:30:00 +0000',
			version       => '2.8.0',
			kit_name      => 'cf',
			kit_version   => '2.1.0',
			kit_is_dev    => 0,
			kit_id        => 'cf/2.1.0',
			features      => 'haproxy,tls',
			deployer      => 'admin',
			bosh          => 'test-bosh',
			manifest_type => 'bosh',
			manifest_sha1 => 'deadbeef1234',
			reason        => 'scheduled deploy',
		};
		my $d = $mgr->synthesize_from_exodus($exodus_data);
		ok(defined $d, 'got a deployment object');
		isa_ok($d, 'Genesis::Env::Deployment');
		is($d->action, 'deploy', 'action is deploy');
		is($d->lookup('result'), 'success', 'result is success');
		is($d->reason, 'scheduled deploy', 'reason from exodus data');
		is($d->lookup('kit.name'), 'cf', 'kit name from exodus');
		is($d->lookup('kit.version'), '2.1.0', 'kit version from exodus');
		done_testing;
	};

	subtest 'empty exodus returns undef' => sub {
		my $env = make_mock_env();
		my $mgr = Genesis::Env::DeploymentManager->new($env);
		my $d = $mgr->synthesize_from_exodus({});
		is($d, undef, 'undef when exodus data is empty');
		done_testing;
	};

	subtest 'unknown user roles set correctly' => sub {
		my $env = make_mock_env();
		my $mgr = Genesis::Env::DeploymentManager->new($env);
		my $exodus_data = {
			dated         => '2024-01-15 10:30:00 +0000',
			version       => '2.8.0',
			kit_name      => 'cf',
			kit_version   => '2.1.0',
			kit_is_dev    => 0,
			kit_id        => 'cf/2.1.0',
			features      => '',
			deployer      => 'jane',
			bosh          => 'my-bosh',
			manifest_type => 'bosh',
			manifest_sha1 => 'abc123',
		};
		my $d = $mgr->synthesize_from_exodus($exodus_data);
		is($d->lookup('user.shell'), 'jane', 'shell user from deployer');
		is($d->lookup('user.vault'), 'unknown', 'vault user is unknown');
		is($d->lookup('user.git'), 'unknown', 'git user is unknown');
		is($d->lookup('user.concourse'), 'unknown', 'concourse user is unknown');
		is($d->lookup('user.bosh'), 'unknown', 'bosh user is unknown');
		done_testing;
	};

	subtest 'manifest sha2 comes from manifest_sha1, with using_sha1 flag' => sub {
		my $env = make_mock_env();
		my $mgr = Genesis::Env::DeploymentManager->new($env);
		my $exodus_data = {
			dated         => '2024-01-15 10:30:00 +0000',
			version       => '2.8.0',
			kit_name      => 'cf',
			kit_version   => '2.1.0',
			kit_is_dev    => 0,
			kit_id        => 'cf/2.1.0',
			features      => '',
			deployer      => 'test',
			bosh          => 'my-bosh',
			manifest_type => 'bosh',
			manifest_sha1 => 'sha1hash',
		};
		my $d = $mgr->synthesize_from_exodus($exodus_data);
		is($d->lookup('manifest.sha2'), 'sha1hash', 'sha2 contains sha1 value');
		is($d->lookup('manifest.sha1'), 'sha1hash', 'sha1 also present');
		is($d->lookup('manifest.using_sha1'), 1, 'using_sha1 flag is set');
		done_testing;
	};

	subtest 'defaults reason when not in exodus data' => sub {
		my $env = make_mock_env();
		my $mgr = Genesis::Env::DeploymentManager->new($env);
		my $exodus_data = {
			dated         => '2024-01-15 10:30:00 +0000',
			version       => '2.8.0',
			kit_name      => 'cf',
			kit_version   => '2.1.0',
			kit_is_dev    => 0,
			kit_id        => 'cf/2.1.0',
			features      => '',
			deployer      => 'test',
			bosh          => 'my-bosh',
			manifest_type => 'bosh',
			manifest_sha1 => 'abc',
		};
		my $d = $mgr->synthesize_from_exodus($exodus_data);
		like($d->reason, qr/synthesized from previous exodus/,
			'default reason mentions synthesized');
		done_testing;
	};

	subtest 'falls back to env exodus_lookup when no data provided' => sub {
		my $env = make_mock_env(
			exodus_lookup => sub {
				return {
					dated         => '2024-03-01 08:00:00 +0000',
					version       => '2.9.0',
					kit_name      => 'bosh',
					kit_version   => '3.0.0',
					kit_is_dev    => 0,
					kit_id        => 'bosh/3.0.0',
					features      => '',
					deployer      => 'ops',
					bosh          => 'prod-bosh',
					manifest_type => 'bosh',
					manifest_sha1 => 'feedface',
				};
			},
		);
		my $mgr = Genesis::Env::DeploymentManager->new($env);
		my $d = $mgr->synthesize_from_exodus();
		ok(defined $d, 'synthesized from env exodus_lookup');
		is($d->lookup('kit.name'), 'bosh', 'kit name from exodus store');
		done_testing;
	};

	done_testing;
};


# ===========================================================================
# Section 3i: Internal methods
# ===========================================================================

# --- _confirm_deployments_sorted ---
subtest '_confirm_deployments_sorted()' => sub {

	subtest 'sorted array returns 1' => sub {
		my $deployments = make_deployment_set(5);
		my $mgr = make_manager(deployments => $deployments);
		my $result = $mgr->_confirm_deployments_sorted($deployments);
		is($result, 1, 'sorted array confirmed');
		done_testing;
	};

	subtest 'unsorted array triggers bug()' => sub {
		my @unsorted = (
			make_deployment(timestamp => '20240101100000'),
			make_deployment(timestamp => '20240101200000'), # out of order
			make_deployment(timestamp => '20240101050000'),
		);
		my $mgr = make_manager(deployments => \@unsorted);
		throws_ok { $mgr->_confirm_deployments_sorted(\@unsorted) }
			qr/not sorted by timestamp/,
			'bug raised for unsorted deployments';
		done_testing;
	};

	subtest '0 elements returns 1' => sub {
		my $mgr = make_manager(deployments => []);
		my $result = $mgr->_confirm_deployments_sorted([]);
		is($result, 1, 'empty array is sorted');
		done_testing;
	};

	subtest '1 element returns 1' => sub {
		my @single = (make_deployment(timestamp => '20240101120000'));
		my $mgr = make_manager(deployments => \@single);
		my $result = $mgr->_confirm_deployments_sorted(\@single);
		is($result, 1, 'single element is sorted');
		done_testing;
	};

	subtest 'equal timestamps are considered sorted' => sub {
		my @equal = (
			make_deployment(timestamp => '20240101120000'),
			make_deployment(timestamp => '20240101120000'),
		);
		my $mgr = make_manager(deployments => \@equal);
		my $result = $mgr->_confirm_deployments_sorted(\@equal);
		is($result, 1, 'equal timestamps pass sort check');
		done_testing;
	};

	done_testing;
};

# --- _get_last_day_of_month ---
subtest '_get_last_day_of_month()' => sub {

	subtest 'January has 31 days' => sub {
		is(Genesis::Env::DeploymentManager::_get_last_day_of_month(2024, 1), 31, 'Jan = 31');
		done_testing;
	};

	subtest 'February non-leap year has 28 days' => sub {
		is(Genesis::Env::DeploymentManager::_get_last_day_of_month(2023, 2), 28, 'Feb 2023 = 28');
		done_testing;
	};

	subtest 'February leap year has 29 days' => sub {
		is(Genesis::Env::DeploymentManager::_get_last_day_of_month(2024, 2), 29, 'Feb 2024 = 29');
		done_testing;
	};

	subtest 'April has 30 days' => sub {
		is(Genesis::Env::DeploymentManager::_get_last_day_of_month(2024, 4), 30, 'Apr = 30');
		done_testing;
	};

	subtest 'December has 31 days' => sub {
		is(Genesis::Env::DeploymentManager::_get_last_day_of_month(2024, 12), 31, 'Dec = 31');
		done_testing;
	};

	subtest 'June has 30 days' => sub {
		is(Genesis::Env::DeploymentManager::_get_last_day_of_month(2024, 6), 30, 'Jun = 30');
		done_testing;
	};

	subtest 'November has 30 days' => sub {
		is(Genesis::Env::DeploymentManager::_get_last_day_of_month(2024, 11), 30, 'Nov = 30');
		done_testing;
	};

	done_testing;
};

# --- _parse_into_timestamp_gt_cmp ---
subtest '_parse_into_timestamp_gt_cmp()' => sub {

	subtest '> with full timestamp (end-of-period fill)' => sub {
		# Use UTC+0000 timezone explicitly to avoid local TZ issues
		my $ts = Genesis::Env::DeploymentManager::_parse_into_timestamp_gt_cmp(
			'20240115143000', '>'
		);
		ok(defined $ts, 'returns a value');
		like($ts, qr/^\d{14}$/, 'is a 14-digit timestamp');
		# gt=1, eq=0, eff_gt=1: no adjustment
		is($ts, '20240115143000', '> with full timestamp preserves value');
		done_testing;
	};

	subtest '>= with full timestamp (start-of-period fill, minus 1s)' => sub {
		my $ts = Genesis::Env::DeploymentManager::_parse_into_timestamp_gt_cmp(
			'20240115143000', '>='
		);
		ok(defined $ts, 'returns a value');
		# gt=1, eq=1, eff_gt=0: subtract 1 second
		is($ts, '20240115142959', '>= subtracts 1 second');
		done_testing;
	};

	subtest '< with full timestamp (start-of-period fill, minus 1s)' => sub {
		my $ts = Genesis::Env::DeploymentManager::_parse_into_timestamp_gt_cmp(
			'20240115143000', '<'
		);
		ok(defined $ts, 'returns a value');
		# gt=0, eq=0, eff_gt=0: subtract 1 second
		is($ts, '20240115142959', '< subtracts 1 second');
		done_testing;
	};

	subtest '<= with full timestamp (end-of-period fill, no adjust)' => sub {
		my $ts = Genesis::Env::DeploymentManager::_parse_into_timestamp_gt_cmp(
			'20240115143000', '<='
		);
		ok(defined $ts, 'returns a value');
		# gt=0, eq=1, eff_gt=1: no adjustment
		is($ts, '20240115143000', '<= preserves value');
		done_testing;
	};

	subtest '> with partial timestamp (year only)' => sub {
		my $ts = Genesis::Env::DeploymentManager::_parse_into_timestamp_gt_cmp(
			'2024', '>'
		);
		ok(defined $ts, 'returns a value');
		# eff_gt = 1, fills with max: 2024-12-31 23:59:59, no adjustment
		is($ts, '20241231235959', '> year fills to end of year');
		done_testing;
	};

	subtest '< with partial timestamp (year only)' => sub {
		my $ts = Genesis::Env::DeploymentManager::_parse_into_timestamp_gt_cmp(
			'2024', '<'
		);
		ok(defined $ts, 'returns a value');
		# eff_gt = 0, fills with min: 2024-01-01 00:00:00, minus 1s
		is($ts, '20231231235959', '< year fills to start of year minus 1s');
		done_testing;
	};

	subtest '>= with year-month partial timestamp' => sub {
		my $ts = Genesis::Env::DeploymentManager::_parse_into_timestamp_gt_cmp(
			'2024-06', '>='
		);
		ok(defined $ts, 'returns a value');
		# eff_gt = 1^1 = 0, fills with min: 2024-06-01 00:00:00, minus 1s
		is($ts, '20240531235959', '>= year-month fills to start minus 1s');
		done_testing;
	};

	subtest '<= with year-month partial timestamp' => sub {
		my $ts = Genesis::Env::DeploymentManager::_parse_into_timestamp_gt_cmp(
			'2024-06', '<='
		);
		ok(defined $ts, 'returns a value');
		# eff_gt = 0^1 = 1, fills with max: 2024-06-30 23:59:59, no adjustment
		is($ts, '20240630235959', '<= year-month fills to end of month');
		done_testing;
	};

	subtest '> with year-month-day partial timestamp' => sub {
		my $ts = Genesis::Env::DeploymentManager::_parse_into_timestamp_gt_cmp(
			'2024-03-15', '>'
		);
		ok(defined $ts, 'returns a value');
		# eff_gt = 1, fills HH:MM:SS with 23:59:59, no adjustment
		is($ts, '20240315235959', '> year-month-day fills to end of day');
		done_testing;
	};

	done_testing;
};

# --- _filter_by_range ---
subtest '_filter_by_range()' => sub {

	subtest 'integer range: single index returns arrayref' => sub {
		my $deployments = make_deployment_set(5);
		my $mgr = make_manager(deployments => $deployments);
		my @copy = @$deployments;
		my $result = $mgr->_filter_by_range(\@copy, '0');
		ok(ref($result) eq 'ARRAY', 'returns arrayref for integer range');
		is_deeply($result, [0], 'single index 0');
		done_testing;
	};

	subtest 'integer range: N...M returns arrayref' => sub {
		my $deployments = make_deployment_set(5);
		my $mgr = make_manager(deployments => $deployments);
		my @copy = @$deployments;
		my $result = $mgr->_filter_by_range(\@copy, '1...3');
		ok(ref($result) eq 'ARRAY', 'returns arrayref');
		is_deeply($result, [1, 2, 3], 'range 1...3');
		done_testing;
	};

	subtest 'integer range: negative index' => sub {
		my $deployments = make_deployment_set(5);
		my $mgr = make_manager(deployments => $deployments);
		my @copy = @$deployments;
		my $result = $mgr->_filter_by_range(\@copy, '-1');
		ok(ref($result) eq 'ARRAY', 'returns arrayref');
		is_deeply($result, [-1], 'single negative index -1');
		done_testing;
	};

	subtest 'integer range: reverse order M...N' => sub {
		my $deployments = make_deployment_set(5);
		my $mgr = make_manager(deployments => $deployments);
		my @copy = @$deployments;
		my $result = $mgr->_filter_by_range(\@copy, '3...1');
		ok(ref($result) eq 'ARRAY', 'returns arrayref');
		is_deeply($result, [3, 2, 1], 'reverse range 3...1');
		done_testing;
	};

	subtest 'timestamp range: > modifies in-place, returns undef' => sub {
		my $deployments = make_deployment_set(5,
			base_timestamp => '20240101120000',
		);
		my $mgr = make_manager(deployments => $deployments);
		my @copy = @$deployments;
		my $original_count = scalar @copy;
		my $result = $mgr->_filter_by_range(\@copy, '>20240101130000');
		is($result, undef, 'timestamp range returns undef');
		ok(scalar @copy <= $original_count, 'array was modified in-place');
		for my $d (@copy) {
			cmp_ok($d->timestamp, 'gt', '20240101130000',
				'remaining deployments are after cutoff');
		}
		done_testing;
	};

	subtest 'timestamp range: < modifies in-place' => sub {
		my $deployments = make_deployment_set(5,
			base_timestamp => '20240101120000',
		);
		my $mgr = make_manager(deployments => $deployments);
		my @copy = @$deployments;
		my $result = $mgr->_filter_by_range(\@copy, '<20240101150000');
		is($result, undef, 'timestamp range returns undef');
		for my $d (@copy) {
			cmp_ok($d->timestamp, 'lt', '20240101150000',
				'remaining deployments are before cutoff');
		}
		done_testing;
	};

	subtest 'timestamp range: between strict' => sub {
		my $deployments = make_deployment_set(5,
			base_timestamp => '20240101120000',
		);
		my $mgr = make_manager(deployments => $deployments);
		my @copy = @$deployments;
		$mgr->_filter_by_range(\@copy, '20240101120000<x<20240101160000');
		for my $d (@copy) {
			cmp_ok($d->timestamp, 'gt', '20240101120000', 'after low bound');
			cmp_ok($d->timestamp, 'lt', '20240101160000', 'before high bound');
		}
		done_testing;
	};

	subtest 'timestamp range: between inclusive' => sub {
		my $deployments = make_deployment_set(5,
			base_timestamp => '20240101120000',
		);
		my $mgr = make_manager(deployments => $deployments);
		my @copy = @$deployments;
		$mgr->_filter_by_range(\@copy, '20240101120000<=x<=20240101160000');
		ok(scalar @copy >= 3, 'inclusive range captures more deployments');
		done_testing;
	};

	subtest 'invalid range format throws' => sub {
		my $deployments = make_deployment_set(3);
		my $mgr = make_manager(deployments => $deployments);
		my @copy = @$deployments;
		throws_ok { $mgr->_filter_by_range(\@copy, 'not-a-range!@#') }
			qr/Invalid range format/,
			'invalid range format throws';
		done_testing;
	};

	subtest 'timestamp range with partial timestamps' => sub {
		my $deployments = make_deployment_set(3,
			base_timestamp => '20240601120000',
		);
		my $mgr = make_manager(deployments => $deployments);
		my @copy = @$deployments;
		$mgr->_filter_by_range(\@copy, '>2024-05');
		is(scalar @copy, 3, 'all June 2024 deployments are after May 2024');
		done_testing;
	};

	subtest 'exact timestamp match range' => sub {
		# Test the =TIMESTAMP format (exact match range)
		my $deployments = make_deployment_set(5,
			base_timestamp => '20240101120000',
		);
		my $mgr = make_manager(deployments => $deployments);
		my @copy = @$deployments;
		# Exact timestamp of the middle deployment
		my $exact_ts = $deployments->[2]->timestamp;
		$mgr->_filter_by_range(\@copy, $exact_ts);
		# Should narrow down to approximately 1 deployment
		ok(scalar @copy >= 1, 'exact match finds at least 1 deployment');
		done_testing;
	};

	done_testing;
};


# ===========================================================================
# Integration: find + range + action combined
# ===========================================================================
subtest 'find() integration: combined filters' => sub {

	subtest 'action + range + limit' => sub {
		my $deployments = make_deployment_set(8,
			base_timestamp => '20240101120000',
			actions => ['deploy', 'terminate', 'deploy', 'deploy',
			            'terminate', 'deploy', 'deploy', 'deploy'],
		);
		my $mgr = make_manager(deployments => $deployments);
		my @found = $mgr->find(
			action => 'deploy',
			limit  => 2,
		);
		is(scalar @found, 2, 'combined: action + limit = 2 results');
		for my $d (@found) {
			is($d->action, 'deploy', 'all are deploy');
		}
		done_testing;
	};

	subtest 'result filter + timestamps_only' => sub {
		my $deployments = make_deployment_set(5,
			results => ['success', 'failed', 'success', 'failed', 'success'],
		);
		my $mgr = make_manager(deployments => $deployments);
		my @found = $mgr->find(result => 'failed', timestamps_only => 1);
		is(scalar @found, 2, '2 failed timestamps');
		for my $ts (@found) {
			ok(!ref($ts), 'each is a string');
		}
		done_testing;
	};

	subtest 'all with no deployments' => sub {
		my $mgr = make_manager(deployments => []);
		my @found = $mgr->find(all => 1, timestamps_only => 1);
		is(scalar @found, 0, 'empty even with all + timestamps_only');
		done_testing;
	};

	done_testing;
};


# ===========================================================================
# Edge cases and additional coverage
# ===========================================================================
subtest 'Edge cases' => sub {

	subtest 'find with range on empty deployments' => sub {
		my $mgr = make_manager(deployments => []);
		my @found = $mgr->find(range => '>20240101');
		is(scalar @found, 0, 'range on empty returns empty');
		done_testing;
	};

	subtest 'at with first deployment timestamp' => sub {
		my $deployments = make_deployment_set(3);
		my $mgr = make_manager(deployments => $deployments);
		my $first_ts = $deployments->[0]->timestamp;
		my $d = $mgr->at($first_ts);
		ok(defined $d, 'found deployment at newest timestamp');
		is($d->timestamp, $first_ts, 'timestamp matches');
		done_testing;
	};

	subtest 'at with last deployment timestamp' => sub {
		my $deployments = make_deployment_set(3);
		my $mgr = make_manager(deployments => $deployments);
		my $last_ts = $deployments->[-1]->timestamp;
		my $d = $mgr->at($last_ts);
		ok(defined $d, 'found deployment at oldest timestamp');
		is($d->timestamp, $last_ts, 'timestamp matches');
		done_testing;
	};

	subtest 'latest with action and result filters combined' => sub {
		# Deployment set (newest-first after reverse):
		# [0] terminate/success, [1] deploy/success, [2] terminate/failed, [3] deploy/success
		my $deployments = make_deployment_set(4,
			actions => ['deploy', 'terminate', 'deploy', 'terminate'],
			results => ['success', 'failed', 'success', 'success'],
		);
		my $mgr = make_manager(deployments => $deployments);
		my $d = $mgr->latest(action => 'terminate', include_failed => 1);
		ok(defined $d, 'found a terminate');
		is($d->action, 'terminate', 'action is terminate');
		# Newest terminate is index 0 (the newest deployment overall)
		is($d->timestamp, $deployments->[0]->timestamp,
			'newest terminate found');
		done_testing;
	};

	subtest 'current_state with only failed deployments falls to exodus' => sub {
		my $env = make_mock_env(
			exodus_lookup => sub { return { something => 'yes' } },
		);
		my $deployments = make_deployment_set(2,
			results => ['failed', 'failed'],
		);
		my $mgr = make_manager(env => $env, deployments => $deployments);
		# find() returns only successful, so empty -> checks exodus
		is($mgr->current_state(), 'deployed',
			'falls back to exodus when all deployments are failed');
		done_testing;
	};

	subtest 'synthesize_from_exodus constructs kit_id from parts when kit_id missing' => sub {
		my $env = make_mock_env();
		my $mgr = Genesis::Env::DeploymentManager->new($env);
		my $exodus_data = {
			dated         => '2024-01-15 10:30:00 +0000',
			version       => '2.8.0',
			kit_name      => 'cf',
			kit_version   => '2.1.0',
			kit_is_dev    => 0,
			features      => 'haproxy',
			deployer      => 'admin',
			bosh          => 'test-bosh',
			manifest_type => 'bosh',
			manifest_sha1 => 'abc',
		};
		my $d = $mgr->synthesize_from_exodus($exodus_data);
		is($d->lookup('kit.id'), 'cf/2.1.0', 'kit_id built from name/version');
		done_testing;
	};

	subtest 'synthesize_from_exodus with dev kit' => sub {
		my $env = make_mock_env();
		my $mgr = Genesis::Env::DeploymentManager->new($env);
		my $exodus_data = {
			dated         => '2024-01-15 10:30:00 +0000',
			version       => '2.8.0',
			kit_name      => 'cf',
			kit_version   => '2.1.0',
			kit_is_dev    => 1,
			features      => '',
			deployer      => 'admin',
			bosh          => 'test-bosh',
			manifest_type => 'bosh',
			manifest_sha1 => 'abc',
		};
		my $d = $mgr->synthesize_from_exodus($exodus_data);
		is($d->lookup('kit.id'), 'cf/2.1.0 (dev)',
			'dev kit appends (dev) to kit_id');
		done_testing;
	};

	done_testing;
};


done_testing;
# vim: set ts=2 sw=2 sts=2 noet:
