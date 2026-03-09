package Genesis::Hook::RuntimeConfig;

use v5.20; # Genesis min perl version is 5.20
use warnings;

use parent qw(Genesis::Hook);

use Genesis qw/bail bug info output notice error warning count_nouns pretty_duration spruce_diff in_array uniq success to_yaml read_json_from/;
use Genesis::Term qw/in_controlling_terminal terminal_width wrap bullet render_markdown colored_block/;
use Genesis::UI qw/prompt_for_boolean/;
use Service::Credhub;
use Time::HiRes qw/gettimeofday/;

# init - Initialize the runtime config hook {{{
sub init {
	my ($class, %opts) = @_;
	my @required_opts = qw/env kit/;
	my @optional_opts = qw/interactive dryrun print remove args file label/;
	my @missing = grep {!defined($opts{$_})} @required_opts;
	bug(
		"Missing required arguments for a perl-based runtime-config hook call: %s",
		join(", ", @missing)
	) if @missing;
	# Check for optional arguments
	my @invalid_opts = grep {!in_array($_, @required_opts, @optional_opts)} keys %opts;
	bug(
		"Invalid optional arguments for a perl-based runtime-config hook call: %s",
		join(", ", @invalid_opts)
	) if @invalid_opts;
	bail(
		"Cannot specify both 'print' and 'remove' options."
	) if ($opts{print} && $opts{remove});


	my $obj = $class->SUPER::init(%opts);
	$obj->{args} //= [];
	$obj->{builds} = {};
	$obj->{bosh} = $obj->env->is_bosh_director
		? $obj->env->get_target_bosh(self => 1)
		: $obj->env->bosh;
	my $vault = $obj->{bosh}->{exodus_vault}//$obj->{env}->vault; # I don't think we need to store this in the obj...
	$obj->{credhub} = Service::Credhub->from_bosh($obj->{bosh});
	$obj->{secrets} = {};
	return $obj;
}

