package Service::BOSH::Director;

use v5.20;
use warnings;
use utf8;

use base 'Service::BOSH';
use Genesis qw(
    trace debug info warning error bail bug dump_stack dump_var
    run lines read_json_from load_yaml load_yaml_file
		save_to_yaml_file mkfile_or_fail copy_or_fail to_yaml
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
use Errno ();

### Class Variables {{{

# One network claims lock owner token per process, keyed by pid
our %NETWORK_LOCK_TOKENS;
# How long a network claims lock write on a kv v1 mount waits before reading itself back
our $NETWORK_LOCK_SETTLE_SECONDS = 2;

# }}}

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

	($exodus_path, $exodus_vault) = $class->_derive_exodus_pointers(
		$alias, $env,
		exodus_path  => $exodus_path,
		exodus_vault => $exodus_vault,
		exodus_mount => $exodus_mount,
		rel_to_env   => $rel_to_env,
		bosh_deployment_type => $opts{bosh_deployment_type},
	);

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
# _derive_exodus_pointers - resolve (exodus_path, exodus_vault) {{{
sub _derive_exodus_pointers {
	my ($class, $alias, $env, %opts) = @_;
	my $exodus_path  = $opts{exodus_path};
	my $exodus_vault = $opts{exodus_vault};
	return ($exodus_path, $exodus_vault) unless $env;

	my $rel_to_env = $opts{rel_to_env} // 'parent';
	my $bosh_env   = $env->bosh_env;

	if (!defined $exodus_path) {
		if ($rel_to_env eq 'self') {
			$exodus_path = $env->exodus_base;
		} else {
			my $mount    = $opts{exodus_mount}
				|| $bosh_env->{exodus_mount} || $env->exodus_mount;
			my $dep_type = $opts{bosh_deployment_type}
				|| $bosh_env->{dep_type} || 'bosh';
			$exodus_path = $mount . $alias . '/' . $dep_type;
		}
	}
	if (!defined $exodus_vault) {
		$exodus_vault = $rel_to_env eq 'self'
			? $env->vault
			: ($bosh_env->{exodus_vault} || $env->vault);
	}
	return ($exodus_path, $exodus_vault);
}

# }}}
# from_alias - create a BOSH director object that uses a local config alias {{{
sub from_alias {
	debug("from_alias called with %d args: [%s]", scalar(@_)-1, join(', ', map {defined($_) ? "'$_'" : 'undef'} @_[1..$#_]));
	my ($class, $alias, $env, %opts) = @_;

	my $config_home = $opts{config_home} || "$ENV{HOME}/.bosh/config";
	return undef unless -f $config_home;
	my $bosh = load_yaml_file($config_home)
		or return;

	bug("from_alias() called without an alias") unless $alias;

	# Derive exodus_path / exodus_vault so callers downstream (e.g.
	# Env::_cap_yaml_file) don't have to special-case alias-built
	# Directors.
	my ($exodus_path, $exodus_vault)
		= $class->_derive_exodus_pointers($alias, $env, %opts);

	for my $e (@{ $bosh->{environments} || []  }) {
		return $class->new(
			$alias,
			env => $env,
			url => $e->{url},
			ca_cert => $e->{ca_cert},
			use_local_config => 1,
			deployment => $opts{deployment},
			exodus_path  => $exodus_path,
			exodus_vault => $exodus_vault,
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

	debug("from_environment: BOSH_ALIAS=%s BOSH_ENVIRONMENT=%s BOSH_CLIENT=%s BOSH_DEPLOYMENT=%s",
		$ENV{BOSH_ALIAS}//'(undef)', $ENV{BOSH_ENVIRONMENT}//'(undef)',
		$ENV{BOSH_CLIENT}//'(undef)', $ENV{BOSH_DEPLOYMENT}//'(undef)');
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
		return $class->from_alias($ENV{BOSH_ALIAS} || $ENV{BOSH_ENVIRONMENT}, undef,
			$ENV{BOSH_DEPLOYMENT} ? (deployment => $ENV{BOSH_DEPLOYMENT}) : ());
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
# alias - specify the name of the bosh director {{{
sub alias {
	return $_[0]->{alias};
}

# }}}
# url - give the full url, including the schema, host and port {{{
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
# director_info - the director's own summary, as `bosh env --json` reports it {{{
#
# Keys: name, uuid, version, director_stemcell, cpi, features, user.
# Populated as a side effect of status(); queried on demand if something asks
# before the director has been contacted.  An unreachable director memoizes an
# empty hash rather than re-querying on every access.
sub director_info {
	my $self = shift;
	$self->status unless defined $self->{director_info};
	$self->{director_info} //= {};
	return $self->{director_info};
}

# }}}
# cpi - the director's latent CPI {{{
sub cpi {
	return $_[0]->director_info->{cpi};
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
		# RISK: the alarm settles the outcome but does not stop bosh -- run()
		#       still waits for the child to exit before this eval unwinds.
		eval {
			local $SIG{ALRM} = sub {die "timeout\n"; };
			alarm $timeout;
			($out,$rc,$err) = $self->execute('env','--json');
			alarm 0;
		};
		alarm 0;
		if ($@ =~ /\Atimeout\n/) { # Carp::Always appends a backtrace
			(my $proxy = $ENV{BOSH_ALL_PROXY}) =~ s/\?.*//; # drop private-key and other options
			return {
				status => 'unreachable',
				msg => sprintf(
					"timed out after %s seconds waiting for %s through proxy %s",
					$timeout, $self->url, $proxy
				)
			};
		}
	} else {
		my $status = tcp_listening($self->{host},$self->{port});
		return {status => 'unreachable', msg => $status} unless ($status eq 'ok');
		($out,$rc,$err) = eval{$self->execute('env','--json')};
	}

	($err,$rc) = ($@,70)if ($@); # 70 is EX_SOFTWARE in sysexits.h,denoting internal software error
	return {status => 'error', msg => $err} if ($rc);
	return {status => 'unauthorized', msg => 'not logged in'} if ($out =~ /\(not logged in\)/);

	# `bosh env --json` transposes its table, so the whole director summary
	# arrives as a single row keyed by snake_cased column titles: name, uuid,
	# version, director_stemcell, cpi, features, user.  Keep the row -- it is
	# the only place the director's latent CPI is reported, and we already
	# paid for the round trip.
	$self->{director_info} = eval {
		read_json_from($out)->{Tables}[0]{Rows}[0]
	} || {};
	return {status => 'unauthorized', msg => 'not logged in'}
		if ($self->{director_info}{user}//'') =~ /not logged in/;
	$self->{user} = $self->{director_info}{user};
	$self->{validated} = 1;
	$ENV{GENESIS_BOSH_VERIFIED} = $self->{alias};
	return {status => 'ok', msg => 'authorized as '.$self->{user}};
}

# }}}
# configs - list all the configurations on the BOSH director {{{
sub configs {
	my ($self, %opts) = @_;
	delete $self->{_configs_cache} if $opts{refresh};
	if (!$self->{_configs_cache}) {
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
		$self->{_configs_cache} = \%configs;
	}
	return wantarray ? %{$self->{_configs_cache}} : $self->{_configs_cache};
}

# }}}
# has_config_of_type - cheap "any configs of $type uploaded?" check {{{
sub has_config_of_type {
	my ($self, $type) = @_;
	return 0 unless defined $type;
	my $configs = $self->configs;
	return (exists($configs->{$type}) && scalar(keys %{$configs->{$type}})) ? 1 : 0;
}
# }}}
# config_names_of - sorted list of CONFIG names for $type {{{
#
# Returns the BOSH `--name=` identifiers (cpi config names, with
# 'default' as the literal default when uploaded without --name).
# See memory:reference-bosh-cpi-terminology -- these are NOT the
# cpi names appearing inside the cpis[] array of a cpi-config.
sub config_names_of {
	my ($self, $type) = @_;
	return () unless defined $type;
	my $configs = $self->configs;
	return () unless exists($configs->{$type});
	return sort keys %{$configs->{$type}};
}
# }}}
# has_config - check if a specific (type, name) configuration is currently active {{{
#
# Derived from the cached configs() listing -- no per-call BOSH
# round-trip.  Returns true when the (type, name) pair appears in
# the listing AND has a current entry (mirrors the prior behavior
# of requiring the id to end with `*`).
sub has_config {
	my ($self, $type, $name) = @_;
	return 0 unless defined $type && defined $name;
	my $configs = $self->configs;
	return 0 unless exists($configs->{$type}) && exists($configs->{$type}{$name});
	return defined($configs->{$type}{$name}{current}) ? 1 : 0;
}
# }}}

# get_config - get the configuration of the given type and name {{{
sub get_config {
	my ($self, $type, $name, %opts) = @_;
	my $key = ($type // '') . '|' . ($name // '');
	$self->{_config_content_cache} //= {};
	delete $self->{_config_content_cache}{$key} if $opts{refresh};
	if (!exists $self->{_config_content_cache}{$key}) {
		my $config_raw = read_json_from(
			$self->execute({interactive => 0}, 'config', "--type=$type", "--name=$name", '--json')
		);
		$self->{_config_content_cache}{$key} =
			$config_raw->{Tables}[0]{Rows}[0]
				? $config_raw->{Tables}[0]{Rows}[0]{content}
				: undef;
	}
	return $self->{_config_content_cache}{$key};
}

# }}}
# download_configs - assemble & deliver BOSH config(s) of the given type {{{
sub download_configs {
	my ($self, $path, $type, $name, %opts) = @_;
	$name ||= '*';
	my $key = "$type|$name";
	$self->{_config_assembly_cache} //= {};

	if ($opts{refresh}) {
		delete $self->{_config_assembly_cache}{$key};
		# Unconditional listing refresh: even when the caller named a
		# specific config, that name could be a fresh upload absent
		# from the cached listing.
		$self->configs(refresh => 1);
	}

	# Build the @configs info list (always returned to caller for
	# their display / use_config registration).
	my @configs;
	if ($name eq '*') {
		for my $cname ($self->config_names_of($type)) {
			my $label = $cname eq "default" ? "default $type config" : "$type config '$cname'";
			push @configs, {type => $type, name => $cname, label => $label};
		}
	} else {
		my $label = $name eq "default" ? "$type config" : "$type config '$name'";
		push @configs, {type => $type, name => $name, label => $label};
	}

	# Cache hit: skip the fetch+merge entirely, just copy the cached
	# assembly into the caller's requested $path.
	if (my $cached = $self->{_config_assembly_cache}{$key}) {
		copy_or_fail($cached, $path);
		return wantarray ? @configs : \@configs;
	}

	# No configs of this type exist on the director.  optional => 1
	# returns empty without writing or bailing (single-iaas envs
	# with no named cpi-configs land here); otherwise preserve the
	# legacy bail.
	if (!@configs) {
		return wantarray ? () : [] if $opts{optional};
		bail(
			"No matching %s configurations defined on '#M{%s}' BOSH director",
			$type, $self->alias
		);
	}

	# Fetch each config's content via the memoized get_config.  If
	# refresh was requested, cascade it through the per-name cache.
	my @config_contents;
	for my $c (@configs) {
		my $content = $opts{refresh}
			? $self->get_config($c->{type}, $c->{name}, refresh => 1)
			: $self->get_config($c->{type}, $c->{name});
		bail("No $c->{label} contents.")
			unless defined($content) && length($content);
		push @config_contents, $content;
	}

	# cpi must concat, not spruce-merge -- see the POD.  BOSH's
	# CpiManifestParser.merge_configs errors on duplicate cpi names;
	# merge-by-name would silently dedupe them.
	my $assembled;
	if ($type eq 'cpi' && @config_contents > 1) {
		my @all_cpis;
		my %seen;        # cpi-name => [cpi-config-name, ...]
		for my $i (0 .. $#config_contents) {
			my $cpi_config_name = $configs[$i]{name};
			my $parsed = eval { load_yaml($config_contents[$i]) } // {};
			my $cpis_arr = $parsed->{cpis};
			next unless ref($cpis_arr) eq 'ARRAY';
			for my $entry (@$cpis_arr) {
				next unless ref($entry) eq 'HASH';
				if (defined(my $cpi_name = $entry->{name})) {
					push @{$seen{$cpi_name}}, $cpi_config_name;
				}
				push @all_cpis, $entry;
			}
		}
		my @dupes = grep { @{$seen{$_}} > 1 } sort keys %seen;
		if (@dupes) {
			bail(
				"Duplicate cpi name(s) found across uploaded cpi configs on '#M{%s}' BOSH director:\n%s\n\n".
				"BOSH will refuse to deploy until the duplicate is resolved (delete the redundant config or rename the cpi entry).",
				$self->alias,
				join("\n", map {
					sprintf("  - #R{%s} appears in: %s", $_,
					        join(', ', map { "#C{$_}" } @{$seen{$_}}))
				} @dupes)
			);
		}
		$assembled = to_yaml({cpis => \@all_cpis});
	} elsif (@config_contents > 1) {
		my ($out, $rc, $err) = run(
			{interactive => 0, stderr=>0},
			'spruce merge --multi-doc --go-patch --fallback-append <(echo "$1")',
			join("\n---\n", @config_contents)
		);
		bail("Failed to converge the active $type configurations: $err") if $rc;
		$assembled = $out;
	} else {
		$assembled = $config_contents[0];
	}

	# Write the assembled output to the director's internal cache
	# path, then copy to the caller's $path.  Subsequent calls for
	# the same (type, name) only pay the copy cost.
	my $cache_path = workdir().'/'.$self->{alias}.'-'.$type.'-'.$name.'-assembled.yml';
	mkfile_or_fail($cache_path, $assembled // '');
	$self->{_config_assembly_cache}{$key} = $cache_path;
	copy_or_fail($cache_path, $path);
	bail(
		"No matching %s configurations defined on '#M{%s}' BOSH director",
		$type, $self->alias
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

	# Invalidate memoized config state for this (type, name): a
	# pre-upload existence probe may have cached a negative content
	# result, and the assembly/listing caches predate this upload.
	delete $self->{_config_content_cache}{($type // '') . '|' . ($name // '')}
		if ref($self->{_config_content_cache}) eq 'HASH';
	if (ref($self->{_config_assembly_cache}) eq 'HASH') {
		delete $self->{_config_assembly_cache}{"$type|$name"};
		delete $self->{_config_assembly_cache}{"$type|*"};
	}
	delete $self->{_configs_cache};

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

	my (undef, $rc) = $self->execute({interactive => 1}, '-n', 'run-errand', $errand);
	bail(
		"Failed to run errand '%s' (%s deployment on '#M{%s}' BOSH director): bosh exited %s",
		$errand, $self->{deployment}, $self->{alias}, $rc
	) if $rc;

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
		# BOSH reports default-cpi stemcells with cpi == '' (defined but
		# empty); normalize both undef and empty to '<default>' so the
		# downstream `in_array('<default>', cpis)` lookup succeeds.
		my $cpi = $stemcell->{cpi};
		$cpi = '<default>' unless defined($cpi) && length($cpi);
		$stemcells{$id} //= {
			id => $id,
			name => $stemcell->{name},
			version => $stemcell->{version} =~ s/^([0-9\.]+).*/$1/r,
			active => $stemcell->{version} =~ m/\*/ ? 1 : 0,
			os => $stemcell->{os},
			cpis => [],
			names => {},
		};
		push @{$stemcells{$id}{cpis}}, $cpi;
		push @{$stemcells{$id}{names}{$stemcell->{name}}}, $cpi;
	}

	return wantarray ? %stemcells : \%stemcells;
}

sub upload_stemcell {
	my ($self, $stemcell, %opts) = @_;
	bug("No stemcell provided in call to upload_stemcell()") unless $stemcell;
	return $stemcell->upload($self, %opts);
}

# cpis - sorted list of CPI names registered with this director {{{
sub cpis {
	my ($self, %opts) = @_;
	delete $self->{_cpis_cache} if $opts{refresh};
	return wantarray ? @{$self->{_cpis_cache}} : $self->{_cpis_cache}
		if $self->{_cpis_cache};

	my $configs = eval { $self->configs } // {};
	my %names;
	for my $config_name (keys %{$configs->{cpi} // {}}) {
		my $yaml = eval { $self->get_config('cpi', $config_name) };
		next unless defined($yaml) && length($yaml);
		my $parsed = eval { load_yaml($yaml) };
		next unless ref($parsed) eq 'HASH' && ref($parsed->{cpis}) eq 'ARRAY';
		for my $entry (@{$parsed->{cpis}}) {
			next unless ref($entry) eq 'HASH' && defined($entry->{name});
			$names{$entry->{name}} = 1;
		}
	}
	$self->{_cpis_cache} = [sort keys %names];
	return wantarray ? @{$self->{_cpis_cache}} : $self->{_cpis_cache};
}

# }}}

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
					push @{ $results{$name}{$release->{'Stemcell OS'}} }, $release->{'Stemcell Version'};
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
# network_lock_path - where the network claims lock for this director is stored {{{
sub network_lock_path {
	my ($self) = @_;
	# A secret of its own, so that a check-and-set write covers the lock and
	# nothing else, and so that rewriting the director's exodus data leaves
	# it alone.
	return $self->exodus_path.'/network-claim-lock';
}

# }}}
# check_network_lock - check for existing network lock {{{
sub check_network_lock {
	my ($self, %opts) = @_;
	my $max_age = $opts{max_lock_age} // 1800; # 30 minutes default

	my $path = $self->network_lock_path;
	my $record = $self->vault->kv_read($path);
	my %found = (
		path       => $path,
		version    => $record->{version},
		kv_version => $record->{kv_version},
	);

	# A released lock leaves a record with no holder in it.
	my $lock = $record->{data};
	return { status => 'unlocked', %found }
		unless ref($lock) eq 'HASH' && defined($lock->{at});

	my ($status, $lock_age) = $self->_network_lock_freshness($lock, $max_age);

	return {
		status => $status,
		lock => $lock,
		age => $lock_age,
		max_age => $max_age,
		%found,
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
	my ($self, %opts) = @_;
	my $path = $self->network_lock_path;

	$self->_refuse_legacy_network_lock($opts{max_lock_age});

	my $lost_race = 0;
	for (1 .. 5) {
		my $current = $self->check_network_lock(%opts);
		$self->_refuse_network_lock($current, $lost_race) if $current->{status} eq 'locked';
		info(
			"Taking over the stale network claims lock on #M{%s} BOSH director (held %s).",
			$self->alias, $current->{description}
		) if $current->{status} eq 'stale';

		my $lock = {
			# UTC, labelled as UTC: POSIX's %z gives the local offset even
			# for a gmtime() value, which made a lock taken west of UTC look
			# hours old, and one taken east of it look hours away.
			at       => strftime('%Y-%m-%d %H:%M:%S +0000', gmtime()),
			hostname => Sys::Hostname::hostname(),
			user     => $ENV{USER} // 'unknown',
			pid      => $$,
			env      => $self->env ? $self->env->name : 'unknown',
			token    => $self->_network_lock_token,
		};

		# kv v2: the write names the version that was just read, so of any
		# number of processes that read the same version, only the first to
		# write gets the lock.  Any other is refused by the vault, and reads
		# again to find out who has it.
		if (($current->{kv_version} // 1) == 2) {
			return $lock if $self->_write_network_lock($path, $lock, $opts{max_lock_age}, cas => $current->{version});
			$lost_race = 'cas';
			next;
		}

		# kv v1 has no check-and-set.  A process that read the lock as free
		# before this write landed writes its own just after it, so wait long
		# enough for that write to land too, and then read back: whichever
		# write landed last holds the lock, and every other writer sees that
		# it lost.  It narrows the race rather than closing it, since a writer
		# slower than the wait can still land after the read-back.
		$self->_warn_network_lock_not_atomic($current);
		$self->_write_network_lock($path, $lock, $opts{max_lock_age});
		select(undef, undef, undef, $NETWORK_LOCK_SETTLE_SECONDS)
			if $NETWORK_LOCK_SETTLE_SECONDS > 0;
		my $now = $self->check_network_lock(%opts);
		return $lock if ($now->{lock}{token} // '') eq $lock->{token};
		$self->_refuse_network_lock($now, 'readback') if $now->{status} ne 'unlocked';
		bail(
			"Wrote the network claims lock for the #M{%s} BOSH director to #C{%s} in ".
			"the vault at #M{%s}, but reading it back a moment later found no lock at all.\n\n".
			"Either another process released the lock in that moment, or the vault ".
			"target is a standby node whose reads lag the leader.  Nothing holds the ".
			"lock now, so running the command again is safe; if this keeps happening, ".
			"point the vault target at the cluster leader.",
			$self->alias, $path, $self->vault->url
		);
	}

	bail(
		"Could not take the network claims lock on the #M{%s} BOSH director: the lock ".
		"record at #C{%s} in the vault at #M{%s} changed between every read and write ".
		"in five attempts.\n\n".
		"This usually means several deploys or #C{bosh-configs upload} runs against ".
		"this director are taking and releasing the lock in quick succession.  Wait ".
		"for them to finish and try again, and check #C{safe get %s} to see who holds ".
		"it now.",
		$self->alias, $path, $self->vault->url, $path
	);
}
# }}}

# network_locked_by_me - check if the current network lock is held by this process {{{
sub network_locked_by_me {
	my ($self) = @_;
	my $lock_status = $self->check_network_lock();
	return 0 if $lock_status->{status} eq 'unlocked';
	return ($lock_status->{lock}{token} // '') eq $self->_network_lock_token ? 1 : 0;
}
# }}}

# clear_network_lock - release the network claims lock, or clear a stale one {{{
sub clear_network_lock {
	my ($self, %opts) = @_;
	my $path = $self->network_lock_path;
	my $expected = $opts{stale};

	for (1 .. 5) {
		my $current = $self->check_network_lock;
		return 0 if $current->{status} eq 'unlocked';

		# Only the lock that was asked about is removed: with no stale lock
		# named, this process's own; with one, that very record.  A lock that
		# has changed hands since is someone else's, and is left alone.
		if ($expected) {
			my $same = defined($current->{version}) && defined($expected->{version})
				? $current->{version} == $expected->{version}
				: JSON::PP->new->canonical->encode($current->{lock})
				  eq JSON::PP->new->canonical->encode($expected->{lock} // {});
			return 0 unless $same;
		} else {
			return 0 unless ($current->{lock}{token} // '') eq $self->_network_lock_token;
		}

		# Released on kv v2 by writing a record with no holder: kv v2 has no
		# check-and-set delete, and a delete would also remove a lock that
		# another process wrote after the read above.
		if (($current->{kv_version} // 1) == 2) {
			return 1 if $self->vault->kv_write($path, {}, cas => $current->{version});
			next;
		}
		# kv v1 refuses a record with no fields, so the lock is deleted instead,
		# with a delete whose refusal is an error rather than a quiet no-op.
		return $self->vault->kv_delete($path) ? 1 : 0;
	}

	bail(
		"Could not clear the network claims lock on the #M{%s} BOSH director: the lock ".
		"record at #C{%s} in the vault at #M{%s} changed between every read and write ".
		"in five attempts.\n\n".
		"This usually means several deploys or #C{bosh-configs upload} runs against ".
		"this director are taking and releasing the lock in quick succession.  Check ".
		"#C{safe get %s} to see who holds it now.",
		$self->alias, $path, $self->vault->url, $path
	);
}
# }}}

# ensure_network_lock_held - stop unless this process still holds the network claims lock {{{
sub ensure_network_lock_held {
	my ($self, $action) = @_;
	if ($self->network_locked_by_me) {
		# An older Genesis that started after this process took its lock never
		# looks at that lock, so the older key is looked at again here, right
		# before the write the lock is for.  This narrows the window in which
		# both write claims; it cannot close it, because an older Genesis can
		# still take its own lock the moment after this check.
		$self->_refuse_legacy_network_lock(undef, $action);
		return 1;
	}

	my $now = $self->check_network_lock;
	my $path = $now->{path} // $self->network_lock_path;
	my $holder = $now->{status} eq 'unlocked'
		? "and nothing holds it now"
		: sprintf("and it is now held by another process, locked %s", $now->{description} // 'by another process');
	bail(
		"Cannot %s on the #M{%s} BOSH director: this process no longer holds the ".
		"network claims lock, %s.\n\n".
		"This usually means this process waited, most often at a prompt, for longer ".
		"than the lock's stale timeout, and another deploy or #C{bosh-configs upload} ".
		"cleared the lock as stale.  Genesis stopped before it could %s, so that it ".
		"would not overwrite what the other process is doing.  Run the command again ".
		"once the other process has finished.  The lock is stored at #C{%s}, and ".
		"#C{safe get %s} shows who holds it.",
		$action, $self->alias, $holder, $action, $path, $path
	);
}
# }}}

# release_network_lock - release the network claims lock if this process holds it, logging rather than dying on failure {{{
sub release_network_lock {
	my ($self) = @_;
	my $stage = 'read';

	# A terminal sends Ctrl-C and Ctrl-\ to every process in its foreground
	# group, and a hung-up ssh session sends HUP to all of them, which includes
	# the safe processes this release runs.  A signal that kills one of those
	# fails the release and leaves the lock on the director.  The signals are
	# blocked here, which the processes started below inherit, so they stay
	# pending in this process until the release is over, and then reach the
	# handler the caller installed, which runs after the release has finished.
	my $blocked = POSIX::SigSet->new(POSIX::SIGINT(), POSIX::SIGTERM(), POSIX::SIGHUP(), POSIX::SIGQUIT());
	my $before = POSIX::SigSet->new;
	POSIX::sigprocmask(POSIX::SIG_BLOCK(), $blocked, $before);

	my $released = eval {
		my $cleared = 0;
		if ($self->network_locked_by_me) {
			$stage = 'release';
			info({pending => 1}, "[[  - >>releasing network claims lock on #M{%s} BOSH director...", $self->alias);
			# The lock can change hands between the check and the clear, and
			# then it is someone else's to keep.
			$cleared = $self->clear_network_lock ? 1 : 0;
			info($cleared ? "#G{done}" : "#Y{no longer held by this process}");
		}
		$cleared;
	};
	my $failure = $@;
	POSIX::sigprocmask(POSIX::SIG_SETMASK(), $before);
	return $released if defined($released);
	$@ = $failure;

	# A failed release must not replace the error that stopped the caller,
	# nor stop it releasing locks on other directors, so it is logged here.
	my $err = ($@ // '') =~ s/\e\[[0-9;]*m//gr =~ s/^\s*\[FATAL\]\s*//mgr =~ s/\s+$//r;
	if ($stage eq 'read') {
		# Nothing was deleted, and nothing is known: this process may hold the
		# lock or may not, so the lock itself is what to look at.
		error(
			"The network claims lock on the #M{%s} BOSH director could not be read, so ".
			"it is not known whether this process holds it: %s\n\n".
			"If it does, other deploys on this director will wait for it until it goes ".
			"stale, which is 30 minutes after it was taken, or sooner once this process ".
			"has exited when they run on this same host.  This usually means the vault ".
			"became unreachable or sealed, or the token expired.  Check with #C{safe vault ".
			"status}, then #C{safe get %s} shows the lock; it is this process's if it names ".
			"host %s and pid %s, and #C{safe rm %s} clears it.",
			$self->alias, $err, $self->network_lock_path,
			Sys::Hostname::hostname(), $$, $self->network_lock_path
		);
		return undef;
	}
	error(
		"The network claims lock on the #M{%s} BOSH director could not be released: %s\n\n".
		"Other deploys on this director will wait for it until it goes stale, which ".
		"is 30 minutes after it was taken, or sooner once this process has exited when ".
		"they run on this same host; the next deploy then offers to clear it.  This ".
		"usually means the vault became unreachable or sealed, or the token expired.  ".
		"Check with #C{safe vault status}, and #C{safe get %s} shows the lock.",
		$self->alias, $err, $self->network_lock_path
	);
	return undef;
}
# }}}

# _write_network_lock - write the lock, saying so when a failure may have left it held {{{
sub _write_network_lock {
	my ($self, $path, $lock, $max_age, %opts) = @_;
	my $written = eval { $self->vault->kv_write($path, $lock, %opts) };
	return $written unless $@;

	my $err = $@;
	# A signal passes through as it came, for the caller's release to handle.
	die $err if $err =~ /^(?:Interrupted by user|Terminated|Hung up|Quit)\b/;
	$err = $err =~ s/\e\[[0-9;]*m//gr =~ s/^\s*\[FATAL\]\s*//mgr =~ s/\s+$//r;
	bail(
		"%s\n\n".
		"This happened while writing the network claims lock for the #M{%s} BOSH ".
		"director.  If the vault accepted the write first, this process may now hold the ".
		"network claims lock.  Genesis releases it as this command exits; if that ".
		"release fails too, the lock goes stale %s minutes after it was taken.  To ".
		"clear it sooner, check that #C{safe get %s} shows host %s and pid %s, then run ".
		"#C{safe rm %s}.",
		$err, $self->alias, int(($max_age // 1800) / 60), $path, $lock->{hostname}, $lock->{pid}, $path
	);
}
# }}}

# _network_lock_freshness - whether a lock record is still held or has gone stale {{{
sub _network_lock_freshness {
	my ($self, $lock, $max_age) = @_;
	my $lock_time = Time::Piece->strptime($lock->{at}, '%Y-%m-%d %H:%M:%S %z');
	my $lock_age = time - $lock_time->epoch;

	my $status = $lock_age > $max_age ? 'stale' : 'locked';

	# Same-host pid-liveness fallback: a lock recorded on this same
	# host whose pid is no longer running can never be released by
	# its owner (eg an interrupted diff, killed process, Ctrl-C), so
	# don't make callers wait out the full $max_age timeout for it.
	# Locks from other hosts can't be checked this way, so those still
	# rely on the age-based timeout above.
	if ($status ne 'stale' && $lock->{pid} && $lock->{hostname}
		&& $lock->{hostname} eq Sys::Hostname::hostname()
		&& !(kill(0, $lock->{pid}) || $!{EPERM})) {
		$status = 'stale';
	}

	return ($status, $lock_age);
}
# }}}

# _refuse_legacy_network_lock - stop while an older Genesis holds the network claims lock {{{
sub _refuse_legacy_network_lock {
	my ($self, $max_age, $action) = @_;
	# Guards against older Genesis versions during a rollout: they keep the
	# lock as JSON in the network-claim-lock key of the exodus secret, and
	# never read the lock's own secret, so each would take its lock without
	# seeing the other's.  This only reads that key, and never changes it.
	my $path = $self->exodus_path;
	my $key = 'network-claim-lock';
	$max_age //= 1800;
	# Said in the refusal as what could not be done: taking the lock when
	# called from the acquire, or the caller's action when this process already
	# holds its own lock.
	my $what = $action // 'take the network claims lock';
	my $appears = $action ? 'appears to have started deploying against it since this process took its lock'
	                      : 'appears to be deploying against it';

	my $record = eval { $self->vault->kv_read($path) };
	if ($@) {
		my $err = $@;
		# A signal passes through as it came, for the caller's release to handle.
		die $err if $err =~ /^(?:Interrupted by user|Terminated|Hung up|Quit)\b/;
		$err = $err =~ s/\e\[[0-9;]*m//gr =~ s/^\s*\[FATAL\]\s*//mgr =~ s/\s+$//r;
		bail(
			"Cannot %s on the #M{%s} BOSH director, because the ".
			"older lock key could not be checked.  An older Genesis, from before the lock ".
			"moved to a secret of its own, keeps it in the #C{%s} key of #C{%s}, and one ".
			"may be deploying against this director now.\n\n".
			"The vault said: %s\n\n".
			"Likely causes are that the vault is sealed or cannot be reached, or that the ".
			"token has no read access on #C{%s}.  Nothing was written.  Run #C{safe get %s:%s} ".
			"with the same token to see which, and #C{safe vault status} to check whether ".
			"the vault is sealed.",
			$what, $self->alias, $key, $path, $err, $path, $path, $key
		);
	}

	my $json = ref($record->{data}) eq 'HASH' ? $record->{data}{$key} : undef;
	return unless defined($json) && $json =~ /\S/;

	my ($lock, $status);
	my $is_lock = eval {
		$lock = JSON::PP->new->decode($json);
		die "not a lock\n" unless ref($lock) eq 'HASH' && defined($lock->{at});
		($status) = $self->_network_lock_freshness($lock, $max_age);
		1;
	};
	my $parse_error = $@;
	# A signal that landed while the value was being read is not a verdict on it
	die $parse_error if !$is_lock && $parse_error =~ /^(?:Interrupted by user|Terminated|Hung up|Quit)\b/;
	return if $is_lock && $status eq 'stale';
	unless ($is_lock) {
		# No older Genesis can have written this, and one reading it would
		# fail on it too, so it holds nothing.
		warning(
			"The #C{%s} key of #C{%s} in the vault at #M{%s} is not a lock record, so ".
			"it is being ignored.  If an older Genesis is not deploying against the ".
			"#M{%s} BOSH director, it can be removed with #C{safe rm -f %s:%s}.",
			$key, $path, $self->vault->url, $self->alias, $path, $key
		);
		return;
	}

	bail(
		"Cannot %s on the #M{%s} BOSH director: an older ".
		"Genesis %s.  It holds the older form of the ".
		"lock, the #C{%s} key of #C{%s} in the vault at #M{%s}, and was taken by ".
		"%s@%s (env: %s, pid: %s) %s, at %s.\n\n".
		"This usually means someone is running a Genesis from before the lock moved ".
		"to a secret of its own, in a deploy or a #C{bosh-configs upload} against this ".
		"director that is still running or is waiting at a prompt.  Wait for it to ".
		"finish, then try again.  If no such process is running, a crashed run left ".
		"the lock behind, and it goes stale %s minutes after it was taken (or as soon ".
		"as its process exits, when that ran on this same host).  #C{safe get %s:%s} ".
		"shows the lock as it is stored, and once you have checked that nothing is ".
		"deploying, #C{safe rm -f %s:%s} clears it.",
		$what, $self->alias, $appears, $key, $path, $self->vault->url,
		$lock->{user} // 'unknown', $lock->{hostname} // 'unknown',
		$lock->{env} // 'unknown', $lock->{pid} // 'unknown',
		strfuzzytime($lock->{at}), $lock->{at},
		int($max_age / 60), $path, $key, $path, $key
	);
}
# }}}

# _network_lock_token - what marks a network claims lock as this process's own {{{
sub _network_lock_token {
	# Keyed by pid, so a forked child never passes for its parent.
	return $NETWORK_LOCK_TOKENS{$$} //= join('-',
		Sys::Hostname::hostname(), $$, time, sprintf('%08x', int(rand(0xffffffff)))
	);
}
# }}}

# _refuse_network_lock - stop, naming who holds the network claims lock {{{
sub _refuse_network_lock {
	my ($self, $current, $lost_race) = @_;
	my $lock = $current->{lock};
	my $max_minutes = int(($current->{max_age} // 1800) / 60);

	my $race = !$lost_race ? ''
		: $lost_race eq 'cas'
			? "  Another process took it between this process's check of the lock and ".
			  "its write; the vault's check-and-set write let only one of them have it."
			: "  Another process wrote the lock at about the same moment as this one, ".
			  "and its write is the one that stayed.  The lock is on a kv v1 mount, ".
			  "which has no check-and-set write, so this process found out by reading ".
			  "the lock back.";
	bail(
		"Cannot take the network claims lock on the #M{%s} BOSH director: it is held ".
		"by %s@%s (env: %s, pid: %s), who took it %s, at %s.%s\n\n".
		"The lock is stored at #C{%s} in the vault at #M{%s}.  This usually means ".
		"another deploy, or a #C{bosh-configs upload}, against this director is ".
		"running now or is waiting at a prompt.  Wait for it to finish, then try ".
		"again.  If no such process is running, the lock goes stale %s minutes after ".
		"it was taken (or as soon as its process exits, when that runs on this same ".
		"host), and the next deploy offers to clear it.  #C{safe get %s} shows the ".
		"lock as it is stored.",
		$self->alias, $lock->{user} // 'unknown', $lock->{hostname} // 'unknown',
		$lock->{env} // 'unknown', $lock->{pid} // 'unknown',
		strfuzzytime($lock->{at}), $lock->{at}, $race,
		$current->{path}, $self->vault->url, $max_minutes, $current->{path}
	);
}
# }}}

# _warn_network_lock_not_atomic - say once that a kv v1 mount makes the lock best-effort {{{
my %_warned_not_atomic;
sub _warn_network_lock_not_atomic {
	my ($self, $current) = @_;
	return if $_warned_not_atomic{$current->{path}}++;
	warning(
		"The network claims lock for the #M{%s} BOSH director is stored at #C{%s}, on ".
		"a kv v1 mount, which has no check-and-set write.  Taking it is therefore not ".
		"atomic: this process writes the lock, waits %s seconds, and reads it back to ".
		"confirm that it still holds it.  That catches a competing deploy that wrote in ".
		"the meantime, but not one slower than the wait.  Keeping exodus on a kv v2 ".
		"mount makes the lock atomic.",
		$self->alias, $current->{path}, $NETWORK_LOCK_SETTLE_SECONDS
	);
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
# }}}
1;
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
