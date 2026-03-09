package Service::BOSH::Director;

use v5.20;
use warnings;
use utf8;

use base 'Service::BOSH';
use Genesis qw(
    trace debug info error bail bug dump_stack dump_var
    run lines read_json_from load_yaml_file
		save_to_yaml_file mkfile_or_fail
    is_valid_uri tcp_listening workdir
		parse_fixed_width_table by_semver
		strfuzzytime
);
use Genesis::State qw/in_callback envset under_test/;
use Service::Vault;
use POSIX qw(strftime);
use Time::Piece;
use JSON::PP ();
use Sys::Hostname ();
use File::Basename qw(basename);

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
		env => $opts{env},
		ca_cert => $opts{ca_cert},
		client => $opts{client},
		secret => $opts{secret},
		alias  => $alias,
		deployment => $opts{deployment},
		use_local_config => $opts{use_local_config},
		validated => ($ENV{GENESIS_BOSH_VERIFIED}||"") eq $alias,
		exodus_vault => $opts{exodus_vault} // (Service::Vault->current || Service::Vault->default),
		exodus_path => $opts{exodus_path},
		rel_to_env => $opts{target} || 'parent',
	};

	return bless($director, $class);
}

sub has_director {
	return 1;
}

# }}}
# from_exodus - create a new BOSH director object based on exodus data {{{
sub from_exodus {
	my ($class, $alias, $env, %opts) = @_;
	my ($exodus, $exodus_path, $exodus_mount, $exodus_vault, $rel_to_env)
		= @opts{qw(exodus_data exodus_path exodus_mount exodus_vault rel_to_env)};

	bail(
		"Require an env object - was not passed in",
	) unless $env && ref($env) eq 'Genesis::Env';

	my $bosh_env = $env->bosh_env;
	if (!defined($exodus_path)) {
		if ($rel_to_env eq 'self') {
			$exodus_path //= $env->exodus_base;
		} else { # default is parent
			$exodus_mount //= $bosh_env->{exodus_mount} || $env->exodus_mount;
			$exodus_path = $exodus_mount . $alias.'/'.($opts{bosh_deployment_type} || $bosh_env->{dep_type} || 'bosh');
		}
	}
	if (!defined($exodus_vault)) {
		$exodus_vault = $rel_to_env eq 'self'
			? $env->vault
			: ($bosh_env->{exodus_vault} || $env->vault);
	}

	my $exodus_source //= 'provided';
	if (!$exodus) {
		$exodus_vault->connect_and_validate();
		trace("Trying to fetch BOSH director exodus data for '$exodus_path'");
		$exodus = $exodus_vault->get($exodus_path);
		$exodus_source = sprintf("under #C{%s} on vault #M{%s}", $exodus_path, $exodus_vault->name);
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
	my $has_director_service = $exodus->{services} && grep { $_ eq 'director' } split(/,/, $exodus->{services});
	if ($exodus->{kit_name} ne 'bosh' && ! $exodus->{is_bosh} && ! $exodus->{is_director} && ! $has_director_service) {
		trace(
			"#R{[ERROR]} Exodus data %s does not appear to be for a BOSH deployment:\n".
			"        Kit type is #M{%s}",
			$exodus_source, $exodus->{kit_name}
		);
		return;
	}

	my ($user, $pw);
	if ($env->user_provided_bosh_creds_policy ne 'ignore') {
		if (exists($ENV{BOSH_USER}) && exists($ENV{BOSH_PASSWORD})) {
			$user = $ENV{BOSH_USER};
			$pw = $ENV{BOSH_PASSWORD};
		} elsif ($env->user_provided_bosh_creds_policy eq 'require') {
			bail(
				"Must provide BOSH credentials via environment variables BOSH_USER and BOSH_PASSWORD"
			);
		}
	}

	return $class->new($alias,
		env     => $env,
		url     => $exodus->{url},
		client  => $user || $exodus->{admin_username},
		secret  => $pw || $exodus->{admin_password},
		ca_cert => $exodus->{ca_cert},
		deployment => $opts{deployment},
		exodus_path => $exodus_path,
		exodus_vault => $exodus_vault,
	);
}

# }}}
# from_alias - create a BOSH director object that uses a local config alias {{{
sub from_alias {
	my ($class, $alias, $env, %opts) = @_;

	my $config_home = $opts{config_home} || "$ENV{HOME}/.bosh/config";
	return undef unless -f $config_home;
	my $bosh = load_yaml_file($config_home)
		or return;

	unless ($alias) {$ENV{GENESIS_TRACE}=1 && dump_stack;}
	for my $e (@{ $bosh->{environments} || []  }) {
		return $class->new(
			$alias,
			env => $env,
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
# from_environment - create a BOSH director object from current environment variables {{{
sub from_environment {
	my $class = shift;

	# REFACTOR: FOR THIS TO BE EFFECTIVE:
	# 1. We need to export variables that will allow us to create the env object that bosh needs
	#    We have GENESIS_ROOT and GENESIS_ENVIRONMENT, so that should allow us to create the env object
	#
	# 2. We need to indicate if we want the self or parent BOSH director

	if (is_valid_uri($ENV{BOSH_ENVIRONMENT}) && $ENV{BOSH_CLIENT}) {
		return $class->new(
			$ENV{BOSH_ALIAS},
			env => undef,
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
# exodus_vault - return the exodus vault from which the connection details will be read {{{
sub exodus_vault {
	bail("No exodus vault set for BOSH director") unless $_[0]->{exodus_vault};
	return $_[0]->{exodus_vault};
}

# }}}
# exodus_path - return the exodus path from which the connection details will be read {{{
sub exodus_path {
	bail("No exodus path set for BOSH director") unless $_[0]->{exodus_path};
	return $_[0]->{exodus_path};
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
# host - return the host of the BOSH director {{{
sub host {
	my $self = shift;
	# TODO: should we use bosh env command to get this, or is that just a
	# reflection of the url we already have?
	return $self->{host};
}

# }}}
# environment_variables - retrieve BOSH environment variables for this BOSH director {{{
sub environment_variables {
	my ($self) = @_;
	my %envs = (
		BOSH_ALIAS         => $self->{alias},
		BOSH_ENVIRONMENT   => $self->url,
		BOSH_CA_CERT       => $self->{ca_cert},
		BOSH_CLIENT        => $self->{client},
		BOSH_CLIENT_SECRET => $self->{secret},
		BOSH_REL_TO_ENV    => $self->{rel_to_env} || 'parent',
		BOSH_USER          => undef,
		BOSH_PASSWORD      => undef,
	);
	# Only set exodus variables if exodus_path is configured
	if ($self->{exodus_path} && $self->{exodus_vault}) {
		$envs{BOSH_EXODUS_PATH} = $self->exodus_path;
		$envs{BOSH_EXODUS_VAULT} = $self->exodus_vault->build_descriptor;
	} else {
		debug "Skipping BOSH_EXODUS_PATH and BOSH_EXODUS_VAULT environment variables (exodus_path and/or exodus_vault not set)";
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
	my @commands = $type eq 'runtime'
		? ('update-runtime-config', "--name=$name", $path) # runtime configs needs to do it this ways to upload releases
		: ('update-config', "--type=$type", "--name=$name", $path);
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

# check_network_lock - check for existing network lock {{{
sub check_network_lock {
	my ($self, %opts) = @_;
	my $lock_key = 'network-claim-lock';
	my $max_age = $opts{max_lock_age} // 1800; # 30 minutes default

	my $existing_lock_json = eval { $self->vault->get($self->exodus_path, $lock_key) };
	return { status => 'unlocked' } unless $existing_lock_json;

	my $lock = JSON::PP->new->decode($existing_lock_json);
	my $lock_time = Time::Piece->strptime($lock->{at}, '%Y-%m-%d %H:%M:%S %z');
	my $lock_age = time - $lock_time->epoch;

	return {
		status => $lock_age > $max_age ? 'stale' : 'locked',
		lock => $lock,
		age => $lock_age,
		description => sprintf(
			"%s by %s@%s (env: %s, pid: %d)",
			strfuzzytime($lock->{at}),
			$lock->{user}, $lock->{hostname},
			$lock->{env}, $lock->{pid}
		)
	};
}
# }}}

# acquire_network_lock - acquire lock for network claim updates {{{
sub acquire_network_lock {
	my ($self) = @_;

	# Check current lock status
	my $lock_status = $self->check_network_lock();
	bail(
		"Cannot acquire network claim lock: it was locked %s.\n",
		$lock_status->{description}
	) unless $lock_status->{status} eq 'unlocked';

	# Acquire the lock
	my $lock_key = 'network-claim-lock';

	my $lock = {
		at       => strftime('%Y-%m-%d %H:%M:%S %z', gmtime()),
		hostname => Sys::Hostname::hostname(),
		user     => $ENV{USER} // 'unknown',
		pid      => $$,
		env      => $self->env ? $self->env->name : 'unknown'
	};

	my $lock_json = JSON::PP->new->encode($lock);
	$self->vault->set($self->exodus_path, $lock_key, $lock_json);
}
# }}}

# network_locked_by_me - check if the current network lock is held by this process {{{
sub network_locked_by_me {
	my ($self) = @_;
	my $lock_status = $self->check_network_lock();
	return 0 if $lock_status->{status} eq 'unlocked';
	return $lock_status->{lock}{pid} == $$
		&& $lock_status->{lock}{hostname} eq Sys::Hostname::hostname()
		&& $lock_status->{lock}{user} eq ($ENV{USER} // 'unknown')
		&& $lock_status->{lock}{env} eq ($self->env ? $self->env->name : 'unknown');
}
# }}}

# clear_network_lock - clear network claim lock {{{
sub clear_network_lock {
	my ($self) = @_;
	$self->vault->clear($self->exodus_path . ':network-claim-lock');
}
# }}}

# run_on_instance - run command on a single instance {{{
sub run_on_instance {
	my ($self, $command, %opts) = @_;
	bug("No command provided in call to run_on_instance()") unless $command;

	my $target = $opts{target};
	bail("No target specified") unless $target;

	# Default to index 0 if only group name provided
	my ($instance_group, $index) = split('/', $target);
	unless (defined($index)) {
		$index = 0;
		debug("No instance index specified for '%s', defaulting to %s/0", $instance_group, $instance_group);
	}
	# TODO: Validate UUID if provided, or convert integer index to UUID

	my $instance = sprintf("%s/%s", $instance_group, $index);
	my $interactive = $opts{interactive} // 0;

	if ($interactive) {
		# Interactive mode: direct streaming, no JSON parsing
		my $err = '';
		my ($out, $rc) = $self->execute(
			{ interactive => 1 },
			'ssh', $instance, '--command', $command
		);
		return { stdout => $out, exit_code => $rc, instance => $instance, interactive => 1 };
	}

	# Non-interactive mode: use --json --results for structured output
	my ($out, $rc, $err) = $self->execute(
		{ interactive => 0, stderr => $opts{stderr} // 0 },
		'ssh', $instance, '--command', $command, '--json', '--results'
	);

	my $json = read_json_from($out, 0, $err); # real rc is inside JSON

	# Extract single instance result from Tables[0].Rows[0]
	my $result = $json->{Tables}[0]{Rows}[0] if $json->{Tables} && @{$json->{Tables}};

	return wantarray ? ($result, $rc, $err) : $result;
}
# }}}

# run_on_instances - run command on multiple instances {{{
sub run_on_instances {
	my ($self, $command, %opts) = @_;
	bug("No command provided in call to run_on_instances()") unless $command;

	# Normalize targets to array ref
	my $targets = ref($opts{targets}) eq 'ARRAY'
		? $opts{targets}
		: defined($opts{targets}) ? [$opts{targets}] : [];

	# Empty targets means all VMs in deployment
	if (!@$targets) {
		debug("No targets specified - running on all VMs in deployment");
		my ($out, $rc, $err) = $self->execute(
			{ interactive => 0, stderr => $opts{stderr} // 0 },
			'ssh', '--command', $command, '--json', '--results'
		);

		my $json = read_json_from($out, $rc, $err);
		return $json->{Tables}[0]{Rows} // [];
	}

	# Run command on each target separately and collect results
	my @all_results;
	for my $target (@$targets) {
		debug("Running command on target '%s'", $target);

		my ($out, $rc, $err) = $self->execute(
			{ interactive => 0, stderr => $opts{stderr} // 0 },
			'ssh', $target, '--command', $command, '--json', '--results'
		);

		my $json = read_json_from($out, $rc, $err);
		my $results = $json->{Tables}[0]{Rows} // [];

		# Add results from this target to accumulated results
		push @all_results, @$results;
	}

	return \@all_results;
}
# }}}

# upload_to_instances - upload file to multiple instances {{{
sub upload_to_instances {
	my ($self, %opts) = @_;

	my $local_path = $opts{local_path};
	bug("No local_path provided in call to upload_to_instances()") unless $local_path;

	# Default remote path to /tmp/<basename>
	my $remote_path = $opts{remote_path} // '/tmp/' . basename($local_path);

	# Normalize targets to array ref
	my $targets = ref($opts{targets}) eq 'ARRAY'
		? $opts{targets}
		: defined($opts{targets}) ? [$opts{targets}] : [];

	bail("No targets specified") unless @$targets;

	# Upload to each target
	my @results;
	for my $target (@$targets) {
		# Default to index 0 if only group name provided
		my ($instance_group, $index) = split('/', $target);
		unless (defined($index)) {
			$index = 0;
			debug("No instance index specified for '%s', defaulting to %s/0", $instance_group, $instance_group);
		}

		my $instance = sprintf("%s/%s", $instance_group, $index);
		debug("Uploading '%s' to '%s:%s'", $local_path, $instance, $remote_path);

		my ($out, $rc, $err) = $self->execute(
			{ interactive => $opts{interactive} // 1 },
			'scp', $local_path, "$instance:$remote_path",
			$opts{recursive} ? '--recursive' : ()
		);

		push @results, {
			target => $instance,
			local_path => $local_path,
			remote_path => $remote_path,
			stdout => $out,
			exit_code => $rc,
			stderr => $err
		};
	}

	return \@results;
}
# }}}

# upload_to_instance - alias for upload_to_instances with single target {{{
sub upload_to_instance {
	my ($self, %opts) = @_;
	# Convert single target to targets array
	$opts{targets} = delete($opts{target}) if $opts{target};
	return $self->upload_to_instances(%opts)->[0];
}
# }}}

# env - return the environment object {{{
sub env {
	return $_[0]->{env};
}

# }}}
1;
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
