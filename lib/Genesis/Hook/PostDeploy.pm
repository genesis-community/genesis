package Genesis::Hook::PostDeploy;
use strict;
use warnings;

use parent qw(Genesis::Hook);

use Genesis;
use Genesis::Term qw/in_controlling_terminal/;
use Service::Credhub;
use Time::HiRes qw/gettimeofday/;

sub init {
	my ($class, %ops) = @_;
	my @missing = grep {!defined($ops{$_})} qw/env rc/;
	bug(
		"Missing required arguments for a perl-based kit hook call: %s",
		join(", ", @missing)
	) if @missing;
	
	my $obj = $class->SUPER::init(%ops);
	return $obj;
}

sub deploy_successful {
	return $_[0]->{rc} == 0;
}

# upload_user_credentials_to_uaa - upload user credentials to UAA after BOSH director deployment {{{
sub upload_user_credentials_to_uaa {
	my ($self) = @_;
	my $env = $self->env;
	
	# Only upload credentials for BOSH director deployments
	return unless $env->is_bosh_director;
	
	# Only proceed if user credentials are configured
	return unless $ENV{BOSH_USER} && $ENV{BOSH_PASSWORD};
	
	my $user = $ENV{BOSH_USER};
	my $password = $ENV{BOSH_PASSWORD};
	
	trace("Uploading user credentials to UAA: user=%s", $user);
	
	# Create both username/password and client credentials with same values
	# This maintains compatibility with Genesis's preference for client credentials
	my $bosh = $env->get_target_bosh({self => 1});
	
	eval {
		# Create UAA user account
		$self->_create_uaa_user($bosh, $user, $password);
		
		# Create UAA client with same credentials
		$self->_create_uaa_client($bosh, $user, $password);
		
		info("Successfully uploaded user credentials to UAA: %s", $user);
	};
	if ($@) {
		warning("Failed to upload user credentials to UAA: %s", $@);
	}
}

# _create_uaa_user - create a UAA user account {{{
sub _create_uaa_user {
	my ($self, $bosh, $username, $password) = @_;
	
	# Use BOSH CLI to create UAA user (requires admin access)
	my ($out, $rc, $err) = $bosh->execute(
		{interactive => 0},
		'run-errand', 'configure-uaa',
		'--var', "username=$username",
		'--var', "password=$password"
	);
	
	if ($rc) {
		bail("Failed to create UAA user $username: $err");
	}
	
	trace("Created UAA user: %s", $username);
}

# _create_uaa_client - create a UAA client with same credentials {{{
sub _create_uaa_client {
	my ($self, $bosh, $client_id, $client_secret) = @_;
	
	# Use BOSH CLI to create UAA client
	my ($out, $rc, $err) = $bosh->execute(
		{interactive => 0},
		'run-errand', 'configure-uaa-client',
		'--var', "client_id=$client_id",
		'--var', "client_secret=$client_secret"
	);
	
	if ($rc) {
		bail("Failed to create UAA client $client_id: $err");
	}
	
	trace("Created UAA client: %s", $client_id);
}

sub update_director_network_config {
	my $self = shift;
	my $env = $self->env;

	return unless $env->can_build_cloud_configs;

	# Run the director-cloud-config hook to generate and apply the cloud-config
	$env->notify("generating the Network space for the BOSH Director");
	info({pending => 1}, "[[  - >>building director cloud-config...");
	my $tstart = gettimeofday;
	my ($config, $network) = $env->run_hook('cloud-config', purpose => 'director');
	info("#G{done}" . pretty_duration(gettimeofday - $tstart, 5, 10));

	# FIXME: Do a check and compare, and ask if different (or just do it if $BOSH_NON_INTERACTIVE is set)
	# or at least show the diff (maybe too late to ask if bosh is already deployed)
	#
	info({pending => 1}, "[[  - >>uploading #c{%s.%s.director} cloud-config...", $env->name, $env->type);
	my $bosh = $env->get_target_bosh({self => !$env->use_create_env});
	my $config_name = join('.',$env->name, $env->type, 'director');
	$tstart = gettimeofday;
	$bosh->upload_config($config, 'cloud', $config_name);
	info("#G{done}" . pretty_duration(gettimeofday - $tstart, 5, 10));

	# Check if network has changes, and if so, show them and store them in exodus
	
	info({pending => 1}, "[[  - >>storing director network details in exodus...");
	$tstart = gettimeofday;
	$env->vault->set_path($env->exodus_base.'/network', $network, flatten => 1, clear => 1);
	info("#G{done}" . pretty_duration(gettimeofday - $tstart, 1, 3));
}

