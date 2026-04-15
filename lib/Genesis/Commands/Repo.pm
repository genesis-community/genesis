package Genesis::Commands::Repo;

use strict;
use warnings;

use Genesis;
use Genesis::Commands;
use Genesis::Term qw/in_controlling_terminal/;
use Genesis::Top;
use Genesis::Kit::Provider;

use Cwd qw/getcwd abs_path/;
use File::Basename qw/basename/;
use File::Path qw/rmtree/;
use JSON::PP qw/encode_json/;

# ==============================================================================
# repo-init (replaces init)
# ==============================================================================

sub repo_init {
	_repo_init_validate();
	my $result = _repo_init_execute();
	_repo_init_report($result);
	exit 0;
}

# -- Phase 1: Validation (parse + validate + gather + prompt) ------------------
#
# Order within validation:
#   1. Parse options and derive values (fast, no side effects)
#   2. Check invalid option combinations (fast bail)
#   3. Gather data: resolve kit provider, check kit availability, detect git repo
#   4. Check for destructive prerequisites (existing directory)
#   5. Prompt for missing info (vault selection)
#   6. Summarize intent
#
sub _repo_init_validate {
	my %opts = %{get_options()};
	my @args = get_args();

	# --- 1. Parse and derive ---

	my $name = $args[0];
	my $kit_file;

	# Check if kit is a local file path
	if ($opts{kit} && $opts{kit} =~ m#(?:.*/)?([^/]+)-\d+\.\d+\.\d+(?:-rc\.?\d+)?\.t(?:ar\.)?gz#) {
		$kit_file = $opts{kit};
		$name = $1 unless $name;
	}

	# Derive name from kit or link-dev-kit if not specified
	unless ($name) {
		if ($opts{kit} && !$kit_file) {
			($name = $opts{kit}) =~ s|/.*||;
		} elsif ($opts{'link-dev-kit'}) {
			$name = basename($opts{'link-dev-kit'});
		}
	}

	my $dir = $opts{directory} || $name;
	my $parent_dir = abs_path(getcwd());
	my $target_path = "$parent_dir/$dir";

	# --- 2. Check invalid option combinations ---

	bail(
		"You must specify a deployment name, a kit (-k), or a dev link target (-l)."
	) unless $name;

	bail(
		"You can only specify one of kit (-k) or link to a kit (-l)."
	) if $opts{kit} && $opts{'link-dev-kit'};

	bail(
		"Cannot specify both --vault and --skip-vault."
	) if $opts{vault} && $opts{'skip-vault'};

	if ($opts{'ci-provider'}) {
		my @valid = qw(concourse github-actions manual);
		bail(
			"Invalid --ci-provider '%s'. Must be one of: %s",
			$opts{'ci-provider'}, join(', ', @valid)
		) unless grep { $_ eq $opts{'ci-provider'} } @valid;
	}

	# --- 3. Gather data: validate kit source, detect git repo ---

	# Validate kit source exists before any destructive actions
	my ($resolved_kit_name, $resolved_kit_version);
	if ($kit_file) {
		bail("Local compiled kit file '%s' not found.", $kit_file)
			unless -f $kit_file;
	} elsif ($opts{'link-dev-kit'}) {
		bail("Dev kit link target '%s' not found.", $opts{'link-dev-kit'})
			unless -e $opts{'link-dev-kit'};
	} elsif ($opts{kit}) {
		# Remote kit — build provider and resolve name/version
		($resolved_kit_name, $resolved_kit_version) = split('/', $opts{kit}, 2);

		my %provider_opts;
		Genesis::Kit::Provider->parse_opts(\@args, \%provider_opts);
		my $provider = eval { Genesis::Kit::Provider->init(%provider_opts) };
		bail("Could not initialize kit provider: %s", $@) if $@;

		# Resolve version — also validates the kit exists on the provider
		unless ($resolved_kit_version && $resolved_kit_version ne 'latest') {
			$resolved_kit_version = eval { $provider->latest_version_of($resolved_kit_name) };
			bail("Kit '%s' not found or no versions available from %s.",
				$resolved_kit_name, $provider->label) unless $resolved_kit_version;
		}
	}

	# Check git author config
	if ($ENV{GIT_AUTHOR_NAME}) {
		$ENV{GIT_COMMITTER_NAME} ||= $ENV{GIT_AUTHOR_NAME};
	} else {
		run({ onfailure => 'Please setup git: git config --global user.name "Your Name"' },
			'git config user.name');
	}
	if ($ENV{GIT_AUTHOR_EMAIL}) {
		$ENV{GIT_COMMITTER_EMAIL} ||= $ENV{GIT_AUTHOR_EMAIL};
	} else {
		run({ onfailure => 'Please setup git: git config --global user.email your@email.com' },
			'git config user.email');
	}

	# Detect git repo for subdirectory mode
	my $in_git_repo = run({ passfail => 1 }, 'git rev-parse --is-inside-work-tree 2>/dev/null');
	my $use_subdir = $opts{sub};
	if ($in_git_repo && !defined($use_subdir)) {
		$use_subdir = 1;
	}

	# --- 4. Check destructive prerequisites ---

	my $replace_existing = 0;
	if (-e $target_path) {
		if ($opts{force}) {
			$replace_existing = 1;
		} elsif (in_controlling_terminal && Genesis::UI::prompt_for_boolean(
			"Directory #C{$dir} already exists. Replace it? [y|n] ", 0
		)) {
			$replace_existing = 1;
		} else {
			bail("Cannot create repository: directory #C{$dir} already exists. Use -F to force replacement.");
		}
	}

	# --- 5. Prompt for missing info ---

	my $vault_target;
	if ($opts{'skip-vault'}) {
		# explicitly skipped
	} elsif ($opts{vault}) {
		$vault_target = $opts{vault};
	} else {
		my $vault = _select_vault_target();
		$vault_target = $vault->{name} if $vault;
	}

	# --- 6. Store derived values and summarize intent ---

	option_defaults(
		_name                 => $name,
		_dir                  => $dir,
		_parent_dir           => $parent_dir,
		_target_path          => $target_path,
		_kit_file             => $kit_file,
		_use_subdir           => $use_subdir,
		_vault_target         => $vault_target,
		_replace_existing     => $replace_existing,
		_resolved_kit_name    => $resolved_kit_name,
		_resolved_kit_version => $resolved_kit_version,
	);

	my @plan;
	if ($resolved_kit_name) {
		push @plan, "kit: #C{$resolved_kit_name/$resolved_kit_version}";
	} elsif ($kit_file) {
		push @plan, "kit: #C{$kit_file} (local)";
	} elsif ($opts{'link-dev-kit'}) {
		push @plan, "kit: dev link to #C{$opts{'link-dev-kit'}}";
	} else {
		push @plan, "kit: #Yi{empty dev directory}";
	}
	push @plan, "vault: #C{$vault_target}" if $vault_target;
	push @plan, "vault: #Yi{deferred}" unless $vault_target;
	push @plan, "ci provider: #C{$opts{'ci-provider'}}" if $opts{'ci-provider'};
	push @plan, "subdirectory: #C{yes} (no separate git)" if $use_subdir;
	info "\nCreating #C{%s} deployment repository in #M{%s/}:", $name, $dir;
	info "  %s", $_ for @plan;
	info "";

	return 1;
}

