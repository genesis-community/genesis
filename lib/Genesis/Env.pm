package Genesis::Env;
use strict;
use warnings;
use utf8;

use Genesis;
use Genesis::Legacy; # but we'd rather not
use Genesis::BOSH;
use Genesis::UI;
use Genesis::IO qw/DumpYAML/;
use Genesis::Vault;

use POSIX qw/strftime/;
use Digest::file qw/digest_file_hex/;
use Time::Seconds;

sub new {
	# Do not call directly, use create or load instead
	my ($class, %opts) = @_;

	# validate call
	for (qw(name top)) {
		bug("No '$_' specified in call to Genesis::Env->new!!")
			unless $opts{$_};
	}

	# drop the YAML suffix
	$opts{name} =~ s/\.yml$//;
	$opts{file} = "$opts{name}.yml";

	# environment names must be valid.
	eval { $class->validate_name($opts{name}) }
		or die "Bad environment name '$opts{name}': $@\n";

	# make sure .genesis is good to go
	die "No deployment type specified in .genesis/config!\n"
		unless $opts{top}->type;

	$opts{__tmp} = workdir;
	return bless(\%opts, $class);
}

sub load {
	my ($class,%opts) = @_;

	for (qw(name top)) {
		bug("No '$_' specified in call to Genesis::Env->load!!")
			unless $opts{$_};
	}

	my $env = $class->new(get_opts(\%opts, qw(name top)));

	bail("#R{[ERROR]} Environment file $env->{file} does not exist.") unless -f $env->path($env->{file});

	bail("#R{[ERROR]} Both #C{kit.features} and deprecated #C{kit.subkits} were found during the environment\n".
			 "build-out using the following files:\n#M{  %s}\n\n".
			 "This can cause conflicts and unexpected behaviour.  Please replace all occurrences of\n".
			 "#C{subkits} with #C{features} under the #C{kit} toplevel key.\n",
			 join("\n  ",$env->actual_environment_files)
	) if ($env->defines('kit.features') && $env->defines('kit.subkits'));

	unless (in_callback || envset("GENESIS_LEGACY")) {
		my ($env_name, $env_key) = $env->lookup(['genesis.env','params.env']);
		bail("\n#R{[ERROR]} Environment file #C{$env->{file}} environment name mismatch: #C{$env_key: $env_name}")
			unless $env->{name} eq $env_name;
		# Deferring Deprecation warning until future version
		# error "\n#Y{[WARNING]} Environment file $env->{file} uses #C{params.env} to specify environment name.\nThis has been moved to #C{genesis.env} -- please update your file to remove this warning.\n"
		# 	if $env_key eq 'params.env' || $env->defines('params.env');
	}

	# reconstitute our kit via top
	my $kit_name = $env->lookup('kit.name');
	my $kit_version = $env->lookup('kit.version');
	$env->{kit} = $env->{top}->local_kit_version($kit_name, $kit_version)
		or bail "Unable to locate v$kit_version of `$kit_name` kit for '$env->{name}' environment.";
	$env->kit->check_prereqs()
		or bail "Cannot use the selected kit.\n";

	my $min_version = $env->lookup(['genesis.min_version','params.genesis_version_min'],'');
	$min_version =~ s/^v//i;
	if ($min_version) {
		if ($Genesis::VERSION eq "(development)") {
			error(
				"#Y{[WARNING]} Environment `$env->{name}` requires Genesis v$min_version or higher.\n".
				"This version of Genesis is a development version and its feature availability cannot\n".
				"be verified -- unexpected behaviour may occur.\n"
			) unless (under_test && !envset 'GENESIS_TESTING_DEV_VERSION_DETECTION');
		} elsif (! new_enough($Genesis::VERSION, $min_version)) {
			bail(
				"#R{[ERROR]} Environment `$env->{name}` requires Genesis v$min_version or higher.\n".
				"You are currently using Genesis v$Genesis::VERSION.\n"
			) unless (under_test && !envset 'GENESIS_TESTING_DEV_VERSION_DETECTION');
		}
	}

	# Check for v2.7.0 features
	unless ($env->kit->feature_compatibility("2.7.0")) {
		bail("#R{[ERROR]} Kit #M{%s} is not compatible with #C{secrets_mount} feature\n".
		     "        Please upgrade to a newer release or remove params.secrets_mount from #M{%s}",
		     $env->kit->id, $env->{file})
			if ($env->secrets_mount ne $env->default_secrets_mount);
		bail("#R{[ERROR]} Kit #M{%s} is not compatible with #C{exodus_mount} feature\n".
		     "        Please upgrade to a newer release or remove params.exodus_mount from #M{%s}",
		     $env->kit->id, $env->{file})
			if ($env->exodus_mount ne $env->default_exodus_mount);
	}

	# determine our vault and secret path
	$ENV{GENESIS_SECRETS_MOUNT} = $env->secrets_mount();
	bail("\n#R{[ERROR]} No vault specified or configured.")
		unless $env->vault;

	return $env;
}

sub create {
	my ($class,%opts) = @_;

	# validate call
	for (qw(name top kit)) {
		bug("No '$_' specified in call to Genesis::Env->create!!")
			unless $opts{$_};
	}

	my $env = $class->new(get_opts(\%opts, qw(name top kit)));

	# environment must not already exist...
	die "Environment file $env->{file} already exists.\n"
		if -f $env->path($env->{file});

	# Setup minimum parameters (normally from the env file) to be able to build
	# the env file.
	$env->{__params} = {
		genesis => {
			env => $opts{name},
			get_opts(\%opts, qw(secrets_path secrets_mount exodus_mount ci_mount root_ca_path credhub_env))}
	};

	# target vault and remove secrets that may already exist
	bail("\n#R{[ERROR]} No vault specified or configured.")
		unless $env->vault;

	if (! $env->kit->uses_credhub) {
		$env->remove_secrets(all => 1) || bail "Cannot continue with existing secrets for this environment";
	}

	## initialize the environment
	if ($env->has_hook('new')) {
		$env->run_hook('new');
	} else {
		Genesis::Legacy::new_environment($env);
	}

	# Load the environment from the file to pick up hierarchy, and generate secrets
	$env = $class->load(name =>$env->name, top => $env->top);
	if (! $env->kit->uses_credhub) {
		if (! $env->add_secrets(verbose=>1)) {
			$env->remove_secrets(all => 1, 'no-prompt' => 1);
			unlink $env->file;
			return undef;
		}
	}
	return $env;
}

sub exists {
	my $env;
	eval { $env = new(@_) };
	return undef unless $env;
	return -f $env->path("$env->{file}");
}


# public accessors
sub name          { $_[0]->{name};   }
sub file          { $_[0]->{file};   }
sub kit           { $_[0]->{kit}    || bug("Incompletely initialized environment '".$_[0]->name."': no kit specified"); }
sub top           { $_[0]->{top}    || bug("Incompletely initialized environment '".$_[0]->name."': no top specified"); }

sub root_ca_path {
	my $self = shift;
	unless (exists($self->{root_ca_path})) {
		$self->{root_ca_path} = $self->lookup('genesis.root_ca_path','');
		$self->{root_ca_path} =~ s/\/$// if $self->{root_ca_path};
	}
	return $self->{root_ca_path};
}

