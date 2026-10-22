#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Exception;
use Test::Output;
use POSIX qw(strftime);
use JSON::PP ();
use Sys::Hostname ();

use_ok "Service::BOSH";
use_ok "Service::BOSH::Director";
use Service::Vault;
use Genesis;

# ===========================================================================
# The network claims lock on a BOSH director
#
# Two operators deploying against the same director at the same moment must
# not both take the lock.  Each test below drives two acquirers against one
# lock record, and the race tests force the interleaving that the old
# check-then-set code lost: both acquirers read the record before either of
# them writes it.
#
# The mock vault keeps one versioned record per path and honours a
# check-and-set version the way a kv v2 mount does, or ignores versions the
# way a kv v1 mount does.  It also answers the plain get/set/clear calls,
# so the same tests can be run against code that only knew those.
# ===========================================================================

package MockLockVault {
	sub new {
		my ($class, %opts) = @_;
		return bless {
			kv_version => $opts{kv_version} // 2,
			store      => {},   # path => {version => N, data => {...}}
			plain      => {},   # "path:key" => value
			log        => [],
		}, $class;
	}

	sub url { 'https://vault.example.com:8200' }
	sub build_descriptor { 'mock-vault' }

	# What runs just before the next write lands, and just after it.  Each
	# fires once, so the code it calls writes without re-entering it.
	sub before_next_write { $_[0]{before_write} = $_[1] }
	sub after_next_write  { $_[0]{after_write}  = $_[1] }

	sub _before { my $hook = delete $_[0]{before_write}; $hook->() if $hook }
	sub _after  { my $hook = delete $_[0]{after_write};  $hook->() if $hook }

	sub kv_read {
		my ($self, $path) = @_;
		die $self->{read_error} if $self->{read_error};
		die $self->{read_errors}{$path} if $self->{read_errors}{$path};
		push @{$self->{log}}, ['read', $path];
		my $rec = $self->{store}{$path};
		return {
			data       => $rec ? {%{$rec->{data}}} : undef,
			version    => $self->{kv_version} == 2 ? ($rec ? $rec->{version} : 0) : undef,
			kv_version => $self->{kv_version},
		};
	}

	sub kv_write {
		my ($self, $path, $data, %opts) = @_;
		die "kv_write was given a check-and-set version on a kv v1 mount\n"
			if exists($opts{cas}) && $self->{kv_version} != 2;
		$self->_before;
		my $rec = $self->{store}{$path} //= {version => 0, data => {}};
		if (exists $opts{cas} && $opts{cas} != $rec->{version}) {
			push @{$self->{log}}, ['cas-mismatch', $path];
			return 0;
		}
		$rec->{data} = {%$data};
		# A writer that stores its pid as a JSON number, as Genesis did
		# before it kept every lock value a string
		$rec->{data}{pid} = 0 + $rec->{data}{pid}
			if ($self->{pid_form} // '') eq 'number' && defined($rec->{data}{pid});
		# Every version written, oldest first, as a kv v2 mount keeps them
		push @{$rec->{history}}, {%{$rec->{data}}};
		$rec->{version}++;
		push @{$self->{log}}, ['write', $path];
		$self->_after;
		# A failure after the vault accepted the write, such as a read that
		# never catches up on an HA vault, or a signal
		if (my $err = delete $self->{die_after_write}) { die $err }
		return $self->{kv_version} == 2 ? $rec->{version} : 1;
	}

	# A refused delete dies, as Service::Vault::kv_delete does.
	sub kv_delete {
		my ($self, $path) = @_;
		die "Could not delete $path from the vault: permission denied\n" if $self->{delete_refused};
		$self->_before;
		delete $self->{store}{$path};
		push @{$self->{log}}, ['write', $path];
		$self->_after;
		return 1;
	}

	# The plain calls, as the check-then-set code used them
	sub get {
		my ($self, $path, $key) = @_;
		push @{$self->{log}}, ['read', "$path:$key"];
		return $self->{plain}{"$path:$key"};
	}
	sub set {
		my ($self, $path, $key, $value) = @_;
		$self->_before;
		$self->{plain}{"$path:$key"} = $value;
		push @{$self->{log}}, ['write', "$path:$key"];
		$self->_after;
		return $value;
	}
	# Service::Vault::clear asks has() first, and a vault that refuses the
	# read answers that nothing is there, so nothing is deleted and no error
	# is raised.
	sub clear {
		my ($self, $full) = @_;
		return if $self->{delete_refused};
		$self->_before;
		delete $self->{plain}{$full};
		delete $self->{store}{$full};
		push @{$self->{log}}, ['write', $full];
		$self->_after;
		return 1;
	}

	# How many reads of a path happened before the first write landed
	sub reads_before_first_write {
		my ($self, $path) = @_;
		my $n = 0;
		for (@{$self->{log}}) {
			last if $_->[0] eq 'write';
			$n++ if $_->[0] eq 'read' && $_->[1] eq $path;
		}
		return $n;
	}

	# Every write or delete the vault was asked to make to a path or to a key of it
	sub writes_to {
		my ($self, $path) = @_;
		return grep { $_->[0] eq 'write' && $_->[1] =~ m{^\Q$path\E(?::|$)} } @{$self->{log}};
	}
}

local $ENV{GENESIS_BOSH_COMMAND};
fake_bosh('');
Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});

my $EXODUS = 'secret/exodus/lock-test/bosh';
my $LOCK_PATH = "$EXODUS/network-claim-lock";

sub director {
	my ($vault) = @_;
	return Service::BOSH::Director->new(
		'lock-test',
		url          => 'https://127.0.0.1:25555',
		ca_cert      => 'ca_cert',
		client       => 'admin',
		secret       => 'password',
		exodus_path  => $EXODUS,
		exodus_vault => $vault,
	);
}

# Runs $code as a second process would: with its own lock owner token.
sub as_other_process {
	my ($code) = @_;
	no warnings 'once';
	# A lexical key: local() does not restore an element keyed by $$ itself.
	my $pid = $$;
	local $Service::BOSH::Director::NETWORK_LOCK_TOKENS{$pid} = 'other-process-token';
	return $code->();
}

sub try_acquire {
	my ($bosh) = @_;
	return eval { quietly { $bosh->acquire_network_lock() }; 1 } ? 'won' : "refused: $@";
}

