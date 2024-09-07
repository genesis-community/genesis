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

		# Check if user or repo allows oversized secrets to be ignored
		__allow_oversized => $Genesis::RC->get('suppress_warnings.oversized_secrets' => 0)
			|| ($env && $env->top->config->get('allow_oversized_secrets' => 0))
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
	$self->{__sources} //= [];
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
			push @{$self->{secrets}}, $secret_src;
			push @{$self->{__sources}}, ref($secret_src);
		} elsif (ref($secret_src) eq '' && ($secret_src//'') =~ /^Genesis::Env::Secrets::Parser::/) {
			eval "require $secret_src";
			bug(
				"Error encountered while trying to require $secret_src perl module:\n\n$@"
			) if $@;
			push @{$self->{secrets}}, $secret_src->new($self->env)->parse(notify => $self->verbose);
			push @{$self->{__sources}}, $secret_src;
		} elsif ($secret_src->isa('Genesis::Env::Secrets::Parser')) {
			push @{$self->{secrets}}, $secret_src->parse(notify => $self->verbose);
			push @{$self->{__sources}}, ref($secret_src);
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
		join("\n", map {"[[- >>".join("\n[[  >>",split(/\n/,$_->describe))} ($self->errors))
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

	$opts{allow_oversized} = $self->{__allow_oversized} if $self->{__allow_oversized};
	$self->notify(@update_args, 'init', total => scalar($self->secrets), indent => '  - ');
	for my $secret ($self->secrets) {
		my ($path, $label, $details) = $secret->describe;
		$self->notify(@update_args, 'start-item', path => $path, label => $label, details => $details);
		my ($result, $msg) = $secret->validate_value($self, %opts);
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
				my ($out,$rc) = $self->store->service->query({interactive => $interactive}, @command);
				$self->notify(@update_args, 'notify', msg=> "\nsaving user input ... ", nonl => 1) if $interactive;
				$self->notify(@update_args, 'done-item', result => ($rc ? 'error': 'ok'));
				last if $rc;
			}
		} else {
			my ($out, $rc) = $secret->process_command_output(
				'add', $self->store->service->query(@command)
			);
			if ($out =~ /refusing to .* as it is already present/ ||
					$out =~ /refusing to .* as the following keys would be clobbered:/) {
				$self->notify(@update_args, 'done-item', result => 'skipped')
			} elsif ($rc == '0' && !$out) {
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
					map {bullet($_, inline => 1, indent => 4)}
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

	$self->{notification_options} = {%opts{qw/level invalid indent/}, indent => '    '};
	my ($no_prompt,$interactive) = delete(@opts{qw/no_prompt interactive/});
	my $severity = ['','invalid','problem','unused', 'unused-vault', 'unused-credhub', 'unused-entombed']->[delete($opts{invalid})||0];

	my $label = '';
	my $confirm = $no_prompt ? 'none' : $interactive ? 'each' : 'all';
	if (! $severity) {
		my @selected_secrets = ($self->secrets);
		# TODO: specify label here or inside _remove_secrets?
		return $self->_remove_secrets(\@selected_secrets, confirm => $confirm, %opts);

	} elsif ($severity && $severity =~ /^unused/) {
		my $check_entombed = $severity =~ /^unused(-entombed)?$/;
		my ($last_manifest, $manifest_type);
		$self->env->notify("loading existing secrets to check for unused or outdated entries...");
		my %results = ();

		if ($severity =~ /^unused(|-credhub|-entombed)$/) {
			if ($check_entombed) {
				# Check if the last manifest deployed is available in exodus
				info({pending => 1}, "[[  - >>retrieving last deployed manifest to determine active entombed secrets ... ");
				my ($source, $error);
				my $t = time_exec(sub {
					($last_manifest, $manifest_type, $source, $error) = $self->env->last_deployed_manifest;
				});
				if ($error) {
					my $msg;
					if ($source eq 'exodus') {
						$msg = $error eq 'not_found'
							?	"[[    #R{[ERROR]} >>no deployment details found in exodus"
							: "[[    #R{[ERROR]} >>failed to retrieve last deployed manifest from exodus: $error"
					} elsif ($source eq 'file') {
						$msg = $error eq 'checksum_mismatch'
							? "[[    #R{[ERROR]} >>local deploy manifest does not match checksum in exodus"
							: "[[    #R{[ERROR]} >>local deploy manifest not found"
					} else {
						$msg = "[[    #R{[ERROR]} >>failed to retrieve last deployed manifest: $error";
					}
					info(
						"#R{failed!}".pretty_duration($t, 0.5, 1.0).
						"\n$msg".
						"\n[[  - >>will not be able to determine unneeded entombed secrets"
					);
					$check_entombed = 0;
				} else {
					info("#G{done}".pretty_duration($t, 0.5, 1.0));
				}
			}
			my $credhub = $self->env->credhub;
			unless ($credhub->is_preloaded) {
				info({pending => 1},
					"[[  - >>loading credhub secrets under path #c{%s} ... ",
					$credhub->base
				);
				my $t = time_exec(sub {
						$credhub->preload;
					});
				info "#G{done}".pretty_duration($t, scalar($self->secrets) * 0.04, scalar($self->secrets) * 0.1);
			}
		}
		if ($severity =~ /^unused(-vault)?$/) {
			info({pending => 1},
				"[[  - >>loading vault secrets under path #c{%s}...",
				$self->store->base
			);
			my $t = time_exec(sub {
					$self->store->fill($self->secrets);
			});
			info "#G{done}".pretty_duration($t, scalar($self->secrets) * 0.02, scalar($self->secrets) * 0.05);
			my @selected_secrets = $self->_unused_vault_secrets();
			my @partial_results = $self->_remove_secrets(
				\@selected_secrets,
				label => 'unused vault',
				confirm => $confirm,
				%opts
			);
			return @partial_results unless $severity eq 'unused';

			# Print message, stash results, and continue to next unused portion
			#$self->notify('remove', ...
			($results{$_}//=0) += $partial_results[0]{$_} for keys %{$partial_results[0]};
		}
		if ($severity =~ /^unused(-credhub)?$/) { # && is vaultified?
			my @selected_secrets = $self->_unused_credhub_secrets();
			my @partial_results = $self->_remove_secrets(
				\@selected_secrets,
				label => 'imported credhub',
				confirm => $confirm,
				source => 'credhub',
				%opts
			);
			return @partial_results unless $severity eq 'unused';
			($results{$_}//=0) += $partial_results[0]{$_} for keys %{$partial_results[0]};
		}
		if ($severity =~ /^unused(-entombed)?$/) {
			my @selected_secrets = $self->_unused_entombed_secrets($last_manifest, $manifest_type);
			my @partial_results = $self->_remove_secrets(
				\@selected_secrets,
				label => 'outdated entombed credhub',
				confirm => $confirm,
				source => 'credhub',
				%opts
			);
			return @partial_results unless $severity eq 'unused';
			($results{$_}//=0) += $partial_results[0]{$_} for keys %{$partial_results[0]};
		}
		# MAYBE: massage results into a cohesive message?
		my $msg = '';
		return \%results, $msg;
	} else {
		my $label = ($severity eq 'problem')
			? "invalid or problematic"
			: "invalid";

		$self->env->notify("checking existing secrets...");
		info({pending => 1}, "[[  - >>loading existing secrets from vault...");
		my $t = time_exec(sub {
				$self->store->fill($self->secrets);
		});
		info "#G{done}".pretty_duration($t, scalar($self->secrets) * 0.02, scalar($self->secrets) * 0.05);

		my @selected_secrets = $self->_invalid_secrets($severity, %opts);
		return $self->_remove_secrets(
			\@selected_secrets,
			label => $label,
			confirm => $confirm,
			%opts
		);
	}
}

# }}}
# notify - callback for notifying user with processing updates {{{
sub notify {
	my $self = shift;
	my $action = shift;
	my $opts = (ref($_[0]) eq 'HASH') ? shift : $self->{notification_options} || {};
	my ($state,%args) = @_;
	my $indent = $args{indent} || $opts->{indent} || '  ';
	$indent = "[[$indent>>" unless $indent =~ /^\[\[.*>>/;
	my $level = $opts->{level} || 'full';
	$level = 'full' if $args{'verbose'};
	$level = 'full' unless -t STDOUT;

	bug('Failure to specify $action') unless $action;

	$action = $args{action} if $args{action};
	$args{result} ||= '';
	(my $actioned = $action) =~ s/e?$/ed/;
	$actioned = 'found' if $actioned eq 'checked';
	(my $actioning = $action) =~ s/e?$/ing/;
	my $secret_label = $args{secret_label}//'secret';

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
			'remove/aborted'   => "#R{aborted} - #Yi{all remaining ${secret_label}s skipped}",
			'add/imported'     => '#C{imported}',
			'add/generated'    => '#Y{generated}',
			skipped            => '#Y{exists!}',
			'remove/missing'   => '#B{not present}',
			missing            => '#R{missing!}'
		};
		push(@{$self->{__update_notifications__items}{$args{result}} ||= []},
				 $self->{__update_notifications__item});

		if ("$action/$args{result}" eq 'remove/aborted') {
			info({pending => 1}, "\r[2K");
			my @updates = @{$self->{__update_notifications__last_start}};
			$updates[0] .= $map->{"$action/$args{result}"};
			info(@updates);
		} elsif ($args{result} && ($level eq 'full' || !( $args{result} eq 'ok' || ($args{result} =~ /^(skipped|imported)$/ && $action eq 'add')))) {
			info $map->{"$action/$args{result}"} || $map->{$args{result}} || $args{result}
		}

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
		if ($args{label} eq "Diffie-Hellman key exchange parameters" && $action =~ /^(add|rotate)$/) {
			$long_warning = ($level eq 'line' ? " - " : "; ")."#Yi{may take a very long time}"
		}
		$self->{__update_notifications__last_start} = [
			"%s[[[%*d/%*d] >>%s #wi{%s}%s ... ",
			$indent,
			$w, $self->{__update_notifications__idx},
			$w, $self->{__update_notifications__total},
			csprintf( ($args{path} =~ /^(.*?):([^: ]*)(?: \((.*)\))?$/)
				? "#C{$1}:#c{$2}".($3 ? " #mi{$3}" : '')
				: "#C{$args{path}}"
			),	
			$args{label} . ($level eq 'line' || !$args{details} ? '' : " - $args{details}"),
			$long_warning
		];
		info({pending => 1}, @{$self->{__update_notifications__last_start}});

	} elsif ($state eq 'init') {
		$self->{__update_notifications__start} = gettimeofday();
		$self->{__update_notifications__total} = $args{total};
		$self->{__update_notifications__idx} = 0;
		$self->{__update_notifications__items} = {};
		my $msg_action = $args{action} || sprintf("%s%s %s", $indent, $actioning, count_nouns($args{total}, $secret_label));
		info "%s under path '#C{%s}':", $msg_action, $args{base_path}//$self->store->base;

	} elsif ($state eq 'wait') {
		$self->env->manifest_provider->{suppress_notification}=1;
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
		my $skip_count = scalar(@{$self->{__update_notifications__items}{skipped} || []});
		my $unprocessed = $self->{__update_notifications__total}
			 - $ok_counts - $err_count - $warn_count - $missing_count
			 - $import_count - $gen_count - $skip_count;

		my $status = scalar(@{$self->{__update_notifications__items}{aborted} || []})
			? '#R{aborted}'
			: $err_count
			? '#r{failed}'
			: "#G{completed}";

		info "%s%s%s [%d %s/".$imported_counts_msg."%d skipped/#%s{%d errors}%s%s]",
			$indent,
			$status,
			pretty_duration(gettimeofday-$self->{__update_notifications__start},0,0,'',' in '),
			$ok_counts, $actioned, @imported_counts,
			$skip_count + $unprocessed,
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
		print "[u[0K" unless $args{noclear};
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
	my $kit_id = $self->env->kit->id if $self->env;
	do {
		_order_x509_secrets($target,\%signers,\@x509certs,\@ordered_secrets,\@errored_secrets, undef, $kit_id)
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
	my ($signer_path,$certs_by_signer,$src_certs,$ordered_certs,$errored_certs, $issuer, $kit_id) = @_;

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
		if (($kit_id//'') !~ /^cf\/2.*/ && $issuer) { # cf/v2.x kits have a CA subject DN error inherited from upstream
			my $subject_cn = $cert->get('subject_cn',(@{$cert->get('names' => [])})[0]);
			my $issuer_cn  = $issuer->get('subject_cn',(@{$issuer->get('names' => [])})[0]);
			push(@$errored_certs, $cert->reject(
				$cert->label => "CA Common Name Conflict - can't share CN '".$subject_cn."' with signing CA"
			)) if $subject_cn && $issuer_cn && $subject_cn eq $issuer_cn;
		}
		$cert->ordered(1);
		push @$ordered_certs, $cert;
		_order_x509_secrets($cert->path,$certs_by_signer,$src_certs,$ordered_certs,$errored_certs, $cert, $kit_id)
			if scalar(@{$certs_by_signer->{$cert->path} || []});
	}
}

# }}}
# _unused_vault_secrets - find secrets in the vault that are not used by the kit {{{
sub _unused_vault_secrets {

	# Note: the intention of this method is to find unused secrets under the vault
	# path for the kit.  It will not find secrets that may have been once used by
	# the environment that are in the vault but under a different root path.
	
	my ($self, %opts) = @_;

	my $vault_prefix = $self->store->base =~ s/^\///r;
	my @actual_paths = map {s/^$vault_prefix//r} $self->store->store_paths();

	# Get the list of secrets known to the kit, including formatted paths if they exist
	my $known_paths = { map {
		my $s = $_;
		map {($_, $s)} $s->all_paths
	} $self->secrets };

	# Also check for known vault paths from the manifest (aka $self->vault_paths)
	info ({pending => 1}, "[[  - >>determining vault paths used by environment ... ");
	my $used_paths;
	my $t = time_exec(sub {
		$used_paths = {
			map {
				my $k = $_;
				$k =~ m#/$vault_prefix(.*)# ? ($1,1) : ($k,1);
			} keys %{$self->env->vault_paths(notify => 0)}
		}
	});
	info("#G{done}".pretty_duration($t, scalar($self->secrets) * 0.02, scalar($self->secrets) * 0.08));

	my @unknown_paths = ();
	my @missing_paths = grep {!$known_paths->{$_} && !$used_paths->{$_}} @actual_paths;
	my @known_keys = grep {$_ =~ m/:/} uniq sort (keys %$known_paths, keys %$used_paths);
	info ({pending => 1}, "[[  - >>searching for keys under specified paths ... ");
	my $start_time = time;
	for my $missing_path (@missing_paths) {
		# Some of the paths may be keys instead of complex paths, so we need to
		# check each key.
		if (grep {$_ =~ m/^$missing_path:/} @known_keys) {
			# There is a known path that contains keys for this path -- validate each key
			my @keys = map {s/^$missing_path://r} $self->store->keys($vault_prefix.$missing_path);
			for my $key (@keys) {
				next if exists($known_paths->{$missing_path.':'.$key});
				next if exists($used_paths->{$missing_path.':'.$key});
				push(@unknown_paths, $missing_path.':'.$key);
			}
		} else {
			# This is a simple path, so we can just add it to the list of unknown paths
			push(@unknown_paths, $missing_path);
		}
	}
	my $elapsed_time = time - $start_time;
	info("#G{done}".pretty_duration($elapsed_time, scalar(@missing_paths) * 0.02, scalar(@missing_paths) * 0.05));
	return @unknown_paths;
}

# }}}
# _unused_credhub_secrets - find secrets in the credhub that are not used by the kit {{{
sub _unused_credhub_secrets {
	my ($self, %opts) = @_;

	# Return an empty list if the kit isn't based on credhub and not vaultified
	return () unless $self->env->is_vaultified;

	my $credhub = $self->env->credhub;
	my $credhub_prefix = $credhub->base;
	my @actual_paths = grep {$_ !~ /^genesis-entombed\//} map {s/^$credhub_prefix//r} $credhub->paths();
	my @unneeded_paths = ();

	my $known_secrets = { map {($_->var_name, $_)} grep {$_->from_manifest} $self->secrets };

	for my $path (@actual_paths) {
		if (my $secret = $known_secrets->{$path}) {
			# Path is known, lets see if it has been imported into vault
			if ($secret->has_value) {
				if (scalar($credhub->get($path)) eq $secret->value) {
					push @unneeded_paths, {path => $path, secret => $secret, details => '#Gi{imported, identical}'};
				} else {
					push @unneeded_paths, {path => $path, secret => $secret, details => '#Gi{imported,} #Yi{altered}'};
				}
			} else {
				# The secret has no value, so it has been not been imported into vault
				push @unneeded_paths, {path => $path, secret => $secret, details => '#Ri{not imported}'};
			}
		} else {
			# Path is not known, so it may not be safe to remove
			push @unneeded_paths, {path => $path, details => '#Yi{unknown}'};
		}
	}
	# TODO: only returning imported secrets for now, but may want to revisit this
	return grep {decolorize($_->{details}) =~ /^imported,/} @unneeded_paths;
}

# }}}
# _unused_entombed_secrets - find entombed secrets in credhub that are not used by the kit {{{
sub _unused_entombed_secrets {
	my ($self, $last_manifest, $type, %opts) = @_;

	my $credhub = $self->env->credhub;
	my $credhub_prefix = $credhub->base;
	my @entombed_paths = uniq sort grep {$_ =~ /^genesis-entombed\//} map {s/^$credhub_prefix//r} $credhub->paths();

	return {} unless @entombed_paths;

	# Determine if the last manifest contains entombed secrets
	if (!defined($type) || $type eq 'unknown') {
		# We need to do some forensics to determine the last manifest type
		my $flat_manifest = flatten({}, undef, $last_manifest);
		if (grep {$_ && /^\(\(genesis-entombed/} values %$flat_manifest) {
			$type = 'entombed';
		} elsif ($_ && /^REDACTED$/) {
			$type = 'redacted';
		} else {
			# still unknown
			$type = 'unknown';
		}
	}
	if ($type !~ /entombed$/) {

		# All entomed secrets are unused if the last manifest is not an entombed manifest
		# so we can just return all entombed paths
		warning(
			"\nLast deployed manifest is not an entombed manifest - all existing ".
			"entombed secrets are not being used."
		);
		return @entombed_paths;
	}

	# Get the list of entombed secrets from the last manifest
	my @used_paths = uniq sort 
		map {my @result = $_ =~ /\(\((.*?)\)\)/g; @result}
		grep {$_ && /^\(\(genesis-entombed/}
		values %{flatten({}, undef, $last_manifest)};

	my ($unused, $used) = compare_arrays(\@entombed_paths, \@used_paths);

	my @unused_paths = ();

	for my $path (@$unused) {
		my ($root, $key, $sig) = $path =~ m{^genesis-entombed/(.+?)--(.+?)--([a-z0-9]+)$};
		my $label = "$root:$key ($sig)";
		$label =~ s/^_\//\//;

		# The following works because any regular expression that doesn't match
		# will return an empty list, which means only matching paths will be considered
		# for the replacement signature, thus no need to grep first.
		my ($replacement) = map {$_ =~ /^genesis-entombed\/$root--$key--([a-z0-9]+)$/} @$used;
		if ($replacement) {
			push @unused_paths, {label => $label, path => $path, details => "#Yi{unused,} #Gi{replaced by $replacement}"};
		} else {
			push @unused_paths, {label => $label, path => $path, details => "#Yi{unused}"};
		}
	}
	return @unused_paths;
}

# }}}
# _invalid_secrets - find secrets that are invalid or problematic {{{
sub _invalid_secrets {
	my ($self, $severity, %opts) = @_;
	my @selected_secrets = ();
	my $label = ($severity eq 'problem')
			? "invalid or problematic"
			: "invalid";
	$self->notify('remove', 'init', action => "[[  - >>determining $label secrets", total => scalar($self->secrets));
	for my $secret ($self->secrets) {
		my ($path, $label, $details) = $secret->describe;
		$self->notify('remove', 'start-item', path => $path, label => $label, details => $details);
		my ($result, $msg) = $secret->validate_value($self);
		if ($result eq 'error' || ($result eq 'warn' && $severity eq 'problem')) {
			$self->notify('remove', 'done-item', result => $result, action => 'validate', msg => $msg) ;
			push @selected_secrets, $secret;
		} elsif ($result eq 'missing') {
			$self->notify('remove', 'done-item', result => $result, action => 'remove') ;
		} else {
			$self->notify('remove', 'done-item', result => 'ok', action => 'validate')
		}
	}
	$self->notify('remove', 'notify', indent => "[[  - >>", msg => sprintf("found %s %s secrets", scalar(@selected_secrets), $label));
	return @selected_secrets;
}

# }}}
# _remove_secrets - remove the selected secrets with optional prompting {{{
sub _remove_secrets {
	my ($self, $selected_secrets, %opts) = @_;

	my $source = $opts{source} || 'vault';
	my $base_path = $source eq 'credhub' ? $self->env->credhub->base : $self->store->base;

	my $label = $opts{label} ? $opts{label}.' secret' : 'secret';
	return ({empty => 1}, "- no ${label} found to remove.\n")
		unless @$selected_secrets;

	my $header = sprintf(
		"found %s %s%s",
		scalar(@$selected_secrets), $label, scalar(@$selected_secrets) == 1 ? '' : 's'
	);
	my %secret_label = ();
	my %secret_desc = ();
	for my $secret (@$selected_secrets) {
		if (ref($secret) eq 'HASH') {
			# Got a hash of secret details
			my $path_label = $secret->{label} || $secret->{path};
			my $path = $secret->{path};
			my $desc = csprintf($secret->{details});
			$secret_desc{$path} = $desc;
			$secret_label{$path} = ($path_label =~ /^(.*?):([^: ]*)(?: \((.*)\))?$/)
				? sprintf("#C{%s}:#c{%s}".($3 ? " (#mi{$3})" : '')." - #i{%s}", $1, $2 , $desc)
				: sprintf("#C{%s} - #i{%s}", $path_label, $desc);

		} elsif (ref($secret) && $secret->can('all_paths')) {
			# Got Genesis::Secret object
			for my $path ($secret->all_paths) {
				my $desc = $secret->path eq $path ? $secret->describe : $secret->can('format_path') ? $secret->describe('format') : '';
				$secret_desc{$path} = $desc;
				$secret_label{$path} = ($path =~ /^(.*?):([^: ]*)(?: \((.*)\))?$/)
					? sprintf("#C{%s}:#c{%s}".($3 ? " (#mi{$3})" : '')." - #i{%s}", $1, $2 , $desc)
					: sprintf("#C{%s} - #i{%s}", $path, $desc);
			}

		} else {
			# Assume got a secret vault path
			my $path = $secret;
			my $desc = '';
			if ($source eq 'vault') {
				if (my $secret = $self->secret_at($path)) {
					$desc = $secret->path eq $path ? $secret->describe : $secret->can('format_path') ? $secret->describe('format') : '';
				}
				$desc = "all keys: ".join(", ", keys %{$self->store->get($self->store->base.$path)})
					if (!$desc && $path !~ /:/);
			} else {
				# Credhub - to be implemented
				bail("Credhub removal not yet implemented");
			}
			$secret_desc{$path} = $desc;
			$secret_label{$path} = ($path =~ /^(.*?):([^:]*)$/)
				? sprintf("#C{%s}:#c{%s} - #i{%s}", $1, $2, $desc)
				: sprintf("#C{%s} - #i{%s}", $path, $desc);
		}
	}
	if ($opts{confirm} eq 'all') {
		my @selected_paths = sort keys %secret_label;
		my $total = scalar(@selected_paths);
		my $total_width = length($total);
		my $msg = sprintf(
			"%s\n  - will remove %s under path '#c{%s}'",
			$header, count_nouns($total, $label), $base_path
		);
		my $i = 0;
		for my $path (@selected_paths) {
			my $label = $secret_label{$path};
			$msg .= sprintf("\n    [%*s/%s] %s", $total_width, ++$i, $total, $label);
		}
		$self->env->notify($msg);
		warning("\nRemoving secrets cannot be undone!");
		my $proceed = $self->notify(
			'remove','inline-prompt',
			prompt => (' ' x (logger->style eq 'fun' ? 12 : 10))."Type 'yes' to remove ".
				count_nouns($total, $label, prefix => [qw/this these/]),
			noclear => 1,
			default => 'no'
		);
		info('');
		return ({abort => 1}, "Quit!\n") if ($proceed ne 'yes');
	} else {
		$self->env->notify($header);
	}

	$self->notify('remove', 'init',
		secret_label => $label,
		base_path    => $base_path,
		total        => scalar(@$selected_secrets),
		indent       => '[[  - >>'
	);

	$self->{notification_options}{level} = 'full' if $opts{confirm} eq 'each';
	for my $secret (@$selected_secrets) {
		my ($path, $alt_path, $desc, $details);
		if (ref($secret) eq 'HASH') {
			$path = $secret->{path};
			$alt_path = $secret->{alt_path};
		} elsif (ref($secret) =~ /^Genesis::Secret(::|$)/) {
			($path, $desc, $details) = $secret->describe;
		} else {
			$path = $secret;
		}
		$desc //= $secret_desc{$path};
		$details //= '';
		$self->notify('remove', 'start-item', path => $alt_path//$path, label => $desc, details => $details);
		if ($source eq 'credhub') {
			my $credhub = $self->env->credhub;
			if (!$credhub->has($path)) {
				$self->notify('remove', 'done-item', result => 'missing');
				next;
			}
		} elsif (ref($secret) =~ /^Genesis::Secret(::|$)/ && !$secret->exists) {
			$self->notify('remove', 'done-item', result => 'missing');
			next;
		}

		if ($opts{confirm} eq 'each') {
			my $confirm = $self->notify('remove', 'inline-prompt', prompt => '#Y{remove} [y/n/q/a]?');
			if ($confirm eq 'q') {
				$self->notify('remove', 'done-item', result => 'aborted', secret_label => $label);
				my $results = $self->notify('remove', 'completed', msg => "$label removed");

				return ({
					abort => 1,
					skipped => $self->{__update_notifications__total} - $self->{__update_notifications__idx} + 1 + scalar(@{$self->{__update_notifications__items}{skipped}//[]}),
					errors => scalar(@{$self->{__update_notifications__items}{error}//[]}),
					warnings => scalar(@{$self->{__update_notifications__items}{warn}//[]}),
					ok => scalar(@{$self->{__update_notifications__items}{ok}//[]}),
				}, "Quit!\n");
			} elsif ($confirm eq 'a') {
				$opts{confirm} = 'none';
			} elsif ($confirm ne 'y') {
				$self->notify('remove', 'done-item', result => 'skipped');
				next;
			}
		}

		my ($result, $msg, $out, $rc, @command) = ();
		if ($source eq 'credhub') {
			# Credhub - to be implemented
			my $credhub = $self->env->credhub;
			($out, $rc) = $credhub->delete($path);
			$out = "" if $out eq "Credential successfully deleted";
		} elsif (!ref($secret)) {
			# Raw vault path string
			@command = ('delete', $self->store->base.$secret);
			($out, $rc) = $self->store->service->query(@command);
		} elsif (ref($secret) =~ /^Genesis::Secret(::|$)/) {
			@command = $secret->get_safe_command_for('remove', %opts);
			my $cmd_interactive = $secret->is_command_interactive('remove', %opts);
			bug (
				"Interactive removal of secrets is not yet supported"
			) if $cmd_interactive;
			($out, $rc) = $secret->process_command_output('remove', $self->store->service->query(@command));
		} else {
			bug "Unknown secret type for removal";
		}

		if ($rc == '0') {
			$self->notify('remove', 'done-item', result => 'ok', msg => $out||undef)
		} else {
			$self->notify('remove', 'done-item', result => 'error', msg => $out);
		}
		last if ($rc);
	}
	return $self->notify('remove', 'completed', msg => sprintf(
		"$label%s removed", scalar(@$selected_secrets) == 1 ? '' : 's')
	);
}

# }}}
# }}}

1;
# vim: fdm=marker:foldlevel=1:noet