# }}}
sub default_secrets_mount { '/secret/'; }
sub secrets_mount {
	my $self = shift;
	($self->{__secrets_mount} = $self->lookup('genesis.secrets_mount', $self->default_secrets_mount)) =~ s#^/?(.*?)/?$#/$1/#
		unless $self->{__secrets_mount};
	return $self->{__secrets_mount};
}
sub default_secrets_slug {
	(my $p = $_[0]->name) =~ s|-|/|g;
	return $p."/".$_[0]->top->type;
}
sub secrets_slug {
	my $self = shift;
	unless ($self->{__secrets_slug}) {
		my ($secrets_path,$src_key) = $self->lookup(
			['genesis.secrets_path','params.vault_prefix','params.vault'],
			$self->default_secrets_slug
		);
		# Deferring Deprecation warning until future version
		# error "\n#Y{[WARNING]} Environment file $env->{file} uses #C{$src_key} to specify secrets path in Vault.\nThis has been moved to #C{genesis.secrets_path} -- please update your file to remove this warning.\n"
		# 	if defined($src_key) && $src_key ne 'genesis.secrets_path';
		($self->{__secrets_slug} = $secrets_path) =~ s#^/?(.*?)/?$#$1#;
	}
	return $self->{__secrets_slug};
}
sub secrets_base {
	my $self = shift;
	$self->{__secrets_base} = $self->secrets_mount . $self->secrets_slug . '/'
		unless ($self->{__secrets_base});
	return $self->{__secrets_base};
}

sub default_exodus_mount { $_[0]->secrets_mount . 'exodus/'; }
sub exodus_mount {
	my $self = shift;
	($self->{__secrets_exodus_mount} = $self->lookup('genesis.exodus_mount', $self->default_exodus_mount)) =~ s#^/?(.*?)/?$#/$1/#
		unless ($self->{__secrets_exodus_mount});
	return $self->{__secrets_exodus_mount};
}
sub exodus_slug {
	sprintf("%s/%s", $_[0]->name, $_[0]->type);
}

sub exodus_base {
	my $self = shift;
	$self->{__secrets_exodus_base} = sprintf("%s%s", $self->exodus_mount, $self->exodus_slug)
		unless ($self->{__secrets_exodus_base});
	return $self->{__secrets_exodus_base};
}

sub default_ci_mount     { $_[0]->secrets_mount . 'ci/'; }
sub ci_mount {
	my $self = shift;
	($self->{__secrets_ci_mount} = $self->lookup('genesis.ci_mount', $self->default_ci_mount)) =~ s#^/?(.*?)/?$#/$1/#
		unless ($self->{__secrets_ci_mount});
	return $self->{__secrets_ci_mount};
}
sub ci_base {
	my $self = shift;
	$self->{__secrets_ci_base} = sprintf("%s%s/%s/", $self->ci_mount, $self->type, $self->name)
		unless ($self->{__secrets_ci_base});
	return $self->{__secrets_ci_base};
}

sub setup_hook_env_vars {
	my ($self, $hook) = @_;

	$ENV{GENESIS_ROOT}         = $self->path;
	$ENV{GENESIS_ENVIRONMENT}  = $self->name;
	$ENV{GENESIS_TYPE}         = $self->type;
	$ENV{GENESIS_TARGET_VAULT} = $ENV{SAFE_TARGET} = $self->vault->ref;
	$ENV{GENESIS_VERIFY_VAULT} = $self->vault->verify || "";

	# Genesis v2.7.0 Secrets management
	# This provides GENESIS_{SECRETS,EXODUS,CI}_{MOUNT,BASE}
	# as well as GENESIS_{SECRETS,EXODUS,CI}_MOUNT_OVERRIDE
	for my $target (qw/secrets exodus ci/) {
		for my $target_type (qw/mount base/) {
			my $method = "${target}_${target_type}";
			$ENV{uc("GENESIS_${target}_${target_type}")} = $self->$method();
		}
		my $method = "${target}_mount";
		my $default_method = "default_$method";
		$ENV{uc("GENESIS_${target}_MOUNT_OVERRIDE")} = ($self->$method ne $self->$default_method) ? "true" : "";
	}
	$ENV{GENESIS_VAULT_PREFIX} = # deprecated in v2.7.0
	$ENV{GENESIS_SECRETS_PATH} = # deprecated in v2.7.0
	$ENV{GENESIS_SECRETS_SLUG} = $self->secrets_slug;
	$ENV{GENESIS_SECRETS_SLUG_OVERRIDE} = $self->secrets_slug ne $self->default_secrets_slug ? "true" : "";

	# Credhub support
	my ($credhub_src,$credhub_src_key) = $self->lookup(
		['genesis.credhub_env','genesis.bosh_env','params.bosh','genesis.env','params.env']
	);

	my $credhub_path = $credhub_src;
	$ENV{GENESIS_CREDHUB_EXODUS_SOURCE_OVERRIDE} =
		($hook eq 'new' && ($credhub_src_key || "") eq 'genesis.credhub-exodus-env') ?
		$credhub_src : "";
	if ($credhub_src =~ /\/\w+$/) {
		$credhub_path  =~ s/\/([^\/]*)$/-$1/;
	} else {
		$credhub_src .= "/bosh";
		$credhub_path .= "-bosh";
	}
	$ENV{GENESIS_CREDHUB_EXODUS_SOURCE} = $credhub_src;
	$ENV{GENESIS_CREDHUB_ROOT}=sprintf("%s/%s-%s", $credhub_path, $self->name, $self->type);

	unless (grep { $_ eq $hook } qw/new prereqs/) {
		$ENV{GENESIS_REQUESTED_FEATURES} = join(' ', $self->features);
	}
	if ($self->needs_bosh_create_env) {
		$ENV{GENESIS_USE_CREATE_ENV} = 'yes';
	} else {
		$ENV{GENESIS_BOSH_ENVIRONMENT} =
		$ENV{BOSH_ALIAS} = scalar $self->lookup_bosh_target;
		my $bosh = Genesis::BOSH->environment_variables($ENV{BOSH_ALIAS});
		$ENV{$_} = $bosh->{$_} for (keys %$bosh);
		$ENV{BOSH_DEPLOYMENT} = sprintf("%s-%s", $self->name, $self->type);
	}

	$ENV{GENESIS_ENV_ROOT_CA_PATH} = $self->root_ca_path;
}

# delegations
sub type   { $_[0]->top->type; }
sub vault  { $_[0]->top->vault; }

sub path {
	my ($self, @rest) = @_;
	$self->{top}->path(@rest);
}
sub tmppath {
	my ($self, $relative) = @_;
	return $relative ? "$self->{__tmp}/$relative"
	                 :  $self->{__tmp};
}

sub use_cloud_config {
	my ($self, $path) = @_;
	$self->{ccfile} = $path;
	return $self;
}

sub download_cloud_config {
	my ($self) = @_;
	my $ccfile = "$self->{__tmp}/cloud.yml";
	Genesis::BOSH->download_cloud_config($self->bosh_target,$ccfile)
		or die "Could not fetch cloud config from ".$self->bosh_target."\n";
	$self->use_cloud_config($ccfile);
}

sub cloud_config {
	return $_[0]->{ccfile} || '';
}

sub features {
	my ($self) = @_;
	if ($self->defines('kit.features')) {
		return @{ scalar($self->lookup('kit.features')) };
	} else {
		return @{ scalar($self->lookup('kit.subkits', [])) };
	}
}

sub has_feature {
	my ($self, $feature) = @_;
	for my $have ($self->features) {
		return 1 if $feature eq $have;
	}
	return 0;
}

sub needs_bosh_create_env {
	my ($self) = @_;
	return $self->has_feature('proto')      ||
	       $self->has_feature('bosh-init')  ||
	       $self->has_feature('create-env');
}

