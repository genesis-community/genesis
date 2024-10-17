package Genesis::Commands::Bosh;

use strict;
use warnings;

use Genesis;
use Genesis::State;
use Genesis::Term;
use Genesis::Commands;
use Genesis::Top;
use Genesis::UI;

sub bosh {
	append_options(redact => ! -t STDOUT);

	command_usage(1) unless @_;
	my $env = Genesis::Top->new('.')->load_env(shift(@_))->with_vault();

	my $bosh = $env->get_target_bosh(get_options());

	if (get_options->{connect}) {
		if (in_controlling_terminal) {
			my $call = $::CALL; # Silence single-use warning
			error(
				"This command is expected to be run in the following manner:\n".
				"  eval \"\$($::CALL)\"\n".
				"\n".
				"This will set the BOSH environment variables in the current shell"
			);
			exit 1;
		}
		my %bosh_envs = $bosh->environment_variables
			unless in_controlling_terminal;
		for (keys %bosh_envs) {
			(my $escaped_value = $bosh_envs{$_}||"") =~ s/"/"\\""/g;
			output 'export %s="%s"', $_, $escaped_value;
		}
		info "Exported environmental variables for BOSH director %s", $bosh->{alias};
		exit 0;
	} else {
		my ($out, $rc) = $bosh->execute({interactive => 1, dir => $ENV{GENESIS_ORIGINATING_DIR}}, @_);
		exit $rc;
	}
}