sub lock_record {
	my (%fields) = @_;
	return {
		at       => strftime('%Y-%m-%d %H:%M:%S +0000', gmtime(time - ($fields{age} // 60))),
		hostname => $fields{hostname} // 'other-host',
		user     => $fields{user}     // 'other-user',
		pid      => $fields{pid}      // 4242,
		env      => $fields{env}      // 'other-env',
		token    => $fields{token}    // 'held-elsewhere',
	};
}

# Seeds the record in whichever form the code under test reads.
sub seed_lock {
	my ($vault, $record) = @_;
	my $rec = $vault->{store}{$LOCK_PATH} //= {version => 0, data => {}};
	$rec->{data} = {%$record};
	$rec->{version}++;
	$vault->{plain}{"$EXODUS:network-claim-lock"} = JSON::PP::encode_json($record);
}

# Seeds the lock as Genesis wrote it before the lock had a secret of its own:
# a JSON string in the network-claim-lock key of the director's exodus
# secret, alongside the exodus data itself.
sub seed_legacy_lock {
	my ($vault, $record) = @_;
	$vault->{store}{$EXODUS} = {
		version => 3,
		data    => {
			url                  => 'https://127.0.0.1:25555',
			'network-claim-lock' => JSON::PP::encode_json($record),
		},
	};
}

# ---------------------------------------------------------------------------
# The races
# ---------------------------------------------------------------------------

subtest 'two acquirers that both read a free lock before either writes: exactly one wins' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	my ($first, $second) = (director($vault), director($vault));

	my $second_result;
	$vault->before_next_write(sub {
		$second_result = as_other_process(sub { try_acquire($second) });
	});
	my $first_result = try_acquire($first);
	my $user = $ENV{USER} // 'unknown';

	is($vault->reads_before_first_write($LOCK_PATH), 2,
		'both acquirers read the lock record before either write landed');
	is(scalar(grep { $_ eq 'won' } $first_result, $second_result), 1,
		'exactly one of the two acquirers takes the lock')
		or diag "first: $first_result\nsecond: $second_result";
	like($first_result, qr/^refused: .*held by \Q$user\E\@.*between this process's check/s,
		'the loser is refused, and told who holds the lock')
		or diag $first_result;
	like($first_result, qr/lock-test/, 'the refusal names the director');
	like($first_result, qr/\Q$LOCK_PATH\E/, 'the refusal names where the lock is stored');
	ok(as_other_process(sub { $second->network_locked_by_me }),
		'the winner holds the lock');
	ok(!$first->network_locked_by_me, 'the loser does not');
};

subtest 'two acquirers that both find the same stale lock: exactly one takes it over' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	seed_lock($vault, lock_record(age => 7200));
	my ($first, $second) = (director($vault), director($vault));

	my $second_result;
	$vault->before_next_write(sub {
		$second_result = as_other_process(sub { try_acquire($second) });
	});
	my $first_result = try_acquire($first);

	is(scalar(grep { $_ eq 'won' } $first_result, $second_result), 1,
		'exactly one of the two acquirers takes over the stale lock')
		or diag "first: $first_result\nsecond: $second_result";
	ok(as_other_process(sub { $second->network_locked_by_me }),
		'the one that wrote first holds it');
	like($first_result, qr/^refused: /, 'the other is refused');
};

subtest 'clearing a stale lock does not remove a lock another process has since taken' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	seed_lock($vault, lock_record(age => 7200));
	my ($first, $second) = (director($vault), director($vault));

	# Both operators are shown the same stale lock and agree to clear it.
	my $seen_by_first  = $first->check_network_lock;
	my $seen_by_second = as_other_process(sub { $second->check_network_lock });
	is($seen_by_first->{status}, 'stale', 'the first operator sees the stale lock');
	is($seen_by_second->{status}, 'stale', 'so does the second');

	ok($first->clear_network_lock(stale => $seen_by_first), 'the first clears it');
	is(try_acquire($first), 'won', 'and takes the lock');

	my $cleared = as_other_process(sub { $second->clear_network_lock(stale => $seen_by_second) });
	ok(!$cleared, 'the second finds the stale lock already gone and clears nothing');
	ok($first->network_locked_by_me, "the first process's lock is still in place");
	my $second_result = as_other_process(sub { try_acquire($second) });
	like($second_result, qr/^refused: /, 'and the second is refused when it tries to take the lock');
};

subtest 'releasing a lock that went stale does not remove the lock that replaced it' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	my ($first, $second) = (director($vault), director($vault));

	is(try_acquire($first), 'won', 'the first process takes the lock');
	# It then outlives the lock timeout, and another process takes over.
	$vault->{store}{$LOCK_PATH}{data}{at} =
		strftime('%Y-%m-%d %H:%M:%S +0000', gmtime(time - 7200));
	$vault->{plain}{"$EXODUS:network-claim-lock"} = JSON::PP::encode_json($vault->{store}{$LOCK_PATH}{data})
		if exists $vault->{plain}{"$EXODUS:network-claim-lock"};
	is(as_other_process(sub { try_acquire($second) }), 'won', 'the second takes over the stale lock');

	ok(!$first->network_locked_by_me, 'the first process no longer holds it');
	ok(!$first->clear_network_lock, "so the first process's release removes nothing");
	ok(as_other_process(sub { $second->network_locked_by_me }), "and the second process's lock is still in place");
};

subtest 'kv v1: a write that a competing write overtook is detected and refused' => sub {
	my $vault = MockLockVault->new(kv_version => 1);
	my $first = director($vault);
	no warnings 'once';
	local $Service::BOSH::Director::NETWORK_LOCK_SETTLE_SECONDS = 0;

	# A second process read the lock as free before this write landed, and
	# its own write lands just after it.
	$vault->after_next_write(sub {
		seed_lock($vault, lock_record(age => 0, user => 'racing-user', token => 'racing-token'));
	});
	my $result = try_acquire($first);
	like($result, qr/^refused: .*racing-user\@/s,
		'the overtaken writer is refused and told who holds the lock')
		or diag $result;
	like($result, qr/kv v1/i, 'and told the mount offers no check-and-set');
	ok(!$first->network_locked_by_me, 'and it does not hold the lock');
};

# ---------------------------------------------------------------------------
# A lock held by an older Genesis
#
# Before the lock had a secret of its own, Genesis kept it as JSON in the
# network-claim-lock key of the exodus secret, and never reads the new
# secret.  During a rollout an older Genesis can be deploying against the
# same director, so taking the new lock has to look at the old key first.
# ---------------------------------------------------------------------------

for my $kv_version (2, 1) {
	subtest "kv v$kv_version: a fresh lock under the old key refuses, naming the holder" => sub {
		my $vault = MockLockVault->new(kv_version => $kv_version);
		no warnings 'once';
		local $Service::BOSH::Director::NETWORK_LOCK_SETTLE_SECONDS = 0;
		seed_legacy_lock($vault, lock_record(
			age => 120, user => 'olduser', hostname => 'oldjumpbox', pid => 31337, env => 'lab-old',
		));
		my $result = try_acquire(director($vault));
		like($result, qr/^refused: /, 'the lock is not taken');
		like($result, qr/older Genesis/, 'the refusal says an older Genesis appears to be deploying');
		like($result, qr/olduser\@oldjumpbox/, 'and names the user and host that hold the old lock');
		like($result, qr/pid: 31337/, 'and its pid');
		like($result, qr/lab-old/, 'and the environment it was taken for');
		like($result, qr/ago/, 'and how long ago it was taken');
		like($result, qr/lock-test/, 'and the director');
		like($result, qr/usually means/, 'and the likely cause');
		like($result, qr/safe\s+get\s+\Q$EXODUS:network-claim-lock\E/, 'and how to check the old key');
		like($result, qr/safe\s+rm\s+-f\s+\Q$EXODUS:network-claim-lock\E/, 'and how to clear it when it is stale');
		ok(!exists $vault->{store}{$LOCK_PATH}, 'and nothing was written to the new lock');
	};
}