sub relate {
	my ($self, $them, $common_base, $unique_base) = @_;
	$common_base ||= '.';
	$unique_base ||= '.';
	$them ||= '';

	my @a = split /-/, $self->{name};
	my @b = split /-/, ref($them) ? $them->{name} : $them;
	my @c = (); # common

	while (@a and @b) {
		last unless $a[0] eq $b[0];
		push @c, shift @a; shift @b;
	}
	# now @c contains common tokens (us, west, 1)
	# and @a contains unique tokens (preprod, a)

	my (@acc, @common, @unique);
	for (@c) {
		# accumulate tokens: (us, us-west, us-west-1)
		push @acc, $_;
		push @common, "$common_base/".join('-', @acc).".yml";
	}
	for (@a) {
		# accumulate tokens: (us-west-1-preprod,
		#                     us-west-1-preprod-a)
		push @acc, $_;
		push @unique, "$unique_base/".join('-', @acc).".yml";
	}

	trace("[env $self->{name}] in relate(): common $_") for @common;
	trace("[env $self->{name}] in relate(): unique $_") for @unique;

	return wantarray ? (@common, @unique)
	                 : { common => \@common,
	                     unique => \@unique };
}

sub potential_environment_files {
	my ($self) = @_;

	# ci pipelines need to pull cache for previous envs
	my $env = $ENV{PREVIOUS_ENV} || '';
	return $self->relate($env, ".genesis/cached/$env");
}

sub actual_environment_files {
	my ($self) = @_;

	# only return the constituent YAML files
	# that actually exist on the filesystem.
	return grep { -f $self->path($_) }
		$self->potential_environment_files;
}

sub lookup {
	my ($self, $key, $default) = @_;
	return struct_lookup($self->params, $key, $default);
}

sub lookup_noeval {
	my ($self, $key, $default) = @_;
	my ($unevaled_manifest, undef) = $self-> _manifest(no_eval=>1);
	return struct_lookup($unevaled_manifest, $key, $default);
}

sub manifest_lookup {
	my ($self, $key, $default) = @_;
	my ($manifest, undef) = $self->_manifest(redact => 0);
	return struct_lookup($manifest, $key, $default);
}

sub last_deployed_lookup {
	my ($self, $key, $default) = @_;
	my $last_deployment = $self->path(".genesis/manifests/".$self->{name}.".yml");
	die "No successfully deployed manifest found for $self->{name} environment"
		unless -e $last_deployment;
	my $out = run(
		{ onfailure => "Could not read last deployed manifest for $self->{name}" },
		'spruce json $1', $last_deployment);
	my $manifest = load_json($out);
	return struct_lookup($manifest, $key, $default);
}

sub exodus_lookup {
	my ($self, $key, $default,$for) = @_;
	$for ||= $self->exodus_slug;
	my $path =  $self->exodus_mount().$for;
	debug "Checking if $path path exists...";
	return $default unless $self->vault->has($path);
	debug "Exodus data exists, retrieving it and converting to json";
	my $out;
	eval {$out = $self->vault->get($path);};
	bail "Could not get $for exodus data from the Vault: $@" if $@;

	my $exodus = _unflatten($out);
	return struct_lookup($exodus, $key, $default);
}

sub defines {
	my ($self, $key) = @_;
	my $what = $self->params();

	for (split /\./, $key) {
		return 0 unless exists $what->{$_};
		$what = $what->{$_};
	}
	return 1;
}

sub params {
	my ($self) = @_;
	if (!$self->{__params}) {
		debug("running spruce merge of environment files, without evaluation, to find parameters");
		my $out = run({ onfailure => "Unable to merge $self->{name} environment files", stderr => 0 },
			'spruce merge --skip-eval "$@" | spruce json',
				map { $self->path($_) } $self->actual_environment_files());
		$self->{__params} = load_json($out);
	}
	return $self->{__params};
}

sub _manifest {
	my ($self, %opts) = @_;
	trace "[env $self->{name}] in _manifest(): Redact %s", defined($opts{redact}) ? "'$opts{redact}'" : '#C{(undef)}';
	my $which = $opts{no_eval} ? '__noeval' : $opts{redact} ? '__redacted' : '__unredacted';
	my $path = "$self->{__tmp}/$which.yml";

	trace("[env $self->{name}] in _manifest(): looking for the '$which' cached manifest");
	if (!$self->{$which}) {
		trace("[env $self->{name}] in _manifest(): cache MISS; generating");
		trace("[env $self->{name}] in _manifest(): cwd is ".Cwd::cwd);

		my @merge_files = $self->_yaml_files($opts{no_eval});
		trace("[env $self->{name}] in _manifest(): merging $_") for @merge_files;

		pushd $self->path;
		my $no_eval;
		if ($opts{no_eval}) {
			$no_eval = '--skip-eval';
			debug("running spruce merge of all files, without evaluation or cloudconfig, for parameter dereferencing");
		} else {
			debug("running spruce merge of all files, with evaluation, to generate a manifest");
		}
		my $out = run({
				onfailure => "Unable to merge $self->{name} manifest",
				stderr => "&1",
				env => {
					%{$self->vault->env()},              # specify correct vault for spruce to target
					REDACT => $opts{redact} ? 'yes' : '' # spruce redaction flag
				}
			},
			grep {$_} ('spruce', 'merge', '--go-patch', $no_eval, @merge_files));
		popd;

		debug("saving #W{%s} manifest to $path", $opts{no_eval} ? 'unevaled' : $opts{redact} ? 'redacted' : 'unredacted');
		mkfile_or_fail($path, 0400, $out);
		$self->{$which} = load_yaml($out);
	} else {
		trace("[env $self->{name}] in _manifest(): cache HIT!");
	}
	return $self->{$which}, $path;
}

sub manifest {
	my ($self, %opts) = @_;

	# prune by default.
	trace "[env $self->{name}] in manifest(): Redact %s", defined($opts{redact}) ? "'$opts{redact}'" : '#C{(undef)}';
	trace "[env $self->{name}] in manifest(): Prune: %s", defined($opts{prune}) ? "'$opts{prune}'" : '#C{(undef)}';
	$opts{prune} = 1 unless defined $opts{prune};


	my (undef, $path) = $self->_manifest(redact => $opts{redact});
	if ($opts{prune}) {
		my @prune = qw/meta pipeline params bosh-variables kit genesis exodus compilation/;

		if (!$self->needs_bosh_create_env) {
			# bosh create-env needs these, so we only prune them
			# when we are deploying via `bosh deploy`.
			push(@prune, qw( resource_pools vm_types
			                 disk_pools disk_types
			                 networks
			                 azs
			                 vm_extensions));
		}

		debug("pruning top-level keys from #W{%s} manifest...", $opts{redact} ? 'redacted' : 'unredacted');
		debug("  - removing #C{%s} key...", $_) for @prune;
		return run({
				onfailure => "Failed to merge $self->{name} manifest",
				stderr => "&1",
				env => $self->vault->env # to target desired vault
			},
			'spruce', 'merge', (map { ('--prune', $_) } @prune), $path)."\n";
	} else {
		debug("not pruning #W{%s} manifest.", $opts{redact} ? 'redacted' : 'unredacted');
	}

	return slurp($path);
}

sub write_manifest {
	my ($self, $file, %opts) = @_;
	my $out = $self->manifest(redact => $opts{redact}, prune => $opts{prune});
	mkfile_or_fail($file, $out);
}

sub cached_manifest_info {
	my ($self) = @_;
	my $mpath = $self->path(".genesis/manifests/".$self->name.".yml");
	my $exists = -f $mpath;
	my $sha1 = $exists ? digest_file_hex($mpath, "SHA-1") : undef;
	return (wantarray ? ($mpath, $exists, $sha1) : $mpath);
}

