package Genesis::Commands::Env;

use strict;
use warnings;
use utf8;

use Genesis;
use Genesis::State;
use Genesis::Term;
use Genesis::Commands;
use Genesis::Top;
use Genesis::UI;
use Genesis::Env::NetworkClaims;
use Service::Vault;

sub create {

	# WARNING: Do not default create-env option to 0, because its absence is used
	# to determine whether the user has explicitly specified it or not, so
	# appropriate warnings can be issued, or actions taken.
	command_usage(1) if @_ != 1;
	warning(
		"The --no-secrets flag is deprecated, and no longer honored."
	) if has_option("secrets", 0);

	my $name = $_[0];
	bail(
		"No environment name specified!"
	) unless $name;
	$name =~ s/\.yml$//;

	my $top = Genesis::Top->new('.');
	my $vault_desc = get_options->{vault} || $top->get_ancestral_vault($name) || '';
	if ($vault_desc) {
		if ( $vault_desc eq "?") {
			$top->set_vault(interactive => 1);
		} else {
			my $vault = Service::Vault->get_vault_from_descriptor($vault_desc, get_options->{vault} ? '--vault option' : '');
			$top->set_vault(vault => $vault);
		}
		$vault_desc = $top->vault->build_descriptor()
	}

	# determine the kit to use (dev or compiled)
	my $kit_id=delete(get_options->{kit}) || '';
	my $kit = $top->local_kit_version($kit_id);
	if (!$kit) {
		bail(
			"Unable to determine the correct version of the Genesis Kit to use.  ".
			"Perhaps you should specify it with the `--kit` flag."
		) if (!$kit_id);

		bail(
			"No dev/ kit found in current working directory.  ".
			"Did you forget to `genesis decompile-kit` first?"
		) if ($kit_id eq 'dev');

		bail(
			"Kit '$kit_id' not found in compiled kit cache.  ".
			"Do you need to `genesis fetch-kit $kit_id`?"
		);
	}

	# Check if root ca path exists if specified
	if (get_options->{'root-ca-path'}) {
		bail(
			"No CA certificate found in vault under '#C{%s}'",
			get_options->{'root-ca-path'}
		) unless $top->vault->query('x509', 'validate', '-A', get_options->{'root-ca-path'});
	}

	# check version prereqs
	$kit->check_prereqs() or exit 86;

	# Pipeline-aware repos require new environments to be created on the
	# control branch so the topology is visible to pipeline tooling and
	# the environment branch can be cut from the right point.
	my $ci_configured = $top->ci_configured;
	my $git;
	if ($ci_configured) {
		require Service::Git;
		# track_branch so that prepare_branch's checkout to the env
		# branch is restored back to control before we return.
		$git = Service::Git->new('.', track_branch => 1);
		my $control = Genesis::Top::DEFAULT_CONTROL_BRANCH();
		my $branch = $git->current_branch;
		if (!defined($branch) || $branch ne $control) {
			bail(
				"Creating environments requires being on the #C{%s} branch, ".
				"but you are currently on #C{%s}.\n\n".
				"    git checkout %s\n",
				$control,
				$branch // '<detached HEAD>',
				$control
			);
		}

		# Refresh env branches so branch_exists checks and reconciliation
		# see teammate-created branches that aren't in the local clone yet.
		$top->fetch_pipeline_envs($git) unless get_options->{'no-fetch'};
	}

	# create the environment
	info("\nSetting up new environment #C{$name} based on kit %s ...", $kit->id);
	my $env = $top->create_env($name, $kit, %{get_options()});
	bail "Failed to create environment $name" unless $env;

	# Phase C: write pipeline metadata when CI provider is configured.
	# Runs interactively when in a controlling terminal; honours --prior-env,
	# --require-pr, and --manual flags for non-interactive (scripted) use.
	if ($ci_configured) {
		my $ci_type = $top->config->get('ci.provider.type') // 'unknown';
		info(
			"\n#G{Pipeline configuration} (ci provider: #C{%s})\n",
			$ci_type
		);

		my %cli_opts = %{get_options()};
		my $interactive = in_controlling_terminal;

		my $prior_env;
		if (exists $cli_opts{'prior-env'}) {
			$prior_env = $cli_opts{'prior-env'} // '';
			if (length($prior_env)) {
				my %known = map { $_->name => 1 } $top->envs();
				bail(
					"--prior-env '%s' does not match any environment in this repository.",
					$prior_env
				) unless $known{$prior_env};
			}
		} elsif ($interactive) {
			my @existing = grep { $_->name ne $name } $top->envs();
			if (@existing) {
				my @env_names = map { $_->name } @existing;
				my @choices = map {{ value => $_, label => $_ }} @env_names;
				push @choices, { separator => 1 };
				push @choices, {
					value => '',
					label => '#Yi{(none — pipeline entrypoint)}',
					summary => '(entrypoint)',
				};
				$prior_env = new_prompt_for_choice(
					header      => "Select prior environment (must succeed before this one):",
					choices     => \@choices,
					description => "environment",
				);
			} else {
				$prior_env = '';
				info("No other environments found — #C{%s} will be the pipeline entrypoint.", $name);
			}
		}

		# --- require_pr / manual ---
		my $require_pr;
		if (exists $cli_opts{'require-pr'}) {
			$require_pr = $cli_opts{'require-pr'} ? 1 : 0;
		} elsif ($interactive) {
			$require_pr = prompt_for_boolean(
				"Require a PR gate before this environment deploys? [y|n]",
				"n",
			);
		}

		my $manual;
		if (exists $cli_opts{manual}) {
			$manual = $cli_opts{manual} ? 1 : 0;
		} elsif ($interactive) {
			$manual = prompt_for_boolean(
				"Require a manual CI trigger before this environment deploys? [y|n]",
				"n",
			);
		}

		# Write pipeline: section when there is something to record.
		# Entrypoints (no prior_env) can still carry manual: true.
		if (length($prior_env // '') || $require_pr || $manual) {
			my $pipeline_yaml = "  pipeline:\n";
			$pipeline_yaml .= "    prior_env:    $prior_env\n" if length($prior_env // '');
			$pipeline_yaml .= "    require_pr:   true\n"       if $require_pr;
			$pipeline_yaml .= "    manual:       true\n"       if $manual;

			my $file     = $env->path($env->file);
			my $contents = slurp($file);

			if ($contents =~ /^\s+pipeline:/m) {
				info(
					"#Y{Note}: pipeline section already present in #C{%s}, skipping injection.",
					$env->file
				);
			} else {
				my $injected = ($contents =~ s/^((\s+)env:\s+\S[^\n]*\n)/$1$pipeline_yaml/m);
				if ($injected) {
					mkfile_or_fail($file, $contents);
					info("#G{Pipeline metadata written to} #C{%s}", $env->file);
				} else {
					warning(
						"Could not inject pipeline metadata into #C{%s}: ".
						"'env:' key not found at expected indentation. ".
						"Add the pipeline section manually:\n%s",
						$env->file, $pipeline_yaml
					);
				}
			}
		} else {
			info(
				"#C{%s} is a pipeline entrypoint with no gate flags — no pipeline section written.",
				$name
			);
		}
	}

	# Git operations: stage, commit, and create an environment branch.
	# Only when CI is configured and --no-commit is not set.
	my %cli_opts_git = %{get_options()};
	if ($ci_configured) {
		my $env_file = $env->file;
		$git->add($git->prefixed($env_file));

		if ($cli_opts_git{'no-commit'}) {
			info "Skipping commit (#C{--no-commit} set); #C{%s} remains staged.", $env_file;
		} else {
			my $message = $cli_opts_git{reason}
				|| "Add environment $name";
			$git->commit($message);

			my $sha = $git->sha('HEAD', short => 1);
			info "#G{Committed} #C{%s} -- %s", $sha // '<unknown>', $message;

			# Create the environment branch (if needed) and reconcile it
			# with the files this env depends on.  prepare_branch handles
			# both the fresh-create case (cut from current commit, prune
			# unrelated files) and the existing-branch case (add files
			# that this env adds without disturbing files owned by other
			# deployments sharing the same branch).
			my $branch_existed = $git->branch_exists($name);
			my ($added, $removed) = $env->prepare_branch;
			info "Environment branch #C{%s} %s (%d added, %d removed).",
				$name, $branch_existed ? 'reconciled' : 'created',
				scalar(@$added), scalar(@$removed);

			# For automated CI providers, the pipeline needs to be
			# rebuilt to include a job for the new environment branch.
			my $provider_type = $top->config->get('ci.provider.type') || 'manual';
			if ($provider_type ne 'manual') {
				if (in_controlling_terminal) {
					if (prompt_for_boolean(
						"Rebuild the CI pipeline to include #C{$name}? [y|n]", "y"
					)) {
						info "Rebuilding pipeline...";
						# TODO: call genesis repipe equivalent
						warning("Automated pipeline rebuild not yet implemented.  Run #C{genesis repipe} manually.");
					}
				} else {
					info "Run #C{genesis repipe} to update the pipeline with the new environment.";
				}
			}
		}
	}

	# Generate secrets.  Non-fatal — the env file, pipeline metadata, and
	# git branch are already in place; secrets can be retried later with
	# `genesis add-secrets` or will be generated at deploy time.
	# quiet_if_empty: this runs immediately after create_env, so the
	# source vault is expected to be empty for a brand-new env.
	my $secrets_ok = eval {
		$env->add_secrets(verbose => 1, import => 1, quiet_if_empty => 1)
	};
	if (!$secrets_ok) {
		my $err = $@ || '';
		$err =~ s/\s+$//;
		warning(
			"Secret generation incomplete for #C{%s}.%s\n".
			"Run #C{genesis add-secrets '%s'} to retry, or secrets will be\n".
			"generated at deploy time.",
			$name,
			$err ? "\n$err" : '',
			$name
		);
	}

	# let the user know
	if ($ci_configured && !$cli_opts_git{'no-commit'}) {
		info(
			"\nNew environment #C{%s} provisioned!\n\n".
			"To deploy, switch to the environment branch and run:\n\n".
			"  #C{git checkout '%s'}\n".
			"  #C{genesis deploy '%s'}\n",
			$env->{name}, $name, $env->{name}
		);
	} else {
		info(
			"\nNew environment #C{%s} provisioned!\n\n".
			"To deploy, run this:\n\n".
			"  #C{genesis deploy '%s'}\n",
			$env->{name}, $env->{name}
		);
	}
}

sub edit {
	option_defaults(
		editor => $ENV{EDITOR} || 'vim',
	);
	my ($name) = @_;
	my $top = Genesis::Top->new('.', no_vault => 1);
	# Can't use load_env because it validates, and we don't care about that here
	my $env = Genesis::Env->new(name => $name, top => $top);

	my $kit_name = $env->params->{kit}{name};
	my $kit_version = $env->params->{kit}{version};
	my $min_genesis_version = $env->params->{genesis}{min_version};
	if (get_options->{kit}) {
		($kit_name,$kit_version) = (get_options->{kit}) =~ m/^([^\/]*)(?:\/(.*))?$/;
	}

	$env->notify("Editing environment file #C{%s}", Cwd::abs_path($env->file) =~ s/^\Q$ENV{HOME}\E/~/r);
	my $kit_id = $kit_name eq 'dev' ? 'dev' : "$kit_name/$kit_version";
	info "[[  - >>based on kit #C{%s}", $kit_id;

	my $editor = get_options->{editor};
	my @cmd = split(/\s+/, $editor);
	$editor = $cmd[0];
	info "[[  - >>using editor #C{%s}%s", $editor, @cmd > 1 ? ", with option(s): ".join(', ', map {"#Y{'$_'}"} @cmd[1..$#cmd]) : '';

	my @warnings = ();
	my $manual_path = '';
	my $use_manual = defined(get_options->{manual}) ? (get_options->{manual} ? 1 : 0) : undef;
	my $prompt_for_kit = 0;

		# Validate Genesis version requirements
	my $version_check = $env->validate_genesis_version_requirements();
	push @warnings, @{$version_check->{warnings}} if @{$version_check->{warnings}};
	push @warnings, @{$version_check->{errors}} if @{$version_check->{errors}};

	bail(
		"Cannot specify #Y{--manual} unless the editor is vi-based (vi,vim,mvim,".
		"nvim,gvim), vscode (code) or emacs: ".
		"Pull request are welcome for other editors."
	) if $use_manual && $editor !~ m/^([gmn]?vim|vi|emacs|code)$/;
	if ($use_manual//1 && $editor =~ m/^([gmn]?vim|vi|emacs|code)$/) {
		if ($kit_name eq 'dev') {
			if (-d $top->path('dev')) {
				$manual_path = $top->path('dev/MANUAL.md');
				if (! -f $manual_path) {
					push @warnings, "Dev kit for environment #C{$name} has no MANUAL.md";
				}
			} else {
				push @warnings, "Dev kit for environment #C{$name} not found - no MANUAL.md available";
			}
		} else {
			my $kit = $top->local_kit_version($kit_name, $kit_version);
			if ($kit) {
				$manual_path = $kit->path('MANUAL.md');
				if (! -f $manual_path) {
					push @warnings, "Kit #C{$kit_name/$kit_version} has no MANUAL.md";
				}
			} else {
				push @warnings, "Kit #C{$kit_name/$kit_version} not found - no MANUAL.md available";
				$prompt_for_kit = 1;
			}
		}
	} else {
		if ($kit_name eq 'dev') {
			push @warnings, "Dev kit for environment #C{$name} not found!"
				unless (-d $top->path('dev'));
		} else {
			my $kit = $top->local_kit_version($kit_name, $kit_version);
			unless ($kit) {
				push @warnings, "Specified kit #C{$kit_name/$kit_version} not found!";
				$prompt_for_kit = 1;
			}
		}
	}
	info "[[  - >>showing kit manual" if $manual_path;

	my @files = ();
	my $show_ancestors = defined(get_options->{ancestors}) ? (get_options->{ancestors} ? 1 : 0) : undef;
	bail(
		"Cannot specify #Y{--include-all-ancestors} unless the editor is vi-based ".
		"(vi,vim,mvim,nvim,gvim) or vscode (code): Pull request are welcome for other editors."
	) if $show_ancestors && $editor !~ m/^([gmn]?vim|vi|code)$/;

	if ($show_ancestors//1 && $editor =~ m/^([gmn]?vim|vi|code)$/) {
		my @ancestors = reverse $env->potential_environment_files;
		shift @ancestors; # remove the current environment file
		@ancestors = grep {-f $_} @ancestors unless $show_ancestors;
		push @files, map {Cwd::abs_path($_)} @ancestors;
		info(
			"[[  - >>including %s hierarchial ancestor files",
			$show_ancestors ? "all" : 'existing'
		) if @ancestors;
	}

	my $replace_kit = undef;
	if (@warnings) {
		warning(
			"\nThe following issues were found with the environment:%s",
			join("", map {"\n[[- >>$_"} @warnings)
		);
		if ($prompt_for_kit && $editor =~ m/^([gmn]?vim|vi)$/) {
			my $local_kits = $top->local_kits;
			my @kit_names = keys %$local_kits;
			my @kit_labels = ();
			my @kits = ();
			for my $kit (@kit_names) {
				my @versions = keys %{$local_kits->{$kit}};
				if (@versions) {
					push @kit_labels, csprintf("---#C{%s-genesis-kit:}---", $kit);
					for my $version (reverse sort by_semver @versions) {
						push @kits, [$kit, $version];
						push @kit_labels, [csprintf("#%s{%s}", ($version =~ /[\.-]rc[\.-]?(\d+)$/) ? 'Y' : 'G',$version), "$kit/$version"];
					}
				}
			}
			my $selection = prompt_for_choice(
				"Would you like to select a local kit and continue?",
				[@kits, 'download','current', 'abort'],
				$kits[0],
				[@kit_labels, '---', csprintf('#g{Download} #C{%s/%s}',$kit_name, $kit_version), csprintf('#y{Keep as-is}'), csprintf('#r{Quit}')]
			) or bail("Aborted by user");

			if ($selection eq 'download') {
				my $kitsig = "$kit_name/$kit_version";
				$env->notify(
					"Attempting to retrieve Genesis kit #M{$kit_name (v$kit_version)}..."
				);
				my ($name,$version,$target) = $top->download_kit($kitsig)
					or bail "Failed to download Genesis Kit #C{$kitsig}";

				$env->notify(
					"Downloaded version #C{$version} of the #C{$name} kit\n",
				);
				$selection = [$name, $version];
				$replace_kit = 0;
			}

			bail("Aborted by user") if $selection eq 'abort';
			if ($selection ne 'current') {
				$replace_kit //= 1;
				($kit_name, $kit_version) = @$selection;
				$manual_path = $top->local_kit_version($kit_name, $kit_version)->path('MANUAL.md');
				$manual_path = '' unless -f $manual_path;
			}
		} else {
			prompt_for_boolean(
				"Continue? [y|n]",
				1
			) or bail("Aborted by user");
		}
	}

	@files = ($top->path($env->file), $manual_path, @files);

	if ($editor =~ m/vim?$/) {
		push @cmd, '-c';
		my $build_opts = 'edit '.shift(@files);
		if ($replace_kit) {
			$build_opts .= ' | %s/\(kit:\(\n  .*$\)*\n  name:\s*\).*/\1'.$kit_name.'/';
			$build_opts .= ' | %s/\(kit:\(\n  .*$\)*\n  version\s*\).*/\1'.$kit_version.'/';
		}
		if (my $manual = shift(@files)) {
			$build_opts .= ' | vsplit '. $manual;
			$build_opts .= ' | wincmd w';
		}
		$build_opts .= ' | split '. $_ for (@files);
		$build_opts .= ' | '.scalar(@files).' wincmd k' if (@files);

		push @cmd, $build_opts;
	} elsif ($editor eq 'code') {
		info(
			"\n[[#Y{Note:} >>VSCode opens files in separate tabs -- drag and drop ".
			"them to split the view if desired."
		) if grep {$_} @files > 1;
		push @cmd, '--wait', '--add','.', grep {$_} @files;
	} elsif ($editor eq 'emacs') {
		push @cmd, '-nw', shift(@files);
		push @cmd, '-f', 'split-window-horizontally', shift(@files), '-f', 'other-window'
			if @files;
	} else {
		push @cmd, shift(@files);
	}

	my ($out, $rc, $err) = run(
		{interactive => 1},
		@cmd
	);

	if ($rc) {
		bail(
			"Failed to edit environment %s",
			$name,
		);
	}
	$env->notify(success => "Environment $name edit completed.\n");
}

sub check {
	command_usage(1) if @_ != 1;

	option_defaults(
		manifest => 1,
	);
	my $env = Genesis::Top->new('.')->load_env($_[0]);
	$env->with_vault() if get_options->{secrets} || get_options->{manifest};

	if (has_option('no-config',1)) {
		$ENV{GENESIS_CONFIG_NO_CHECK}=1;
		bail(
			"Cannot specify --no-config without also specifying --no-manifest"
		) if get_options->{manifest};
	} else {
		my @hooks = qw/check/;
		push(@hooks, 'manifest', 'blueprint') if has_option('manifest',1);
		$env->download_required_configs(@hooks);
	}

	get_options->{$_} //= 0 for qw/secrets stemcells cpis/;

	my $ok = $env->check(
		(map {("check_$_" => has_option($_,1))} qw/manifest secrets stemcells cpis/)
	);
	if ($ok) {
		info "\n[#M{%s}] #G{All Checks Succeeded}", $env->name;
		exit 0;
	} else {
		bail "\n[#M{%s}] #R{PREFLIGHT FAILED}", $env->name;
	}
}

sub list_secrets {
	command_usage(1) if @_ < 1;
	my ($name, @filters) = @_;
	my $env = Genesis::Top
		->new(".")
		->load_env($name)
		->with_vault();

	# TODO: Should we support the missing|invalid|problematic|unused options here?
	my %options = %{get_options()};
	my $plan = $env->secrets_plan(no_validation=>1)->filter(@filters)->autoload;

	my $results = [];
	for my $secret ($plan->secrets) {
		my $path = $options{relative} ? $secret->path :$secret->full_path;
		if ($options{json}) {
			my $json = undef;
			if ($options{verbose}) {
				$json = {
					path => $path,
					type => $secret->type,
					description => scalar($secret->describe),
					source => $secret->source,
				};
				$json->{value} = $secret->value if $options{verbose} > 1;
				$json->{feature} = $secret->feature if $secret->from_kit;
				$json->{var_name} = $secret->var_name if $secret->from_manifest;
			} else {
				$json = $path;
			}
			push @$results, $json;
		} else {
			my $value = $path;
			if ($options{verbose}) {
				$value .= " #C{(".$secret->describe.")}";
				my $source = $secret->source;
				my $descriminator = $source eq 'kit' ? 'feature' : 'var_name';
				my $desc = $secret->$descriminator;
				$value .= " from #m{$source} (#Mi{$descriminator: $desc})";
			}
			push @$results, csprintf($value);
		}
	}
	if ($options{json}) {
		info '';
		my %json_key_order = (
			path => 1,
			type => 2,
			description => 2,
			source => 3,
			feature => 4,
			var_name => 5,
		);

		require "JSON/PP.pm";
		print(
			JSON::PP->new->pretty
			->sort_by(sub {
				my ($a, $b) = ($JSON::PP::a, $JSON::PP::b);
				return ($json_key_order{$a}//999) <=> ($json_key_order{$b}//999) || $a cmp $b;
			})
			->encode($results)
		);
	} else {
		info "\nSecrets in #C{$name}:\n";
		output(join("\n", @$results));
	}

	$env->notify(success => "found ".scalar($plan->secrets)." secrets.\n");

}
sub check_secrets {
	command_usage(1) if @_ < 1;
	my ($name,@paths) = @_;

	my $level = delete(get_options->{exists});
	my ($action_desc, $validation_level) = $level
		? (checked => 0)
		: (validated => 1);

	my $env = Genesis::Top
		->new(".")
		->load_env($name)
		->with_vault();

	my ($results, $msg) = $env->check_secrets(
		paths=>\@paths,
		%{get_options()}
		, validate => $validation_level
	);

	if ($results->{empty}) {
		if ($msg) {
			$env->notify($msg."\n")
		} else {
			$env->notify(success => "doesn't have any secrets to be $action_desc.\n");
		}
	}

	if ($results->{error}) {
		$env->notify(fatal => "- invalid secrets detected.\n");
		exit 1
	}
	if ($results->{missing}) {
		$env->notify(fatal => "- missing secrets detected.\n");
		exit 1
	}
	if ($results->{warn}) {
		$env->notify(warning => "- all secrets valid, but warnings were encountered.\n");
		exit 0;
	}
	$env->notify(success => "$action_desc secrets successfully!\n");
	exit 0
}

sub add_secrets {
	command_usage(1) if @_ < 1;
	my ($name,@paths) = @_;
	my $env = Genesis::Top
		->new(".")
		->load_env($name)
		->with_vault();

	my ($results) = $env->add_secrets(paths=>\@paths,%{get_options()});
	if ($results->{error}) {
		$env->notify(fatal => "- errors encountered while adding secrets");
		exit 1
	}
	my $msg;
	my @warnings = ();
	push(@warnings, 'warnings were encountered') if $results->{warn};
	push(@warnings, 'not all secrets could be imported from CredHub, so were generated instead')
		if $results->{generated};

	if ($results->{ok} || $results->{generated}) {
		$msg = "- all ".($results->{skipped} ? 'missing ':'')."secrets were added";
	} elsif ($results->{imported}) {
		$msg = "- all ".($results->{skipped} ? 'missing ':'')."secrets were imported";
	} elsif ($results->{skipped}) {
		$env->notify(success => "- all secrets already present, nothing to do!\n");
		exit 0;
	} else {
		$env->notify(warning => "- no secrets were added.\n");
		exit 0;
	}

	if (@warnings) {
		$env->notify(warning => "$msg, but ".sentence_join(@warnings)."\n");
	} else {
		$env->notify(success => "$msg successfully!\n");
	}
	exit 0;
}

sub rotate_secrets {
	command_usage(1) if @_ < 1;
	my ($name, @paths) = @_;
	bail(
		"--force option no longer valid. See `genesis rotate-secrets -h` for more details"
	) if get_options->{force};

	get_options->{invalid} = 2 if delete(get_options->{problematic});
	my $env = Genesis::Top
		->new(".")
		->load_env($name)
		->with_vault();

	my ($results, $msg) = $env->rotate_secrets(paths => \@paths,%{get_options()});

	bail($msg||"User aborted secrets rotation") if $results->{abort};

	if ($results->{empty}) {
		$env->notify($msg);
		exit 0
	}
	if ($results->{error}) {
		$env->notify(fatal => "- errors encountered while rotating secrets");
		exit 1;
	}
	my @warnings = ();
	push(@warnings, 'some rotations were skipped') if $results->{skipped};
	push(@warnings, 'warnings were encountered') if $results->{warn};
	if ($results->{skipped} && !$results->{ok} && !$results->{warn}) {
		$env->notify(warning => "no secrets were rotated!\n");
	} elsif (@warnings) {
		$env->notify(warning => "$msg, but ".sentence_join(@warnings)."\n");
	} else {
		my $selective = @paths ? 'specified' : 'all';
		$env->notify(success => "$selective $msg successfully!\n");
	}
	exit 0;
}

sub remove_secrets {
	command_usage(1, 'Missing environment name or file') if @_ < 1;
	my %options = %{get_options()};
	$options{invalid} //= 0;
	my ($name, @paths) = @_;
	if ( $options{all}) {
		bail(
			"Cannot specify secret paths when using the --all option."
		) if @paths;
		bail(
			"Cannot use --invalid, --problematic, --interactive or --unused at the same time as the --all option."
		) if $options{problematic} || $options{invalid} || $options{interactive} || $options{unused};
	}
	if ($options{unused}) {
		bail(
			"Cannot specify secret paths or filters when using the --unused option."
		) if @paths;
		bail(
			"Cannot use --invalid or --problematic at the same time as the --unused option."
		) if $options{problematic} || $options{invalid};
	}

	$options{invalid} = 2 if delete($options{problematic});
	$options{invalid} = 3 if delete($options{unused});
	my $env = Genesis::Top
		->new(".")
		->load_env($name)
		->with_vault();

	my ($results, $msg) = $env->remove_secrets(paths => \@paths,%options);
	if ($results->{abort}) {
		if ($options{invalid} == 3 || $options{interactive}) { # -- unused or interactive can be partially aborted
			bail($msg||"User aborted secrets removal") unless $results->{ok} || $results->{warn} || $results->{error} || $results->{missing};
		} else {
			bail($msg||"User aborted secrets removal");
		}
	}

	if ($results->{empty} && keys %$results == 1) {
		$env->notify($msg||"No secrets were found to remove");
		exit 0
	}
	if ($results->{error}) {
		$env->notify(fatal => "- errors encountered while removing secrets");
		exit 1;
	}

	my @warnings = ();
	$msg ||= "unused secrets removed" if $options{invalid} == 3;
	push(@warnings, 'some removals were skipped') if $results->{skipped};
	push(@warnings, 'warnings were encountered') if $results->{warn};
	if ($results->{missing} && !$results->{skipped} && !$results->{ok} && !$results->{warn}) {
		$env->notify(success => "no secrets to remove.\n");
	} elsif (($results->{skipped} || $results->{missing}) && !$results->{ok} && !$results->{warn}) {
		$env->notify(warning => "no secrets were removed!\n");
	} elsif (@warnings) {
		$env->notify(warning => "$msg, but ".sentence_join(@warnings)."\n");
	} else {
		my $selective = @paths ? 'specified' : 'all';
		$env->notify(success => "$selective $msg successfully!\n");
	}
	exit 0;
}

sub manifest {
	command_usage(1) if @_ != 1;

	my ($type,$subset) = @{get_options()}{qw(type subset)};

	my $env = Genesis::Top
		->new('.')
		->load_env($_[0])
		->with_vault();

	my %valid_types = $env->manifest_provider->known_types;
	my %valid_subsets = $env->manifest_provider->known_subsets;
	if (get_options->{list}) {
		# Calculate max width for consistent alignment
		my $max_len = ((sort {$b <=> $a} map {length($_ =~ s/_/-/gr)} (keys %valid_types, keys %valid_subsets))[0] || 0) + 2;

		# Format types with descriptions
		my @type_lines = map {
			my $name = $_ =~ s/_/-/gr . ':';
			sprintf("[[  #c{%-*s}>>%s", $max_len, $name, $valid_types{$_})
		} sort keys %valid_types;

		# Format subsets with descriptions
		my @subset_lines = map {
			my $name = $_ =~ s/_/-/gr . ':';
			sprintf("[[  #c{%-*s}>>%s", $max_len, $name, $valid_subsets{$_})
		} sort keys %valid_subsets;

		output(
			"Valid manifest types (defaults to default deployment manifest):\n".
			join("\n", @type_lines).
			"\n\n".
			"Valid subsets (defaults to full contents):\n".
			join("\n", @subset_lines)
		);
		return 1;
	}

	bail(
		"Unknown manifest type %s - use --list option to show valid types",
		$type
	) if ($type && ! in_array($type =~ s/-/_/gr, keys %valid_types));

	bail(
		"Unknown manifest subset %s - use --list option to show valid subsets",
		$subset
	) if ($subset && ! in_array($subset =~ s/-/_/gr, keys %valid_subsets));

	if ($env->use_create_env && scalar(@{$env->configs})) {
		warning(
			"\nThe provided configs will be ignored, as create-env environments do ".
			"not use them:\n[[- >>".join(
				"\n[[- >>", map {"#C{$_}"} (@{$env->configs})
			)
		);
	}

	$type //= 'deployment';
	$type =~ s/-/_/g if $type;
	$subset =~ s/-/_/g if $subset;

	bail(
		"Manifest type %s is not supported by this environment",
		$type
	) unless $env->manifest_provider->can($type);

	my $manifest = $env
		->download_required_configs('blueprint', 'manifest')
		->manifest_provider->$type(notify=>1,subset=>$subset);
	my $content = slurp($manifest->file) =~ s/\s*\z//msr;
	print STDERR "\n";
	output {raw => 1}, $content;
}

# _derive_deploy_reason - build a default --reason from the pipeline commit range {{{
#
# Reads the last successful deployment's `git.commit` from exodus and
# compares it to the env branch HEAD.  If equal, this is a redeploy —
# returns a "Redeploy of <sha>" stub.  If different, walks commits in
# the `$last_deployed..$branch_head` range on the env branch and
# delegates to _format_pipeline_reason to produce the audit string.
#
# Returns undef if vault is unreachable (caller falls back to the
# operator-provided or default reason).
sub _derive_deploy_reason {
	my ($env, $git) = @_;

	my $env_v = eval { $env->with_vault };
	return undef unless $env_v;

	my $dep = eval { $env_v->deployments->latest_successful };
	my $last_deployed = $dep ? ($dep->lookup('git.commit') || '') : '';

	my $branch_head = $git->sha($env->name);
	return undef unless $branch_head;

	if ($last_deployed && $last_deployed eq $branch_head) {
		return sprintf("Redeploy of %s", $git->sha($branch_head, short => 1));
	}

	my $range = $last_deployed ? "$last_deployed..$branch_head" : $branch_head;

	# Scope the history to commits that actually touched files this env
	# depends on.  Without this filter, multi-deploy repos (e.g. bosh and
	# vault sharing one env branch) would surface propagation markers
	# from sibling deployments whose subjects are irrelevant to the deploy
	# being reasoned about.
	my @dep_files = $env->propagation_files;
	my @lines = $git->log_subjects(
		$range,
		limit => 50,
		paths => \@dep_files,
	);

	return _format_pipeline_reason(
		\@lines,
		sub { $git->sha($_[0], short => 1) },
		sub {
			my ($subject) = $git->log_subjects($_[0], limit => 1, format => '%s');
			$subject //= '';
			$subject =~ s/\s+$//;
			return $subject;
		},
	);
}

# }}}
# _format_pipeline_reason - pure formatter for the derived deploy reason {{{
#
# Inputs:
#   \@log_lines   — output of `git log --format='%H %s'` for the range
#   $short_sha    — callback: sha => abbreviated-sha (kept for API
#                   compatibility; may be unused)
#   $subject_of   — callback: sha => commit subject line
#
# Extracts `[pipeline] control@<sha>` markers from the env-branch log
# lines, flips them into oldest-first order, and produces a reason
# string made up of the control commit subjects (SHAs are omitted
# because exodus already records `git.control_commit`).  For a single
# commit the subject is returned verbatim; for multiple commits a
# bulleted list is produced.  Returns undef if no markers are found.
sub _format_pipeline_reason {
	my ($log_lines, $short_sha, $subject_of) = @_;

	my @controls;
	for my $line (@{$log_lines || []}) {
		next unless $line =~ /\[pipeline\] control\@([0-9a-f]+)/;
		push @controls, $1;
	}
	return undef unless @controls;

	@controls = reverse @controls;  # log is newest-first; reason reads oldest-first

	my @subjects = map { $subject_of->($_) } @controls;

	return $subjects[0] if @subjects == 1;

	return join("\n",
		sprintf("%d commits:", scalar @subjects),
		map { "  - $_" } @subjects,
	);
}

# }}}
sub deploy {
	option_defaults(
		redact   => ! -t STDOUT,
		reactions => 1,
	);
	command_usage(1) if @_ < 1 || @_ > 2;
	my ($env_name, $reason) = @_;

	my %options = %{get_options()};
	my @invalid_create_env_opts = grep {$options{$_}} (qw/fix fix-stemcells/);

	# --pull: explicitly requested, or implied by -F/--fix-checks unless --no-pull.
	# Remove 'pull' from %options so it is not forwarded to $env->deploy().
	my $do_pull;
	if (exists $options{pull}) {
		$do_pull = delete($options{pull}) ? 1 : 0;
	} elsif ($options{'fix-checks'}) {
		$do_pull = 1;
	} else {
		$do_pull = 0;
	}

	# --no-fetch: skip the pre-deploy env-branch refresh (offline use).
	# Remove from %options so it is not forwarded to $env->deploy().
	my $no_fetch = delete($options{'no-fetch'}) ? 1 : 0;

	# When CI is configured, switch to the environment's branch and
	# pull from remote BEFORE loading the env -- otherwise all the
	# preflight work (cloud-config download, manifest viability,
	# secret checks, stemcell checks) would run against whatever
	# branch the operator happened to be on.  The post-deploy git
	# work (commit + push manifest artifacts, auto-cascade) runs in
	# Genesis::Env::_post_deploy after the deploy itself.
	my $top = Genesis::Top->new('.');
	my $pipeline_git;
	my $pipeline_branch;
	if ($top->ci_configured) {
		require Service::Git;
		$pipeline_git = Service::Git->new('.', track_branch => 1);
		(my $branch_name = $env_name) =~ s{^.*/}{};
		$branch_name =~ s/\.ya?ml$//;
		$pipeline_branch = $branch_name;

		# Fetch all pipeline env branches in one round-trip before any
		# branch-state reads (branch_exists, checkout, pull_ff_only).
		# This ensures teammate-created branches and propagation commits
		# are visible before we act on them.
		$top->fetch_pipeline_envs($pipeline_git) unless $no_fetch;

		my $current = $pipeline_git->current_branch // '';
		if ($current ne $branch_name) {
			bail(
				"Working tree has uncommitted changes.  Commit or stash them\n".
				"before deploying."
			) unless $pipeline_git->is_clean;
			bail(
				"Environment branch #C{%s} does not exist.\n".
				"Create it with #C{genesis new %s} on the control branch.",
				$branch_name, $branch_name
			) unless $pipeline_git->branch_exists($branch_name);
			info "\nSwitching to environment branch #C{%s}...", $branch_name;
			$pipeline_git->checkout($branch_name);
			# Reload Top now that the working tree is on the env branch
			$top = Genesis::Top->new('.');
		}

		if (my $remote = $pipeline_git->default_remote) {
			info "Pulling latest #C{%s} from #C{%s}...", $branch_name, $remote;
			$pipeline_git->pull_ff_only($branch_name, $remote);
		}
	}

	$options{'disable-reactions'} = ! delete($options{reactions});
	my $env = $top->load_env($env_name)->with_vault()->with_bosh();

	# CI-only checks for pipeline-managed environments.
	if ($top->ci_configured) {
		my $prior = eval { $env->lookup('genesis.pipeline.prior_env', '') } // '';
		if ($prior) {
			# Hard invariant (no --yes override): the pipeline predecessor must
			# have been successfully deployed at least once.  Without this guard
			# a deploy could proceed past an env that skipped its predecessor,
			# leaving the pipeline DAG in an inconsistent state.
			_assert_prior_env_deployed($env, $prior);

			# Warn when manually deploying outside of a pipeline job.
			# GENESIS_HONOR_ENV is set by ci-pipeline-deploy; its absence
			# means we are running at a terminal, not inside Concourse.
			# Skip the warning when the configured provider is 'manual' --
			# in that mode the operator IS the pipeline, so the warning
			# is just noise.
			my $provider_type = $top->config->get('ci.provider.type') || '';
			if ($provider_type ne 'manual' && !$ENV{GENESIS_HONOR_ENV}) {
				warning(
					"\nManually deploying #C{%s}, which is managed by a Genesis pipeline.\n".
					"The pipeline is the preferred deploy path — manual deploys bypass\n".
					"change-detection, propagation gating, and approval gates.\n\n".
					"The deployment will still record a #C{git.control_commit} so that\n".
					"cascade propagation continues to work after this deploy.",
					$env->name
				);
				unless ($options{yes} || !in_controlling_terminal()) {
					prompt_for_boolean(
						"Continue with manual deploy? [y|n]", 0
					) || bail("Aborted.");
				}
			}
		}
	}

	# --pull: pull propagated files from the prior env (or control HEAD for
	# entry points) onto the env branch before deploying.  No-op when the
	# env branch is already current or when CI is not configured.
	if ($do_pull && $top->ci_configured && $pipeline_git) {
		my $prior = eval { $env->lookup('genesis.pipeline.prior_env', '') } // '';

		# Upgrade to track_branch so DESTROY returns us to the branch we were
		# on before the pull (e.g. control), not to the env branch.
		$pipeline_git = Service::Git->new('.', track_branch => 1);

		bail(
			"Environment branch #C{%s} does not exist.\n".
			"Create it with #C{genesis new %s} on the control branch.",
			$pipeline_branch, $pipeline_branch
		) unless $pipeline_git->branch_exists($pipeline_branch);

		# Switch to the env branch.  _pre_deploy will find us already there.
		if (($pipeline_git->current_branch // '') ne $pipeline_branch) {
			bail(
				"Working tree has uncommitted changes.  Commit or stash them\n".
				"before deploying with --pull."
			) unless $pipeline_git->is_clean;
			$pipeline_git->checkout($pipeline_branch);
		}

		my $source_sha = _get_source_sha_for_pull($env, $prior, $pipeline_git);
		_apply_pull_propagation($env, $pipeline_branch, $source_sha, $pipeline_git)
			if $source_sha;
	}

	my $deployment_files = $env->deployment_cache_path_lookup('existing');
	if (scalar(keys %$deployment_files)) {
		# TODO: Support the --resume option here, to resume a previous deployment.
		#       This will have to use a step file that indicates the last step
		#       that was completed, and then resume from there, if possible.
		if ($options{clear}) {
			$env->deployment_cache_clear;
		} else {
			my $cache_dir = $env->deployment_cache_dir;
			my $file_list = join("\n", map {
				sprintf("[[  - >>%s", basename($_))
			} sort values %$deployment_files);
			warning(
				"\nThere are cached deployment files in #C{%s} from the previous failed or interrupted deployment:\n%s%s",
				$cache_dir, $file_list,
				$deployment_files->{state}
					? "\n\n[[#Yr{IMPORTANT:} >>The cached files contain a state file.  ".
					"Genesis already kept the state of the failed attempt and will ".
					"deploy from it, so clearing the cache loses nothing on its own.  ".
					"This copy matters when the attempt was interrupted before Genesis ".
					"could keep it, or when the state has to be edited by hand.  Copy ".
					"it somewhere safe first, then pass it back with the ".
					"--STATE-FILE-PATH option."
					: ""
			);
			if (!$options{yes} && in_controlling_terminal()) {
				# Ask the user if they want to clear the cache directory
				prompt_for_boolean(
					"Do you want to clear the cache directory and start a new deployment? [y|n]",
					0
				) || bail("Aborted by user");

				$env->notify("Clearing deployment cache files...");
				$env->deployment_cache_clear;
			} else {
				bail(
					"\nCowardly refusing to clear deployment cache files in #C{%s} ".
					"without user confirmation.\n\n".
					"Use the #Y{--clear} option to clear them, or run the command ".
					"without the #Y{--yes} option in an interactive terminal to be ".
					"prompted.",
					$cache_dir
				);
			}
		}
	}

	# Derive a default reason from the pipeline commit range when the
	# env is on a pipeline branch and no --reason was supplied.
	if (!defined($reason) && $pipeline_git && $pipeline_branch) {
		if (my $derived = _derive_deploy_reason($env, $pipeline_git)) {
			$reason = $derived;
			$env->notify("derived deploy reason from pipeline history:\n%s", $reason);
		}
	}

	# Check if the user is compelled to provide a reason for the deployment
	if (my $min_size = $env->deployment_change_reason_required_size_policy) {
		# TODO: Maybe prompt for a reason if it wasn't provided
		bail(
			"Cannot deploy environment #C{%s} without a reason (minimum length is %d characters).\n".
			"Please provide a reason after any options on the command line",
			$env->name, $min_size
		) unless length($reason//'') >= $min_size;
	}
	$reason //= 'unknown'; # if not provided or required, use 'unknown' as the reason

	if (scalar(grep {$_} ($options{fix}, $options{recreate}, $options{'dry-run'})) > 1) {
		command_usage(1,"Can only specify one of --dry-run, --fix or --recreate");
	}
	my $noprompt = $options{yes} // 0;
	$ENV{BOSH_NON_INTERACTIVE} = 'true' if $noprompt;
	my $dryrun = $options{'dry-run'} // 0;

	bail(
		"The following options cannot be specified for #M{create-env}: %s",
		join(", ", @invalid_create_env_opts)
	) if $env->use_create_env && @invalid_create_env_opts;

	if (delete $options{'fix-checks'}) {
		$options{'fix-stemcells'} = 1 unless $env->use_create_env;
		$options{'fix-secrets'} = 1;
	}

	info "\nPreparing to deploy #C{%s}:\n  - based on kit #c{%s}\n  - using Genesis #c{%s}%s",
		$env->name, $env->kit->id, $Genesis::VERSION,
		_format_deploy_feature_opt_in($env);
	if ($pipeline_branch) {
		info "  - from branch #c{%s}", $pipeline_branch;
	}
	if ($env->use_create_env) {
		info "  - as a #M{create-env} deployment.";
	} else {
		info "  - to '#M{%s}' BOSH director at #c{%s}.", $env->bosh->{alias}, $env->bosh->{url};
	}
	# Specify the environment iaas and scale
	my $scale = $env->scale;
	if ($scale) {
		info("  - to a #Y{%s}-scale #G{%s} IaaS target", $scale, $env->iaas);
	} else {
		info("  - targeting #G{%s} IaaS", $env->iaas);
	}
	info "";

	# Check if the kit supports the environment's IaaS
	if (my $supported_iaas = $env->kit->metadata('supports')) {
		bail(
			"Genesis kit #C{%s} does not support the IaaS type #C{%s} - ".
			"you will need to use a different kit/version.",
			$env->kit->id, $env->iaas
		) unless in_array($env->iaas, @$supported_iaas);
	}

	my ($cloud_config, $network_map, $cpi_config, $credhub_secrets, $cpi_err) = ();
	my $ok = 1;
	if (! $env->use_create_env) {
		# TODO: refactor to clean this up a bit

		# CPI config management is an OCFP concern.  Non-OCFP envs have
		# CPI config managed externally (typically via the director's
		# cloud-config), so skip the check/fix and the default-CPI notify.
		if ($env->is_ocfp) {
			if ($env->cpi_enabled) {
				if ($env->has_hook('cpi-config')) {
					$env->notify("checking CPI config for #C{%s} deployment...", $env->name); #FIXME: move this into the _check_cpi_config method
					my $check_result = $env->_check_cpi_config();

					bail(
						"Cannot provide the required CPI config: %s",
						$check_result->{msg}
					) if $check_result->{fatal}; # Should we just set a flag instead, and skip to next check?

					if ($check_result->{state} ne 'ok') {
						if ($dryrun) {
							dryrun(
								"CPI config check failed: %s\n\nThis would be fixed if not in dry-run mode.",
								$check_result->{msg}
							);
						} else {
							# Just going to force the fix for now
							my $fix_result = $env->_fix_cpi_config(
								$check_result->{state},
								$check_result->{fix_data},
								noprompt => 1,
							);
							bail(
								"Could not update required CPI config: %s",
								$fix_result->{msg}
							) unless $fix_result->{result} eq 'ok';
						}
					}
				}
			} else {
				# Use the cpi config provided by the director (via exodus data)
				$env->notify(
					"Using %s CPI config from #M{%s} BOSH director...",
					scalar $env->director_exodus_lookup('default_cpi_config','default'),
					$env->bosh->{alias}
				);
			}
		}

		if ($env->can_build_cloud_configs) {
			# Refactor this to use _check_cloud_config and _fix_cloud_config like the cpi stuff above
			if ($env->has_hook('cloud-config')) {
				$env->notify("checking cloud configs for #C{%s} deployment...", $env->name);

				# The cloud config synthesis reads the network claims on the
				# director and a real deploy rewrites them, so the deploy holds
				# the network claims lock from here until the claims are
				# submitted.  A dry run only reads, so it takes no lock.
				_deploy_under_network_claims_lock($env, sub {
					($cloud_config, $network_map) = $env->run_hook('cloud-config');

					# TODO: Support multiple cloud configs
					my $cloud_config_name = $env->name.'.'.$env->type;
					my $cloud_config_dir = $env->workpath('cloud-configs');
					my $diff_dir = $env->workpath('cloud-config-diffs');
					my $new_path = "$cloud_config_dir/${cloud_config_name}.yml";
					my $new_path_diff = "$diff_dir/${cloud_config_name}.yml";
					info "[[  - >>cloud config synthesized.";

					# Wrap this in an eval block to ensure the lock is cleared on error
					mkdir($cloud_config_dir) unless -d $cloud_config_dir;
					mkdir($diff_dir) unless -d $diff_dir;
					mkfile_or_fail($new_path, 0644, $cloud_config);
					my ($out, $rc, $err) = run( 'spruce merge --skip-eval $1 > $2',$new_path,$new_path_diff);
					bail "Error generating cloud config for diff: %s", $err//$out if $rc;
					info "[[  - >>checking for existing cloud config on #M{%s} BOSH director...", $env->bosh->{alias};
					if ($env->bosh->has_config('cloud',$cloud_config_name)) {
						my $old_path = "$cloud_config_dir/current-${cloud_config_name}.yml";
						info "[[  - >>comparing generated cloud config with existing cloud config...";
						$env->bosh->download_configs($old_path,'cloud',$cloud_config_name);
						my $out = _deploy_cloud_config_diff($old_path, $new_path_diff);
						if ($out) {
							info "[[  - >>#yui{found the following differences:}\n\n%s", $out;
							if ($dryrun) {
								_deploy_dryrun_cloud_config_warning($env, $cloud_config_name, 'outdated');
								dryrun(
									"Cloud config check failed: %s\n\nThis would be fixed if not in dry-run mode.",
									$out
								);
							} else {
								_deploy_confirm(
									"Upload the new cloud config to the BOSH director ('no' will cancel deploy)? [y|n]",
									yes => $options{yes}, default => 1
								) or bail "Aborted by user!";
								# The prompt above can wait past the lock's stale timeout,
								# and another deploy may have cleared and taken it since.
								$env->bosh->ensure_network_lock_held('upload the cloud config');
								info(
									"Uploading new cloud config to #M{%s} BOSH director...",
									$env->bosh->{alias}
								);
								eval {
									# Upload the new cloud config
									$env->bosh->upload_config_from_file($new_path,'cloud',$cloud_config_name);
								} or bail(
									"Failed to upload cloud config %s to BOSH director: %s\n\nContent:\n%s",
									$cloud_config_name,
									fix_wrap($@),
									slurp($new_path)
								);
								info "[[  - >>cloud config for #C{%s} deployment has been updated.\n", $env->name;
							}
						} else {
							info "[[  - >>no changes required in cloud config; proceeding with deploy.\n";
						}
					} elsif ($dryrun) {
						_deploy_dryrun_cloud_config_warning($env, $cloud_config_name, 'missing');
						dryrun(
							"Cloud config #C{%s} missing.  This would be created and uploaded if not in dry-run mode.  Content:\n\n%s",
							$cloud_config_name, slurp($new_path_diff)
						);
					} else {
						info(
							"[[  - >>uploading new cloud config to #M{%s} BOSH director...",
							$env->bosh->{alias}
						);
						eval {
							$env->bosh->upload_config_from_file($new_path,'cloud',$cloud_config_name);
						} or bail(
							"Failed to upload cloud config %s to BOSH director: %s\n\nContent:\n%s",
							$cloud_config_name,
							fix_wrap($@),
							slurp($new_path)
						);
						info "[[  - >>cloud config for #C{%s} deployment has been created.\n", $env->name;
					}

					if (ref($network_map) eq 'HASH') {
						if ($dryrun) {
							dryrun(
								"Network map would be updated on the BOSH director if not in dry-run mode."
							);
						} else {
							_deploy_submit_network_claims($env, $network_map);
						}
					}
				}, dryrun => $dryrun, yes => $options{yes});
			} else {
				warning(
					"Kit #C{%s} does not provide a cloud-config hook, so cloud configs ".
					"will not be generated.  Ensure that the BOSH director has the ".
					"necessary cloud config in place.",
					$env->kit->id,
				);
			}
		} elsif ($env->is_ocfp) {
			# OCFP env opted out via genesis.manage-cloud-configs: false.
			# For non-OCFP envs the cloud-config is always externally
			# managed, so skip the warning entirely — it's not actionable.
			warning(
				"Cloud Configs will not be generated for this deployment.  ".
				"Ensure that the BOSH director has the necessary cloud config in place."
			);
		}
		my @hooks = qw(blueprint manifest deploy);
		push @hooks, grep {$env->kit->has_hook($_)} qw(check pre-deploy post-deploy);
		$env->download_required_configs(@hooks);
	} # end if ! $env->use_create_env

	# Check environment for viability
	$env->{notify_prefix_overrides}{'determining manifest fragments for merging...'} = sprintf(
		"[[  - >>checking manifest components...\n[[  - >>",
	);
	my $env_check = $env->_check_environment_viability();
	bail("%s", $env_check->{msg}) if $env_check->{fatal};
	$ok = 0 unless $env_check->{state} eq 'ok';
	my $kit_files = $env_check->{kit_files};

	# Check or fix secrets for required items
	my $fix_secrets = delete($options{'fix-secrets'}) || $Genesis::RC->get('fix_on_deploy') ne 'never';
	if ($fix_secrets && !$dryrun) {
		my $secret_fixes = $env->_fix_secrets(noprompt => $noprompt);
		bail(
			"Failed to fix secrets: %s",
			$secret_fixes->{msg}
		) if $secret_fixes->{fatal};
		$env->notify("%s", $secret_fixes->{msg});
		$ok = 0 unless $secret_fixes->{result} =~ /^(ok|warning)$/;

	} else {
		my $secrets_check = $env->_check_secrets();
		my $msg_type = $secrets_check->{state};
		$msg_type = '%s' if $msg_type eq 'ok';

		$env->notify($msg_type => $secrets_check->{msg});
		if ($secrets_check->{state} !~ /^(ok|warning)$/) {
			dryrun(
				"Secrets would be automatically fixed if not in dry-run mode."
			) if $fix_secrets;
			$ok = 0;
		}
	}

	# Checking yaml files - more of a visual dump than a validation
	if (envset("GENESIS_CHECK_YAML_ON_DEPLOY")) {
		if (my @missing = $env->missing_required_configs('blueprint')) {
			$env->notify("#Y{Required BOSH configs not provided - can't check manifest viability: %s}", join(', ', @missing));
		} else {
			$env->notify("inspecting YAML files used to build manifest...");
			my @yaml_files = $env->format_yaml_files('include-kit' => 1, padding => '  ', kit_files => $kit_files);
			info join("\n",@yaml_files)."\n";
		}
	}

	# Check manifest validation
	if ($ok) {
		if (my @missing = $env->missing_required_configs('manifest')) {
			$env->notify("#Y{Required BOSH configs not provided - can't check manifest viability: %s}", join(', ', @missing));
		} else {
			$env->notify("running manifest viability checks...");
			$env->manifest_provider->unredacted->validate or $ok = 0;
		}
	}

	# Check for release overrides
	my $release_check = $env->_check_release_overrides();
	my $confirm = $noprompt ? 'never' : $Genesis::RC->get(
		'confirm_release_overrides' => $env->top->config->{'confirm_release_overrides'} // 'outdated'
	);
	if ($release_check->{state} ne 'ok' && !$dryrun) {
		if ($confirm eq 'always' || ($confirm eq 'outdated' && $release_check->{state} eq 'outdated')) {
			bail(
				"Cannot prompt user for confirmation of release version overrides - ".
				"not in a controlling terminal.  Please specify #Y{-y|--yes} to bypass this prompt."
			) unless in_controlling_terminal;

			$ok = 0 unless prompt_for_boolean(
				"Release version overrides detected.  Proceed with release version overrides? [y|n]",
				1
			);
		}
	}

	# Check for and potentially fix stemcell availability
	# FIXME: This won't be accurate if there is a missing CPI config for this env
	_deploy_check_stemcells(
		$env,
		fix      => $options{'fix-stemcells'},
		dryrun   => $dryrun,
		noprompt => $noprompt,
	) if !$env->use_create_env;

	bail(
		"Preflight checks failed; deployment operation halted."
	) unless $ok;

	$ok = $env->deploy(%options, network_map => $network_map, reason => $reason);

	if ($ok) {
		success "#M{%s}/#c{%s} deployed successfully.\n", $env->name, $env->type;
		exit 0;
	} else {
		bail "[#M{%s}] #R{Deployment Failed}", $env->name;
	}
}

# _assert_prior_env_deployed - hard invariant: prior_env must have a successful deploy {{{
#
# Bails unconditionally (no --yes override) when the prior_env has never
# produced a successful deployment.  Called from deploy() when CI is
# configured and genesis.pipeline.prior_env is set.
sub _assert_prior_env_deployed {
	my ($env, $prior_name) = @_;

	# exodus_mount already ends with '/'; construct the deployments path directly.
	my $prior_deploys = $env->exodus_mount . $prior_name . '/' . $env->type . '/deployments';
	my $deploys = eval { $env->vault->get_path($prior_deploys) };
	# A record Genesis cannot read is not a record that is missing.
	die $@ if Service::Vault::is_export_error($@);

	if ($deploys && ref($deploys) eq 'HASH') {
		for my $entry (values %$deploys) {
			next unless ref($entry) eq 'HASH';
			my $result = $entry->{result} // '';
			# 'post-failed' means the BOSH deploy itself succeeded; env is running.
			return if $result eq 'success' || $result eq 'post-failed';
		}
	}

	bail(
		"Cannot deploy #C{%s}: its pipeline predecessor #C{%s} has\n".
		"never been successfully deployed.\n\n".
		"Deploy #C{%s} first, then retry.",
		$env->name, $prior_name, $prior_name
	);
}

# }}}
# _get_source_sha_for_pull - determine the control SHA to use for a --pull {{{
#
# Entry-point envs (no prior_env): returns control HEAD so the env
# gets the latest committed control content.
#
# Downstream envs: returns the git.control_commit from the prior_env's
# last successful deployment — the certified control state that was in
# effect when the predecessor last shipped.  Falls back to control HEAD
# with a warning when no record is found.
sub _get_source_sha_for_pull {
	my ($env, $prior_name, $git) = @_;

	my $control = Genesis::Top::DEFAULT_CONTROL_BRANCH();

	unless ($prior_name) {
		# Entry point: pull from control HEAD.
		return $git->sha($control);
	}

	# Access the prior env's last successful deployment directly via vault.
	my $prior_deploys = $env->exodus_mount . $prior_name . '/' . $env->type . '/deployments';
	my $deploys = eval { $env->vault->get_path($prior_deploys) };
	# Falling back to control HEAD would pull content the prior env never
	# shipped, so a record Genesis cannot read stops the pull instead.
	die $@ if Service::Vault::is_export_error($@);

	if ($deploys && ref($deploys) eq 'HASH') {
		for my $ts (sort { $b cmp $a } keys %$deploys) {
			my $entry = $deploys->{$ts};
			next unless ref($entry) eq 'HASH';
			my $result = $entry->{result} // '';
			next unless $result eq 'success' || $result eq 'post-failed';

			# get_path unflattens vault data: git.control_commit → {git}{control_commit}
			my $ctl = (ref($entry->{git}) eq 'HASH') ? $entry->{git}{control_commit} : undef;
			return $ctl if $ctl;
		}
	}

	warning(
		"Prior environment #C{%s} has no #C{git.control_commit} in its\n".
		"last successful deployment.  Falling back to control HEAD for pull.",
		$prior_name
	);
	return $git->sha($control);
}

# }}}
# _apply_pull_propagation - pull propagated files from source_sha onto env branch {{{
#
# Diffs the propagation files between the env branch and the source SHA.
# If there are changes, checks out the updated files from source_sha,
# removes any deleted files, and commits with a [pipeline] control@<sha>
# (pulled) marker.  Notifies and returns without committing when the env
# branch is already current.
sub _apply_pull_propagation {
	my ($env, $env_branch, $source_sha, $git) = @_;

	my @dep_files = $env->propagation_files;
	unless (@dep_files) {
		info "  #Yi{%s}: no propagation files defined — nothing to pull.", $env_branch;
		return;
	}

	my $diff = $git->diff_files($env_branch, $source_sha, @dep_files);
	my @to_copy = @{$diff->{changed}};
	my @to_rm   = @{$diff->{deleted}};

	unless (@to_copy || @to_rm) {
		info "  #Yi{%s}: already current — no propagation changes to pull.", $env_branch;
		return;
	}

	my $total     = scalar(@to_copy) + scalar(@to_rm);
	my $sha_short = $git->sha($source_sha, short => 1) // substr($source_sha, 0, 8);

	info "  #C{%s}: pulling %d file%s from control\@%s",
		$env_branch, $total, $total == 1 ? '' : 's', $sha_short;

	$git->checkout_file($source_sha, $_) for @to_copy;
	$git->rm(@to_rm) if @to_rm;

	my $msg = sprintf("[pipeline] control\@%s -> %s (pulled)", $sha_short, $env_branch);
	$git->commit($msg, @to_copy);

	info "  #G{%s}: propagation pull committed.", $env_branch;
}

# }}}
sub terminate {
	my ($env, $reason, @extras) = @_;
	command_usage(1) if @extras || !defined($env);

	my %options = %{get_options()};
	$env = Genesis::Top->new('.')->load_env($env)->with_vault()->with_bosh()
		unless $env->isa('Genesis::Env');

	# Check if the user is compelled to provide a reason for the deployment
	if (my $min_size = $env->deployment_change_reason_required_size_policy) {
		# TODO: Maybe prompt for reason if not provided?
		bail(
			"Cannot terminate environment #C{%s} without a reason (minimum length is %d characters).\n".
			"Please provide a reason after any options on the command line",
			$env->name, $min_size
		) unless length($reason//'') >= $min_size;
	}

	my $flags = join(" ", map {
		if ($_ =~ m/(resources|secrets|user-secrets|credhub|networking)/) {
			$options{$_} ? "--$_" : "--no-$_";
		} else {
			"--$_";
		}
	} (sort keys %options));

	my %clean_up = ();
	my $default_cleanup = delete($options{'no-cleanup'}) ? 0 : 1;
	for my $opt (qw/resources secrets user-secrets credhub networking/) {
		$clean_up{$opt =~ s/-/_/gr} = exists($options{$opt})
			? (delete($options{$opt}) ? 1 : 0)
			: $default_cleanup;
	}

	my $noprompt = delete($options{'yes'})//0;
	my $dry_run = delete($options{'dry-run'})//0;
	my $force = delete($options{'force'})//0;

	bug(
		"Undefined options passed in from the Genesis command handler: %s",
		join(", ", sort keys %options)
	) if keys %options;

	my $action_desc = $dry_run ? 'would' : 'will';
	my $msg = (
		"This $action_desc #R{terminate} this deployment:\n".
		"[[  - >>#R{all its VMs and persistent disks} $action_desc be #R{destroyed}."
	).(
		$clean_up{secrets}
		? "\n[[  - >>#R{this environment's generated secrets} $action_desc be #R{removed}".
			($default_cleanup ? " (use --no-secrets to keep)." : ".")
		: "\n[[  - >>#G{this environment's generated secrets} $action_desc be left in place".
			($default_cleanup ? "." : " (use --secrets to remove).")
	).(
		$clean_up{user_secrets}
		? "\n[[  - >>#R{this environment's user-provided secrets} $action_desc be #R{removed}".
			($default_cleanup ? " (use --no-user-secrets to keep)." : ".")
		: "\n[[  - >>#G{this environment's user-provided secrets} $action_desc be left in place".
			($default_cleanup ? "." : " (use --user-secrets to remove).")
	);
	$msg .= (
		(
			$clean_up{credhub}
			? "\n[[  - >>#R{this environment's credhub secrets} $action_desc be #R{removed}".
				($default_cleanup ? " (use --no-credhub to keep)." : ".")
			: "\n[[  - >>#G{this environment's credhub secrets} $action_desc be left in place".
				($default_cleanup ? "." : " (use --credhub to remove).")
		).(
			$clean_up{resources}
			? "\n[[  - >>#R{all unused resources} $action_desc be #R{removed} from its BOSH director".
				($default_cleanup ? " (use --no-resources to keep)." : ".")
			: "\n[[  - >>#G{all unused resources} $action_desc be left in place on its BOSH director".
				($default_cleanup ? "." : " (use --resources to remove).")
		).(
			$clean_up{networking}
			? "\n[[  - >>#R{all claimed networks} $action_desc be #R{removed} from its BOSH director".
				($default_cleanup ? " (use --no-networking to keep)." : ".")
			: "\n[[  - >>#G{all claimed networks} $action_desc be left in place on its BOSH director".
				($default_cleanup ? "." : " (use --networking to remove).")
		).(
		"\n[[  - >>#R{all associated BOSH configs on its BOSH director} $action_desc be #R{removed}."
		)
	) unless $env->use_create_env;
	$env->notify($msg);

	if (!$dry_run && !$noprompt) {
		notice(
		"\nYou can run this command with the #Y{--dry-run} option to see exactly what ".
		"would be removed without actually terminating the deployment or removing ".
		"any asscoiated items."
		);
		warning "\nThis action is #R{irreversible} and #R{cannot be undone}!";
		my $msg = sprintf(
			"Are you sure you want to terminate #M{%s}/#c{%s} deployment? [y|n]",
			$env->name, $env->type
		);
		prompt_for_boolean($msg, 0) or bail "Aborted by user!";
	}

	my $ok = $env->terminate(
		dryrun    => $dry_run,
		noprompt  => $noprompt,
		force     => $force,
		reason    => $reason,
		flags     => $flags,
		%clean_up
	);
	if ($dry_run) {
		notice(
			"\n#M{%s}/#c{%s} termination dry-run completed %s.\n",
			$env->name, $env->type,
			$ok ? "#g{successfully}" : "with #r{errors}"
		);
		exit($ok ? 0 : 1);
	}
	if ($ok) {
		success "\n#M{%s}/#c{%s} terminated successfully.\n", $env->name, $env->type;
		exit 0;
	} else {
		bail "\n#M{%s}/#c{%s} #R{termination failed!}", $env->name, $env->type;
	}
}

sub addon {
	command_usage(1) if @_ < 1;

	my ($name, $script, @args) = @_;
	$script = 'help' if !$script || $script eq '--help' || $script eq '-h';
	my $env = Genesis::Top->new('.')->load_env($name)->with_vault();

	$env->kit->check_prereqs($env)
		or bail "Cannot use the kit specified by %s.\n", $env->name;

	$env->has_hook('addon', script => $script)
		or bail "#R{Kit %s does not provide an addon hook!}", $env->kit->id;

	$env->download_required_configs('addon', "addon-$script");

	info(
		"Running #G{%s} addon for #C{%s} #M{%s} deployment",
		$script, $env->name, $env->type
	) unless $script eq 'help';

	$env->run_hook('addon', script => $script, args => \@args)
		or exit 1;
}

sub env_shell {
	append_options(redact => ! -t STDOUT);
	command_usage(1) if @_ != 1;
	my $env = Genesis::Top->new('.')->load_env($_[0])->with_vault();
	$env->with_bosh() unless get_options->{'no-bosh'};
	$env->shell(%{get_options()});
}

# _format_deploy_feature_opt_in - returns the " (feature opt-in: ...)" tail
# for the deploy header, or '' when the env has no effective floor.
sub _format_deploy_feature_opt_in {
	my ($env) = @_;
	my $fc = $env->effective_minimum_version;
	return '' if !$fc || $fc eq '0.0.0';
	return sprintf(
		" (feature opt-in: #c{v%s} from #c{%s})",
		$fc, $env->effective_minimum_version_source
	);
}

# _deploy_cloud_config_diff - the differences between the director's cloud config and the generated one {{{
#
# Returns '' when they match, and the diff when they differ.  A spruce
# failure aborts the deploy with spruce's own message.  This goes through
# spruce_diff, which reads spruce's own exit code on every platform.  When
# this ran spruce under fake_tty directly, any change aborted a deploy on
# macOS with an empty message, and on Linux a spruce failure read as a
# difference.
sub _deploy_cloud_config_diff {
	my ($old_path, $new_path) = @_;
	my ($out, $rc) = spruce_diff($old_path, $new_path);
	bail("Error comparing cloud configs: %s", $out || "spruce diff exited $rc with no output")
		if $rc > 1;
	return '' unless $rc;
	$out =~ s/\(root level\)/<root>/m;
	return $out;
}

# }}}
# _deploy_dryrun_cloud_config_warning - say that a dry run validates against the director's copy of the cloud config {{{
sub _deploy_dryrun_cloud_config_warning {
	my ($env, $cloud_config_name, $state) = @_;

	if ($state eq 'outdated') {
		warning(
			"A dry-run never uploads cloud configs, so the #M{%s} BOSH ".
			"director will validate the manifest against its current copy ".
			"of cloud config #C{%s} rather than the updated one shown above.  ".
			"Errors from bosh about networks, vm types, disk types, vm ".
			"extensions, or availability zones that only the updated cloud ".
			"config defines are expected here and do not indicate a manifest ".
			"problem.  Deploy without #y{--dry-run} to upload the updated cloud ".
			"config before the manifest is validated.",
			$env->bosh->{alias}, $cloud_config_name
		);
	} elsif ($state eq 'missing') {
		warning(
			"A dry-run never uploads cloud configs, and the #M{%s} BOSH director ".
			"does not hold a cloud config named #C{%s}.  When bosh validates the ".
			"manifest it will only see the cloud configs already on the director, ".
			"so errors about unknown networks, vm types, disk types, vm extensions, ".
			"or availability zones are expected here and do not indicate a manifest ".
			"problem.  Deploy without #y{--dry-run} to create and upload the cloud ".
			"config before the manifest is validated.",
			$env->bosh->{alias}, $cloud_config_name
		);
	} else {
		bug("Unknown cloud config state '%s' for a dry-run warning", $state);
	}
	return 1;
}

# }}}
# _deploy_network_claims_lock - check the network claims lock on the director and take it for a real deploy {{{
sub _deploy_network_claims_lock {
	my ($env, %opts) = @_;
	my $bosh = $env->bosh;

	info({pending => 1},
		"[[  - >>checking for existing network claims lock on #M{%s} BOSH director...",
		$bosh->alias
	);
	my $current_lock = $bosh->check_network_lock;
	if ($current_lock->{status} eq 'unlocked') {
		info "#G{available}";
	} elsif ($current_lock->{status} eq 'locked') {
		info "#r{locked} %s", $current_lock->{description};
		if ($opts{dryrun}) {
			warning(
				"Another deploy holds the network claims lock: %s\n\nA dry run only ".
				"reads the network claims, so it carries on, but the deploy that holds ".
				"the lock can change those claims while this dry run is reading them.  ".
				"Any addresses this dry run reports may therefore differ from the ones ".
				"a real deploy would claim once the lock is free.",
				$current_lock->{description}
			);
		} else {
			bail(
				"Network claims are currently locked -- cannot proceed with deployment!\n\n".
				"The network claims lock on the #M{%s} BOSH director is held %s%s.  This ".
				"usually means another deploy, or a #C{bosh-configs upload}, against this ".
				"director is running now or is waiting at a prompt.  Wait for it to finish, ".
				"then deploy again.  If no such process is running, the lock goes stale 30 ".
				"minutes after it was taken, and the next deploy offers to clear it.",
				$bosh->alias, $current_lock->{description} // 'by another process',
				defined($current_lock->{path}) ? sprintf(", and is stored at #C{%s}", $current_lock->{path}) : ''
			);
		}
	} elsif ($current_lock->{status} eq 'stale') {
		info "#y{locked (stale)} %s", $current_lock->{description};
		if ($opts{dryrun}) {
			dryrun(
				"Network claims are locked with a stale lock: %s\n\nThis would be ".
				"cleared if not in dry-run mode.", $current_lock->{description}
			);
		} elsif ($opts{yes}) {
			# --yes clears the stale lock without asking.
		} elsif (in_controlling_terminal) {
			prompt_for_boolean(
				"Clear the stale network claims lock and continue with deployment? [y|n]",
				0
			) or bail "Aborted by user!";
		} else {
			bail(
				"Network claims are locked with a stale lock: %s\n\nRerun with ".
				"#y{--yes} to clear it, or run this command in a terminal to be ".
				"asked.", $current_lock->{description}
			);
		}
		unless ($opts{dryrun}) {
			# Only the stale lock shown above is cleared; one that another
			# process has taken since is left for the acquire below to refuse.
			my $cleared = $bosh->clear_network_lock(stale => $current_lock);
			$env->notify("checking cloud configs for #C{%s} deployment (continued)...", $env->name);
			info($cleared
				? "[[  - >>stale network claims lock cleared."
				: "[[  - >>stale network claims lock was already cleared or taken by another process.");
		}
	}

	if ($opts{dryrun}) {
		info "[[  - >>a dry run reads the network claims without taking the lock.";
		return 0;
	}

	info({pending => 1},
		"[[  - >>acquiring network claims lock on #M{%s} BOSH director...", $bosh->alias
	);
	$bosh->acquire_network_lock();
	info "#G{done}";
	return 1;
}

# }}}
# _deploy_confirm - answer a yes/no question for the deploy: --yes says yes, a terminal asks, a pipe stops {{{
sub _deploy_confirm {
	my ($question, %opts) = @_;
	return 1 if $opts{yes};
	return prompt_for_boolean($question, $opts{default} // 1) ? 1 : 0
		if in_controlling_terminal;
	bail(
		"Cannot ask \"%s\" without a controlling terminal.\n\nRerun with #y{--yes} ".
		"to answer yes, or run this command in a terminal to be asked.",
		$question =~ s/\s*\[y\|n\]\s*$//r
	);
}

# }}}
# _deploy_release_network_claims_lock - release the network claims lock if this process still holds it {{{
sub _deploy_release_network_claims_lock {
	my ($env) = @_;
	# Logs a failed release rather than dying, so it never replaces the error
	# that stopped the deploy.
	return $env->bosh->release_network_lock;
}

# }}}
# _deploy_under_network_claims_lock - run the cloud config step under the network claims lock, releasing it on every exit {{{
sub _deploy_under_network_claims_lock {
	my ($env, $code, %opts) = @_;
	my $takes_lock = !$opts{dryrun};

	# A signal has to unwind through the release below instead of killing the
	# process with the lock still recorded on the director, and that holds
	# from before the lock is written: a signal during the write, or during
	# the wait that confirms it, would otherwise leave it there.  HUP is in
	# the list because these deploys are run over ssh from a bastion, and a
	# dropped session hangs up every process in it -- which is how a lock
	# outlives the process that took it.
	#
	# The first signal unwinds the work.  Any that follows, including one in
	# the gap before the release starts or while it runs, is held until the
	# release has finished, because dying there would skip it or cut it short.
	my $unwinding = $takes_lock;
	my $held_signal;
	my $on_signal = sub {
		my ($message) = @_;
		# $unwinding stays set until the work has been left, below, and not
		# until this first die: code inside the work can catch that die, and
		# the next signal then still has to unwind it.
		die $message if $unwinding;
		$held_signal //= $message;
	};
	local $SIG{INT}  = $takes_lock ? sub { $on_signal->("Interrupted by user\n") } : $SIG{INT};
	local $SIG{TERM} = $takes_lock ? sub { $on_signal->("Terminated\n") }         : $SIG{TERM};
	local $SIG{HUP}  = $takes_lock ? sub { $on_signal->("Hung up\n") }            : $SIG{HUP};
	local $SIG{QUIT} = $takes_lock ? sub { $on_signal->("Quit\n") }               : $SIG{QUIT};

	my ($ok, $err);
	eval {
		$ok = eval {
			_deploy_network_claims_lock($env, dryrun => $opts{dryrun}, yes => $opts{yes});
			$code->();
			1;
		};
		$err = $@;
		# Inside the outer eval, so that a signal between the two lands in it
		$unwinding = 0;
		1;
	} or ($ok, $err) = (0, $@);

	# Released whenever this process holds it, which covers an acquire that
	# wrote the lock and then failed.  A successful deploy already released
	# it when the network claims were submitted.
	_deploy_release_network_claims_lock($env) if $takes_lock;
	die $err unless $ok;
	die $held_signal if defined($held_signal);
	return 1;
}

# }}}
# _deploy_submit_network_claims - write this deployment's network claims to the director, then release the lock {{{
sub _deploy_submit_network_claims {
	my ($env, $network_map) = @_;
	my $bosh = $env->bosh;
	$env->notify(
		"submitting network claims for this deployment to #M{%s} BOSH director...",
		$bosh->alias
	);

	# The claims replace the director's whole network record, so a deploy
	# that lost the lock while it waited would overwrite the claims of the
	# deploy that took it over.
	$bosh->ensure_network_lock_held('write the network claims');

	my $network_path = $bosh->exodus_path.'/network';
	eval {
		# Strict, because a read that failed would look like a record
		# with no claims, and the summary would show every claim as new
		my $stored = $bosh->vault->get_path_strict($network_path) // {};
		Genesis::Env::NetworkClaims::claims_summary($network_path, $stored, $network_map);
		$bosh->vault->set_path($network_path, $network_map, flatten => 1, clear => 1);
		1;
	} or do {
		my $err = $@;
		info("  - #R{failed to update network map}\n");
		bail("\nCannot continue without a valid network map:\n\n%s", $err);
	};

	my $released = $bosh->clear_network_lock();
	info($released
		? "  - #G{network map successfully updated }#Gi{(lock removed)}\n"
		: "  - #G{network map successfully updated}, #y{but the network claims lock was not removed, because it was no longer this deploy's to remove}\n"
	);
	return 1;
}

# }}}
# _deploy_check_stemcells - check the env's stemcells on the director and fix or advise on any that are missing {{{
sub _deploy_check_stemcells {
	my ($env, %opts) = @_;
	my $stemcell_check_result = $env->_check_stemcells();
	return 1 if $stemcell_check_result->{state} eq 'ok';

	if ($opts{fix} && !$stemcell_check_result->{fatal}) {
		if ($opts{dryrun}) {
			dryrun(
				"\nStemcell check failed: %s\n\nThis would be fixed if not in dry-run mode.",
				$stemcell_check_result->{msg}
			);
		} else {
			my $stemcell_fix = $env->_fix_stemcells(
				$stemcell_check_result->{fix_data},
				noprompt => $opts{noprompt},
			);
			bail(
				"Failed to fix stemcells: %s",
				$stemcell_fix->{msg}
			) if $stemcell_fix->{fatal};
			$env->notify("%s", $stemcell_fix->{msg}); # Check if this makes sense or is reduntant
		}
		return 1;
	}

	$env->_advise_stemcell_updates(
		$stemcell_check_result->{fix_data},
	);
	bail(
		"Stemcell check failed: %s",
		$stemcell_check_result->{msg}
	);
}

# }}}

1;
# vim: fdm=marker:foldlevel=1:noet