# }}}
# dryrun - Get dryrun flag {{{
sub dryrun {return $_[0]->{dryrun} // 0}

# }}}
# interactive - Get interactive flag {{{
sub interactive {return $_[0]->{interactive} // 0}

# }}}
# print - Get print flag {{{
sub print {return $_[0]->{print} // 0}

# }}}
# remove - Get remove flag {{{
sub remove {return $_[0]->{remove} // 0}

# }}}
# bosh - Get BOSH object {{{
sub bosh {return $_[0]->{bosh}}

# }}}
# credhub - Get Credhub object {{{
sub credhub {return $_[0]->{credhub}}

# }}}
# credhub_base - Get Credhub base path {{{
sub credhub_base {
	my ($self) = @_;
	return undef unless $self->env->feature_compatibility('3.0.0-rc.1')
		&& scalar($self->env->lookup('genesis.entomb', 1));
	return $self->credhub->base if $self->credhub && $self->credhub->base;
}

# }}}
# config_name_for - Get the config name for a runtime build {{{
sub config_name_for {
	my ($self, $build) = @_;
	return $self->env->bosh_config_name.".$build";
}

# }}}
# perform - Default perform method, so kits just have to implement the build_*_runtime methods {{{
sub perform {
	my $self = shift;
	my $env = $self->env;

	# FIXME: May need to revisit this output when called through post-deploy as it looks redundant
	$env->notify(
		"%s runtime config(s): %s %s",
		$self->remove ? "removing" : "generating", # Fixme vv
		join(", ", $self->{requests}->@*),
		$self->dryrun ? " (dry-run)" : ""
	);

	return $self->remove_configs() if ($self->remove);

	for my $config ($self->{requests}->@*) {
		my $config_name = $self->config_name_for($config);
		my $config_data = $self->build($config, $config_name);
		next unless $config_data; # If the build failed or was skipped, continue to the next config
		if ($self->print) {
			$self->print_config($config_data, $config_name);
			next;
		}

		next unless $self->compare_configs($config, $config_data, $config_name);
		next if ($self->dryrun);
		$self->upload_runtime_config($config, $config_data, $config_name);
	}

	# FIXME: Automatically upload any missing releases (if possible, or
	#        warn that they're missing) when uploading the runtime configs,
	#        or list them in dry-run mode.

	# Store any secrets that were generated during the runtime config builds (or
	# list them in dry-run mode)
	$self->store_secrets();

	# Clean up?
	success("\nDone!\n");
	return $self->done();
}

# }}}
# register_runtime_config_builds - Register available runtime config builds {{{
sub register_runtime_config_builds {
	my ($self, @names) = @_;
	bail("No builds specified for registration") unless @names;
	$self->{builds} = {}; # Reset builds to an empty hash, just in case this is reapplied
	my $i = 0; # Order of the builds, so we can sort them later
	for my $info (@names) {
		my ($name,$description) = ();
		if (ref($info) eq 'ARRAY') {
			$description = $info->[1] // '';
			$name = $info->[0];
		} else {
			$name = $info;
			$description = join(' ', map {ucfirst} split(/[_-]/, $name));
		}
		bail("Invalid runtime config name '%s' specified", $name) unless $name =~ /^[a-z0-9\-_]+$/i;

		my $build_method = sprintf('build_%s_runtime', $name =~ s/-/_/gr);
		if ($self->can($build_method)) {
			$self->{builds}{$name}{method} = $build_method;
			$self->{builds}{$name}{description} = $description;
			$self->{builds}{$name}{order} = $i++;
		} else {
			$self->kit_bug("Cannot find build method '%s' for runtime config", $build_method);
		}
	}
	return $self;
}

# }}}
# validate_runtime_config_requests - Validate requested runtime configs exist {{{
sub validate_runtime_config_requests {
	my ($self) = @_;
	my $args = $self->{args};

	# Step 0: Short circuit if no args are specified or if the args are 'true'
	if (!($args || (ref($args) eq 'JSON::PP::Boolean' && $args))) {
		# If no args are specified or the argument is 'true', we assume all valid
		# runtime configs are requested with default options (short-circuit the rest
		# of the function)
		$self->{requests} = [$self->_get_req_names('*')];
		$self->{request_options} = {};
		return 1;
	}

	# Step 1: Standardize the requests to a hash of request names with options
	if (!ref($args) && $args =~ /^[\w\,]+$/) {
		# If its a string, promote it to a hash with no options
		$args = {$args => {}};

	} elsif (ref($args) eq 'ARRAY') {
		# The world built a better idiot, and it was I.

		# The PostDeploy hook will pass in an array of not just strings, but also
		# hashes, so we need to be more surgical about how we handle this.
		my @names = ();
		my %new_args = ();
		my $disable_all = 0;
		for my $arg (@$args) {
			if (!ref($arg)) {
				# If its a string, we assume its a request name
				push(@names, $arg);
			} elsif (ref($arg) eq 'HASH') {
				# If its a hash, merge it into the new_args
				%new_args = (%new_args, %$arg);
			} elsif (ref($arg) eq 'JSON::PP::Boolean') {
				# If its a boolean, we assume its a request with no options
				push(@names, $arg ? '*' : ());
				$disable_all = 1 if !$arg; # If its false, we disable all requests
			} else {
				bail("Invalid runtime config request argument type: expecting a string, a boolean, or hash of options, got %s", ref($arg));
			}
		}
		$args = {%{@names ? {join(',', @names) => {}} : {}}, %new_args};
		if (!keys %$args && $disable_all) {
			# If we have no args and we disabled all, we assume no requests
			$args = {all => $JSON::PP::false};
		}
	} elsif (!ref($args) || ref($args) ne 'HASH') {
		# Invalid argument type, bail out
		bail(
			"Invalid runtime config request arguments: expecting a #C{true}, a ",
			"string, array of strings or build => option hash, or a hash of ".
			"runtime build with options or boolean, but got %s",
			ref($args)
				? "a ".ref($args)." value"
				: defined $args
				? "'#C{$args}'"
				: '#y{<undef>}'
		);
	}

	# Step 2: Convert the now-unified hash args to a list of requests and their options

	# It will merge options for any series of matches, specifically in the
	# case where you set a common set of options using '*' or a
	# comma-separated list.  Note that because hashes are unordered, any merging should
	# NOT count of the order of processing.
	my @requests = ();
	my %req_opts = ();
	my @excluded_reqs = ();

	for my $req_id (keys %{$args}) {
		my @names = $self->_get_req_names($req_id);
		my $opts = $args->{$req_id};
		if (ref($opts) eq 'JSON::PP::Boolean') {
			# Boolean options are reserved for inclusion/exclusion of requests
			push(@{$opts ? \@requests : \@excluded_reqs}, @names);
		} elsif (ref($opts) eq 'HASH') {
			# Any hashes are merged - leaving validation to the build_*_runtime methods
			push(@requests, @names);
			# Merge if they already exist
			$req_opts{$_} = {%{$req_opts{$_} // {}}, %$opts} for @names;
		} else {
			# Invalid option type, bail out
			bail(
				"Invalid runtime config request options for '%s': expecting a hash or boolean, got %s",
				$req_id, ref($opts) || $opts || '#y{<undef>}'
			);
		}
	}

	# Step 3: Handle excluded requests
	if (@excluded_reqs) {
		# If there are any excluded requests, we remove them from the requests list
		# (defaults to all builds)
		@requests = @requests
			? grep {!in_array($_, @excluded_reqs)} @requests
			: grep {!in_array($_, @excluded_reqs)} $self->_get_req_names('*');
	}

	# Step 4: Validate the requests
	my @invalid_requests = grep {!exists $self->{builds}->{$_}} @requests;
	my $padding = (sort {$a <=> $b} map {length($_)} keys %{$self->{builds}})[-1];
	bail(
		"Invalid runtime config requests: %s\n\nExpecting one or more of the following:\n%s\n\n".
		"[[#Yi{Note:}>> No arguments is the same as requesting all runtime configs.\n",
		join(", ", @invalid_requests),
		join("\n", map {sprintf(
			"[[  #C{%-*s}>> %s %s runtime config",
			$padding+1,
			$_.':',
			ucfirst($self->action),
			$self->{builds}->{$_}{description} // $_
		)} sort keys %{$self->{builds}}),
	) if @invalid_requests;

	$self->{requests} = [uniq @requests];
	$self->{request_options} = \%req_opts;
	return 1;
}

# }}}
# action - Get current action description {{{
sub action {
	my ($self) = @_;
	return $self->{remove} ? "remove" : $self->{dryrun} ? "generate" : "generate and upload";
}

# }}}
# build - Build a specific runtime config {{{
sub build {
	my ($self, $build) = @_;
	bail("No runtime config name specified") unless $build;
	bail("Invalid runtime config name '%s' specified", $build)
		unless exists $self->{builds}->{$build};

	my $build_method = $self->{builds}->{$build}{method};
	my $description = $self->{builds}->{$build}{description};
	info({pending => 1}, "\n  - synthesizing #m{%s} runtime config...", $description);
	my $start_time = gettimeofday();

	$self->{__current_config} = $build; # This is so the _get_secrets knows which config its for
	my ($config_data,$status,$msg) = $self->$build_method();
	delete $self->{__current_config};

	if ($status && $status eq 'failed') {
		info("#R{failed}".pretty_duration(gettimeofday() - $start_time));
		error({prefix => '    '}, $msg);
		delete $self->{secrets}{$build};
		return undef;
	} elsif ($status && $status eq 'skipped') {
		info("#y{skipped}".pretty_duration(gettimeofday() - $start_time));
		warning({prefix => '    '},
			"#y{Skipping %s runtime config generation: %s}",
			$build, $msg
		);
		return undef;
	} else {
		info("#G{done}".pretty_duration(gettimeofday() - $start_time));
	}
	$config_data = to_yaml($config_data) if (ref($config_data)//'') =~ /HASH|ARRAY/;
	return $config_data;
}

# }}}
# print_config - Print runtime config contents {{{
sub print_config {
	my ($self, $config_data, $config_name) = @_;
	bail("No runtime config contents given") unless $config_data;
	my $code_colors = $Genesis::RC->get('ui.colors.code', 'Yb');
	output({raw => 1},
		"\n#%s{#--[%s]%s}\n%s\n",
		$code_colors,
		$config_name,
		'-' x (terminal_width - length($config_name) - 5),
		colored_block($config_data, $code_colors)
	);
	return 1;
}

# }}}
# compare_configs - Compare existing vs generated config {{{
sub compare_configs {
	my ($self, $build, $config_data, $config_name) = @_;
	my $description = $self->{builds}->{$build}{description} // $build;

	# Check if the config data is already present on the bosh director, and if so, diff it
	if ($self->bosh->has_config('runtime',$config_name)) {
		local $ENV{BOSH_NON_INTERACTIVE} = 1; # We do interactive outside of bosh commands
		my $current_config = $self->bosh->get_config('runtime',$config_name);
		my ($diff, $is_diff) = spruce_diff(
			{content => $current_config, label => 'existing'},
			{content => $config_data,    label => 'generated'}
		);
		if ($is_diff) {
			info("  - found the following changes between existing and generated #m{%s} runtime config:\n\n%s", $description, $diff);
		} else {
			info("  - existing #m{%s} runtime config is already up to date", $description);
			return undef;
		}
	} else {
		info(
			"  - no existing #m{%s} runtime config found, generated the following:\n\n%s",
			$description,
			render_markdown("```yaml\n$config_data```") . $Genesis::Term::ansi_cursor_up
		);
	}
	return 1;
}

# }}}
# upload_runtime_config - Upload runtime config to BOSH {{{
sub upload_runtime_config {
	my ($self, $build, $config_data, $config_name) = @_;
	my $description = $self->{builds}->{$build}{description} // $build;

	# Determine if we can upload the config
	if ($self->interactive) {
		# TODO: Support case where yes is default but user specified --interactive or the like
		bail(
			"Not in a controlling terminal, cannot prompt for confirmation to upload ".
			"runtime config. Please use #y{%s} to skip the confirmation prompt.",
			$self->{yes_option} // '--yes'
		) unless in_controlling_terminal;

		# If we're in interactive mode, we can prompt the user to confirm the upload
		my $prompt = wrap(sprintf(
			"[[  - >>upload #m{%s} runtime config #c{%s} to BOSH director #M{%s}? [y|n]",
			$description, $config_name, $self->bosh->alias || $self->bosh->host
		), terminal_width - 2);
		if (prompt_for_boolean($prompt, 1, 1)) {
			info("[[  - >>#y{skipped}\n");
			return undef;
		}
	}

	my $start_time = gettimeofday();
	info({pending => 1}, "[[  - >>uploading #m{%s} runtime config...", $description);
	local $ENV{BOSH_NON_INTERACTIVE} = 1; # We do interactive outside of bosh commands
	my ($out, $rc, $err) = $self->bosh->upload_config($config_data, 'runtime', $config_name);
	if ($rc) {
		info("#R{failed}".pretty_duration(gettimeofday() - $start_time));
		error("Failed to upload %s runtime config: %s", $description, $err||$out);
		delete $self->{secrets}{$build};
		return undef;
	}
	info("#G{done}".pretty_duration(gettimeofday() - $start_time));
	info("[[  - >>#G{runtime config upload %scomplete}\n", $self->dryrun ? "dry-run " : "");
	return 1;
}

# }}}
# remove_configs - Remove runtime configs from BOSH {{{
sub remove_configs {
	my ($self) = @_;

	my %existing = map {
		($_->{name} => {
			since => $_->{created_at},
			id => $_->{id} =~ s/\*$//r,
			used => $_->{id} =~ /\*$/
		})
	} @{$self->_get_runtime_configs()};

	for my $config_build ($self->{requests}->@*) {
		my $config = $self->config_name_for($config_build);
		if (!exists $existing{$config}) {
			info("  - runtime config #g{%s} does not exist", $config);
			next;
		}
		if ($self->{dryrun}) {
			info(
				"[[  - >>would remove %s runtime config #c{%s} (id: %s - %s)",
				$existing{$config}{used} ? "#y{active}" : "#g{unused}",
				$config, $existing{$config}{id}, $existing{$config}{since}
			);
		} elsif ($self->{yes}) {
			my $start_time = gettimeofday();
			info({pending => 1}, "  - removing existing #g{%s} runtime...", $config);
			$self->{bosh}->delete_config('runtime', $config);
			info("#G{done}".pretty_duration(gettimeofday() - $start_time));
		} else {
			my $prompt = wrap(sprintf(
				"[[  - >>remove %s runtime config #c{%s} (id: %s - %s)? [y|n]",
				$existing{$config}{used} ? "#y{active}" : "#g{unused}",
				$config, $existing{$config}{id}, $existing{$config}{since}
			), terminal_width - 2);
			if (prompt_for_boolean($prompt, 0, 1)) {
				info("[[  - >>#y{skipping}\n");
				next;
			}
			$self->{bosh}->delete_config('runtime', $config);
		}
	}

	success("\nruntime config removal %scomplete\n", $self->dryrun ? "dry-run " : "");
	return $self->done(1);
}

# }}}
# store_secrets - Store secrets to Credhub {{{
sub store_secrets {
	my ($self) = @_;

	# Entombify the secrets if allowed
	my %secrets = map {%$_} values $self->{secrets}->%*;
	if (keys %secrets) {
		my $start_time = gettimeofday();
		# TODO: Might be faster to get the list of existing secrets under
		# /runtime-configs/genesis-entombments and only entomb the new ones (and
		# identify the ones that are already entombed), but right now it only takes
		# ~1-2 seconds, so not a big deal.
		if ($self->{dryrun}) {
			info(
				"\n[[  - >>would entomb %s used by these runtime configs:\n%s",
				count_nouns( scalar keys %{$self->{secrets}}, "secret"),
				join("\n", map {bullet($_, indent => 4)} map {sprintf(
					"#c{%s}#C{%s}", ($_ =~ m#^(.*/)([^/]+)$#),
				)} sort keys %secrets)
			);
		} else {
			info(
				"\n[[  - >>entombing %s secrets used by these runtime configs:",
				scalar keys %secrets
			);
			my $idx = 0;
			my $secrets_count = scalar keys %secrets;
			my $w = length("$secrets_count");
			my $previous_lines = 0;
			for my $credhub_var (sort keys %secrets) {
				my $value = $secrets{$credhub_var};
				info( "%s#c{%s}#C{%s}", bullet('', indent => 4),
					($credhub_var =~ m#^(.*/)([^/]+)$#),
				);
				$self->{credhub}->set($credhub_var, $value);
			}
			info("    #G{done}".pretty_duration(gettimeofday() - $start_time));
		}
	}
}

# }}}
# _get_secret - Get secret from vault or credhub {{{
sub _get_secret {
	my ($self, $secret) = @_;
	my $config = $self->{__current_config};
	my ($path, $key) = split(/:/, $secret, 2);
	my $original_path = $path;
	my $base_path = $self->env->secrets_store->base;
	$path = $base_path.$path unless $path =~ m#^/#;
	my $value = $self->env->vault->get($path,$key);
	return $value unless $self->credhub_base;

	$original_path = "_$original_path" if $original_path =~ m#^/#;
	my $credhub_var = $self->get_credhub_variable(
		$self->credhub_base.'runtime-configs/genesis-entombments/',
		$original_path,
		$key,
		$value
	);
	$self->{secrets}{$config//''}{$credhub_var} = $value;
	return "(($credhub_var))";
}

# }}}
# _get_exodus_secret - Get secret from exodus data with entombment support {{{
sub _get_exodus_secret {
	my ($self, $key, $default, $deployment_slug) = @_;
	my $config = $self->{__current_config};

	# Use exodus_lookup which handles deployment slug pass-through automatically
	my $value = $self->env->exodus_lookup($key, $default, $deployment_slug);
	return $value unless $self->credhub_base;

	# we actually want an explicit deployment slug here, so we can entomb the secret
	# with the deployment slug as part of the path
	$deployment_slug //= $self->env->exodus_slug;

	# Create entombed reference if credhub is available
	my $credhub_var = $self->get_credhub_variable(
		$self->credhub_base . 'runtime-configs/genesis-entombments/',
		"exodus/$deployment_slug",
		$key,
		$value
	);
	$self->{secrets}{$config//''}{$credhub_var} = $value;
	return "(($credhub_var))";
}

# }}}
# _get_runtime_configs - Get runtime configs from BOSH {{{
sub _get_runtime_configs {
	my ($self, $name) = @_;
	my @cmd = ('configs', '--type=runtime', '--json');
	push @cmd, '--name='.$name if $name;
	my ($data, $rc, $err) = read_json_from($self->bosh->execute(@cmd));
	bail("Failed to get runtime configs: %s", $err) if $rc;
	return $data->{Tables}[0]{Rows};
}

# }}}
# _get_req_names - Get the runtime build name from a request identifier {{{
sub _get_req_names {
	# Names can be a single name, a comma-separated list of names, or '*'/'all'
	my ($self, $req_id) = @_;
	if ($req_id eq '*' || $req_id eq 'all') {
		# If the request is '*', we return all registered builds, sorted by their
		# registration order
		return sort {
			$self->{builds}->{$a}{order} <=> $self->{builds}->{$b}{order}
		} keys %{$self->{builds}};
	}
	return split(/,/, $req_id);
}

# }}}


1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