sub command {
	my $self = shift;
	my @cmd = ($ENV{GENESIS_CALL_ENV} ||$ENV{GENESIS_CALL});
	for my $arg (@_) {
		$arg = "'$arg'" if ($arg =~ / \(\)!\*\?/);
		push @cmd, $arg;
	}
	return join(" ", @cmd);
}

sub help {
	my ($self, %addons) = @_;

	if ($self->can('cmd_details')) {
		info (
			"\n#Gu{%s}\n[[  >>%s\n",
			$self->{label}, join("\n[[  >>", split("\n",$self->cmd_details()))
		);
		return 1;
	}

	# FIXME: The code below is not being called yes, so may contain errors:
	# - the passed in %addons does not seem compatible with the code below
	#   due to the includsion of $addons{$cmd} already containing the help
	#   output.

	# Loook for any extended addon hooks
	my @module_files = glob($self->kit->path("hooks/addon-*.pm"));
	foreach my $file (@module_files) {
		my $class = $self->load_hook_module($file, $self->kit);
		next unless $class && $class->can('cmd_details');
		my ($cmd) = $file =~ m{addon-(.*)\.pm};
		$addons{"$cmd"} = $class->cmd_details() // 'No help available';
	}

	unless (keys %addons) {
		info "No addons are defined for the %s kit.", $self->env->kit->id;
		return 0
	}

	my ($label, $short, $msg);
	info "The following addons are defined for the %s kit:", $self->env->kit->id;

	foreach my $cmd (sort keys %addons) {
		$label = $cmd =~ s/([^~]*).*/$1/r;
		$short = $cmd =~ s/([^~]*)(~(.*))?/$3/r;
		$short = "|$short" if $short;
		info(
			"\n  #Gu{%s%s}\n[[    >>%s",
			$label, $short, join("\n[[    >>", split("\n",$addons{$cmd}))
		);
	}
}

sub upload_director_cpi_config {
	# This will setup the default director config for the environment.
	my $self = shift;
	my $credhub_prefix = "/cpi-config/properties/";
	if ($self->cpi_enabled && $self->env->has_hook('cpi-config')) {
		$self->env->notify("providing custom cpi-config to the BOSH director");
		info({pending => 1}, "[[  - >>building director cpi-config...");
		my $tstart = gettimeofday;
		my ($config, $secrets, $errors) = $self->env->run_hook(
			'cpi-config', credhub_prefix => $credhub_prefix
		);
		if ($errors) {
			info("#G{failed}" . pretty_duration(gettimeofday - $tstart, 2, 5));
			error("Errors were found in the cpi-config: %s", $errors);
			return 0;
		}
		info("#G{done}" . pretty_duration(gettimeofday - $tstart, 2, 5));

		# FIXME: Determine if there is already a cpi and show differences

		my $bosh = $self->env->get_target_bosh({self => 1});
		my $config_name = join('.',$self->env->cpi_name, 'director');
		info({pending => 1},
			"[[  - >>uploading base CPI config to #M{%s} bosh director...",
			$self->env->name
		);
		$tstart = gettimeofday;
		my ($out, $rc, $err) = $bosh->upload_config($config, 'cpi', $config_name);
		if ($rc) {
			info("#G{failed}" . pretty_duration(gettimeofday - $tstart, 2, 5));
			error("Failed to upload the cpi-config: %s", $err);
			return 0;
		}
		info("#G{done}" . pretty_duration(gettimeofday - $tstart, 2, 5));

		$self->_commit_config_credhub_secrets($secrets);
	}	
}