subtest 'a fresh old lock from a dead process on this host is stale, as the older Genesis counts it' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	my $dead_pid = fork();
	if (defined($dead_pid) && $dead_pid == 0) { exit 0; }
	waitpid($dead_pid, 0) if defined($dead_pid);
	seed_legacy_lock($vault, lock_record(age => 60, hostname => Sys::Hostname::hostname(), pid => $dead_pid));
	is(try_acquire(director($vault)), 'won', 'the lock is taken');
};

subtest 'a stale lock under the old key does not block' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	seed_legacy_lock($vault, lock_record(age => 7200, user => 'crashed-user'));
	is(try_acquire(director($vault)), 'won', 'the lock is taken');
	ok(director($vault)->network_locked_by_me, 'and is held by this process');

	my $record = lock_record(age => 1700);
	my $fresh = MockLockVault->new(kv_version => 2);
	seed_legacy_lock($fresh, $record);
	like(try_acquire(director($fresh)), qr/^refused: .*older Genesis/s,
		'one just inside the thirty minute limit still blocks');

	my $max_age = MockLockVault->new(kv_version => 2);
	seed_legacy_lock($max_age, lock_record(age => 600));
	is(quietly { eval { director($max_age)->acquire_network_lock(max_lock_age => 300); 1 } ? 'won' : "refused: $@" },
		'won', 'max_lock_age applies to the old lock as it does to the new one');
};

subtest 'an absent old key does not block' => sub {
	my $none = MockLockVault->new(kv_version => 2);
	is(try_acquire(director($none)), 'won', 'no exodus secret at all');

	my $no_field = MockLockVault->new(kv_version => 2);
	$no_field->{store}{$EXODUS} = {version => 1, data => {url => 'https://127.0.0.1:25555'}};
	is(try_acquire(director($no_field)), 'won', 'an exodus secret without the lock field');

	my $empty = MockLockVault->new(kv_version => 2);
	$empty->{store}{$EXODUS} = {version => 1, data => {'network-claim-lock' => ''}};
	is(try_acquire(director($empty)), 'won', 'an empty lock field');
};

subtest 'an old lock value that is not a lock record does not block, and is warned about' => sub {
	for my $junk ('not json at all', '{"user":"x"}', '{"at":"yesterday"}') {
		my $vault = MockLockVault->new(kv_version => 2);
		$vault->{store}{$EXODUS} = {version => 1, data => {'network-claim-lock' => $junk}};
		my ($result, $out);
		$out = join('', output_from(sub {
			$result = eval { director($vault)->acquire_network_lock; 'won' } || "refused: $@";
		}));
		is($result, 'won', "the lock is taken over '$junk'");
		like($out, qr/network-claim-lock.*is\s+not\s+a\s+lock\s+record/s, '... with a warning that names the key')
			or diag $out;
	}
};

subtest 'an old-key read the vault refuses stops the acquire' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	$vault->{read_errors}{$EXODUS} = "Could not read $EXODUS from the vault: 403 permission denied\n";
	my $result = try_acquire(director($vault));
	like($result, qr/^refused: /, 'the lock is not taken');
	like($result, qr/permission denied/, 'the vault\'s reason is kept');
	like($result, qr/older Genesis/, 'and it says why the old key matters');
	like($result, qr/lock-test/, 'it names the director');
	like($result, qr/\Q$EXODUS\E/, 'and the path it could not read');
	like($result, qr/usually means|likely/i, 'and the likely causes');
	like($result, qr/safe\s+get\s+\Q$EXODUS:network-claim-lock\E/, 'and what to check');
	ok(!exists $vault->{store}{$LOCK_PATH}, 'and nothing was written to the new lock');
	is(scalar($vault->writes_to($EXODUS)) + scalar($vault->writes_to($LOCK_PATH)), 0, 'and nothing was written at all');
};

subtest 'the old key is only ever read' => sub {
	for my $case (
		['kv v2, fresh old lock',  2, 120],
		['kv v2, stale old lock',  2, 7200],
		['kv v1, stale old lock',  1, 7200],
	) {
		my ($name, $kv_version, $age) = @$case;
		my $vault = MockLockVault->new(kv_version => $kv_version);
		no warnings 'once';
		local $Service::BOSH::Director::NETWORK_LOCK_SETTLE_SECONDS = 0;
		my $record = lock_record(age => $age);
		seed_legacy_lock($vault, $record);
		my $before = JSON::PP->new->canonical->encode($vault->{store}{$EXODUS});
		my $bosh = director($vault);
		try_acquire($bosh);
		$bosh->clear_network_lock;
		is(scalar($vault->writes_to($EXODUS)), 0, "$name: no write or delete was issued against the old key");
		is(JSON::PP->new->canonical->encode($vault->{store}{$EXODUS}), $before, "$name: and the old record is as it was");
		is(scalar(grep { $_->[0] eq 'read' && $_->[1] eq $EXODUS } @{$vault->{log}}), 1,
			"$name: it was read once");
	}
};

subtest 'a fresh old lock that appears after this process took its lock stops the claims write' => sub {
	for my $kv_version (2, 1) {
		my $vault = MockLockVault->new(kv_version => $kv_version);
		no warnings 'once';
		local $Service::BOSH::Director::NETWORK_LOCK_SETTLE_SECONDS = 0;
		my $bosh = director($vault);
		is(try_acquire($bosh), 'won', "kv v$kv_version: the lock is taken with no older lock about");
		ok($bosh->ensure_network_lock_held('write the network claims'), "kv v$kv_version: and the claims may be written");

		# An older Genesis starts after the lock was taken, and takes its own.
		seed_legacy_lock($vault, lock_record(age => 30, user => 'lateuser', hostname => 'latebox', pid => 555, env => 'lab-late'));
		my $before = JSON::PP->new->canonical->encode($vault->{store}{$EXODUS});
		throws_ok { $bosh->ensure_network_lock_held('write the network claims') }
			qr/Cannot write the network claims.*lock-test.*older Genesis.*lateuser\@latebox.*lab-late.*pid: 555/s,
			"kv v$kv_version: the write is refused, naming the older Genesis and its holder";
		throws_ok { $bosh->ensure_network_lock_held('write the network claims') }
			qr/safe\s+get\s+\Q$EXODUS:network-claim-lock\E.*safe\s+rm\s+-f\s+\Q$EXODUS:network-claim-lock\E/s,
			"kv v$kv_version: and gives the commands that check and clear the old key";
		is(scalar($vault->writes_to($EXODUS)), 0, "kv v$kv_version: nothing was written to the old key");
		is(JSON::PP->new->canonical->encode($vault->{store}{$EXODUS}), $before, "kv v$kv_version: the old record is as it was");
		ok($bosh->network_locked_by_me, "kv v$kv_version: and this process still holds its own lock, for its release to clear");

		# Once that lock is stale, or gone, the claims may be written again.
		seed_legacy_lock($vault, lock_record(age => 7200));
		ok($bosh->ensure_network_lock_held('write the network claims'), "kv v$kv_version: a stale old lock does not stop the write");
		delete $vault->{store}{$EXODUS};
		ok($bosh->ensure_network_lock_held('write the network claims'), "kv v$kv_version: nor does an absent one");
	}
};