sub vars_file {
	my ($self, $file) = @_;

	# Check if manifest currently has params.variable-values hash, and if so,
	# build a variables.yml file in temp directory and return a path to it
	# (return undef otherwise)

	return $self->{_vars_file} if ($self->{_vars_file} && -f $self->{_vars_file});

	my $vars = $self->manifest_lookup('bosh-variables');
	if ($vars && ref($vars) eq "HASH" && scalar(keys %$vars) > 0) {
		my $vars_file = "$self->{__tmp}/bosh-vars.yml";
		DumpYAML($vars_file,$vars);
		dump_var "BOSH Variables File" => $vars_file, "Contents" => slurp($vars_file);
		return $self->{_vars_file} = $vars_file;
	} else {
		return undef
	}
}

sub _yaml_files {
	my ($self, $no_eval) = @_;
	(my $vault_path = $self->secrets_base) =~ s#/?$##; # backwards compatibility
	my $type   = $self->{top}->type;

	my @cc;
	if ($self->needs_bosh_create_env) {
		trace("[env $self->{name}] in_yaml_files(): IS a create-env, skipping cloud-config");
	} elsif ($no_eval) {
		trace("[env $self->{name}] in_yaml_files(): skipping eval, no need for cloud-config");
	} else {
		trace("[env $self->{name}] in _yaml_files(): not a create-env, we need cloud-config");
		die "No cloud-config specified for this environment\n"
			unless $self->{ccfile};

		trace("[env $self->{name}] in _yaml_files(): cloud-config at $self->{ccfile}");
		push @cc, $self->{ccfile};
	}

	if ($self->kit->feature_compatibility('2.6.13')) {
		mkfile_or_fail("$self->{__tmp}/init.yml", 0644, <<EOF);
---
meta:
  vault: $vault_path
exodus:  {}
genesis: {}
params:  {}
EOF
	} else {
		mkfile_or_fail("$self->{__tmp}/init.yml", 0644, <<EOF);
---
meta:
  vault: $vault_path
exodus: {}
genesis: {}
params:
  env:  (( grab genesis.env ))
  name: (( concat genesis.env || params.env "-$type" ))
EOF
	}

	my $now = strftime("%Y-%m-%d %H:%M:%S +0000", gmtime());
	mkfile_or_fail("$self->{__tmp}/fin.yml", 0644, <<EOF);
---
name: (( concat genesis.env || params.env "-$type" ))
exodus:
  version:     $Genesis::VERSION
  dated:       $now
  deployer:    (( grab \$CONCOURSE_USERNAME || \$USER || "unknown" ))
  kit_name:    (( grab kit.name    || "unknown" ))
  kit_version: (( grab kit.version || "unknown" ))
  vault_base:  (( grab meta.vault ))
EOF
		# TODO: In BOSH refactor, add the bosh director to the exodus data

	return (
		"$self->{__tmp}/init.yml",
		$self->kit_files(1), # absolute
		@cc,
		$self->actual_environment_files(),
		"$self->{__tmp}/fin.yml",
	);
}

sub kit_files {
	my ($self, $absolute) = @_;
	return $self->kit->source_yaml_files($self, $absolute),
}

sub _flatten {
	my ($final, $key, $val) = @_;

	if (ref $val eq 'ARRAY') {
		for (my $i = 0; $i < @$val; $i++) {
			_flatten($final, $key ? "${key}[$i]" : "$i", $val->[$i]);
		}

	} elsif (ref $val eq 'HASH') {
		for (keys %$val) {
			_flatten($final, $key ? "$key.$_" : "$_", $val->{$_})
		}

	} else {
		$final->{$key} = $val;
	}

	return $final;
}

