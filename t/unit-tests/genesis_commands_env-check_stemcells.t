#!/usr/bin/env perl
use strict;
use warnings;

# The deploy's stemcell gate: what it does with each kind of stemcell check
# result, with and without --fix-stemcells and --dry-run.

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Exception;
use Test::Output;

use Genesis;
use_ok 'Genesis::Commands::Env';

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

my $unknown_msg = "required stemcells source unknown - requires manual upload:\n- #R{ubuntu-resolute\@0.999}";

# An env whose _check_stemcells returns $result, recording which of the
# advise and fix methods the gate calls.
sub make_env {
	my ($result, $calls) = @_;
	return mock "Mock::StemcellGate::Env" => {
		_check_stemcells        => sub { $result },
		_advise_stemcell_updates => sub { push @$calls, ['advise', $_[1]]; 1 },
		_fix_stemcells          => sub { push @$calls, ['fix', $_[1]]; {result => 'ok', msg => 'fixed'} },
		notify                  => sub { 1 },
	};
}

sub fatal_result {
	return {
		state    => 'error',
		fatal    => 1,
		msg      => $unknown_msg,
		fix_data => {missing => [{os => 'ubuntu-resolute', search_term => '0.999'}], alt => []},
	};
}

for my $dryrun (0, 1) {
	my $mode = $dryrun ? 'in a dry run' : 'outside a dry run';
	subtest "a fatal check with --fix-stemcells advises and stops $mode" => sub {
		plan tests => 4;
		my @calls;
		my $result = fatal_result();
		throws_ok {
			output_from {
				Genesis::Commands::Env::_deploy_check_stemcells(
					make_env($result, \@calls), fix => 1, dryrun => $dryrun, noprompt => 1,
				)
			}
		} qr/Stemcell check failed: required stemcells source unknown - requires manual upload:.*ubuntu-resolute\@0\.999/s,
			'stops with the manual-upload message';
		is(scalar(grep {$_->[0] eq 'fix'} @calls), 0, '_fix_stemcells is never called');
		is_deeply([map {$_->[0]} @calls], ['advise'], 'the gate advises exactly once');
		is($calls[0][1], $result->{fix_data}, 'advice gets the check result\'s fix_data');
	};
}

subtest 'a fatal check without --fix-stemcells advises and stops' => sub {
	plan tests => 2;
	my @calls;
	throws_ok {
		output_from {
			Genesis::Commands::Env::_deploy_check_stemcells(make_env(fatal_result(), \@calls), fix => 0)
		}
	} qr/Stemcell check failed: required stemcells source unknown/, 'stops with the manual-upload message';
	is_deeply([map {$_->[0]} @calls], ['advise'], 'advises, and does not fix');
};

subtest 'a fixable check with --fix-stemcells is fixed' => sub {
	plan tests => 3;
	my @calls;
	my $fix_data = {missing => [], alt => []};
	my $ok;
	lives_ok {
		output_from {
			$ok = Genesis::Commands::Env::_deploy_check_stemcells(
				make_env({state => 'error', msg => 'missing required or preferred stemcells', fix_data => $fix_data}, \@calls),
				fix => 1, dryrun => 0, noprompt => 1,
			)
		}
	} 'carries on';
	is($ok, 1, 'returns 1');
	is_deeply([map {$_->[0]} @calls], ['fix'], 'fixes, and does not advise');
};

subtest 'a fixable check with --fix-stemcells in a dry run says it would be fixed' => sub {
	plan tests => 2;
	my @calls;
	my ($out, $err) = output_from {
		Genesis::Commands::Env::_deploy_check_stemcells(
			make_env({state => 'error', msg => 'missing required or preferred stemcells', fix_data => {}}, \@calls),
			fix => 1, dryrun => 1,
		)
	};
	like($out.$err, qr/This would be fixed if not in dry-run mode/, 'says it would be fixed');
	is(scalar(@calls), 0, 'neither fixes nor advises');
};

subtest 'an ok check does nothing' => sub {
	plan tests => 2;
	my @calls;
	my $ok = Genesis::Commands::Env::_deploy_check_stemcells(
		make_env({state => 'ok', msg => 'all present'}, \@calls), fix => 1,
	);
	is($ok, 1, 'returns 1');
	is(scalar(@calls), 0, 'neither fixes nor advises');
};

done_testing;
