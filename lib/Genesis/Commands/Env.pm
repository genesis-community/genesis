package Genesis::Commands::Env;

use strict;
use warnings;

use Genesis;
use Genesis::Commands;
use Genesis::Top;
use Genesis::UI;

sub create {
	command_usage(1) if @_ != 1;
	warn "The --no-secrets flag is deprecated, and no longer honored.\n"
		if has_option("secrets", 0);

	my $name = $_[0];
	bail "No environment name specified!\n" unless $name;
	$name =~ s/\.yml$//;

	my $top = Genesis::Top->new('.');
	my $vault_desc = get_options->{vault} || $top->get_ancestral_vault($name) || '';
	if ($vault_desc) {
		if ( $vault_desc eq "?") {
			$top->set_vault(interactive => 1);
		} else {
			my $vault = Genesis::Vault->get_vault_from_descriptor($vault_desc, get_options->{vault} ? '--vault option' : '');
			$top->set_vault(vault => $vault);
		}
		$vault_desc = $top->vault->build_descriptor()
	}


	# determine the kit to use (dev or compiled)
	my $kit_id=delete(get_options->{kit}) || '';
	my $kit = $top->local_kit_version($kit_id);
	if (!$kit) {
		if (!$kit_id) {
			die "Unable to determine the correct version of the Genesis Kit to use.\n".
			    "Perhaps you should specify it with the `--kit` flag.\n";
		}
		if ($kit_id eq 'dev') {
			die "No dev/ kit found in current working directory.\n".
			    "(did you forget to `genesis decompile-kit` first?)\n";
		}
		die "Kit '$kit_id' not found in compiled kit cache.\n".
		    "Do you need to `genesis fetch-kit $kit_id`?\n";
	}

	# Check if root ca path exists if specified
	if (get_options->{'root-ca-path'}) {
		bail "No CA certificate found in vault under '#C{%s}'", get_options->{'root-ca-path'}
			unless $top->vault->query('x509', 'validate', '-A', get_options->{'root-ca-path'});
	}

	# check version prereqs
	$kit->check_prereqs() or exit 86;

	# create the environment
	explain("\nSetting up new environment #C{$name} based on kit %s ...", $kit->id);
	my $env = $top->create_env($name, $kit, %{get_options()});
	bail "Failed to create environment $name" unless $env;

	# let the user know
	explain("New environment $env->{name} provisioned!");
	explain("\nTo deploy, run this:\n");
	explain("  #C{genesis deploy '%s'}\n\n", $env->{name});
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
	error "Editing environment $name (kit #C{%s})", $kit->id;

	my $man = $kit->path('MANUAL.md');
	explain("#Y{[WARNING]} #M{%s} has no MANUAL.md", $kit->id)
		unless (-f $man);

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
		bail "Cannot specify --no-config without also specifying --no-manifest"
			if get_options->{manifest};
	} else {
		my @hooks = qw/check/;
		push(@hooks, 'manifest', 'blueprint') if has_option('manifest',1);
		$env->download_required_configs(@hooks);
	}

	my $ok = $env->check(map {("check_$_" => has_option($_,1))} qw/manifest secrets stemcells/);
	if ($ok) {
		explain "\n[#M{%s}] #G{All Checks Succeeded}", $env->name;
		exit 0;
	} else {
		explain "\n[#M{%s}] #R{PREFLIGHT FAILED}", $env->name;
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
		bail "#R{[ERROR]} Invalid -l|--level value: expecting one of #g{missing}, #g{invalid} or".
		     "        #g{problem} (or respective short form#g{m}, #g{i} or #g{p} short forms) - got '#R{%s}'", $level
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
	bail "--force option no longer valid. See `genesis rotate-secrets -h` for more details"
		if get_options->{force};

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
		bail "Cannot specify secret paths when using the --all option."
			if @paths;
		bail "Cannot use --invalid, --problematic, or --interactive at the same time as the --all option."
			if $options{problematic} || $options{invalid} || $options{interactive};
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

	option_defaults(
		redact => get_options->{'bosh-vars'} ? 0 : ! -t STDOUT,
		prune  => get_options->{'bosh-vars'} ? 0 : 1
	);

	bail(
		"\n#R{[ERROR]} Cannot specify --bosh-vars with --redact or --prune\n"
	)	if (get_options->{'bosh-vars'} && (get_options->{prune} || get_options->{redact}));

	my $env = Genesis::Top
		->new('.')
		->load_env($_[0])
		->with_vault();

	if ($env->use_create_env && scalar($env->configs)) {
		error( "\n".
			wrap(
				"The provided configs will be ignored, as create-env environments do ".
				"not use them:\n[[- >>".join("\n[[- >>", map {"#C{$_}"} ($env->configs) ),
				terminal_width, "#Y{[WARNING]} "
		));
	}

	print $env
		->download_required_configs('blueprint', 'manifest')
		->manifest(
			partial   => get_options->{partial},
			redact    => get_options->{redact},
			prune     => get_options->{prune},
			vars_only => get_options->{'bosh-vars'}
		);
}

