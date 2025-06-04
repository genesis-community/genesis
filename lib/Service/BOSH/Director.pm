package Service::BOSH::Director;

use strict;
use warnings;
use utf8;

use base 'Service::BOSH';
use Genesis qw(
    trace debug info error bail bug dump_stack dump_var
    run lines read_json_from load_yaml_file
		save_to_yaml_file mkfile_or_fail
    is_valid_uri tcp_listening workdir
		parse_fixed_width_table by_semver
);
use Genesis::State qw/in_callback envset under_test/;
use Service::Vault;

### Class Methods {{{

# new - raw instantiation of a BOSH director object {{{
sub new {

	my ($class, $alias, %opts) = @_;

	my ($schema,$host,$port) = $opts{url} =~ qr(^(http(?:s?))://(.*?)(?::([0-9]*))?$);

	my $director = {
		schema => $schema,
		host => $host,
		port => $port || 25555,
		url => $opts{url},
		ca_cert => $opts{ca_cert},
		client => $opts{client},
		secret => $opts{secret},
		alias  => $alias,
		deployment => $opts{deployment},
		use_local_config => $opts{use_local_config},
		user_credentials => $opts{user_credentials},
		validated => ($ENV{GENESIS_BOSH_VERIFIED}||"") eq $alias,
		exodus_vault => $opts{vault} // (Service::Vault->current || Service::Vault->default),
		exodus_path => $opts{exodus_path}//$class->exodus_path($alias, %opts)
	};

	return bless($director, $class);
}

sub has_director {
	return 1;
}

# }}}
# from_exodus - create a new BOSH director object based on exodus data {{{
sub from_exodus {
	my ($class, $alias, %opts) = @_;
	my ($exodus, $exodus_source);
	if ($opts{exodus_data}) {
		$exodus = $opts{exodus_data};
		$exodus_source = 'provided';
	} else {
		$opts{vault} ||= (Service::Vault->current || Service::Vault->default);
		if (!$opts{exodus_path}) {
			$opts{exodus_path} =
				($opts{exodus_mount} || '/secret/exodus/').
				$alias.'/'.
				($opts{bosh_deployment_type} || 'bosh');
		}
		$opts{vault}->connect_and_validate();
		trace("Trying to fetch BOSH director exodus data for '$opts{exodus_path}'");
		$exodus = $opts{vault}->get($opts{exodus_path});
		$exodus_source = sprintf("under #C{%s} on vault #M{%s}", $opts{exodus_path}, $opts{vault}->name);
		unless ($exodus) {
			trace("#R{[ERROR]} No exodus data found %s", $exodus_source);
			return;
		}
	}

	# validate exodus data
	my @missing_keys;
	for (qw(url admin_username admin_password ca_cert kit_name)) {
		push(@missing_keys,$_) unless $exodus->{$_};
	}
	if (@missing_keys) {
		trace(
			"#R{[ERROR]} Exodus data %s does not appear to be for a BOSH deployment:\n".
			"        Missing keys: %s",
			$exodus_source, join(", ", @missing_keys)
		);
		return;
	}
	if ($exodus->{kit_name} ne 'bosh' && ! $exodus->{is_bosh} && ! $exodus->{is_director}) {
		trace(
			"#R{[ERROR]} Exodus data %s does not appear to be for a BOSH deployment:\n".
			"        Kit type is #M{%s}",
			$exodus_source, $exodus->{kit_name}
		);
		return;
	}

	return $class->new($alias,
		url     => $exodus->{url},
		client  => $exodus->{admin_username},
		secret  => $exodus->{admin_password},
		ca_cert => $exodus->{ca_cert},
		deployment => $opts{deployment},
		exodus_path => $opts{exodus_path},
		exodus_vault => $opts{vault},
	);
}

# }}}
# from_alias - create a BOSH director object that uses a local config alias {{{
sub from_alias {
	my ($class, $alias, %opts) = @_;

	my $config_home = $opts{config_home} || "$ENV{HOME}/.bosh/config";
	return undef unless -f $config_home;
	my $bosh = load_yaml_file($config_home)
		or return;

	unless ($alias) {$ENV{GENESIS_TRACE}=1 && dump_stack;}
	for my $e (@{ $bosh->{environments} || []  }) {
		return $class->new(
			$alias,
			url => $e->{url},
			ca_cert => $e->{ca_cert},
			use_local_config => 1,
			deployment => $opts{deployment},
			%opts
		) if $e->{alias} eq $alias;
	}

	return;
}

# }}}
# validate_user_credentials - check if user credentials are available and valid {{{
sub validate_user_credentials {
	my $class = shift;

	debug("Validating user credentials...");
	debug("  BOSH_USER: %s", $ENV{BOSH_USER} ? $ENV{BOSH_USER} : '<not set>');
	debug("  BOSH_PASSWORD: %s", $ENV{BOSH_PASSWORD} ? '<set>' : '<not set>');

	# Check if all required user credentials are present
	my @missing;
	my @validation_errors;

	push @missing, 'BOSH_USER' unless $ENV{BOSH_USER};
	push @missing, 'BOSH_PASSWORD' unless $ENV{BOSH_PASSWORD};

	if (@missing || @validation_errors) {
		my $error_msg = '';
		$error_msg .= "Missing required environment variables: " . join(', ', @missing) if @missing;
		$error_msg .= "; " if @missing && @validation_errors;
		$error_msg .= "Validation errors: " . join('; ', @validation_errors) if @validation_errors;

		trace("User credential validation failed: %s", $error_msg);
		return (0, $error_msg);
	}

	trace("User credentials validation passed: BOSH_USER=%s", $ENV{BOSH_USER});
	debug("User credentials are valid and ready for use");
	return (1, "User credentials validated successfully");
}

# }}}
# detect_user_credentials - prioritize user credentials from environment variables {{{
sub detect_user_credentials {
	my $class = shift;

	debug("Attempting to detect user credentials...");

	# Validate user credentials first
	my ($valid, $msg) = $class->validate_user_credentials();
	if (!$valid) {
		debug("User credential detection failed, falling back to standard environment: %s", $msg);
		return $class->from_environment();
	}

	# Priority 1: User credentials (BOSH_USER/BOSH_PASSWORD)
	info("Using user credentials from environment variables: BOSH_USER=%s", $ENV{BOSH_USER});
	debug("Creating BOSH director with user credentials:");
	debug("  Environment: %s", $ENV{BOSH_ENVIRONMENT});
	debug("  Alias: %s", $ENV{BOSH_ALIAS} || 'user-env');
	debug("  CA Cert: %s", $ENV{BOSH_CA_CERT} ? '<provided>' : '<not provided>');
	debug("  Deployment: %s", $ENV{BOSH_DEPLOYMENT} || '<not set>');

	my $director = $class->new(
		$ENV{BOSH_ALIAS} || 'user-env',
		url => $ENV{BOSH_ENVIRONMENT}, # TODO : Is this the way to get the url?
		client => $ENV{BOSH_USER},  # Use as client for compatibility
		secret => $ENV{BOSH_PASSWORD},
		ca_cert => $ENV{BOSH_CA_CERT},
		deployment => $ENV{BOSH_DEPLOYMENT},
		user_credentials => 1  # Flag to indicate these are user credentials
	);

	debug("Successfully created BOSH director with user credentials");
	return $director;
}

# }}}
# from_environment - create a BOSH director object from current environment variables {{{
sub from_environment {
	my $class = shift;

	# Check for user credentials first (BOSH_USER/BOSH_PASSWORD)
	if (is_valid_uri($ENV{BOSH_ENVIRONMENT}) && $ENV{BOSH_USER} && $ENV{BOSH_PASSWORD}) {
		trace("Using user credentials from environment: BOSH_USER=%s", $ENV{BOSH_USER});
		return $class->new(
			$ENV{BOSH_ALIAS} || 'user-env',
			url => $ENV{BOSH_ENVIRONMENT},
			client => $ENV{BOSH_USER},
			secret => $ENV{BOSH_PASSWORD},
			ca_cert => $ENV{BOSH_CA_CERT},
			deployment => $ENV{BOSH_DEPLOYMENT},
			user_credentials => 1
		);
	}

	# Fall back to client credentials (existing behavior)
	if (is_valid_uri($ENV{BOSH_ENVIRONMENT}) && $ENV{BOSH_CLIENT}) {
		return $class->new(
			$ENV{BOSH_ALIAS},
			url => $ENV{BOSH_ENVIRONMENT},
			client => $ENV{BOSH_CLIENT},
			secret => $ENV{BOSH_CLIENT_SECRET},
			ca_cert => $ENV{BOSH_CA_CERT},
			deployment => $ENV{BOSH_DEPLOYMENT}
		);
	} else {
		return $class->from_alias($ENV{BOSH_ALIAS} || $ENV{BOSH_ENVIRONMENT}, deployment => $ENV{BOSH_DEPLOYMENT});
	}
}

# }}}
# exodus_path - return the exodus path from which the connection details will be read {{{
sub exodus_path {
	my ($class, $alias, %opts) = @_;
	if (ref($class) && $class->isa(__PACKAGE__)) {
		return $class->{exodus_path};
	}
	return $opts{exodus_path} || (
		($opts{exodus_mount} || '/secret/exodus/').
		$alias.'/'.
		($opts{bosh_deployment_type} || 'bosh')
	);
}
# }}}
# }}}

## Instance Methods {{{

# deployment - set or get target deployment {{{
sub deployment {
	my $self = shift;
	$self->{deployment} = shift if @_;
	bug("Too many arguments to Service::BOSH::Director#deployment: expecting at most 1, got extra: ".join(', ',@_))
		if @_;
	return $self->{deployment};
}

# }}}
# alias - specify the name of the bosh director
sub alias {
	return $_[0]->{alias};
}

# }}}
# url - give the full url, including the schema, host and port
sub url {
	my $self = shift;
	return $self->{schema}."://".$self->{host}.":".$self->{port};
}

# }}}
# environment_variables - retrieve BOSH environment variables for this BOSH director {{{
sub environment_variables {
	my ($self) = @_;
	my %envs = (
		BOSH_ALIAS         => $self->{alias},
		BOSH_ENVIRONMENT   => $self->url,
		BOSH_CA_CERT       => $self->{ca_cert},
	);

	# Set credentials based on type
	if ($self->{user_credentials}) {
		# For user credentials, set both formats for compatibility
		$envs{BOSH_USER} = $self->{client};
		$envs{BOSH_PASSWORD} = $self->{secret};
		# Also set client format since Genesis expects these
		$envs{BOSH_CLIENT} = $self->{client};
		$envs{BOSH_CLIENT_SECRET} = $self->{secret};
		trace("Setting environment variables for user credentials: BOSH_USER=%s", $self->{client});
	} else {
		# Standard client credentials
		$envs{BOSH_CLIENT} = $self->{client};
		$envs{BOSH_CLIENT_SECRET} = $self->{secret};
	}

	$envs{BOSH_DEPLOYMENT} = $self->{deployment} if $self->{deployment};
	return %envs;
}

# }}}
# connect_and_validate - connect to the BOSH director and validate access {{{
sub connect_and_validate {
	my ($self) = @_;
	return $self if $self->{validated};
	debug "Checking BOSH at '$self->{alias}' for connectivity";
	my $waiting=0;
	unless (in_callback || envset "GENESIS_TESTING") {;
		info {pending=>1}, "Checking availability of the #M{%s} BOSH director...", $self->{alias};
		$waiting=1;
	}

	my ($status, $msg) = $self->status()->@{qw(status msg)};
	if ($status ne 'ok') {
		error("#R{%s - %s!}\n", $status, $msg) if $waiting;
		dump_stack;
		bail(
			"Unable to connect to #M{%s} BOSH director:\n%s - %s",
			$self->{alias}, $status, $msg
		) if $status =~ /error|unreachable/;
		bail(
			"Unable to connect to #M{%s} BOSH director: no active session.  ".
			"Please log in and try again.",
			$self->{alias}
		) if $status eq 'unauthorized';
	}
	info("#G{%s} - %s", $status, $msg) if $waiting;
	return $self;
}

# }}}
# status - check the status of the BOSH director {{{
sub status {
	my ($self) = @_;
	my ($out, $rc, $err);
	if ($ENV{BOSH_ALL_PROXY}) {
		my $timeout = $ENV{GENESIS_NETWORK_TIMEOUT} || 10;
		eval {
			local $SIG{ALRM} = sub {die "timeout\n"; };
			alarm $timeout;
			($out,$rc,$err) = eval{$self->execute('env')};
			alarm 0;
		};
		my $err = $@ if $@;
		return {
			status => 'unreachable',
			msg => $err eq "timeout\n" ? "timeout after $timeout seconds" : $err
		} if ($err);
	} else {
		my $status = tcp_listening($self->{host},$self->{port});
		return {status => 'unreachable', msg => $status} unless ($status eq 'ok');
		($out,$rc,$err) = eval{$self->execute('env')};
	}

	($err,$rc) = ($@,70)if ($@); # 70 is EX_SOFTWARE in sysexits.h,denoting internal software error
	return {status => 'error', msg => $err} if ($rc);
	return {status => 'unauthorized', msg => 'not logged in'} if ($out =~ /\(not logged in\)/);
	($self->{user}) = $out =~ /^(.*)\z/m;
	$self->{validated} = 1;
	$ENV{GENESIS_BOSH_VERIFIED} = $self->{alias};
	return {status => 'ok', msg => 'authorized as '.$self->{user}};
}

# }}}
# configs - list all the configurations on the BOSH director {{{
sub configs {
	my ($self) = @_;
	my $configs_raw = read_json_from(
		$self->execute({interactive => 0}, 'configs', '-r=99999', '--json')
	);
	my %configs = ();
	for my $config (@{$configs_raw->{Tables}[0]{Rows}}) {
		my ($type, $name) = @{$config}{qw{type name}};
		my ($id, $current) = $config->{id} =~ m/^(\d+)(\*)?$/;
		$configs{$type}{$name} //= {'current' => undef, 'entries' => {}};
		$configs{$type}{$name}{'current'} = $id if $current;
		$configs{$type}{$name}{'entries'}{$id} = {
			date => $config->{"created_at"},
			team => $config->{"team"},
		}
	}
	return wantarray ? %configs : \%configs;
}
# has_config - check if a configuration exists on the BOSH director {{{
sub has_config {
	my ($self, $type, $name) = @_;
	my $config_raw = read_json_from(
		$self->execute({interactive => 0}, 'configs', '-r=1', "--type=$type","--name=$name",'--json')
	);
	return ($config_raw->{Tables}[0]{Rows}[0]{name}||'') eq $name
	    && ($config_raw->{Tables}[0]{Rows}[0]{type}||'') eq $type
	    && ($config_raw->{Tables}[0]{Rows}[0]{id}||'') =~ m/^\d+\*?$/;
}
# }}}

# get_config - get the configuration of the given type and name {{{
sub get_config {
	my ($self, $type, $name) = @_;
	my $config_raw = read_json_from(
		$self->execute({interactive => 0}, 'config', "--type=$type", "--name=$name", '--json')
	);
	return $config_raw->{Tables}[0]{Rows}[0]{content} if $config_raw->{Tables}[0]{Rows}[0];
	return undef;
}

# }}}
# download_confgs - download configuration(s) of the given type (and optional name) {{{
sub download_configs {
	my ($self, $path, $type, $name) = @_;
	$name ||= '*';

	my @configs;
	if ($name eq '*') {
		# FIXME:
		# There is a bug here that all the cloud config names are pointing to the same merged file.  It would
		# be better if each separate cloud config got its own file, and then also provide a .../merged-cloud.yml
		# file that contains the merged contents of all the cloud configs.
		my ($out,$rc,$err) = $self->execute({interactive => 0},
			'configs -r=1 --type="$1" --json | jq -r \'.Tables[0].Rows[]| {"type": .type, "name": .name}\' | jq -sMc',
			$type
		);

		my $configs_list = eval {JSON::PP::decode_json($out) unless $rc};
		chomp(my $json_err = $@ || '');
		if ($rc || $json_err) {
			$json_err =~ s/ at lib\/Genesis\/BOSH.*//sm if $json_err;
			$err ||= $json_err || "bosh configs returned exit code $rc";
			bail("Could not determine available #C{$type} configurations: $err");
		}

		for (@$configs_list) {
			my $label = $_->{name} eq "default" ? "base $_->{type} config" : "$_->{type} config '$_->{name}'";
			push @configs, {type => $_->{type}, name => $_->{name}, label => $label};
		}
	} else {
		my $label = $name eq "default" ? "$type config" : "$type config '$name'";
		push @configs, {type => $type, name => $name, label => $label};
	}

	my @config_contents;
	for (@configs) {
		my ($out,$rc,$err) = $self->execute({ interactive => 0},
			'config', "--type=$_->{type}", "--name=$_->{name}", '--json'
		);

		my $json = eval {JSON::PP::decode_json($out) unless $rc};
		chomp(my $json_err = $@ || '');
		if ($rc || $json_err) {
			$json_err =~ s/ at lib\/Genesis\/BOSH.*//sm if $json_err;
			$err ||= $json_err || "bosh configs returned exit code $rc";
			bail("Could not determine available #C{$type} configurations: $err");
		}

		if ($rc || $json_err) {
			my $msg = $err;
			$msg = "#R{$json_err:}\n\n\e[36m$out\e[0m" if ($json_err && !$msg);
			$msg ||= join("\n", grep {$_ !~ /^Exit code/} grep {$_ !~ /^using environment/} @{$json->{Lines}});
			$msg ||= "Could not understand 'BOSH config' json output:\n\n\e[36m$out\e[0m";
			$msg = "No $_->{label} found" if $msg eq 'No config';
			bail $msg;
		}

		bug("BOSH returned multiple entries for $_->label - Genesis doesn't know how to process this")
			if (@{$json->{Tables}} != 1 || @{$json->{Tables}[0]{Rows}} != 1);

		my $config = $json->{Tables}[0]{Rows}[0]{content};

		bail "No $_->{label} contents." unless $config;
		push @config_contents, $config;
	}
	my $config;
	if (scalar(@config_contents) > 1) {
		($config, my $rc, my $err) = run(
			{interactive => 0, stderr=>0},
			'spruce merge --multi-doc --go-patch --fallback-append <(echo "$1")',
			join("\n---\n", @config_contents)
		);
		bail("Failed to converge the active $type configurations: $err") if $rc;
	} else {
		$config = $config_contents[0]
	}
	mkfile_or_fail($path,$config || "");
	bail(
		"No matching $type configurations defined on '#M{%s}' BOSH director", $self->alias
	) unless (-s $path);
	return wantarray ? @configs : \@configs;
}

# }}}
# upload_config - upload a configuration to the BOSH director {{{
sub upload_config {
	my ($self, $config, $type, $name, $confirm) = @_;
	$name ||= 'default';
	my $path = workdir() . "/$name-$type.yml";
	if (ref($config)) {
		save_to_yaml_file($config, $path);
	} else {
		mkfile_or_fail($path, $config);
	}
	$self->upload_config_from_file($path, $type, $name, $confirm);
}

sub upload_config_from_file {
	my ($self, $path, $type, $name, $confirm) = @_;
	$name ||= 'default';
  local $ENV{BOSH_NON_INTERACTIVE} = undef;
	my @commands = (
		'update-config', "--type=$type", "--name=$name", $path
	);
	push @commands, '-n' unless $confirm;
	my ($out, $rc, $err) = $self->execute({interactive => $confirm}, @commands);
	bail(
		"Failed to upload %s configuration to '#M{%s}' BOSH director: %s",
		$name, $self->alias, $err
	) if $rc && !wantarray;
	return wantarray ? ($out, $rc, $err) : $rc ? 0 : 1;
}

sub delete_config {
	my ($self, $type, $name, $confirm) = @_;
	local $ENV{BOSH_NON_INTERACTIVE} = undef;
	my @commands = ('delete-config', "--type=$type", "--name=$name");
	push @commands, '-n' unless $confirm;
	my ($out, $rc, $err) = $self->execute({interactive => $confirm}, @commands);
	bail(
		"Failed to delete %s configuration from '#M{%s}' BOSH director: %s",
		$name, $self->alias, $err
	) if $rc;
	return 1;
}


# }}}
# deploy - deploy the given manifest as the deployment {{{
sub deploy {
	my ($self, $manifest, %opts) = @_;

	$opts{flags} ||= [];
	push(@{$opts{flags}}, "-l", $opts{vars_file}) if ($opts{vars_file});

	bug("No deployment name provided for BOSH Director in call to deploy()")
		unless $self->deployment;

	bug("Missing manifest in call to deploy()")
		unless $manifest;

	return $self->execute( {interactive => 1},
		'deploy', @{$opts{flags}}, $manifest
	);
}

# }}}
# run_errand - run an errand against the BOSH deployment {{{
sub run_errand {
	my ($self, $errand) = @_;

	bug("No deployment name provided for BOSH Director in call to run_errand()")
		unless $self->deployment;

	bug("Missing errand name in call to deploy()")
		unless $errand;

	$self->execute(
		{ interactive => 1, onfailure => "Failed to run errand '$errand' ($self->{deployment} deployment on $self->{alias} BOSH director)" },
		'-n', 'run-errand', $errand
	);

	return 1;
}

# }}}
# stemcells - list the present stemcells on the BOSH director {{{
sub stemcells {
	my %stemcells;
	my $stemcell_rows = read_json_from(
		$_[0]->execute('stemcells', '--json')
	)->{Tables}[0]{Rows};
	for my $stemcell (@$stemcell_rows) {
		my $id = sprintf('%s@%s', $stemcell->{os}, $stemcell->{version}) =~ s/\*$//r;
		my $cpi = $stemcell->{cpi} // '<default>';
		$stemcells{$id} //= {
			id => $id,
			name => $stemcell->{name},
			version => $stemcell->{version} =~ s/^([0-9\.]+).*/$1/r,
			active => $stemcell->{version} =~ m/\*/ ? 1 : 0,
			os => $stemcell->{os},
			cpis => []
		};
		push @{$stemcells{$id}{cpis}}, $cpi if $cpi;
	}

	return wantarray ? %stemcells : \%stemcells;
}

