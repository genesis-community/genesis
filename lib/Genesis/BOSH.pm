package Genesis::BOSH;

use File::Temp qw/tempfile/;

use Genesis;
use Genesis::State;

## Class Variables {{{
my ($bosh_cmd);

#}}}

### Class Methods {{{
#
# command - get, and optionally check version, of local BOSH command {{{
sub command {
	my ($class, $min_version, $max_version) = @_;
	return $ENV{GENESIS_BOSH_COMMAND} if $ENV{GENESIS_BOSH_COMMAND};
	return $bosh_cmd if ($bosh_cmd && !$min_version && !$max_version);

	$min_version ||= '0.0.0';
	my %versions;
	foreach my $boshcmd (qw(bosh-cli bosh2 boshv2 bosh)) {
		my ($version, undef) = run("$boshcmd -v 2>&1 | grep version | head -n1");
		trace("Version for $boshcmd: '$version'");
		next unless defined($version) && $version =~ /version (\S+?)-.*/;
		$version = $1;
		my $cmd = `/usr/bin/env bash -c 'command -v $boshcmd 2>/dev/null' 2>/dev/null`;
		$cmd = `which $boshcmd 2>/dev/null` if $? != 0;
		$cmd = "\\$boshcmd" if $? != 0;
		chomp $cmd;
		debug("#G{Version v$version} of #C{$cmd} is found on this system.");
		$versions{$version} = $cmd;
	}

	bail "#R{Missing `bosh`} - install the BOSH (v2) CLI from #B{https://github.com/cloudfoundry/bosh-cli/releases}"
		unless keys %versions;

	my $best = "0.0.0";
	for (keys %versions) {
		$best = $_ if (
			new_enough($_, $best) &&
			new_enough($_, $min_version) &&
			(! $max_version || new_enough($max_version, $_))
		)
	}

	if ($min_version && $best eq "0.0.0") {
		my $msg=sprintf(
			"BOSH CLI #c{v%s} %s is required, but this system only provides the following:",
			$min_version,
			$max_version ? "up to #Y{v$max_version}" : "or higher"
		);
		$msg .= "\n  - $versions{$_} (#Y{v$_})" for (keys %versions);
		bail $msg;
	}
	debug("Selecting #c{%s} (v%s) as BOSH cli for Genesis BOSH activities", $versions{$best}, $best);
	$bosh_cmd = $versions{$best};
}

# }}}
# set_command - override the command path {{{
sub set_command {
	my ($class, $cmd) = @_;
	$bosh_cmd = $cmd;
}

# }}}
# }}}

## Instance Methods {{{

# environment_variables - retrieve BOSH environment variables for this BOSH director {{{
sub environment_variables {
	return ();
}

#}}}
# execute - execute a bosh command {{{
sub execute {
	my ($self, @cmd) = @_;
	my %env = $self->environment_variables;

	my $opts = (ref($cmd[0]) eq 'HASH') ? shift @cmd : {};

	$env{BOSH_DEPLOYMENT} = delete($opts->{deployment}) || $self->{deployment}; # TODO: do we need this still?
	$opts->{stderr} = 0 unless (defined($opts->{stderr}) || $opts->{interactive});

	$env{$_} = $opts->{env}{$_} for (keys %{$opts->{env}||{}});
	$opts->{env} = \%env;
	unless ($ENV{GENESIS_HONOR_ENV}) {
		$opts->{env}{HTTPS_PROXY} = undef; # bosh dislikes this env var
		$opts->{env}{https_proxy} = undef; # bosh dislikes this env var
	}
	my $noninteractive = envset('BOSH_NON_INTERACTIVE') ? ' -n' : '';
	$opts->{env}{BOSH_NON_INTERACTIVE} = undef;

	my ($fh, $file);

	my $bosh = ref($self)->command();
	if ($cmd[0] =~ m/^bosh(\s|$)/) {
		# ('bosh', 'do', 'things') or 'bosh do things'
		$cmd[0] =~ s/^bosh/$bosh$noninteractive/;

	} elsif ($cmd[0] =~ /(\||\$\{?[\@0-9])/) {
		# ('deploy "$1" | jq -r .whatever', $d)
		$cmd[0] = "$bosh$noninteractive $cmd[0]";

	} else {
		# ('deploy', $d)
		my $allow_script_wrapper = !(grep {$_ eq $cmd[0]} (qw(
			int
		)));
		unshift(@cmd, '-n') if $noninteractive;
		unshift(@cmd, $bosh);

		# Capture output if interactive using script command
		if ($opts->{interactive} && $allow_script_wrapper) {
			my $OS = "$^O";
			($fh, $file) = tempfile('bosh-output-XXXXXXXX', TMPDIR => 1, UNLINK => 1);

			if ($OS eq 'darwin') {
				unshift(@cmd, "script", "-q", "$file");
			} elsif ($OS eq 'linux') {
				# Sometimes gnu just sucks...
				my $subcmd = join(" ", map {$_ =~ m/\s/ ? "\"$_\"" : $_} @cmd);
				# TODO: more rigorous wrapping of subcmd to deal with quotes and pipes
				@cmd = ("script -q $file -c '$subcmd'");
			}
		}
	}

	$Genesis::Log::Logger->dump_var("bosh command" => \@cmd);
	my @results = run($opts, @cmd);

	if ($opts->{interactive} && ! $opts->{passfail} && $file) {
		$results[0] = slurp($file);
		$results[0] =~ s/^Script [^\n]+\n//m; # remove script header (linux)
		if ($results[0] =~ s/\nScript done.*\[COMMAND_EXIT_CODE="(.*)"]$//m) {
			$results[1] = $1;  # Linux stores command exit code in the script output
		}
		$Genesis::Log::Logger->dump_var("bosh results" => \@results);
	}
	return wantarray ? @results : $results[1];
}

# }}}
# }}}
1
# vim: fdm=marker:foldlevel=1:noet
