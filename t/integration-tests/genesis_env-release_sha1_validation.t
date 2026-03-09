#!/usr/bin/perl
use strict;
use warnings;

# =============================================================================
# REBUILD REQUIRED - This test does not actually test Genesis::Env
# =============================================================================
#
# This test was originally intended to validate SHA1 checksum verification for
# BOSH releases in manifests, but it only tests inline logic and never calls
# the actual Genesis::Env method.
#
# The REAL implementation is: Genesis::Env::_check_release_url_sha1
#   - Located in lib/Genesis/Env.pm lines 5079-5133
#   - Called from Genesis::Env::check() method
#   - Uses $self->manifest_provider->deployment(subset=>'releases')->data
#   - Returns {state => 'ok'|'error', msg => ...}
#
# TO REBUILD THIS TEST:
#   1. Create a Genesis::Env object with a test environment
#   2. Mock or provide a manifest with releases (some with SHA1, some without)
#   3. Call $env->_check_release_url_sha1() or $env->check()
#   4. Verify the method correctly identifies missing SHA1s for http/https URLs
#   5. Verify file:// URLs are correctly ignored
#
# The test concepts below are valid but need to test against actual Genesis::Env
# =============================================================================

use lib 'lib';
use lib 't';
use helper;
use Test::More;

# Test the SHA1 validation logic directly
use_ok 'Genesis::Env';

# Mock test data
my $test_releases_missing_sha1 = [
    {
        name => "bosh",
        version => "270.12.0",
        url => "https://bosh.io/d/github.com/cloudfoundry/bosh?v=270.12.0",
        sha1 => "af876dc5f2c5c1a02fca850e1261cce0b5b1e899"
    },
    {
        name => "uaa",
        version => "74.5.0",
        url => "https://bosh.io/d/github.com/cloudfoundry/uaa-release?v=74.5.0",
        # Missing SHA1
    },
    {
        name => "local-release",
        version => "1.0.0",
        url => "file:///tmp/local-release.tgz",
        # File URLs don't need SHA1
    },
    {
        name => "another-http-release", 
        version => "2.0.0",
        url => "http://example.com/releases/another-release-2.0.0.tgz",
        # Missing SHA1
    }
];

my $test_releases_with_sha1 = [
    {
        name => "bosh",
        version => "270.12.0",
        url => "https://bosh.io/d/github.com/cloudfoundry/bosh?v=270.12.0",
        sha1 => "af876dc5f2c5c1a02fca850e1261cce0b5b1e899"
    },
    {
        name => "uaa",
        version => "74.5.0",
        url => "https://bosh.io/d/github.com/cloudfoundry/uaa-release?v=74.5.0",
        sha1 => "0ce0927b52b140ac5f6a86c1d21fb8c1c4488779"
    },
    {
        name => "local-release",
        version => "1.0.0",
        url => "file:///tmp/local-release.tgz",
        # File URLs don't need SHA1
    },
    {
        name => "another-http-release", 
        version => "2.0.0",
        url => "http://example.com/releases/another-release-2.0.0.tgz",
        sha1 => "1234567890abcdef1234567890abcdef12345678"
    }
];

# Test validation logic for missing SHA1s
subtest 'SHA1 validation for HTTP/HTTPS releases' => sub {
    my @missing_sha1 = ();
    
    # Test with releases missing SHA1
    for my $release (@$test_releases_missing_sha1) {
        if (defined($release->{url}) && $release->{url} =~ m{^https?://}) {
            unless (defined($release->{sha1}) && $release->{sha1} ne '') {
                push @missing_sha1, {
                    name => $release->{name},
                    version => $release->{version},
                    url => $release->{url}
                };
            }
        }
    }
    
    is scalar(@missing_sha1), 2, "should find 2 releases missing SHA1";
    is $missing_sha1[0]->{name}, "uaa", "first missing SHA1 should be uaa";
    is $missing_sha1[1]->{name}, "another-http-release", "second missing SHA1 should be another-http-release";
    
    # Test with all releases having SHA1
    @missing_sha1 = ();
    for my $release (@$test_releases_with_sha1) {
        if (defined($release->{url}) && $release->{url} =~ m{^https?://}) {
            unless (defined($release->{sha1}) && $release->{sha1} ne '') {
                push @missing_sha1, {
                    name => $release->{name},
                    version => $release->{version},
                    url => $release->{url}
                };
            }
        }
    }
    
    is scalar(@missing_sha1), 0, "should find no releases missing SHA1 when all have SHA1s";
};

# Test that file:// URLs are ignored
subtest 'file URLs do not require SHA1' => sub {
    my $file_release = {
        name => "local-release",
        version => "1.0.0",
        url => "file:///tmp/local-release.tgz"
    };
    
    my $needs_sha1 = 0;
    if (defined($file_release->{url}) && $file_release->{url} =~ m{^https?://}) {
        unless (defined($file_release->{sha1}) && $file_release->{sha1} ne '') {
            $needs_sha1 = 1;
        }
    }
    
    is $needs_sha1, 0, "file:// URLs should not require SHA1";
};

done_testing;