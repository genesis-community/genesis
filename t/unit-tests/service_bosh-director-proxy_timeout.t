#!perl
# status() must report a director that does not answer through BOSH_ALL_PROXY
# as unreachable, and must not leave its proxy timeout armed when it returns.
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Exception;

use Service::BOSH;
use Service::BOSH::Director;
use Genesis;

my $env_json = '{"Tables":[{"Content":"","Header":{"user":"User"},"Rows":[{"name":"proto-bosh","user":"admin","version":"280.0.23"}],"Notes":null}],"Blocks":null,"Lines":["Succeeded"]}';

sub proxied_director {
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	Service::BOSH::Director->new('proxied-bosh',
		url => 'https://10.99.0.4:25555', ca_cert => 'ca_cert',
		client => 'admin', secret => 'password'
	);
}

local $ENV{GENESIS_NETWORK_TIMEOUT} = 1;
local $ENV{BOSH_ALL_PROXY} = 'ssh+socks5://jumpbox@192.0.2.10:22?private-key=/tmp/jumpbox.key';
local $ENV{GENESIS_BOSH_COMMAND};
local $ENV{GENESIS_BOSH_VERIFIED};

subtest 'a director that hangs behind the proxy is unreachable' => sub {
	# Answers well after the timeout, so a lost timeout reads as success.
	fake_bosh(<<EOF);
#!/bin/bash
sleep 2
echo '$env_json'
EOF
	my $bosh = proxied_director();
	my $status = $bosh->status();
	is($status->{status}, 'unreachable', 'status is unreachable');
	like($status->{msg}, qr/timed out after 1 seconds?/, 'message gives the timeout');
	like($status->{msg}, qr{https://10\.99\.0\.4:25555}, 'message names the director');
	like($status->{msg}, qr{ssh\+socks5://jumpbox\@192\.0\.2\.10:22}, 'message names the proxy');
	unlike($status->{msg}, qr/private-key/, 'message leaves out the proxy query string');
	ok(!$bosh->{validated}, 'director is not marked validated');
	ok(!$ENV{GENESIS_BOSH_VERIFIED}, 'GENESIS_BOSH_VERIFIED is not set');
	is(alarm(0), 0, 'no alarm is left pending');

	delete $bosh->{validated};
	throws_ok { $bosh->connect_and_validate() }
		qr/Unable to connect to .*proxied-bosh.* BOSH director:\s*unreachable - timed out/s,
		'connect_and_validate bails naming the director';
};

subtest 'a director that answers behind the proxy is ok' => sub {
	fake_bosh(<<EOF);
#!/bin/bash
echo '$env_json'
EOF
	my $bosh = proxied_director();
	my $status = $bosh->status();
	is($status->{status}, 'ok', 'status is ok');
	is($status->{msg}, 'authorized as admin', 'message names the user');
	ok($bosh->{validated}, 'director is marked validated');
	is(alarm(0), 0, 'no alarm is left pending');
	delete $ENV{GENESIS_BOSH_VERIFIED};
};

subtest 'a failing bosh behind the proxy keeps its error' => sub {
	fake_bosh(<<EOF);
#!/bin/bash
echo >&2 'Fetching info: Performing request GET: dial tcp: connection refused'
exit 1
EOF
	my $bosh = proxied_director();
	my $status = $bosh->status();
	is($status->{status}, 'error', 'status is error');
	like($status->{msg}, qr/connection refused/, 'message carries the bosh error');
	ok(!$bosh->{validated}, 'director is not marked validated');
	is(alarm(0), 0, 'no alarm is left pending');
};

done_testing;
