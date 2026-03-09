use strict;
use warnings;

use lib 'lib';
use lib 't';

use Test::More;
use Test::Exception;

BEGIN {
	use_ok 'Service::Github';
}

subtest 'Service::Github SSH key methods' => sub {
	plan tests => 4;

	subtest 'get_user_ssh_keys with GitHub user' => sub {
		plan tests => 4;

		my $gh = Service::Github->new(domain => 'github.com');
		my ($keys, $err) = $gh->get_user_ssh_keys('dennisjbell');

		ok(!$err, 'no error fetching GitHub user keys');
		ok($keys, 'returned keys array');
		isa_ok($keys, 'ARRAY', 'keys is an array reference');
		ok(scalar(@$keys) > 0, 'found at least one key for dennisjbell');
	};

	subtest 'get_user_ssh_keys with GitLab user' => sub {
		plan tests => 4;

		my $gitlab = Service::Github->new(domain => 'gitlab.com');
		my ($keys, $err) = $gitlab->get_user_ssh_keys('sytses');

		ok(!$err, 'no error fetching GitLab user keys');
		ok($keys, 'returned keys array');
		isa_ok($keys, 'ARRAY', 'keys is an array reference');
		ok(scalar(@$keys) > 0, 'found at least one key for sytses on GitLab');
	};

	subtest 'get_user_ssh_keys error handling' => sub {
		plan tests => 6;

		my $gh = Service::Github->new(domain => 'github.com');

		# Non-existent user
		my ($keys, $err) = $gh->get_user_ssh_keys('thisuserdoesnotexist12345678');
		ok($err, 'returns error for non-existent user');
		ok(!$keys, 'returns undef keys for non-existent user');
		like($err, qr/not found/i, 'error message mentions not found');

		# Invalid username format
		dies_ok { $gh->get_user_ssh_keys('invalid..username') }
			'dies with invalid username format';
		dies_ok { $gh->get_user_ssh_keys('') }
			'dies with empty username';
		dies_ok { $gh->get_user_ssh_keys(undef) }
			'dies with undef username';
	};

	subtest 'get_user_ssh_keys validates returned keys' => sub {
		plan tests => 2;

		my $gh = Service::Github->new(domain => 'github.com');
		my ($keys, $err) = $gh->get_user_ssh_keys('dennisjbell');

		ok(!$err, 'successfully fetched keys');

		# All returned keys should pass validation
		my $all_valid = 1;
		foreach my $key (@$keys) {
			$all_valid = 0 unless $gh->validate_ssh_key($key);
		}
		ok($all_valid, 'all returned keys are valid SSH public keys');
	};
};

subtest 'Service::Github API methods' => sub {
	plan tests => 2;

	subtest 'repos() and repo_names() integration' => sub {
		plan tests => 7;

		my $gh = Service::Github->new(org => 'genesis-community');

		# Test repos() fetches data from GitHub API
		my $repos = $gh->repos();
		isa_ok($repos, 'ARRAY', 'repos() returns array reference');
		ok(scalar(@$repos) > 0, 'repos() returns at least one repository');

		# Verify repos have expected structure
		my $first_repo = $repos->[0];
		ok(exists $first_repo->{name}, 'repo has name field');

		# Test repo_names() without filter
		my $all_names = $gh->repo_names();
		isa_ok($all_names, 'ARRAY', 'repo_names() returns array reference');
		ok(scalar(@$all_names) > 0, 'repo_names() returns at least one name');

		# Test repo_names() with filter for genesis kits
		my $kit_names = $gh->repo_names(qr/-genesis-kit$/);
		my $has_kits = scalar(@$kit_names) > 0;
		ok($has_kits, 'repo_names() with filter finds genesis kits');

		# Verify filter actually works by checking all names match pattern
		if ($has_kits) {
			my $all_match = 1;
			foreach my $name (@$kit_names) {
				$all_match = 0 unless $name =~ /-genesis-kit$/;
			}
			ok($all_match, 'all filtered names match the pattern') if $all_match;
		}
	};

	subtest 'API error handling' => sub {
		plan tests => 2;

		# Test with non-existent organization
		my $gh = Service::Github->new(org => 'thisorgdoesnotexist12345678');
		my ($code, $status) = $gh->check();

		ok($code != 200, 'check() returns non-200 for non-existent org');
		ok(defined($status), 'check() returns error message for non-existent org');
	};
};

done_testing;
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1
