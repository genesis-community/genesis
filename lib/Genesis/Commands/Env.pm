package Genesis::Commands::Env;

use strict;
use warnings;

use Genesis;
use Genesis::State;
use Genesis::Term;
use Genesis::Commands;
use Genesis::Top;

sub create {
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
	my ($name) = @_;
	my $top = Genesis::Top->new('.');
	my $env = $top->load_env($name);
	my $kit;

	if (get_options->{kit}) {
		my @possible_kits = keys %{$top->local_kits};
		push @possible_kits, 'dev' if $top->has_dev_kit;

		bail "No local kits found; you must specify the name of the kit to fetch"
			unless scalar(@possible_kits);

		my ($kit_name,$version) = (get_options->{kit}) =~ m/^([^\/]*)(?:\/(.*))?$/;
		if (!$version && semver($name)) {
			bail "More than one local kit found; please specify the kit to get the manual for"
				if scalar(@possible_kits) > 1;
			$version = $name;
			$version =~ s/^v//;
			$name = $possible_kits[0];
		}
		$kit = $top->local_kit_version($name, $version);

		if(!(defined $kit)) {
			error "Kit not found: #C{%s}", $name;
			exit 1;
		}

	} else {
		$kit = $env->kit;
	}
	info "Editing environment $name (kit #C{%s})", $kit->id;

	my $man = $kit->path('MANUAL.md');
	warning(
		"#M{%s} has no MANUAL.md",
		$kit->id
	) unless (-f $man);

	$kit->run_hook('edit', env => $env, editor => get_options->{editor});
	exit 0;
}

sub check {
	command_usage(1) if @_ != 1;

	option_defaults(
		secrets => 0,
		manifest => 1,
		stemcells => 0
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
		error "\n[#M{%s}] #R{PREFLIGHT FAILED}", $env->name;
		exit 1;
	}
}

sub check_secrets {
	command_usage(1) if @_ < 1;
	my ($name,@paths) = @_;
	my $level = delete(get_options->{level}) || 'i';
	my $validation_level;
	if ($level =~ /^m(issing)?/) {
		$validation_level=0;
	} elsif ($level =~ /^i(nvalid)?/) {
		$validation_level=1;
	} elsif ($level =~ /^p(roblem(atic)?)?/) {
		$validation_level=2;
	} else {
		bail(
			"Invalid -l|--level value: expecting one of #g{missing}, #g{invalid} or ".
			"#g{problem} (or respective short form#g{m}, #g{i} or #g{p} short forms) ".
			"- got '#R{%s}'", $level
		)
	}
	Genesis::Top
		->new(".")
		->load_env($name)
		->with_vault()
		->check_secrets(paths=>\@paths,%{get_options()}, validate => $validation_level)
		or exit 1;
}

sub add_secrets {
	command_usage(1) if @_ < 1;
	my ($name,@paths) = @_;
	Genesis::Top
		->new(".", vault => get_options->{vault})
		->load_env($name)
		->with_vault()
		->add_secrets(paths=>\@paths,%{get_options()});
}

sub rotate_secrets {
	command_usage(1) if @_ < 1;
	my ($name, @paths) = @_;
	bail(
		"--force option no longer valid. See `genesis rotate-secrets -h` for more details"
	) if get_options->{force};

	get_options->{invalid} = 2 if delete(get_options->{problematic});
	Genesis::Top
		->new(".", vault => get_options->{vault})
		->load_env($name)
		->with_vault()
		->rotate_secrets(paths => \@paths,%{get_options()})
		or exit 1;
}

sub remove_secrets {
	command_usage(1, 'Missing environment name or file') if @_ < 1;
	my %options = %{get_options()};
	my ($name, @paths) = @_;
	if ( $options{all}) {
		bail(
			"Cannot specify secret paths when using the --all option."
		) if @paths;
		bail(
			"Cannot use --invalid, --problematic, or --interactive at the same time as the --all option."
		) if $options{problematic} || $options{invalid} || $options{interactive};
	}

	$options{invalid} = 2 if delete($options{problematic});
	Genesis::Top
		->new(".", vault => $options{vault})
		->load_env($name)
		->with_vault()
		->remove_secrets(paths => \@paths,%options)
		or exit 1;
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
	my $manifest = $env
		->download_required_configs('blueprint', 'manifest')
		->manifest_provider->$type(notify=>1,subset=>$subset);
	my $content = slurp($manifest->file) =~ s/\s*\z//msr;
	print STDERR "\n";
	output {raw => 1}, $content;
}

sub deploy {
	option_defaults(
		redact => ! -t STDOUT,
		entomb => !!$Genesis::RC->get('entomb_secrets',1)
	);
	command_usage(1) if @_ != 1;

	my %options = %{get_options()};
	my @invalid_create_env_opts = grep {$options{$_}} (qw/fix dry-run entomb/);

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

	$options{entomb} = 1 unless defined($options{entomb});
	$options{entomb} = 0 if $env->use_create_env;

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


sub bosh {
	append_options(redact => ! -t STDOUT);

	command_usage(1) unless @_;
	my $env = Genesis::Top->new('.')->load_env(shift(@_))->with_vault();

	my $bosh;
	my $bosh_exodus_path;
	if (get_options->{'as-director'}) {
		$bosh_exodus_path=$env->exodus_base;
		my $exodus_data = eval {$env->vault->get($bosh_exodus_path)};
		if ($exodus_data->{url} && $exodus_data->{admin_password}) {
			$bosh = Service::BOSH::Director->from_exodus($env->name, exodus_data => $exodus_data);
		} else {
			$bosh = Service::BOSH::Director->from_alias($env->name);
		}
	} else {
		bail(
			"Environment %s is a 'create-env' environment, so it does not have an ".
			"associated BOSH Director.  Please use the #y{--as-director} option if ".
			"you are trying to target this environment as the BOSH director.",
			 $env->name
		) if ($env->use_create_env);
		$bosh_exodus_path=Service::BOSH::Director->exodus_path($env->name);
		$bosh = $env->bosh; # This sets the deployment name.
	}
	bail(
		"No BOSH connection details found.  This may be due to not having read ".
		"access to the BOSH deployment's exodus data in vault (#M{%s}).",
		$bosh_exodus_path
	) unless $bosh;

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

sub env_shell {

	append_options(redact => ! -t STDOUT);
	command_usage(1) if @_ != 1;
	
	my $env = Genesis::Top->new('.')->load_env($_[0])->with_vault();
	$env->with_bosh() unless get_options->{'no-bosh'};
	$env->shell(%{get_options()});
}
1;
