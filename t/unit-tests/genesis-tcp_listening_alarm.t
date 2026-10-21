#!/usr/bin/env perl
# tcp_listening() must not leave its connect timeout armed when it returns.
#
# It sets an alarm and opens the socket inside an eval.  A refused connection
# died out of the eval before the alarm was cancelled, and the eval's local
# SIGALRM handler went with it, so GENESIS_NETWORK_TIMEOUT seconds later the
# default SIGALRM action killed Genesis in the middle of whatever it was doing.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::More;
use IO::Socket::INET;
use POSIX qw/SIGALRM/;

use Genesis;

# A port that was free a moment ago refuses connections at once.
sub closed_port {
	my $sock = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp', Listen => 1)
		or die "cannot bind a local port: $!";
	my $port = $sock->sockport;
	close $sock;
	return $port;
}

local $ENV{GENESIS_NETWORK_TIMEOUT} = 1;

subtest 'a refused connection leaves no alarm pending' => sub {
	is(tcp_listening('127.0.0.1', closed_port()), 'failed', 'a closed port is reported as failed');
	is(alarm(0), 0, 'no alarm is left pending');
};

subtest 'a successful connection leaves no alarm pending' => sub {
	my $listener = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp', Listen => 1)
		or die "cannot bind a local port: $!";
	is(tcp_listening('127.0.0.1', $listener->sockport), 'ok', 'a listening port is reported as ok');
	is(alarm(0), 0, 'no alarm is left pending');
	close $listener;
};

subtest 'Genesis outlives the network timeout after a refused connection' => sub {
	my $port = closed_port();
	my $pid = fork() // die "cannot fork: $!";
	if (!$pid) {
		tcp_listening('127.0.0.1', $port);
		select(undef, undef, undef, 1.5);
		POSIX::_exit(0);
	}
	waitpid($pid, 0);
	isnt($? & 127, SIGALRM, 'the process is not killed by SIGALRM');
	is($? >> 8, 0, 'the process exits normally');
};

done_testing;