subtest 'a vault that refuses the old-key read stops the claims write' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	my $bosh = director($vault);
	is(try_acquire($bosh), 'won', 'the lock is taken');
	$vault->{read_errors}{$EXODUS} = "Could not read $EXODUS from the vault: 403 permission denied\n";
	throws_ok { $bosh->ensure_network_lock_held('write the network claims') }
		qr/Cannot write the network claims.*older Genesis.*permission denied/s,
		'the write is refused, with the vault\'s reason';
};

subtest 'a lock this process lost is still reported as lost, before the old key is looked at' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	my $bosh = director($vault);
	$vault->{read_errors}{$EXODUS} = "Could not read $EXODUS from the vault: 403 permission denied\n";
	throws_ok { $bosh->ensure_network_lock_held('write the network claims') }
		qr/no longer holds the network claims lock/, 'the lost lock is what is reported';
};

# ---------------------------------------------------------------------------
# The lock's ordinary life
# ---------------------------------------------------------------------------

subtest 'acquire, check, and release on a kv v2 mount' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	my $bosh = director($vault);

	is($bosh->check_network_lock->{status}, 'unlocked', 'a director with no lock record is unlocked');
	is(try_acquire($bosh), 'won', 'the lock is taken when it is free');
	my $status = $bosh->check_network_lock;
	is($status->{status}, 'locked', 'and then reads as locked');
	is($status->{lock}{user}, $ENV{USER} // 'unknown', 'by this user');
	is($status->{lock}{pid}, $$, 'and this process');
	ok($bosh->network_locked_by_me, 'network_locked_by_me() is true for the holder');

	like(try_acquire(director($vault)), qr/^refused: /,
		'a second take by the same process is refused rather than nested');

	ok($bosh->clear_network_lock, 'the holder releases it');
	is($bosh->check_network_lock->{status}, 'unlocked', 'and the director is unlocked again');
	ok(!$bosh->network_locked_by_me, 'network_locked_by_me() is false after release');
	ok(!$bosh->clear_network_lock, 'releasing again removes nothing');
	is(try_acquire($bosh), 'won', 'and the lock can be taken again after a release');
};

subtest 'acquire and release on a kv v1 mount' => sub {
	my $vault = MockLockVault->new(kv_version => 1);
	my $bosh = director($vault);
	no warnings 'once';
	local $Service::BOSH::Director::NETWORK_LOCK_SETTLE_SECONDS = 0;

	is(try_acquire($bosh), 'won', 'the lock is taken when it is free');
	ok($bosh->network_locked_by_me, 'and is held by this process');
	ok($bosh->clear_network_lock, 'the holder releases it');
	is($bosh->check_network_lock->{status}, 'unlocked', 'and the director is unlocked again');
};

subtest 'a lock held by another process is refused with the specifics' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	seed_lock($vault, lock_record(age => 120, user => 'jdoe', hostname => 'jumpbox', pid => 777, env => 'lab-ocf'));
	my $result = try_acquire(director($vault));
	like($result, qr/^refused: /, 'the lock is not taken');
	like($result, qr/jdoe\@jumpbox/, 'the refusal names the holder');
	like($result, qr/lab-ocf/, 'and the environment it was taken for');
	like($result, qr/pid: 777/, 'and its pid');
	like($result, qr/ago/, 'and how long ago it was taken');
	like($result, qr/lock-test/, 'and the director');
	like($result, qr/\Q$LOCK_PATH\E/, 'and where the lock is stored');
	like($result, qr/usually means/, 'and the likely cause');
};

subtest 'stale locks' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	my $bosh = director($vault);

	seed_lock($vault, lock_record(age => 7200));
	is($bosh->check_network_lock(max_lock_age => 1800)->{status}, 'stale',
		'a lock older than max_lock_age is stale');
	is(try_acquire($bosh), 'won', 'acquire takes over a stale lock');
	ok($bosh->network_locked_by_me, 'and then holds it');

	# A lock taken on this host by a process that has exited can never be
	# released by its owner, so it is stale however fresh it is.
	my $dead_pid = fork();
	if (defined($dead_pid) && $dead_pid == 0) { exit 0; }
	waitpid($dead_pid, 0) if defined($dead_pid);
	seed_lock($vault, lock_record(age => 60, hostname => Sys::Hostname::hostname(), pid => $dead_pid));
	is($bosh->check_network_lock(max_lock_age => 1800)->{status}, 'stale',
		'a same-host lock whose pid is dead is stale, even when fresh');

	seed_lock($vault, lock_record(age => 60, hostname => Sys::Hostname::hostname(), pid => $$));
	is($bosh->check_network_lock(max_lock_age => 1800)->{status}, 'locked',
		'a same-host lock whose pid is alive is not');
};

subtest 'clearing a stale lock that is still the same record' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	my $bosh = director($vault);
	seed_lock($vault, lock_record(age => 7200));
	my $seen = $bosh->check_network_lock;
	ok($bosh->clear_network_lock(stale => $seen), 'the stale lock is cleared');
	is($bosh->check_network_lock->{status}, 'unlocked', 'and the director is unlocked');
};

# ---------------------------------------------------------------------------
# Failures around the lock
# ---------------------------------------------------------------------------

subtest 'a lock taken on a host that is not on UTC records the right time' => sub {
	use Time::Piece ();
	my $saved = $ENV{TZ};
	for my $tz ('America/Chicago', 'Asia/Kolkata', 'UTC') {
		local $ENV{TZ} = $tz;
		POSIX::tzset();
		my $vault = MockLockVault->new(kv_version => 2);
		my $bosh = director($vault);
		is(try_acquire($bosh), 'won', "$tz: the lock is taken");
		my $at = $vault->{store}{$LOCK_PATH}{data}{at};
		my $when = Time::Piece->strptime($at, '%Y-%m-%d %H:%M:%S %z');
		cmp_ok(abs($when->epoch - time), '<=', 5, "$tz: the time it records is now, wherever it is read")
			or diag "recorded $at";
		my $status = $bosh->check_network_lock;
		is($status->{status}, 'locked', "$tz: a lock just taken is neither stale nor waiting to be");
		cmp_ok(abs($status->{age}), '<=', 5, "$tz: and is seconds old");
	}
	defined($saved) ? ($ENV{TZ} = $saved) : delete($ENV{TZ});
	POSIX::tzset();
};