sub _unflatten {
	my ($data, $branch) = @_;

	return $data unless ref($data) eq 'HASH'; # Catchall for scalar data coming in.

	# Data must represent all array elements or all hash keys.
	my ($elements, $keys) = ([],[]);
	push @{($_ =~ /^\[\d+\](?:\.|\[|$)/) ? $elements : $keys}, $_ for (sort keys %$data);
	die("Cannot unflatten data that contains both array elements and hash keys at same level "
		 . ($branch ? "(at $branch)" : "(top level)") ."\n") if @$elements && @$keys;

	if (@$elements) {
		my @a_data;
		for my $k (sort keys %$data) {
			my ($i, $sk) = $k =~ /^\[(\d+)\](?:\.)?([^\.].*)?$/;
			if (defined $sk) {
				die "Array cannot have scalar and non-scalar values (at ${branch}[$i])"
					if defined $a_data[$i] && ref($a_data[$i]) ne 'HASH';
				$a_data[$i]->{$sk} = delete $data->{$k};
			} else {
				die "Array cannot have scalar and non-scalar values (at ${branch}[$i])"
					if defined $a_data[$i];
				$a_data[$i] = delete $data->{$k};
			}
		}
		for my $i (0..$#a_data) {
			$a_data[$i] = _unflatten($a_data[$i], ($branch||"")."[$i]");
		}
		return [@a_data];
	} else {
		my %h_data;
		for my $k (sort keys %$data) {
			my ($pk, $sk) = $k =~ /^([^\[\.]*)(?:\.)?([^\.].*?)?$/;
			if (defined $sk) {
				die "Hash cannot have scalar and non-scalar values (at ".join('.', grep $_, ($branch, "pk")).")"
					if defined $h_data{$pk} && ref($h_data{$pk}) ne 'HASH';
				$h_data{$pk}->{$sk} = delete $data->{$k};
			} else {
				die "Hash cannot have scalar and non-scalar values (at ".join('.', grep $_, ($branch, "pk")).")"
					if defined $h_data{$pk};
				$h_data{$pk} = delete $data->{$k};
			}
		}
		for my $k (sort keys %h_data) {
			$h_data{$k} = _unflatten($h_data{$k}, join('.', grep $_, ($branch, "$k")));
		}
		return {%h_data}
	}
}

sub exodus {
	my ($self) = @_;
	return _flatten({}, undef, scalar($self->manifest_lookup('exodus', {})));
}

sub lookup_bosh_target {
	my ($self) = @_;
	return undef if $self->needs_bosh_create_env;

	my ($bosh, $source,$key);
	if ($bosh = $ENV{GENESIS_BOSH_ENVIRONMENT}) {
			$source = "GENESIS_BOSH_ENVIRONMENT environment variable";

	} elsif (($bosh,$key) = $self->lookup(['genesis.bosh_env','params.bosh','genesis.env','params.env'])) {
			$source = "$key in $self->{name} environment file";

	} else {
		die "Could not find the 'genesis.bosh_env', 'params.bosh', 'genesis.env' or 'params.env' key in $self->{name} environment file!\n";
	}

	return wantarray ? ($bosh, $source) : $bosh;
}

sub bosh_target {
	my ($self) = @_;
	return undef if $self->needs_bosh_create_env;

	unless ($self->{__bosh_target}) {
		my ($bosh, $source) = $self->lookup_bosh_target;

		Genesis::BOSH->ping($bosh)
			or bail("\n#R{[ERROR]} Could not connect to BOSH Director '#M{$bosh}'\n  - specified via $source\n");
		$self->{__bosh_target} = $bosh;
	}

	return $self->{__bosh_target};
}

sub deployment {
	my ($self) = @_;
	if ($self->defines('params.name')) {
		return $self->lookup('params.name');
	}
	return $self->lookup(['genesis.env','params.env']) . '-' . $self->{top}->type;
}

sub has_hook {
	my $self = shift;
	return $self->kit->has_hook(@_);
}

sub run_hook {
	my ($self, $hook, %opts) = @_;
	debug "Started run_hook '$hook'";
	return $self->kit->run_hook($hook, %opts, env => $self);
}

sub deploy {
	my ($self, %opts) = @_;

	$self->write_manifest("$self->{__tmp}/manifest.yml", redact => 0);

	my ($ok, $predeploy_data);
	if ($self->has_hook('pre-deploy')) {
		($ok, $predeploy_data) = $self->run_hook('pre-deploy');
		die "Cannot continue with deployment!\n" unless $ok;
	}

	if ($self->needs_bosh_create_env) {
		debug("deploying this environment via `bosh create-env`, locally");
		$ok = Genesis::BOSH->create_env(
			"$self->{__tmp}/manifest.yml",
			vars_file => $self->vars_file,
			state => $self->path(".genesis/manifests/$self->{name}-state.yml"));

	} else {
		$self->download_cloud_config unless $self->{ccfile};

		my @bosh_opts;
		push @bosh_opts, "--$_"             for grep { $opts{$_} } qw/fix recreate dry-run/;
		push @bosh_opts, "--no-redact"      if  !$opts{redact};
		push @bosh_opts, "--skip-drain=$_"  for @{$opts{'skip-drain'} || []};
		push @bosh_opts, "--$_=$opts{$_}"   for grep { defined $opts{$_} }
		                                          qw/canaries max-in-flight/;

		debug("deploying this environment to our BOSH director");
		$ok = Genesis::BOSH->deploy(
			$self->bosh_target,
			vars_file => $self->vars_file,
			manifest   => "$self->{__tmp}/manifest.yml",
			deployment => $self->deployment,
			flags      => \@bosh_opts);
	}

	# Don't do post-deploy stuff if just doing a dry run
	if ($opts{"dry-run"}) {
		explain "Dry-run deployment complete.  Post-deployment activities will be skipped.";
		return $ok;
	}

	unlink "$self->{__tmp}/manifest.yml"
		or debug "Could not remove unredacted manifest $self->{__tmp}/manifest.yml";

	# bail out early if the deployment failed;
	# don't update the cached manifests
	if (!$ok) {
		$self->run_hook('post-deploy', rc => 1, data => $predeploy_data)
			if $self->has_hook('post-deploy');
		return $ok;
	}

	# deployment succeeded; update the cache
	my $manifest_path=$self->path(".genesis/manifests/$self->{name}.yml");
	$self->write_manifest($manifest_path, redact => 1, prune => 0);
	debug("written redacted manifest to $manifest_path");

	$self->run_hook('post-deploy', rc => 0, data => $predeploy_data)
		if $self->has_hook('post-deploy');

	# track exodus data in the vault
	my $exodus = $self->exodus;
	$exodus->{manifest_sha1} = digest_file_hex($manifest_path, 'SHA-1');
	$exodus->{bosh} = $self->bosh_target || "(none)";
	debug("setting exodus data in the Vault, for use later by other deployments");
	$ok = $self->vault->query(
		{ onfailure => "Successfully deployed, but could not save $self->{name} metadata to the Vault" },
		'rm',  $self->exodus_base, "-f",
		  '--', 'set', $self->exodus_base,
		               map { "$_=$exodus->{$_}" } keys %$exodus);

	return $ok;
}

sub dereferenced_kit_metadata {
	my ($self) = shift;
	return $self->kit->dereferenced_metadata(sub {$self->lookup_noeval(@_)}, 1);
}


# add_secrets - add the required secrets {{{
# Valid options:
#   --verbose: boolean, default is 0
#   --filter: (regex) matching pattern, defaults to /.*/
sub add_secrets {
	my ($self, %opts) = @_;

	#Credhub check
	if ($self->kit->uses_credhub) {
		explain "#Yi{Credhub-based kit - no local secrets generation required}";
		return 1;
	}

	if ($self->has_hook('secrets')) {
		$self->run_hook('secrets', action => 'add')
	} else {
		# Determine secret_store from kit - assume vault for now (credhub ignored)
		my $store = $self->vault->connect_and_validate;
		my $processing_opts = {
			level=>$opts{verbose}?'full':'line'
		};
		my $ok = $store->process_kit_secret_plans(
			'add',
			$self,
			sub{$self->_secret_processing_updates_callback('add',$processing_opts,@_)},
			get_opts(\%opts, qw/filter/)
		);
		return $ok;
	}
}

sub check_secrets {
	my ($self,%opts) = @_;

	#Credhub check
	if ($self->kit->uses_credhub) {
		explain "#Yi{Credhub-based kit - no local secrets validation required}\n";
		return 1;
	}

	if ($self->has_hook('secrets')) {
		$self->run_hook('secrets', action => 'check');
	} else {
		# Determine secret_store from kit - assume vault for now (credhub ignored)
		my $store = $self->vault->connect_and_validate;
		my $action = $opts{validate} ? 'validate' : 'check';
		my $processing_opts = {
			no_prompt => $opts{'no-prompt'},
			level=>$opts{verbose}?'full':'line'
		};
		my $ok = $store->validate_kit_secrets(
			$action,
			$self,
			sub{$self->_secret_processing_updates_callback($action,$processing_opts,@_)},
			get_opts(\%opts, qw/filter fail_on_warn/)
		);
		return $ok;
	}
}

sub rotate_secrets {
	my ($self, %opts) = @_;

	#Credhub check
	if ($self->kit->uses_credhub) {
		explain "#Yi{Credhub-based kit - no local secrets rotation allowed}";
		return 1;
	}

	my $action = $opts{'renew'} ? 'renew' : 'recreate';
	if ($self->has_hook('secrets')) {
		$self->run_hook('secrets', action => $action);
	} else {
		# Determine secret_store from kit - assume vault for now (credhub ignored)
		my $store = $self->vault->connect_and_validate;
		my $processing_opts = {
			no_prompt => $opts{'no-prompt'},
			level=>$opts{verbose}?'full':'line'
		};
		my $ok = $store->process_kit_secret_plans(
			$action.($opts{failed} ? '-failed' : ''),
			$self,
			sub{$self->_secret_processing_updates_callback($action,$processing_opts,@_)},
			get_opts(\%opts, qw/filter no_prompt fail_on_warn/)
		);
		return $ok;
	}
}

sub remove_secrets {
	my ($self, %opts) = @_;

	#Credhub check
	if ($self->kit->uses_credhub) {
		explain "#Yi{Credhub-based kit - no local secrets removal permitted}";
		return 1;
	}

	# Determine secret_store from kit - assume vault for now (credhub ignored)
	my $store = $self->vault->connect_and_validate;
	my @generated_paths;
	if ($opts{all}) { # ignores --failed or --filter (which should have been trapped at the cli parser
		my @paths = $self->vault->paths($self->secrets_base);
		return 2 unless scalar(@paths);

		unless ($opts{'no-prompt'}) {
			die_unless_controlling_terminal "#R{[ERROR] %s", join("\n",
				"Cannot prompt for confirmation to remove all secrets outside a",
				"controlling terminal.  Use #C{-y|--no-prompt} option to provide confirmation",
				"to bypass this limitation."
			);
			explain "#Yr{[WARNING]} This will delete all %s secrets under '#C{%s}', including\n".
			             "          non-generated values set by 'genesis new' or manually created",
				 scalar(@paths), $self->secrets_base;
			while (1) {
				my $response = prompt_for_line(undef, "Type 'yes' to remove these secrets, 'list' to list them; anything else will abort","");
				print "\n";
				if ($response eq 'list') {
					# TODO: check and color-code generated vs manual entries
					my $prefix_len = length($self->secrets_base);
					bullet $_ for (map {substr($_, $prefix_len)} @paths);
				} elsif ($response eq 'yes') {
					last;
				} else {
					explain "\nAborted!\nKeeping all existing secrets under '#C{%s}'.\n", $self->secrets_base;
					return 0;
				}
			}
		}
		waiting_on "Deleting existing secrets under '#C{%s}'...", $self->secrets_base;
		my ($out,$rc) = $self->vault->query('rm', '-rf', $self->secrets_base);
		bail "#R{error!}\n%s", $out if ($rc);
		explain "#G{done}\n";
		return 1;
	}

	if ($self->has_hook('secrets')) {
		$self->run_hook('secrets', action => 'remove');
	} else {
		my $processing_opts = {
			level=>$opts{verbose}?'full':'line'
		};
		my $ok = $store->process_kit_secret_plans(
			'remove'.($opts{failed} ? '-failed' : ''),
			$self,
			sub{$self->_secret_processing_updates_callback('remove',$processing_opts,@_)},
			get_opts(\%opts, qw/filter no_prompt/)
		);
		return $ok;
	}
}

sub _secret_processing_updates_callback {
	my ($self,$action,$opts,$state,%args) = @_;
	my $indent = $opts->{indent} || '  ';
	my $level = $opts->{level} || 'full';
	$level = 'full' unless -t STDOUT;

	$action = $args{action} if $args{action};
	$args{result} ||= '';
	(my $actioned = $action) =~ s/e?$/ed/;
	$actioned = 'found' if $actioned eq 'checked';
	(my $actioning = $action) =~ s/e?$/ing/;

	if ($state eq 'done-item') {
		my $map = { error => "#R{failed!}",
		            'check/ok' =>  "#G{found.}",
		            'validate/ok' =>  "#G{valid.}",
		            'validate/warn' => "#Y{warning!}",
		            ok =>  "#G{done.}",
		            'recreate/skipped' => '#Y{skipped}',
		            skipped => "#Y{exists!}",
		            missing => "#R{missing!}" };
		push(@{$self->{__secret_processing_updates_callback__items}{$args{result}} ||= []},
		     $self->{__secret_processing_updates_callback__item});

		explain $map->{"$action/$args{result}"} || $map->{$args{result}} || $args{result}
			if $args{result} && ($level eq 'full' || !( $args{result} eq 'ok' || ($args{result} eq 'skipped' && $action eq 'add')));

		if ($args{msg}) {
			my @lines = grep {$level eq 'full' || $_ =~ /^\[#[YR]/} split("\n",$args{msg});
			my $pad = " " x (length($self->{__secret_processing_updates_callback__total})*2+4);
			explain "  $pad%s\n", join("\n  $pad", @lines) if @lines;
		}
		waiting_on "\r[2K" unless $level eq 'full';

	} elsif ($state eq 'start-item') {
		$self->{__secret_processing_updates_callback__idx}++;
		my $w = length($self->{__secret_processing_updates_callback__total});
		waiting_on "  [%*d/%*d] #C{%s} #wi{%s} ... ",
			$w, $self->{__secret_processing_updates_callback__idx},
			$w, $self->{__secret_processing_updates_callback__total},
			$args{path},
			$args{label} . ($level eq 'line' ? '' : " - $args{details}");

	} elsif ($state eq 'empty') {
		explain "%s - nothing to %s!\n",
			$args{msg} || "No kit secrets found",
			$action;
		return 1;

	} elsif ($state eq 'abort') {
		error($args{msg}) if $args{msg};
		return;

	} elsif ($state eq 'init') {
		$self->{__secret_processing_updates_callback__start} = time();
		$self->{__secret_processing_updates_callback__total} = $args{total};
		$self->{__secret_processing_updates_callback__idx} = 0;
		$self->{__secret_processing_updates_callback__items} = {};
		my $msg_action = $args{action} || sprintf("%s %s secrets", ucfirst($actioning), $args{total});
		explain "\n%s for #M{%s} under path '#C{%s}':", $msg_action, $self->name, $self->secrets_base;

	} elsif ($state eq 'wait') {
		$self->{__secret_processing_updates_callback__startwait} = time();
		waiting_on "%s ... ", $args{msg};

	} elsif ($state eq 'wait-done') {
		explain("%s #Ki{- %s}",
			$args{result} eq 'ok' ? "#G{done.}" : "#R{error!}",
			Time::Seconds->new(time() - $self->{__secret_processing_updates_callback__startwait})->pretty()
		) if ($args{result} && ($args{result} eq 'error' || $level eq 'full'));
		error("#R{[ERROR]} Encountered error: %s", $args{msg}) if ($args{result} eq 'error');
		waiting_on "\r[2K" unless $level eq 'full';

	} elsif ($state eq 'completed') {
		my @extra_errors = @{$args{errors} || []};
		my $warn_count = scalar(@{$self->{__secret_processing_updates_callback__items}{warn} || []});
		my $err_count = scalar(@{$self->{__secret_processing_updates_callback__items}{error} || []})
			+ scalar(@extra_errors)
			+ ($action =~ /^(check|validate)$/ ?
				scalar(@{$self->{__secret_processing_updates_callback__items}{missing} || []}) : 0);
		explain "%s - Duration: %s [%d %s/%d skipped/%d errors%s]\n",
			$err_count ? "Failed" : "Completed",
			Time::Seconds->new(time() - $self->{__secret_processing_updates_callback__start})->pretty(),
			scalar(@{$self->{__secret_processing_updates_callback__items}{ok} || []}), $actioned,
			scalar(@{$self->{__secret_processing_updates_callback__items}{skipped} || []}),
			$err_count,
			$warn_count ? "/$warn_count warnings" : '';
		return !$err_count;
	} elsif ($state eq 'prompt') {
		my $title = '';
		if ($args{class}) {
			$title = sprintf("\r[2K\n#%s{[%s]} ", $args{class} eq 'warning' ? "Y" : '-', uc($args{class}));
		}
		explain "%s%s", $title, $args{msg};
		die_unless_controlling_terminal "#R{[ERROR] %s", join("\n",
			"Cannot prompt for confirmation to $action secrets outside a",
			"controlling terminal.  Use #C{-y|--no-prompt} option to provide confirmation",
			"to bypass this limitation."
		);
		return prompt_for_line(undef, $args{prompt}, $args{default} || "");
	} elsif ($state eq 'notify') {
		explain $args{msg};
	} else {
		bug "_secret_processing_updates_callback encountered an unknown state '$state'";
	}
}


sub validate_name {
	my ($class, $name) = @_;

	die "names must not be empty.\n"
		if !$name;

	die "names must not contain whitespace.\n"
		if $name =~ m/\s/;

	die "names can only contain lowercase letters, numbers, and hyphens.\n"
		if $name !~ m/^[a-z0-9_-]+$/;

	die "names must start with a (lowercase) letter.\n"
		if $name !~ m/^[a-z]/;

	die "names must not end with a hyphen.\n"
		if $name =~ m/-$/;

	die "names must not contain sequential hyphens (i.e. '--').\n"
		if $name =~ m/--/;

	1; # name is valid
}

1;

=head1 NAME

Genesis::Env

=head1 DESCRIPTION

The Env class represents a single, deployable unit of YAML files in a
Genesis deployment repository / working directory, and wraps up all of the
core rules for dealing with the set as a whole.

To load an existing environment, all you need is the C<Genesis::Top> object
that represents the top of the deployment repository, and the name of the
environment you want:

    use Genesis::Top;
    use Genesis::Env;

    my $top = Genesis::Top->new('.');
    my $env = Genesis::Env->new(
      top  => $top,
      name => 'us-west-1-preprod',
    );

To create a new environment, you need a bit more information.  You also need
to be ready to run through interactive ask-the-user-questions mode, for
things like the `new` hook:

    my $env = Genesis::Env->create(
       top  => $top,
       name => 'us-west-1-preprod',
       kit  => $top->local_kit_version('some-kit', 'latest'),
    );

It can optionally take the following options to modify the default `vault`
behaviour:
  * secrets_mount - the mount point for secrets (default: /secrets/)
  * exodus_mount  - the mount point for exodus data (default: $secrets_mount/exodus)
  * ci_mount      - the mount point for ci secrets (default: $secrets_mount/ci)
  * secrets_path  - the path under the secrets_mount for the environment secrets
                    (defaults to env-name-split-by-hyphens/deployment-type)
  * root_ca_path  - specified a path to a common root CA to sign all otherwise
                    self-signed certificates
  * credhub_env   - used to specify the environment that provides the credhub
                    login credentials (defaults to bosh environment)

You can also avail yourself of the C<new> constructor, which does a lot of
the validation, but won't access the environment files directly:

    my $env = Genesis::Env->new(
       top  => $top,
       name => 'us-west-1-preprod',
    );

=head1 CONSTRUCTORS

=head2 new(%opts)

Create a new Env object without making any assertions about the filesystem.
Usually, this is not the constructor you want.  Check out C<load> or
C<create> instead.

The following options are recognized:

=over

=item B<name> (required)

The name of your environment.  See NAME VALIDATION for details on naming
requirements.  This option is B<required>.

=item B<top> (required)

The Genesis::Top object that represents the root working directory of the
deployments repository.  This is used to fetch things like deployment
configuration, kits, etc.  This option is B<required>.

=item B<secrets_path>

A path in the Genesis Vault, under which secrets for this environment should
be stored.  Normally, you don't need to specify this.  When an environment
is loaded, it will probably be overridden by the operators C<param>s.
Otherwise, Genesis can figure out the correct default value.

=back

Unrecognized options will be silently ignored.

=head2 load(%opts)

Create a new Env object by loading its definition from constituent YAML
files on-disk (by way of the given Genesis::Top object).  If the given
environment does not exist on-disk, this constructor will throw an error
(via C<die>), so you may want to C<eval> your call to it.

C<load> does not recognize additional options, above and beyond those which
are handled by and required by C<new>.

=head2 exists(%opts)

Returns true if the environment defined by the options exist.

=head2 create(%opts)

Create a new Env object by running the user through the wizardy setup of the
C<hooks/new> kit hook.  This often cannot be run unattended, and definitely
cannot be run without access to the Genesis Vault.

If the named environment already exists on-disk, C<create> throws an error
and dies.

C<create> recognizes the following options, in addition to those recognized
by (and required by) C<new>:

=over

=item B<kit> (required)

A Genesis::Kit object that represents the Genesis Kit to use for
provisioning (and eventually deploying) this environment.  This option is
required.

=back

=head1 CLASS FUNCTIONS

=head2 validate_name($name)

Validates an environment name, according to the following rules:

=over

=item 1.

Names must not be empty.

=item 2.

They cannot contain whitespace

=item 3.

They must consist entirely of lowercase letters, numbers, and hyphens

=item 4.

Names must start with a letter, and cannot end with a hyphen

=item 5.

Sequential hyphens (C<-->) are expressly prohibited

=back

=head1 METHODS

=head2 name()

Retrieves the bare environment name (without the file suffix).

=head2 file()

Retrieves the file name of the final environment file.  This is just the
name with a C<.yml> suffix attached.


=head2 deployment()

Retrieves the BOSH deployment name for this environment, which is based off
of the environment name and the root directory repository type (i.e.
C<bosh>, C<concourse>, etc.)


=head2 secrets_path()

Retrieve the Vault secrets_path that this environment should store its secrets
under, based off of either its name (by default) or its C<genesis.secrets_path>
parameter.  Legacy environments may also have this specified by C<params.vault>
or C<params.vault_prefix>

=head2 kit()

Retrieve the Genesis::Kit object for this environment.

=head2 tmppath($relative)

Retrieve a temporary work path the given C<$relative> path for this environment.
If no relative path is given, it returns the temporary root directory.

=head2 type()

Retrieve the deployment type for this Genesis::Kit object.

=head2 path([$relative])

Returns the absolute path to the root directory, with C<$relative> appended
if it is passed.

=head2 use_cloud_config($file)

Use the given BOSH cloud-config (as defined in C<$file>) when merging this
environments manifest.  This must be called before calls to C<manifest()>,
C<write_manifest()>, or C<manifest_lookup()>.

=head2 download_cloud_config()

Download a cloud-config file from the BOSH director, and set the environment
to use it.  This can be used in leiu of C<use_cloud_config>.

=head2 cloud_config

Returns the path to the cloud-config file that has been associated with this
environment or empty string if no cloud-config present.

=head2 relate($them, [$cachedir, [$topdir])

Relates an environment to another environment, and returns the set of
possible YAML files that could comprise the environment.  C<$them> can
either be another Env object, or the name of an environment, as a string.

This method returns either a list of files (in list mode) or a hashref
containing the set of common files and the set of unique files.  Aside from
that, it's actually really hard to explain I<what> it does, without resoring
to examples.  Without further ado:

    my $a = Genesis::Env->new(name => "us-west-1-preprod");
    my @files = $a->relate('us-west-1-prod');

    #
    # returns:
    #   - ./us.yml
    #   - ./us-west.yml
    #   - ./us-west-1.yml
    #   - ./us-west-1-preprod.yml
    #

The real fun begins when you pass a directory prefix as the second argument:

    my $a = Genesis::Env->new(name => "us-west-1-preprod");
    my @files = $a->relate('us-west-1-prod', '.cache');

    #
    # returns:
    #   - .cache/us.yml
    #   - .cache/us-west.yml
    #   - .cache/us-west-1.yml
    #   - ./us-west-1-preprod.yml
    #

Notice that the first three file paths returned are inside of the C<./cache>
directory, since those constituent YAML files are common to both
environments.  This is how the Genesis CI/CD pipelines handle propagation of
environmental changes.

If you pass a third argument, it affects the I<unique set>, YAML files that
only affect the first environment:

    my $a = Genesis::Env->new(name => "us-west-1-preprod");
    my @files = $a->relate('us-west-1-prod', 'old', 'NEW');

    #
    # returns:
    #   - old/us.yml
    #   - old/us-west.yml
    #   - old/us-west-1.yml
    #   - NEW/us-west-1-preprod.yml
    #

In scalar mode, the two sets (I<common> and I<unique>) are returned as array
references under respecitvely named hashref keys:


    my $a = Genesis::Env->new(name => "us-west-1-preprod");
    my $files = $a->relate('us-west-1-prod');

    #
    # returns:
    # {
    #    common => [
    #                './us.yml',
    #                './us-west.yml',
    #                './us-west-1.yml',
    #              ],
    #    unique => [
    #                './us-west-1-preprod.yml',
    #              ],
    # }
    #

Callers can use this to treat the common files differently from the unique
files.  The CI pipelines use this to properly craft the Concourse git
resource watch paths.


=head2 potential_environment_files()

Assemble the list of candidate YAML files that comprise this environment.
Under the hood, this is just a call to C<relate()> with no environment,
which forces everything into the I<unique> set.  See C<relate()> for more
details.

If the C<PREVIOUS_ENV> environment variable is set, it is interpreted as the
name of the Genesis environment that preceeds this one in the piepline.
Files that this environment shares with that one (per the semantics of
C<relate>) will be taken from the C<.genesis/cached/$env> directory, instead
of the top-level.


=head2 actual_environment_files()

Return C<potential_environment_files>, filtered to include only the files
that actually reside on-disk.  Suitable for merging with Spruce!


=head2 kit_files

Returns the source YAML files from the environment's kit, based on the
selected features.  This is a very thin wrapper around Genesis::Kit's
C<source_yaml_files> method.


=head2 params()

Merges the environment files (see C<environment_files>), without evaluating
Spruce operators (i.e. C<--skip-eval>), and then returns the resulting
hashref structure.

This structure can then be interrogated by things like C<defines> and
C<lookup> to retrieve metadata about the environment.

This call is I<memoized>; calling it multiple times on the same object will
not incur additional merges.  If cache coherency is a concern, recreate your
object.


=head2 defines($key)

Returns true of this environment has defined C<$key> in any of its
constituent YAML files.  Multi-level keys should be specified in
dot-notation:

    if ($env->defines('params.something')) {
      # ...
    }

If you need the actual I<values> that the defined key is set to, look at
C<lookup>.


=head2 lookup($key, [$default])

Retrieve the value an environment has set for C<$key> (in any of its files),
or C<$default> if the key hasn't been defined.  If C<$key> is an array
reference, each key in the array is checked until it finds one that has been
defined.  If called in a list context (including inside a function call), it
will return a list of the value, and the matching key (which will be undefined
if no key is found)

    my $v = $env->lookup('kit.version', 'latest');
    print "using version $v...\n";

To get just the found value when calling within a function, wrap the call with
`scalar(...)`:

    debug "Kit name: %s", scalar($env->lookup('kit.name'));

This can be combined with calls to C<defines> to avoid having to specify a
default value when you don't want to:

    if ($env->defines('params.optional')) {
      my $something = $env->lookup('params.optional');
      print "optionally doing $something\n";
    }

Note that you can retrieve complex structures like YAML maps (Perl hashrefs)
and lists (arrayrefs) by not specifying a leaf node:

    my $kit = $env->lookup('kit');
    print "Using $kit->{name}/$kit->{version}\n";

This can be preferable to calling C<lookup> multiple times, and is currently
the only way to pull data out of a list.

If the key is an empty string, it will return the entire data structure.

If default is a code reference, it will be executed and the result will be
returned if and only if the default value is needed (ie no matching key is
found). This allows for short circuit evaluation of the default.

=head2 manifest_lookup($key, [$default])

Similar to C<lookup>, but uses the merged manifest as the source of the data.

=head2 last_deployed_lookup($key, [$default])

Similar to C<lookup>, but uses the last deployed (redacted) manifest for the
environment.  Raises an error if there hasn't been a cached manifest for the
environment.

=head2 exodus_lookup($key, [$default])

Similar to C<lookup>, but uses the exodus data stored in Vault for the
environment.  Raises an error if there hasn't been a successful deployment for
the environment.

=head2 features()

Returns a list (not an arrayref) of the features that this environment has
specified in its C<kit.features> parameter.

=head2 has_feature($x)

Returns true if this environment has activated the feature C<$x> by way of
C<kit.features>.

=head2 needs_bosh_create_env()

Returns true if this environment (based on its activated features) needs to
be deployed via a C<bosh create-env> run, instead of the more normal C<bosh
deploy>.


=head2 manifest_lookup($key, $default)

Like C<lookup()>, except that it considers the entire, unredacted deployment
manifest for the environment.  You must have set a cloud-config via
C<use_cloud_config()> before you call this method.


=head2 manifest(%opts)

Generates the complete manifest for this environment, merging in the
environment definition files with the kit manifest fragments for the
selected features.  The manifest will be cached, effectively memoizing this
method.  You must have set a cloud-config via C<use_cloud_config()> before
you call this method.

The following options are recognized:

=over

=item redact

Redact the manifest, obscuring all secrets that would normally have been
populated from the Genesis Vault.  Redacted and unredacted versions of the
manifest will be memoized separately, to avoid cache coherence issues.

=item prune

Whether or not to prune auxilliary top-level keys from the generated
manifest (redacted or otherwise).  BOSH requires the manifest to be pruned
before it will process it for deployment, since Genesis has to merge in the
active BOSH cloud-config for things like the Spruce (( static_ips ... ))
operator.

You may want to set prune => 0 to get the full manifest, for debugging.

By default, the manifest will be pruned.

=back


=head2 write_manifest($file, %opts)

Write the deployment manifest (as generated by C<manifest>) to the given
C<$file>.  This method takes the same options as the C<manifest> method that
it wraps.  You must have set a cloud-config via C<use_cloud_config()> before
you call this method.

=head2 cached_manifest_info

Returns the path, existance (boolean), and SHA-1 checksum for the cached
redacted deployment manifest.  The SHA-1 sum is undefined if the file does not
exist.

=head2 exodus()

Retrieves the I<Exodus> data that the kit compiled for this environment, and
flatten it so that it can be stuffed into the Genesis Vault.


=head2 bosh_target()

Determine the alias of the BOSH director that Genesis would use to deploy
this environment.  It consults the following, in order:

=over

=item 1.

The C<$GENESIS_BOSH_ENVIRONMENT> variable.

=item 2.

The C<params.bosh> parameter

=item 3.

The C<params.env> parameter

=back

If none of these pan out, this method will die with a suitable error.

Note that if this environment is to be deployed via C<bosh create-env>, this
method will always return C<undef> immediately.

=head2 has_hook($hook)

Returns true if the kit used by this environment has the named hook.

=head2 run_hook($hook, %options)

Runs the kit hook named C<$hook> against this environment, with the given
options.  See C<Genesis::Kit::run_hook> for more details.

=head2 deploy(%opts)

Deploy this environment, to its BOSH director.  If successful, a redacted
copy of the manifest will be saved in C<.genesis/manifests>.  The I<Exodus>
data for the environment will also be extracted and placed in the Genesis
Vault at that point.

The following options are recognized (for non-create-env deployments only):

=over

=item redact

Do (or don't) redact the output of the C<bosh deploy> command.

=item fix

Sets the C<--fix> flag in the call to C<bosh deploy>.

=item recreate

Sets the C<--recreate> flag in the call to C<bosh deploy>.

=item dry-run

Sets the C<--dry-run> flag in the call to C<bosh deploy>.

=item skip-drain => [ ... ]

Sets the C<--skip-drain> flag multiple times, once for each value in the
given arrayref.

=item canaries => ...

Sets the C<--canaries> flag to the given value.

=item max-in-flight => ...

Sets the C<--max-in-flight> flag to the given value.

=back


=head2 add_secrets(%opts)

Adds secrets to the Genesis Vault.  This generally invokes the "secrets"
hook, but can fallback to legacy kit.yml behavior.

The following options are recognized:

=over

=item recreate

This is a recreate, and all credentials should be recreated, not just the
missing one.

=back


=head2 check_secrets()

Checks the Genesis Vault for secrets that the kit defines, but that are not
present.  This runs the "secrets" hook, but also handles legacy kit.yml
behavior.


=head2 rotate_secrets(%opts)

Rotates all non-fixed secrets stored in the Genesis Vault.

The following options are recognized:

=over

=item force

If set to true, all non-fixed credentials will be rotated, not just the
missing ones (which is the default behavior for some reason).

=back

=cut