# }}}
# credhub - execute a credhub command for the target environment {{{
sub credhub {

	command_usage(1) unless @_;
	my $env = Genesis::Top->new('.')->load_env(shift(@_))->with_vault();

	# TODO: Support a --connect option similar to `bosh` command so that it
	#       will set the environment variables in the current shell.

	my ($cmd,@args) = @_;

	my ($bosh, $target) = $env->get_target_bosh(get_options());

	my $credhub = ($target eq 'self')
		? Service::Credhub->from_bosh($bosh, vault => $bosh->{exodus_vault}//$env->vault)
		: $env->credhub;

	# Check for invalid commands in the context of Genesis-augmented CredHub
	# environments
	if ($cmd =~ m/^(l|login|a|api|o|logout)$/) {
		bail(
			"Command #C{genesis credhub %s} is not allowed in when Genesis is ".
			"managing authentication to CredHub",
			$cmd
		);
	}

	unless (get_options->{raw}) {

		# Find the name or path option, and make it magically work under the
		# environment's base path

		my $name_idx = index_of('-n', @args) // index_of('--name', @args);
		my $path_idx = index_of('-p', @args) // index_of('--path', @args) // index_of('--prefix', @args);

		# Commands that take a --name option only
		if ($cmd =~ m/^(g|get|s|set|n|generate|r|regenerate|d|delete)$/) {
			if (defined($name_idx)) {
				$args[$name_idx+1] = $credhub->base. $args[$name_idx+1]
					if ($args[$name_idx+1] !~ m/^\//);
			} else {
				# Can't generate a name if --name isn't present -- let credhub handle it
			}

		# Commands that take a --path or --prefix option (both use -p for short)
		} elsif ($cmd =~ m/^(e|export|interpolate|f|find)$/) {
			if (defined($path_idx)) {
				$args[$path_idx+1] = $credhub->base. $args[$path_idx+1]
					if ($args[$path_idx+1] !~ m/^\//);
			} else {
				unshift(@args, '-p', $credhub->base);
			}
		}
	}

	pushd($ENV{GENESIS_ORIGINATING_DIR});
	$env->notify(
		"Running #C{credhub %s} against CredHub server on #M{%s} (#C{%s}):\n",
		$cmd, $credhub->{name}, $credhub->{url}
	);
	my ($out, $rc) = $credhub->execute($cmd, @args);
	popd();
	if ($rc) {
		$env->notify(
			fatal => "command #C{credhub %s} failed with exit code #R{%d}\n",
			$cmd, $rc
		);
	} else {
		$env->notify(
			success => "command #C{credhub %s} succeeded!\n",
			$cmd
		);
	}
	exit $rc;
}


# }}}
sub logs {
	my %options = %{get_options()};
	my ($env_name, @extra_args) = @_;

	my $env = Genesis::Top->new('.')->load_env($env_name)->with_vault()->with_bosh();
	bail(
		"No bosh logs for environments deployed with #M{create-env}"
	) if $env->use_create_env;

	my @logs = $env->bosh_logs(@extra_args);
}

sub broadcast {
	my %options = %{get_options()};
	my ($env_name, @extra_args) = @_;

	my $targets = $options{on}; # default to all jobs

	my $env = Genesis::Top->new('.')->load_env($env_name)->with_vault()->with_bosh();
	my $bosh = $env->bosh;
	my ($out,$rc, $err) = read_json_from($bosh->execute({interactive => 0}, 'vms', '--json'));
	bail("Failed to fetch VM list: %s", $err) if $rc;
	my @vms = ();
	eval {
		@vms = @{$out->{Tables}[0]{Rows}};
	} or bail("Failed to parse VM list: %s", $@);

	my @errors = ();
	if ($targets) {
		my @instances = ();
		for my $target (@$targets) {
			my $search_target = $target;
			$search_target .= '/' unless $search_target =~ m{/};
			my @match = map {$_->{instance}} grep {$_->{instance} =~ m{^\Q$target\E}} @vms;
			if (@match) {
				push @instances, @match;
			} else {
				@errors = (@errors, ($target =~ m{/})
					? "No instances found matching specified instance ID #c{$target}"
					: "No instances found matching specified instance type #C{$target}");
			}
		}
		$targets = \@instances;
	} else {
		$targets = [map {$_->{instance}} @vms];
	}

	bail(
		"Errors were encountered while determining broadcast targets:\n%s",
		join("\n", map {"- $_"} @errors)
	) if @errors;

	for my $target ( uniq @$targets ) {
		info("\n" . ('=' x terminal_width()));
		info("#g{Broadcasting to }#C{%s}#g{...}", $target);
		info('-' x terminal_width());
		my ($out, $rc, $err) = $bosh->execute({interactive => 1}, 'ssh', $target, '--', @extra_args);
		error("Failed to broadcast to %s: %s", $target, $err) if $rc;
	}

	info("\n" . ('=' x terminal_width()));
	success("\nBroadcast complete!\n");
}

sub bosh_configs {
	my %options = %{get_options()};
	my ($env_name, $action, @extra_args) = @_;

	$action //= 'upload';
	my @valid_actions = qw(upload list view compare delete);
	bail(
		"Invalid action: %s - expected one of: %s (leave blank for 'upload')",
		$action, sentence_join(@valid_actions)
	) unless grep {$_ eq $action} @valid_actions;

	bail("Too many arguments provided") if @extra_args > 0;

	my $env = Genesis::Top->new('.')->load_env($env_name)->with_vault()->with_bosh();
	my $bosh = $env->bosh;

	my $subcommand = "bosh_configs_$action";
	return (\&{$subcommand})->($env, $bosh, %options);
}

sub bosh_configs_upload {
	my ($env, $bosh, %options) = @_;
	print "Genesis::Commands::Bosh::bosh_configs_upload called - TO BE IMPLEMENTED\n";
	return 1;
}

sub bosh_configs_list {
	my ($env, $bosh, %options) = @_;
	print "Genesis::Commands::Bosh::bosh_configs_list called - TO BE IMPLEMENTED\n";
	my $configs_raw = read_json_from(
		$bosh->execute({interactive => 0}, 'configs', '-r=99999', '--json')
	);
	my %configs = ();
	for my $config (@{$configs_raw->{Tables}[0]{Rows}}) {
		my ($type, $name) = @{$config}{qw{type name}};
		my ($id, $current) = $config->{id} =~ m/^(\d+)(\*)?$/;
		$configs{$type}{$name} //= {'current' => undef, 'entries' => {}};
		$configs{$type}{$name}{'current'} = $id if $current;
		$configs{$type}{$name}{'entries'}{$id} = {
			date => $config->{"created_at"},
			team => $config->{"team"},
		}
	}
	use Pry; pry();
	return 1;
}

sub bosh_configs_view {
	my ($env, $bosh, %options) = @_;
	print "Genesis::Commands::Bosh::bosh_configs_view called - TO BE IMPLEMENTED\n";
	return 1;
}

sub bosh_configs_compare {
	my ($env, $bosh, %options) = @_;
	print "Genesis::Commands::Bosh::bosh_configs_compare called - TO BE IMPLEMENTED\n";
	return 1;
}

sub bosh_configs_delete {
	my ($env, $bosh, %options) = @_;
	print "Genesis::Commands::Bosh::bosh_configs_delete called - TO BE IMPLEMENTED\n";
	return 1;
}
1;
# vim: fdm=marker:foldlevel=1:noet
