#!/usr/bin/env perl
use strict;
use warnings;
use lib 't';
use helper;

our $Logger;
use_ok 'Genesis::Log';

subtest 'constructor returns a blessed Genesis::Log object' => sub {
	my $log;
	lives_ok { $log = Genesis::Log->new() } 'new() does not die';
	isa_ok $log, 'Genesis::Log', 'new() returns a Genesis::Log object';
};

subtest 'singleton pattern' => sub {
	my $first  = Genesis::Log->new();
	my $second = Genesis::Log->new();
	is $second, $first, 'repeated new() calls return the same reference';
	no warnings 'once';
	is $Genesis::Log::Logger, $first, 'package variable holds the same singleton';
};

subtest '$Logger export matches new()' => sub {
	ok defined($Logger), '$Logger is defined after use Genesis::Log';
	isa_ok $Logger, 'Genesis::Log', '$Logger is a Genesis::Log object';
	is $Logger, Genesis::Log->new(), '$Logger matches Genesis::Log->new()';
};

subtest 'initial state - system identity fields' => sub {
	my $log = Genesis::Log->new();

	ok defined($log->{hostname}), 'hostname is defined';
	ok length($log->{hostname}) > 0, 'hostname is non-empty';

	ok defined($log->{user}), 'user is defined';
	ok length($log->{user}) > 0, 'user is non-empty';

	ok defined($log->{pid}), 'pid is defined';
	ok length($log->{pid}) > 0, 'pid is non-empty';

	# version is populated when $Genesis::VERSION is set and not "(development)"
	ok exists($log->{version}), 'version key exists in object';
};

subtest 'version field reflects Genesis::VERSION at construction time' => sub {
	my $log = Genesis::Log->new();
	# The constructor assigns: ($Genesis::VERSION eq "(development)") ? "0.0.0-rc.0" : $Genesis::VERSION
	# When $Genesis::VERSION is undef, eq warns and returns false, so version is also undef.
	# When $Genesis::VERSION is "(development)", version is "0.0.0-rc.0".
	# Otherwise version mirrors $Genesis::VERSION.
	if (defined($Genesis::VERSION) && $Genesis::VERSION eq '(development)') {
		is $log->{version}, '0.0.0-rc.0',
			'version is 0.0.0-rc.0 when Genesis::VERSION is (development)';
	} elsif (defined($Genesis::VERSION)) {
		is $log->{version}, $Genesis::VERSION,
			'version matches Genesis::VERSION when it is a release string';
	} else {
		ok !defined($log->{version}),
			'version is undef when Genesis::VERSION is undef (test environment)';
	}
};

subtest 'buffer initialized as empty arrayref' => sub {
	my $log = Genesis::Log->new();
	ok defined($log->{buffer}), 'buffer is defined';
	is ref($log->{buffer}), 'ARRAY', 'buffer is an arrayref';
	is scalar(@{$log->{buffer}}), 0, 'buffer is empty on initialization';
};

subtest 'logs initialized as empty hashref' => sub {
	my $log = Genesis::Log->new();
	ok defined($log->{logs}), 'logs is defined';
	is ref($log->{logs}), 'HASH', 'logs is a hashref';
	is scalar(keys %{$log->{logs}}), 0, 'logs is empty on initialization';
};

subtest 'internal tracking fields initialized as empty hashrefs' => sub {
	my $log = Genesis::Log->new();

	ok defined($log->{log_templates}), 'log_templates is defined';
	is ref($log->{log_templates}), 'HASH', 'log_templates is a hashref';
	is scalar(keys %{$log->{log_templates}}), 0, 'log_templates is empty on initialization';

	ok defined($log->{realized_logs}), 'realized_logs is defined';
	is ref($log->{realized_logs}), 'HASH', 'realized_logs is a hashref';
	is scalar(keys %{$log->{realized_logs}}), 0, 'realized_logs is empty on initialization';

	ok defined($log->{command_logged}), 'command_logged is defined';
	is ref($log->{command_logged}), 'HASH', 'command_logged is a hashref';
	is scalar(keys %{$log->{command_logged}}), 0, 'command_logged is empty on initialization';
};

subtest 'capture_stack_min_level defaults to 2' => sub {
	my $log = Genesis::Log->new();
	ok defined($log->{capture_stack_min_level}), 'capture_stack_min_level is defined';
	is $log->{capture_stack_min_level}, 2, 'capture_stack_min_level is set to 2';
};

done_testing;
