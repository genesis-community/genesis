package Service::Vault::Local;

use strict;
use warnings;

use Genesis;

use base 'Service::Vault';

my $local_vaults = {};

### Class Methods {{{

# create - create a local memory-backed vault, then return a Service::Vault pointer to it. {{{
sub create {
	my ($class, $name) = @_;

	# Start local vault in the background
	my $alias = _generate_alias($name);
	my $logfile = workdir."/$alias.out";
	return $local_vaults->{$alias} if $local_vaults->{$alias};

	trace "Looking for existing safe $alias";
	my $safe_process = _get_safe_process($alias,0.25);

	unless ($safe_process) {
		debug "Starting background local safe $alias";
		system("safe local -m --as '$alias' &>$logfile &");
		trace "Looking for new process";
		$safe_process = _get_safe_process($alias,1);
		bail(
			"Could not start local memory-backed vault:\n%s",
			slurp($logfile)
		) unless $safe_process;
	}

	my $vault_process = _get_vault_process($safe_process->{pid}, 1);
	bail(
		"Could not start local memory-backed vault:\n%s",
		slurp($logfile)
	) unless $vault_process && $vault_process->{ppid} == $safe_process->{pid};

	# Restore default vault target?

	my $vault_info = read_json_from(run({env => {SAFE_TARGET => undef}},
			"safe targets --json | jq '.[] | select(.name==\"$alias\")'"
	));
	bail(
		"Failed to find vault alias after starting local vault."
	)	unless ($vault_info && ref($vault_info) eq 'HASH' && $vault_info->{url});

	my $vault = $class->SUPER::new(
		@{$vault_info}{qw(url name verify namespace strongbox mount)}
	);
	$vault->{logfile}   = $logfile;
	$vault->{safe_pid}  = $safe_process->{pid};
	$vault->{vault_pid} = $vault_process->{pid};
	$local_vaults->{$alias} = $vault;

	while ($vault->status ne "ok") {
		trace "Waiting for local vault to become available...";
		select(undef,undef,undef,0.25);
	}

	return $vault;
}

# }}}
# rebind - connect to and return an already-running local vault {{{
sub rebind {
	my ($class, $name) = @_;
  return unless $class->valid_local_vault($name);

	my $alias = _generate_alias($name);
	return $local_vaults->{$alias} if $local_vaults->{$alias};

	my $vault_info = read_json_from(run({env => {SAFE_TARGET => undef}},
			"safe targets --json | jq '.[] | select(.name==\"$alias\")'"
	));
	return unless ($vault_info && ref($vault_info) eq 'HASH' && $vault_info->{url});

	my $pid = _get_safe_process($alias);
	return unless defined($pid);

	my $vault = $class->SUPER::new(
		@{$vault_info}{qw(url name verify namespace strongbox mount)}
	);
	return unless $vault;
	
	$vault->{logfile}   = workdir."/$alias.out"; #FIXME: This just assumes this value -- should use lsof to detect correct value
	$vault->{safe_pid}  = $pid;
	$vault->{vault_pid} = _get_vault_process($pid);
	$local_vaults->{$alias} = $vault;

	return $vault;
}

# }}}
# valid_local_vault - return true if the submitted name and optional url would be valid as a local vault {{{
sub valid_local_vault {
	my ($class, $name, $url) = @_;
	$name =~ /^local_vault_(.*)_[0-9]+$/ && (!$url || $url =~ /localhost/);
}


# }}}
# shutdown_all - shutdown all local vaults {{{
sub shutdown_all {
	for (keys %$local_vaults) {
		debug "Shutting down $_ ...";
		delete($local_vaults->{$_})->shutdown;
	}
}
# }}}
# }}}

### Instance Methods {{{

# pid - return the pid of the local vault instance {{{
sub pid {
	return $_[0]->{name} =~ /.*_([0-9]*)$/ ? $1 : undef;
}

# }}}

# shutdown - shutdown the local vault (which should restore previous safe target) {{{
sub shutdown {
	my $self = shift;

	# Don't shut down parent process provided local vault;
	unless ($self->pid == $$) {
		debug(
			"Not shutting down local vault %s because it is owned by a different process",
			$self->pid
		);
		return;
	}

	if ($self->{vault_pid}) {
		my $signal = 'INT';
		my $tries = 0;
		while (_process_running($self->{vault_pid})) {
			trace "Shutting down vault $self->{vault_pid} with $signal";
			kill $signal => $self->{vault_pid};
			select(undef, undef, undef, 0.5);
			$tries += 1;
			$signal = 'TERM' if ($tries > 4);
			$signal = 'KILL' if ($tries > 8);
		}
	}
	if ($self->{safe_pid}) {
		my $signal = '';
		my $tries = 0;
		select(undef, undef, undef, 0.20);
		while (_process_running($self->{safe_pid})) {
			if ($signal) {
				trace "Shutting down safe $self->{safe_pid} with $signal";
				kill $signal => $self->{vault_pid}
			}
			select(undef, undef, undef, 0.20);
			$tries += 1;
			$signal = 'TERM' if ($tries > 10);
			$signal = 'KILL' if ($tries > 20);
		}
	}
	trace(
		"Shut down local vault %s - Output:\n%s",
		$self->{name}, slurp($self->{logfile})
	);
	$self->{safe_pid} = $self->{vault_pid} = undef;
	return;
}

# }}}
# DESTROY - perl descructor: will shutdown local vault if it hasn't been already shut down {{{
sub DESTROY {
	$_[0]->shutdown if $_[0]->{safe_pid};
}

# }}}
# }}}


### Helper functions {{{
sub _generate_alias {
	my $name = shift;
	my $pid = $name =~ /^local_vault_(.*)_([0-9]+)$/ ? $2 : $$;
	$name =~ s/^local_vault_(.*)_[0-9]+$/$1/; # strip back to original name
	return "local_vault_${name}_${pid}";
}

sub _get_safe_process {
	my ($alias, $timeout) = @_;
	return _get_process("\\s\\+[s]afe local -m --as $alias", $timeout);
}

sub _get_vault_process {
	my ($ppid, $timeout) = @_;
	return _get_process("\\s\\+$ppid\\s\\+[v]ault server", $timeout);
}

sub _get_process {
	my ($filter, $timeout) = @_;
	$timeout = sprintf("%0.f", ($timeout//5)/0.05);
	my $i = 0;
	while ($i < $timeout ) {
		$i += 1;
		select(undef,undef,undef,0.05);
		my $ps_line = scalar(qx(ps -eo 'pid,ppid,command' | grep '$filter' | sed -e 's/^ *//' | head -n 1));
		trace "psline: $ps_line";
		chomp $ps_line;
		next unless $ps_line;

		my ($pid, $ppid, $cmd) = split(/ +/, $ps_line, 3);
		return {pid => $pid, ppid => $ppid, cmd => $cmd}
	}
	return undef;
}

sub _process_running {
	my $pid = shift;
	trace "Checking for process ID $pid...";
	my $out = scalar(qx(ps -o 'pid,command' -p $pid | grep '^\\s*$pid'));
	my $rc = $? >> 8;
	trace "[rc: $rc] $out";
	return $rc == '0';
}
# }}}
1;
# vim: fdm=marker:foldlevel=1:noet
