package Genesis::Commands::Env;

use strict;
use warnings;

use Genesis;
use Genesis::State;
use Genesis::Term;
use Genesis::Commands;
use Genesis::Top;
use Genesis::UI;

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

	# create the environment
	info("\nSetting up new environment #C{$name} based on kit %s ...", $kit->id);
	my $env = $top->create_env($name, $kit, %{get_options()});
	bail "Failed to create environment $name" unless $env;

	# let the user know
	info(
		"New environment $env->{name} provisioned!\n\n".
		"To deploy, run this:\n\n".
		"  #C{genesis deploy '%s'}\n",
		$env->{name}
	);
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

	push(@warnings,
		"Genesis version #Y{$Genesis::VERSION} does not meet the environment's ".
		"minimum required version #R{$min_genesis_version} - you will need to ".
		"upgrade Genesis or alter the environment file to manage this environment ".
		"with this version of Genesis."
	) if $min_genesis_version && !new_enough($Genesis::VERSION, $min_genesis_version);

	bail(
		"Cannot specify #Y{--manual} unless the editor is vi-based (vi,vim,mvim,".
		"nvim,gvim), vscode (code) or emacs: ".
		"Pull request are welcome for other editors."
	) if $use_manual && ! $editor =~ m/^([gmn]?vim|vi|emacs|code)$/;
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
	) if $show_ancestors && !$editor =~ m/^([gmn]?vim|vi|^code)$/;

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
		secrets => 0,
		manifest => 1,
		stemcells => 0,
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

	my $ok = $env->check(map {("check_$_" => has_option($_,1))} qw/manifest secrets stemcells/);
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

	my $valid_types = $env->manifest_provider->known_types;
	my $valid_subsets = $env->manifest_provider->known_subsets;
	if (get_options->{list}) {
		output(
			"Valid manifest types (defaults to default deployment manifest):\n".
			join("", map {"  - $_\n"} map {$_ =~ s/_/-/gr} sort @$valid_types).
			"\n".
			"Valid subsets (defaults to full contents):\n".
			join("", map {"  - $_\n"} map {$_ =~ s/_/-/gr} sort @$valid_subsets)
		);
		return 1;
	}

	bail(
		"Unknown manifest type %s - use --list option to show valid types",
		$type
	) if ($type && ! in_array($type =~ s/-/_/gr, @$valid_types));

	bail(
		"Unknown manifest subset %s - use --list option to show valid subsets",
		$subset
	) if ($subset && ! in_array($subset =~ s/-/_/gr, @$valid_subsets));

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
	);
	command_usage(1) if @_ != 1;

	my %options = %{get_options()};
	my @invalid_create_env_opts = grep {$options{$_}} (qw/fix dry-run/);

	$options{'disable-reactions'} = ! delete($options{reactions});
	my $env = Genesis::Top->new('.')->load_env($_[0])->with_vault();

	if (scalar(grep {$_} ($options{fix}, $options{recreate}, $options{'dry-run'})) > 1) {
		command_usage(1,"Can only specify one of --dry-run, --fix or --recreate");
	}
	$ENV{BOSH_NON_INTERACTIVE} = 'true' if delete $options{yes};

	bail(
		"The following options cannot be specified for #M{create-env}: %s",
		join(", ", @invalid_create_env_opts)
	) if $env->use_create_env && @invalid_create_env_opts;

	info "Preparing to deploy #C{%s}:\n  - based on kit #c{%s}\n  - using Genesis #c{%s}", $env->name, $env->kit->id, $Genesis::VERSION;
	if ($env->use_create_env) {
		info "  - as a #M{create-env} deployment\n";
	} else {
		info "  - to '#M{%s}' BOSH director at #c{%s}.\n", $env->bosh->{alias}, $env->bosh->{url};
	}
	$env
		->with_bosh
		->download_required_configs('deploy');

	my $ok = $env->deploy(%options);
	exit ($ok ? 0 : 1);
}

sub do {
	command_usage(1) if @_ < 2;

	my ($name, $script, @args) = @_;
	my $env = Genesis::Top->new('.')->load_env($name)->with_vault();

	$env->kit->check_prereqs($env)
		or bail "Cannot use the kit specified by %s.\n", $env->name;

	$env->has_hook('addon')
		or bail "#R{Kit %s does not provide an addon hook!}", $env->kit->id;

	$env->download_required_configs('addon', "addon-$script");

	info "Running #G{%s} addon for #C{%s} #M{%s} deployment", $script, $env->name, $env->type;

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
1;
# vim: fdm=marker:foldlevel=1:noet
