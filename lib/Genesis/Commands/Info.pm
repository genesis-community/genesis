package Genesis::Commands::Info;

use strict;
use warnings;
use feature 'state';
no warnings 'utf8';
use utf8;

use Genesis;
use Genesis::State;
use Genesis::Term;
use Genesis::Commands;
use Genesis::UI qw/prompt_for_boolean new_prompt_for_choice/;
use Genesis::Top;
use Genesis::Env::Deployment;

use Cwd            qw/getcwd abs_path/;
use File::Basename qw/basename/;
use JSON::PP       qw/encode_json/;
use Time::HiRes    qw/gettimeofday/;

sub information {
	# TODO: Make use of terminal_width and wrap to make this look better
	# FIXME: Make compatible with new (and existing) exodus data, including the deployment audit log

	command_usage(1) if @_ < 1 || @_ > 2;

	my ($name,$timestamp) = @_;
	my $env = Genesis::Top->new('.')->load_env($name)->with_vault();

	# Timestamp is only valid if the environment has deployment audit logs
	if ($timestamp) {
		bail(
			"Cannot use timestamp arguement with environments that do not have ".
			"deployment audit logs.  Please ensure the environment file specifies ".
			"#C{genesis.minimum_version} of at least #B{3.1.0}, and that the ".
			"#C{manifest_store} is set to #B{exodus} or #B{hybrid} in the ".
			"#c{<repo>/.genesis/config} file.",
		) if $env->manifest_store eq 'repository';
	} else {
		my @hooks = grep {$env->kit->has_hook($_)} qw(info);
		$env->download_required_configs(@hooks);
	}

	my $out = sprintf(
		"\n#c{%s}\n\n#C{%s Deployment for Environment '}#M{%s}#C{'}\n\n",
		"=" x terminal_width, uc($env->type), $env->name
	);

	my $deployment = undef;
	if ($timestamp) {
		my $trimmed_ts = $timestamp =~ s/[ \/:T]+//gr; # TODO: Handle converting to UTC if another timezone is specified
		my @deployments = $env->deployments->find(all => 1, range => $trimmed_ts);
		if (@deployments <= 1 && !defined($deployments[0]) ) {
			bail(
				"Could not find a deployment with timestamp matching ".
				"#C{%s} in environment #M{%s}.  Please ensure the timestamp is correct.",
				$timestamp, $env->name
			);
		} elsif (scalar(@deployments) > 1) {
			# If we found multiple deployments with the timestamp descriptor, prompt the user to chose one from a list we provide using new_prompt_for_choice
			my $choice = new_prompt_for_choice(
				header => sprintf(
					"Multiple deployments found with timestamp matching #C{%s} in environment #M{%s}.  Please select one:",
					$timestamp, $env->name
				),
				choices => [(map {{
					value => $_,
					label => sprintf(
						"%s - %s %s - #y{%s}",
						$_->completed('%Y/%m/%d %H:%M:%S'),
						$_->action eq 'deploy' ? 'deployment' : 'termination',
						$_->result,
						$_->user_description =~ s/ \[/\} #ki\{[/r || '#YI{unknown}'
					),
				}}	@deployments), {separator => 1}, {value => 'Cancel'}],
				default => $deployments[0]
			);

			bail(
				"Aborted!"
			) if $choice eq 'Cancel';
			$deployment = $choice;
		} else {
			$deployment = $deployments[0];
		}
	} else {
		$deployment = $env->deployments->latest_successful;
		unless ($deployment) {
			# Synthesize a last deployment based on the current exodus data
			my $exodus = $env->exodus_lookup(".",{});
			$deployment = $env->deployments->synthesize_from_exodus($exodus)
		}
	}

	if (my $artifact = get_options->{'print-artifact'}) {
		# If the user specified an artifact to print, we will print it
		# and exit.
		my $artifact_content = $deployment->artifact($artifact);
		bail(
			"Artifact '%s' not found in deployment %s.  Please confirm the artifact exists.",
			$artifact, $deployment->timestamp
		) unless ($artifact_content);

		my $output_target = get_io_target;
		my $target_msg = ($output_target eq 'terminal')
			? ":\n"
			: " written to #C{$output_target}";
		info(
			"Contents of artifact '%s' for deployment %s%s\n",
			$artifact,
			$deployment->timestamp,
			$target_msg
		);
		output {raw => 1}, $artifact_content;
		exit 0;
	}

	if (my $path = get_options->{'fetch-artifacts-to'}) {
		# If the user specified a path to fetch artifacts to, we will
		# fetch all artifacts and write them to the specified path.
		my @artifact_types = $deployment->artifact_types;
		bail(
			"Deployment #%d has no artifacts to fetch.",
			$deployment->sequence
		) unless scalar(@artifact_types);

		# Normalize the path in reference to the calling directory
		$path = Genesis::absolute_path($path, $ENV{GENESIS_CALLER_DIR});
		my $path_label = humanize_path($path);

		mkdir_or_fail($path) unless -d $path;

		# Check if there are any existing files in the path
		my @existing_files = map {s/^$path\///r} glob("$path/*");
		if (@existing_files) {
			prompt_for_boolean(
				wrap(
					"Path '$path_label' is not empty.  Continuing may overwrite some files - proceed? [y|n]",
					terminal_width
				),
				0,
			) or bail('Aborted!');
		}

		info(
			"Fetching artifacts for deployment #%s to '%s'...\n",
			$deployment->timestamp, $path_label
		);
		for my $artifact_type (@artifact_types) {
			next if $artifact_type eq 'secrets' && !get_options->{'INCLUDE-SECRETS-ARTIFACT'};
			info({pending => 1}, "[[  - >>fetching artifact type #M{%s} ... ", $artifact_type);
			my $output = $deployment->extract_artifacts_to($path, $artifact_type);
			my $file = $output->{$artifact_type};
			if ($file) {
				info("done: #C{%s}", humanize_path($file));
			} else {
				error("failed to fetch artifact type '%s' for deployment #%d", $artifact_type, $deployment->sequence);
				exit 1;
			}
		}
		success("\nDone!\n");
		exit 0;
	}

	my $unknown = csprintf("#YI{unknown}");
	if ($deployment) {
		$out .= sprintf(
			"[[  #I{%13s} >>%s\n".
			"[[  #I{           by} >>#C{%s}\n",
			$deployment->action eq 'deploy' ? 'Deployed' : 'Terminated',
			strfuzzytime($deployment->completed, "#C{%~} #-K{(%I:%M%p on %b %d, %Y %Z)}"),
			$deployment->user_description =~ s/ \[/\} #ki\{[/r || $unknown
		);

		# TODO: Handle standalone create-env deployments that aren't BOSH deployments
		if ($deployment->lookup('create_env')) {
			$out .= sprintf(
				"[[  #I{     via BOSH} >>#CI{create-env}\n"
			);
		} elsif ($deployment->lookup('bosh_target')) {
			$out .= sprintf(
				"[[  #I{      on BOSH} >>#CI{%s}\n",
				$deployment->lookup('bosh_target.name')
			);
		}

		$out .= sprintf(
			"[[  #I{ based on kit} >>#C{%s}%s%s\n",
			$deployment->lookup('kit.id') =~ s/ \(.*\)//r, # Remove the @dev suffix if present
			($deployment->lookup('kit.is_dev') ? " #y{(dev)}" : ''),
			($env->kit->version ne $deployment->lookup('kit.version','')
				? " #E{warning}#Y{local file specifies ${\($env->kit->id)}!}"
				: ''
			)
		) if $deployment->action eq 'deploy';

		$out .= sprintf(
			"[[  #I{        using}>> #C{Genesis v%s}\n",
			$deployment->lookup('genesis_version', 'unknown')
		);

		# TODO: Restore manifest validation status for 'repository' manifests
		if ($env->manifest_store eq 'repository') {
			# Do the manifest validation status here...
			bail(
				"Currently Genesis does not support manifest validation for ".
				"environments that store manifests in the repository.  Please set ".
				"#C{manifest_store} in the environment's #C{.genesis/config} to ".
				"#C{exodus} or #C{hybrid} to enable manifest validation."
			)
		}

		if ($deployment->{kit}{features}) {
			my @features = split(',', $deployment->{kit}{features});
			$out .= "\n[[      #Wku{Kit Features:} >>";
			if (@features) {
				$out .= "#C{".join("}\n[[                >>#C{",@features)."}\n";
			} else {
				$out .= "#Ci{None}\n";
			}
		}

		if ($env->manifest_store ne 'repository') {
			# All the manifests are stored in exodus, so we can get the details from
			# the last successful deployment.
			$out .= sprintf("\n#Wku{Archived Files:}\n");
			if (my @archived_types = $deployment->artifact_types) {
				my @standard_types = qw(manifest unpruned redacted vars redacted_vars state store secrets log);
				my (undef, $common, $extra) = compare_arrays(\@standard_types, \@archived_types); # Sort common first then any others
				my @details = $deployment->details_for_artifacts(@$common, @$extra);
				for my $artifact (@details) {
					$out .= sprintf(
						"[[  #I{%13.13s} >>#g{%s} #Ki{(%s b, SHA2: %s)}\n",
						$artifact->{type},
						$artifact->{filename},
						$artifact->{size},
						$artifact->{sha2} ? $artifact->{sha2} =~ s/^([a-f0-9]{6}).*([a-f0-9]{6})$/$1...$2/ir : 'n/a'
					);
				}
			}
		}

		if (get_options->{history}) {
			# Show the history of deployments
			my @deployments = $env->deployments->all;
			if (@deployments > 1) {
				my $prefix = "\n[[       #Wku{History:} >>";
				my @roles = ();
				for my $deployment (@deployments) {
					my ($roles_string, @used_roles) = $deployment->user_colorized_roles;
					@roles = uniq (@roles, @used_roles);
					$out .= sprintf(
						"%s#-K{[%s]} #%s{%-22s} - %s - #Ki{%s}\n",
						$prefix,
						$deployment->completed("%Y/%m/%d %H:%M"),
						$deployment->succeeded ? 'G' : 'R',
						($deployment->action eq 'deploy' ? 'deployment ' : 'termination ').
						($deployment->succeeded ? 'succeeded' : 'failed   '),
						$roles_string =~ s/%/%%/gr, # Escape % signs in the roles string
						$deployment->lookup('kit.id')
					);
					$prefix = "[[                >>";
					$out .= sprintf(
						"%s[[           #i{Reason:} >>%s\n\n",
						$prefix,
						$deployment->reason
					) if $deployment->has_reason;
					$out .= sprintf(
						"%s[[            #i{Error:} >>%s\n\n",
						$prefix,
						$deployment->error
					) if $deployment->has_error && $deployment->error ne 'Deployment failed.';
				}
				$out .=     "\n[[   #I{user legend:} >>".Genesis::Env::Deployment::user_colorized_legend(@roles)."\n";
			}
		}

		if ($env->has_hook('info') && !$timestamp && !get_options->{history}) {
			info "$out\n#c{%s}\n", "-" x terminal_width;
			$out = '';
			$env->run_hook('info');
		}
	} else {
		info $out; $out = '';
		error "#YI{No record of deployment found -- info available only after deployment!}"
	}

	info "$out\n#c{%s}\n", "=" x terminal_width;
}

sub lookup {
	command_usage(1) if @_ < 2 or @_ > 3;
	get_options->{exodus} = 1 if get_options->{'exodus-for'};
	command_usage(1,"Can only specify one of --merged, --partial, --deployed, or --exodus(-for)")
		if ((grep {$_ =~ /^(exodus|deployed|partial|merged|env)$/} keys(%{get_options()})) > 1);

	my ($name, $key, $default) = @_;
	# Legacy support -- previous versions used key/name order
	my $top = Genesis::Top->new('.');
	($name, $key) = ($key,$name) if !$top->has_env($name) && $top->has_env($key);

	if (get_options->{"defined"}) {
		command_usage(1, "Cannot specify default value with --defines option")
			if defined($default);
		$default = bless({},"NotFound"); # Impossible to have this value in sources.
	}
	my $env = $top->load_env($name);
	my $v;
	if (get_options->{entomb}) {
		bail(
			"Cannot use --entombed option with --exodus, --exodus-for or --deployed",
		) if scalar( grep {$_} (@{get_options()}{qw/exodus exodus-for deployed/}));
		$env->entombed_secrets_enabled(1);
	}

	if (get_options->{merged}) {
		bail(
			"Circular reference detected while trying to lookup merged manifest of $name"
		) if envset("GENESIS__LOOKUP_MERGED_MANIFEST");
		$ENV{GENESIS__LOOKUP_MERGED_MANIFEST}="1";
		$env->download_required_configs('manifest');
		$v = $env->manifest_lookup($key,$default);
	} elsif (get_options->{partial}) {
		bail(
			"Circular reference detected while trying to lookup merged manifest of $name"
		) if envset("GENESIS__LOOKUP_MERGED_MANIFEST");
		$ENV{GENESIS__LOOKUP_MERGED_MANIFEST}="1";
		$v = $env->partial_manifest_lookup($key,$default);
	} elsif (get_options->{deployed}) {
		$v = $env->last_deployed_lookup($key,$default);
	} elsif (get_options->{exodus}) {
		$v = $env->exodus_lookup($key,$default,get_options->{'exodus-for'})
	} elsif (get_options->{env}) {
		my %envvars = $env->get_environment_variables();
		$key =~ s/^\.//;
		if ($key) {
			$v = exists($envvars{$key}) ? $envvars{$key} :
			     exists($ENV{$key}) ? $ENV{$key} : $default;
		} else {
			$v = {%ENV, %envvars};
		}
	} else {
		$v = $env->lookup($key, $default);
	}

	if (get_options->{defined}) {
		exit(ref($v) eq "NotFound" ? 4 : 0);
	} elsif (defined($v)) {
		$v = encode_json($v) if ref($v);
		output {raw => 1}, $v;
	}
	exit 0;
}

sub yamls {
	option_defaults(
		"include-kit" => 1
	);
	command_usage(1) if @_ != 1;

	my $env = Genesis::Top
		->new('.')
		->load_env($_[0])
		->download_required_configs('blueprint');

	my $view = delete(get_options->{view});
	if ($view) {
		my $file;
		if ($view =~ /^(init|fin).yml$/) {
			# Check if the file is a dynamically generated genesis meta file:
			$file = $1 eq 'init' ? $env->_init_yaml_file : $env->_cap_yaml_file;
			output {raw => 1}, slurp($file);
			exit 0;
		}

		if (-f ($file = $env->path($view))) {
			# If the file exists under the environment's path, we will read it and output
			# it to the terminal.
			output {raw => 1}, slurp($file);
			exit 0;
		}

		my $start_time = gettimeofday();
		$env->notify({pending => 1}, 'building file list for the current kit features...');
		$env->kit_files;
		info('#G{done}%s', pretty_duration(gettimeofday() - $start_time));
		$env->notify({pending => 0}, 'done in %.2f seconds', gettimeofday() - $start_time);
		if (-f ($file = $env->kit->path($view))) {
			# If the file exists under the kit's path, we will read it and output
			# it to the terminal.
			output {raw => 1}, slurp($file);
			exit 0;
		}
		bail(
			"File '%s' not found in environment '%s' or kit '%s'.",
			$view, $env->name, $env->kit->id
		);
	}

	my $start_time = gettimeofday();
	$env->notify({pending => 1}, 'building file list for the current kit features...');
	my @kit_files = $env->kit_files;
	info('#G{done}%s', pretty_duration(gettimeofday() - $start_time));
	my @files = $env->format_yaml_files(%{get_options()}, kit_files => \@kit_files);
	output join("\n", @files)."\n";
	exit 0;
}

sub vault_paths {
	option_defaults(
		"references" => 0
	);
	command_usage(1) if @_ != 1;

	my $env = Genesis::Top
		->new('.')
		->load_env($_[0]);

	my $vault_paths = $env->vault_paths();
	my $msg = "";
	for my $path (sort keys %$vault_paths) {
		$msg .= "\n$path";
		$msg .= ":\n  - ".join("\n  - ", @{$vault_paths->{$path}})
			if (get_options->{references});
	}
	# TODO: Do we want to color code secret and exodus mounts and base paths?
	output "$msg\n";
}

sub deployments {
	my ($name) = @_;
	bail("The 'deployments' command is not yet fully implemented.");
}


sub kit_manual {
	my ($name) = @_;
	my $top = Genesis::Top->new('.');
	my @possible_kits = keys %{$top->local_kits};
	push @possible_kits, 'dev' if $top->has_dev_kit;

	bail(
		"No local kits found; you must specify the name of the kit to fetch"
	) unless scalar(@possible_kits);

	my $kit;
	$name ||= '';
	if ($name && $top->has_env($name)) {
		$top->reset_vault();
		# TODO: provide a vaultless way to read env kit without vault
		$kit = $top->load_env($name)->kit;
	} elsif ($name && $name eq 'dev') {
		$kit = $top->local_kit_version('dev')
	} else {
		my ($kit_name,$version) = $name =~ m/^([^\/]*)(?:\/(.*))?$/;
		if (!$version && semver($name)) {
			bail "More than one local kit found; please specify the kit to get the manual for"
				if scalar(@possible_kits) > 1;
			$version = $name;
			$version =~ s/^v//;
			$name = $possible_kits[0];
		}
		$kit = $top->local_kit_version($name, $version);
	}

	if(!(defined $kit)) {
		error "Kit not found: #C{%s}", $name;
		exit 1;
	}

	info "Displaying manual for kit #M{%s}...\n", $kit->id;

	my $man = $kit->path('MANUAL.md');
	if (-f $man) {
		my $man_contents = slurp($man);
		my $contents = get_options->{raw} ? $man_contents : render_markdown($man_contents);
		if (get_options->{pager}) {
			open my $pager, "|-", "less -R" or die "Can't open pager: $!";
			print $pager $contents;
			close $pager;
		} else {
			output $contents;
		}
		exit 0;
	}
	error "#M{%s} has no MANUAL.md", $kit->id;
	exit 1;
}

# List all environments known to Genesis under the deployment_roots.  This
# will display the following properties for each environment:
# - Root path
# - Environment name
# - Environment kit type and version
# - Last deployment date
#
# TODO: Add a flag for verbose mode that will display significantly more
# detailed information about each environment - TBD
# TODO: Add a flag for filtering environments by kit type
# TODO: Add a flag to mass check secrets in all environments
sub environments {

	pushd($ENV{GENESIS_ORIGINATING_DIR}) if $ENV{GENESIS_ORIGINATING_DIR};

	my ($filter_env, $filter_type,$search) = ();
	if ($ENV{GENESIS_PREFIX_TYPE} eq 'search') {
		$search = delete($ENV{GENESIS_PREFIX_SEARCH});
		$ENV{GENESIS_PREFIX_TYPE} = 'none';
		($filter_env, $filter_type) = $search =~ m{^@([^:]+)?(?::(.*))?$};
		$filter_env //= '*';
		$filter_type //= '*';
		$filter_env = "*$filter_env*" =~ s/\*\^/\^/r =~ s/\$\*/\$/r unless $filter_env eq '*';
		$filter_type = "*$filter_type*" =~ s/\*\^/\^/r =~ s/\$\*/\$/r unless $filter_type eq '*';
		$filter_env =~ s/([\*\?])/.$1/g;
		$filter_type =~ s/([\*\?])/.$1/g;
	}

	my $show_details = get_options->{details};
	my $group_by = get_options->{group_by_env} ? 'env' : 'kit';
	my $json = get_options->{json};
	my %data;
	#preemptively check that vault is available

	# Get the list of deployment roots
	my $root_map = Genesis::deployment_roots_map(
		['@current', $ENV{GENESIS_ORIGINATING_DIR}],
		['@parent', Cwd::abs_path(Genesis::expand_path($ENV{GENESIS_ORIGINATING_DIR}.'/..'))],
	);

	for my $label (@{$root_map->{labels}}) {
		# Find all deployments under each root
		my $root = $root_map->{roots}{$label};
		my @repos = grep {Genesis::Top->is_repo($_)} map {s{/.genesis/config$}{}; $_} glob("$root/*/.genesis/config");
		@repos = grep {basename($_) =~ qr($filter_type)} @repos if $filter_type;
		my %envs_by_deployments;
		my %deployments_by_name;
		if (scalar @repos) {
			$root =~ s{/?$}{/};
			if ($json) {
				info(
					"\nReading %s under deployment root #C{%s}",
					$group_by eq 'env' ? "environments" : "repositories",
					humanize_path($root, root_map => $root_map) =~ s{/?$}{/}r =~ s{>\e\[0m/$}{>\e\[0m}r
				);
			} else {
				info(
					"\nDeployment root #C{%s} contains the following %s:",
					humanize_path($root, root_map => $root_map) =~ s{/?$}{/}r =~ s{>\e\[0m/$}{>\e\[0m}r,
					$group_by eq 'env' ? "environments" : "repositories"
				);
			}
			info $ansi_hide_cursor if $group_by eq 'env';
			my ($i,$j) = (0,0);
			for my $repo (@repos) {
				__processing($i, scalar(@repos), $j) if ($show_details && ($group_by eq 'env' || $json));
				my $top = Genesis::Top->new($repo, silent_vault_check => 1, allow_no_vault => 1);
				my $repo_label = basename($top->path);
				my @envs = $top->envs; # Do the heavy lifting to determine which files are environments
				@envs = grep {$_->name =~ qr($filter_env)} @envs if $filter_env;
				__processing(++$i, scalar(@repos), $j) if ($show_details && ($group_by eq 'env' || $json));

				if (scalar(@envs)) {
					if ($group_by eq 'kit' && ! $json) {
						my $msg = "";
						$msg .= sprintf(
							"\n[[  >>#u{Environments under repo }#mu{%s}#u{:}",
							$repo_label
						) if $show_details;
						info $msg;
					}
					for my $env (@envs) {
						# Each environment is not initialized because otherwise we would
						# get errors if it contains any bad configuration (ie invalid kit)
						# We will try to load it and if it works, we're good -- otherwise
						# we'll need to get what we can, and report the errors.

						my $env_info = {
							name => $env->name,
							type => $env->type,
							path => $repo_label,
						};

						if ($show_details) {
							# TODO: Extract this into a method so that it can be called per
							# environment to get the details.
							my $exodus = $top->vault->status ne 'ok' ? {} : $env->exodus_lookup('.',{});
							$env_info->{bosh_env} = $exodus->{bosh} // $env->params->{bosh_env} // $env->name;
							my $loaded_env = eval {
								$top->load_env($env->name);
							};
							if (my $err_msg = $@) {
								# FIXME: Test for 'genesis <xxx> does not meet minimum version of <yyy>' and provide a more helpful message.
								my $kit_name = $env->params->{kit}{name} // 'unknown';
								my $kit_version = $env->params->{kit}{version} // 'unknown';
								my $kit_id = $kit_name . ($kit_name eq 'dev' ? '' : '/'.$kit_version);
								$env_info->{kit_version} = $kit_version;
								$env_info->{kit} = csprintf("%s #Ri{(not found)}", $kit_id);
								$env_info->{is_director} = 'unknown';
							} else {
								$env = $loaded_env;
								$env_info->{kit} = $env->kit->id;
								$env_info->{kit_version} = $env->kit->version;
								$env_info->{is_director} = $env->is_bosh_director ? JSON::PP::true : JSON::PP::false;
							};
							if ($exodus->{dated}) {
								$env_info->{last_deployed} = $exodus->{dated};
								$env_info->{last_deployed_by} = $exodus->{deployer};
								$env_info->{last_kit} = $exodus->{kit_name}.'/'.$exodus->{kit_version}.($exodus->{kit_is_dev} ? ' (dev)' : '');
							}
							$env_info->{vault_status} = $top->vault->status;
							if ($top->vault->status ne 'ok') {
								$env_info->{vault_status} = $top->vault->status;
								$env_info->{vault_url} = $top->config->get("secrets_provider.url");
							}

							if ($group_by eq 'env' || $json) {
								__processing($i, scalar(@repos), ++$j);
							} else {
								my $msg = sprintf(
									"[[    #c{%s}: >>#m{%s}",
									$env_info->{name},
									$env_info->{kit}
								);
								if ($env_info->{last_deployed}) {
									$msg .= sprintf(
										" - deployed #yi{%s}by #G{%s} %s",
										$env_info->{bosh_env} && $env_info->{bosh_env} ne $env_info->{name} ? "on BOSH $env_info->{bosh_env} " : '',
										$env_info->{last_deployed_by},
										strfuzzytime($env_info->{last_deployed}),
									);
									$msg .= " using kit #Y{$env_info->{last_kit}} #y\@{!}"
										if ($env_info->{last_kit} ne $env_info->{kit});
								} elsif ($env_info->{vault_status} ne 'ok') {
									my $status = $env_info->{vault_status};
									my $vault_url = $env_info->{vault_url};
									$msg .= " - #Ri{vault }#Mi{$vault_url}#Ri{ is $status:} #Y{exodus deployment data unavailable}";
								} else {
									$msg .= " - #r{never deployed}";
								}
								info $msg;
							}
						} elsif ($group_by eq 'kit' && ! $json) {
							my $msg = sprintf(
								"    #m{%s}/#c{%s}",
								$repo_label,
								$env_info->{name},
							);
							info $msg;
						}
						$envs_by_deployments{$repo_label}{$env_info->{name}} = $env_info;
						push @{$deployments_by_name{$env_info->{name}}}, $env_info;
					}
				}
			}

			info {pending => 1}, $ansi_show_cursor.$ansi_reset_line.$ansi_cursor_up
				if $show_details && ($group_by eq 'env' || $json);

			if ($group_by eq 'env' && ! $json) {
				if (scalar keys %deployments_by_name) {
					if ($show_details) {
						for my $env_name (sort keys %deployments_by_name) {
							info "\n[[  >>#u{Environment }#cu{%s}#u{:}", $env_name;
							for my $env_info (@{$deployments_by_name{$env_name}}) {
								my $type = ($env_info->{is_director} && $env_info->{is_director} ne 'unknown')
								? '#R{BOSH director}'
								: '#G{'.$env_info->{type}.' deployment}';
								my $msg = sprintf(
									"[[    $type#yi{%s}: >>#m{%s}",
									$env_info->{path} =~ /^$env_info->{type}(-deployments)?$/ ? '' : ' (in '.$env_info->{path}.')',
									$env_info->{kit}
								);
								if ($env_info->{last_deployed}) {
									$msg .= sprintf(
										" - deployed #yi{%s}by #G{%s} %s",
										$env_info->{bosh_env} && $env_info->{bosh_env} ne $env_info->{name} ? "on BOSH $env_info->{bosh_env} " : '',
										$env_info->{last_deployed_by},
										strfuzzytime($env_info->{last_deployed}),
									);
									$msg .= " using kit #Y{$env_info->{last_kit}} #y\@{!}"
										if ($env_info->{last_kit} ne $env_info->{kit});
								} elsif ($env_info->{vault_status} ne 'ok') {
									my $status = $env_info->{vault_status};
									my $vault_url = $env_info->{vault_url};
									$msg .= " - #Ri{vault }#Mi{$vault_url}#Ri{ is $status:} #Y{exodus deployment data unavailable}";
								} else {
									$msg .= " - #r{never deployed}";
								}
								info $msg;
							}
						}
					} else {
						for my $env_name (sort keys %deployments_by_name) {
							info "[[  #cu{%s:} >>%s\n", $env_name, join(', ', map {$_->{path} =~ s/-deployments$//r} @{$deployments_by_name{$env_name}})
						}
					}
				} else {
					info {pending => 1}, $ansi_reset_line.$ansi_cursor_up.$ansi_show_cursor;
					info "\n[[  #E{warning}>>#Ki{No environments found}" . ($search
						? sprintf("#Ki{ matching pattern }#Ci{%s}", $search)
						: '#Ki{.}'
					);
				}
			}
		} elsif ($label !~ /^@/) {
			warning("#Ki{No environments found under deployment root }#C{%s}", $root)
		}
		if ($group_by eq 'env') {
			next if $label =~ /^@/ && ! scalar(keys %deployments_by_name);
			$data{$label}{environments} = \%deployments_by_name;
		} else {
			next if $label =~ /^@/ && ! scalar(keys %envs_by_deployments);
			$data{$label}{deployments} = \%envs_by_deployments;
		}
	}
	if ($json) {
		output {raw => 1}, encode_json(\%data);
	}
	info $ansi_show_cursor;
}

sub __processing {
	my ($block, $total, $strobe, $strobe_size) = @_;
	$strobe_size ||= 7;
	my $percent = $block / $total;
	my $strobe_swing = $strobe_size - 1;
	my $strobe_pos = ($strobe_swing) - abs(($strobe % ($strobe_swing*2)) - $strobe_swing);
	my $strobe_char = $ENV{GENESIS_NO_UTF8} ? "*" : "\x{25FC}";
	info(
		{pending => 1, raw => 1},
		$ansi_reset_line."  Processing: %3d%%: [%s ]",
		$percent * 100,
		join('', map { csprintf("#%s{%s}", $_ == $strobe_pos ? "Y" : "K", $strobe_char)} 0..$strobe_swing)
	);

}


1;
