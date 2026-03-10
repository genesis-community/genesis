#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use helper;
use Expect;

use Test::More;
use Test::Deep;
use Test::Differences;
use Test::Exception;

use_ok 'Genesis';

# Test run() - Core command execution function
subtest 'run() - basic command execution' => sub {
	my ($out, $rc, $err);

	# Simple command
	($out, $rc, $err) = run('echo "hello world"');
	is $rc, 0, 'simple echo returns 0';
	is $out, 'hello world', 'simple echo returns correct output';
	ok !defined($err), 'simple echo has no stderr (undef when not capturing)';

	# Command with exit code
	($out, $rc, $err) = run('exit 42');
	is $rc, 42, 'exit 42 returns correct exit code';

	# Command with stderr (use stderr=>0 to capture separately, brace group for redirect scope)
	($out, $rc, $err) = run({stderr => '0'}, '{ echo "error message" >&2; }');
	is $rc, 0, 'stderr command returns 0';
	like $err, qr/error message/, 'stderr captured correctly';
};

subtest 'run() - argument passing' => sub {
	my ($out, $rc, $err);

	# Arguments passed via array
	($out, $rc, $err) = run('echo "$1" "$2"', 'arg1', 'arg2');
	is $rc, 0, 'command with args returns 0';
	is $out, 'arg1 arg2', 'arguments passed correctly';

	# Arguments with special characters
	($out, $rc, $err) = run('echo "$1"', 'test "quoted" value');
	is $rc, 0, 'command with quoted args returns 0';
	like $out, qr/test "quoted" value/, 'quoted arguments handled correctly';
};

subtest 'run() - options hash' => sub {
	my ($out, $rc, $err);

	# onfailure option
	lives_ok {
		($out, $rc, $err) = run({onfailure => 'test failed'}, 'exit 0');
	} 'onfailure with success does not die';

	throws_ok {
		run({onfailure => 'test failed'}, 'exit 1');
	} qr/test failed/, 'onfailure with failure dies with message';

	# passfail option
	ok run({passfail => 1}, 'exit 0'), 'passfail returns true on success';
	ok !run({passfail => 1}, 'exit 1'), 'passfail returns false on failure';

	# dir option
	($out, $rc, $err) = run({dir => '/tmp'}, 'pwd');
	is $rc, 0, 'dir option command returns 0';
	like $out, qr{^/tmp|^/private/tmp}, 'dir option changes directory';
};

subtest 'run() - environment variables' => sub {
	my ($out, $rc, $err);

	# Set environment variable
	($out, $rc, $err) = run({env => {TEST_VAR => 'test_value'}}, 'echo "$TEST_VAR"');
	is $rc, 0, 'env option command returns 0';
	is $out, 'test_value', 'environment variable set correctly';

	# Unset environment variable
	$ENV{TEST_UNSET} = 'original';
	($out, $rc, $err) = run({env => {TEST_UNSET => undef}}, 'echo "VAR=${TEST_UNSET}"');
	is $rc, 0, 'env unset command returns 0';
	is $out, 'VAR=', 'environment variable unset correctly';
	is $ENV{TEST_UNSET}, 'original', 'original ENV not modified';
};

subtest 'run() - stderr handling' => sub {
	my ($out, $rc, $err);

	# Separate stderr capture (use stderr=>0 with brace group for correct redirect scope)
	($out, $rc, $err) = run({stderr => '0'}, '{ echo "stdout"; echo "stderr" >&2; }');
	is $rc, 0, 'stderr capture returns 0';
	is $out, 'stdout', 'stdout captured';
	like $err, qr/stderr/, 'stderr captured separately';

	# stderr merged to stdout (brace group so 2>&1 applies to entire command)
	($out, $rc, $err) = run({stderr => '&1'}, '{ echo "stdout"; echo "stderr" >&2; }');
	is $rc, 0, 'stderr redirect returns 0';
	like $out, qr/stdout.*stderr|stderr.*stdout/s, 'stderr redirected to stdout';
};

# Test lines() - Split command output into lines
subtest 'lines() - output splitting' => sub {
	my @lines;

	# Success with multiple lines
	@lines = lines(run('echo "line1"; echo "line2"; echo "line3"'));
	is scalar(@lines), 3, 'lines returns 3 lines on success';
	is $lines[0], 'line1', 'first line correct';
	is $lines[1], 'line2', 'second line correct';
	is $lines[2], 'line3', 'third line correct';

	# Failure returns empty
	@lines = lines(run('exit 1'));
	is scalar(@lines), 0, 'lines returns empty array on failure';

	# Single line
	@lines = lines(run('echo "single"'));
	is scalar(@lines), 1, 'lines returns 1 line for single line';
	is $lines[0], 'single', 'single line correct';

	# Empty output
	@lines = lines(run('echo -n ""'));
	ok scalar(@lines) <= 1, 'lines handles empty output';
};

# Test curl() - HTTP operations
subtest 'curl() - basic requests' => sub {
	SKIP: {
		skip "curl tests require network", 4 unless $ENV{TEST_NETWORK};

		my ($out, $rc, $err);

		# GET request
		($out, $rc, $err) = curl('GET', 'https://httpbin.org/get');
		is $rc, 0, 'GET request returns 0';
		like $out, qr/"url"/, 'GET request returns JSON response';

		# POST request
		($out, $rc, $err) = curl('POST', 'https://httpbin.org/post', {}, '{"test":"data"}');
		is $rc, 0, 'POST request returns 0';
		like $out, qr/"data"/, 'POST request returns JSON response';
	}
};

subtest 'curl() - headers and options' => sub {
	SKIP: {
		skip "curl tests require network", 3 unless $ENV{TEST_NETWORK};

		my ($out, $rc, $err);

		# Custom headers
		($out, $rc, $err) = curl('GET', 'https://httpbin.org/headers',
			{'X-Test-Header' => 'test-value'});
		is $rc, 0, 'custom headers request returns 0';
		like $out, qr/X-Test-Header/, 'custom header sent';
		like $out, qr/test-value/, 'custom header value sent';
	}
};

subtest 'curl() - error handling' => sub {
	# Invalid method
	throws_ok {
		curl('INVALID', 'https://example.com');
	} qr/Invalid method/, 'invalid method dies';

	# No URL
	throws_ok {
		curl('GET', undef);
	} qr/No url provided/, 'no URL dies';
};

# Test fake_tty() - OS-specific script wrapping
subtest 'fake_tty() - command wrapping' => sub {
	my @cmd;

	# Test wrapping
	@cmd = fake_tty('/tmp/output.txt', 'echo', 'hello');
	ok scalar(@cmd) > 0, 'fake_tty returns commands';

	if ($^O eq 'darwin') {
		is $cmd[0], 'script', 'Darwin uses script command';
		like join(' ', @cmd), qr/-qeF/, 'Darwin uses -qeF flags';
		like join(' ', @cmd), qr{/tmp/output\.txt}, 'Darwin includes output file';
	} elsif ($^O eq 'linux') {
		like $cmd[0], qr/script/, 'Linux uses script command';
		like $cmd[0], qr/-qf/, 'Linux uses -qf flags';
		like $cmd[0], qr{/tmp/output\.txt}, 'Linux includes output file';
	}
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