# -- Phase 2: Execution -------------------------------------------------------
#
# All validation is complete. This phase only does work — no prompts, no bails
# on user input. Failures here are unexpected errors.
#
sub _repo_init_execute {
	my (
		$name,             # derived name of the deployment/repo
		$dir,              # target directory name (derived from name or specified by user)
		$parent_dir,       # parent directory where repo will be created (usually cwd)
		$target_path,      # full path to the target directory ($parent_dir/$dir)
		$kit_file,         # optional local kit file to copy into the repo
		$kit_spec,         # optional remote kit name[/version] to download
		$use_subdir,       # whether to create the repo as a subdirectory of an existing git repo
		$vault_target,     # vault target to configure, or undef to skip vault
		$replace_existing, # whether to remove existing target directory if it exists
		$linked_dev_kit,   # optional path to a local dev kit to link into the repo
		$ci_provider,      # optional CI provider type
		$directory,        # optional custom directory name override
		$kits_path,        # optional custom kits path
	) = get_options()->@{qw/
		_name _dir _parent_dir _target_path _kit_file kit _use_subdir _vault_target _replace_existing
		link-dev-kit ci-provider directory kits-path
	/};

	# Remove existing directory if validation approved it
	if ($replace_existing && -e $target_path) {
		rmtree $target_path;
	}

	# Resolve link-dev-kit to absolute path before we potentially chdir
	my $abs_dev_target;
	if ($linked_dev_kit) {
		$abs_dev_target = abs_path($linked_dev_kit);
	}

	# Build create options for Top->create
	my %create_opts;
	if ($vault_target) {
		$create_opts{vault} = $vault_target;
	} else {
		$create_opts{skip_vault} = 1;
	}
	$create_opts{directory} = $directory if $directory;

	# Kits path handling
	my $kit_path;
	if (defined $kits_path) {
		$kit_path = abs_path($kits_path // $ENV{HOME}.'/.genesis/kits');
		mkdir_or_fail($kit_path) unless -d $kit_path;
	}

	# Create the repo via Top->create
	my $top = Genesis::Top->create($parent_dir, $name, %create_opts, kits_path => $kit_path);
	$top->embed($ENV{GENESIS_CALLBACK_BIN} || $0) if $ci_provider;

	my $root = $top->path;
	my $human_root = humanize_path($root);
	my $kit_desc = "";

	pushd($root);
	eval {
		# Kit setup
		if ($abs_dev_target) {
			symlink_or_fail($abs_dev_target, "./dev");
			$kit_desc = "linked to kit at #C{$abs_dev_target}";
		} elsif ($kit_file) {
			my $target = $top->path(".genesis/kits");
			mkdir_or_fail($target);
			my $abs_src = $kit_file =~ m#^/# ? $kit_file : abs_path($ENV{GENESIS_CALLER_DIR}."/".$kit_file);
			copy_or_fail($abs_src, $target);
			$kit_desc = "using locally provided compiled kit #C{$kit_file}";
		} elsif ($kit_spec) {
			my ($kit_name, $kit_version) = $top->download_kit($kit_spec);
			$kit_desc = "using the #C{$kit_name/$kit_version} kit";
		} else {
			mkdir_or_fail("./dev");
			$kit_desc = "with an empty development kit in #C{$human_root/dev}";
		}

		# CI provider scaffold
		if ($ci_provider) {
			_create_ci_scaffold($top, $ci_provider);
		}

		# Git init (skip if subdirectory of existing repo)
		unless ($use_subdir) {
			run({ onfailure => "Failed to initialize git in $human_root/" },
				'git init && git add .');
			run({ onfailure => "Failed to commit initial repository in $human_root/" },
				'git commit -m "Initial Genesis Repo"');
		}
	};
	my $err = $@;
	popd;
	if ($err) {
		debug("removing incomplete Genesis repository at #C{$root} due to failed creation");
		rmtree $root;
		bail $err;
	}

	return {
		root          => $root,
		human_root    => $human_root,
		name          => $name,
		kit_desc      => $kit_desc,
		ci_provider   => $ci_provider,
		vault_skipped => $vault_target ? 0 : 1,
		vault         => $vault_target ? ($top->vault ? $top->vault->url : $vault_target) : undef,
		submodule     => $use_subdir,
	};
}

# -- Phase 3: Report ----------------------------------------------------------

sub _repo_init_report {
	my ($result) = @_;
	success "\nGenesis repository #C{%s} created successfully.\n", $result->{name};
}

# -- Helpers -------------------------------------------------------------------

sub _select_vault_target {
	my $configure = Genesis::UI::prompt_for_boolean(
		"Would you like to configure a secrets vault now? [y|n] ", 1
	);
	return undef unless $configure;

	require Service::Vault::Remote;
	my $vault = eval { Service::Vault::Remote->target(undef) };
	return $vault;
}

sub _create_ci_scaffold {
	my ($top, $provider) = @_;

	$top->config->set('ci', {
		enabled  => Genesis::Config::TRUE,
		provider => {
			type => $provider,
		},
		pipeline => {
			name => $top->config->get('deployment_type'),
		},
	});
	$top->config->save;

	my $ci_dir = $top->path(".genesis/ci");
	mkdir_or_fail($ci_dir);
	mkfile_or_fail("$ci_dir/.keep", "");
}


# ==============================================================================
# Legacy init (preserved for backward compatibility, aliased to repo-init)
# ==============================================================================

sub init {
	my %options;
	Genesis::Kit::Provider->parse_opts(\@_, \%options);
	append_options(%options);
	%options = %{get_options()};

	command_usage(1) if @_ > 1;
	command_usage(1, "You can only specify one of kit (-k) or link to a kit (-L)")
		if scalar(grep {$_ =~ /^(?:kit|link-dev-kit)$/} keys %options) > 1;

	my $abs_target;
	my $kit_desc = "";
	my $kit_path = undef;
	if (exists($options{'kits-path'})) {
		$kit_path = abs_path($options{'kits-path'}//$ENV{HOME}.'/.genesis/kits');
		mkdir_or_fail ($kit_path) unless -d $kit_path;
		delete($options{'kits-path'});
	}
	if ($options{'link-dev-kit'}) {
		$abs_target = abs_path($options{'link-dev-kit'});
		my $pwd = getcwd;
		bail(
			"Link target '%s' cannot be found from $pwd!", $options{'link-dev-kit'}
		) unless $abs_target;
	}
	my $name = shift;
	my $kit_file;
	if (($options{kit}||'') =~ m#(?:.*/)?([^/]+)-\d+\.\d+\.\d+(?:-rc\.?\d+)?\.t(?:ar\.)?gz#) {
		bail (
			"Local compiled kit file %s not found", $options{kit}
		) unless -f $options{kit};
		$kit_file = $options{kit};
		$name = $1 unless $name;
	}

	unless ($name) {
		if ($options{kit} && ! $kit_file) {
			($name = $options{kit}) =~ s|/.*||;
		} elsif ($options{'link-dev-kit'}) {
			$name = basename($options{'link-dev-kit'});
		}
	}
	command_usage(1, "You must specify a deployment name if you don't specify a kit or a dev link target.\n")
		unless $name;

	if ($ENV{GIT_AUTHOR_NAME}) {
		$ENV{GIT_COMMITTER_NAME} ||= $ENV{GIT_AUTHOR_NAME};
	} else {
		run(
			{ onfailure => 'Please setup git: git config --global user.name "Your Name" -or- export GIT_AUTHOR_NAME="Your Name"' },
			'git config user.name'
		);
	}
	if ($ENV{GIT_AUTHOR_EMAIL}) {
		$ENV{GIT_COMMITTER_EMAIL} ||= $ENV{GIT_AUTHOR_EMAIL};
	} else {
		run(
			{ onfailure => 'Please setup git: git config --global user.email your@email.com -or- export GIT_AUTHOR_EMAIL=your@email.com' },
			'git config user.email'
		);
	}

	my $top = Genesis::Top->create('.', $name, %options, kits_path => $kit_path);
	my $vault_desc = "\n - using default safe target for the system";
	if ($top->vault) {
		$vault_desc = "\n - using vault at #C{".$top->vault->url."}";
		$vault_desc .= " #Y{(insecure)}" unless $top->vault->tls;
		$vault_desc .= " #Y{(noverify)}" if $top->vault->tls && ! $top->vault->verify;
	}
	$top->embed($ENV{GENESIS_CALLBACK_BIN} || $0);

	my $root = $top->path;
	my $human_root = humanize_path($root);
	pushd($root);
	eval {
		if ($options{'link-dev-kit'}) {
			debug("Kit: linking dev to $abs_target");
			symlink_or_fail($abs_target, "./dev");
			$kit_desc = "\n - linked to kit at #C{$abs_target}.";

		} elsif ($kit_file) {
			debug("Kit: using local kit file $kit_file");
			my $target = $top->path(".genesis/kits");
			mkdir_or_fail($target);
			my $abs_src = $kit_file =~ m#^/# ? $kit_file : abs_path($ENV{GENESIS_CALLER_DIR}."/".$kit_file);
			copy_or_fail($abs_src, $target);
			$kit_desc = "\n - using locally provided compiled kit #C{$kit_file}.";

		} elsif ($options{kit}) {
			debug("Kit: installing kit $options{kit}");
			my ($kit_name, $kit_version) = $top->download_kit($options{kit});
			$kit_desc = "\n - using the #C{$kit_name/$kit_version} kit.";

		} else {
			debug("Kit: creating empty ./dev kit directory");
			mkdir_or_fail("./dev");
			$kit_desc = "\n - with an empty development kit in #C{$human_root/dev}";
		}

		run({ onfailure => "Failed to initialize a git repository in $human_root/" },
			'git init && git add .');

		run({ onfailure => "Failed to commit initial Genesis repository in $human_root/" },
			'git commit -m "Initial Genesis Repo"');
	};
	my $err = $@;
	popd;
	if ($err) {
		debug("removing incomplete Genesis deployments repository at #C{$root} due to failed creation");
		rmtree $root;
		bail $err;
	}
	info "\nInitialized empty Genesis repository in #C{%s}%s%s\n", $human_root, $vault_desc, $kit_desc;
	exit 0;
}

# ==============================================================================
# Other repo commands
# ==============================================================================

sub secrets_provider {
	command_usage(1) if @_ > 1;

	my %options = %{get_options(qw(interactive clear))};
	$options{target} = shift if scalar(@_);
	bail("You can only specify one of target, -i|--interactive or -c|--clear")
		if scalar(keys %options) > 1;

	my $ui_nl = $options{interactive} ? "" : "\n";

	my $top = Genesis::Top->new('.', no_vault => 1);
	my $err;
	if (scalar(keys %options)) {
		$err = $top->set_vault(%options);
		error "$ui_nl$err\nCurrent vault was not changed.\n" if $err;
	}

	info("${ui_nl}Secrets provider for #C{%s} deployment at #M{%s}:", $top->type, $top->path);
	my %vault_info = $top->vault_status;
	if (%vault_info) {
		if ($vault_info{status} eq "unauthenticated") {
			eval {$top->vault->authenticate};
			%vault_info = $top->vault_status;
		}
		info(
			"         Type: #G{%s}\n".
			"          URL: #G{%s} %s\n".
			"  Local Alias: #%s{%s}\n".
			"       Status: #%s{%s}\n",
			"Safe/Vault", $vault_info{url}, $vault_info{security},
			$vault_info{alias_error} ? "R" : "G",
			$vault_info{alias} ? $vault_info{alias} : "$vault_info{alias_error}",
			$vault_info{status} eq "ok" ? "G" : "R",
			$vault_info{status}
		);
	} else {
		info "\n#Y{Not set - legacy mode enabled (will use current safe target on system)}\n";
	}

	exit defined($err) ? 1 : 0;
}

sub kit_provider {
	my %options;
	Genesis::Kit::Provider->parse_opts(\@_, \%options);
	%options = %{append_options(%options)};
	my $cfg_export = delete($options{'export-config'});
	bail "Option #M{--export-config} cannot be used with any other options"
		if ($cfg_export && scalar(keys(%options)));

  my $verbose = delete($options{verbose});
	if (delete($options{default})) {
		$options{'kit-provider'} = 'genesis-community';
	}
	command_usage(1) if @_ > 0;

	my $top = Genesis::Top->new('.');
	my $err;
	my $kit_provider_lookup = "current";
	if (scalar(grep {$_ =~ /^kit-provider/} keys %options)) {
		$err = $top->set_kit_provider(%options);
		if ($err) {
			error "\n#R{[ERROR]} Current kit provider was not changed - reason:\n\n$err\n";
			exit 1;
		}
		$kit_provider_lookup = "new";
	}

	if ($cfg_export) {
		output JSON::PP::encode_json({$top->kit_provider->config});
		exit 0
	}

	info(
		"\nCollecting information on %s kit provider for #C{%s} deployment at #M{%s}",
		$kit_provider_lookup, $top->type, humanize_path($top->path)
	);
	my %info;
	eval {
		%info = $top->kit_provider_info($verbose);
	};
	info("Complete.\n");

	bail "$@" if $@;

	info("         Type: #M{%s}\n", $info{type});
	info("%13s: #C{%s}", $_, $info{$_}) for (@{$info{extras} || []});
	info("\n       Status: #%s{%s}\n", $info{status} eq "ok" ? "G" : "R", $info{status});

	my $kit_list;
	if (ref($info{kits}) eq "HASH" && scalar(keys(%{$info{kits}}))) {
		my $width = (sort {$b <=> $a} map {length($_)} keys %{$info{kits}})[0];
		$kit_list = join("\n               ",
										 map {
											 sprintf("#%s{%-${width}s} [%s]", $_ eq $top->type ? 'G' : '-', $_, $info{kits}->{$_})
										} sort keys(%{$info{kits}})
								);
	} elsif (ref($info{kits}) eq "ARRAY" && scalar(@{$info{kits}})) {
		$kit_list = join("\n               ", map {sprintf("#%s{%s}", $_ eq $top->type ? 'G' : '-', $_)} @{$info{kits}});
	} elsif (ref($info{kits}) eq "" && ($info{kits} || "") =~ /^[1-9][0-9]*$/) {
		$kit_list = $info{kits} . "kit" . ($info{kits} == 1 ? "" : "s");
	} else {
		$kit_list = "#Yi{None}";
	}
	info("         Kits: %s\n\n", $kit_list) if $info{status} eq "ok";
}

1;
# vim: fdm=marker:foldlevel=0:noet