subtest 'a process that lost its lock while it waited is stopped before it changes anything' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	my ($first, $second) = (director($vault), director($vault));
	is(try_acquire($first), 'won', 'the first process takes the lock');
	ok($first->ensure_network_lock_held('upload the cloud config'), 'and may go on while it holds it');

	# The first waits at a prompt past the stale timeout, and a second
	# process clears the lock and takes it.
	$vault->{store}{$LOCK_PATH}{data}{at} = strftime('%Y-%m-%d %H:%M:%S +0000', gmtime(time - 7200));
	is(as_other_process(sub { try_acquire($second) }), 'won', 'the second takes over the stale lock');

	my $user = $ENV{USER} // 'unknown';
	throws_ok { $first->ensure_network_lock_held('upload the cloud config') }
		qr/Cannot upload the cloud config.*lock-test.*no longer holds.*\Q$user\E\@.*stale.*\Q$LOCK_PATH\E/s,
		'the first is stopped, and told who holds the lock now and why it lost it';

	ok(as_other_process(sub { $second->clear_network_lock }), 'once the second releases it');
	throws_ok { $first->ensure_network_lock_held('write the network claims') }
		qr/Cannot write the network claims.*no longer holds.*nothing holds it now/s,
		'the first is still stopped, and told that nothing holds the lock';
};

subtest 'a write that fails after it may have landed says the lock may be held, and how to clear it' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	my $bosh = director($vault);
	$vault->{die_after_write} = "Wrote version 1 of $LOCK_PATH, but reads still returned version 0 after 10s.\n";
	my $result = try_acquire($bosh);
	like($result, qr/^refused: .*reads still returned version 0/s, 'the vault\'s failure is kept')
		or diag $result;
	like($result, qr/may now hold the network claims lock/, 'and it says this process may now hold the lock');
	like($result, qr/safe rm \Q$LOCK_PATH\E/, 'and how to clear it');
	ok($bosh->network_locked_by_me, 'which it does, so a release by its caller removes it');
	ok($bosh->clear_network_lock, 'and the release does');

	$vault->{die_after_write} = "Hung up\n";
	my $signal = eval { quietly { $bosh->acquire_network_lock }; 1 } ? '' : $@;
	like($signal, qr/^Hung up\b/, 'a signal during the write passes through as it came');
	unlike($signal, qr/may now hold/, 'with nothing added to it');
};

subtest 'a release that cannot read the lock says its state is unknown, and never dies' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	my $bosh = director($vault);
	is(try_acquire($bosh), 'won', 'the lock is taken');

	$vault->{read_error} = "Could not read $LOCK_PATH from the vault: Vault is sealed\n";
	my ($result, $out);
	lives_ok { $out = join('', output_from(sub { $result = $bosh->release_network_lock })) }
		'a release against an unreadable vault does not die';
	ok(!defined($result), 'it reports that the release failed');
	my $flat = $out =~ s/\s+/ /gr;
	like($flat, qr/could not be read.*Vault is sealed/, 'and logs that the lock state could not be read, and why');
	like($flat, qr/not known whether (?:this process|a lock)/i, 'and that it is not known whether a lock is held');
	unlike($flat, qr/could not be released/, 'without claiming that a release failed');
	like($flat, qr/lock-test/, 'naming the director');
	like($flat, qr/safe get \Q$LOCK_PATH\E/, 'and giving the command that shows the lock');
	like($flat, qr/safe vault status/, 'and the one that checks the vault');
	like($flat, qr/stale/, 'and when other deploys can take it');

	delete $vault->{read_error};
	is(quietly { $bosh->release_network_lock }, 1, 'a release of this process\'s lock returns 1');
	is($bosh->check_network_lock->{status}, 'unlocked', 'and removes it');
	is(quietly { $bosh->release_network_lock }, 0, 'with nothing of ours to release, it returns 0');
};

subtest 'a release whose delete fails is logged as a failed release, and never dies' => sub {
	my $vault = MockLockVault->new(kv_version => 1);
	my $bosh = director($vault);
	no warnings 'once';
	local $Service::BOSH::Director::NETWORK_LOCK_SETTLE_SECONDS = 0;
	is(try_acquire($bosh), 'won', 'the lock is taken');
	$vault->{delete_refused} = 1;
	my ($result, $out);
	lives_ok { $out = join('', output_from(sub { $result = $bosh->release_network_lock })) }
		'a release the vault refuses does not die';
	ok(!defined($result), 'it reports that the release failed');
	my $flat = $out =~ s/\s+/ /gr;
	like($flat, qr/could not be released.*permission denied/, 'and logs that the lock could not be released, and why');
	unlike($flat, qr/could not be read/, 'without saying the state was unreadable');
	like($flat, qr/\Q$LOCK_PATH\E/, 'and where the lock is stored');
	like($flat, qr/stale/, 'and when other deploys can take it');
};

subtest 'a release that finds the lock taken by another process reports that it released nothing' => sub {
	my $vault = MockLockVault->new(kv_version => 2);
	my $bosh = director($vault);
	is(try_acquire($bosh), 'won', 'the lock is taken');

	# Another process clears the lock as stale and takes it between the
	# release's ownership check and its clear.
	my $reads = 0;
	my $real_read = \&MockLockVault::kv_read;
	no warnings 'redefine';
	local *MockLockVault::kv_read = sub {
		my $read = $real_read->(@_);
		if (++$reads == 1) {
			my $rec = $vault->{store}{$LOCK_PATH};
			$rec->{data} = {%{$rec->{data}}, token => 'another-process', pid => getppid()};
			$rec->{version}++;
		}
		return $read;
	};
	my $result;
	my $out = join('', output_from(sub { $result = $bosh->release_network_lock }));
	is($result, 0, 'the release reports that nothing was released');
	unlike($out, qr/done/, 'without saying it was done');
	like($out, qr/no longer held by this process/, 'and says the lock was no longer this process\'s');
	is($vault->{store}{$LOCK_PATH}{data}{token}, 'another-process', 'and the other process\'s lock is left alone');
};

