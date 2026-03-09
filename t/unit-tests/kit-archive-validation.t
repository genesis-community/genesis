#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;

use_ok 'Genesis';
use_ok 'Genesis::Kit::Compiled';

use_ok 'Genesis::Config';
$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");

my $tmp = workdir;

# --- Test 1: Missing archive parameter ---
subtest 'missing archive parameter' => sub {
	throws_ok {
		Genesis::Kit::Compiled->new(name => 'x', version => '1.0.0')
	} qr/Missing required option: archive/,
		'dies with missing archive parameter';
};

# --- Test 2: Nonexistent archive file ---
subtest 'nonexistent archive file' => sub {
	throws_ok {
		Genesis::Kit::Compiled->new(
			name    => 'x',
			version => '1.0.0',
			archive => '/no/such/file.tar.gz'
		)
	} qr/does not exist/,
		'dies when archive file does not exist';
};

# --- Test 3: Unreadable archive file (permission denied) ---
SKIP: {
	skip "cannot test permission denied as root", 1 if $> == 0;

	subtest 'unreadable archive file' => sub {
		my $file = "$tmp/noread-1.0.0.tar.gz";
		put_file($file, "\x1f\x8b" . ("\x00" x 100));
		chmod 0000, $file;
		throws_ok {
			Genesis::Kit::Compiled->new(
				name    => 'noread',
				version => '1.0.0',
				archive => $file
			)
		} qr/cannot be read|permissions/i,
			'dies when archive file is unreadable';
		chmod 0644, $file;  # cleanup
	};
}

# --- Test 4: Empty archive file (0 bytes) ---
subtest 'empty archive file' => sub {
	put_file("$tmp/empty-1.0.0.tar.gz", "");
	throws_ok {
		Genesis::Kit::Compiled->new(
			name    => 'empty',
			version => '1.0.0',
			archive => "$tmp/empty-1.0.0.tar.gz"
		)
	} qr/empty.*0 bytes/i,
		'dies when archive file is empty';
};

# --- Test 5: HTML content instead of archive (proxy interception) ---
subtest 'HTML content instead of archive' => sub {
	put_file("$tmp/html-1.0.0.tar.gz",
		"<!DOCTYPE html><html><body>403 Forbidden</body></html>");
	throws_ok {
		Genesis::Kit::Compiled->new(
			name    => 'html',
			version => '1.0.0',
			archive => "$tmp/html-1.0.0.tar.gz"
		)
	} qr/HTML.*proxy|captive portal/i,
		'dies when archive contains HTML (proxy interception)';
};

# --- Test 6: Non-gzip binary content (corrupted file) ---
subtest 'non-gzip binary content' => sub {
	put_file("$tmp/corrupt-1.0.0.tar.gz", "\x00\x01\x02\x03" x 100);
	throws_ok {
		Genesis::Kit::Compiled->new(
			name    => 'corrupt',
			version => '1.0.0',
			archive => "$tmp/corrupt-1.0.0.tar.gz"
		)
	} qr/not.*valid gzip/i,
		'dies when archive is not a valid gzip file';
};

# --- Test 7: Truncated gzip (valid header, incomplete body) ---
subtest 'truncated gzip' => sub {
	put_file("$tmp/trunc-1.0.0.tar.gz", "\x1f\x8b\x08\x00" . ("\x00" x 16));
	throws_ok {
		Genesis::Kit::Compiled->new(
			name    => 'trunc',
			version => '1.0.0',
			archive => "$tmp/trunc-1.0.0.tar.gz"
		)
	} qr/could not be read|corrupted|truncated|Failed to read/i,
		'dies when archive is truncated';
};

# --- Test 8: Valid archive still works (regression guard) ---
subtest 'valid archive loads successfully' => sub {
	my $valid_kit = mk_test_kit('good', '1.0.0', $tmp);
	lives_ok {
		Genesis::Kit::Compiled->new(
			name    => 'good',
			version => '1.0.0',
			archive => $valid_kit
		)
	} 'valid kit archive loads without error';
};

# --- Test 9: local_kits skips corrupt archives instead of dying ---
subtest 'local_kits skips corrupt archives and returns valid kits' => sub {
	my $scan_dir = "$tmp/local_kits_test";
	mkdir $scan_dir unless -d $scan_dir;

	# Create one valid kit
	mk_test_kit('alpha', '1.0.0', $scan_dir);

	# Create one corrupt kit (HTML content, not a real tarball)
	put_file("$scan_dir/broken-2.0.0.tar.gz",
		"<!DOCTYPE html><html><body>403 Forbidden</body></html>");

	# Create another valid kit
	mk_test_kit('charlie', '3.0.0', $scan_dir);

	my $result;
	lives_ok {
		$result = Genesis::Kit::Compiled->local_kits(undef, $scan_dir);
	} 'local_kits does not die when a corrupt kit is present';

	ok defined($result), 'local_kits returns a result';
	ok ref($result) eq 'HASH', 'local_kits returns a hashref';
	ok exists($result->{alpha}), 'valid kit alpha is present in results';
	ok exists($result->{alpha}{'1.0.0'}), 'alpha version 1.0.0 is present';
	ok exists($result->{charlie}), 'valid kit charlie is present in results';
	ok exists($result->{charlie}{'3.0.0'}), 'charlie version 3.0.0 is present';
	ok !exists($result->{broken}), 'corrupt kit broken is not in results';
};

# --- Test 10: local_kits with only valid kits works normally ---
subtest 'local_kits with all valid kits works normally' => sub {
	my $scan_dir = "$tmp/local_kits_valid";
	mkdir $scan_dir unless -d $scan_dir;

	mk_test_kit('foo', '1.0.0', $scan_dir);
	mk_test_kit('bar', '2.0.0', $scan_dir);

	my $result;
	lives_ok {
		$result = Genesis::Kit::Compiled->local_kits(undef, $scan_dir);
	} 'local_kits works with all valid kits';

	ok exists($result->{foo}{'1.0.0'}), 'foo/1.0.0 found';
	ok exists($result->{bar}{'2.0.0'}), 'bar/2.0.0 found';
};

done_testing;
