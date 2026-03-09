use strict;
use warnings;

use lib 'lib';
use lib 't';

use Test::More;
use Test::Exception;

BEGIN {
	use_ok 'Service::Github';
}

subtest 'Service::Github pure unit tests' => sub {
	plan tests => 6;

	subtest 'new() constructor' => sub {
		plan tests => 12;

		# Test defaults without ENV credentials
		my $gh;
		{
			local $ENV{GITHUB_USER};
			local $ENV{GITHUB_AUTH_TOKEN};
			$gh = Service::Github->new();
		}
		is($gh->{domain}, 'github.com', 'default domain');
		is($gh->{org}, 'genesis-community', 'default org');
		is($gh->{tls}, 'yes', 'default tls');
		ok(!defined($gh->{creds}), 'no credentials without ENV vars');

		# Test Bearer token format (token only)
		{
			local $ENV{GITHUB_USER};
			local $ENV{GITHUB_AUTH_TOKEN} = 'ghp_test123token';
			$gh = Service::Github->new();
			is($gh->{creds}, 'Bearer ghp_test123token', 'Bearer format when only GITHUB_AUTH_TOKEN');
		}

		# Test user:token format (both ENV vars)
		{
			local $ENV{GITHUB_USER} = 'testuser';
			local $ENV{GITHUB_AUTH_TOKEN} = 'ghp_test456token';
			$gh = Service::Github->new();
			is($gh->{creds}, 'testuser:ghp_test456token', 'user:token format with both ENV vars');
		}

		# Test custom values
		$gh = Service::Github->new(
			domain => 'gitlab.com',
			org => 'my-org',
			tls => 'no',
			label => 'My GitLab'
		);
		is($gh->{domain}, 'gitlab.com', 'custom domain');
		is($gh->{org}, 'my-org', 'custom org');
		is($gh->{tls}, 'no', 'custom tls');
		is($gh->{label}, 'My GitLab', 'custom label');

		# Test TLS normalization
		$gh = Service::Github->new(tls => 'invalid');
		is($gh->{tls}, 'skip', 'invalid TLS value normalizes to skip');

		$gh = Service::Github->new(tls => 'skip');
		is($gh->{tls}, 'skip', 'skip TLS value preserved');
	};

	subtest 'label() method' => sub {
		plan tests => 2;

		my $gh = Service::Github->new();
		is($gh->label, 'github.com/genesis-community', 'default label from domain/org');

		$gh = Service::Github->new(label => 'My Github');
		is($gh->label, 'My Github', 'custom label');
	};

	subtest 'base_url() method' => sub {
		plan tests => 4;

		my $gh = Service::Github->new();
		is($gh->base_url, 'https://api.github.com', 'default HTTPS base_url');

		$gh = Service::Github->new(tls => 'no');
		is($gh->base_url, 'http://api.github.com', 'HTTP base_url when tls=no');

		$gh = Service::Github->new(tls => 'skip');
		is($gh->base_url, 'https://api.github.com', 'HTTPS base_url when tls=skip');

		$gh = Service::Github->new(domain => 'gitlab.com');
		is($gh->base_url, 'https://api.gitlab.com', 'base_url with custom domain');
	};

	subtest 'repos_url() method' => sub {
		plan tests => 3;

		my $gh = Service::Github->new(org => 'test-org');
		is($gh->repos_url, 'https://api.github.com/users/test-org/repos',
			'repos_url without page');
		is($gh->repos_url(1), 'https://api.github.com/users/test-org/repos?page=1',
			'repos_url with page 1');
		is($gh->repos_url(5), 'https://api.github.com/users/test-org/repos?page=5',
			'repos_url with page 5');
	};

	subtest 'releases_url() method' => sub {
		plan tests => 3;

		my $gh = Service::Github->new(org => 'test-org');
		is($gh->releases_url('mykit'), 'https://api.github.com/repos/test-org/mykit/releases',
			'releases_url without page');
		is($gh->releases_url('mykit', 2), 'https://api.github.com/repos/test-org/mykit/releases?page=2',
			'releases_url with page');

		$gh = Service::Github->new(domain => 'gitlab.com', org => 'my-org');
		is($gh->releases_url('test-kit'), 'https://api.gitlab.com/repos/my-org/test-kit/releases',
			'releases_url with custom domain/org');
	};

	subtest 'release_version_urls() method' => sub {
		plan tests => 8;

		my $gh = Service::Github->new(org => 'test-org');

		# Test with version that already has 'v' prefix
		my $urls = $gh->release_version_urls('mykit', 'v1.0.0');
		isa_ok($urls, 'ARRAY', 'returns array reference');
		is(scalar(@$urls), 2, 'returns 2 URLs for v-prefixed version');
		like($urls->[0], qr/tags\/1\.0\.0$/, 'first URL strips v prefix');
		like($urls->[1], qr/tags\/v1\.0\.0$/, 'second URL keeps v prefix');

		# Test with version without 'v' prefix
		$urls = $gh->release_version_urls('mykit', '2.0.0');
		is(scalar(@$urls), 2, 'returns 2 URLs for non-prefixed version');
		like($urls->[0], qr/tags\/2\.0\.0$/, 'first URL without v');
		like($urls->[1], qr/tags\/v2\.0\.0$/, 'second URL adds v prefix');

		# Verify full URL structure
		$urls = $gh->release_version_urls('test-kit', '1.2.3');
		is($urls->[0], 'https://api.github.com/repos/test-org/test-kit/releases/tags/1.2.3',
			'complete URL structure correct');
	};
};

subtest 'validate_ssh_key method' => sub {
	plan tests => 8;

	my $gh = Service::Github->new(domain => 'github.com');

	# Valid keys
	ok($gh->validate_ssh_key('ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA test@example.com'),
		'validates ssh-rsa key');
	ok($gh->validate_ssh_key('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG'),
		'validates ssh-ed25519 key');
	ok($gh->validate_ssh_key('ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY'),
		'validates ecdsa-sha2-nistp256 key');

	# Invalid keys
	ok(!$gh->validate_ssh_key('invalid key format'),
		'rejects invalid key format');
	ok(!$gh->validate_ssh_key('ssh-rsa'),
		'rejects incomplete key');
	ok(!$gh->validate_ssh_key(''),
		'rejects empty string');
	ok(!$gh->validate_ssh_key(undef),
		'rejects undef');
	ok(!$gh->validate_ssh_key('BEGIN RSA PRIVATE KEY'),
		'rejects private key format');
};

done_testing;
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1
