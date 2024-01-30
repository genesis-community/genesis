package Genesis::Env::Secrets::Plan;

use strict;
use warnings;
use utf8;

use Genesis;
use Genesis::Term;
use Genesis::UI;
use Genesis::Env::Secrets::Parser;
use Time::HiRes qw/gettimeofday/;

### Class Methods {{{
# new - create a new blank plan object {{{
sub new {
	my ($class, $env, $store, $credhub, %opts) = @_;
	my $plan = {
		env     => $env,
		store   => $store,
		credhub => $credhub,
		parent  => undef,
		secrets => [],
		filter  => undef,

		# Options
		__verbose => exists($opts{verbose}) ? $opts{verbose} : 1,
	};
	return bless($plan, $class)
}

# }}}
# }}}

### Instance Methods {{{
# Read Accessors: env, parent, secrets, errors, secret_at {{{
sub env       {$_[0]->{env}}
sub store     {$_[0]->{store}}
sub credhub   {$_[0]->{credhub}}
sub parent    {$_[0]->{parent}}
sub secrets   {@{$_[0]->{secrets}} }
sub paths     {sort keys %{$_[0]->{paths}} }
sub secret_at {$_[0]->{paths}{$_[1]}};
sub errors    {grep {ref($_) eq 'Genesis::Secret::Invalid'} @{$_[0]->{secrets}} }

sub verbose {
	my $self = shift;
	$self->{__verbose} = shift if @_;
	return $self->{__verbose} ? 1 : 0
}

# }}}
# filters - list of filters currently applies to this plan (including parent plans) {{{
sub filters {
	my $self = shift;
	return ($self->{parent} ? $self->{parent}->filters : (), $self->{filters} ? @{$self->{filters}} : ())
}

