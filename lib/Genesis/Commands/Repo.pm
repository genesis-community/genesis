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

sub repo_init {
	_repo_init_parse();
	_repo_init_validate();
	my $result = _repo_init_execute();
	_repo_init_report($result);
	exit 0;
}

sub _repo_init_execute {
	my %opts = %{get_options()};
	my $name = $opts{_name};
	my $dir = $opts{_dir};

	# Resolve link-dev-kit to absolute path before we potentially chdir
	my $abs_dev_target;
	if ($opts{'link-dev-kit'}) {
		$abs_dev_target = abs_path($opts{'link-dev-kit'});
		bail("Link target '%s' cannot be found!", $opts{'link-dev-kit'})
			unless $abs_dev_target;
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

	# Handle existing directory (before any interactive prompts)
	my %create_opts = %opts;
	if (-e $dir) {
		if ($opts{force}) {
			rmtree $dir;
		} elsif (in_controlling_terminal && Genesis::UI::prompt_for_boolean(
			"Directory #C{$dir} already exists. Replace it? [y|n] ", 0
		)) {
			rmtree $dir;
		} else {
			bail("Cannot create repository: directory #C{$dir} already exists. Use -F to force replacement.");
		}
	}

	# Subrepo detection
	my $in_git_repo = run({ passfail => 1 }, 'git rev-parse --is-inside-work-tree 2>/dev/null');
	my $use_subdir = $opts{sub};
	if ($in_git_repo && !defined($use_subdir)) {
		$use_subdir = 1;
	}

	# Vault selection
	if ($opts{'skip-vault'}) {
		$create_opts{skip_vault} = 1;
		delete $create_opts{vault};
		delete $create_opts{'skip-vault'};
	} elsif (!$opts{vault}) {
		# Interactive vault selection
		my $vault = _select_vault_target();
		if ($vault) {
			$create_opts{vault} = $vault->{name};
		} else {
			$create_opts{skip_vault} = 1;
		}
	}

	# Kits path handling
	my $kit_path;
	if (exists($create_opts{'kits-path'})) {
		$kit_path = abs_path($create_opts{'kits-path'} // $ENV{HOME}.'/.genesis/kits');
		mkdir_or_fail($kit_path) unless -d $kit_path;
		delete $create_opts{'kits-path'};
	}

	# Remove repo-init specific options before passing to Top->create
	my $ci_provider = delete $create_opts{'ci-provider'};
	delete $create_opts{force};
	delete $create_opts{'skip-vault'};
	delete $create_opts{'sub'};
	delete $create_opts{_name};
	delete $create_opts{_dir};

	# Create the repo via Top->create
	my $top = Genesis::Top->create('.', $name, %create_opts, kits_path => $kit_path);
	$top->embed($ENV{GENESIS_CALLBACK_BIN} || $0);

	my $root = $top->path;
	my $human_root = humanize_path($root);
	my $kit_desc = "";

	pushd($root);
	eval {
		# Kit setup
		if ($abs_dev_target) {
			symlink_or_fail($abs_dev_target, "./dev");
			$kit_desc = "linked to kit at #C{$abs_dev_target}";
		} elsif ($opts{kit}) {
			my $kit_file;
			if ($opts{kit} =~ m#(?:.*/)?([^/]+)-\d+\.\d+\.\d+(?:-rc\.?\d+)?\.t(?:ar\.)?gz#) {
				bail("Local compiled kit file %s not found", $opts{kit}) unless -f $opts{kit};
				$kit_file = $opts{kit};
			}
			if ($kit_file) {
				my $target = $top->path(".genesis/kits");
				mkdir_or_fail($target);
				my $abs_src = $kit_file =~ m#^/# ? $kit_file : abs_path($ENV{GENESIS_CALLER_DIR}."/".$kit_file);
				copy_or_fail($abs_src, $target);
				$kit_desc = "using locally provided compiled kit #C{$kit_file}";
			} else {
				my ($kit_name, $kit_version) = $top->download_kit($opts{kit});
				$kit_desc = "using the #C{$kit_name/$kit_version} kit";
			}
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
		root        => $root,
		human_root  => $human_root,
		name        => $name,
		kit_desc    => $kit_desc,
		ci_provider => $ci_provider,
		vault_skipped => $create_opts{skip_vault} ? 1 : 0,
		vault       => $create_opts{skip_vault} ? undef : ($top->vault ? $top->vault->url : undef),
		submodule   => $use_subdir,
	};
}

sub _repo_init_report {
	my ($result) = @_;

	my @details;
	push @details, " - $result->{kit_desc}" if $result->{kit_desc};

	if ($result->{vault}) {
		my $vault_desc = "using vault at #C{$result->{vault}}";
		push @details, " - $vault_desc";
	} else {
		push @details, " - #Y{vault not configured} (use #C{genesis secrets-provider} to set)";
	}

	if ($result->{ci_provider}) {
		push @details, " - CI provider: #C{$result->{ci_provider}}";
	}

	if ($result->{submodule}) {
		push @details, " - created as subdirectory (no separate git)";
	}

	info "\nInitialized Genesis repository in #C{%s}\n%s\n",
		$result->{human_root}, join("\n", @details);
}

sub _select_vault_target {
	# Ask if user wants to configure vault now or skip
	my $configure = Genesis::UI::prompt_for_boolean(
		"Would you like to configure a secrets vault now? [y|n] ", 1
	);
	return undef unless $configure;

	# Use the existing interactive vault selector from Service::Vault::Remote
	require Service::Vault::Remote;
	my $vault = eval { Service::Vault::Remote->target(undef) };
	return $vault;
}

sub _create_ci_scaffold {
	my ($top, $provider) = @_;

	# Write ci: section to .genesis/config
	$top->config->set('ci', {
		enabled  => Genesis::Config::TRUE,
		provider => $provider,
		pipeline => {
			name => $top->config->get('deployment_type'),
		},
	});
	$top->config->save;

	# Create .genesis/ci/ scaffold
	my $ci_dir = $top->path(".genesis/ci");
	mkdir_or_fail($ci_dir);

	mkfile_or_fail("$ci_dir/targets.yml", <<'TARGETS');
---
# BOSH director connection info (per environment)
# Fill in for each environment that will be deployed via pipeline.
#
# Example:
#   my-env:
#     url:      https://bosh.example.com:25555
#     ca_cert:  (( vault "secret/bosh/ssl:ca" ))
#     username: admin
#     password: (( vault "secret/bosh/admin:password" ))
TARGETS

	mkfile_or_fail("$ci_dir/resources.yml", <<'RESOURCES');
---
# Abstract resource declarations
# These are translated to provider-specific format during compilation.
RESOURCES

	mkfile_or_fail("$ci_dir/ci-overrides-${provider}.yml", <<'OVERRIDES');
---
# Post-provider output overrides
# Merged over provider output after compilation.
# Use this for provider-specific customizations.
OVERRIDES
}

sub _repo_init_parse {
	my %options;
	Genesis::Kit::Provider->parse_opts(\@_, \%options);
	append_options(%options);
	return 1;
}

sub _repo_init_validate {
	my %opts = %{get_options()};
	my @args = get_args();
	my $name = $args[0];

	# Derive name from kit if not specified
	unless ($name) {
		if ($opts{kit} && $opts{kit} !~ m#\.t(?:ar\.)?gz$#) {
			($name = $opts{kit}) =~ s|/.*||;
		} elsif ($opts{'link-dev-kit'}) {
			$name = basename($opts{'link-dev-kit'});
		}
	}

	# Must have a name or a kit to derive it from
	bail(
		"You must specify a deployment name, a kit (-k), or a dev link target (-l)."
	) unless $name;

	# --kit and --link-dev-kit are mutually exclusive
	bail(
		"You can only specify one of kit (-k) or link to a kit (-l)."
	) if $opts{kit} && $opts{'link-dev-kit'};

	# --vault and --skip-vault are mutually exclusive
	bail(
		"Cannot specify both --vault and --skip-vault."
	) if $opts{vault} && $opts{'skip-vault'};

	# --ci-provider must be a valid value
	if ($opts{'ci-provider'}) {
		my @valid = qw(concourse github-actions manual);
		bail(
			"Invalid --ci-provider '%s'. Must be one of: %s",
			$opts{'ci-provider'}, join(', ', @valid)
		) unless grep { $_ eq $opts{'ci-provider'} } @valid;
	}

	# Store derived values back into options for execution phase
	my $dir = $opts{directory} || $name;
	option_defaults(
		_name => $name,
		_dir  => $dir,
	);

	# Summarize intent
	my @plan;
	push @plan, "kit: #C{$opts{kit}}" if $opts{kit};
	push @plan, "kit: dev link to #C{$opts{'link-dev-kit'}}" if $opts{'link-dev-kit'};
	push @plan, "kit: #Yi{empty dev directory}" unless $opts{kit} || $opts{'link-dev-kit'};
	push @plan, "vault: #C{$opts{vault}}" if $opts{vault};
	push @plan, "vault: #Yi{deferred}" if $opts{'skip-vault'};
	push @plan, "vault: #Yi{will prompt}" unless $opts{vault} || $opts{'skip-vault'};
	push @plan, "ci provider: #C{$opts{'ci-provider'}}" if $opts{'ci-provider'};
	info "\nCreating #C{%s} deployment repository in #M{%s/}:", $name, $dir;
	info "  %s", $_ for @plan;
	info "";

	return 1;
}

sub init {
	my %options;
	# FIXME: The following might work, but it may need some tweaking as it used to
	# run before the regular option parser.
	Genesis::Kit::Provider->parse_opts(\@_, \%options);
	append_options(%options);
	%options = %{get_options()};

	command_usage(1) if @_ > 1; # name is now optional if kit specified
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

sub secrets_provider {
	command_usage(1) if @_ > 1; # target is optional

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
			eval {$top->vault->authenticate}; # Try to auto-authenticate
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