sub upload_stemcell {
	my ($self, $stemcell, %opts) = @_;
	bug("No stemcell provided in call to upload_stemcell()") unless $stemcell;
	return $stemcell->upload($self, %opts);
}

# }}}
# vault - returns the vault object used to fetch exodus data {{{
sub vault {
	return $_[0]->{exodus_vault};
}

# }}}
# deployments - list the deployments on the BOSH director {{{
sub deployments {
	my $deployment_rows = read_json_from($_[0]->execute('deployments','--json'))->{Tables}[0]{Rows};
	my $deployments = {};
	for my $deployment (@$deployment_rows) {
		# Clean up
		my $name = $deployment->{name};
		$deployments->{$name} = {
			releases  => [split(/\n/, $deployment->{release_s} // '')],
			stemcells => [split(/\n/, $deployment->{stemcell_s} // '')],
			teams     => [split(/\n/, $deployment->{team_s} // '')],
		}
	}
	return $deployments
}

sub has_deployment {
	my ($self, $deployment) = @_;
	my $deployments = $self->deployments;
	return exists $deployments->{$deployment};
}

# }}}
# delete_deployment - delete the deployment from the BOSH director {{{
sub delete_deployment {
	my ($self, %opts) = @_;

	my $deployment = $self->deployment or
		bug("No deployment name provided for BOSH Director in call to delete()");

	my @cmd = ('delete-deployment');
	push @cmd, '--force' if $opts{force};
	push @cmd, '-d', $deployment;

	if ($opts{dryrun}) {
		$self->dryrun_of(@cmd);
		return wantarray ? (undef, 0, undef) : 1;
	}

	my ($out, $rc, $err) = $self->execute({interactive => 1}, @cmd);
	return wantarray ? ($out, $rc, $err) : !$rc;
}

# }}}
# cleanup - cleanup the BOSH director {{{
sub cleanup {
	my ($self, %opts) = @_;

	my @cmd = ('clean-up');
	push @cmd, '--all' if $opts{all};
	push @cmd, '--keep-orphaned-disks' if $opts{'keep-orphaned-disks'};

	if ($opts{dryrun}) {
		my ($out, $rc, $err) =  $self->dryrun_of(
			{
				exec_msg => 'the removal of the following resources',
				execute => [qw/--dry-run --tty/],
				interactive => 0
			}, @cmd
		);

    if (under_test and $out =~ /^bosh/) {
      print $out."\n";
      return $rc ? 0 : 1;
    }

		# Parse the output into something more consumable
		my $new_output = '';
		my $blocks = [split(/\n\n/, $out)];
		my $unused_releases = {};
		shift @$blocks if $blocks->[0] !~ /^Unused/; # RISK: Assumes the first usable block starts with 'Unused'
		while (@$blocks) {
			my $category = shift @$blocks;
			last if $category eq 'Succeeded';
			my $contents = [split(/\n/, shift @$blocks)];
			my $header = shift @$contents;
			my $table = parse_fixed_width_table($header, @$contents);
			next unless @$table;

			my %results = ();
			my $last_name = '';
			my $name_length = 0;
			$new_output .= "\n#Wku{$category:}\n";
			if ($category =~ /^Unused (Releases|Stemcells)$/) {
				for my $release (@$table) {
					my $name = $release->{Name};
					if ($name eq '~') {
						$name = $last_name;
					} else {
						$last_name = $name;
						$name_length = length($name) if length($name) > $name_length;
					}
					push @{$results{$name}}, $release->{Version};
				}
				$name_length += 2; # for the ': '
				for my $name (sort keys %results) {
					my $versions = $results{$name};
					my $version_string = join(', ', sort by_semver @$versions);
					$new_output .= sprintf(
						"[[  #c{%-${name_length}s}>>%s\n", "$name: ", $version_string
					);
				}
			} elsif ($category =~ /^Unused Compiled Packages$/) {
				for my $release (@$table) {
					my $name = $release->{Name};
					if ($name eq '~') {
						$name = $last_name;
					} else {
						$last_name = $name;
						$name_length = length($name) if length($name) > $name_length;
					}
					push @{$results{$name}{$release->{'Stemcell OS'}}}, $release->{'Stemcell Version'};
				}

				$name_length += 2; # for the ': '
				for my $name (sort keys %results) {
					my $stemcells = $results{$name};
					my @stemcell_blocks = ();
					for my $stemcell (sort keys %$stemcells) {
						my $versions = $stemcells->{$stemcell};
						my $version_string = join(', ', sort by_semver @$versions);
						push @stemcell_blocks, sprintf(
							"#m{%s} #Ki{(%s)}", $stemcell, $version_string
						);
					}
					$new_output .= sprintf(
						"[[  #c{%-${name_length}s}>>%s\n",
						$name.': ',
						join("; ", @stemcell_blocks)
					);
				}
			} else {
				$new_output .= "  $header\n".join("\n", map { "  $_" } @$contents)."\n";
			}
		}
		if ($new_output) {
			info $new_output;
		} else {
			info "\n#Gi{No unused resources found!}";
		}
		return wantarray ? ($new_output, $rc, $err) : !$rc;
	}

	my ($out, $rc, $err) = $self->execute({interactive => 1},@cmd);
	return wantarray ? ($out, $rc, $err) : !$rc;
}
# }}}

# synchronize_credentials - ensure both user and client credential formats work {{{
sub synchronize_credentials {
	my ($self) = @_;

	# If this director was created with user credentials, ensure both formats are synchronized
	if ($self->{user_credentials}) {
		trace("Synchronizing user and client credential formats for: %s", $self->{client});

		# Both BOSH_USER/BOSH_PASSWORD and BOSH_CLIENT/BOSH_CLIENT_SECRET should work
		# This is already handled in environment_variables method
		return {
			user_format => {
				user => $self->{client},
				password => $self->{secret}
			},
			client_format => {
				client => $self->{client},
				secret => $self->{secret}
			},
			synchronized => 1
		};
	}

	return {
		synchronized => 0,
		message => "Director not using user credentials"
	};
}

# supports_user_credentials - check if this director instance supports user credentials {{{
sub supports_user_credentials {
	my ($self) = @_;
	return $self->{user_credentials} || 0;
}

# get_credential_type - return the type of credentials being used {{{
sub get_credential_type {
	my ($self) = @_;
	return $self->{user_credentials} ? 'user' : 'client';
}

# }}}
1
# vim: fdm=marker:foldlevel=1:noet
