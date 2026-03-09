#!/usr/bin/env perl
use strict;
use warnings;
use lib 't';
use helper;

use_ok 'Genesis::Log';

subtest 'get_scope returns formatted scope string' => sub {
	my $scope;
	lives_ok { $scope = get_scope(0) } 'get_scope(0) does not die';
	ok(defined $scope, 'returns a defined value');
	like($scope, qr/genesis_log-get_scope\.t/, 'scope contains caller filename');
	like($scope, qr/L\d+/, 'scope contains line number');
};

done_testing;