subtest 'a kv v1 release the vault refuses is reported, not counted as released' => sub {
	my $vault = MockLockVault->new(kv_version => 1);
	my $bosh = director($vault);
	no warnings 'once';
	local $Service::BOSH::Director::NETWORK_LOCK_SETTLE_SECONDS = 0;
	is(try_acquire($bosh), 'won', 'the lock is taken');
	$vault->{delete_refused} = 1;
	throws_ok { $bosh->clear_network_lock } qr/Could not delete.*permission denied/,
		'the refused delete is a failure';
	ok($bosh->network_locked_by_me, 'and the lock is still there, as the failure says');
};

# ---------------------------------------------------------------------------
# How the lock is stored
#
# The lock record sits under the director's exodus path, so a safe export of
# that path takes it along.  safe 1.26.0 exports a value that is not a
# string with its JSON type kept (export format 3), and Genesis refuses an
# export whose current version of a secret holds anything but strings, so
# every lock value has to go to the vault as a string.  Genesis before that
# change stored the pid as a number, and both have to share the lock while a
# rollout is under way.  The tests run on both kinds of kv mount.
# ---------------------------------------------------------------------------

# The JSON type a value has as it was decoded, by the check the export
# reader makes: undef for a string.
sub json_type { Service::Vault::_export_value_type($_[0]) }

# A lock record as it comes out of the vault, freshly decoded, with its pid
# a JSON number or a JSON string.
sub decoded_lock {
	my ($form, %fields) = @_;
	my $record = lock_record(%fields);
	$record->{pid} = $form eq 'number' ? 0 + $record->{pid} : "$record->{pid}";
	return JSON::PP::decode_json(JSON::PP::encode_json($record));
}

# The pid of a process that has exited and been reaped
sub dead_pid {
	my $pid = fork() // die "Could not fork: $!\n";
	exit 0 if $pid == 0;
	waitpid($pid, 0);
	die "Process $pid is still there after it was reaped\n" if kill(0, $pid);
	return $pid;
}

# What safe 1.26.0's `safe export` of the director's exodus path prints for
# the mock's records: the latest version of each secret, or with all => 1
# every version a kv v2 mount keeps.  It is format 1 when each secret has
# one version of strings, 2 when some secret has more, and 3 when some
# value is not a string, which then keeps its JSON type.  Formats 2 and 3
# give an empty version no value, give each secret the number of its oldest
# exported version as `first` unless that is 1, and name the mount of any
# secret with more than one version in `requires_versioning`.
sub safe_export {
	my ($vault, %opts) = @_;
	my %versions;   # path => [[number, data], ...], oldest first
	for my $path (grep { m{^\Q$EXODUS\E(?:/|$)} } keys %{$vault->{store}}) {
		my $rec = $vault->{store}{$path};
		my @all = $vault->{kv_version} == 2 && $rec->{history}
			? map { [$_ + 1, $rec->{history}[$_]] } 0 .. $#{$rec->{history}}
			: ([$rec->{version}, $rec->{data}]);
		$versions{$path} = $opts{all} ? [@all] : [$all[-1]];
	}
	my $typed = grep { defined json_type($_) } map { values %{$_->[1]} } map { @$_ } values %versions;
	my $many  = grep { @$_ > 1 } values %versions;
	my $json = JSON::PP->new->canonical;
	return $json->encode({map { ($_ => $versions{$_}[0][1]) } keys %versions})
		unless $typed || $many;
	return $json->encode([{
		export_version      => $typed ? 3 : 2,
		data                => {map {
			my $first = $versions{$_}[0][0];
			($_ => {
				($first == 1 ? () : (first => $first)),
				versions => [map { %{$_->[1]} ? {value => $_->[1]} : {} } @{$versions{$_}}],
			})
		} keys %versions},
		requires_versioning => {$many ? ('secret/' => JSON::PP::true) : ()},
	}]);
}

# Every lock below is taken with no wait for a competing kv v1 write.
$Service::BOSH::Director::NETWORK_LOCK_SETTLE_SECONDS = 0;

# A real Service::Vault, with `safe curl` answered by a kv mount kept in
# memory, so that the request bodies are the JSON that would go to the vault.
sub curl_vault {
	my ($kv_version, $bodies) = @_;
	my $vault = Service::Vault->new('https://vault.example.com:8200', 'test-vault', 1, '', undef, '/secret/');
	my (%store, %version);
	my $answer = sub {
		my ($status, $body) = @_;
		my %reason = (200 => 'OK', 204 => 'No Content', 404 => 'Not Found');
		my $out = "HTTP/1.1 $status $reason{$status}\r\nContent-Type: application/json\r\n\r\n"
			.(defined($body) ? JSON::PP::encode_json($body) : '')."\n";
		return ($out, $status >= 400 ? 1 : 0, '');
	};
	$vault->{__test_query} = sub {
		my (undef, $method, $uri, $body) = @_;   # curl METHOD URI [BODY]
		return $answer->(200, {data => {path => 'secret/', type => 'kv', options => {version => "$kv_version"}}})
			if $uri =~ m{^/sys/internal/ui/mounts/};
		my $key = $uri =~ s{^/secret/(?:data/)?}{}r;
		if ($method eq 'POST') {
			push @$bodies, $body;
			my $sent = JSON::PP::decode_json($body);
			$store{$key} = $kv_version == 2 ? $sent->{data} : $sent;
			$version{$key}++;
			return $kv_version == 2 ? $answer->(200, {data => {version => $version{$key}}}) : $answer->(204);
		}
		if ($method eq 'GET') {
			return $answer->(404, {errors => []}) unless $store{$key};
			return $kv_version == 2
				? $answer->(200, {data => {data => $store{$key}, metadata => {version => $version{$key}}}})
				: $answer->(200, {data => $store{$key}});
		}
		return ('', 1, "!! no stub for $method $uri");
	};
	return $vault;
}