sub upload_stemcells {
	# This will upload the stemcells to the director.  If non-interactive, it will upload the latest stemcell
	# for the IaaS.  If interactive, it will ask the user to select a stemcell to upload.

	# RISK: This assumes that the kit is a bosh director, but doesn't verify it.

	my ($self, %opts) = @_;
	return unless $self->deploy_successful;

	my $env = $self->env;
	my $bosh = $env->get_target_bosh({self => 1});

	$env->notify("checking for stemcells on the BOSH director");
	my @stemcells = values $bosh->stemcells()->%*;
	if (@stemcells) {
		info("[[  - >>found %s on the BOSH director", count_nouns(scalar @stemcells, 'existing stemcell'));
		return 1;
	}

	# If interactive, ask the user if they want to upload a stemcell
	if (in_controlling_terminal && $opts{interactive}) {
		my $answer = prompt_for_boolean(
			"[[  - >>no stemcells found on the BOSH director. Do you want to upload a stemcell? [y|n] ",
			1
		);
		return unless $answer;
	}
	
	# Otherwise, use the Service::BOSH::Stemcell module to upload a suitable stemcell
	my $tstart = gettimeofday;
	info({pending => 1}, "[[  - >>determining available stemcells...");
	my $type_filter = $self->env->lookup('bosh-configs.stemcells.type',undef);
	my @available_stemcells = $bosh->available_stemcells(
		env => $env,
		all => 1,
		type => $type_filter,
	);

	if (!@available_stemcells) {
		info("#R{failed}" . pretty_duration(gettimeofday - $tstart, 2, 5));
		error("No available stemcells found for the IaaS %s", $env->iaas);
		return 0;
	}
	info("#G{done}" . pretty_duration(gettimeofday - $tstart, 2, 5));

	my $selected_stemcell;
	if ($self->{interactive}) {
		require Service::BOSH::Stemcell;
		$selected_stemcell = Service::BOSH::Stemcell->select_stemcell(
			stemcells => \@available_stemcells,
			type => $type_filter
		);
	} else {
		# Select the latest available stemcell
		$selected_stemcell = $available_stemcells[0]; # Latest is always first
	}

	info("[[  - >>uploading first stemcell to BOSH director:");
	
	my $ok = $selected_stemcell->upload(
		$bosh,
		dryrun => $opts{dryrun},
	);

	if (!$ok) {
		error("Failed to upload stemcells!");
		return 0;
	}
	
	notice(
		"\nTo add more stemcells later, run:\n".
		"  #G{%s do upload-stemcells [--os <os>] <version>[... <versionN>]}\n".
		"#Ki{(or run with no arguments to be provided with a list to chose from)}\n",
		scalar $self->env->get_call_path_with_env,
	);
	return 1;
}

sub upload_runtime_configs {
	my ($self, %opts) = @_;
	# TBD: This is a placeholder for the runtime config upload process.
	# Options will consist of the following:
	#   hooks => [hashref1, hashref2, ...] - a list of hashes that describee hook-based runtime config deployments, with each containing
	#		 - name: the name of the runtime config
	#		 - args: a list of arguments to pass to the hook
	#		 - TBD: How to tell if the hook should run or not, or if a given option should be used.
	# This will upload the runtime configs to the director.
}

sub results {
	return 1;
}

sub _commit_config_credhub_secrets {
	my ($self, $secrets) = @_;
	my @paths = keys %{$secrets || {}};
	return 1 unless @paths;

	my $bosh = $self->env->get_target_bosh({self => 1});
	my $credhub = Service::Credhub->from_bosh($bosh);
	my $start = gettimeofday;
	info({pending => 1},
		"[[  - >>entombing %s secrets into #M{%s} BOSH director's credhub...",
		scalar @paths,
		$self->env->name
	);
	for my $path (@paths) {
		my $secret = $secrets->{$path};
		bail("No value specified for the secret %s", $path) unless $secret;
		# FIXME: set supports ($out, $rc, $err) model so we can check for errors
		# directly instead of capturing bails in an eval block.
		eval {$credhub->set($path, $secrets->{$path})};
		my $err = $@;
		if ($err) {
			info("#G{failed}" . pretty_duration(gettimeofday - $start, 2, 5));
			bail("Failed to entomb the secret %s: %s", $path, $err);
		}
	}
	info("#G{done}" . pretty_duration(gettimeofday - $start, 2, 5));
	return 1
}

1;