# }}}
# populate - add secrets to the plan: accepts Secret::* objects, Env::Secrets::Parser::* objects or classes {{{
sub populate {
	my ($self, @secrets) = @_;
	if ($self->env && $self->verbose) {
		$self->env->notify({tags=>[qw(secrets task env)]},
			"processing secrets descriptions..."
		);
		logger->info("[[  - >>using kit #M{%s} #Ri{%s}", $self->env->kit->id =~ /^(.*?) ?(|\(dev\))?$/);
	}
	my %initial_counts = ();
	my $tstart = gettimeofday();
	$initial_counts{ref($_)}++ for ($self->secrets);
	for my $secret_src (@secrets) {
		if ($secret_src->isa('Genesis::Secret')) {
			push @{$self->{secrets}}, $secret_src
		} elsif (ref($secret_src) eq '' && ($secret_src//'') =~ /^Genesis::Env::Secrets::Parser::/) {
			eval "require $secret_src";
			push @{$self->{secrets}}, $secret_src->new($self->env)->parse(notify => $self->verbose);
		} elsif ($secret_src->isa('Genesis::Env::Secrets::Parser')) {
			push @{$self->{secrets}}, $secret_src->parse(notify => $self->verbose)
		} else {
			bug(
				"Genesis::Env::Secrets::Plan->populate was given an argument that ".
				"wasn't a Genesis::Secret object or a Genesis::Env::Secret::Parser ".
				"object or class."
			)
		}
	}

	# TODO: if there were any previous versions, make sure there are no path conflicts

	$self->_order_secrets(); # Note to self - this takes ~1ms, don't need to skip for efficiency when order doesn't matter.
	$self->{paths} = { map {($_->path, $_)} @{$self->{secrets}} };
	my %new_counts = map {($_,0-$initial_counts{$_})} keys %initial_counts;
	$new_counts{ref($_)}++ for ($self->secrets);
	my $count = 0; $count += $_ for values %new_counts;
	my $duration = gettimeofday - $tstart;
	return $self unless $self->env && $self->verbose;
	if ($count) {
		info({tags=>[qw(secrets task env)]},
			"[[  - >>processed %s%s%s",
			count_nouns($count, 'secret definition'),
			pretty_duration($duration,$count*0.04,$count*0.08,'', ' in '),
			$count > 0 ? " [".join('/', map {$new_counts{$_}." ".lc($_->type)} sort keys %new_counts)."]" : ''
		);
	} else {
		info({tags=>[qw(secrets task env)]},
			"[[  - >>no secrets defined for #C{%s}",
			$self->env->name
		);
	}
	return $self;
}

# }}}
# filter - filter the current plan by paths or property lookups, returning a new plan {{{
sub filter {
	my ($self,@filters) = @_;
	return $self unless @filters;

	# Filter
	my @explicit_paths;
	my @filtered_paths;
	my $filtered = 0;
	for my $filter ( @{[@filters]} ) { #and each filter with previous results
		if (grep {$_->{path} eq $filter} $self->secrets) { # explicit path
			push @explicit_paths, $filter;
			next;
		}
		my @or_paths;
		@filtered_paths = map {$_->{path}} $self->secrets # start will all possible paths
			unless $filtered++; # initialize on first use
		while (defined $filter) {
			my @paths;
			($filter, my $remainder) = $filter =~ /(.*?)(?:\|\|(.*))?$/; # or
			debug "Parsing left half of an or-filter: $filter || $remainder" if $remainder;

			if ($filter =~ /(.*?)(=|!=|=~|!~)(.*)$/) { # plan properties
				my ($key,$compare,$value) = ($1,$2,$3);
				my $negate = $compare =~ /^!/;
				my $re     = $compare =~ /~$/;
				@paths = map {
					$_->path
				} grep {
					my $check =
						($key eq 'path') ? $_->path :
						($key eq 'type') ? $_->type :
					  $_->has($key)    ? $_->get($key) : undef;

					if (!defined($check) && ($re || !$negate)) {
						#if $check is not defined and the filter is a regex or a equality, there can't be a match
						0
					} elsif ($re) {
						my ($pattern, $reopt) = $value =~ m'/(.*?)/(i)?$';
						$pattern //= $value;
						$reopt //='';
						my $re; eval "\$re = qr/\$pattern/$reopt";
						($negate ? $check !~ $re : $check =~ $re)
					} elsif ($value =~ /^(?:true|false)$/i) {
						$negate ? (($value eq 'true') xor !!$check) : (($value eq 'false') xor !!$check)
					} else {
						($negate ? $check ne $value : $check eq $value)
					}
				} $self->secrets;
				debug "Parsing plan properties filter: $key $compare '$value' => ".join(", ",@paths);

			} elsif ($filter =~ m'^(!)?/(.*?)/(i)?$') { # path regex
				my ($match,$pattern,$reopt) = (($1 || '') ne '!', $2, ($3 || ''));
				debug "Parsing plan path regex filter: path %s~ /%s/%s", $match?'=':'!', $pattern, $reopt;
				my $re; eval "\$re = qr/\$pattern/$reopt";
				@paths = map {$_->path} grep {$match ? $_->path =~ $re : $_->path !~ $re} $self->secrets;
			} else {
				bail "\nCould not understand path filter of '%s'", $filter;
			}
			@or_paths = uniq(@or_paths, @paths); # join together the results of successive 'or's
			$filter = $remainder;
		}
		my %and_paths = map {($_,1)} @filtered_paths;
		@filtered_paths = grep {$and_paths{$_}} @or_paths; #and together each feature
	}
	my %filter_map = map {($_,1)} (@filtered_paths, @explicit_paths);
	my @filtered_secrets = grep { $filter_map{$_->{path}} } $self->secrets;

	my $filtered_plan = bless({
		%$self,
		parent  => $self,
		secrets => [@filtered_secrets],
		filters => [@filters],
		paths   => { map {($_->path, $_)} @filtered_secrets }
	}, ref($self));

	info(
		"[[  - >>limited to %s secrets due to filter(s): %s",
		scalar($filtered_plan->secrets), join(', ', $filtered_plan->filters)
	);
	return $filtered_plan;
}

# }}}
# validate - validate the secret definitions, and any dependencies {{{
sub validate {
	my $self = shift;
	return 1 unless ($self->errors);
	bail(
		"\nErrors found in %s:\n%s\n".
		"#r{This may be an issue with the kit or with values in your environment ".
		"file(s).}",
		count_nouns(scalar($self->errors),'secret definition'),
		join("\n", map {"[[- >>".$_->describe} ($self->errors))
	);
}

# }}}
# check_secrets - check that the secrets are present {{{
sub check_secrets {
	my ($self,%opts) = @_;
	my @update_args = ('check', {%opts, indent => '    '});
	$self->env->notify("checking presence of environment secrets...");
	info({pending => 1}, "[[  - >>loading secrets from source...");
	my $t = time_exec(sub {$self->store->fill($self->secrets)});
	info("#G{done}".pretty_duration($t, scalar($self->secrets) * 0.02, scalar($self->secrets) * 0.05));

	$self->notify(@update_args, 'init', total => scalar($self->secrets), indent => '  - ');
	for my $secret ($self->secrets) {
		my ($path, $label, $details) = $secret->describe;
		$self->notify(@update_args, 'start-item', path => $path, label => $label, details => $details);
		my ($result, $msg) = $secret->check_value;
		$self->notify(@update_args, 'done-item', result => $result, msg => $msg, action => 'check');
	}
	return $self->notify(@update_args, 'completed');
}

# }}}
# validate_secrets - validate that the secrets are correctly formed {{{
sub validate_secrets {
	my ($self,%opts) = @_;
	my @update_args = ('validate', {%opts, indent => '    '});
	$self->env->notify("validating environment secrets...");
	info({pending => 1}, "[[  - >>loading secrets from source...");
	my $t = time_exec(sub {$self->store->fill($self->secrets)});
	info("#G{done}".pretty_duration($t, scalar($self->secrets) * 0.02, scalar($self->secrets) * 0.05));

	# TODO: if secret has a credhub var_name and the value in credhub differs, warn

	$self->notify(@update_args, 'init', total => scalar($self->secrets), indent => '  - ');
	for my $secret ($self->secrets) {
		my ($path, $label, $details) = $secret->describe;
		$self->notify(@update_args, 'start-item', path => $path, label => $label, details => $details);
		my ($result, $msg) = $secret->validate_value($self);
		$self->notify(@update_args, 'done-item', result => $result, msg => $msg, action => 'validate');
	}
	return $self->notify(@update_args, 'completed');
}

# }}}
# generate_secrets - create missing secrets from secret definition {{{
sub generate_secrets {
	my ($self,%opts) = @_;
	my @update_args = ('add', {%opts, indent => '    '});
	$self->env->notify("adding missing environment secrets...");
	info({pending => 1}, "[[  - >>loading existing secrets from source...");
	my $t = time_exec(sub {
			$self->store->fill($self->secrets);
			$self->credhub->preload() if $opts{import};
	});
	info("#G{done}".pretty_duration($t, scalar($self->secrets) * 0.04, scalar($self->secrets) * 0.08));

	$self->notify(@update_args, 'init', total => scalar($self->secrets), indent => '  - ');
	for my $secret ($self->secrets) {
		my ($path, $label, $details) = $secret->describe;
		$self->notify(@update_args, 'start-item', path => $path, label => $label, details => $details);
		if ($secret->has_value) {
			$self->notify(@update_args, 'done-item', result => 'skipped');
			next;
		}
		my ($import_result, $import_msg) = ();
		if ($opts{'import'} && $secret->from_manifest) {
			($import_result, $import_msg) = $secret->import_from_credhub($self->credhub);
			if ($import_result eq 'ok') {
				$self->notify(@update_args, 'done-item', result => 'imported', msg => $import_msg);
				next;
			}
		}

		my @command = $secret->get_safe_command_for('add');
		my $interactive = $secret->is_command_interactive('add');

		my ($result, $msg) = ();
		if ($interactive) {
			unless (in_controlling_terminal && scalar(@command)) {
				$self->notify(
					@update_args, 'done-item', result => 'error',
					msg => "Cannot prompt for user input from a non-controlling terminal"
				);
				last;
			}
			$self->notify(@update_args, "notify", msg => "#Yi{user input required:\n}");
			if (ref($command[0]) eq 'CODE') {
				my $precommand = shift @command;
				my @precommand_args;
				while (my $arg = shift @command) {
					last if $arg eq '--';
					push @precommand_args, $arg;
				}
				$interactive = $precommand->(@precommand_args);
			}
			if (@command) {
				$self->notify(@update_args, 'notify', msg=> "\nsaving user input ... ", nonl => 1) if ! $interactive;
				my ($out,$rc) = $self->query({interactive => $interactive}, @command);
				$self->notify(@update_args, 'notify', msg=> "\nsaving user input ... ", nonl => 1) if $interactive;
				$self->notify(@update_args, 'done-item', result => ($rc ? 'error': 'ok'));
				last if $rc;
			}
		} else {
			my ($out, $rc) = $self->store->service->query(@command);
			$out = $secret->process_command_output('add', $out) if $self->can('process_command_output');
			if ($out =~ /refusing to .* as it is already present/ ||
					$out =~ /refusing to .* as the following keys would be clobbered:/) {
				$self->notify(@update_args, 'done-item', result => 'skipped')
			} elsif ($rc == '0' &&  !$out) {
				if ($import_msg) {
					$self->notify(@update_args, 'done-item', result => 'generated', msg => "Import failed, generated new value: $import_msg");
				} else {
					$self->notify(@update_args, 'done-item', result => 'ok')
				}
			} else {
				$self->notify(@update_args, 'done-item', result => 'error', msg => $out);
			}
			last if ($rc);
		}
	}
	return $self->notify(@update_args, 'completed');
}

# }}}
# regenerate_secrets - create new versions of existing secrets {{{
sub regenerate_secrets {
	my ($self,%opts) = @_;
	my @update_args = ('rotate', {%opts{qw/level invalid indent/}, indent => '    '});
	my ($no_prompt,$interactive) = delete(@opts{qw/no_prompt interactive/});
	my $severity = ['','invalid','problem']->[delete($opts{invalid})||0];

	$self->env->notify("rotating environment secrets...");
	info({pending => 1}, "[[  - >>loading existing secrets from source...");
	my $t = time_exec(sub {
			$self->store->fill($self->secrets);
	});
	info("#G{done}".pretty_duration($t, scalar($self->secrets) * 0.02, scalar($self->secrets) * 0.05));

	my $label = '';
	my @selected_secrets = ();
	if ($severity) {
		$label = ($severity eq 'problem')
			? "invalid, problematic, or missing"
			: "invalid or missing";
		$self->notify(@update_args, 'init', action => "[[  - >>determining $label secrets", total => scalar($self->secrets));
		for my $secret ($self->secrets) {
			my ($path, $label, $details) = $secret->describe;
			$self->notify(@update_args, 'start-item', path => $path, label => $label, details => $details);
			my ($result, $msg) = $secret->validate_value($self);
			if ($result eq 'error' || $result eq 'missing' || ($result eq 'warn' && $severity eq 'problem')) {
				$self->notify(@update_args, 'done-item', result => $result, action => 'validate', msg => $msg) ;
				push @selected_secrets, $secret;
			} else {
				$self->notify(@update_args, 'done-item', result => 'ok', action => 'validate')
			}
		}
		$self->notify(@update_args, 'notify', indent => "[[  - >>", msg => sprintf("found %s %s secrets", scalar(@selected_secrets), $label));
		return ({empty => 1}, "- no $label secrets found to rotate.\n")
			unless @selected_secrets;
	} else {
		@selected_secrets = ($self->secrets);
	}

	if (!$no_prompt && !$interactive) {
		my $permission = $self->notify(@update_args, 'prompt',
			msg => sprintf(
				"[[  - >>the following secrets under path '#C{%s}' will be rotated:\n%s",
				$self->store->base,
				join("\n",
					map {bullet($_, inline => 1, indent => 6)}
					map {
						my @items;
						for my $path ($_->all_paths) {
							my $desc = $_->path eq $path ? $_->describe : $_->can('format_path') ? $_->describe('format') : '';
							if ($path =~ /^(.*?):([^:]*)$/) {
								push(@items, sprintf("#C{%s}:#c{%s} #i{%s}", $1, $2, $desc))
							} else {
								push(@items, sprintf("#C{%s} #i{%s}", $path, $desc))
							}
						}
						@items;
					}
					@selected_secrets
				)
			),
			prompt => "    Type 'yes' to rotate these secrets"
		);
		return ({abort => 1}) if $permission ne 'yes';
		info "";
	}

	$self->notify(@update_args, 'init', total => scalar(@selected_secrets), indent => '[[  - >>');
	for my $secret (@selected_secrets) {
		my ($path, $label, $details) = $secret->describe;
		$self->notify(@update_args, 'start-item', path => $path, label => $label, details => $details);

		if ($interactive) {
			my $confirm = $self->notify(@update_args, 'inline-prompt', prompt => '#Y{rotate} [y/n/q]?');
			if ($confirm ne 'y') {
				$self->notify(@update_args, 'done-item', result => 'skipped');
				return ({abort => 1}, "Quit!") if ($confirm eq 'q');
				next;
			}
		}

		my @command = $secret->get_safe_command_for('rotate', %opts);
		my $cmd_interactive = $secret->is_command_interactive('rotate', %opts);

		my ($result, $msg) = ();
		if ($cmd_interactive) {
			unless (in_controlling_terminal && scalar(@command)) {
				$self->notify(
					@update_args, 'done-item', result => 'error',
					msg => "Cannot prompt for user input from a non-controlling terminal"
				);
				last;
			}
			$self->notify(@update_args, "notify", msg => "#Yi{user input required:\n}");
			if (ref($command[0]) eq 'CODE') {
				my $precommand = shift @command;
				my @precommand_args;
				while (my $arg = shift @command) {
					last if $arg eq '--';
					push @precommand_args, $arg;
				}
				$interactive = $precommand->(@precommand_args);
			}
			if (@command) {
				$self->notify(@update_args, 'notify', msg=> "\nsaving user input ... ", nonl => 1) if ! $interactive;
				my ($out,$rc) = $secret->process_command_output('rotate', $self->query({interactive => $interactive}, @command));
				$self->notify(@update_args, 'notify', msg=> "\nsaving user input ... ", nonl => 1) if $interactive;
				$self->notify(@update_args, 'done-item', result => ($rc ? 'error': 'ok'));
				last if $rc;
			}
		} else {
			my ($out, $rc) = $secret->process_command_output('rotate', $self->store->service->query(@command));
			if ($out =~ /refusing to .* as it is already present/ ||
					$out =~ /refusing to .* as the following keys would be clobbered:/) {
				$self->notify(@update_args, 'done-item', result => 'skipped')
			} elsif ($rc == '0') {
				$self->notify(@update_args, 'done-item', result => 'ok', msg => $out||undef)
			} else {
				$self->notify(@update_args, 'done-item', result => 'error', msg => $out);
			}
			last if ($rc);
		}
	}
	return $self->notify(@update_args, 'completed', msg => ($label ? "$label ":'').'secrets rotated');
}


# }}}
# remove_secrets - remove some or all the secrets in the plan {{{
sub remove_secrets {
	my ($self,%opts) = @_;
	my @update_args = ('remove', {%opts{qw/level invalid indent/}, indent => '    '});
	my ($no_prompt,$interactive) = delete(@opts{qw/no_prompt interactive/});
	my $severity = ['','invalid','problem']->[delete($opts{invalid})||0];

	$self->env->notify("rotating environment secrets...");
	info({pending => 1}, "[[  - >>loading existing secrets from source...");
	my $t = time_exec(sub {
			$self->store->fill($self->secrets);
	});
	info("#G{done}".pretty_duration($t, scalar($self->secrets) * 0.02, scalar($self->secrets) * 0.05));

	my $label = '';
	my @selected_secrets = ();
	if ($severity) {
		$label = ($severity eq 'problem')
			? "invalid or problematic"
			: "invalid";
		$self->notify(@update_args, 'init', action => "[[  - >>determining $label secrets", total => scalar(@selected_secrets));
		for my $secret ($self->secrets) {
			my ($path, $label, $details) = $secret->describe;
			$self->notify(@update_args, 'start-item', path => $path, label => $label, details => $details);
			my ($result, $msg) = $secret->validate_value($self);
			if ($result eq 'error' || ($result eq 'warn' && $severity eq 'problem')) {
				$self->notify(@update_args, 'done-item', result => $result, action => 'validate', msg => $msg) ;
				push @selected_secrets, $secret;
			} elsif ($result eq 'missing') {
				$self->notify(@update_args, 'done-item', result => $result, action => 'remove') ;
			} else {
				$self->notify(@update_args, 'done-item', result => 'ok', action => 'validate')
			}
		}
		$self->notify(@update_args, 'notify', indent => "[[  - >>", msg => sprintf("found %s %s secrets", scalar(@selected_secrets), $label));
		return ({empty => 1}, "- no $label secrets found to remove.\n")
			unless @selected_secrets;
	} else {
		@selected_secrets = ($self->secrets);
	}

	if (!$no_prompt && !$interactive) {
		my $permission = $self->notify(@update_args, 'prompt',
			msg => sprintf(
				"[[  - >>the following secrets under path '#C{%s}' will be removed\n%s",
				$self->store->base,
				join("\n",
					map {bullet($_, inline => 1, indent => 6)}
					map {
						my @items;
						for my $path ($_->all_paths) {
							my $desc = $_->path eq $path ? $_->describe : $_->can('format_path') ? $_->describe('format') : '';
							if ($path =~ /^(.*?):([^:]*)$/) {
								push(@items, sprintf("#C{%s}:#c{%s} #i{%s}", $1, $2, $desc))
							} else {
								push(@items, sprintf("#C{%s} #i{%s}", $path, $desc))
							}
						}
						@items;
					}
					grep {$_->has_value}
					@selected_secrets
				)
			),
			prompt => "    Type 'yes' to remove these secrets"
		);
		return ({abort => 1}) if $permission ne 'yes';
		info "";
	}

	$self->notify(@update_args, 'init', total => scalar(@selected_secrets), indent => '[[  - >>');
	for my $secret (@selected_secrets) {
		my ($path, $label, $details) = $secret->describe;
		$self->notify(@update_args, 'start-item', path => $path, label => $label, details => $details);
		if (!$secret->has_value) {
			$self->notify(@update_args, 'done-item', result => 'missing');
			next;
		}

		if ($interactive) {
			my $confirm = $self->notify(@update_args, 'inline-prompt', prompt => '#Y{remove} [y/n/q]?');
			if ($confirm ne 'y') {
				$self->notify(@update_args, 'done-item', result => 'skipped');
				return ({abort => 1}, "Quit!\n") if ($confirm eq 'q');
				next;
			}
		}

		my @command = $secret->get_safe_command_for('remove', %opts);
		my $cmd_interactive = $secret->is_command_interactive('remove', %opts);

		my ($result, $msg) = ();
		if ($cmd_interactive) {
			unless (in_controlling_terminal && scalar(@command)) {
				$self->notify(
					@update_args, 'done-item', result => 'error',
					msg => "Cannot prompt for user input from a non-controlling terminal"
				);
				last;
			}
			$self->notify(@update_args, "notify", msg => "#Yi{user input required:\n}");
			if (ref($command[0]) eq 'CODE') {
				my $precommand = shift @command;
				my @precommand_args;
				while (my $arg = shift @command) {
					last if $arg eq '--';
					push @precommand_args, $arg;
				}
				$interactive = $precommand->(@precommand_args);
			}
			if (@command) {
				$self->notify(@update_args, 'notify', msg=> "\nsaving user input ... ", nonl => 1) if ! $interactive;
				my ($out,$rc) = $secret->process_command_output('remove', $self->query({interactive => $interactive}, @command));
				$self->notify(@update_args, 'notify', msg=> "\nsaving user input ... ", nonl => 1) if $interactive;
				$self->notify(@update_args, 'done-item', result => ($rc ? 'error': 'ok'));
				last if $rc;
			}
		} else {
			my ($out, $rc) = $secret->process_command_output('remove', $self->store->service->query(@command));
			if ($rc == '0') {
				$self->notify(@update_args, 'done-item', result => 'ok', msg => $out||undef)
			} else {
				$self->notify(@update_args, 'done-item', result => 'error', msg => $out);
			}
			last if ($rc);
		}
	}
	return $self->notify(@update_args, 'completed', msg => ($label ? "$label ":'').'secrets removed');
}

# }}}
# }}}

### Private Instance Methods {{{
# _order_secrets - determine signing changes, add defaults and specify build order {{{
sub _order_secrets {
	my $self = shift;
	my $root_ca_path = $self->env->root_ca_path if $self->env;

	my @ordered_secrets = ();
	my @errored_secrets = ();

	my @x509certs = grep {ref($_) eq 'Genesis::Secret::X509'} @{$self->{secrets}};
	#my @paths = map {$_->paths} grep {ref($_) eq 'Genesis::Secret::X509'} @{$self->{secrets}};

	my %base_cas = ();
	for my $ca (grep {$_->get(is_ca => '')} @x509certs) {
		my $base_path = $ca->get('base_path') or next;
		push(@{$base_cas{$base_path}}, $ca);
	}

	for my $base_path (keys %base_cas) {
		my ($base_ca_path, $err);
		my $count = scalar(@{$base_cas{$base_path}});
		if ($count == 1) {
			# Use the ca for the base path
			$base_ca_path = $base_cas{$base_path}[0]->path;
		} elsif (grep {$_->path eq "$base_path/ca"} @{$base_cas{$base_path}}) {
			# Use the default ca if there's more than one
			$base_ca_path = "$base_path/ca";
		} else {
			# Ambiguous - flag this further down
			$err = "Unspecified/ambiguous signing CA";
		}

		my @signable_certs = grep {
			$_->get(base_path => '') eq $base_path &&
			! $_->get(signed_by => undef) &&
			$_->path ne $base_ca_path
		} @x509certs;

		for my $cert (@signable_certs) {
			if ($err) {
				push @errored_secrets, $cert->reject(
					$cert->label => "Ambiguous or missing signing CA"
				)
			} else {
				$cert->set(signed_by => $base_ca_path);
			}
		}
	}

	my %signers = ();
	push (@{$signers{$_->get(signed_by => '')}}, $_) for (@x509certs);

	$signers{$_} = [sort {$a->path cmp $b->path} @{$signers{$_}}]
		for (keys %signers); #sorts each signers list of signees by path

	my @unsigned_certs = @{$signers{''}//[]};
	for my $cert (@unsigned_certs) {
		next if grep {$_->path eq $cert->path} @errored_secrets;
		if ($root_ca_path) {
			$cert->set(signed_by => $root_ca_path);
			$cert->set(self_signed => 0);
		} else {
			#FIXME: should error if cert isn't a CA...
			$cert->set(self_signed => 1);
		}
	}

	my $target = undef;
	do {
		_order_x509_secrets($target,\%signers,\@x509certs,\@ordered_secrets,\@errored_secrets)
	} while ($target = _next_x509_signer(\%signers));

	# Find unresolved signage paths and handled errors
	push @ordered_secrets, $_->reject(
		$_->label => "Could not find associated signing CA"
	) for (grep {!$_->ordered} @x509certs);

	for my $error (@errored_secrets) { # Replace errored x509 with Invalid Secret for that path
		my $err_path = $error->path;
		my ($ordered_idx) = grep {$ordered_secrets[$_]->path eq $err_path} (0 ... $#ordered_secrets);
		$ordered_secrets[$ordered_idx] = $error if defined($ordered_idx);
	}

	#Add the rest of the non-x509 secrets
	$self->{secrets} = [
		@ordered_secrets,
		sort {$a->path cmp $b->path}
		grep {ref($_) ne 'Genesis::Secret::X509'}
		@{$self->{secrets}}
	];
	$_->set_plan($self) for $self->secrets;
	return $self
}

# }}}
# _next_x509_signer - get the next available signing x509 certificate {{{
sub _next_x509_signer {
	my $signers = shift;
	my @available_targets = grep {scalar(@{$signers->{$_}})} sort(keys %$signers);
	while (@available_targets) {
		my $candidate = shift @available_targets;
		# Dont use a signer if its signed by a remaining signer
		next if grep {$_ eq $candidate} map { @{$signers->{$_}} } @available_targets;
		return $candidate;
	}
	return undef;
}

# }}}
# _order_x509_secrets - process the certs in order of signer {{{
sub _order_x509_secrets {
	my ($signer_path,$certs_by_signer,$src_certs,$ordered_certs,$errored_certs) = @_;

	if ($signer_path) { # Not implicitly self-signed or signed by root ca path
		my $signer_certs = $certs_by_signer->{$signer_path};
		if (! grep {$_->path eq $signer_path} (@$ordered_certs)) { # Deal with self-signed cert
			my ($idx) = grep {$signer_certs->[$_]->path eq $signer_path} ( 0 .. $#$signer_certs);
			if (defined($idx)) { # I'm signing myself - must be a CA
				my $cert = splice(@{$signer_certs}, $idx, 1);
				$cert->set(self_signed => 2); # explicitly self-signed
				$cert->set(signed_by => "");  # WHY??!!
				unshift(@{$signer_certs}, $cert);
			}
		}
	}
	while (my $cert = shift(@{$certs_by_signer->{$signer_path//''}})) {
		if (grep {$_->path eq $cert->path} (@$ordered_certs)) {
			push @$errored_certs, $cert->reject( $cert->label => 'Cyclical CA signage detected');
			next;
		}
		$cert->ordered(1);
		push @$ordered_certs, $cert;
		_order_x509_secrets($cert->path,$certs_by_signer,$src_certs,$ordered_certs,$errored_certs)
			if scalar(@{$certs_by_signer->{$cert->path} || []});
	}
}

# }}}
# notify - callback for notifying user with processing updates {{{
sub notify {
	my ($self,$action,$opts,$state,%args) = @_;
	my $indent = $args{indent} || $opts->{indent} || '  ';
	$indent = "[[$indent>>" unless $indent =~ /^\[\[.*>>/;
	my $level = $opts->{level} || 'full';
	$level = 'full' unless -t STDOUT;

	bug('Failure to specify $action') unless $action;

	$action = $args{action} if $args{action};
	$args{result} ||= '';
	(my $actioned = $action) =~ s/e?$/ed/;
	$actioned = 'found' if $actioned eq 'checked';
	(my $actioning = $action) =~ s/e?$/ing/;

	if ($state eq 'done-item') {
		my $map = {
			'validate/error'   => '#R{invalid!}',
			error              => '#R{failed!}',
			'check/ok'         => '#G{found.}',
			'validate/ok'      => '#G{valid.}',
			'validate/warn'    => '#Y{warning!}',
			ok                 => '#G{done.}',
			'rotate/skipped'   => '#Y{skipped}',
			'remove/skipped'   => '#Y{skipped}',
			'add/imported'     => '#C{imported}',
			'add/generated'    => '#Y{generated}',
			skipped            => '#Y{exists!}',
			'remove/missing'   => '#B{not present}',
			missing            => '#R{missing!}'
		};
		push(@{$self->{__update_notifications__items}{$args{result}} ||= []},
				 $self->{__update_notifications__item});

		info $map->{"$action/$args{result}"} || $map->{$args{result}} || $args{result}
			if $args{result} && ($level eq 'full' || !( $args{result} eq 'ok' || ($args{result} =~ /^(skipped|imported)$/ && $action eq 'add')));

		if (defined($args{msg}) && $args{msg} ne '') {
			my @lines = grep {$level eq 'full' || $_ =~ /^\[#[YR]/} split("\n",$args{msg});
			my $pad = " " x (length($self->{__update_notifications__total})*2+4);
			my $indent_pad = $indent =~ s/>>/$pad>>/r;
			info("%s%s", $indent_pad, join("\n$indent_pad", @lines)) if @lines;
			info("") if $level eq 'full' || scalar @lines;
		}
		info({pending => 1}, "\r[2K") unless $level eq 'full';

	} elsif ($state eq 'start-item') {
		$self->{__update_notifications__idx}++;
		my $w = length($self->{__update_notifications__total});
		my $long_warning='';
		if ($args{label} eq "Diffie-Hellman key exchange parameters" && $action =~ /^(add|recreate)$/) {
			$long_warning = ($level eq 'line' ? " - " : "; ")."#Yi{may take a very long time}"
		}
		info({pending => 1},
			"%s[%*d/%*d] #C{%s} #wi{%s}%s ... ",
			$indent,
			$w, $self->{__update_notifications__idx},
			$w, $self->{__update_notifications__total},
			$args{path},
			$args{label} . ($level eq 'line' || !$args{details} ? '' : " - $args{details}"),
			$long_warning
		);

	} elsif ($state eq 'init') {
		$self->{__update_notifications__start} = gettimeofday();
		$self->{__update_notifications__total} = $args{total};
		$self->{__update_notifications__idx} = 0;
		$self->{__update_notifications__items} = {};
		my $msg_action = $args{action} || sprintf("%s%s %s", $indent, $actioning, count_nouns($args{total}, 'secret'));
		info "%s under path '#C{%s}':", $msg_action,$self->store->base;

	} elsif ($state eq 'wait') {
		$self->manifest_provider->{suppress_notification}=1;
		$self->{__update_notifications__startwait} = gettimeofday();
		info {pending => 1},  "%s ... ", $args{msg};

	} elsif ($state eq 'wait-done') {
		$self->env->manifest_provider->{suppress_notification}=0;
		info("%s%s",
			$args{result} eq 'ok' ? "#G{done.}" : "#R{error!}",
			pretty_duration(gettimeofday - $self->{__update_notifications__startwait},0,0,'',' - ','Ki')
		) if ($args{result} && ($args{result} eq 'error' || $level eq 'full'));
		error("Encountered error: %s", $args{msg}) if ($args{result} eq 'error');
		info {pending => 1}, "\r[2K" unless $level eq 'full';

	} elsif ($state eq 'completed') {
		my @extra_errors = @{$args{errors} || []};
		my $warn_count = scalar(@{$self->{__update_notifications__items}{warn} || []});
		my $err_count = scalar(@{$self->{__update_notifications__items}{error} || []})
			+ scalar(@extra_errors)
			+ ($action =~ /^(check|validate)$/ ?
				scalar(@{$self->{__update_notifications__items}{missing} || []}) : 0);
		my $err_color = $err_count ? 'r' : '-';
		my $missing_count = $action eq 'remove'
			? scalar(@{$self->{__update_notifications__items}{missing} || []}) : 0;

		my $ok_counts = scalar(@{$self->{__update_notifications__items}{ok} || []});
		my $imported_counts_msg = '';
		my @imported_counts = ();
		my $import_count = scalar(@{$self->{__update_notifications__items}{imported}//[]});
		my $gen_count = scalar(@{$self->{__update_notifications__items}{generated}//[]});
		if ($action eq 'add' && $import_count + $gen_count > 0) {
			if ($gen_count == 0) {
				$imported_counts_msg = "%d imported/";
				push @imported_counts, $import_count;
			} else {
				$imported_counts_msg = "#y{%d of %d imported}/";
				push @imported_counts, $import_count, $import_count + $gen_count;
				$ok_counts += $gen_count;
			}
		}

		info "%s%s%s [%d %s/".$imported_counts_msg."%d skipped/#%s{%d errors}%s%s]",
		  $indent,
			$err_count ? "#R{failed}" : "#G{completed}",
			pretty_duration(gettimeofday-$self->{__update_notifications__start},0,0,'',' in '),
			$ok_counts, $actioned, @imported_counts,
			scalar(@{$self->{__update_notifications__items}{skipped} || []}),
			$err_color, $err_count,
			$warn_count ? "/#y{$warn_count warnings}" : '',
			$missing_count ? "/#B{$missing_count missing}" : '';
		$err_count += $warn_count
			if (($opts->{invalid}||0) == 2 || ($opts->{validate}||0) == 2);
		my $results = {
			map {($_, scalar(@{$self->{__update_notifications__items}{$_} || []}))} keys %{$self->{__update_notifications__items}}
		};
		return wantarray ? ($results,$args{msg}) : !$err_count;
	} elsif ($state eq 'inline-prompt') {
		die_unless_controlling_terminal(
			"Cannot prompt for confirmation to $action secrets outside a controlling ".
			"terminal.  Use #C{-y|--no-prompt} option to provide confirmation to ".
			"bypass this limitation."
		);
		print "[s\n[u[B[A[s"; # make sure there is room for a newline, then restore and save the current cursor
		my $response = Genesis::UI::__prompt_for_line($args{prompt}, $args{validation}, $args{err_msg}, $args{default}, !$args{default});
		print "[u[0K";
		return $response;
	} elsif ($state eq 'prompt') {
		my $title = '';
		if ($args{class}) {
			$title = sprintf("\r[2K\n#%s{[%s]} ", $args{class} eq 'warning' ? "Y" : '-', uc($args{class}));
		}
		info "%s%s", $title, $args{msg};
		die_unless_controlling_terminal(
			"Cannot prompt for confirmation to $action secrets outside a controlling ".
			"terminal.  Use #C{-y|--no-prompt} option to provide confirmation to ".
			"bypass this limitation."
		);
		return prompt_for_line(undef, $args{prompt}, $args{default} || "");
	} elsif ($state eq 'notify') {
		if ($args{nonl}) {
			info {pending => 1}, "%s%s", $indent, $args{msg};
		} else {
			info "%s%s", $indent, $args{msg};
		}
	} else {
		bug "notify encountered an unknown state '$state'";
	}
}

# }}}
# }}}

1;
# vim: fdm=marker:foldlevel=1:noet