for my $kv_version (2, 1) {
	subtest "kv v$kv_version: the lock goes to the vault with every value a JSON string" => sub {
		local $ENV{GENESIS_VAULT_CONFIRM_WRITES} = '0';
		no warnings qw(redefine once);
		local $Service::BOSH::Director::NETWORK_LOCK_SETTLE_SECONDS = 0;
		local *Service::Vault::query = sub {
			my $self = shift;
			shift if ref($_[0]) eq 'HASH';
			shift if $_[0] eq 'safe';
			return $self->{__test_query}->(@_);
		};

		my @bodies;
		my $bosh = director(curl_vault($kv_version, \@bodies));
		is(try_acquire($bosh), 'won', 'the lock is taken');
		is(scalar(@bodies), 1, 'with one write to the vault');

		my $sent = JSON::PP::decode_json($bodies[0] // '{}');
		my $record = $kv_version == 2 ? $sent->{data} : $sent;
		is(ref($record), 'HASH', 'which sends the lock record') or return;
		is_deeply([sort keys %$record], [qw(at env hostname pid token user)], 'with every field of the lock');
		like($bodies[0], qr/"pid":"$$"/, 'the pid is sent as a JSON string')
			or diag $bodies[0];
		is_deeply({map {($_ => json_type($record->{$_}))} keys %$record},
			{map {($_ => undef)} keys %$record},
			'and so is every other value, by the check the export reader makes');

		my $exported;
		lives_ok { $exported = Service::Vault::normalize_export({$LOCK_PATH => $record}) }
			'the record, exported, is one Genesis can read';
		is($exported->{$LOCK_PATH}{pid}, "$$", 'with the pid as it was written');
		ok($bosh->network_locked_by_me, 'and the lock reads back as this process\'s');
	};
}

# The record each kind of writer leaves, as the export reader sees its pid
my %STORED_PID = (number => 'number', this => undef);

for my $kv_version (2, 1) {
for my $holder ('number', 'string') {
	for my $contender ('number', 'this') {
		my $name = "kv v$kv_version: a $holder pid holder against a contender that writes "
			.($contender eq 'this' ? 'a string pid' : 'a number pid');

		subtest "$name: a live lock is refused" => sub {
			my $vault = MockLockVault->new(kv_version => $kv_version);
			$vault->{pid_form} = $contender;
			seed_lock($vault, decoded_lock($holder, age => 60, pid => 4242));
			my $result = try_acquire(director($vault));
			like($result, qr/^refused: .*pid: 4242/s, 'the lock is refused, naming the holder\'s pid')
				or diag $result;
			is($vault->{store}{$LOCK_PATH}{data}{token}, 'held-elsewhere', 'and the holder keeps it');
		};

		subtest "$name: a lock past the timeout is taken over" => sub {
			my $vault = MockLockVault->new(kv_version => $kv_version);
			$vault->{pid_form} = $contender;
			seed_lock($vault, decoded_lock($holder, age => 7200, pid => 4242));
			my $bosh = director($vault);
			is(try_acquire($bosh), 'won', 'the stale lock is taken over');
			ok($bosh->network_locked_by_me, 'and is held by the contender');
			is(json_type($vault->{store}{$LOCK_PATH}{data}{pid}), $STORED_PID{$contender},
				'whose record holds its pid as that writer stores it');
		};

		subtest "$name: a same-host lock whose pid is dead is taken over" => sub {
			my $vault = MockLockVault->new(kv_version => $kv_version);
			$vault->{pid_form} = $contender;
			seed_lock($vault, decoded_lock($holder, age => 60, hostname => Sys::Hostname::hostname(), pid => dead_pid()));
			my $bosh = director($vault);
			is($bosh->check_network_lock->{status}, 'stale', 'the lock is stale');
			is(try_acquire($bosh), 'won', 'and is taken over');
			is(json_type($vault->{store}{$LOCK_PATH}{data}{pid}), $STORED_PID{$contender},
				'whose record holds its pid as that writer stores it');
		};

		subtest "$name: a same-host lock whose pid cannot be signalled is still held" => sub {
			plan skip_all => 'running as root, which can signal every process' if $> == 0;
			my $vault = MockLockVault->new(kv_version => $kv_version);
			$vault->{pid_form} = $contender;
			seed_lock($vault, decoded_lock($holder, age => 60, hostname => Sys::Hostname::hostname(), pid => 1));
			ok(!kill(0, 1) && $!{EPERM}, 'pid 1 answers a signal check with EPERM');
			like(try_acquire(director($vault)), qr/^refused: /, 'so the lock is refused');
			is($vault->{store}{$LOCK_PATH}{data}{token}, 'held-elsewhere', 'and the holder keeps it');
		};
	}
}

for my $pair (['number', 'this'], ['this', 'number']) {
	my ($holder, $contender) = @$pair;
	my $name = "kv v$kv_version: "
		.($holder eq 'number' ? 'a number pid holder and a string pid contender'
			: 'a string pid holder and a number pid contender');

	subtest "$name: only the token says who holds the lock" => sub {
		my $vault = MockLockVault->new(kv_version => $kv_version);
		my ($mine, $theirs) = (director($vault), director($vault));
		$vault->{pid_form} = $holder;
		is(try_acquire($mine), 'won', 'the holder takes the lock');
		is(json_type($vault->{store}{$LOCK_PATH}{data}{pid}), $STORED_PID{$holder},
			'and its record holds its pid as that writer stores it');

		$vault->{pid_form} = $contender;
		like(as_other_process(sub { try_acquire($theirs) }), qr/^refused: /,
			'the contender, on the same host with a live pid, is refused');
		ok(!as_other_process(sub { $theirs->network_locked_by_me }), 'and does not hold the lock');
		ok($mine->network_locked_by_me, 'which the holder still does');
		ok(!as_other_process(sub { $theirs->clear_network_lock }), 'the contender\'s release removes nothing');
		ok($mine->network_locked_by_me, 'and the holder still holds the lock');
		ok($mine->clear_network_lock, 'until it releases it');
		is($mine->check_network_lock->{status}, 'unlocked', 'and the director is unlocked');
	};

	subtest "$name: a holder whose stale lock was taken over has lost it" => sub {
		my $vault = MockLockVault->new(kv_version => $kv_version);
		my ($mine, $theirs) = (director($vault), director($vault));
		$vault->{pid_form} = $holder;
		is(try_acquire($mine), 'won', 'the holder takes the lock');
		is(json_type($vault->{store}{$LOCK_PATH}{data}{pid}), $STORED_PID{$holder},
			'and its record holds its pid as that writer stores it');
		$vault->{store}{$LOCK_PATH}{data}{at} = strftime('%Y-%m-%d %H:%M:%S +0000', gmtime(time - 7200));

		$vault->{pid_form} = $contender;
		is(as_other_process(sub { try_acquire($theirs) }), 'won', 'the contender takes over the stale lock');
		is(json_type($vault->{store}{$LOCK_PATH}{data}{pid}), $STORED_PID{$contender},
			'and its record holds its pid as that writer stores it');
		throws_ok { $mine->ensure_network_lock_held('write the network claims') }
			qr/no longer holds the network claims lock/, 'the holder is stopped';
		ok(!$mine->clear_network_lock, 'and its release removes nothing');
		ok(as_other_process(sub { $theirs->network_locked_by_me }), 'so the contender still holds the lock');
		ok(as_other_process(sub { $theirs->clear_network_lock }), 'until it releases it');
	};
}
}

subtest 'kv v1: a stale lock read back unchanged is cleared, whatever its pid type' => sub {
	for my $form ('number', 'string') {
		for my $case (
			['past the timeout', age => 7200],
			['from a dead pid on this host', age => 60, hostname => Sys::Hostname::hostname(), pid => dead_pid()],
		) {
			my ($what, %fields) = @$case;
			my $vault = MockLockVault->new(kv_version => 1);
			my $bosh = director($vault);
			seed_lock($vault, decoded_lock($form, %fields));
			my $seen = $bosh->check_network_lock;
			is($seen->{status}, 'stale', "$form pid, $what: the lock is stale");
			ok($bosh->clear_network_lock(stale => $seen), "$form pid, $what: and is cleared");
			ok(!exists $vault->{store}{$LOCK_PATH}, "$form pid, $what: and is gone");
		}
	}
};

subtest 'kv v1: a stale lock that changed after it was read is left alone, whatever its pid type' => sub {
	for my $form ('number', 'string') {
		for my $change (['token', token => 'taken-since'], ['holder', user => 'someone-else', hostname => 'elsewhere']) {
			my ($what, %changed) = @$change;
			my $vault = MockLockVault->new(kv_version => 1);
			my $bosh = director($vault);
			seed_lock($vault, decoded_lock($form, age => 7200));
			my $seen = $bosh->check_network_lock;
			seed_lock($vault, decoded_lock($form, age => 7200, %changed));
			ok(!$bosh->clear_network_lock(stale => $seen), "$form pid, changed $what: the lock is not cleared");
			ok(exists $vault->{store}{$LOCK_PATH}, "$form pid, changed $what: and is still there");
		}
	}
};

# The director's own exodus data, which the export takes along with the lock
sub seed_exodus {
	my ($vault) = @_;
	$vault->{store}{$EXODUS} = {version => 1, data => {url => 'https://127.0.0.1:25555'}};
}

sub read_export {
	my ($vault, %opts) = @_;
	return Service::Vault::normalize_export(JSON::PP::decode_json(safe_export($vault, %opts)));
}

for my $kv_version (2, 1) {
	subtest "kv v$kv_version: the director's exodus data exports readably while this Genesis holds the lock, and after" => sub {
		my $vault = MockLockVault->new(kv_version => $kv_version);
		seed_exodus($vault);
		my $bosh = director($vault);
		is(try_acquire($bosh), 'won', 'the lock is taken');

		my $exported;
		like(safe_export($vault), qr/^\{/, 'safe exports it as format 1, every value a string');
		lives_ok { $exported = read_export($vault) } 'and Genesis reads the export';
		is($exported->{$LOCK_PATH}{pid}, "$$", 'with the lock in it');

		ok($bosh->clear_network_lock, 'once the lock is released');
		lives_ok { $exported = read_export($vault) } 'the export still reads';
		is_deeply($exported->{$LOCK_PATH}, $kv_version == 2 ? {} : undef,
			$kv_version == 2 ? 'with the released lock a secret with no keys' : 'with no lock in it');
		return unless $kv_version == 2;
		like(safe_export($vault, all => 1), qr/"export_version":2/,
			'an export of every version is format 2, as the history holds only strings');
		lives_ok { $exported = read_export($vault, all => 1) } 'and Genesis reads it';
		is_deeply($exported->{$LOCK_PATH}, {}, 'with the released lock current');
	};

	subtest "kv v$kv_version: a lock an earlier Genesis left behind stops the export until it is replaced or released" => sub {
		my $vault = MockLockVault->new(kv_version => $kv_version);
		seed_exodus($vault);
		$vault->{pid_form} = 'number';
		is(try_acquire(director($vault)), 'won', 'an earlier Genesis takes the lock, and stores its pid as a number');
		like(safe_export($vault), qr/"export_version":3/, 'which safe exports as format 3');
		throws_ok { read_export($vault) }
			qr/Cannot use the safe export of .*network-claim-lock.*pid.*typed value, a JSON number/s,
			'and Genesis refuses, naming the lock and its pid';

		# It dies without releasing it, and this Genesis takes it over once it is stale.
		$vault->{store}{$LOCK_PATH}{data}{at} = strftime('%Y-%m-%d %H:%M:%S +0000', gmtime(time - 7200));
		delete $vault->{pid_form};
		my $bosh = director($vault);
		is(as_other_process(sub { try_acquire($bosh) }), 'won', 'this Genesis takes over the stale lock');
		my $exported;
		lives_ok { $exported = read_export($vault) } 'and the export reads again';
		is(json_type($exported->{$LOCK_PATH}{pid}), undef, 'with a string pid in the lock');
		ok(as_other_process(sub { $bosh->clear_network_lock }), 'which it then releases');
		lives_ok { read_export($vault) } 'and the export still reads';
		return unless $kv_version == 2;

		my $all = safe_export($vault, all => 1);
		like($all, qr/"export_version":3/, 'an export of every version is format 3, for the number pid in the history');
		like($all, qr/\{\}\]/, 'with no value for the released version');
		like($all, qr/"requires_versioning":\{"secret\/":true\}/, 'and naming the mount that keeps versions');
		lives_ok { $exported = read_export($vault, all => 1) } 'and Genesis reads it';
		is_deeply($exported->{$LOCK_PATH}, {}, 'as only the current, released version counts');

		# Released by the earlier Genesis itself, with no takeover in between
		my $released = MockLockVault->new(kv_version => 2);
		seed_exodus($released);
		$released->{pid_form} = 'number';
		my $earlier = director($released);
		is(try_acquire($earlier), 'won', 'an earlier Genesis takes the lock');
		ok($earlier->clear_network_lock, 'and releases it');
		like(safe_export($released), qr/^\{/, 'the export of the latest versions is format 1 again');
		lives_ok { read_export($released) } 'and reads';
		lives_ok { $exported = read_export($released, all => 1) } 'as does one of every version, number pid and all';
		is_deeply($exported->{$LOCK_PATH}, {}, 'with the released lock current');

		is(try_acquire($earlier), 'won', 'once the earlier Genesis takes the lock again');
		like(safe_export($released), qr/"first":3.*"export_version":3/s,
			'the export of the latest versions is format 3, from the lock\'s third version');
		throws_ok { read_export($released) } qr/typed value, a JSON number/, 'and is refused again';
	};
}

# safe 1.26.0's export of every version of a lock an earlier Genesis took
# and released, as it prints it: format 3, and no value for the release.
subtest 'a format 3 export of a released lock with a number pid in its history reads' => sub {
	my $export = JSON::PP::decode_json(sprintf(
		'[{"export_version":3,"data":{'.
			'"%s":{"versions":[{"value":{"url":"https://127.0.0.1:25555"}}]},'.
			'"%s":{"versions":[{"value":{"at":"2026-10-22 12:00:00 +0000","env":"lab",'.
				'"hostname":"jumpbox","pid":4242,"token":"t","user":"jdoe"}},{}]}'.
		'},"requires_versioning":{"secret/":true}}]',
		$EXODUS, $LOCK_PATH
	));
	my $exported;
	lives_ok { $exported = Service::Vault::normalize_export($export) } 'Genesis reads it';
	is_deeply($exported, {$EXODUS => {url => 'https://127.0.0.1:25555'}, $LOCK_PATH => {}},
		'with the released lock a secret with no keys');
};

done_testing;