sub deploy {
	option_defaults(
		redact => ! -t STDOUT
	);
	command_usage(1) if @_ != 1;

	my %options = %{get_options()};
	my @invalid_create_env_opts = grep {$options{$_}} (qw/fix dry-run/);

	$options{'disable-reactions'} = ! delete($options{reactions});
	my $env = Genesis::Top->new('.')->load_env($_[0])->with_vault();

	if (scalar(grep {$_} ($options{fix}, $options{recreate}, $options{'dry-run'})) > 1) {
		command_usage(1,"Can only specify one of --dry-run, --fix or --recreate");
	}
	$ENV{BOSH_NON_INTERACTIVE} = delete $options{yes} ? 'true' : '';

	bail(
		"The following options cannot be specified for #M{create-env}: %s",
		join(", ", @invalid_create_env_opts)
	) if $env->use_create_env && @invalid_create_env_opts;

	explain "Preparing to deploy #C{%s}:\n  - based on kit #c{%s}\n  - using Genesis #c{%s}", $env->name, $env->kit->id, $Genesis::VERSION;
	if ($env->use_create_env) {
		explain "  - as a #M{create-env} deployment\n";
	} else {
		explain "  - to '#M{%s}' BOSH director at #c{%s}.\n", $env->bosh->{alias}, $env->bosh->{url};
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

	explain STDERR "Running #G{%s} addon for #C{%s} #M{%s} deployment", $script, $env->name, $env->type;

	$env->run_hook('addon', script => $script, args => \@args)
		or exit 1;
}

sub lookup {
	command_usage(1) if @_ < 2 or @_ > 3;
	get_options->{exodus} = 1 if get_options->{'exodus-for'};
	command_usage(1,"#R{[ERROR]} Can only specify one of --merged, --partial, --deployed, or --exodus(-for)")
		if ((grep {$_ =~ /^(exodus|deployed|partial|merged|env)$/} keys(%{get_options()})) > 1);

	my ($name, $key, $default) = @_;
	# Legacy support -- previous versions used key/name order
	my $top = Genesis::Top->new('.');
	($name, $key) = ($key,$name) if !$top->has_env($name) && $top->has_env($key);

	if (get_options->{"defined"}) {
		command_usage(1, "#R{[ERROR]} Cannot specify default value with --defines option")
			if defined($default);
		$default = bless({},"NotFound"); # Impossible to have this value in sources.
	}
	my $env = $top->load_env($name);
	my $v;
	if (get_options->{merged}) {
		die "Circular reference detected while trying to lookup merged manifest of $name\n"
			if envset("GENESIS__LOOKUP_MERGED_MANIFEST");
		$ENV{GENESIS__LOOKUP_MERGED_MANIFEST}="1";
		$env->download_required_configs('manifest');
		$v = $env->manifest_lookup($key,$default);
	} elsif (get_options->{partial}) {
		die "Circular reference detected while trying to lookup merged manifest of $name\n"
			if envset("GENESIS__LOOKUP_MERGED_MANIFEST");
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
		print "$v\n";
	}
	exit 0;
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
			$bosh = Genesis::BOSH::Director->from_exodus($env->name, exodus_data => $exodus_data);
		} else {
			$bosh = Genesis::BOSH::Director->from_alias($env->name);
		}
	} else {
		bail("#R{[ERROR]} Environment %s is a 'create-env' environment, so it does\n".
				 "        not have an associated BOSH Director.  Please use the #y{--as-director} option\n".
				 "        if you are trying to target this environment as the BOSH director.\n",
				 $env->name
		) if ($env->use_create_env);
		$bosh_exodus_path=Genesis::BOSH::Director->exodus_path($env->name);
		$bosh = $env->bosh; # This sets the deployment name.
	}
	bail(
		"#R{[ERROR]} No BOSH connection details found.  This may be due to not having read access\n".
		"        to the BOSH deployment's exodus data in vault (#M{%s}).\n",
		$bosh_exodus_path
	) unless $bosh;

	if (get_options->{connect}) {
		if (in_controlling_terminal) {
			my $call = $::CALL; # Silence single-use warning
			explain "This command is expected to be run in the following manner:";
			explain "  eval \"\$($::CALL)\"";
			explain "";
			explain "This will set the BOSH environment variables in the current shell";
			exit 1;
		}
		my %bosh_envs = $bosh->environment_variables
			unless in_controlling_terminal;
		for (keys %bosh_envs) {
			(my $escaped_value = $bosh_envs{$_}||"") =~ s/"/"\\""/g;
			explain 'export %s="%s"', $_, $escaped_value;
		}
		explain STDERR "Exported environmental variables for BOSH director %s", $bosh->{alias};
		exit 0;
	} else {
		my (undef, $rc) = $bosh->execute({interactive => 1, dir => $ENV{GENESIS_ORIGINATING_DIR}}, @_);
		exit $rc;
	}
}

sub env_shell {
	my %options = (redact => ! -t STDOUT);
	options(\@_, \%options, qw/
		shell|s=s
		no-bosh
		hook|H=s
	/);
	command_usage(1) if @_ != 1;
	
	my $env = Genesis::Top->new('.')->load_env($_[0])->with_vault();
	$env->with_bosh() unless $options{'no-bosh'};
	$env->shell(%options);
}

1;