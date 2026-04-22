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
use Encode qw(decode_utf8);

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
	if ($ci_configured) {
		my $control = Genesis::Top::DEFAULT_CONTROL_BRANCH();
		my ($branch) = run({}, 'git rev-parse --abbrev-ref HEAD');
		chomp $branch if defined $branch;
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
		run({ onfailure => "Failed to stage $env_file" },
			'git', 'add', $env_file);

		if ($cli_opts_git{'no-commit'}) {
			info "Skipping commit (#C{--no-commit} set); #C{%s} remains staged.", $env_file;
		} else {
			my $message = $cli_opts_git{reason}
				|| "Add environment $name";
			run({ onfailure => "Failed to commit $env_file" },
				'git', 'commit', '-m', $message);

			my ($sha) = run({}, 'git rev-parse --short HEAD');
			chomp $sha if defined $sha;
			info "#G{Committed} #C{%s} -- %s", $sha // '<unknown>', $message;

			# Create the environment branch at the current commit.
			# This is the branch where future config changes and
			# deploys for this environment will happen.  We stay on
			# the control branch.
			run({ onfailure => "Failed to create branch '$name'" },
				'git', 'branch', $name);
			info "Environment branch #C{%s} created.", $name;
		}
	}

	# Generate secrets.  Non-fatal — the env file, pipeline metadata, and
	# git branch are already in place; secrets can be retried later with
	# `genesis add-secrets` or will be generated at deploy time.
	my $secrets_ok = eval { $env->add_secrets(verbose => 1, import => 1) };
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

	get_options->{$_} //= 0 for qw/secrets stemcells/;

	my $ok = $env->check(
		(map {("check_$_" => has_option($_,1))} qw/manifest secrets stemcells/)
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

sub deploy {
	option_defaults(
		redact   => ! -t STDOUT,
		reactions => 1,
	);
	command_usage(1) if @_ < 1 || @_ > 2;
	my ($env_name, $reason) = @_;

	my %options = %{get_options()};
	my @invalid_create_env_opts = grep {$options{$_}} (qw/fix dry-run fix-stemcells/);

	$options{'disable-reactions'} = ! delete($options{reactions});
	my $env = Genesis::Top->new('.')->load_env($env_name)->with_vault()->with_bosh();

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
					? "\n\n[[#Yr{IMPORTANT:} >>The cached files contain a state file, which ".
					"may contain values necessary to run this deployment successfully.  ".
					"Please copy it to a safe location, then use the --STATE-FILE-PATH ".
					"option to use that file instead of a potentially outdated one from ".
					"a previously successful deployment instead of clearing and ".
					"continuing with this deployment."
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

	info "\nPreparing to deploy #C{%s}:\n  - based on kit #c{%s}\n  - using Genesis #c{%s}", $env->name, $env->kit->id, $Genesis::VERSION;
	if ($env->use_create_env) {
		info "  - as a #M{create-env} deployment.";
	} else {
		info "  - to '#M{%s}' BOSH director at #c{%s}.", $env->bosh->{alias}, $env->bosh->{url};
	}
	# Specify the environment iaas and scale
	info(
		"  - to a #Y{%s}-scale #G{%s} IaaS target",
		$env->scale, $env->iaas
	);

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
				$env->director_exodus_lookup('default_cpi_config','default'),
				$env->bosh->{alias}
			);
		}

		if ($env->can_build_cloud_configs) {
			# Refactor this to use _check_cloud_config and _fix_cloud_config like the cpi stuff above
			if ($env->has_hook('cloud-config')) {
				$env->notify("checking cloud configs for #C{%s} deployment...", $env->name);
				info({pending=>1},
					"[[  - >>checking for existing network claims lock on #M{%s} BOSH director...",
					$env->bosh->{alias}
				);
				my $current_lock = $env->bosh->check_network_lock;
				if ($current_lock->{status} eq 'unlocked') {
					info "#G{available}";
				} elsif ($current_lock->{status} eq 'locked') {
					info "#r{locked} %s", $current_lock->{description};
					bail(
						"Network claims are currently locked -- cannot proceed with deployment!"
					);
				} elsif ($current_lock->{status} eq 'stale') {
					info "#y{locked (stale)} %s", $current_lock->{description};
					if ($dryrun) {
						dryrun(
							"Network claims are locked with a stale lock: %s\n\nThis would be fixed if not in dry-run mode.",
							$current_lock->{description}
						);
					} else {
						if (in_controlling_terminal || !$options{'yes'}) {
							prompt_for_boolean(
								"Clear the stale network claims lock and continue with deployment? [y|n]",
								0
							) or bail "Aborted by user!";
						}
						$env->bosh->clear_network_lock;
						$env->notify("checking cloud configs for #C{%s} deployment (continued)...", $env->name);
						info "[[  - >>stale network claims lock cleared.";
					}
				}

				# Place network-update lock here, to prevent concurrent updates to the network data
				info({pending=>1},
					"[[  - >>acquiring network claims lock on #M{%s} BOSH director...", $env->bosh->{alias}
				);
				$env->bosh->acquire_network_lock();
				info "#G{done}";

				eval {
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
						my ($out, $rc, $err) = run(
							fake_tty("$cloud_config_dir/spruce-out.txt",'spruce','diff',$old_path, $new_path_diff)
						);
						bail "Error comparing cloud configs: %s", $err if $rc;

						$out = decode_utf8($out) =~ s/\A\s*(.*?)\s*\z/$1/mrs;
						if ($out) {
							$out =~ s/\(root level\)/<root>/m;
							info "[[  - >>#yui{found the following differences:}\n\n%s", $out;
							if ($dryrun) {
								dryrun(
									"Cloud config check failed: %s\n\nThis would be fixed if not in dry-run mode.",
									$out
								);
							} else {
								if (in_controlling_terminal || !$options{'yes'}) {
									prompt_for_boolean(
										"Upload the new cloud config to the BOSH director ('no' will cancel deploy)? [y|n]",
										1
									) or bail "Aborted by user!";
								}
								my $last_check = $env->bosh->check_network_lock;
								bail(
									"Network claims lock was lost since last checked (may have become stale and removed) -- cannot proceed with deployment!"
								) if ($last_check->{status} eq 'unlocked');
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
						dryrun(
							"Cloud config missing.  This would be created and uploaded if not in dry-run mode.",
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
							# Update the network map on the director's exodus network data
							$env->notify(
								"submitting network claims for this deployment to #M{%s} BOSH director...",
								$env->bosh->{alias}
							);
							eval {$env->bosh->vault->set_path(
								$env->bosh->exodus_path.'/network', $network_map, flatten => 1, clear => 1
							);};
							if ($@) {
								info("  - #R{failed to update network map}\n");
								bail("\nCannot continue without a valid network map:\n\n%s", $@);
							}
							$env->bosh->clear_network_lock();
							info("  - #G{network map successfully updated }#Gi{(lock removed)}\n");
						}
					}
				}; # end eval

				if ($@) {
					my $err = $@;
					# Clear network-update lock here (even if there was an error)
					if ($env->bosh->network_locked_by_me) {
						$env->notify("cleaning up...");
						info({pending=>1},
							"[[  - >>releasing network claims lock on #M{%s} BOSH director...", $env->bosh->{alias}
						);
						$env->bosh->clear_network_lock();
						info "#G{done}";
					}
					die $err;
				}
			} else {
				warning(
					"Kit %s does not provide a cloud-config hook, so cloud configs will ".
					"not be generated.  Ensure that the BOSH director has the necessary ".
					"cloud config in place.",
				);
			}
		} else {
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
		if ($env->missing_required_configs('blueprint')) {
			$env->notify("#Y{Required BOSH configs not provided - can't check manifest viability}");
		} else {
			$env->notify("inspecting YAML files used to build manifest...");
			my @yaml_files = $env->format_yaml_files('include-kit' => 1, padding => '  ', kit_files => $kit_files);
			info join("\n",@yaml_files)."\n";
		}
	}

	# Check manifest validation
	if ($ok) {
		if ($env->missing_required_configs('manifest')) {
			$env->notify("#Y{Required BOSH configs not provided - can't check manifest viability}");
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
	if (!$env->use_create_env) {
		my $stemcell_check_result = $env->_check_stemcells();
		if ($stemcell_check_result->{state} ne 'ok') {
			if ($options{'fix-stemcells'}) {
				if ($dryrun) {
					dryrun(
						"\nStemcell check failed: %s\n\nThis would be fixed if not in dry-run mode.",
						$stemcell_check_result->{msg}
					);
				} else {
					my $stemcell_fix = $env->_fix_stemcells(
						$stemcell_check_result->{fix_data},
						noprompt => $noprompt,
					);
					bail(
						"Failed to fix stemcells: %s",
						$stemcell_fix->{msg}
					) if $stemcell_fix->{fatal};
					$env->notify("%s", $stemcell_fix->{msg}); # Check if this makes sense or is reduntant
				}
			} else {
				$env->_advise_stemcell_updates(
					$stemcell_check_result->{fix_data},
				);
				bail(
					"Stemcell check failed: %s",
					$stemcell_check_result->{msg}
				);
			}
		}
	}

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


1;
# vim: fdm=marker:foldlevel=1:noet
