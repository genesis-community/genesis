package Genesis::Env;

use v5.20;
use warnings;
use utf8;

use base 'Genesis::Base'; # for _memoize

use Genesis; # We import 50% of the functions provided, so more efficient to just use promiscuous import
use Genesis::State qw/envset under_test in_callback/;
use Genesis::Term qw/csprintf wrap fix_wrap decolorize in_controlling_terminal bullet/;
use Genesis::UI qw/prompt_for_boolean prompt_for_line prompt_for_choice new_prompt_for_choice/;
use Genesis::Commands qw/current_command known_commands/;
use Genesis::Env::ManifestProvider;
use Genesis::Env::Secrets::Plan;

use Genesis::Env::Deployment;

use Service::BOSH::Director;
use Service::BOSH::CreateEnvProxy;
use Service::Vault::Remote;
use Service::Vault::Local;
use Service::Vault::None;
use IPv4;

use Archive::Tar;
use Data::Dumper;
use Digest::SHA qw/sha1_hex sha256_hex/;
use Digest::file qw/digest_file_hex/;
use Encode qw/decode_utf8/;
use File::Basename qw/basename dirname/;
use File::Path qw/rmtree/;
use IO::Compress::Gzip qw/gzip $GzipError/;
use IO::Uncompress::Gunzip qw/gunzip $GunzipError/;
use JSON::PP qw/encode_json decode_json/;
use MIME::Base64 qw/encode_base64 decode_base64/;
use POSIX qw/strftime/;
use Time::Piece;
use Time::Seconds;
use Time::HiRes qw/gettimeofday/;

# Class-level validation cache to avoid re-validating the same file multiple times
# Cache is keyed by absolute file path and stores validation results
my %_validation_cache;

### Class Methods {{{

# new - create a raw Genesis::Env object {{{
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
	my $err = _env_name_errors($opts{name});
	bail("Bad environment name '$opts{name}': %s", $err) if $err;

	# make sure .genesis is good to go
	bail("No deployment type specified in .genesis/config!\n")
		unless $opts{top}->type;

	$opts{__tmp} = workdir('ENV');
	return bless(\%opts, $class);
}

# }}}
# load - return an Genesis::Env object represented by a environment file {{{
sub load {
	my ($class,%opts) = @_;

	bug("No '$_' specified in call to Genesis::Env->load!!")
		for (grep {! $opts{$_}} qw/name top/);

	my $env = $class->new(get_opts(\%opts, qw(name top)));
	my (@errors, @config_warnings, @deprecations);
	while (1) {
		# Validate environment file using centralized cached validation
		my ($valid, @validation_errors) = $class->is_valid_env_file($env->{name}, $env->{top});
		push(@errors, @validation_errors) unless $valid;
		last if @errors;

		$env->notify("using environment file #M{%s}", humanize_path($env->path($env->{file})))
			if ($ENV{GENESIS_PREFIX_TYPE}//'none') eq "search";

		push(@errors, "#ci{kit.subkits} has been superceeded by #ci{kit.features}")
			if $env->defines('kit.subkits');

		my ($env_name, $env_src) = $env->lookup(['genesis.env','params.env']);
		if ($env_name) {
			push(@errors, "environment name mismatch: #ci{$env_src} specifies #ri{$env_name}, expected #ci{$env->{name}}")
				unless $env->{name} eq $env_name || in_callback || envset("GENESIS_LEGACY");
		} else {
			push(@errors, "missing required #ci{genesis.env} field")
		}

		# Deprecation Warnings
		if ($env->defines('params.genesis_version_min')) {
			push(@deprecations, "#ci{params.genesis_version_min} has been superceeded by #ci{genesis.min_version}");
			$env->{__params}{genesis}{min_version} = delete($env->{__params}{params}{genesis_version_min});
		}
		if ($env->defines('params.bosh')) {
			push(@deprecations, "#ci{params.bosh} has been superceeded by #ci{genesis.bosh_env}");
			$env->{__params}{genesis}{bosh_env} = delete($env->{__params}{params}{bosh});
		}

		# Normalize genesis.use_create_env to boolean
		if ($env->defines('genesis.use_create_env')) {
			my $val = $env->lookup('genesis.use_create_env');
			my $normalized = ref($val) eq 'JSON::PP::Boolean' ? ($val ? 1 : 0) : lc($val // '');
			my $result = {
				'yes' => 1, 'true' => 1, '1' => 1, 1 => 1,
				'no' => 0, 'false' => 0, '0' => 0, 0 => 0
			}->{$normalized};

			if (defined $result) {
				$env->{__params}{genesis}{use_create_env} = $result;
			} else {
				push(@errors,
					"Invalid value #ri{%s} for #ci{genesis.use_create_env}.\n".
					"Valid values are: #Y{yes}, #Y{no}, #Y{true}, #Y{false}, #Y{1}, or #Y{0}",
					$val
				);
			}
		}

		# Validate bosh-configs keys
		if ($env->defines('bosh-configs')) {
			my $bosh_configs = $env->lookup('bosh-configs');
			if (ref($bosh_configs) eq 'HASH') {
				my @valid_keys = qw(cloud director_cloud cpi runtime);
				my %valid = map { $_ => 1 } @valid_keys;
				my @invalid_keys = grep { !$valid{$_} } keys %$bosh_configs;

				if (@invalid_keys) {
					my @key_errors;
					foreach my $key (@invalid_keys) {
						if ($key eq 'scale' || $key eq 'iaas') {
							push(@key_errors, "#ri{$key} should be under #Y{kit:}");
						} else {
							push(@key_errors, "#ri{$key} is invalid");
						}
					}
					push(@errors, "Encountered errors under #Y{bosh-configs:} key:\n  - ".join("\n  - ", @key_errors));
				}
			}
		}

		my $version_check = $env->validate_genesis_version_requirements();
		if ($version_check->{effective_minimum}) {
			my $min_version = $version_check->{effective_minimum};
			if ($Genesis::VERSION eq "(development)") {
				my $version_min_source = $version_check->{source};
				push(@config_warnings, "using development version of Genesis, cannot confirm it meets minimum version #ci{$min_version} required by the $version_min_source");
			} else {
				push(@errors, @{$version_check->{errors}}) if @{$version_check->{errors}};
				push(@config_warnings, @{$version_check->{warnings}}) if @{$version_check->{warnings}}
			}
		}

		my $kit_name = $env->lookup('kit.name');
		my $kit_version = $env->lookup('kit.version');
		my $kit = $env->{top}->local_kit_version($kit_name, $kit_version);
		if ($kit) {
			$env->{kit} = $kit;
			my $overrides = $env->lookup('kit.overrides');
			if (defined($overrides)) {
				$overrides = [ $overrides ] unless (ref($overrides) eq 'ARRAY');
				my @override_files;

				my $i=0;
				my $override_dir = workdir;
				for my $override (@$overrides) {
					my $file="$override_dir/env-overrides-$i.yml";
					$i+=1;
					if (ref($override) eq "HASH") {
						save_to_yaml_file($override,$file);
					} else {
						mkfile_or_fail($file,$override);
					}
					push @override_files, $file;
				}
				$env->kit->apply_env_overrides(@override_files);
			}
		} elsif (!$kit_name) {
			push(@errors, "Missing #ci{kit.name} and no local dev kit");
			push(@errors, "Missing #ci{kit.version}") unless $kit_version;
		} elsif (!$kit_version) {
			push(@errors, "Missing #ci{kit.version}");
		} else {
			my $vlabel = $kit_version eq 'latest' ? 'latest version' : "v$kit_version";
			push(@errors, sprintf(
				"Unable to locate %s of #M{%s} kit for #C{%s} environment.",
				$vlabel, $kit_name, $env->name
			));
		}
		last if @errors;
		$env->kit->check_prereqs($env) or bail "Cannot use the selected kit.";

		if (! $env->kit->feature_compatibility("2.7.0")) {
			push(@errors, sprintf("kit #M{%s} is not compatible with #ci{secrets_mount} feature; check for newer kit version or remove feature.", $env->kit->id))
				if ($env->secrets_mount ne $env->default_secrets_mount);
			push(@errors, sprintf("kit #M{%s} is not compatible with #C{exodus_mount} feature; check for newer kit version or remove feature.", $env->kit->id))
				if ($env->exodus_mount ne $env->default_exodus_mount);
		}
		last;
	}

	unless (under_test && !envset 'GENESIS_TESTING_DEV_VERSION_DETECTION' ) {
		if (@deprecations && !envset("REPORTED_ENV_DEPRECATIONS")) {
			error({label => "DEPRECATIONS", colors => 'Y'},
				"Environment #C{%s} contains the following deprecation:\n[[- >>%s\n",
				$env->{file}, join("\n[[- >>",map {join("\n    ",split("\n",$_))} @deprecations)
			);
			$ENV{REPORTED_ENV_DEPRECATIONS}=1;
		}
		if (@config_warnings && !envset("REPORTED_ENV_CONFIG_WARNINGS")) {
			warning(
				"\nEnvironment #C{%s} contains the following configuration warnings:\n[[- >>%s\n",
				$env->{file}, join("\n[[- >>",map {join("\n    ",split("\n",$_))} @config_warnings)
			);
			$ENV{REPORTED_ENV_CONFIG_WARNINGS}=1
		}
	}

	bail(
		"Environment #C{%s} could not be loaded:\n[[- >>%s\n\n".
		"Please fix the above errors and try again.",
		$env->{file}, join("\n[[- >>",map {join("\n    ",split("\n",$_))} @errors)
	) if @errors;

	return $env
}

# }}}
# from_envvars -- builds a pseudo-env based on the current env vars - used for hooks callbacks {{{
sub from_envvars {
	my ($class,$top) = @_;

	bail "Can only assemble environment from environment variables in a kit hook callback"
		unless ($ENV{GENESIS_KIT_HOOK}||'') eq 'new' && in_callback();

	bug("No 'GENESIS_$_' found in enviornmental variables - cannot assemble environemnt!!")
		for (grep {! $ENV{'GENESIS_'.$_}} qw(ENVIRONMENT KIT_NAME KIT_VERSION ENVIRONMENT_PARAMS));

	my $env = $class->new(name => $ENV{GENESIS_ENVIRONMENT}, top => $top);
	$env->{is_from_envvars} =1;
	$env->{__params} = decode_json($ENV{GENESIS_ENVIRONMENT_PARAMS});

	# reconstitute our kit via top
	my $kit_name = $ENV{GENESIS_KIT_NAME};
	my $kit_version = $ENV{GENESIS_KIT_VERSION};
	my $vlabel = $kit_version eq 'latest' ? 'latest version' : "v$kit_version";
	$env->{kit} = $env->{top}->local_kit_version($kit_name, $kit_version)
		or bail "Unable to locate $vlabel of #M{$kit_name} kit for #C{$env->{name}} environment.";
	$env->kit->apply_env_overrides(split(' ',$ENV{GENESIS_ENV_KIT_OVERRIDE_FILES}))
	  if defined $ENV{GENESIS_ENV_KIT_OVERRIDE_FILES};

	my $min_version = $ENV{GENESIS_MIN_VERSION} || scalar($env->lookup('genesis.min_version', ''));
	$min_version =~ s/^v//i;

	if ($min_version) {
		if ($Genesis::VERSION eq "(development)") {
			warning(
				"Environment `$env->{name}` requires Genesis v$min_version or higher.\n".
				"\n".
				"This version of Genesis is a development version and its feature ".
				"availability cannot be verified -- unexpected behaviour may occur."
			) unless (under_test && !envset 'GENESIS_TESTING_DEV_VERSION_DETECTION');
		} elsif (! new_enough($Genesis::VERSION, $min_version)) {
			bail(
				"Environment `$env->{name}` requires Genesis v$min_version or higher.  ".
				"You are currently using Genesis v$Genesis::VERSION."
			) unless (under_test && !envset 'GENESIS_TESTING_DEV_VERSION_DETECTION');
		}
	}

	# features
	$env->{'__features'} = [split(' ',$ENV{GENESIS_REQUESTED_FEATURES})]
		if $ENV{GENESIS_REQUESTED_FEATURES};

	# bosh and credhub env overrides
	if (envset 'GENESIS_USE_CREATE_ENV') {
		$env->{__params}{genesis}{use_create_env} = 'true';
		$env->{__params}{genesis}{min_version} ||= $min_version;
		$env->{__bosh} = Service::BOSH::CreateEnvProxy->new();
	} else {
		$env->{__bosh} = Service::BOSH::Director->from_environment();
	}
	$env->{__params}{genesis}{credhub_env} = $ENV{GENESIS_CREDHUB_EXODUS_SOURCE}
		if ($ENV{GENESIS_CREDHUB_EXODUS_SOURCE});

	# determine our vault and secret path
	$env->{__params}{genesis}{vault} = $ENV{GENESIS_ENV_VAULT_DESCRIPTOR} if $ENV{GENESIS_ENV_VAULT_DESCRIPTOR};
	for (qw(secrets_mount secrets_base secrets_slug exodus_mount exodus_base ci_mount ci_base root_ca_path)) {
		$env->{'__'.$_} = $env->{__params}{genesis}{$_} = $ENV{'GENESIS_'.uc($_)}
			unless eval "\$env->$_" eq $ENV{'GENESIS_'.uc($_)};
	}

	# Check for v2.7.0 features
	unless ($env->kit->feature_compatibility("2.7.0")) {
		bail(
			"Kit #M{%s} is not compatible with #C{secrets_mount} feature\n".
			"Please upgrade to a newer release or remove params.secrets_mount from #M{%s}",
			$env->kit->id, $env->{file}
		) if ($env->secrets_mount ne $env->default_secrets_mount);
		bail(
			"Kit #M{%s} is not compatible with #C{exodus_mount} feature\n".
			"Please upgrade to a newer release or remove params.exodus_mount from #M{%s}",
			$env->kit->id, $env->{file}
		) if ($env->exodus_mount ne $env->default_exodus_mount);
	}

	bail(
		"No vault specified or configured."
	) unless $env->vault;

	return $env;
}

# }}}
# create - create a new Genesis::Env object from user input {{{
sub create {
	my ($class,%opts) = @_;

	# validate call
	for (qw(name top kit)) {
		bug("No '$_' specified in call to Genesis::Env->create!!")
			unless $opts{$_};
	}

	my $env = $class->new(get_opts(\%opts, qw(name top kit)));
	my $create_env = $opts{'create-env'};

	# environment must not already exist...
	die "Environment file $env->{file} already exists.\n"
		if -f $env->path($env->{file});

	# Sanitize the vault descriptor, if present
	if ($opts{vault}) {
		unless (grep {$_ =~ /^https?:\/\/[^\/]+/} (split(' ',$opts{vault}))) {
			my $vault = (Service::Vault->find(name => $opts{vault}))[0];
			bail(
				"Cannot find a vault target with alias '$opts{vault}'"
			) unless $vault;
			$opts{vault} = $vault->build_descriptor();
		}
	}

	# Setup minimum parameters (normally from the env file) to be able to build
	# the env file.
	$env->{__params} = {
		genesis => {
			env => $opts{name},
			get_opts(\%opts, qw(vault secrets_path secrets_mount exodus_mount ci_mount root_ca_path credhub_env))}
	};

	my $bosh_env = ($ENV{GENESIS_BOSH_ENVIRONMENT}//'') eq '' ? undef : $ENV{GENESIS_BOSH_ENVIRONMENT};

	# The crazy-intricate create-env/bosh_env dance...
	if ($env->kit->feature_compatibility("2.8.0")) {
		# Kits that are explicitly compatible with 2.8.0 can specify if they
		# support or require create-env deployments.
		my $uce = $env->kit->metadata('use_create_env')||'';
		if ($uce eq 'yes') {
			bail(
				"Kit %s requires use of create-env, but --no-create-env option was specified",
				$env->kit->id
			) if defined($create_env) && !$create_env;
			bail(
				"Cannot specify a bosh environment for environments that use ".
				"create-env deployment method"
			) if defined($bosh_env);
			$env->{__params}{genesis}{use_create_env} = 1;
			$env->{__params}{genesis}{bosh_env} = '';
		} elsif ($uce eq 'no') {
			bail(
				"Kit %s cannot use create-env, but --create-env option was specified",
				$env->kit->id
			) if $create_env;
			$env->{__params}{genesis}{use_create_env} = 0;
			$env->{__params}{genesis}{bosh_env} = $bosh_env//$opts{name};
		} else {
			# Complicated state: the kit allows but does not require create-env.
			warning(
				"\nKit #M{%s} supports both bosh and create-env deployment.  No --create-env ".
				"option specified, so using bosh deployment method.",
				$env->kit->id
			) unless defined($create_env) || $bosh_env;
			bail(
				"Cannot specify a bosh environment for environments that use create-env deployment method."
			) if $create_env && $bosh_env;
			$env->{__params}{genesis}{use_create_env} = $create_env//0;
			$env->{__params}{genesis}{bosh_env} = $create_env ? '' : $bosh_env || $opts{name};
		}
	} else {
		bail(
			"Kit %s does not support the --[no-]create-env option",
			$env->kit->id
		) if defined($create_env);
		if ($env->is_bosh_director()) { # Prior to 2.8.0, only the bosh kit can use create_env.
			$env->{__params}{genesis}{use_create_env} = ($bosh_env) ? 0 : 1;
			$env->{__params}{genesis}{bosh_env} = $bosh_env || '';
		} else {
			$env->{__params}{genesis}{use_create_env} = 0;
			$env->{__params}{genesis}{bosh_env} = $bosh_env || $opts{name};
		}
	}

	# target vault and remove secrets that may already exist
	bail("No vault specified or configured.")
		unless $env->vault;

	my ($results) = $env->remove_secrets(all => 1, no_populate => 1);
	bail "Cannot continue with existing secrets for this environment"
		if ($results->{abort} || $results->{error});

	# credhub env overrides
	$env->{__params}{genesis}{credhub_env} = $ENV{GENESIS_CREDHUB_EXODUS_SOURCE}
		if ($ENV{GENESIS_CREDHUB_EXODUS_SOURCE});

	## initialize the environment
	$env->download_required_configs('new')
		unless $env->lookup('genesis.use_create_env','0');

	# Use the current version of Genesis as the minimum version if not specified
	$ENV{GENESIS_MIN_VERSION} ||= $Genesis::VERSION;

	bail(
		"Kit %s is not supported in Genesis %s (no hooks/new script).  Check for ".
		"a newer version of this kit.",
		$env->kit->id, $Genesis::VERSION
	) unless $env->has_hook('new');
	$env->run_hook('new');

	# Load the environment from the file to pick up hierarchy, and generate secrets
	$env = $class->load(name =>$env->name, top => $env->top);

	# Make environment file executable if requested
	if ($Genesis::RC->get('executable_environments')) {
		# append hashbang to the file
		my $file = $env->path($env->file);
		my $contents = slurp($file);
		unless ($contents =~ /^#!/) {
			$contents = "#!/usr/bin/env genesis\n".$contents;
			mkfile_or_fail($file, 0755, $contents);
		}
	}

	if (! $env->add_secrets(verbose=>1, import => 1)) {
		$env->remove_secrets(all => 1, 'no-prompt' => 1);
		unlink $env->file;
		return undef;
	}
	return $env;
}

# }}}
# exists - returns true if the given environment exists {{{
sub exists {
	my $ref = shift if @_ % 2 == 1;
	return -f $ref->path($ref->{file}) if ref($ref) eq __PACKAGE__;

	# Called directly or on class
	my %args = @_;
	bug(
		"%s::exists called without name and/or top named arguments",
		__PACKAGE__
	) unless $args{name} && $args{top};
	return scalar __PACKAGE__->is_valid_env_file($args{name}, $args{top});
}

#}}}
# is_valid_env_file - check if a named environment file is valid without instantiation {{{
sub is_valid_env_file {
	my ($class, $name, $top) = @_;

	# Check required top parameter
	bug(
		"No 'top' specified in call to is_valid_env_file!!"
	) unless $top;

	# Strip .yml extension if present
	$name =~ s/.yml$//;
	my $path = $top->path("$name.yml");

	# Check validation cache
	if (exists $_validation_cache{$path}) {
		my $cached = $_validation_cache{$path};
		return wantarray ? @$cached : $cached->[0];
	}

	# Collect all errors
	my @errors;
	my $yaml_src;

	while (1) {
		# Validate environment name
		my $name_err = _env_name_errors($name);
		push @errors, "Invalid environment name #ri{$name}:$name_err" if $name_err;
		last if @errors;

		push @errors, sprintf(
			"Environment file #C{%s} does not exist.",
			humanize_path($path)
		) unless -f $path;
		last if @errors;

		# Check if the environment file has genesis.env declaration
		$yaml_src = eval { slurp($path) };
		unless ($yaml_src) {
			push @errors, sprintf(
				"Failed to read environment file #C{%s}.",
				humanize_path($path)
			);
			last;
		}

		# Block format: genesis:\n  env: name
		my @env_names = $yaml_src =~ /^genesis:\r?\n\r?  (?:.*\r?\n\r?  )*env:\s+([^\s]*)/mg;
		# Inline format: {genesis: {env: 'name'}} or {genesis: {env: name}}
		unless (@env_names) {
			@env_names = $yaml_src =~ /\bgenesis:\s*\{[^}]*\benv:\s*'?([a-zA-Z0-9_][a-zA-Z0-9_-]*)'?/mg;
		}
		unless (scalar(@env_names) == 1 && ($env_names[0] eq $name || envset("GENESIS_LEGACY"))) {
			if (scalar(@env_names) == 0) {
				push @errors, sprintf(
					"Environment file #C{%s} does not contain a 'genesis.env' declaration.",
					humanize_path($path)
				);
			} elsif (scalar(@env_names) > 1) {
				push @errors, sprintf(
					"Environment file #C{%s} contains multiple 'genesis.env' declarations.",
					humanize_path($path)
				);
			} else {
				push @errors, sprintf(
					"Environment file #C{%s} declares environment '%s' but is named '%s.yml'.",
					humanize_path($path), $env_names[0], $name
				);
			}
			last;
		}

		# Check if the environment has kit information available
		# Kit info can be split across hierarchical files (kit.name in parent, kit.version in child)
		my $kit_name_re = qr/^kit:\r?\n\r?  (?:.*\r?\n\r?  )*name:\s+([^\s]+)/m;
		my $kit_version_re = qr/^kit:\r?\n\r?  (?:.*\r?\n\r?  )*version:\s+([^\s]+)/m;
		my $has_kit_name = $yaml_src =~ $kit_name_re;
		my $has_kit_version = $yaml_src =~ $kit_version_re;

		# If kit info not complete in main file, check hierarchical files
		unless ($has_kit_name && $has_kit_version) {
			my $env_obj = bless({name => $name, top => $top}, 'Genesis::Env');
			my @env_files = $env_obj->actual_environment_files();
			pop @env_files; # Remove main file, already checked
			while (my $ancestor_file = pop @env_files) {
				next unless -f $top->path($ancestor_file);
				my $ancestor_yaml = eval { slurp($top->path($ancestor_file)) };
				next unless $ancestor_yaml;

				$has_kit_name = 1 if !$has_kit_name && $ancestor_yaml =~ $kit_name_re;
				$has_kit_version = 1 if !$has_kit_version && $ancestor_yaml =~ $kit_version_re;
				last if $has_kit_name && $has_kit_version;
			}

			# Skip kit validation error if a dev kit is present AND no kit: block
			# exists in any env file (handles env files that rely entirely on the dev kit)
			unless ($has_kit_name && $has_kit_version) {
				my $has_kit_block = ($yaml_src =~ /^kit:/m);
				last if !$has_kit_block && !$has_kit_name && !$has_kit_version && $top->has_dev_kit();
				my @missing;
				push @missing, "kit.name" unless $has_kit_name;
				push @missing, "kit.version" unless $has_kit_version;
				push @errors, sprintf(
					"Environment file #C{%s} is missing required kit information: %s.",
					humanize_path($path),
					join(", ", @missing)
				);
				last;
			}
		}

		last; # All validation passed
	}

	# Cache and return results
	my @result = @errors ? (undef, @errors) : (1);
	$_validation_cache{$path} = \@result;
	return wantarray ? @result : $result[0];
}

#}}}
# search_for_env_file - search for an environment file in known deployment root(s) {{{
sub search_for_env_file {
	my ($class, $env, $deployment) = @_;
	my $label = '@'.($env//'').($deployment ? ":$deployment" : '');
	my $director_target = defined($deployment) ? 'parent' : 'self';
	my %file_map;

	my ($root_labels, $root_map) = Genesis::deployment_roots_map(
		['@current', $ENV{GENESIS_ORIGINATING_DIR}],
		['@parent', Cwd::abs_path(Genesis::expand_path($ENV{GENESIS_ORIGINATING_DIR}.'/..'))],
	);
	$env = "*$env*" =~ s/\*\^//r =~ s/\$\*//r unless $env eq '*';
	my $given_deployment = $deployment//'';
	$deployment = "*$deployment*" =~ s/\*\^//r =~ s/\$\*//r if defined($deployment) && $deployment ne '*';

	for my $label (@$root_labels) {
		my $root = $root_map->{$label};
		my @deployments = map {s{/\.genesis/config$}{}r}
			glob("$root/".($deployment//'*')."/.genesis/config"); # Only include genesis repos
		next unless @deployments;
		if (defined $deployment) {
			$file_map{$label} = [map {glob("$_/$env.yml")} @deployments];
		} else {
			$file_map{$label} = [map {glob("$_/$env.yml")} grep { /\/bosh(-deployments)?$/ } @deployments];
		}
	}

	# Order the files by current directory, then by the order of the deployment
	# roots specified in the .genesis/config file, then bosh first, followed by
	# any other deployments in alphabetical order.
	my @files = ();
	for my $label ('@current', '@parent', @$root_labels) {
		if ($file_map{$label}) {
			my $is_bosh= qr{/bosh(-deployments)?/[^/]*\.yml$};
			push(@files,
				map {[$label, $_]}
				sort {
					($a =~ $is_bosh ? 0 : 1) <=> ($b =~ $is_bosh ? 0 : 1 ) || $a cmp $b
				} @{delete $file_map{$label}}
			);
		}
	}

	# Filter out files that aren't genesis environments
	@files = grep {
		my (undef, $name) = $_->[1] =~ m{(.*)/([^/]*)\.yml$};
		my $contents = slurp($_->[1]);
		($contents =~ m/^genesis:\s*$(\n  .*: .*$)*(\n  env: *$name)/m)
			&& ($contents !~ m/^name:/);
	} @files;

	bail("No environment files found matching #C{%s}", $label)
		unless @files;

		# Check if the deployment, if given, is an exact singular match
	if (scalar(@files) > 1 && $given_deployment =~ /^[\w-]+$/) {
		my @exact_matches = grep {$_->[1] =~ m{/$given_deployment(-deployments)?/}} @files;
		@files = @exact_matches	if (scalar(@exact_matches) == 1);
	}

	if (scalar(@files) > 1) {
		my $last_section = '';
		my @file_labels = map {
			my ($section, $label) = @$_;
			$label =~ m{(?:(.*?)/)?([^/]*)/([^/]*)\.yml};
			my $fmt_label = csprintf("#c{%s}/#m{%s}", $2, $3);
			if ($section ne $last_section) {
				$last_section = $section;
				my $fmt_section;
				my $target_path = $root_map->{$section} =~ s{^$ENV{HOME}/}{~/}r;
				my $is_current = $root_map->{$section} eq $ENV{GENESIS_ORIGINATING_DIR};
				my $flag = $ENV{GENESIS_NO_UTF8}
					? ''
					: $is_current ? "\x{1F4C2} " : "\x{1F4C1} ";
				if ($section eq '@current') {
					$fmt_section = csprintf("#Gu{%sCurrent Directory:} #Ki{%s}", $flag, $target_path);
				} elsif ($section eq '@parent') {
					$fmt_section = csprintf("#Yu{%sParent Directory:} #Ki{%s}", $flag, $target_path);
				} elsif ($section ne $root_map->{$section}) {
					my $is_current = $root_map->{$section} eq $ENV{GENESIS_ORIGINATING_DIR};
					$fmt_section = csprintf("#%su{%sDeployment Root '%s':} #Ki{%s}", $is_current ? 'g' : 'B', $flag, $section, $target_path);
				} else {
					$fmt_section = csprintf("#Bu{%sDeployment Root:} #Ki{%s}", $flag, $target_path);
				}
				("---$fmt_section---", [$fmt_label, csprintf("#C{%s}", humanize_path($root_map->{$section}, absolute => 1))."/$fmt_label"])
			} else {
				[$fmt_label, csprintf("#C{%s}", humanize_path($root_map->{$section}, absolute => 1))."/$fmt_label"]
			}
		} @files;

		bail(
			"Ambiguous environment name: #C{%s} matches multiple files:\n  - %s\n\n".
			"Please refine your match criteria.",
			$label, join("\n  - ", map {$_->[1]} grep {ref($_) eq 'ARRAY'} @file_labels)
		) unless in_controlling_terminal;

		my $selected_file = prompt_for_choice(
			csprintf(
				"Multiple environment files found matching #C{$label}:"
			),
			[@files, ['none']],
			$files[0],
			[ @file_labels, '---', csprintf('#R{%s of these - cancel}', scalar(@files) == 2 ? 'Neither' : "None") ],
			undef,
			"the desired environment file"
		);
		output({stderr=>1}, "");
		bail("No environment file selected.") if $selected_file->[0] eq 'none';
		$files[0] = $selected_file;
	}

	$files[0][1] =~ m{(?:(.*?)/)?([^/]*)/([^/]*)\.yml};
	my $deployment_root = $1;
	return ($deployment_root, $files[0][1]);
}
#}}}
#}}}

### Private Class Methods {{{

# _env_name_errors - ensure name is valid {{{
sub _env_name_errors {
	my ($name) = @_;

	my @errors = ();

	bug(
		"Environment name expected to be a string, got a %s",
		ref($name) || 'undefined value'
	) if !defined($name) || ref($name);

	push(@errors,"names must not be empty.\n")
		if !$name;

	push(@errors,"names must not contain whitespace.\n")
		if $name =~ m/\s/;

	push(@errors,"names can only contain lowercase letters, numbers, underscores and hyphens.\n")
		if $name !~ m/^[a-z0-9_-]+$/;

	push(@errors,"names must start with a lowercase letter.\n")
		if $name !~ m/^[a-z]/;

	push(@errors,"names must not end with a hyphen.\n")
		if $name =~ m/-$/;

	push(@errors,"names must not contain sequential hyphens (i.e. '--').\n")
		if $name =~ m/--/;

	return '' unless scalar(@errors);
	return join("\n  - ", '', @errors);
}

# }}}
# }}}

### Instance Methods {{{

# Public Accessors: name, file, kit, top {{{
sub name   { $_[0]->{name};   }
sub file   { $_[0]->{file};   }
sub kit    { $_[0]->{kit}    || bug("Incompletely initialized environment '".$_[0]->name."': no kit specified"); }
sub top    { $_[0]->{top}    || bug("Incompletely initialized environment '".$_[0]->name."': no top specified"); }

# }}}
# Delegations: type, path {{{
sub type   { $_[0]->top->type; }
sub path   { shift->top->path(@_); }
# }}}

# Information Lookup
# signature - unique 12-character id for the environment based on name, type and file {{{
sub signature {
	return $_[0]->_memoize( sub {
		my ($self) = @_;
		my $absfile = $self->path($self->file);
		my $sig_string = sprintf("%s/%s@%s:%s",
			$self->name,
			$self->type,
			$absfile,
			(-f $absfile ? slurp($absfile) : '')
		);
		return substr(sha1_hex($sig_string),0,12)
	});
}
# }}}
# deployment_name - returns the deployment name (env name + env type) {{{
sub deployment_name {
	$_[0]->_memoize('__deployment', sub {
		my $self = shift;
		sprintf('%s-%s',$self->name,$self->type);
	});
}

# }}}
# sub manifest_store - returns the type of manifest store: exodus, hybrid, or repository {{{
sub manifest_store {
	my ($self) = @_;
	# If the environment supports a version of Genesis lower than 3.1.0, then
	# the manifest store is always 'repository' because earlier versions of Genesis
	# cannot update the exodus deployment audit data.
	my $min_version = '3.1.0';
	return $self->top->config->get('manifest_store','hybrid')
		if ($self->feature_compatibility($min_version));

	debug(
		"Using 'repository' manifest store because enviroment does ".
		"not specify a genesis.minimum_version of %s or greater",
		$min_version
	);
	return 'repository';
}

# }}}
# deployment_state - returns the status of the deployment {{{
# DEPRECATED: use deployments->current_state instead
sub deployment_state {
	return $_[0]->deployments->current_state;
}

# }}}
# is_bosh_director - returns true if the environment represents a BOSH director deployment {{{
sub is_bosh_director {
	my $self = shift;
	$self->kit->provides_service('director');
}

# }}}
# use_create_env - true if the deployment uses bosh create-env {{{
sub use_create_env {

	return 'unknown' if $_[0]->_get_memo() && $_[0]->_get_memo() eq "processing";
	return $_[0]->_memoize(sub {
		my ($self) = @_;
		$self->_set_memo("processing");
		my $is_bosh_director = $self->is_bosh_director;

		my $clear_and_bail = sub {
			my $self = shift;
			$self->_clear_memo('__use_create_env');
			bail(@_);
		};

		my $validate_create_env_state = sub {
			my ($self,$is_create_env,$has_bosh_env,$env_type,$is_bosh_kit, $is_310plus) = @_;
			$clear_and_bail->($self,
				"This #M{$env_type} environment specifies an alternative bosh_env, but ".
				"is marked as a create-env (proto) environment. Create-env deployments ".
				"can't use a #C{genesis.bosh_env} value, so please remove it, or mark ".
				"this environment as a non-create-env environment.  It may be that ".
				"bosh_env is configured in an inherited environment file."
			) if $is_create_env && $has_bosh_env;
			return unless $is_bosh_kit;
			$clear_and_bail->($self,
				"This #M{$env_type} environment does not use create-env nor does it ".
				"specify an alternative #C{genesis.bosh_env} as a deploy target.  ".
				"Please provide the name of the BOSH environment that will deploy this ".
				"environment, or mark this environment as a create-env environment."
			) if $is_310plus && !($is_create_env || $has_bosh_env );
			$clear_and_bail->($self,
				"This #M{$env_type} environment does not use create-env (proto) or ".
				"specify an alternative #C{genesis.bosh_env} as a deploy target.  ".
				"Please provide the name of the BOSH environment that will deploy this ".
				"environment, or mark this environment as a create-env environment."
			) unless $is_create_env || $has_bosh_env;
		};

		my $different_bosh_env = ($self->bosh_env->{description}//$self->name) ne $self->name;

		if ($self->kit->feature_compatibility("2.8.0")) {
			# Kits that are explicitly compatible with 2.8.0 can specify if they
			# support or require create-env deployments.

			# use_create_env is already sanitized to 'yes', 'no', or 'allow' by Genesis::Kit
			my $kuce = $self->kit->metadata('use_create_env');

			if ($kuce eq 'yes') {
				$clear_and_bail->($self,
					"This kit only allows create-env deployments, but this environment ".
					"specifies an alternative bosh_env.  Please remove the ".
					"#C{genesis.bosh_env} entry from the environment file."
				) if $different_bosh_env;
				return 1;
			};
			if ($kuce eq 'no') {
				$clear_and_bail->($self,
					"BOSH environments must specify the name of the parent BOSH director ".
					"that will deploy this enviornment under #C{genesis.bosh_env} in the ".
					"file, because unlike other kits, it cannot derive its director from ".
					"its environment name."
				) if $is_bosh_director && !$different_bosh_env;
				return 0 ;
			}

			# Allow, but not required to use create-env
			my $is_create_env = undef;
			# genesis.use_create_env is already normalized to 1/0 by load()
			my $euce = $self->lookup('genesis.use_create_env', undef);
			my $is_310plus = $self->feature_compatibility("3.1.0-rc1");
			my $is_proto = grep {$_ eq 'proto'} @{$self->lookup('kit.features', [])};
			if ($is_310plus && $is_bosh_director) {
				# proto feature removed in 3.1.0-rc1
				$is_create_env = ($euce || !$different_bosh_env) ? 1 : 0;
			} elsif ($euce) {
				$is_create_env = 1;
			} elsif ($is_proto) {
				# Proto feature forces create-env (checked before bosh_env)
				$is_create_env = 1;
			} elsif ( $is_bosh_director && $different_bosh_env) {
				$is_create_env = 0;
			} else {
				$is_create_env = 0;
			}
			if ($is_proto && $different_bosh_env) {
				$clear_and_bail->($self,
					"This environment is marked as a create-env (proto) environment ".
					"by using the #M{proto} feature, but also specifies an alternative ".
					"bosh_env.  Create-env deployments can't use a #C{genesis.bosh_env} ".
					"value, so please remove it."
				);
			}

			$validate_create_env_state->(
				$self,$is_create_env,$different_bosh_env,$self->type,
				$is_bosh_director,$is_310plus
			);
			return $is_create_env;
		}

		# Before 2.8.0, we only support create-env deployments for bosh deployments.
		return 0 unless $is_bosh_director;

		# If creating a new bosh environment, we need to do some special handling.

		# Support pre-v2.8.0 create env schemes...
		my $euce;
		if ($self->exists) {
			my $features = scalar($self->lookup(['kit.features', 'kit.subkits'], []));
			$euce = scalar(grep {$_ =~ /^(proto|bosh-init|create-env)$/} @$features) ? 1 : 0; # FIXME: remove bosh-init prior to 3.1.0, proto prior to 3.2.0
		} else {
			$euce = $ENV{GENESIS_BOSH_ENVIRONMENT} ? 0 : 1;
		}
		dump_var detected=>$euce, diff => $different_bosh_env;
		$validate_create_env_state->($self,$euce,$different_bosh_env,"bosh",1);
		return $euce;
	});
}

# }}}
# can_build_cloud_configs - returns true if the environment can build a cloud config {{{
sub can_build_cloud_configs {
	my $self = shift;
	return 0 unless $self->feature_compatibility("3.1.0-rc.9");
	return 0 unless $self->lookup('genesis.manage-cloud-configs')//1;
	return 1;
}

# }}}

# minimum_genesis_version - returns the effective minimum genesis version for this environment {{{
sub minimum_genesis_version {
	my ($self) = @_;
	return $self->_memoize(sub {
		my $env_min = $self->lookup(['genesis.min_version', 'genesis.minimum_version'], '') =~ s/^v//ri;
		my $repo_min = $self->top->config->get('minimum_version','') =~ s/^v//ri;

		# Environment minimum takes precedence if specified
		return $env_min if $env_min;

		# Fall back to repository minimum
		return $repo_min if $repo_min;

		# No minimum specified
		return'0.0.0';
	});
}

# }}}
# feature_compatibility - returns true if the min version for the environment meets or exceeds the specified version {{{
sub feature_compatibility {
	my ($self,$version) = @_;
	trace("Comparing %s environment specified version (%s) to %s feature base", $self->name, $self->minimum_genesis_version, $version);
	return new_enough($self->minimum_genesis_version,$version);
}

# }}}
# validate_genesis_version_requirements - checks if the environment's minimum genesis version is compatible with the given version {{{
sub validate_genesis_version_requirements {
	my ($self) = @_;

	my @warnings = ();
	my @errors = ();
	my $running_version = $Genesis::VERSION;
	my $env_min = $self->lookup(['genesis.min_version', 'genesis.minimum_version'], '') =~ s/^v//ri;
	my $repo_min = $self->top->config->get('minimum_version','') =~ s/^v//ri;

	# Determine effective minimum (whichever is greater)
	my $effective_min;
	my $source;
	if ($env_min && $repo_min) {
		# Both specified - use whichever is greater
		$effective_min = new_enough($env_min, $repo_min) ? $env_min : $repo_min;
		my $src_map = {
			$repo_min => 'repository configuration',
			$env_min  => 'environment file',
		};
		$source = $src_map->{$effective_min};

		if ($effective_min ne $repo_min) {
			# Environment requires newer version than repo - this is fine
			push @warnings, sprintf(
				"Environment requires Genesis %s, which is newer than the ".
				"repository minimum of %s",
				$env_min, $repo_min
			);
		} elsif (!new_enough($env_min, $repo_min)) {
			# Environment allows older version than repo requires
			push @errors, sprintf(
				"Environment specifies minimum Genesis version %s, but repository ".
				"requires at least %s",
				$env_min, $repo_min
			);
		}
	} elsif ($env_min) {
		$effective_min = $env_min;
		$source = 'environment file';
	} elsif ($repo_min) {
		$effective_min = $repo_min;
		$source = 'repository configuration';
	} else {
		$effective_min = '0.0.0';
		$source = 'unspecified';
	}

	# Check running version against effective minimum
	if ($running_version eq "(development)") {
		# Development version, no minimum check
		push @warnings, "Running Genesis in development mode, skipping minimum version checks";
		return {
			errors => \@errors,
			warnings => \@warnings,
			effective_minimum => $effective_min,
			running_version => $running_version,
			source => $source,
		};
	}
	if ($effective_min && !new_enough($running_version, $effective_min)) {
		my $source = $env_min ? "environment file" : "repository configuration";
		push @errors, sprintf(
			"Genesis version %s does not meet the minimum required version %s ".
			"specified in the %s",
			$running_version, $effective_min, $source
		);
	}

	return {
		errors => \@errors,
		warnings => \@warnings,
		effective_minimum => $effective_min//'0.0.0',
		running_version => $running_version,
		source => $env_min ? 'environment file' : $repo_min ? 'repository configuration' : undef,
	};
}

# }}}
# get_call_path - returns the path to the genesis binary {{{
sub get_call_path {
	my ($self) = @_;
	return $self->_memoize(sub {
		my $bin = $ENV{GENESIS_CALL_BIN} || humanize_bin();
		$bin = "'$bin'" if $bin =~ / \(\)!\*\?/;
		return $bin;
	});
}

# }}}
# get_call_path_with_env - returns the path to the genesis binary and the environment name {{{
sub get_call_path_with_env {
	my ($self) = @_;
	my $bits = $self->_memoize(sub {
		my $bin = $self->get_call_path();
		my $is_alt_path = defined($ENV{GENESIS_CALLER_DIR}) && $self->path ne $ENV{GENESIS_CALLER_DIR};

		my $env_ref = $self->name;
		if (($ENV{GENESIS_PREFIX_TYPE}//'') eq 'search') {
			$env_ref = "$ENV{GENESIS_PREFIX_SEARCH}";
		} else {
			$env_ref .= '.yml' if (grep {$_ eq $self->name} known_commands);
			$env_ref = humanize_path($self->path)."/$env_ref" if $is_alt_path;
		}
		$env_ref = "'$env_ref'" if $env_ref =~ / \(\)!\*\?/;
		return [$bin, $env_ref];
	});
	return wantarray ? @$bits : join(' ', @$bits);
}

# workpath - provide the path to the temporary file storage for this envionment {{{
sub workpath {
	my ($self, $relative) = @_;
	return $relative ? "$self->{__tmp}/$relative"
	                 :  $self->{__tmp};
}

# }}}
# potential_environment_files - list the heirarchal environment files possible for this env {{{
sub potential_environment_files {
	my $env = $ENV{PREVIOUS_ENV} || ''; # ci pipelines need to pull cache for previous envs
	return $_[0]->relate($env, ".genesis/cached/$env");
}

# }}}
# actual_environment_files - list the heirarchal environment files that exist for this env {{{
sub actual_environment_files {

	# This will return all name-based and explicitly inherited environment files, with itself last.
	my ($self, $seen) = @_;

	my $ref = $_[0]->_memoize('__actual_files', sub {
		my $self = shift;
		if ($self->{is_from_envvars} && ! -f $self->path($self->file)) {
			my $tmpenv = $self->workpath("reconstructed-env.yml");
			save_to_yaml_file($self->params,$tmpenv);
			return [$tmpenv];
		}
		# FIXME:  SUPER IMPORTANT - we need to handle cached files too (ie pipeline support)
		my $self_filename = "./".$self->name.".yml";
		my @files;
		$seen //= {$self_filename => -1}; # Ensure we always include self last.

		# This will cycle through all the name-based inherited files that exist, including itself.
		my @existing_ancestors = (grep {-f $self->path($_)} $self->potential_environment_files);
		my $i = 1;
		for my $ancestor_file (@existing_ancestors) {
			next if $seen->{$ancestor_file}++ > 0; # Already seen this file
			$seen->{$ancestor_file} = 1;

			# This will cycle through all explicitly inherited files of the target
			# file (NOT including the file itself), and any actual files they inherit
			# by explicit inheritance.  We need to make sure it doesn't include itself
			# or any other files already seen to avoid infinite loops.
			my @ignore_files = keys %$seen;
			#push(@ignore_files, $self_filename) unless $seen->{$self_filename};
			for my $inherited_file ($self->_genesis_inherits($ancestor_file, @ignore_files)) {

				# For any explicitly inherited file, we need to check if it has any
				# name-based files that it should inherit as well (and recursively, if
				# they have any explicit inherits).  This should never return already
				# seen files (or the current file name).

				# Check if the inherited file should inherit name-based files
				my ($inherited_name) = $inherited_file =~ m{.*/([^/]*)\.yml$};
				next unless $inherited_name; # This should never happen, but just in case...
				my $inherited_env = bless({name => $inherited_name, top => $self->top}, ref($self)); # Lightweight env object for inspecting name-based relationships

				# Pass in the seen files to avoid duplicates and infinite loops
				for my $ancestor ($inherited_env->actual_environment_files($seen)) {
					push(@files, $ancestor);
					$seen->{$ancestor}++;
				}

				# Get name-based files for the inherited environment
			}
			push( @files, $ancestor_file);
		};
		return \@files;
	});
	return @$ref;
}

# }}}
# relate - get hierarchal file relationships with another environment {{{
sub relate {
	my ($self, $them, $common_base, $unique_base) = @_;
	return relate_by_name($self->{name}, ref($them) ? $them->{name} : $them, $common_base, $unique_base);
}

# }}}
# relate_by_name - get hierarchal file relationships between named environments {{{
sub relate_by_name {
	my ($name, $other, $common_base, $unique_base) = @_;
	$common_base ||= '.';
	$unique_base ||= '.';
	$other ||= '';

	my @a = split /-/, $name;
	my @b = split /-/, $other;
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

	trace("[env $name] in relate(): common $_") for @common;
	trace("[env $name] in relate(): unique $_") for @unique;

	return wantarray
		? (@common, @unique)
		: { common => \@common, unique => \@unique };
}

# }}}
# format_yaml_files - return the list of all yaml files used to create the manifest {{{
sub format_yaml_files {
	my ($self, %options) = @_;
	my $local_label = $options{'local-label'} || "./";
	my $padding = $options{padding} || '';

	my @files;
	if ($options{'include-kit'}) {
		my $kit_label   = $options{'kit-label'} || "#G{".$self->kit->id.":} ";
		$local_label = sprintf("%*s", length($kit_label), "#C{local:} ");
		my $env_path = $self->path();
		for ($options{kit_files} ? $options{kit_files}->@* : $self->kit_files) {
			if ($_ =~ qr/^$env_path\/(.*)$/) {
				push @files, "$padding$local_label$1";
			} else {
				push @files, "$padding$kit_label#K{$_}";
			}
		}
	}
	push @files, map {(my $f = $_) =~ s/^\.\//$padding$local_label/; $f}
		($self->actual_environment_files);
	return @files;
}

# }}}
# features - returns the list of features (specified and derived) {{{
sub features {
	my $ref = $_[0]->_memoize(sub {
		my $self = shift;
		my $features = scalar($self->lookup('kit.features', []));
		bail(
			"Environment #C{%s} #G{kit.features} must be an array - got a #y{%s}.",
			$self->name, defined($features) ? (lc(ref($features)) || 'string') : 'null'
		) unless ref($features) eq 'ARRAY';

		my @derived_features = grep {$_ =~ /^\+/} @$features;
		bail(
			"Environment #C{%s} cannot explicitly specify derived features:\n  - %s",
			$self->name, join("\n  - ",@derived_features)
		) if @derived_features;
		$features = $self->kit->run_hook('features',env => $self, features => $features)
			if $self->kit->has_hook('features');
		$features;
	});
	return @$ref;
}

# }}}
# has_feature - returns true if the environment requests the given feature {{{
sub has_feature {
	my ($self, $feature) = @_;
	for my $have ($self->features) {
		return 1 if $feature eq $have;
	}
	return 0;
}

# }}}
# params - get all the values from the hierarchal environment. {{{
sub params {
	return $_[0]->_memoize(sub {
		my $manifest_type = envset("GENESIS_UNEVALED_PARAMS")
			? 'unevaluated_environment'
			: 'partial_environment';
		$_[0]->manifest_provider->$manifest_type->data;
	});
}

# }}}
# defines - true if the given path is defined in the hierarchal environment parameters. {{{
sub defines {
	my ($self, $key) = @_;
	my $found;
	if (defined($self->{__params})) {
		(undef, $found) = struct_lookup($self->params(),$key);
	} else {
		(undef, $found) = $self->lookup_unevaled($key);
	}
	return defined($found);
}

# }}}
# lookup - look up a value from the heirarchal evironment {{{
sub lookup {
	my ($self, $key, $default) = @_;
	$key //= '.';
	return struct_lookup($self->params, $key, $default);
}

# }}}
# lookup_unevaled - look up a value from the heirarchal evironment without evaluating operators {{{
sub lookup_unevaled {
	my ($self, $key, $default) = @_;
	$key //= '.';
	return $default unless $self->actual_environment_files();
	return struct_lookup($self->manifest_provider->unevaluated_environment->data, $key, $default);
}

# }}}
# partial_manifest_lookup - look up a value from a best-effort merged manifest for this environment {{{
sub partial_manifest_lookup {
	my ($self, $key, $default) = @_;
	$key //= '.';
	return struct_lookup($self->manifest_provider->partial->data, $key, $default);
}

# }}}
# manifest_lookup - look up a value from a completely merged manifest for this environment {{{
sub manifest_lookup {
	my ($self, $key, $default) = @_;
	$key //= '.';
	return struct_lookup($self->manifest_provider->base_manifest->data, $key, $default);
}

# }}}
# last_deployed_lookup - look up values from the last deployment of this environment {{{
sub last_deployed_lookup {
	my ($self, $key, $default) = @_;
	$key //= '.';
	my $last_manifest = $self->{__last_deployed_lookup_manifest};
	unless ($last_manifest) {
		my $last_manifest_file = scalar($self->last_deployed_manifest(just => 'file'));
		die "No successfully deployed manifest found for $self->{name} environment"
			unless $last_manifest_file;
		$last_manifest = load_yaml_file($last_manifest_file);
		$self->{__last_deployed_lookup_manifest} = $last_manifest;
	}
	return struct_lookup($last_manifest, $key, $default);
}

# }}}
# exodus_lookup - lookup Exodus data from the last deployment of this (or named) deployment {{{
sub exodus_lookup {
	my ($self, $key, $default,$for) = @_;
	$key //= '.';
	$for ||= $self->exodus_slug;
	my $path =  $self->exodus_mount().$for;
	debug "Checking if $path path exists...";
	return $default unless $self->vault->has($path);
	debug "Exodus data exists, retrieving it and converting to json";

	my $extended = 0;
	if ($key =~ m#^(/[^:]*)(?::(.*))?#) {
		$path .= $1;
		$key = $2//'';
		$extended = 1;
	}

	my $out;
	if ($extended) {
		eval {$out = $self->vault->get_path($path);};
		bail "Could not get $for exodus data from the Vault: $@" if $@;
		return struct_lookup($out, $key, $default);
	} else {
		eval {$out = $self->vault->get($path);};
		bail "Could not get $for exodus data from the Vault: $@" if $@;
		my $exodus = unflatten($out);
		return struct_lookup($exodus, $key, $default);
	}
}

# }}}
# director_exodus_lookup - lookup Exodus data from the director that deploys this environment {{{
sub director_exodus_lookup {
	my ($self, $key) = (shift, shift);
	$key //= '.';
	my $default = shift if scalar(@_) % 2 == 1;
	my %opts = @_;

	# Return default (with undef source) if this is a create-env environment
	return (wantarray ? ($default, undef) : $default) if $self->use_create_env;

	# Check for cached data
	my $bosh_exodus = undef;
	my $ext_path = undef;
	if ($key =~ m#^(/[^:]*)(?::(.*))?#) {
		$ext_path = $1;
		$key = $2//'';
	}
	if (exists($self->{__director_exodus_cache}{$ext_path//''})) {
		$bosh_exodus = $self->{__director_exodus_cache}{$ext_path//''};
	} else {
		# FIXME: This assumes the bosh deployment is of type 'bosh' -- we need to pass in options to override this if needed.
		my $path = $self->bosh->exodus_path; # changed fromn ${bosh_exodus_mount}${bosh_alias}/$bosh_dep_type";
		my $out;
		if ($ext_path) {
			eval {$out = $self->bosh->vault->get_path("$path$ext_path");}; # changed from $bosh_vault to $self->bosh->vault
			bail "Could not get director exodus data from the Vault: $@" if $@;
		} else {
			eval {$out = $self->bosh->vault->get($path);}; # changed from $bosh_vault to $self->bosh->vault
			bail "Could not get director exodus data from the Vault: $@" if $@;
			$out = unflatten($out);
		}
		$bosh_exodus = $self->{__director_exodus_cache}{$ext_path//''} = $out;
	}
	return $bosh_exodus unless defined($key);
	return struct_lookup($bosh_exodus, $key, $default);
}
# }}}
# dereferenced_kit_metadata - get kit metadata that been filled with environment references {{{
sub dereferenced_kit_metadata {
	my ($self) = shift;
	return $self->kit->dereferenced_metadata(sub {
		my $val = $self->partial_manifest_lookup(@_);
		if (defined($val) && !ref($val) && $val =~ /\(\(\s*vault\s/) {
			my $full_val = eval { $self->manifest_lookup(@_) };
			return $full_val if defined($full_val) && !ref($full_val) && $full_val !~ /\(\(\s*vault\s/;
		}
		return $val;
	}, 1);
}

# }}}
# vault_paths - get the list of paths in the vault for this environment {{{
sub vault_paths {
	my ($self, %opts) = @_;

	$self->manifest_provider
		->base_manifest
		->get_vault_paths(notify=>$opts{notify}//1);
}

# }}}
# scale - returns the scale for the environment {{{
sub scale {
	my ($self) = @_;
	my $scale = $self->lookup('kit.scale');

	return $scale if $scale;
	eval {$scale = $self->director_exodus_lookup('scale',undef)};

	bug(
		"No scale set for %s environment, and no default scale set for ".
		"deployments under %s bosh director.",
		$self->name, $self->bosh->alias
	) if !$scale && $self->kit->requires_scale($self);

	return $scale//'';
}

# }}}
# iaas - returns the iaas for the environment {{{
sub iaas {
	my ($self) = @_;
	my $iaas = $self->lookup('kit.iaas');

	return lc($iaas) if $iaas;

	bail(
		"No IaaS type set for %s environment, which uses a create-env deployment. ".
		"Please set the `kit.iaas` in the enviroment file -- you can use #G{%s ".
		"%s edit} to do this.",
		$self->name,
		humanize_bin(),
		humanize_path($self->path($self->name))
	) if $self->use_create_env;

	eval {$iaas = $self->director_exodus_lookup('iaas') }; # FIXME: How to handle multiple CPIs?

	bail(
		"No IaaS type set for %s environment, and no default IaaS type set for ".
		"deployments under %s bosh director.",
		$self->name, $self->bosh->alias
	) if ! $iaas && $self->kit->requires_iaas($self);

	return lc($iaas//'');
}

# }}}

# OCFP Stuff
# is_ocfp - returns true if the environment is an OCFP environment {{{
sub is_ocfp {
	my $self = shift;
	return $self->has_feature('ocfp')
}

# }}}
# ocfp_type - returns the type of OCFP environment {{{
sub ocfp_type {
	my $self = shift;
	return '' unless $self->is_ocfp;
	my $name = $self->name;
	# Match -mgmt/-ocf at end or in middle, or mgmt-/ocf- at beginning
	if ($name =~ /-(mgmt|ocf)(?:-|$)/ || $name =~ /^(mgmt|ocf)-/) {
		return $1;
	} else {
		# If it doesn't match, assume it's an OCF environment
		return 'ocf';
	}
}

# }}}
# ocfp_env - returns the OCFP environment name used in vault {{{
sub ocfp_env {
	my $self = shift;
	my $name = $self->name;
	# If -mgmt/-ocf is at the end, replace dash with slash: foo-mgmt -> foo/mgmt
	if ($name =~ /^(.*)-(mgmt|ocf)$/) {
		return "$1/$2";
	}
	# If -mgmt/-ocf is in the middle or mgmt-/ocf- at the beginning, append at end
	# Examples: ocfp-aws-mgmt-us-east-1 -> ocfp-aws-mgmt-us-east-1/mgmt
	#           mgmt-production -> mgmt-production/mgmt
	elsif ($name =~ /-(mgmt|ocf)-/ || $name =~ /^(mgmt|ocf)-/) {
		my $type = $1;
		return "$name/$type";
	} else {
		# mgmt is mgmt, anything else is ocf
		return "$name/ocf";
	}
}

# }}}
#	ocfp_config - returns the OCFP configuration for the environment {{{
sub ocfp_config {
	my ($self) = @_;
	return scalar $self->_memoize(sub {
		return {} unless $self->is_ocfp();
		return scalar $self->vault->get_path($self->ocfp_config_base);
	});
}

# }}}
# ocfp_config_lookup - look up a value from the OCFP configuration {{{
sub ocfp_config_lookup {
	my ($self, $key, $default) = @_;
	return struct_lookup($self->ocfp_config, $key, $default);
}

# }}}

# Policies

# deployment_change_reason_required_policy - returns min length of reason if policy is enabled {{{
sub deployment_change_reason_required_size_policy {
	my $self = shift;
	return $self->_memoize(sub {
		# This comes from two places: OCFP config and the repo config.
		# The OCFP config takes precedence, but if it is not set, then
		# the repo config is used.  Default is false.
		my $length = $self->ocfp_config_lookup('policies.deployment_change_reason_required_size', undef);
		$length //= $self->top->config->get('deployment_change_reason_required_size', 0);
		return $length;
	});
}

# }}}
# user_provided_bosh_creds_policy - returns ignore, allow or require for how BOSH_USER/BOSH_PASSWORD env vars are handled {{{
sub user_provided_bosh_creds_policy {
	my $self = shift;
	return $self->_memoize(sub {
		# This comes from the OCFP config, then repo config, and defaults to 'ignore'.
		my $policy = $self->ocfp_config_lookup('policies.user_provided_bosh_creds', undef);
		$policy //= $self->top->config->get('user_provided_bosh_creds', 'ignore');
		bail(
			"Invalid value for user_provided_bosh_creds policy: %s. Valid values are 'ignore', 'allow', or 'require'.",
			$policy
		) unless $policy =~ /^(ignore|allow|require)$/;
		return $policy;
	});
}

# BOSH config stuff - Generic

sub bosh_config_name {
	return $_[0]->name.'.'.$_[0]->type;
}

# BOSH config stuff - CPI

# The CPI config is defined in the environment under the bosh-configs.cpi key.
# The contents of this key are defined as a hash, with the following keys:
#  - enabled: true/false
#  - based-on: 'parent' | <arbitrary name> # TBD: not sure if needed, or how to implement
#  - <arbitrary name>: <cpi config> - whatever the CPI needs to be configured

# Note: If using OCFP, the CPI is always enabled, but can be disabled by setting
# the 'enabled' key to false in the OCFP configuration.

# The current intent is to just apply this to the BOSH director deployments, but
# it could be extended to other deployments in the future (ie we don't know it
# _won't_ work for other deployments).

sub cpi_enabled {
	my $self = shift;
	return $self->cpi_config->{enabled}//$self->is_ocfp
}

sub cpi_config {
	my $self = shift;
	return $self->lookup('bosh-configs.cpi', {});
}

sub cpi_name {
	# REFACTOR: We need a way to determine the name of the cpi for the
	# environment.  In most cases, it will be whatever the director
	# is using, but in some cases, it may be different.  For example,
	# another BOSH deployment will use its own cpi name, and provide
	# its own cpi config.  This is already implmenented, but other cases
	# might need to be considered in the future:
	#
	# A currently unsupported reason for selecting a different cpi name is to
	# support multicloud deployments, where the cpi name is used to determine
	# which cloud is being targeted.
	my $self = shift;
	return undef unless $self->cpi_enabled;
	if ($self->has_hook('cpi-config')) {
		# TODO: Should the kit specify if it wants its own cpi name?
		return join('.', $self->name, $self->iaas, $self->type);
	}
	# Return the base cpi name of the director (now provided by exodus)
	#my $bosh_env = $self->bosh_env;
	#return join('.', $bosh_env->{name}, $self->iaas, $bosh_env->{dep_type}//'bosh')
	return scalar $self->director_exodus_lookup('default_cpi_config', undef);
}

sub cpi_credhub_base {
	# This is the location that the cpi credhub secrets will be uploaded to when
	# the environment is not uploading a director default CPI config.
	my $self = shift;
	my $base = $self->lookup('bosh-configs.cpi.credhub_base');
	return $base // ($self->credhub->base."genesis-entombed/");
}

# Bosh Config stuff - TODO: sort later
# bosh_config_names - returns a hash of bosh config names proved by the environment {{{
sub bosh_config_names {
	my $self = shift;
	# environments need to be given a name based on the environment name and type
	my $configs = {};
	my $prefix = $self->name . '/' . $self->type;
	my @config_types = $self->kit->provided_configs;
	for my $config_type (@config_types) {
		my ($type, $purpose) = split(/:/,$config_type,2); # Support multiple files per type
		push @{$configs->{$type}}, $prefix.($purpose ? ":$purpose" : '');
	}
	return $configs;
}

# }}}
# env_config_overrides - returns the bosh config overrides for the environment {{{
sub env_config_overrides {
	my ($self, $type) = @_;
	bug("No type specified for bosh config overrides") unless $type;
	my $overrides = $self->lookup("bosh-configs.$type", {});
	# TODO: Need to figure out where to find these overrides
	return $overrides;
}

# }}}
# director_config_overrides - returns the director config overrides for the environment {{{
sub director_config_overrides {
	my ($self, $type) = @_;
	bug("No type specified for director config overrides") unless $type;
	my $overrides = $self->director_exodus_lookup('/bosh-config/'.$type, {});
	return $overrides;
}

# }}}

## Secrets Plan
# is_vaultified - returns true if the environment is vaultified {{{
sub is_vaultified {
	my $self = shift;
	return $self->_memoize('__is_vaultified', sub {

		# Short circuit if we don't meed minimum requirements
		return 0 unless $self->feature_compatibility('3.0.0-rc.1')
			&& ! $self->use_create_env
			&& scalar($self->lookup('genesis.vaultify', 1));

		# If credhub is used explicitly, we can assume we're vaultified
		return 1 if $self->kit->uses_credhub;

		# We might still be using credhub, so check each blueprint file for
		# occurances of 'variables' blocks.  Return on finding at least one.
		my @files = map {
			my $f = $_;
			$f =~ /^\// ? $_ : $self->kit->path($_)
		} $self->kit_files;
		push (@files, $self->actual_environment_files);
		for my $file (@files) {
			# Make sure we're using the top path for relative files
			$file = $self->path($file) unless ($file =~ m#^/#);

			my $content = slurp($file) =~ s/\A---\n//r;
			my @pages = split(/\n---\n/,$content);
			for my $page (@pages) {
				if ($page =~ /^- /) {
					# Go-patch-based arrays file - spruce can't handle these, so need to
					# convert to hash format
					$page = "__ops__:\n$page";
				}
				# Skip empty pages (that may be multiple lines
				next if $page =~ /\A\s*\z/;

				my $data = load_yaml($page);
				next unless $data;
				return 1 if $data->{variables};
				if (exists $data->{__ops__}) {
					return 1 if grep {
						$_->{path} =~ /^\/variables\??\// &&
						$_->{type} ne 'remove'
					} @{$data->{__ops__}};
				}
			}
		}
		return 0;
	});
}

# }}}
# can_be_entombed - returns true if the environment can be entombed {{{
sub can_be_entombed {
	my $self = shift;
	$self->feature_compatibility('3.0.0-rc.1')
	&& ! $self->use_create_env
	&& scalar($self->lookup('genesis.entomb', 1));
}

# }}}
# secrets_store - get the vault store for the environment {{{
sub secrets_store {
	return $_[0]->_memoize(sub{
		my $self = shift;
		require Genesis::Env::Secrets::Store;
		Genesis::Env::Secrets::Store->provide($self, $self->vault);
	});
}

# }}}
# secrets_plan - get the secrets plan {{{
sub secrets_plan {
	my ($self, %opts) = @_;
	my $plan = $self->_memoize(sub {
		my @sources = ('Genesis::Env::Secrets::Parser::FromKit');
		push @sources, 'Genesis::Env::Secrets::Parser::FromManifest' if $self->is_vaultified;
		my $plan = Genesis::Env::Secrets::Plan
			->new($_[0], $self->secrets_store(), $self->credhub, verbose => !$opts{silent})
			->populate(@sources);
		$plan;
	});
	$plan = $plan->filter(@{$opts{paths}//[]});
	$plan->validate unless $opts{no_validate};
	$plan;
}

# }}}

# Environment Variables
# get_environment_variables - returns a hash of all environment variables pertaining to this Genesis::Env object {{{
sub get_environment_variables {
	my ($self, $hook) = @_;
	$hook //= '';

	my $env = $self->_memoize("__env_vars_for_".$hook, sub {
		my $self = shift;
		# Set up the environment variables

		my %env;

		$env{GENESIS_ROOT}        = $self->path;
		$env{GENESIS_ENVIRONMENT} = $self->name;
		$env{GENESIS_TYPE}        = $self->type;
		$env{GENESIS_PREFIX_TYPE} = $ENV{GENESIS_PREFIX_TYPE} || 'none';

		my ($bin, $env_ref)       = $self->get_call_path_with_env();
		$env{GENESIS_CALL}        =
		$env{GENESIS_CALL_BIN}    = $bin;
		$env{GENESIS_ENV_REF}     = $env_ref;
		$env{GENESIS_CALL_ENV}    = join(' ', $bin, $env_ref);

		if ($ENV{GENESIS_COMMAND}) {
			$env{GENESIS_CALL_PREFIX} = sprintf("%s %s %s", $env{GENESIS_CALL_BIN}, $env_ref, $ENV{GENESIS_COMMAND});
			$env{GENESIS_CALL_FULL} = $env{GENESIS_PREFIX_TYPE} =~ /(^search|file)$/
				? $env{GENESIS_CALL_PREFIX}
				: sprintf("%s %s '%s'", $env{GENESIS_CALL},$ENV{GENESIS_COMMAND}, $self->name);
		}

		# Full param json to reconstitution by from_envvars method.
		$env{GENESIS_ENVIRONMENT_PARAMS} = encode_json($self->params);

		# Genesis minimum version (if specified)
		my $min_version = $self->lookup('genesis.min_version');
		$env{GENESIS_MIN_VERSION} = $min_version if $min_version;

		# Vault ENV VARS
		if (my $descriptor = $self->lookup('genesis.vault')) {
			$env{GENESIS_ENV_VAULT_DESCRIPTOR} = $descriptor;
		}
		$env{GENESIS_TARGET_VAULT} = $env{SAFE_TARGET} = $self->vault->ref;
		$env{GENESIS_VERIFY_VAULT} = $self->vault->connect_and_validate->verify || "";

		# Kit ENV VARS
		$env{GENESIS_KIT_NAME}                 = $self->kit->name;
		$env{GENESIS_KIT_VERSION}              = $self->kit->version;
		$env{GENESIS_KIT_PATH}                 = $self->kit->path;
		$env{GENESIS_MIN_VERSION_FOR_KIT}      = $self->kit->genesis_version_min();
		if ($self->exists) {
			$env{GENESIS_ENV_IAAS}               = $self->iaas();
			$env{GENESIS_ENV_SCALE}              = $self->scale();
			$env{GENESIS_ENV_KIT_OVERRIDE_FILES} = join(' ', $self->kit->env_override_files);
		}

		# Genesis v2.7.0 Secrets management
		# This provides GENESIS_{SECRETS,EXODUS,CI}_{MOUNT,BASE}
		# as well as GENESIS_{SECRETS,EXODUS,CI}_MOUNT_OVERRIDE
		for my $target (qw/secrets exodus ci/) {
			for my $target_type (qw/mount base/) {
				my $method = "${target}_${target_type}";
				$env{uc("GENESIS_${target}_${target_type}")} = $self->$method();
			}
			my $method = "${target}_mount";
			my $default_method = "default_$method";
			$env{uc("GENESIS_${target}_MOUNT_OVERRIDE")} = ($self->$method ne $self->$default_method) ? "true" : "";
		}
		$env{GENESIS_VAULT_ENV_SLUG} = $self->env_vault_slug;
		$env{GENESIS_VAULT_PREFIX} = # deprecated in v2.7.0
		$env{GENESIS_SECRETS_PATH} = # deprecated in v2.7.0
		$env{GENESIS_SECRETS_SLUG} = $self->secrets_slug;
		$env{GENESIS_SECRETS_SLUG_OVERRIDE} = $self->secrets_slug ne $self->default_secrets_slug ? "true" : "";
		$env{GENESIS_ROOT_CA_PATH} = $self->root_ca_path;

		# Credhub support
		my %credhub_env = $self->credhub_connection_env;
		$env{$_} = $credhub_env{$_} for keys %credhub_env;

		# BOSH support
		if ($self->use_create_env) {
			$env{GENESIS_USE_CREATE_ENV} = $self->use_create_env eq 'unknown' ? 'unknown' : 'true';
			for my $bosh_env (qw/ALIAS ENVIRONMENT CA_CERT CLIENT CLIENT_SECRET DEPLOYMENT/) {
				$env{"BOSH_$bosh_env"}=undef; # clear out any bosh variables
			}
		} else {
			$env{GENESIS_USE_CREATE_ENV} = "false";
			$env{BOSH_ALIAS} = $self->bosh_alias;
			if ($self->{__bosh} || grep {$_ eq 'bosh'} ($self->kit->required_connectivity($hook))) {
				my %bosh_env = $self->bosh->environment_variables;
				$env{$_} = $bosh_env{$_} for keys %bosh_env;
			}
		}

		return \%env;
	});

	if ($hook ne 'new' && $hook ne 'features' && !defined($env->{GENESIS_REQUESTED_FEATURES})) {
		$env->{GENESIS_REQUESTED_FEATURES} = join(' ', $self->features);
	}

	return %$env
}

# }}}
# credhub_connection_env - returns environment variables hash for connecting to this environment's Credhub {{{
sub credhub_connection_env {
	my $self = shift;
	my ($credhub_src,$credhub_src_key) = $self->lookup(
		['genesis.credhub_env','genesis.bosh_env','params.bosh','genesis.env','params.env']
	);
	my %env=();

	my $credhub_info = {};
	$env{GENESIS_CREDHUB_EXODUS_SOURCE_OVERRIDE} = "";
	if ($credhub_src_key eq 'genesis.bosh_env') {
		my ($bosh_alias,$bosh_dep_type,$bosh_exodus_vault,$bosh_exodus_mount) = $self->_parse_bosh_env($credhub_src);
		$bosh_alias //= $self->name;
		$bosh_dep_type //= 'bosh';
		$bosh_exodus_mount //= $self->exodus_mount;
		my $bosh_vault = $self->vault;
		if ($bosh_exodus_vault) {
			$bosh_vault = Service::Vault->find_single_match_or_bail($bosh_exodus_vault);
			bail(
				"Could not access vault #C{$bosh_exodus_vault} to retrieve BOSH ".
				"director login credentials"
			) unless $bosh_vault && $bosh_vault->connect_and_validate;
		}
		$env{GENESIS_CREDHUB_EXODUS_SOURCE} = "$bosh_alias/$bosh_dep_type";
		$env{GENESIS_CREDHUB_ROOT}=sprintf("/%s-%s/%s-%s", $bosh_alias, $bosh_dep_type, $self->name, $self->type);
		$credhub_info = $bosh_vault->get("$bosh_exodus_mount/$bosh_alias/$bosh_dep_type");
	} else {
		$env{GENESIS_CREDHUB_EXODUS_SOURCE_OVERRIDE} =
			(($credhub_src_key || "") eq 'genesis.credhub_env') ? $credhub_src : "";

		my $credhub_path = $credhub_src;
		if ($credhub_src =~ /\/\w+$/) {
			$credhub_path  =~ s/\/([^\/]*)$/-$1/;
		} else {
			$credhub_src .= "/bosh";
			$credhub_path .= "-bosh";
		}
		$env{GENESIS_CREDHUB_EXODUS_SOURCE} = $credhub_src;
		$env{GENESIS_CREDHUB_ROOT}=sprintf("/%s/%s-%s", $credhub_path, $self->name, $self->type);
		$credhub_info = $self->exodus_lookup('.',undef,$credhub_src) if ($credhub_src);
	}

	if ($credhub_info) {
		$env{CREDHUB_SERVER} = $credhub_info->{credhub_url}||"";
		$env{CREDHUB_CLIENT} = $credhub_info->{credhub_username}||"";
		$env{CREDHUB_SECRET} = $credhub_info->{credhub_password}||"";
		$env{CREDHUB_CA_CERT} = sprintf("%s%s",$credhub_info->{ca_cert}||"",$credhub_info->{credhub_ca_cert}||"");
	}

	return %env;
}

# }}}

# Environment Dependencies
# connect_required_endpoints - ensure external dependencies are reachable {{{
sub connect_required_endpoints {
	my ($self, @hooks) = @_;
	my @endpoints;
	push(@endpoints, $self->kit->required_connectivity($_)) for (@hooks);
	for (uniq(@endpoints)) {
		$self->with_vault   if $_ eq 'vault';
		$self->with_bosh    if $_ eq 'bosh';
		$self->with_credhub if $_ eq 'credhub'; # TODO: write this...!
		bail("Unknown connectivity endpoint type #Y{%s} in kit #m{%s}", $_, $self->kit->id);
	}
	return $self
}

# }}}

# Environment Dependencies - Vault
# vault - get the vault instance for the environment, or default to the top level vault {{{
sub vault {
	my $ref = $_[0]->_memoize(sub {
		my ($self) = @_;
		my $vault_info = $self->get_ancestral_vault();
		return $self->top->vault() unless $vault_info;

		my $details = Service::Vault->parse_vault_descriptor($vault_info);

		return Service::Vault::Remote->rebind()
			if (
				in_callback &&
				$ENV{GENESIS_TARGET_VAULT} &&
				$ENV{GENESIS_TARGET_VAULT} eq $details->{url}
			);

		my %filter = ();
		$filter{verify} = ($details->{verify} && $details->{tls} ? 1 : 0 ) if $details->{tls};
		$filter{namespace} = $details->{namespace} || '';
		$filter{strongbox} = $details->{strongbox};

		return Service::Vault::Remote->attach(
			url => $details->{url},
			alias => $details->{alias},
			%filter
		);
	});
	return $ref;

}
# }}}
# with_vault - ensure this environment is able to connect to the Vault server {{{
sub with_vault {
	my $self = shift;
	$ENV{GENESIS_SECRETS_MOUNT} = $self->secrets_mount();
	$ENV{GENESIS_EXODUS_MOUNT} = $self->exodus_mount();
	bail("No vault specified or configured.")
		unless $self->vault;
	return $self;
}

# }}}
# get_ancestral_vault {{{
sub get_ancestral_vault {
	my ($self) = @_;

	my $vault_info = scalar($self->lookup_unevaled('genesis.vault', undef));
	bail(
		"Expecting #C{genesis.vault} to be a singular string value, not a ".lc(ref($vault_info))
	) if ref($vault_info);
	bail(
		"Cannot use spruce operator to specify #C{genesis.vault_info}"
	)	if $vault_info && $vault_info =~ /^\(\(/;
	return $vault_info;
}

# }}}
# root_ca_path - returns the root_ca_path, if provided by the environment file (env: GENESIS_ROOT_CA_PATH) {{{
sub root_ca_path {
	my $self = shift;
	unless (exists($self->{__root_ca_path})) {
		$self->{__root_ca_path} = $self->lookup('genesis.root_ca_path','');
		$self->{__root_ca_path} =~ s/\/$// if $self->{__root_ca_path};
	}

	return $self->{__root_ca_path};
}

# }}}
# secrets_mount - returns the Vault path under which all secrets are stored (env: GENESIS_SECRETS_MOUNT) {{{
sub default_secrets_mount { '/secret/'; }
sub secrets_mount {
	$_[0]->_memoize(sub{
		(my $mount = $_[0]->lookup('genesis.secrets_mount', $_[0]->default_secrets_mount)) =~ s#^/?(.*?)/?$#/$1/#;
		return $mount
	});
}

# }}}
# secrets_slug - returns the component of the Vault path under the mount that represents this environment (env: GENESIS_SECRETS_SLUG) {{{
sub env_vault_slug {
	(my $p = $_[0]->name) =~ s|-|/|g;
	return $p;
}
sub default_secrets_slug {
	return $_[0]->env_vault_slug()."/".$_[0]->top->type;
}
sub secrets_slug {
	$_[0]->_memoize(sub {
		my $slug = $_[0]->lookup(
			['genesis.secrets_path','params.vault_prefix','params.vault'],
			$_[0]->default_secrets_slug
		);
		$slug =~ s#^/?(.*?)/?$#$1#;
		return $slug
	});
}

# }}}
# secrets_base - returns the full Vault path for secrets stored for this environment with / suffic (env: GENESIS_SECRETS_BASE) {{{
sub secrets_base {
	$_[0]->_memoize(sub {
		$_[0]->secrets_mount . $_[0]->secrets_slug . '/'
	});
}

# }}}
# exodus_mount - returns the Vault path under which all Exodus data is stored (env: GENESIS_EXODUS_MOUNT) {{{
sub default_exodus_mount { $_[0]->secrets_mount . 'exodus/'; }
sub exodus_mount {
	$_[0]->_memoize(sub {
		(my $mount = $_[0]->lookup('genesis.exodus_mount', $_[0]->default_exodus_mount)) =~ s#^/?(.*?)/?$#/$1/#;
		return $mount;
	});
}

# }}}
# exodus_slug - returns the component of the Vault path under the Exodus mount for this environment's Exodus data {{{
sub exodus_slug {
	sprintf("%s/%s", $_[0]->name, $_[0]->type);
}

# }}}
# exodus_base - returns the full Vault path of the Exodus data for this environment (env:  GENESIS_EXODUS_BASE) {{{
sub exodus_base {
	$_[0]->_memoize(sub {
		$_[0]->exodus_mount . $_[0]->exodus_slug
	});
}

# }}}
# ci_mount - returns the Vault path under which all CI secrets are stored (env: GENESIS_CI_MOUNT) {{{
sub default_ci_mount { $_[0]->secrets_mount . 'ci/'; }
sub ci_mount {
	$_[0]->_memoize(sub {
		(my $mount = $_[0]->lookup('genesis.ci_mount', $_[0]->default_ci_mount)) =~ s#^/?(.*?)/?$#/$1/#;
		return $mount;
	});
}

# }}}
# ci_base - returns the full Vault path under which the CI secrets for this environment are stored (env: GENESIS_CI_BASE) {{{
sub ci_base {
	$_[0]->_memoize(sub {
		my $default = sprintf("%s%s/%s/", $_[0]->ci_mount, $_[0]->type, $_[0]->name);
		(my $base = $_[0]->lookup('genesis.ci_base', $default)) =~ s#^/?(.*?)/?$#/$1/#;
		return $base
	});
}

# }}}
# ocfp_config_mount - returns the Vault path under which all ocfp_config data is stored (env: GENESIS_OCFP_CONFIG_MOUNT) {{{
sub default_ocfp_config_mount { $_[0]->secrets_mount . $_[0]->lookup('params.ocfp_vault_config_prefix','config') . '/'; }
sub ocfp_config_mount {
	$_[0]->_memoize(sub {
		(my $mount = $_[0]->lookup('genesis.ocfp_config_mount', $_[0]->default_ocfp_config_mount)) =~ s#^/?(.*?)/?$#/$1/#;
		return $mount;
	});
}

# }}}
# ocfp_config_slug - returns the component of the Vault path under the ocfp_config mount for this evironments ocfp_config data {{{
sub ocfp_config_slug {
	my $self = shift;
	# 1. Explicit slug override (full slug including env type)
	my $slug = $self->lookup('params.ocfp_vault_config_slug');
	return $slug if defined $slug;

	# 2. Bloc name from env file (just the bloc name, env type appended)
	my $bloc = $self->lookup('ocfp.bloc');
	if (defined $bloc) {
		return $bloc . "/" . $self->ocfp_type;
	}

	# 3. Fallback: derive from environment name
	return $self->ocfp_env;
}

# }}}
# ocfp_config_base - returns the full Vault path of the ocfp_config data for this environment (env:  GENESIS_OCFP_CONFIG_BASE) {{{
sub ocfp_config_base {
	$_[0]->_memoize(sub {
		$_[0]->ocfp_config_mount . $_[0]->ocfp_config_slug
	});
}

sub ocfp_subnet_prefix {
	return $_[0]->lookup('params.ocfp_subnet_prefix') // 'ocfp';
}

# }}}

# Environment Dependencies - CredHub
# credhub - get the credhub instance for the environment {{{
sub credhub {
	my $ref = $_[0]->_memoize(sub {
		require Service::Credhub;
		my ($self) = @_;
		my %env = $self->credhub_connection_env;
		my $credhub = Service::Credhub->new(
			$self->deployment_name,
			$env{GENESIS_CREDHUB_ROOT},
			$env{CREDHUB_SERVER},
			$env{CREDHUB_CLIENT},
			$env{CREDHUB_SECRET},
			$env{CREDHUB_CA_CERT}
		);
		return $credhub;
	});
	return $ref;
}
# }}}

# Environment Dependencies - BOSH and BOSH Config Files
# with_bosh - ensure the BOSH director is available and authenticated {{{
sub with_bosh {
	$_[0]->bosh->connect_and_validate;
	$_[0];
}

# }}}
# bosh_env - return the bosh_env for this environment {{{
sub bosh_env {
	my $data = $_[0]->_memoize(sub {
		my $self = shift;
		my $env_bosh_target = scalar($self->lookup('genesis.bosh_env', $self->is_bosh_director ? undef : $self->{name}));
		return {} unless $env_bosh_target;
		return scalar($self->_parse_bosh_env($env_bosh_target));
	});
	return wantarray ? @$data{'name', 'dep_type','vault_url','exodus_mount','description'} : $data;
}

# }}}
# bosh_alias - return the alias of the bosh used to deploy this environment (diminutive of bosh_env) {{{
sub bosh_alias {
	return $_[0]->bosh_env->{name};
}

# }}}
# bosh - the Service::BOSH::Director (or ::CreateEnvProxy) associated with this environment {{{
sub bosh {
	scalar $_[0]->_memoize(sub {
		my $self = shift;
		my $bosh;
		return Service::BOSH::CreateEnvProxy->new($self) if $self->use_create_env;

		# If we're in a callback or under test, just reload from envirionemnt variables.
		if (in_callback || under_test) {
			if ($ENV{GENESIS_BOSH_ENVIRONMENT} && $ENV{BOSH_CLIENT} && is_valid_uri($ENV{GENESIS_BOSH_ENVIRONMENT})) {
				$ENV{BOSH_ENVIRONMENT} = $ENV{GENESIS_BOSH_ENVIRONMENT};
				$ENV{BOSH_ALIAS} ||= scalar($self->lookup('genesis.bosh_env', $self->{name}));
				$ENV{BOSH_DEPLOYMENT} ||= $self->deployment_name;
				$bosh = Service::BOSH::Director->from_environment();
				return $bosh if $bosh;
			}
		}

		# bosh env can be <alias>[/<deployment-type>]@[http(s?)://<host>[:<port>]/][<mount>]
		my ($bosh_alias,$bosh_dep_type,$bosh_exodus_vault_url,$bosh_exodus_mount) = $self->bosh_env;

		my $bosh_vault = $self->vault;
		if ($bosh_exodus_vault_url) {
			$bosh_vault = Service::Vault->find_single_match_or_bail($bosh_exodus_vault_url);
			bail(
				"Could not access vault #C{$bosh_exodus_vault_url} to retrieve BOSH ".
				"director login credentials"
			) unless $bosh_vault && $bosh_vault->connect_and_validate;
		}

		$bosh = Service::BOSH::Director->from_exodus(
			$bosh_alias,
			$self,
			exodus_vault => $bosh_vault,
			exodus_mount => $bosh_exodus_mount,
			bosh_deployment_type => $bosh_dep_type,
			deployment => $self->deployment_name,
			rel_to_env => 'parent',
		) || Service::BOSH::Director->from_alias(  # FIXME: Need to pass in vault and mount/path if this ever gets used...
			$bosh_alias,
			$self,
			rel_to_env => 'parent',
			deployment => $self->deployment_name
		);
		bail(
			"Could not find BOSH director #M{%s} (under exodus #C{%s%s} or by alias in ~/.bosh/config)",
			$bosh_alias,
			$bosh_exodus_mount || $self->exodus_mount,
			$bosh_vault->name eq $self->vault->name ? "" : " in vault ".$bosh_vault->ref

		) unless $bosh;

		warning(
			"Calling shell has BOSH_ALIAS set to %s, but this environment specifies ".
			"the #M{%s} BOSH director; ignoring \$BOSH_ALIAS set in shell\n",
			$ENV{BOSH_ALIAS}, $bosh->alias
		) if ($ENV{BOSH_ALIAS} && $ENV{BOSH_ALIAS} ne $bosh->{alias});

		if ($ENV{BOSH_ENVIRONMENT}) {
			if (is_valid_uri($ENV{BOSH_ENVIRONMENT})) {
				warning(
					"Calling shell has BOSH_ENVIRONMENT set to %s, but this environment ".
					"specifies the BOSH director at #M{%s}; ignoring \$BOSH_ENVIRONMENT ".
					"set in shell.\n",
					$ENV{BOSH_ENVIRONMENT}, $bosh->url
				) if ($ENV{BOSH_ENVIRONMENT} ne $bosh->url);
			} else {
				error(
					"Calling shell has BOSH_ENVIRONMENT set to %s, but this environment ".
					"specifies the #M{%s} BOSH director; ignoring \$BOSH_ENVIRONMENT set ".
					"in shell.\n",
					$ENV{BOSH_ENVIRONMENT}, $bosh->alias
				) if ($ENV{BOSH_ENVIRONMENT} ne $bosh->alias);
			}
		}

		return $bosh;
	});
}
# }}}
# get_target_bosh - determine the correct BOSH to target for this environment {{{

# REFACTOR: We need an internal method for being able to get the bosh director
#           that this environment is, rather than the director that deloys this
#           environment.  The below does this, but its has too much user-facing
#           output that wouldn't apply to internal usage.
sub get_target_bosh {
	my $self = shift;
	my $options = ref($_[0]) eq 'HASH' ? shift : {@_}; # allow for explicit or implicit option hash
	my $bosh;
	my $bosh_exodus_path;

	my $is_director = $self->is_bosh_director;
	my $is_create_env = $self->use_create_env;

	# Handle invalid option combinations first
	bail(
		"Cannot use the #y{--self} and #y{--parent} options together."
	) if ($options->{self} && $options->{parent});
	my $target = (grep {$options->{$_}} qw/self parent/)[0]//'';

	bail(
		"Environment %s is a #M{create-env} deployment, so the #y{--parent} option is invalid.",
		$self->name
	) if ($is_create_env && $target eq 'parent');

	bail(
		"Environment %s is not a BOSH director, so the #y{--self} option is invalid.",
		$self->name
	) if (!$is_director && $target eq 'self');

	bail(
		"Environment %s is a #M{create-env} deployment, but not a BOSH director, ".
		"so there is no BOSH director to target.",
		$self->name
	) if (!$is_director && $is_create_env);

	# Issue warnings for unnecessary options
	unless ($Genesis::RC->get('suppress_warnings.bosh_target' => 0)) {
		warning(
			"\nEnvironment %s is a create-env BOSH director, so the #y{--self} option is unnecessary.\n",
			$self->name
		) if ($is_director && $is_create_env && $target eq 'self');
		warning(
			"\nEnvironment %s is not a BOSH director, so the #y{--parent} option is unnecessary.\n",
			$self->name
		) if (!$is_director && $target eq 'parent');
	}

	# Determine target
	$target ||= 'self' if $is_director && $is_create_env;
	$target ||= 'parent' if !$is_director;
	$target ||= $Genesis::RC->get('default_bosh_target' => 'ask');

	if ($target eq 'ask') {
		# BOSH director deployed by another director - need to ask
		bail(
			"Environment #C{%s} is a BOSH director deployed by another BOSH ".
			"director.  You must specify either #y{--self} or #y{--parent} option ".
			"to target it or its deploying director respectively.",
			$self->name
		) unless in_controlling_terminal;

		my $self_name = $self->name;
		my $bosh_alias = $self->bosh_alias;
		$target = prompt_for_choice(
			"Which BOSH director do you want to target?",
			['self', 'parent'],
			'self',
			[ map {[ $_, s/: .*//r ]} map {csprintf("%s", $_)} (
				"#C{$self_name}: this environment",
				"#C{$bosh_alias}: the BOSH director that deployed this environment"
			) ]
		);
	}

	if ($target eq 'self') {
		$bosh_exodus_path=$self->exodus_base;
		my $exodus_data = eval {$self->vault->get($bosh_exodus_path)};
		if ($exodus_data->{url} && $exodus_data->{admin_password}) {
			$bosh = Service::BOSH::Director->from_exodus($self->name, $self,
				exodus_data => $exodus_data,
				exodus_vault => $self->vault,
				exodus_path => $bosh_exodus_path,
				rel_to_env => 'self'
			);
		} else {
			# FIXME: If the environment uses BOSH aliases (ie due to requiring users to log in),
			#        then we will need to update the from_alias method and call to resolve bosh
			#        connection details from the vault and exodus path -- see above.
			$bosh = Service::BOSH::Director->from_alias($self->name, $self, rel_to_env => 'self');
		}
	} else {
		$bosh = $self->bosh;
		$bosh_exodus_path = $self->exodus_base;
	}
	bail(
		"No BOSH connection details found.  This may be due to not having read ".
		"access to the BOSH deployment's exodus data in vault (#M{%s}).",
		$bosh_exodus_path
	) unless $bosh;

	return wantarray ? ($bosh, $target, $bosh_exodus_path) : $bosh;
}
# }}}

# Config Management
# configs - return the list of configs being used by this environment. {{{
sub configs {
	my @env_configs = map {
		$_ =~ m/GENESIS_([A-Z0-9_-]+)_CONFIG(?:_(.*))?$/;
		lc($1).($2 && $2 ne '*' ? "\@$2" : '');
	} grep {
		/GENESIS_[A-Z0-9_-]+_CONFIG(_.*)?$/;
	} keys %ENV;
	my @configs = sort(uniq(keys %{$_[0]->{__configs}}, @env_configs));
	return wantarray ? @configs : \@configs; # can't just return the above because scalar/list context crazies
}

# }}}
# required_configs - determine what BOSH configs are needed {{{
sub required_configs {
	my ($self, @hooks) = @_;
	return () if $self->use_create_env;
	my @deploy_hooks = $self->_memoize('__deploy_hooks', sub {
		my $self = shift;
		my @h = qw/blueprint check manifest/;
		push @h, grep {$self->kit->has_hook($_)} qw(pre-deploy post-deploy);
	});
	my @expanded_hooks;
	push(@expanded_hooks, ($_ eq 'deploy' ? @deploy_hooks : $_)) for (@hooks);
	return $self->kit->required_configs(uniq(@expanded_hooks));
}

# }}}
# missing_required_configs - determine what BOSH configs are missing {{{
sub missing_required_configs {
	my ($self, @hooks) = @_;
	return grep {!$self->has_config($_)} $self->required_configs(@hooks);
}

# }}}
# has_required_configs - determine what BOSH configs are needed {{{
sub has_required_configs {
	my ($self, @hooks) = @_;
	return scalar($self->missing_required_configs(@hooks)) == 0;
}

# }}}
# download_required_configs - determzoine what BOSH configs are needed and download them {{{
sub download_required_configs {
	my ($self, @hooks) = @_;
	my @configs = $self->missing_required_configs(@hooks);
	return $self unless @configs;
	debug "Missing configs: ".join(', ', @configs);
	$self->with_bosh->download_configs(@configs);
	return $self
}

# }}}
# download_configs - download the specified BOSH configs from the director {{{
sub download_configs {
	my ($self, @configs) = @_;
	@configs = qw/cloud runtime/ unless @configs;

	info "Downloading configs from #M{%s} BOSH director...", $self->bosh->{alias};
	my $err;
	for (@configs) {
		my $file = "$self->{__tmp}/$_.yml";
		my ($type,$name) = split('@',$_);
		$name ||= '*';
		my $label = $name eq "*" ? "all $type configs" : $name eq "default" ? "$type config" : "$type config '$name'";
		info {pending => 1}, bullet('empty',$label."...", box => 1);
		my @downloaded = eval {$self->with_bosh->bosh->download_configs($file,$type,$name)};
		if ($@) {
			$err = $@;
			info(
				"\r".bullet(
					'bad',$label.join("\n      ", ('...failed!',"",split("\n",$err),"")),
					box => 1
				)
			);
		} else {
			info(
				"[2K\r".bullet(
					'good',$label.($name eq '*' ? ':' : ''),
					box => 1
				)
			);
			$self->use_config($file,$type,$name);
			for (@downloaded) {
				$self->use_config($file,$_->{type},$_->{name});
				info(
					bullet('good',$_->{label}, box => 1, indent => 7)
				)if $name eq "*";
			}
		}
	}

	bail(
		"Could not fetch requested configs from #M{%s} BOSH director at #c{%s}\n",
		$self->bosh->{alias}, $self->bosh->{url}
	) if $err;
	return $self;
}

# }}}
# use_config - specify a local file to use for the given BOSH config {{{
sub use_config {
	my ($self,$file,$type,$name) = @_;
	$self->{__configs} ||= {};
	my $label = $type ||= 'cloud';
	my $env_var = "GENESIS_".uc($type)."_CONFIG";
	if ($name && $name ne '*') {
		$label .= "\@$name";
		$env_var .= "_$name";
	}
	$self->{__configs}{$label} = $file;
	$ENV{$env_var} = $file;
	return $self;
}

# }}}
# has_config - determine if the environment has the specific config file set {{{
sub has_config {
	my ($self, $type, $name) = @_;
	!!$self->config_file($type,$name);
}

# }}}
# config_file - retrieve the path of the local file (provided or downloaded) being used for the named BOSH config {{{
sub config_file {
	my ($self, $type, $name) = @_;
	my $label = $type ||= 'cloud';
	my $env_var = "GENESIS_".uc($type)."_CONFIG";
	if ($name && $name ne '*') {
		$label .= "\@$name";
		$env_var .= "_$name";
	}
	return $self->{__configs}{$label} || $ENV{$env_var} || '';
}

sub config_contents {
	my ($self, %opts) = @_;
	my $type = $opts{type} // 'cloud';
	my $name = $opts{name};
	my $to_s = $opts{to_s} // 0;
	my $content = undef;
	# Bug in cloud config download causes all the cloud configs to point at the same file
	# which is already merged together: commenting out the following code for now..
	# if (!defined($name) || $name eq '*') {
	# 	# We need to merge all the configs together for the given type
	# 	my $file_ids = grep { /$type(\@.*)?$/ } $self->configs;
	# 	$name = $self->config_file($type);
	# } else {
	# 	$content = slurp($self->config_file($type,$name));
	# }
	if ($to_s) {
		return slurp($self->config_file($type,$name));
	} else {
		return load_yaml_file($self->config_file($type,$name))
	}
}

# }}}

# Legacy non-generic config methods {{{
# TODO: Remove these
sub download_cloud_config { $_[0]->download_configs('cloud'); }
sub use_cloud_config { $_[0]->use_config($_[1],'cloud'); }
sub cloud_config { return $_[0]->config_file('cloud'); }
sub download_runtime_config { $_[0]->download_configs('runtime'); }
sub use_runtime_config { $_[0]->use_config($_[1],'runtime'); }
sub runtime_config { return $_[0]->config_file('runtime'); }

# }}}

# Kit Components
# kit_files - get list of yaml files from the kit to be used to merge the manifest {{{
sub kit_files {
	my ($self, $absolute) = @_;
	$absolute = !!$absolute; #booleanify it.
	$self->{__kit_files}{$absolute} ||= [$self->kit->source_yaml_files($self, $absolute)];
	return @{$self->{__kit_files}{$absolute}};
}

# }}}
# has_hook - true if the environment's kit provides the specified hook {{{
sub has_hook {
	my $self = shift;
	return $self->kit->has_hook(@_);
}

# }}}
# run_hook - runs the specified hook in the environment's kit {{{
sub run_hook {
	my ($self, $hook, %opts) = @_;
	my @config_hooks = ($hook);
	push(@config_hooks, "addon-".$opts{script})
		if ($hook eq 'addon');

	$self->connect_required_endpoints(@config_hooks);
	$self->download_required_configs(@config_hooks);
	debug "Started run_hook '$hook'";
	return $self->kit->run_hook($hook, %opts, env => $self);
}

# }}}
# shell - provide a bash shell with the hook environment variables and helper functions available {{{
sub shell {
	my ($self, %opts) = @_;
	if ($opts{hook}) {
		my @config_hooks = ($opts{hook});

		if ($opts{hook} =~ /^addon-/) {
			$opts{hook_script} = $opts{hook};
			push(@config_hooks, "addon");
			$opts{hook} = "addon";
		}

		$self->connect_required_endpoints(@config_hooks);
		$self->download_required_configs(@config_hooks);
	}
	info "#Y{Started shell environment for }#C{%s}#Y{:}", $self->name;
	return $self->kit->run_hook('shell', %opts, env => $self);
}

# }}}

# Manifest Management
# manifest_provider - builder for making manifests in different ways {{{
sub manifest_provider {
	return $_[0]->_memoize(sub {
		Genesis::Env::ManifestProvider->new($_[0]);
	});
}

# }}}
# deployment_manifest_type - returns the type of manifest to be generated for deploying this environment {{{
sub deployment_manifest_type {
	my ($self) = @_;

	my $entomb = $self->can_be_entombed;
	if ($self->is_vaultified && @{$self->manifest_provider->unevaluated->data->{variables}//[]}) {
		return $entomb ? 'vaultified_entombed' : 'vaultified';
	} else {
		return $entomb ? 'entombed' : 'unredacted';
	}
}

# }}}
# prunable_keys - list the keys that can be pruned from a manifest and still be deployable {{{
sub prunable_keys {
	return @{$_[0]->_memoize( sub {
		my @keys = (qw(
			meta pipeline params bosh-variables bosh-configs kit genesis exodus compilation
		));
		if (!$_[0]->use_create_env) {
			# bosh create-env needs these, so we only prune them
			# when we are deploying via `bosh deploy`.
			push(@keys, (qw(
				resource_pools vm_types disk_pools disk_types networks azs vm_extensions
			)));
		}
		return \@keys;
	})};
}
# }}}
# last_deployed_manifest - get the details of last deployed manifest {{{
sub last_deployed_manifest {
	my ($self, %opts) = @_;

	# Deployed manifest data is found in three places:
	# 1. In the environment's exodus data under the deployed/<timestamp>/ subpath
	#    under the nominal exodus mount path (ie /secret/exodus/<env>/<type>)
	#    It contains keys for manifest package, type, and sha1sum, as well as who
	#    deployed it.  The manifest package is a tarball, containing the
	#    manifest.yml and other support files, such as vars, state and store.
	#
	# 2. In the environment's exodus data at the nominal exodus mount path, under
	#    the keys 'manifest', 'manifest_type', 'manifest_sha1'. This is the
	#    most recent deployed manifest, implemented in v3.0.0, but being phased
	#    out in favor of the deployed/<timestamp> method.
	#
	# 3. In the .genesis/manifests/ directory in the deployment repository, under
	#    the name of the environment, with a .yml extension.  This is the legacy
	#    method of storing the manifest, and is being phased out in favor of the
	#    exodus method, though may still be used by setting the deployment
	#    config file's 'manifest_store' to 'repository'.
	#
	# Returns depend on options sent in:
	# - just => 'manifest' or 'manifest_file' to return just the manifest or the
	#  path to the manifest file, along with the type, sha1sum, and source.  If
	#  an error occurs, it will return the error message as the fifth element if
	#  fail_on_error option is true.
	#
	# - files => 1 to include the paths to the files in the results (default is
	#   false)
	#
	# - contents => 1 to include the contents of the files in the results (default
	#   is true, set to 0 to not include the contents)

	# REFACTOR:  Now that we have Env::Deployments, we should use that unified
	#            interface to retrieve deployment data, including files, and for
	#            legacy deployments, manufacture a local-file-hash formatted
	#            deployment object that can be used to retrieve the manifest
	#            and other files.

	$self->notify('retrieving previously deployed manifest data:');

	my $just_return = $opts{just} || '';
	bug(
		"Invalid value for 'just' option: %s.  Must be 'contents' or 'file'",
		$just_return
	) if $just_return && $just_return !~ /^(contents|file)$/;
	my $include_files = $opts{files} || 0;
	my $pruned = !exists($opts{pruned}) || $opts{pruned} || 0;
	my $include_contents = !exists($opts{contents}) || $opts{contents} || 0;

	my $results = undef;
	my $start = gettimeofday;
	my @errors;
	while (1) {
		if ($self->manifest_store ne 'repository') {
			my $deploy_date = $self->exodus_lookup('dated');
			info({pending => 1},
				"  - looking for cached manifest..."
			);
			my $deployment = $self->deployments->latest;
			info("#G{done}" . pretty_duration(gettimeofday - $start));
			$start = gettimeofday;
			if ($deployment && $deployment->action eq 'deploy') {
				info({pending => 1},
					"  - found manifest in exodus/deployments - retrieving..."
				);
				my $type = $deployment->lookup(['manifest.type', 'manifest_type']);
				my $sha2 = $deployment->lookup(['manifest.sha2', 'manifest_sha2']);
				my $source = 'exodus-deployments';

				# Extract the artifiacts
				my @artifacts = $deployment->artifact_types();
				my $manifest_target = $pruned ? 'manifest' : 'unpruned';
				unless (in_array($manifest_target, @artifacts)) {
					push(@errors, sprintf(
						"Manifest for %s %s is not in the tarball of deployment artifacts",
						$pruned ? 'pruned' : 'unpruned',
						$self->name
					));
					last;
				}
				if ($just_return eq 'contents') {
					my $manifest = $deployment->artifact($manifest_target);
					info("#G{done}".pretty_duration(gettimeofday - $start));
					$results = wantarray ? [$manifest, $type, $sha2, $source] : $manifest;
					last
				}
				mkdir_or_fail($self->workpath('manifests')) unless -d $self->workpath('manifests');
				if ($just_return eq 'file') {
					my $manifest_file = $deployment->extract_artifacts_to(
						$self->workpath("manifests/"), $manifest_target
					);
					info("#G{done}".pretty_duration(gettimeofday - $start));
					$results = wantarray ? [$manifest_file, $type, $sha2, $source] : $manifest_file->{manifest};
					last;
				}

				$results = {
					manifest_type => $type,
					manifest_sha2 => $sha2,
					dated         => $deploy_date,
					deployer      => $deployment->user_description,
					timestamp     => $deployment->timestamp,
					source        => $source,
					artifacts     => []
				};
				for my $name ($deployment->artifact_filenames()) {
					my $file_type =
						$name eq $self->name.".yml" ? 'manifest' :
						$name eq $self->name.'.vars' ? 'vars' :
						$name eq $self->name.'-state.json' ? 'state' :
						$name eq $self->name.'-store.yml' ? 'store' :
						$name eq $self->name.'-unpruned.yml' ? 'unpruned' :
						$name eq $self->name.'-output.log' ? 'log' :
						"other/$name";

					push(@{$results->{artifacts}}, $file_type);
					$results->{$file_type}{source} = $source;
					$results->{$file_type}{sha2} = sha256_hex($deployment->artifact($name));
					if ($include_files) {
						my $artifact_path_map = $deployment->extract_artifacts_to(
							$self->workpath('manifests'), $name
						);
						$results->{$file_type}{path} = $artifact_path_map->{$name} if ($artifact_path_map->{$name});
					}
					$results->{$file_type}{data} = $deployment->artifact($name) if ($include_contents);
				}
				last;

			} else {
				# Check for manifest in base exodus data
				info({pending => 1},
					"  - fetching exodus data..."
				);
				my $manifest_data = $self->exodus_lookup('manifest');
				my $type = $self->exodus_lookup('manifest_type');
				my $sha1 = $self->exodus_lookup('manifest_sha1');
				info("#G{done}".pretty_duration(gettimeofday - $start));

				if ($manifest_data) {
					$start = gettimeofday;
					info({pending => 1},
						"  - found manifest in exodus - retrieving..."
					);
					my $source = 'exodus';
					my $compressed_data = decode_base64($manifest_data);
					unless ($compressed_data) {
						push(@errors, "Failed to decode base64 encoded manifest");
						last;
					}

					my $data;
					gunzip(\$compressed_data => \$data);

					my $is_pruned = ! grep {/^genesis:/} split /\n/, $data;
					if ($pruned && !$is_pruned) {
						my $file_sha1 = sha1_hex($data);
						my ($pruned_data, $rc, $err) = run(
							'fin=$1; shift 1; echo "$fin" | spruce merge "$@" -',
							$data,
							map {('--prune',$_)} $self->prunable_keys
						);
						if ($rc) {
							push(@errors,
								"Manifest is not pruned, and could not be retroactively pruned: ".
								($err//$pruned_data)
							);
							last;
						}
						if ($file_sha1 ne sha1_hex($data)) { # Check if original data has been tampered with
							push(@errors,
								"Manifest does not match specified sha1 at the time of deployment"
							);
							last;
						}
						$sha1 = sha1_hex($pruned_data); # We're going to fudge the sha1 because we pruned it
						$data = $pruned_data;
					} elsif (!$pruned && $is_pruned) {
						push(@errors, "Manifest is pruned, but unpruned manifest requested");
						last;
					}

					if ($just_return eq 'contents') {
						$results = wantarray ? [$data, $type, $sha1, $source] : $data;
						last;
					}
					my $manifest_file = $self->workpath('manifests/'.$self->name.".yml");
					if ($just_return eq 'file' || $opts{files}) {
						mkdir_or_fail(dirname($manifest_file)) unless -d dirname($manifest_file);
						mkfile_or_fail($manifest_file, $data);
						if ($just_return eq 'file') {
							$results =  wantarray ? [$manifest_file, $type, $sha1, $source] : $manifest_file;
							last;
						}
					}

					$results = {
						manifest_type => $type,
						manifest_sha1 => $sha1,
						dated => $deploy_date,
						deployer => scalar($self->exodus_lookup('deployer')),
						source => $source,
						artifacts => []
					};

					# Legacy workaround - find the non-manifest files in the local repo.
					# First, rename the state.yml file to state.json
					if (-f $self->path(".genesis/manifests/".$self->name."-state.yml")) {
						rename(
							$self->path(".genesis/manifests/".$self->name."-state.yml"),
							$self->path(".genesis/manifests/".$self->name."-state.json")
						);
					}
					my %files = (
						manifest => $manifest_file,
						state =>    $self->path(".genesis/manifests/".$self->name."-state.json"),
						store =>    $self->path(".genesis/manifests/".$self->name."-store.yml"),
						vars =>     $self->path(".genesis/manifests/".$self->name.".vars"),
					);

					for (grep {-f $files{$_}} keys %files) {
						push(@{$results->{artifacts}}, $_);
						$results->{$_}{source} = $_ eq 'manifest' ? $source : 'repository';
						$results->{$_}{sha1} = $_ eq 'manifest'
							? sha1_hex($data)
							: digest_file_hex($files{$_}, 'SHA-1');
						$results->{$_}{path} = $files{$_} if ($include_files);
						$results->{$_}{data} = ($_ eq 'manifest' ? $data : slurp($files{$_}))
							if ($include_contents);
					}
					info("#G{done}".pretty_duration(gettimeofday - $start));
					last;
				}
			}
		}

		# Check for legacy manifest file
		my $type = $self->exodus_lookup('manifest_type');
		my $sha1 = $self->exodus_lookup('manifest_sha1');
		my $mpath = $self->path(".genesis/manifests/".$self->name.".yml");

		if (-f $mpath) {
			info({pending => 1},
				"  - found manifest in .genesis/manifests - retrieving..."
			);

			my $data = load_yaml(slurp($mpath));
			my $is_pruned = exists($data->{genesis});
			if ($pruned && !$is_pruned) {
				push(@errors, "Manifest is not pruned, but pruned manifest requested");
				last;
			} elsif (!$pruned && $is_pruned) {
				push(@errors, "Manifest is pruned, but unpruned manifest requested");
				last;
			}

			if ($just_return eq 'contents') {
				$results = wantarray ? [$data, $type, $sha1, 'repository']: $data;
				last;
			} elsif ($just_return eq 'file') {
				$results = wantarray ? [$mpath, $type, $sha1, 'repository'] : $mpath;
				last;
			}
			$results = {
				manifest_type => $type,
				manifest_sha1 => $sha1,
				dated => scalar($self->exodus_lookup('dated')),
				deployer => scalar($self->exodus_lookup('deployer')),
				source => 'repository',
				artifacts => []
			};
			my %files = (
				manifest => $mpath,
				state =>    $self->path(".genesis/manifests/".$self->name."-state.yml"),
				store =>    $self->path(".genesis/manifests/".$self->name."-store.yml"),
				vars =>     $self->path(".genesis/manifests/".$self->name.".vars"),
			);
			;
			for (grep {-f $files{$_}} keys %files) {
				push(@{$results->{artifacts}}, $_);
				$results->{$_}{source} = 'repository';
				$results->{$_}{sha1} = digest_file_hex($files{$_}, 'SHA-1');
				$results->{$_}{path} = $files{$_} if ($include_files);
				$results->{$_}{data} = slurp($files{$_}) if ($include_contents);
			}
			last;
		} else {
			$results = $just_return  ? [undef, undef, undef, undef] : {not_found => 1};
			unless ($opts{fail_on_error}) {
				push(@errors, "No previously deployed manifest found.");
				last;
			}
		}
	}

	# Check if we have to try harder to find a state file
	if ($self->use_create_env && ref($results) eq 'HASH' && !exists($results->{state})) {
		# No state file found in the exodus-deployments data, so check
		# repository for it.
		my $local_path = $self->path(".genesis/manifests/".$self->name."-state.json");
		$local_path = $self->path(".genesis/manifests/".$self->name."-state.yml") if (! -f $local_path);
		if (-f $local_path) {
			$results->{state} = {
				source => 'repository',
				sha1 => digest_file_hex($local_path, 'SHA-1'),
			};
			$results->{state}{data} = slurp($local_path) if ($include_contents);
			$results->{state}{path} = $local_path if ($include_files);
			push(@{$results->{artifacts}}, 'state');
		}
	}

	if (scalar(@errors)) {
		push @$results, \@errors if ref($results) eq 'ARRAY';
		$results->{errors} = \@errors if ref($results) eq 'HASH';
		trace "Errors: ".join("\n",@errors);
	}
	if (wantarray) {
		trace 'Compound Results: '.Dumper($results);
		return %$results if ref($results) eq 'HASH';
		return @$results if ref($results) eq 'ARRAY';
		return ($results);
	} else {
		trace 'Scalar Results: '.Dumper($results);
		return $results;
	}
}

# }}}
# vars_file - create yml file and return path for bosh variables {{{
sub vars_file {
	my ($self,$redact,$file) = @_;
	my $manifest = $self->manifest_provider->deployment(subset=>'bosh_vars');
	$manifest = $manifest->redacted if $redact;
	$manifest->notify(sprintf(
		"generating %sBOSH variables file #i{(if applicable)}...",
		$redact ? "redacted " : ""
	));

	return unless scalar(keys %{$manifest->data});
	dump_var "BOSH Variables File" => $manifest->file, "Contents" => $manifest->data;
	if ($file) {
		save_to_yaml_file($manifest->data, $file);
	} else {
		$file = $manifest->file;
	}

	# BOSH variables won't interpolate more than once, so if a bosh variable
	# contains a reference to another bosh variable, it won't be resolved.
	# So, we'll have to resolve it for them.
	my $tries = 0;
	while (1) {
		my ($int_vars, $rc, $err) = $self->bosh->execute(
			'interpolate -l "$1" "$1"', $file
		);
		bail(
			"Failed to interpolate BOSH variables: %s",
			$err||$int_vars
		) if $rc;
		last if digest_file_hex($file, 'SHA-1') eq sha1_hex($int_vars);
		mkfile_or_fail($file, $int_vars);
		last if ++$tries >= 10;
	}
	return $file;
}

# }}}

# Deployment
# check - check the environment {{{
sub check {
	# TODO: should be moved to Genesis::Commands::Env::check
	my ($self,%opts) = @_;

	# FIXME: Check CPI exists if custom cpi is in use (not create-env)

	# FIXME: Check if cloud config exists if cloud-config hook exists (not create-env)

	my $ok = 1;
	my $env_check = $self->_check_environment_viability();
	bail("%s", $env_check->{msg}) if $env_check->{fatal};
	$ok = 0 unless $env_check->{state} eq 'ok';
	my $kit_files = $env_check->{kit_files};

	# TODO: Detect 'fix-secrets' option and run it against invalid or missing secrets, then run the check
	if (!exists($opts{check_secrets}) || $opts{check_secrets}) {
		my $secrets_check = $self->_check_secrets();
		my $msg_type = $secrets_check->{status};
		$msg_type = '%s' if $msg_type eq 'ok';

		$self->notify($msg_type => $secrets_check->{msg});
		$ok = 0 unless $secrets_check->{status} =~ /^(ok|warning)$/;
	}

	if ($opts{check_yamls}) {
		if ($self->missing_required_configs('blueprint')) {
			$self->notify("#Y{Required BOSH configs not provided - can't check manifest viability}");
		} else {
			$self->notify("inspecting YAML files used to build manifest...");
			my @yaml_files = $self->format_yaml_files('include-kit' => 1, padding => '  ', kit_files => $kit_files);
			info join("\n",@yaml_files)."\n";
		}
	}

	if ($ok) {
		if ($self->missing_required_configs('manifest')) {
			$self->notify("#Y{Required BOSH configs not provided - can't check manifest viability}");
		} elsif (!exists($opts{check_manifest}) || $opts{check_manifest}) {
			$self->notify("running manifest viability checks...");
			$self->manifest_provider->unredacted->validate or $ok = 0;
		}
	}

	# Check for release overrides in the environment file.
	if (!exists($opts{check_releases}) || $opts{check_releases}) {
		my $release_override_check = $self->_check_release_overrides();
		# Really nothing to do here, just check the status
	}

	# Check that HTTP/HTTPS release URLs have SHA1 checksums
	if (!exists($opts{check_release_sha1}) || $opts{check_release_sha1}) {
		my $release_sha1_check = $self->_check_release_url_sha1();
		if ($release_sha1_check->{state} eq 'error') {
			$ok = 0;
		}
	}

	# TODO: secrets check for Credhub (post manifest generation)
if ((!exists($opts{check_stemcells}) || $opts{check_stemcells}) && !$self->use_create_env) {
		my $stemcells_check = $self->_check_stemcells();
		my $msg_type = $stemcells_check->{status};
		$msg_type = '%s' if $msg_type eq 'ok';

		$self->notify($msg_type => $stemcells_check->{msg});
		$self->_advise_stemcell_updates($stemcells_check->{fix_data}) unless $stemcells_check->{status} eq 'ok';
		$ok = 0 unless $stemcells_check->{status} =~ /^(ok|warning)$/;
	}
	return $ok;
}

# }}}
# deployment_cache_setup - create the deployment cache directory {{{
sub deployment_cache_setup {
	my ($self) = @_;
	my $deploy_cache = $self->top->path('.genesis/deploy-cache/'.$self->name);
	mkdir_or_fail($deploy_cache) unless -d $deploy_cache;

	$self->{__deployment_cache_path} = $deploy_cache;
	$self->{__deployment_cache_files} = {
		manifest => $deploy_cache."/".$self->name.".yml",
		unpruned_manifest => $deploy_cache."/".$self->name."-unpruned.yml",
		redacted_manifest => $deploy_cache."/".$self->name."-redacted.yml",
		vars => $deploy_cache."/".$self->name.".vars",
		redacted_vars => $deploy_cache."/".$self->name."-redacted.vars",
		state => $deploy_cache."/".$self->name."-state.json",
		store => $deploy_cache."/".$self->name."-store.yml",
		deploy_log => $deploy_cache."/".$self->name."-output.log",
	};
}

# }}}
# deployment_cache_cleanup - remove the deployment cache {{{
sub deployment_cache_cleanup {
	my ($self) = @_;
	my $deploy_cache = $self->{__deployment_cache_path};
	if ($deploy_cache && -d $deploy_cache) {
		debug("cleaning up deployment cache...");
		rmtree($deploy_cache);
	}
}

# }}}
# deployment_cache_path_lookup - return the path to a file in the deployment cache {{{
sub deployment_cache_path_lookup {
	my ($self, $descriptor) = @_;
	return {} unless defined $self->{__deployment_cache_path};

	my $deploy_cache = $self->{__deployment_cache_path};
	return $deploy_cache unless $descriptor;

	my $files = $self->{__deployment_cache_files};
	return $files if $descriptor eq 'all';
	return {
		map {($_,$files->{$_})}
		grep {-f $files->{$_}}  # Only return existing files
		keys %$files
	} if $descriptor eq 'existing';
	bug("Invalid deployment cache path: %s", $descriptor) unless exists($files->{$descriptor});
	return $files->{$descriptor};
}

# }}}
# deploy - deploy the environment {{{
sub deploy {
	my ($self, %opts) = @_;
	my $noprompt = delete($opts{yes});

	if (my $min_reason_length = $self->deployment_change_reason_required_size_policy()) {
		bail(
			"Deployment without reason is not allowed - minimum length is %d characters",
			$min_reason_length
		) unless length($opts{reason}//'') > $min_reason_length;
	}
	$opts{reason} //= 'unknown';

	# TODO: Support the --resume option to resume a deployment
	$self->deployment_cache_setup;

	# Initialize deployment state
	$self->{deployment_state} = {
		opts => \%opts,
		noprompt => $noprompt,
		deploy_started => undef,
		results => [],
		ok => undef,
	};

	# Run pre-deployment phase
	my $predeploy_ok = $self->_pre_deploy(%opts, noprompt => $noprompt);
	return unless $predeploy_ok;

	# Run the actual deployment
	$self->use_create_env
		? $self->_deploy_create_env(%opts, noprompt => $noprompt)
		: $self->_deploy_to_bosh(%opts, noprompt => $noprompt);

	my $deploy_completed = gettimeofday;
	$self->notify(
		"BOSH deployment completed in %s",
		pretty_duration($deploy_completed - $self->{deployment_state}{deploy_started}, undef,undef, '','','-',1)
	);

	# Run post-deployment phase
	return $self->_post_deploy(%opts, noprompt => $noprompt);
}

# }}}
# _deployment_may_affect_secrets_vault - determine if deployment could seal secrets vault {{{
sub _deployment_may_affect_secrets_vault {
	my $self = shift;

	# Check for explicit configuration override
	my $explicit_config = $self->lookup('genesis.unseal_vault_after_deploy', undef);
	return $explicit_config if defined($explicit_config);

	return 0 unless $self->vault->initialized;

	# Check if deploying a vault kit
	if ($self->kit->provides_service('vault')) {
		debug("Vault service kit detected - deployment may affect secrets vault");

		# Check for static IPs in the vault kit
		my @kit_ips =
			map {IPv4->address($_)}
			grep {$_} map { ($_->{static_ips}//[])->@* }
			grep {$_} map { ($_->{networks}//[])->@* }
			@{scalar $self->manifest_lookup('instance_groups')};
		debug("Vault kit has static IPs: ".join(", ", @kit_ips)) if (@kit_ips);

		# Get ips from `safe status`
		my @vault_ips =
			map {IPv4->address($_)}
			grep {$_} map {$_ =~ m{https?://([^: ]*)} && $1}
			grep {$_ =~ /^http/}
			lines($self->vault->query('status'));
		debug("Active vault using IPs: ".join(", ", @vault_ips)) if (@vault_ips);

		my (undef, $shared_ips) = compare_arrays(\@kit_ips, \@vault_ips);
		return scalar(@$shared_ips) ? 1 : 0;
	}

	# Check if vault domain matches any external domain in the deployment
	my $vault_url = $self->vault->url;
	my ($vault_domain) = $vault_url =~ m{^https?://([^:/]+)};
	return 0 unless $vault_domain;

	# Look for external domain parameters that might match
	my @domain_params = qw(
		external_domain
		external_url
		domain
		vault_external_domain
		vault_domain
	);

	for my $param (@domain_params) {
		my $deploy_domain = $self->lookup($param, undef);
		next unless $deploy_domain;

		# Remove protocol if present
		$deploy_domain =~ s{^https?://}{};
		# Remove port if present
		$deploy_domain =~ s{:[0-9]+$}{};

		if ($vault_domain eq $deploy_domain) {
			debug("Vault domain '$vault_domain' matches deployment domain '$deploy_domain' (from $param)");
			return 1;
		}
	}

	debug("No indication that deployment will affect secrets vault");
	return 0;
}

# }}}
# _pre_deploy - handle pre-deployment setup and validation {{{
sub _pre_deploy {
	my ($self, %opts) = @_;
	my $noprompt = delete($opts{noprompt});

	# Generate and store the deployment manifest (pruned and unpruned versions)
	my $pruned_deploy_manifest = $self->manifest_provider->deployment(subset=>'pruned',notify=>1);
	my $unpruned_deploy_manifest = $self->manifest_provider->deployment(notify=>0);
	my $manifest_path = $self->deployment_cache_path_lookup('manifest');
	$pruned_deploy_manifest->write_to($manifest_path);
	my $unpruned_manifest_path = $self->deployment_cache_path_lookup('unpruned_manifest');
	$unpruned_deploy_manifest->write_to($unpruned_manifest_path);

	# Store paths in deployment state
	$self->{deployment_state}{manifest_path} = $manifest_path;
	$self->{deployment_state}{unpruned_manifest_path} = $unpruned_manifest_path;

	my ($ok, $predeploy_data, $data_fn) = ();
	my $vars_path = $self->vars_file(0, $self->deployment_cache_path_lookup('vars'));
	$self->{deployment_state}{vars_path} = $vars_path;

	if ($self->has_hook('pre-deploy')) {
		($ok, $predeploy_data) = $self->run_hook(
			'pre-deploy',
			manifest  => $manifest_path,
			vars_file => $vars_path
		);
		bail "Cannot continue with deployment!\n" unless $ok;
		$data_fn = $self->workpath("predeploy-data");
		mkfile_or_fail($data_fn, $predeploy_data) if ($predeploy_data);
		$self->{deployment_state}{predeploy_data} = $predeploy_data;
		$self->{deployment_state}{data_fn} = $data_fn;
	}

	my $disable_reactions = delete($opts{'disable-reactions'});
	$self->{deployment_state}{disable_reactions} = $disable_reactions;

	if ($self->_reactions) {
		if ($disable_reactions) {
			warning("\nReactions are disabled for this deploy");
		} else {
			$self->_validate_reactions;
			my $reaction_vars = {
				GENESIS_PREDEPLOY_DATAFILE => $data_fn,
				GENESIS_MANIFEST_FILE => $unpruned_manifest_path,
				GENESIS_BOSHVARS_FILE => $vars_path,
				GENESIS_DEPLOY_OPTIONS => JSON::PP::encode_json(\%opts),
				GENESIS_DEPLOY_DRYRUN => $opts{"dry-run"} ? "true" : "false"
			};
			$self->{deployment_state}{reaction_vars} = $reaction_vars;
			$ok = $self->_process_reactions('pre-deploy', $reaction_vars);
			bail(
				"Cannnot deploy: environment pre-deploy reaction failed!"
			) unless $ok;
		}
	}

	# Generate redacted versions for caching
	my $cached_redacted_manifest_path = $self->deployment_cache_path_lookup('redacted_manifest');
	my $cached_redacted_vars_path = $self->deployment_cache_path_lookup('redacted_vars');
	$self->manifest_provider->deployment->redacted->write_to($cached_redacted_manifest_path);
	$self->vars_file('redacted', $cached_redacted_vars_path);

	$self->{deployment_state}{cached_redacted_manifest_path} = $cached_redacted_manifest_path;
	$self->{deployment_state}{cached_redacted_vars_path} = $cached_redacted_vars_path;

	# Check if this deployment might affect the vault being used for secrets
	if ($self->_deployment_may_affect_secrets_vault()) {
		# Fetch vault unseal keys if available (for post-deploy unsealing)
		my ($success, $message) = $self->vault->fetch_unseal_keys($self);
		if (!$success) {
			debug("[[ERROR: >>%s", $message);
			bail(
				"Cannot proceed with deployment - vault unsealing will be required after deployment ".
				"but no unseal keys are available. Please ensure unseal keys are stored at:\n".
				"[[  >>#C{%s}vault/seal/keys:key[1-N]\n".
				"#Ki(where N is 3 or greater, normally 5)",
				$self->secrets_mount
			);
		} else {
			info('[[  #g@{+}>>%s', $message);
		}
	} else {
		debug("Skipping unseal key check - deployment does not appear to affect secrets vault");
	}

	$self->notify("all systems #G{ok}, initiating BOSH deploy...");
	return 1;
}

# }}}
# _deploy_create_env - handle create-env deployment {{{
sub _deploy_create_env {
	my ($self, %opts) = @_;
	my $noprompt = delete($opts{noprompt});
	my $state = $self->{deployment_state};

	debug("deploying this environment via `bosh create-env`, locally");
	my $last_manifest = $self->last_deployed_manifest(files => 1, contents => 0);

	my ($last_manifest_path, $last_manifest_sha1);
	unless ($last_manifest->{not_found}) {
		if ($last_manifest->{errors}) {
			$self->_cleanup_and_bail("Errors encountered while retrieving last deployed manifest: %s",
				join("\n", @{$last_manifest->{errors}})
			);
		}
		$last_manifest_path = ($last_manifest->{manifest}{path});
		$last_manifest_sha1 = $last_manifest->{manifest_sha1};
	}

	my $alternative_state_file = $opts{'STATE-FILE-PATH'};
	if ($alternative_state_file) {
		$alternative_state_file = absolute_path($alternative_state_file,$ENV{GENESIS_CALLER_DIR});
		$self->_cleanup_and_bail(
			"Alternative state file option specified, but does not appear to be valid file: %s",
			humanize_path($alternative_state_file)
		) if $alternative_state_file && !-f $alternative_state_file;
	}

	# Validate manifest consistency
	if ($last_manifest_path && ($last_manifest->{source}||'') ne 'exodus-deployments') {
		# Legacy method of storing state files, and possibly manifests
		my $last_state_path = $last_manifest->{state}{path};
		my $last_manifest_repo_path = $last_state_path =~ s/-state\.yml$/.yml/r;
		my $last_repo_sha1 = sha1_hex(slurp($last_manifest_repo_path));
		my $issue = '';

		if (!defined($last_manifest_sha1) || $last_manifest_sha1 eq '') {
			$issue = "Cannot confirm local cached deployment manifest pertains to ".
			         "the current deployment (sha1 sum missing from exodus data).";
		} elsif ($last_repo_sha1 ne $last_manifest_sha1) {
			$issue = "Manifest in the deployment archive does not match the manifest in the ".
			         "local repository; perhaps you need to perform a #C{git pull}.  #y{Differences ".
			         "will not be accurate for this deployment compared to what was last deployed.}";
		}
		if ($issue) {
			$issue .= "  #R{This may mean your state file is also out of date!}";
			if (in_controlling_terminal || !$noprompt) {
				warning("\n".$issue);
				prompt_for_boolean(
					"Proceed with BOSH create-env for the #C{${\($self->name)}} anyways? [y|n] ",
					0
				) or $self->_cleanup_and_bail("Aborted!\n");
				$self->notify("\nchecking for the currently deployed manifest...");
			} else {
				bail(
					"$issue\n\nRefusing to deploy to protect integrity of the environment."
				);
			}
		}
	}

	# Show diff if previous manifest exists
	if ($last_manifest_path) {
		bail(
			"Cannot find state file for previous deployment; cannot proceed with create-env."
		) unless $last_manifest->{state}{path};

		if ($last_manifest->{manifest}{source} eq 'repository' && !defined($last_manifest->{manifest_sha1})) {
			warning(
				"Cannot confirm local cached deployment manifest pertains to the ".
				"current deployment."
			);
		} elsif ($last_manifest_sha1 && $last_manifest_sha1 ne sha1_hex(slurp($last_manifest_path))) {
			warning(
				"Manifest in the deployment archive does not match the manifest in the ".
				"local repository; perhaps you need to perform a #C{git pull}.  #y{Differences ".
				"will not be accurate for this deployment compared to what was last deployed.}"
			);
		}

		info("\n[[  - >>comparing against the last deployed manifest...");
		my ($out, $rc, $err) = spruce_diff(
				{file => $last_manifest_path, label => 'last-deployed'},
				{file => $state->{manifest_path}, label => 'current'}
		);

		my ($vars_out, $vars_rc, $vars_err) = ('',0,'');
		if ($state->{vars_path} && -f $state->{vars_path}) {
			($vars_out, $vars_rc, $vars_err) = spruce_diff(
				{file => $last_manifest->{vars}{path}, label => 'last-deployed-vars'},
				{file => $state->{vars_path}, label => 'current-vars'}
			);
		}

		$self->_cleanup_and_bail(
			"Failed to diff the last deployed manifest with the current manifest: %s",
			$err//$out
		) if $rc > 1;
		$self->_cleanup_and_bail(
			"Failed to diff the last deployed vars file with the current vars file: %s",
			$vars_err//$vars_out
		) if ($vars_rc > 1);

		if (!$out && !$vars_out) {
			info(
				"[[  - >>#G{no differences found between last deployed and current manifest or bosh variables.}"
			);
		} else {
			info(
				"[[  - >>#y{found differences between last deployed and current manifest:}\n\n%s",
				$out,
			) if $out;
			info(
				"[[  - >>#y{found differences between last deployed and current bosh variables:}\n\n%s",
				$vars_out
			) if $vars_out;
			warning(
				"\n#y{NOTE}: values from vault have been redacted, so differences are not shown."
			) if $last_manifest->{manifest}{source} eq 'repository';
		}
	} else {
		info "[[  - >>no previous deployment of this environment found in the deployment archive.";
	}

	# Confirm deployment
	if (in_controlling_terminal && !$noprompt) {
		prompt_for_boolean(
			"Proceed with BOSH create-env for the #C{${\($self->name)}}? [y|n] ",1
		) or $self->_cleanup_and_bail("Aborted!\n");
		print "\n";
	} elsif (!$noprompt) {
		$self->_cleanup_and_bail(
			"Cannot proceed with BOSH create-env for the #C{${\($self->name)}} without user confirmation. ".
			"Please run this command in a terminal, or use the --yes option to skip confirmation."
		);
	} else {
		print "\n";
	}

	# Setup state and store files
	my $state_path = $self->deployment_cache_path_lookup('state');
	my $store_path = $self->deployment_cache_path_lookup('store');

	if ($alternative_state_file) {
		copy_or_fail($alternative_state_file, $state_path);
		notice("Using Custom state file: %s", humanize_path($alternative_state_file));
	} elsif ($last_manifest->{state}{path}) {
		copy_or_fail($last_manifest->{state}{path}, $state_path)
	}
	copy_or_fail($last_manifest->{store}{path}, $store_path)
		if $last_manifest->{store}{path};

	my @bosh_opts;
	push @bosh_opts, "--$_" for grep { $opts{$_} } qw/recreate skip-drain/;

	# Execute deployment
	$state->{deploy_started} = gettimeofday;
	my @results = $self->bosh->create_env(
		$state->{manifest_path},
		flags => \@bosh_opts,
		vars_file => $state->{vars_path},
		state => $state_path,
		store => $self->kit->secrets_store eq 'credhub' ? $store_path : undef,
	);

	$state->{results} = \@results;
	return $state->{ok} = !$results[1];
}

# }}}
# _deploy_to_bosh - handle regular BOSH deployment {{{
sub _deploy_to_bosh {
	my ($self, %opts) = @_;
	my $state = $self->{deployment_state};

	my @bosh_opts = ('--tty');
	push @bosh_opts, "--$_"             for grep { $opts{$_} } qw/fix fix-releases recreate dry-run/;
	push @bosh_opts, "--no-redact"      if  !$opts{redact};
	push @bosh_opts, '--skip-drain'     if grep {$_ eq ''} @{$opts{'skip-drain'}};
	push @bosh_opts, "--skip-drain=$_"  for grep {$_} @{$opts{'skip-drain'} || []};
	push @bosh_opts, "--$_=$opts{$_}"   for grep { defined $opts{$_} } qw/canaries max-in-flight/;

	debug("deploying this environment to our BOSH director");
	$state->{deploy_started} = gettimeofday;
	my @results = $self->bosh->deploy(
		$state->{manifest_path},
		vars_file => $state->{vars_path},
		flags     => \@bosh_opts
	);

	$state->{results} = \@results;
	return $state->{ok} = !$results[1];
}

# }}}
# _post_deploy - handle post-deployment activities {{{
sub _post_deploy {
	my ($self, %opts) = @_;
	my $noprompt = delete($opts{noprompt});
	my $state = $self->{deployment_state};
	my $deployment_ok = $state->{ok};

	$self->notify("#G{Deployment successful.}") if $deployment_ok;

	# Process post-deploy reactions
	if ($self->_reactions && !$state->{disable_reactions}) {
		$state->{reaction_vars}{GENESIS_DEPLOY_RC} = ($state->{results}[1]);
		$self->_process_reactions('post-deploy', $state->{reaction_vars}) or warning(
			"Environment post-deploy reaction failed!  Manual intervention may be needed."
		);
	}

	# Save deployment log
	my $manifest_store = $self->top->config->get('manifest_store','hybrid');
	mkfile_or_fail(
		$self->deployment_cache_path_lookup('deploy_log'),
		decode_utf8($state->{results}[0]//'No output received')
	) unless $manifest_store eq 'repository';

	# Update legacy manifest store
	if ($deployment_ok && $manifest_store ne 'exodus' && !$opts{"dry-run"}) {
		# deployment succeeded; update the cache (Legacy manifest store)
		mkdir_or_fail($self->path(".genesis/manifests")) unless -d $self->path(".genesis/manifests");
		eval {
			copy_or_fail($state->{cached_redacted_manifest_path}, $self->path(".genesis/manifests/$self->{name}.yml"));
			copy_or_fail($state->{cached_redacted_vars_path}, $self->path(".genesis/manifests/$self->{name}.vars"))
				if -e $state->{cached_redacted_vars_path};
		};
		warning("Failed to copy manifest to repository: $@") if ($@);
		for ('state', 'store') {
			my $cached_file = $self->deployment_cache_path_lookup($_);
			next unless -f $cached_file;
			my $file = basename($cached_file);
			eval {
				copy_or_fail("$cached_file", $self->path(".genesis/manifests/$file"));
			};
			warning("Failed to copy $file to repository: $@") if ($@);
		}
	}

	# bail out early if the deployment failed;
	if (!$deployment_ok) {
		if (!$opts{"dry-run"} && $self->has_hook('post-deploy')) {
			# Call post-deploy hook with the pre-deploy data in case of cleanup on failure
			$self->run_hook('post-deploy', rc => $state->{results}[1], interactive => !$noprompt, data => $state->{predeploy_data});
		}
		$state->{results}[0] //= '';
		my $last_bits_of_output = join "\n", map {decolorize($_)} (split(/\r?\n/,$state->{results}[0]))[-5..-1];
		my $msg;
		my $cleanup_cache = 1;
		if ($last_bits_of_output =~ /Continue\?[^\n]*: [^\n]*[nN]o?\r?\n\s*Stopped\s*Exit code 1/sm) {
			$msg = "User canceled deployment when prompted to continue.";
		} elsif ($last_bits_of_output =~ /Continue\?[^\n]*:\s*Asking for confirmation:\s*  EOF\s*Exit code 1/sm) {
			$msg = "User interrupted deployment at continue prompt.";
		} elsif ($last_bits_of_output =~ qr{\^C$}m) {
			# This may leave the deployment detached if pressed after the confirmation prompt, so
			# once we have deployment recovery working, we'll need to handle this state differently.
			$msg = "User interrupted deployment (Ctrl-C)";
			$cleanup_cache = 0; # Don't clean up the cache, as we may want to rejoin the deployment
		} else {
			$msg = "Deployment failed.";
		}
		$self->_create_deployment_audit_log(
			'deploy'      => Genesis::Env::Deployment::action_failed,
			reason        => $opts{reason},
			error         => $msg,
			flags         => $opts{flags} || '',
			bails_with    => $msg,
			cleanup_cache => $cleanup_cache,
		);
	}

	if ($opts{"dry-run"}) {
		$self->notify("dry-run deployment complete; post-deployment activities will be skipped.");
		exit 0;
	}

	# If vault is sealed after deployment, unseal it before updating exodus data
	if ($self->vault->status eq 'sealed') {
		$self->notify("vault is sealed - attempting to unseal...");
		my ($out, $rc, $err) = $self->vault->unseal;
		if ($rc) {
			error(
				"Failed to unseal vault: %s\n\n%s", $err || $out,
				"#Yi{Exodus data update may fail due to sealed vault}"
			);
		} else {
			info('[[  #g@{+} >>Vault unsealed successfully');
		}
	}

	# Update exodus data
	$self->notify("preparing metadata for export...");

	my @skip_drains = @{$opts{'skip-drain'}//[]};
	my $opt_flags = join(' ', map {'--'.$_} sort grep {$_} (
		$noprompt ? 'yes' : undef,
		$state->{disable_reactions} ? 'no-reactions' : undef,
		$opts{recreate} ? 'recreate' : undef,
		scalar(@skip_drains) ?
			scalar(grep {$_ eq ''} @skip_drains)
			? 'skip-drain'
			: 'skip-drain['.join(',',@skip_drains).']' : undef,
		$opts{'fix'} ? 'fix' : undef,
		$opts{'fix-releases'} ? 'fix-releases' : undef,
		$opts{'canaries'} ? "canaries=$opts{'canaries'}" : undef,
		$opts{'max-in-flight'} ? "max-in-flight=$opts{'max-in-flight'}" : undef,
	));
	my $exodus_overrides = {};
	if ($self->is_bosh_director && $self->cpi_enabled) {
		$exodus_overrides->{default_cpi_config} = $self->cpi_name;
	}
	$self->update_deployment_exodus(
		'deploy' => Genesis::Env::Deployment::action_succeeded,
		reason => $opts{reason},
		flags => $opt_flags,
		exodus_overrides => $exodus_overrides
	);

	# Clean up deployment cache
	$self->deployment_cache_cleanup;

	# Remove exodus-only manifest files
	if ($manifest_store eq 'exodus') {
		unlink $_ for grep {-f $_} (
			$self->path(".genesis/manifests/".$self->name.".yml"),
			$self->path(".genesis/manifests/".$self->name.".vars"),
			$self->path(".genesis/manifests/".$self->name."-state.yml"),
			$self->path(".genesis/manifests/".$self->name."-state.json"),
			$self->path(".genesis/manifests/".$self->name."-store.yml")
		);
	}

	# Run post-deploy hook
	$self->run_hook(
		'post-deploy',
		rc => $state->{results}[1],
		data => $state->{predeploy_data},
		interactive => !$noprompt,
		flags => $opt_flags,
	) if $self->has_hook('post-deploy');

	# Clean up deployment state
	delete $self->{deployment_state};

	return $deployment_ok;
}

# }}}

#	 extract_manifest_exodus - get the populated exodus data generated in the manifest {{{
sub extract_manifest_exodus {
	my ($self) = @_;
	# FIXME: May need to use an unentombed manifest...
	my $exodus = scalar($self->manifest_lookup('exodus', {}));
	my $vars_file = $self->vars_file;
	return $exodus unless ($vars_file || $self->kit->uses_credhub); ## May be redundant if vaultifying credhub secrets...?

	$exodus = flatten($exodus);

	#interpolate bosh vars first
	if ($vars_file) {
		for my $key (keys %$exodus) {
			if (defined($exodus->{$key})) {
				while ($exodus->{$key} =~ /\(\((.*)\)\)/) {
					my $val = $self->manifest_lookup("bosh-variables.$1", undef);
					# FIXME: This should be handled when its a credhub reference
					trace("Unknown BOSH variable encountered in exodus: $1 in $key") &&	last unless $val;
					$exodus->{$key} =~ s/\(\($1\)\)/$val/;
				}
			}
		}
	}

	my @int_keys = grep {$exodus->{$_} =~ /^\(\(.*\)\)$/} grep {defined($exodus->{$_})} keys %$exodus;
	if ($self->kit->uses_credhub && @int_keys) {
		# Get credhub info
		my $credhub = $self->credhub;
		for my $target (@int_keys) {
			my ($secret,$key) = ($exodus->{$target} =~ /^\(\(([^\.]*)(?:\.(.*))?\)\)$/);
			next unless $secret;
			my ($out, $err) = $credhub->get($secret, $key);
			error(
				"Could not retrieve %s under %s:\n%s",
				$key ? "$secret.$key" : $secret,
				$credhub->base, $err
			) if $err;
			$exodus->{$target} = $out;
		}
	}
	return unflatten($exodus);
}

# }}}
# update_deployment_exodus - update the exodus data in the vault {{{
sub update_deployment_exodus {
	my ($self, $action, $result, %deployment_details) = @_;

	# Authenticate to the vault
	$self->vault->authenticate unless $self->vault->authenticated;

	my $exodus_overrides = delete($deployment_details{exodus_overrides}) // {};

	# Get the completed timestamp from overrides, or use the current time
	my $timestamp = $deployment_details{completed} || Time::Piece->new->strftime(EXODUS_TIME_FORMAT);

	# Build the base exodus data (manifest data and legacy deployment data)
	my $exodus = {};
	my @exodus_cmds = ();

	my $notify = !delete($deployment_details{quiet});
	my $started = gettimeofday;

	my @rm_exodus_cmds = ();
	if (keys $self->vault->get($self->exodus_base)->%*) {
		# If the exodus data already exists, we need to remove it first
		push @rm_exodus_cmds, ('rm', $self->exodus_base, "-f");
	}

	my $info_msg = '';
	if ($action eq 'deploy') {
		if (Genesis::Env::Deployment::is_a_successful_result($result)) {
			# if a successful deploy, generate the exodus data from the manifest using
			# $self->extract_manifest_exodus, as well as the standard deployment exodus
			# data
			$exodus = {
				$self->extract_manifest_exodus->%*,
				completed => $timestamp,
			};

			$exodus = {
				%$exodus,
				manifest_sha1 => digest_file_hex(
					$self->deployment_cache_path_lookup('redacted_manifest'), 'SHA-1'
				),
				manifest_type => $self->manifest_provider->deployment->redacted->type,
			} if ($self->manifest_store ne 'exodus');

			# Special case for the started timestamp
			if ($deployment_details{started}) {
				$exodus->{dated} = $deployment_details{started};
			} else {
				$deployment_details{started} = $exodus->{dated} // $timestamp;
			}
			push @exodus_cmds, @rm_exodus_cmds;
			$info_msg = "updating exodus data for this deployment";
		} else {
			$info_msg = "retaining any previous exodus data (deployment failed)";
			# Don't change exodus on a failed deploy
			$exodus = {};
			$exodus_overrides = {};
		}
	} elsif ($action eq 'terminate') {
		if (Genesis::Env::Deployment::is_a_successful_result($result) && @rm_exodus_cmds) {
			$info_msg = "removing previous exodus data";
			push @exodus_cmds, @rm_exodus_cmds;
		} else {
			$info_msg = "retaining any previous exodus data (termination failed)";
		}
	} else {
		# TODO: Support 'pending' as an result, for when the deployment has started,
		# then move it to success or failure when it's done
		bug(
			"Invalid action for deployment exodus: %s - expected 'deploy' or 'terminate'",
			$action
		)
	}

	# Build the exodus set commands as an array
	$exodus = deep_merge($exodus, $exodus_overrides, 'flatten');
	if (keys %$exodus) {
		push(@exodus_cmds, '--') if @exodus_cmds && $exodus_cmds[-1] ne '--';
		push @exodus_cmds, (
			'set', $self->exodus_base, map {
				"$_=$exodus->{$_}"
			} grep {defined $exodus->{$_}} keys %$exodus
		);
	}
	# Set the exodus data in the vault
	my @errors = ();
	info(
		"[[  - >>%s",
		$info_msg
	) if $notify;
	if (Genesis::Env::Deployment::is_a_successful_result($result)) {
		debug("setting exodus data in the Vault, for use later by other deployments");
		eval {
			$self->vault->authenticate;
		};
		my $err = $@;
		if ($err) {
			push @errors, "Failed to authenticate to vault: $err";
		} elsif (@exodus_cmds) {
			my ($out, $rc, $err) = $self->vault->query({ redact => 1}, @exodus_cmds);
			push @errors, "Failed to set exodus data in vault: $err" if $rc;
		}
	} else {
		debug("$action failed, not updating exodus in vault");
	}

	# If the manifest store is not 'repository', build the deployment audit data
	if ($self->manifest_store ne 'repository' && !@errors) {
		info(
			"[[  - >>creating deployment audit log for %s %s",
			Genesis::Env::Deployment::is_a_successful_result($result) ? 'successful' : 'failed',
			$action eq 'deploy' ? 'deployment' : 'termination'
		) if $notify;
		eval {
			$self->_create_deployment_audit_log(
				$action => $result,
				%deployment_details,
			);
		};
		push @errors, fix_wrap($@) if ($@);

		unless (@errors) {
			my $latest_deployment = $self->deployments->latest;
			$self->vault->set(
				$self->exodus_base, 'sequence' => $latest_deployment->sequence,
			) if ($latest_deployment->succeeded && $latest_deployment->sequence);
		}
	}

	if (@errors) {
		my $error_msg = join("\n", @errors);
		bail(
			"#R{Failed to export %s metadata.}\n\nError(s):%s\n\n".
			"Environment was still successfully %s, but metadata used by addons and ".
			"other kits is outdated.\n%s",
			$self->{name},
			join("\n[[  - >>", '', @errors),
			$action eq 'deploy' ? 'deployed' : 'terminated',
			$action eq 'deploy'
				? "\nThis may be resolved by deploying again, or it may be a permissions issue while trying to ".
					"write to vault path '".$self->exodus_base."'\n"
				: "\nThis may be resolved by terminating again, or it may be a permissions issue while trying to ".
					"write to vault path '".$self->exodus_base."'\n"
		);
	}

	info(" #G{done.}%s", pretty_duration(gettimeofday - $started)) if $notify;
	return 1;
}

# }}}
# terminate - terminate the environment {{{
sub terminate {
	my ($self, %opts) = @_;

	# FIXME: Need to be able to handle deleting the vault deployment without erroring out.
	# Vault kit should offer a backup of the vault contents to file or to running local vault.
	# May be generic enough to use a --backup-vault-to option that takes a file or url.

	my $dryrun =   $opts{dryrun}   //= 0;
	my $force =    $opts{force}    //= 0;
	my $noprompt = $opts{noprompt} //= 0;

	my $reason =     delete($opts{reason}) // 'unknown';
	my $term_flags = delete($opts{flags})  // '';
	my %clean_up = map { $_ => delete $opts{$_} } qw/resources secrets user_secrets networking credhub/;

	my $start_time = Time::Piece->new->strftime(EXODUS_TIME_FORMAT);
	my %audit_data = (
		'started' => $start_time,
		'flags'   => $term_flags,
		'reason'  => $reason,
	);

	if (my $min_reason_length = $self->deployment_change_reason_required_size_policy()) {
		bail(
			"Termination without reason is not allowed - minimum length is %d characters",
			$min_reason_length
		) unless length($reason//'') > $min_reason_length;
	}

	# Set up deployment cache early so it's available for all termination paths
	$self->deployment_cache_setup;

	# TODO: Do we want to support a full reset where all exodus data and secrets are removed?
	#my $full_reset = delete($opts{'deployment-history'})//0;
	#if ($full_reset && !$clean_up{secrets} && !$clean_up{user_secrets}) {
	#	bail("Cannot perform a full reset and keep any secrets at the same time.");
	#}

	my $ok = undef;

	my $deployment_state = $self->deployment_state();
	if ($deployment_state eq 'undeployed') {
		warning(
			"No exodus data found for #C{%s}; may not exist.%s",
			$self->name,
			$force ? '': "\n\nCowardly refusing to terminate.  Use --force to attempt anyway."
		);
		return 0 unless $force;

	} elsif ($deployment_state eq 'terminated') {
		my $last_deployment = $self->deployments->latest_successful;
		my ($date, $time) = $last_deployment->completed(EXODUS_TIME_FORMAT) =~ m{^(\d{4}-\d{2}-\d{2}).(\d{2}:\d{2}:\d{2})};
		# FIXME: Parse with Time::Piece, then present in local time

		warning(
			"\nEnvironment #C{%s} has already been terminated%s on %s at %s UTC%s\n\n%s",
			$self->name,
			$last_deployment->{user}{shell} ? ' by #B{'.$last_deployment->{user}{shell}.'}' : '',
			$date, $time,
			$last_deployment->{reason} ? " for reason: '#Y{".$last_deployment->{reason}."}'" : '',
			$force ? 'Forcing termination anyway...' : 'Cowardly refusing to terminate.  Use --force to attempt anyway.'
		);
		return 0 unless $force;
	}

	# All the pronmpting has already been done in the Command phase
	$ENV{BOSH_NON_INTERACTIVE} = 'true';

	my $start = gettimeofday();

	if ($self->has_hook('terminate')) {
		$self->notify(
			'running %s termination hooks before deployment is terminated...%s',
			$self->kit->id,
			$dryrun ? ' (dry-run)' : '',
		);
		$ok = $self->run_hook('terminate', %opts, env => $self, mode => 'before');
		return unless $ok;
	} elsif ($self->is_bosh_director) {
		$self->_create_deployment_audit_log(
			'terminate' => Genesis::Env::Deployment::action_failed,
			reason      => $reason,
			error       => "Aborted due to unsupported BOSH director kit (no terminate hook) - no --force specified",
			started     => $start_time,
			flags       => $opts{flags} || '',
			bails_with  => [
				"Cowardly refusing to terminate a BOSH director environment without a ".
				"termination hook.  Please upgrade your kit to a version that supports ".
				"termination hooks, or use --force to terminate anyway (this will ".
				"likely leave orphaned resources on your IaaS unless you manually ".
				"cleaned it up first)."
			]
		) unless $force;

		warning(
			"\nTerminating a BOSH director environment without a termination hook.  ".
			"This will likely leave orphaned resources on your IaaS unless you ".
			"manually cleaned it up first."
		);
	}

	$self->notify(
		"terminating %s environment...%s",
		$self->use_create_env ? 'create-env' : 'deployed',
		$dryrun ? ' #i{(dry-run)}' : ''
	);
	my $results = {};
	if ($self->use_create_env) {
		$self->notify("preparing to delete a create-env environment...");
		# Gather all the files needed to send to delete-env
		my $files = {};
		if ($self->manifest_store eq 'repository') {
			info(
				"[[  - >>Regenerating the unredacted manifest and vars files as needed for `bosh delete-env`.\n".
				"[[  - >>Using the state file from the local repository."
			);
			# We can use the state file in the repo, but have to generate
			# the manifest and vars files from scratch.
			$self->manifest_provider->unredacted->write_to($self->deployment_cache_path_lookup('manifest'));
			$self->manifest_provider->unredacted(subset=>'bosh_vars')->write_to($self->deployment_cache_path_lookup('vars'));
			my $state_path = grep {-f $_} map {$self->path(".genesis/manifests/".$self->name."-state.$_")} (qw/json yml/);
			bail(
				"Cannot find state file for previous deployment; cannot proceed with delete-env."
			) unless -f $state_path;
			copy_or_fail($state_path, $self->deployment_cache_path_lookup('state'));
			my $store = grep {-f $_} map {$self->path(".genesis/manifests/".$self->name."-store.$_")} (qw/yml json/);
			copy_or_fail($store, $self->deployment_cache_path_lookup('store'))
				if $store;
		} else {
			# We can pull the full manifest, vars and state files from the
			# deployment artifacts in the vault.
			info(
				"[[  - >>Using the unredacted manifest, vars and state file from the deployment archive."
			);
			my $last_deployment = $self->deployments->latest(action => 'deploy');

			# If we can't find artifacts, try to fall back to repository files if they exist
			if (!$last_deployment || !$last_deployment->artifact_types()) {
				warning(
					"Cannot find artifacts for previous deployment in vault; attempting to use local repository files."
				);

				# Check if we have local state file
				my $state_path = grep {-f $_} map {$self->path(".genesis/manifests/".$self->name."-state.$_")} (qw/json yml/);

				if (-f $state_path) {
					# We found a state file, let's try to regenerate the manifest
					info("[[  - >>Found local state file; regenerating manifest and vars files.");
					$self->manifest_provider->unredacted->write_to($self->deployment_cache_path_lookup('manifest'));
					$self->manifest_provider->unredacted(subset=>'bosh_vars')->write_to($self->deployment_cache_path_lookup('vars'));
					copy_or_fail($state_path, $self->deployment_cache_path_lookup('state'));

					# Also copy store file if it exists
					my $store = grep {-f $_} map {$self->path(".genesis/manifests/".$self->name."-store.$_")} (qw/yml json/);
					copy_or_fail($store, $self->deployment_cache_path_lookup('store'))
						if $store;
				} else {
					# No state file found, we can't proceed
					bail(
						"Cannot find artifacts for previous deployment in vault, and no local state file found; cannot proceed with delete-env.\n\n".
						"If the BOSH VM still exists but state is missing, you may need to manually delete it using:\n".
						"  - Cloud provider's management console/CLI\n".
						"  - Or recreate the state file manually if you know the instance details"
					);
				}
			} else {
				# We have deployment artifacts, extract them normally
				my (undef, $optional_artifacts) = compare_arrays(
					[$last_deployment->artifact_types()],
					[qw/vars store/]
				);
				$last_deployment->extract_artifacts_to(
					$self->deployment_cache_path_lookup(),
					'manifest', 'state', @$optional_artifacts
				);
			}
		}
		$self->notify("deleting create-env environment...");

		my ($out, $rc) = $self->bosh->delete_env(
			$self->deployment_cache_path_lookup('manifest'),
			%opts,
			vars_file => $self->deployment_cache_path_lookup('vars'),
			state => $self->deployment_cache_path_lookup('state'),
			store => -f $self->deployment_cache_path_lookup('store')
				? $self->deployment_cache_path_lookup('store')
				: undef,
		);
		$self->deployment_cache_cleanup;
		$ok = ($rc == 0);
		$results->{delete_env} = {
			msg => $out,
			rc  => $rc
		};
	} else {
		$self->notify("deleting deployment...");
		my ($out, $rc) = $self->bosh->delete_deployment(%opts);
		$ok = ($rc == 0);
		$results->{delete_deployment} = {
			msg => $out,
			rc => $rc
		};
		if ($ok) {
			if ($clean_up{resources} ) {
				$self->notify("cleaning up any unused resources...");
				$ok = $self->bosh->cleanup(%opts, env => $self, all => 1) ? 1 : 2;
				warning("\n".
					"The contents above is a summary of the resources currently unused ".
					"by any deployment. Further resources may become unused once this ".
					"environment is actually terminated."
				) if $dryrun;
			} else {
				dryrun("\nwould keep any unused resources on the #M{%s} BOSH director.", $self->bosh->{alias}) if $dryrun;
			}
		}
	}

	if ($self->has_hook('terminate')) {
		$self->notify(
			'running %s termination hooks after deployment terminated...%s',
			$self->kit->id,
			$dryrun ? ' (dry-run)' : '',
		);
		$opts{results} = $results;
		my $hook_results = $self->run_hook(
			'terminate', %opts, env => $self, mode => $ok ? 'after' : 'failed'
		);
		# FIXME: The results of the hook should be analyzed instead of just assuming its a boolean.
		$results->{hook} = $hook_results;
		$ok = 0 unless (ref($hook_results) eq 'HASH' ? $hook_results->{success} : $hook_results);
	}

	return $self->_create_deployment_audit_log(
		'terminate' => Genesis::Env::Deployment::action_failed,
		%audit_data,
		error => sub {
			my ($env, $results) = @_;
			my $error_message = "Deployment failed with the following issues:\n";

			# Analyze the results hash to determine the error sources
			# $results keys and their contents:
			# - delete_env: Hash containing output and return code from `bosh delete-env` command
			#   - msg: Output from the command (string)
			#   - rc: Return code from the command (integer)
			# - delete_deployment: Hash containing output and return code from `bosh delete-deployment` command
			#   - msg: Output from the command (string)
			#   - rc: Return code from the command (integer)
			# - hook: Hash containing results from running termination hooks
			#   - success: Boolean indicating if the hook succeeded
			#   - error: Error message if the hook failed (string)
			# --or--
			# - hook: Boolean indicating if the hook succeeded (true) or failed (false)

			if ($results->{delete_env} && ref($results->{delete_env}) eq 'HASH' && !$results->{delete_env}{rc}) {
				$error_message .= sprintf(
					"  - Error during `bosh delete-env`: %s\n",
					$results->{delete_env}{msg}
				);
			}

			if ($results->{delete_deployment} && ref($results->{delete_deployment}) eq 'HASH' && !defined($results->{delete_deployment_rc})) {
				$error_message .= sprintf(
					"  - Error during `bosh delete-deployment`: %s\n",
					$results->{delete_deployment}
				);
			}

			if ($results->{hook} && ref($results->{hook}) eq 'HASH') {
				$error_message .= sprintf(
					"  - Termination hook failed: %s\n",
					$results->{hook}{error} // 'See above for details'
				) unless $results->{hook}{success};
			} elsif (defined($results->{hook}) && !$results->{hook}) {
				$error_message .= "  - Termination hook failed: See above for details\n";
			}
			return $error_message;
		}->($self,$results)
	) unless $ok;

	# Determine existing claims, configs and secrets
	my $start_cleanup = gettimeofday();
	$self->notify({pending => 1},
		"gathering list of associated items for cleanup..."
	);
	my (@kept_secrets, @removed_secrets) = ();
	$self->manifest_provider->{suppress_notification} = 1; # Suppress notifications
	my @all_secrets = $self->secrets_plan(silent => 1)->secrets;
	my @generated_secrets = grep {$_->exists} grep {$_->type ne 'userprovided'} @all_secrets;
	my @user_secrets = grep {$_->exists} grep {$_->type eq 'userprovided'} @all_secrets;
	push(@{$clean_up{secrets} ? \@removed_secrets : \@kept_secrets}, @generated_secrets);
	push(@{$clean_up{user_secrets} ? \@removed_secrets : \@kept_secrets}, @user_secrets);
	$self->secrets_plan->verbose(1);

	my $claims = {};
	my $configs = {};
	if (! $self->use_create_env) {
		# TODO: kits may have multiple config files of a given type, so in the
		#       future, we'll ask the kit for the list of config file names,
		#       and then iterate over them to get the list of existing configs.
		my $config_name = sprintf('%s.%s', $self->name, $self->type);
		for my $config_type (qw{cloud runtime cpi}) {
			push(@{$configs->{$config_type}}, $config_name)
				if $self->bosh->has_config($config_type, $config_name);
		}
		my $network_claims = $self->get_network_claims();
		if (scalar keys $network_claims->%*) {
			for my $network (keys $network_claims->%*) {
				$claims->{$network}{description} = sprintf("\n  #Cu{%s}:", $network);
				for my $subnet (sort keys $network_claims->{$network}->%*) {
					my $subnet_info = {
						'path' => $network_claims->{$network}{$subnet}{path},
						'range' => $network_claims->{$network}{$subnet}{ips},
						'description' => sprintf(
							"%s#i{%s:} #c{%s}", bullet(''), $subnet, $network_claims->{$network}{$subnet}{ips})
					};
					push $claims->{$network}{subnets}->@*, $subnet_info;
				}
			}
		}
	}
	info(" #G{done}".pretty_duration(gettimeofday() - $start_cleanup));

	# Dry-run output
	if ($dryrun) {
		if (scalar keys $configs->%*) {
			my $config_descriptions = [];
			for my $config_type (sort keys $configs->%*) {
				push(@$config_descriptions, sprintf(
					"would #r{remove} the following #r{%s config} files:\n%s",
					$config_type, join("\n", map {bullet("#c{$_}")} $configs->{$config_type}->@*)
				));
			}
			dryrun("\n%s", join("\n", $config_descriptions->@*));
		} elsif (!$self->use_create_env) {
			dryrun("\nno config files found to remove.");
		}

		if (scalar(keys $claims->%*)) {
			my $claim_descriptions = [];
			for my $network (sort keys $claims->%*) {
				my $block = $claims->{$network}{description};
				$block .= "\n".$_->{description} for $claims->{$network}{subnets}->@*;
				push(@$claim_descriptions, $block);
			}
			dryrun("\nwould #%s{%s} the following network claims:\n%s",
				$clean_up{networking} ? ("r",'release') : ('G','keep'),
				join("\n", $claim_descriptions->@*)
			);
		} elsif (!$self->use_create_env) {
			dryrun("\nno network claims found to release.");
		}

		# TODO: Add the credhub secrets to the list of secrets to remove if not using create-env

		dryrun(
			"\nwould #G{keep} the following #G{%s} secrets:\n%s",
			join(" and ", ($clean_up{secrets} ? () : 'generated'), ($clean_up{user_secrets} ? () : 'user-provided')),
			join("\n", map {csprintf('  #@{*} #c{%s}#c{%s}',$self->secrets_store->base,$_->path)} sort {$a->path cmp $b->path} @kept_secrets)
		) if (scalar @kept_secrets);

		dryrun(
			"\nwould #r{remove} the following #r{%s} secrets:\n%s",
			join(" and ", ($clean_up{secrets} ? 'generated' : ()), ($clean_up{user_secrets} ? 'user-provided' : ())),
			join("\n", map {csprintf('  #@{*} #c{%s}#c{%s}',$self->secrets_store->base,$_->path)} sort {$a->path cmp $b->path} @removed_secrets)
		) if (scalar @removed_secrets);

		return 1;
	}

	# Actual cleanup
	if (scalar $configs->%*) {
		$self->notify("removing BOSH config files...");
		for my $config_type (sort keys $configs->%*) {
			for my $config_name ($configs->{$config_type}->@*) {
				my $start = gettimeofday();
				info({pending => 1}, "  - removing %s config file %s...", $config_type, $config_name);
				my ($out, $rc, $err) = $self->bosh->delete_config($config_type, $config_name);
				info(
					'%s%s',
					$rc ? "#R{failed}": "#G{done.}",
					$rc ? "\n\n$err" : pretty_duration(gettimeofday() - $start)
				)
			}
		}
	}

	if (scalar $claims->%*) {
		if ($clean_up{networking}) {
			$self->notify("releasing network claims...");
			for my $network (sort keys $claims->%*) {
				my $start = gettimeofday();
				info("  releasing claims for the #C{%s} network...", $network);
				# FIXME: Need to revisit the short-circuiting here... (also let's not reuse the $ok variable in local scope as its confusing)
				my $ok = 1;
				for my $subnet ($claims->{$network}{subnets}->@*) {
					info("%s", $subnet->{description});
					$ok = $self->bosh->vault->clear($subnet->{path});
					last unless $ok;
				}
				info(
					'%s%s',
					$ok ? " #G{done.}" : " #R{failed}",
					$ok ? pretty_duration(gettimeofday() - $start) : '' # TODO: capture bail message and print it here
				)
			}
		} else {
			$self->notify("keeping network claims for this environment");
		}
	}

	if (scalar @removed_secrets) {
		$self->notify(
			"removing #r{%s} secrets...",
			join(" and ", ($clean_up{secrets} ? 'generated' : ()), ($clean_up{user_secrets} ? 'user-provided' : ())),
		);
		my ($results, $msg) = $self->secrets_plan->_remove_secrets(
			\@removed_secrets,
			verbose => 1,
			confirm => 'none',
			no_header => 1,
		);
		if ($results->{error}) {
			info("#r{error!}");
			error("Failed to remove secrets: %s", $msg);
			return 0;
		} else {
			info("#g{done.}");
		}
	}

	# Update deployment archive with new exodus data indicating the deployment has been terminated
	#if ($full_reset) {
	#	$self->vault->authenticate->clear($self->exodus_base, 1);
	#} els ...
	if ($self->manifest_store =~ /^(?:exodus|hybrid)$/) {
		# If the manifest_store uses exodus, then we need to update the exodus
		# deployment audit data to indicate the deployment has been terminated
		# Set exodus data to indicate the deployment has been terminated
		$self->vault->authenticate;
		my $result = [
			Genesis::Env::Deployment::action_failed,
			Genesis::Env::Deployment::action_succeeded,
			Genesis::Env::Deployment::action_post_failed,
		]->[$ok//0];
		$self->update_deployment_exodus(
			'terminate' => $result,
			reason  => $reason,
			flags   => $term_flags,
			started => Time::Piece->new(int($start))->strftime(EXODUS_TIME_FORMAT),
		);
	} else {
		# No exodus deployment audit data to update, so just remove the base exodus data
		$self->vault->authenticate->clear($self->exodus_base);
	}

	if ($self->manifest_store ne 'exodus') {
		# Remove any lingering manifest files from the repo
		unlink $_ for grep {-f $_} (
			$self->path(".genesis/manifests/".$self->name.".yml"),
			$self->path(".genesis/manifests/".$self->name.".vars"),
			$self->path(".genesis/manifests/".$self->name."-state.yml"),
			$self->path(".genesis/manifests/".$self->name."-state.json"),
			$self->path(".genesis/manifests/".$self->name."-store.yml")
		);
	}
	return 1;
}

# }}}

# Deployment Audits
# deployments - the deployment audit manager for this environment {{{
sub deployments {
	my ($self) = @_;
	return $self->_memoize(sub {
		require Genesis::Env::DeploymentManager;
		return Genesis::Env::DeploymentManager->new(
			$self,
		);
	})
}

# Secrets Processing
# add_secrets - add any secrets missing from the environment {{{
sub add_secrets {
	my ($self, %opts) = @_;

	$self->manifest_provider->kit_files(); #process blueprint
	my $plan = $self->secrets_plan(%opts);

	unless ($plan->secrets) {
		if ($plan->filters) {
			info("\nNo applicable secrets found - no need to continue.\n");
		} else {
			$self->notify(success => "doesn't have any secrets to add.\n");
		}
		return ({empty => 1});
	}

	kit_bug(
		"Kits with secrets hook are no longer supported. Check for an upgraded version."
	) if ($self->has_hook('secrets'));

	return $plan->generate_secrets(
		import    => $opts{import},
		level     => $opts{verbose}?'full':'line'
	);
}

# }}}
# check_secrets - check that the environment has no missing or invalid secrets {{{
sub check_secrets {
	my ($self,%opts) = @_;
	my ($action,$action_desc) = delete($opts{validate})
		? ('validate_secrets','validated')
		: ('check_secrets', 'checked');

	$self->manifest_provider->kit_files(); #process blueprint
	my $plan = $self->secrets_plan(%opts);

	unless ($plan->secrets) {
		my $msg = ($plan->filters)
			? "No applicable secrets found"
			: undef;
		return ({empty => 1}, $msg);
	}

	kit_bug(
		"Kits with secrets hook are no longer supported. Check for an upgraded version."
	) if ($self->has_hook('secrets'));

	return $plan->$action(
		level => $opts{verbose}?'full':'line',
	);
}

# }}}
# rotate_secrets - generate new secrets for the environment {{{
sub rotate_secrets {
	my ($self, %opts) = @_;

	$self->manifest_provider->kit_files(); #process blueprint
	my $plan = $self->secrets_plan(%opts);

	unless ($plan->secrets) {
		if ($plan->filters) {
			info("\nNo applicable secrets found - no need to continue.\n");
		} else {
			$self->notify(success => "doesn't have any secrets to rotate.\n");
		}
		exit 0;
	}

	kit_bug(
		"Kits with secrets hook are no longer supported. Check for an upgraded version."
	) if ($self->has_hook('secrets'));

	my %regen_opts = (
		regen_x509_keys => $opts{'regen-x509-keys'},
		update_subject  => $opts{'update-subjects'},
		no_prompt       => $opts{'no-prompt'},
		invalid         => $opts{invalid},
		interactive     => $opts{interactive},
		level           => $opts{verbose}?'full':'line'
	);
	$regen_opts{notice} = $opts{notice} if $opts{notice};
	$regen_opts{action} = $opts{action} if $opts{action};

	return $plan->regenerate_secrets(%regen_opts);
}

# }}}
# remove_secrets - remove secrets from the environment {{{
sub remove_secrets {
	my ($self, %opts) = @_;

	my $store = $self->secrets_store(%opts);

	# Determine secrets_store from kit - assume vault for now (credhub ignored)
	if ($opts{all}) {
		# TODO: extract this to a method in Genesis::Env::Secrets::Store
		my @paths = $store->store_paths();
		return ({empty => 1}) unless scalar(@paths);

		my $plan = $self->secrets_plan(%opts, silent => 1);
		unless ($opts{'no-prompt'}) {
			die_unless_controlling_terminal(
				"\nCannot prompt for confirmation to remove all secrets outside a ".
				"controlling terminal.  Use #C{-y|--no-prompt} option to provide ".
				"confirmation to bypass this limitation."
			);
			warning(
				"\nThis will delete the following %s secrets under '#C{%s}', which may".
				"include non-generated values set by 'genesis new' or manually created:\n",
				scalar(@paths), $self->secrets_base
			);
			my $prefix = $store->base =~ s/^\///r;
			my $plan = $self->secrets_plan(%opts);
			for my $full_path (sort @paths) {
				my $path = $full_path =~ s/^$prefix//r;
				my $secret = $plan->secret_at($path);
				if ($secret) {
					info(bullet(sprintf(
						"#C{%s} #i{%s}",
						$path,
						scalar($secret->describe),
					)));
				} else {
					my @keys = keys %{$store->store_data->{$full_path}};
					for my $ext_path (map {$path.':'.$_} sort @keys) {
						$secret = $plan->secret_at($ext_path);
						if ($secret) {
							info(bullet(sprintf(
								"#C{%s}:#c{%s} #i{%s}",
								split(":", $secret->path, 2),
								scalar($secret->describe),
							)));
						} elsif (($secret) = grep {$_->get('format') && $_->can('format_path') && ($_->format_path//'') eq $ext_path} ($plan->secrets)) {
							info(bullet(sprintf(
								"#C{%s}:#c{%s} #i{%s}",
								split(":", $secret->format_path, 2),
								scalar($secret->describe('format')),
							)))
						} else {
							info(bullet(sprintf(
								"#C{%s}:#c{%s} #%s{%s}",
								split(":", $ext_path, 2),
								"R", "not defined by kit"
							)))
						}
					}
				}
			}
			my $response = prompt_for_line(undef, "Type 'yes' to remove these secrets; anything else will abort","");
			if ($response ne 'yes') {
				return ({abort => 1}, sprintf(
					"Keeping all existing secrets under '#C{%s}'.",
					$store->base
				));
			}
		}
		output {pending => 1}, "Deleting existing secrets under '#C{%s}'...", $store->base;
		my ($out,$rc) = $store->service->query('rm', '-rf', $store->base);
		$self->secrets_plan->reset_secrets;

		if ($rc) {
			my $msg = "Failed to remove secrets under '#C{%s}':\n%s";
			return ({error => 1}, sprintf($msg, $store->base, $out));
		}
		return ({success => 1}, "#G{All applicable secrets removed.}");
	}

	$self->manifest_provider->kit_files(); #process blueprint
	my $plan = $self->secrets_plan(%opts);
	unless ($plan->secrets || $opts{invalid} >= 3) {
		# FIXME: this should get returned as a result to the calling proceedure
		if ($plan->filters) {
			info("\nNo applicable secrets found - no need to continue.\n");
		} else {
			$self->notify(success => "doesn't have any secrets to remove.\n");
		}
		exit 0;
	}

	return $plan->remove_secrets(
		no_prompt       => $opts{'no-prompt'},
		invalid         => $opts{invalid},
		interactive     => $opts{interactive},
		level           => $opts{verbose}?'full':'line'
	);
}

# }}}

# Messaging
# notify - print an environment-specific message {{{
sub notify {
	my $self = shift;
	my ($target, $prefix,$postfix) = $_[0] =~ /^(error|warning|fatal|success)$/
		? (shift,"","")
		: ("info","[","]");
	my $opts = ref($_[0]) eq 'HASH' ? shift : {};
	my $msg = shift;
	bug(
		"Invalid message argument to 'notify' - expected a string, got undefined value: [%s]",
		join(", ", map {$_//'<undef>'} @_)
	) if grep {!defined} (@_);
	$msg = sprintf($msg, @_) if scalar(@_);

	# Check for custom prefix
	if (ref($self->{notify_prefix_overrides}) eq 'HASH' && defined $self->{notify_prefix_overrides}{$msg}) {
		$prefix = delete($self->{notify_prefix_overrides}{$msg});
		return $self->can($target)->($opts, "%s%s", $prefix, $msg);
	}

	$self->can($target)->($opts, "\n%s#M{%s}/#c{%s}%s %s", $prefix, $self->name, $self->type, $postfix, $msg);
}

# }}}

# Post-deployment Activities
# bosh_logs - get the logs for the environment {{{
sub bosh_logs {
	my ($self, @extra_opts ) = @_;

	if (grep {$_ =~ /^(-h|--help)$/} @extra_opts) {
		info("\nFetching help for 'bosh logs'...\n");
		$self->bosh->execute({interactive => 1}, "logs", "--help");
		exit 0;
	}

	bail(
		"Cannot use log with -f|--follow option; use %s %s bosh logs %s instead",
		$ENV{GENESIS_CALL_BIN},
		$ENV{'GENESIS_PREFIX_'.uc($ENV{GENESIS_PREFIX_TYPE})},
		join(" ", map {$_ =~ /\s+/ ? "'$_'" : $_} @extra_opts)
	)	if (grep {$_ =~ /^(-f|--follow)$/} @extra_opts);

	my %opts = ref($extra_opts[0]) eq 'HASH' ? %{shift @extra_opts} : ();

	$self->notify("fetching BOSH logs for %s/%s...", $self->name, $self->type);
	my $log_path = $Genesis::RC->get('bosh_logs_path');
	my $deployment_root = $ENV{GENESIS_DEPLOYMENT_ROOT};
	unless ($deployment_root) {
		if (-f ".genesis/config") {
			$deployment_root = Cwd::abs_path('..');
		} else {
			$deployment_root = Cwd::abs_path('.');
		}
	}
	$log_path =~ s/^<DEPLOYMENT_ROOT>\//$deployment_root\//;
	my $dep_log_path = $log_path.'/'.$self->name.'/'.$self->type;
	info("- logs will be saved to %s", humanize_path($dep_log_path));

	mkdir_or_fail($dep_log_path) unless -d $dep_log_path;

	info("- fetching logs...\n");
	pushd($log_path);
	my $bosh = $self->bosh;
	my ($out, $rc, $err) = $bosh->execute({interactive => 1}, "logs", @extra_opts);
	info("");
	if ($rc) {
		bail("Failed to fetch logs: %s", $err);
	}

	$self->notify("extracting logs...");
	my $grouped = $out =~ m/Fetching group of logs: Packing log files together/;
	my @archives = $out =~ m/Downloading resource .* to '(.*)'\.\.\./g;
	my @logs = ();
	if ($grouped) {
		for my $archive (@archives) {
			my $file_name = basename($archive) =~ s/\.tgz$//r;
			my ($extract_out, $extract_rc, $extract_err) = run({stderr => 0},
				"tar", "xzf", $archive, "-C", $dep_log_path
			);
			if ($extract_rc) {
				warning("- failed to extract packed archive %s: %s", $file_name, $extract_err);
			} else {
				info("- extracted packed archive %s", $file_name);
			}
			unlink $archive;
		}
	} else {
		# Move the singleton log into the right place with the corrected name
		basename($archives[0]) =~ m/^(.*?)[-\.](\d\d\d\d)(\d\d)(\d\d)-(\d\d)(\d\d)(\d\d)-(\d+)\.tgz$/;
		my $new_archive = sprintf("%s.%s-%s-%s-%s-%s-%s.tgz", $1, $2, $3, $4, $5, $6, $7);
		require File::Copy;
		File::Copy::move($archives[0], "$dep_log_path/$new_archive")
			or bail("Failed to move %s to %s: %s", $archives[0], "$dep_log_path/$new_archive", $!);
	}

	pushd($dep_log_path);
	my @dep_archives = glob("*.tgz");

	foreach my $archive (@dep_archives) {
		my $file_name = $archive =~ s/\.tgz$//r;
		my ($job, $vmid, $ts) = split /\./, $file_name;

		my $target_dir = "$dep_log_path/$job/$vmid/$ts";
		mkdir_or_fail($target_dir) unless -d $target_dir;

		my ($out, $rc, $err) = run("tar", "-zxf", $archive, "-C", $target_dir);
		if ($rc) {
			warning("failed to extract archive %s: %s", $file_name, $err);
		} else {
			info("- extracted archive %s", $file_name);
		}
		unlink $archive;
	}
	popd();
	popd();
	$self->notify(success => "BOSH logs fetched successfully - they can be found in #G{%s}\n", humanize_path($dep_log_path));
}
# }}}

# }}}

### Private Instance Methods {{{

sub _check_environment_viability {
	my ($self) = @_;

	my $checks = "environmental parameters";
	$checks = "BOSH configs and $checks" if scalar($self->configs);
	my $ok = 1;

	if ($self->has_hook('check')) {
		$self->notify("running %s checks...", $checks);
		$self->run_hook('check') or $ok = 0;
	} else {
		$self->notify("#Y{%s does not define a 'check' hook; $checks checks will be skipped.}", $self->kit->id);
	}

	my $kit_files = eval {
		$self->manifest_provider->kit_files(); # pre-warm the cache
	};
	my $err = $@;
	if ($err) {
		info("[[  - >>manifest blueprint #R{failed}");
		return {
			state => 'error',
			fatal => 1,
			msg   => "Kit files could not be generated -- cannot continue with further checks:\n\n".fix_wrap($err),
		};
	}
	info("[[  - >>manifest blueprint #G{passed}");
	return {
		state     => $ok ? 'ok' : 'error',
		msg       => $ok ? "environmental is viable" : "environmental is not viable",
		kit_files => $kit_files,
	}
}

sub _check_cpi_config {
	# Check that the cpi config is available and unchanged on the director.
	# Returns a hash:
	#  state => 'ok' | 'changed' | 'missing'
	#  fatal => 1 | 0
	#  fix_data => {
	#    cpi_config => <yaml config string>,
	#    name => <name of the config>,
	#    director => <bosh director>
	#  }
	#  msg => <message to display>
	my ($self) = @_;

	return {
		state => 'ok', msg => "using create-env, no CPI config needed."
	} if $self->use_create_env; # No cpi check needed

	my $cpi_name = $self->cpi_name;
	my $director = $self->bosh;

	# FIXME: Need to deal with the "default" config that doesn't show up in the
	# list of configs.  This is the default config that the director uses if
	# it doesn't explicitly have a cpi config.
	# FIXME: inform user that we're checking the cpi config on the director
	my $current_config = $director->get_config('cpi', $cpi_name);
	my $has_hook = $self->has_hook('cpi-config');
	unless ($current_config) {
		return $has_hook ? {
			state => 'missing',
			msg   => sprintf("missing CPI config"),
			fix_data => { name => $cpi_name, director => $director },
		} : {
			state => 'missing',
			fatal => 1,
			msg   => sprintf("missing CPI config - kit does not provide a cpi-config hook"),
		};
	}

	return {
		state => 'ok',
		msg   => sprintf("CPI config #m{%s} is provided by the BOSH director #M{%s}.", $cpi_name, $director->alias),
	} unless $has_hook;

	# Check if the config is up-to-date
	my $cpi_config = $self->run_hook(
		'cpi-config',
		credhub_prefix => $self->cpi_credhub_base
	);
	info("[[  - >>CPI config synthesized.");

	my ($diff,$is_diff) = spruce_diff(
		{content => $current_config,        label => 'current'},
		{content => $cpi_config->{content}, label => 'new'}
	);

	if ($is_diff) {
		info(
			"[[  - >>required CPI config #m{%s} is different from the one currently on the BOSH director:\n\n%s",
			$cpi_name, $diff
		);
		return {
			state    => 'changed',
			fix_data => {
				cpi_config => $cpi_config,
				name       => $cpi_name,
				director   => $director,
			},
			msg      => sprintf("CPI config #m{%s} is different from the one currently on the BOSH director.", $cpi_name),
		};
	} else {
		info("[[  - >>current CPI config #m{%s} is up-to-date.", $cpi_name);
	}

	# Check if any entombed secrets are empty or missing
	my @secrets = sort keys %{$cpi_config->{credhub_secrets}};

	my @empty = grep {
		($cpi_config->{credhub_secrets}{$_}//'') eq ''
	} @secrets;

	if (@empty) {
		my $credhub_base = $self->credhub->base;
		info(
			"[[  - >>%d missing secret values:\n%s",
			scalar(@empty),
			join("\n", map {sprintf("[[  %s>>#R{%s}",bullet(''), $_ =~ s#.*--(.*)--.*#$1#r)} @empty)
		);
		return {
			state    => 'error',
			fatal    => 1,
			msg      => sprintf(
				"CPI config #m{%s} references secrets that have no value!%s",
				$cpi_name,
				$self->is_ocfp ? "\n\n#yi{This may be due to missing value in the OCFP config.}" : ''
			),
		};
	}

	my @missing_secrets = grep {
		!$self->credhub->has($_)
	} @secrets;

	if (@missing_secrets) {
		my $credhub_base = $self->credhub->base;
		info(
			"[[  - >>missing %d entombed secrets under #c{%s}:\n%s",
			scalar(@missing_secrets), $self->credhub->base,
			join("\n", map {sprintf("[[  %s>>#R{%s}",bullet(''), $_ =~ s#$credhub_base##r)} @missing_secrets)
		);
		return {
			state    => 'missing secrets',
			fatal    => 1,
			fix_data => {
				cpi_config => $cpi_config,
				name       => $cpi_name,
				director   => $director,
			},
			msg      => sprintf("CPI config #m{%s} is missing %d entombed secrets.", $cpi_name, scalar(@missing_secrets)),
		};
	}

	return {
		state => 'ok',
		msg  => sprintf("CPI config is up-to-date"),
	};
}

# }}}
# _fix_cpi_config - fix the cpi config on the director {{{
sub _fix_cpi_config {
	my ($self, $state, $fix_data, %opts) = @_;

	# If no fix_data is provided, generate it using the cpi-config hook
	unless ($fix_data) {
		bail("Cannot fix CPI config without a valid cpi-config hook")
			unless $self->has_hook('cpi-config');
		$fix_data = {};
	}

	my $cpi_config = $fix_data->{cpi_config} // scalar($self->run_hook(
			'cpi-config',
			credhub_prefix => $self->cpi_credhub_base
		));
	my $cpi_name   = $fix_data->{name} // $self->cpi_name;
	my $director   = $fix_data->{director} // $self->bosh;
	my $indent     = $opts{indent} // "  - ";
	my $noprompt   = $opts{noprompt} // $ENV{BOSH_NON_INTERACTIVE} // 0;

	if ($state eq 'ok') {
		info("[[  - >>#G{CPI config is already up-to-date}");
		return {
			result => 'ok',
			msg    => sprintf("CPI config is up-to-date"),
		};
	}

	# Upload the CPI config to the BOSH director
	my $start = gettimeofday();
	if ($state ne 'missing secrets') {
		if (in_controlling_terminal && !$noprompt) {
			prompt_for_boolean(
				"Upload the new CPI config to the BOSH director ('no' will cancel ".$Genesis::Commands::COMMAND.")? [y|n]",
				1
			) or bail "Aborted by user!";
		}

		info({pending => 1}, # ??? $noprompt},
			"[[%s>>uploading CPI config #m{%s} to BOSH director #M{%s}...",
			$indent, $cpi_name, $director->alias
		);
		my ($out, $rc, $err) = $director->upload_config(
			$cpi_config->{content}, 'cpi', $cpi_name, !$noprompt
		);
		if ($rc) {
			info("#R{failed}".pretty_duration(gettimeofday() - $start));
			return {
				result => 'error',
				fatal  => 1,
				msg    => sprintf(
					"failed to upload CPI config: %s",
					$err ? $err : $out
				),
			}
		}
		info("#G{done}".pretty_duration(gettimeofday() - $start));
	}

	# Generate any missing CredHub secrets
	if ($cpi_config->{credhub_secrets} && ref($cpi_config->{credhub_secrets}) eq 'HASH') {
		my $count = scalar keys %{$cpi_config->{credhub_secrets}};
		info(
			"[[%s>>generating %d missing CredHub secrets used by CPI config #m{%s}...",
			$indent, $count, $cpi_name
		) if $count;
		my $credhub = $self->credhub;
		my %existing_secrets = eval {map {$_, 1} $credhub->paths($self->cpi_credhub_base)};
		my $idx = 0;
		my $width = length($count);
		my $prefix = $indent =~ s/./ /gr;

		my $failed = 0;
		for my $secret (sort keys %{$cpi_config->{credhub_secrets}}) {
			my ($name,$sha1) = $secret =~ m{/[^/]+--([^/]+)--([^/]+)$};
			info({pending => 1},
				"[[%s[%*s] >>#m{%s} #Ki{(sha: %s)}...",
				$prefix, $width, ++$idx, $name, $sha1
			);

			# Only upload the secret if it doesn't exist
			if ($existing_secrets{$secret} || $credhub->has($secret)) {
				info("#B{exists}");
				next;
			}

			my $value = $cpi_config->{credhub_secrets}{$secret};
			if (!defined($value)) {
				info("#R{invalid value}");
				$failed = 1;
				next;
			}

			my ($out, $err) = $credhub->set($secret, $value);
			if ($err) {
				info("#R{failed}");
				$failed = 1;
			} else {
				info("created");
			}
		}

		if ($failed) {
			info("[[  - >>#R{failed to create some secrets}");
			return {
				result => 'error',
				fatal  => 1,
				msg    => sprintf("failed to create some secrets"),
			};
		}
	}

	return {
		result => 'ok',
		msg    => sprintf("successfully uploaded CPI config"),
	};
}

# _check_cloud_config - check the cloud config {{{
sub _check_cloud_config {
	my ($self) = @_;
	# TODO: Implement cloud config check; see Genesis::Commands::Env for planned usage
	return;
}

# }}}
# _fix_cloud_config - fix the cloud config on the director {{{
sub _fix_cloud_config {
	my ($self, $fix_data, %opts) = @_;
	# TODO: Implement cloud config fix; see Genesis::Commands::Env for planned usage
	return;
}

# }}}
# _check_secrets - check the secrets {{{
sub _check_secrets {
	my ($self) = @_;

	my %check_opts=(indent => '  ', validate => ! envset("GENESIS_TESTING_CHECK_SECRETS_PRESENCE_ONLY"));

	# FIXME: Revisit the _check_secrets(this ui wrapper) vs check_secrets (thing that
	# actually does the work) - this is a bit confusing and thus error-prone.
	my ($secrets_results, $secrets_msg) = $self->check_secrets(%check_opts);
	if ($secrets_results) {
		return {
			state => 'error',
			msg   => '#R{invalid secrets detected}',
		}	if ($secrets_results->{error});

		if ($secrets_results->{missing}) {
			my $msg = "#{missing secrets detected}";
			if ($self->is_vaultified && grep {$_->{source} eq 'manifest'} ($self->secrets_plan->secrets)) {
				$msg .= csprintf(
					" (you may need to run '#g{%s add-secrets} #Y{--import}' to import them from credhub)",
					scalar($self->get_call_path_with_env)
				);
			}
			return {
				state => 'error',
				msg   => $msg,
			};
		}
		return {
			state => 'warning',
			msg   => "#y{all secrets valid, but warnings were encountered.}",
		}	if ($secrets_results->{warn});
		return {
			state => 'ok',
			msg   => "#G{all secrets valid}",
		}
	}
}
# }}}
# _fix_secrets - fix the secrets {{{
sub _fix_secrets {
	my ($self, %opts) = @_;
	my $ok = 1;

	# FIXME: Find a way to check if secrets are in the manifest (ie credhub
	# secrets), and import them if they're not in the vault but are in credhub
	# (does import skip secrets already in vault?)
	if ($self->is_vaultified && grep {$_->{source} eq 'manifest'} ($self->secrets_plan->secrets)) {
		# Check if there are any credhub secrets for the environment, and if there
		# are, tell user what to do.  Otherwise, just generate any missing secrets
		# normally..
		my $existing_ch_secrets = scalar(grep {$_ !~ /genesis-entombed/} $self->credhub->paths());
		bail(
			"Cannot safely fix secrets in vaultified environment with manifest ".
			"secrets, as they already exist in credhub.  Please import them from ".
			"credhub manually by calling:\n".
			"[[  >>#g{%s add-secrets} #Y{--import}\n\n".
			"Once that is done, remove the credhub secrets by calling:\n".
			"[[  >>#g{%s remove-secrets} #Y{--unused}\n\n".
			"Then you can this command to fix any remaining invalid secrets (or ".
			"run #g{%s add-secrets} again without the #Y{--import} option).",
			(scalar($self->get_call_path_with_env)) x 3
		)	if $existing_ch_secrets;
	}

	my ($rotate_results, $rotate_msg) = $self->rotate_secrets(
		notice      => "checking secrets, and repairing if necessary...",
		action      => 'repair',
		'no-prompt' => $opts{noprompt},
		invalid     => 1,
		interactive => 0,
		level       => 'line', # Maybe support full in 'verbose' mode (which is not yet implemented)?
	);
	if (ref($rotate_results) eq 'HASH') {
		return {
			result => 'ok',
			msg    => "#G{no invalid secrets detected.}",
		} if $rotate_results->{empty};
		return {
			result => 'error',
			fatal  => 1,
			msg    => "#r{could not successfully rotate secrets.}"
		} if $rotate_results->{error};
		return {
			result => 'abort',
			fatal  => 1,
			msg    => "#R{user aborted secret rotation.}"
		} if $rotate_results->{abort};
		return {
			result => 'warn',
			msg    => "#y{all secrets valid, but warnings were encountered.}"
		} if $rotate_results->{warn};
		return {
			result => 'ok',
			msg    => "#G{secrets successfully rotated.}"
		}
	}

	require Data::Dumper;
	bug(
		"#R{invalid return from rotate_secrets: %s}",
		Data::Dumper::Dumper($rotate_results)
	);
}

# }}}
# _check_release_url_sha1 - check that HTTP/HTTPS release URLs have SHA1 checksums {{{
sub _check_release_url_sha1 {
	my ($self) = @_;
	$self->notify("checking release URLs for SHA1 checksums...");

	my @missing_sha1 = ();
	my $releases = $self->manifest_provider->deployment(subset=>'releases')->data;

	if (ref($releases) eq 'ARRAY' && scalar(@$releases)) {
		for my $release (@$releases) {
			# Check if the release has a URL and if it's HTTP/HTTPS
			if (defined($release->{url}) && $release->{url} =~ m{^https?://}) {
				# Check if SHA1 is missing
				unless (defined($release->{sha1}) && $release->{sha1} ne '') {
					push @missing_sha1, {
						name => $release->{name},
						version => $release->{version},
						url => $release->{url}
					};
				}
			}
		}
	}

	if (!@missing_sha1) {
		info("[[  - >>#G{All HTTP/HTTPS release URLs have SHA1 checksums}");
		return {
			state => 'ok',
			msg   => "all HTTP/HTTPS release URLs have SHA1 checksums",
		}
	}

	error "[[  - >>#R{The following releases are missing SHA1 checksums:}";
	for my $release (@missing_sha1) {
		error(
			"[[       %s #C{%s} v#M{%s}\n[[         URL: #y{%s}",
			bullet('bad', '>>', indent => 0),
			$release->{name},
			$release->{version} || 'unknown',
			$release->{url}
		);
	}
	error "\n[[  - >>BOSH requires SHA1 checksums for all HTTP/HTTPS release URLs.";
	error "[[  - >>Please add a 'sha1' field to each release definition above.";

	return {
		state => 'error',
		msg   => sprintf(
			"%d release%s missing SHA1 checksum%s for HTTP/HTTPS URL%s",
			scalar(@missing_sha1),
			scalar(@missing_sha1) == 1 ? ' is' : 's are',
			scalar(@missing_sha1) == 1 ? '' : 's',
			scalar(@missing_sha1) == 1 ? '' : 's'
		),
	};
}

# }}}
# _check_release_overrides - check the release overrides {{{
sub _check_release_overrides {
	my ($self) = @_;
	$self->notify("checking for release overrides...");

	my @overrides = ();
	my @outdated = ();
	my $env_releases = $self->manifest_provider->partial_environment(subset=>'releases')->data;
	$env_releases = $env_releases->{releases} if ref($env_releases) eq 'HASH';
	if (ref($env_releases) eq 'ARRAY' && scalar(@$env_releases)) {

		my $kit_releases = scalar(load_yaml(scalar(run(
			'spruce','merge',
			'--skip-eval','--go-patch','-m',
			'--cherry-pick', 'releases',
			map { $_ =~ m{^/} ? $_ : $self->kit->path($_)} $self->kit_files)))
		)->{releases} // [];

		# Step through each override sorted by release name
		for my $override (sort {$a->{name} cmp $b->{name}} @$env_releases) {
			my ($release) = grep {$_->{name} eq $override->{name}} @$kit_releases;
			push @overrides, [$override->{name}, $override->{version}, $release ? $release->{version} : undef]
				if !$release || !defined($release->{version}) || !defined($override->{version}) || $release->{version} ne $override->{version};
		}
	}
	if (!@overrides) {
		info("[[  - >>#G{No release overrides found}");
		return {
			state => 'ok',
			msg   => "no release overrides found",
		}
	}

	info "[[  #E{warning}>>#y{environment overrides the following releases:}";
	for my $override (@overrides) {
		my ($name, $env_version, $kit_version) = @$override;
		if (defined $kit_version) {
			if (defined $env_version) {
				info(
					"[[     %s#C{%s} #y{v%s} => #%s{v%s}",
					bullet('', '>>', indent => 0),
					$name, $kit_version,
					(defined($env_version) && defined($kit_version) && new_enough($env_version,$kit_version)) ? 'G' : 'R', $env_version
				);
			} else {
				info(
					"[[     %s#C{%s} #y{v%s} => #R{undefined version}",
					bullet('', '>>', indent => 0),
					$name, $kit_version
				);
			}
		} else {
			info(
				"[[    >>#C{%s} #G{v%s} added (not found in kit)",
				$name, $env_version // 'undefined'
			);
		}
	}
	@outdated = grep {defined($_->[1]) && defined($_->[2]) && !new_enough($_->[1],$_->[2])} @overrides;
	return {
		state => @outdated ? 'outdated' : 'overridden',
		msg   => sprintf(
			"environment overrides %d releases, %d of which are outdated",
			scalar(@overrides), scalar(@outdated)
		),
	};
}

# }}}
# _check_stemcells - check the stemcells {{{
sub _check_stemcells {
	my ($self) = @_;

	if ($self->use_create_env) {
		$self->notify("#Y{create-env environment detected - skipping stemcell checks}"); # TODO: Move this out to caller for customization
		return {
			state => 'ok',
			msg   => "using create-env, no stemcell needed."
		};
	}

	$self->notify("running stemcell checks...");
	my @stemcell_status = $self->_get_stemcell_status(1);

	my (@missing, @alt) = ();
	for my $stemcell_info (@stemcell_status) {
		if ($stemcell_info->{found}) {
			my $wants_latest = $stemcell_info->{latest};
			my %details = $stemcell_info->{found}->%*;
			info(
				"[[%s>>Stemcell #C{%s} (%s/%s) %s%s",
				bullet('good', '', box => 1),
				$stemcell_info->{alias}, $details{os},
				$stemcell_info->{search_term},
				$wants_latest ? "#G{will use v$details{version}}" : '#G{present}',
				$self->cpi_enabled ? " for CPI #C{".$stemcell_info->{cpi}."}" : "",
			);

			# Warn if alternative stemcell is found
			if ($stemcell_info->{alt}) {
				info(
					"[[       #Y{Warning:} >>#C{v%s} would be used, but does not support the #m{%s} CPI",
					$stemcell_info->{version},
					$stemcell_info->{cpi} eq '<default>' ? 'default' : $stemcell_info->{cpi}
				);
				push @alt, $stemcell_info;
			}
			next;
		}

		# Deal with missing stemcells
		info(
			"[[%s>>Stemcell #C{%s} (%s/%s) %s%s#R{!}",
			bullet('bad', '', box => 1),
			$stemcell_info->{alias}, $stemcell_info->{os},
			$stemcell_info->{search_term},
			$stemcell_info->{latest} ? "#R{- no matching stemcells available}" : '#R{missing}',
			$self->cpi_enabled ? "#R{ for CPI }#ri{".$stemcell_info->{cpi}."}":"",
		);
		push(@missing, $stemcell_info);
	}

	if (@missing) {
		# Some stemcells are missing, while others have preferred alternatives
		my @unknown = grep {!defined($_->{alt})} @missing;
		return {
			state => 'error',
			fatal => 1,
			msg   => "required stemcells source unknown - requires manual upload:\n- #R{".join("\n- ", map {$_->{os}."@".$_->{search_term}} @unknown)."}",
		} if @unknown;

		return {
			state => 'error',
			msg   => "missing required or preferred stemcells",
			fix_data => {
				missing => \@missing,
				alt     => \@alt,
			}
		}
	} elsif (@alt) {
		# No stemcells missing, but there are preferred alternatives
		return {
			state => 'degraded',
			msg   => "missing preferred stemcells",
			fix_data => {
				missing => \@missing,
				alt     => \@alt,
			},
		}
	} else {
		return {
			state => 'ok',
			msg   => "all required stemcells are present and curent",
		}
	}
}

# }}}
# _fix_stemcells - fix the stemcells on the director {{{
sub _fix_stemcells {
	my ($self, $fix_data, %opts) = @_;

	unless ($fix_data) {
		bail("Cannot fix stemcells without a valid fix_data");
		# Todo: should this just call _check_stemcells() to get the fix_data if missing?
	}

	my ($missing, $alt) = $fix_data->@{qw/missing alt/};
	my @unknown = grep {!defined($_->{alt})} (@$missing, @$alt);
	bail (
		"Required stemcells source unknown - requires manual upload:\n- #R{%s}",
		join("\n- ", map {$_->{os}."@".$_->{search_term}} @unknown)
	) if @unknown;

	my @downloadable = grep {$_->{alt}} (@$missing, @$alt);
	my $noprompt = $opts{noprompt} // $ENV{BOSH_NON_INTERACTIVE} // 0;

	return {
		result => 'ok',
		msg    => "all required stemcells are present and current"
	} unless @downloadable;
	my $type = 'missing and preferred';

	if (!$noprompt) {
		bail(
			"\nCannot prompt for confirmation to upload stemcells outside a controlling terminal.  ".
			"Use #Y{-y|--yes} option to provide confirmation to bypass this limitation outside a controlling terminal."
		) unless in_controlling_terminal;

		my $selection = new_prompt_for_choice(
			header => "Upload all missing and preferred stemcells, or just the required ones?",
			choices => [
				{value => 'all',      label => "Upload all missing and preferred stemcells"},
				{value => 'required', label => "Upload only the required stemcells"},
				{separator => 1},
				{value => 'abort',    label => "Abort and do not upload any stemcells"},
			],
			default => 'all',
		);

		bail "Aborted by user!" if $selection eq 'abort';
		$type = 'required' if $selection eq 'required';
		@downloadable = grep {
			$selection eq 'all' || !$_->{found}
		} @downloadable;
	}

	if ($type eq 'required' && @downloadable == 0) {
		$self->notify("#G{No required stemcells to upload}");
		return {
			result => 'ok',
			msg    => "no missing required stemcells",
		};
	}

	my @failed_required = ();
	$self->notify("uploading $type stemcells:");
	my %uploaded = ();
	my $indent = $opts{indent} // 4;;
	for my $stemcell (uniq(@downloadable)) {
		my $alias = $stemcell->{alias};
		my $id = $stemcell->{os}.'@'.$stemcell->{alt}{version};
		my $required = $stemcell->{found} ? 0 : 1;
		info({pending => 1},
			"[[%*s>>%s#C{%s} stemcell (%s/%s) ...",
			$indent,
			bullet(''),
			$type eq 'required' ? '': $required ? "#R{required} " : "#B{preferred} ",
			$alias, $stemcell->{os},
			$stemcell->{alt}{version}
		);

		if ($uploaded{$id}) {
			# This really shouldn't happen, but just in case
			info("#y{already uploaded!}");
		} else {
			local $ENV{BOSH_NON_INTERACTIVE} = 1;
			my $upload_start = gettimeofday();
			my $bosh = $self->get_target_bosh({parent => 1});
			my ($out, $rc, $err) = $stemcell->{alt}->upload(
				$bosh, fix => 1, silent => 1
			);
			if ($rc) {
				info("#R{failed}".pretty_duration(gettimeofday - $upload_start));
				error(
					"\nFailed to upload stemcell: #r{%s}\n",
					join("\n", $out, $err)
				);
				push @failed_required, $stemcell;

				bail(
					"Cannot continue without required stemcells - aborting!\n".
					"Please upload the stemcells manually and re-run the command.",
				) if $required;
			} else {
				info("#G{done}".pretty_duration(gettimeofday - $upload_start));
				$uploaded{$id} = 1;
			}
		}
	}
	return {
		result => 'warning',
		msg    => sprintf(
			"failed to upload %d preferred stemcells",
			scalar(@failed_required)
		),
		failed => \@failed_required,
	} if @failed_required;

	return {
		result => 'ok',
		msg    => sprintf(
			"successfully uploaded %d stemcells",
			scalar(@downloadable)
		),
	};
}

sub _advise_stemcell_updates {
	my ($self, $fix_data) = @_;
	unless ($fix_data) {
		bail("Cannot fix stemcells without a valid fix_data");
		# Todo: should this just call _check_stemcells() to get the fix_data if missing?
	}

	my ($missing, $alt) = $fix_data->@{qw/missing alt/};
	my @downloadable = grep {$_->{alt}} (@$missing, @$alt);

	my $msg = "\n#Y{The following stemcells are available for download:}";
	my @stemcell_ids = ();
	for my $stemcell_info (@downloadable) {
		my $required = $stemcell_info->{found} ? 0 : 1;
		$msg .= sprintf(
			"\n[[%s>>%s#C{%s} stemcell (%s/%s)",
			bullet(''),
			$required ? "#R{required} " : "#B{preferred} ",
			$stemcell_info->{alias}, $stemcell_info->{os},
			$stemcell_info->{alt}{version}
		);
		push @stemcell_ids, sprintf("%s@%s", $stemcell_info->{alt}{os}, $stemcell_info->{alt}{version});
	}

	my $cmd = Genesis::Commands->current_command;
	my $fix_opt = $cmd eq 'deploy'
		? '--fix-stemcells|--fix-checks|-F'
		: '';

	$msg .= "\n\nThese can be downloaded by running the following command:\n";
	$msg .= "[[  > >>#G{%s do upload-stemcells %s}";
	$msg .= (
		"\n\n#Yu{Note:} You can also use the #Y{%s} argument to the #G{%s} command ".
		"to automatically fetch and upload stemcells.\n\n"
	) if $fix_opt;

	info(
		$msg,
		join(' ', $self->get_call_path, '<parent-bosh-director-env>'),
		join(' ', map {"'$_'"} @stemcell_ids),
		$fix_opt ? ($fix_opt, $cmd) : (),
	);
}

# _genesis_inherits - return the list of inherited files (recursive) {{{
sub _genesis_inherits {
	my ($self,$file, @files) = @_;
	my ($out,$rc,$err) = run({stderr => 0},'cat "$1" | spruce merge --skip-eval --go-patch --multi-doc | spruce json', $self->path($file));
	bail "Error processing json in $file!:\n$err" if $rc;

	# Better error handling for empty output
	if (!$out || $out =~ /^\s*$/) {
		bail "Spruce returned empty output when processing file %s - the file may have YAML syntax errors or be empty", $file;
	}

	my @contents = eval {
		map {load_json($_)} lines($out)
	};
	if ($@) {
		bail "Failed to parse JSON from spruce output for file %s: %s\nOutput was: %s", $file, $@, $out;
	}

	my @new_files;
	for my $contents (@contents) {
		next unless $contents->{genesis}{inherits};
		bail(
			"$file specifies 'genesis.inherits', but it is not a list"
		) unless ref($contents->{genesis}{inherits}) eq 'ARRAY';

		for (@{$contents->{genesis}{inherits}}) {
			s/\.yml$//; # remove any .yml extensions
			my $cached_file = '';
			if ($ENV{PREVIOUS_ENV}) {
				$cached_file = ".genesis/cached/$ENV{PREVIOUS_ENV}/$_.yml";
				$cached_file = undef unless -f $self->path($cached_file);
			}
			my $inherited_file = $cached_file || "./$_.yml";
			next if grep {$_ eq $inherited_file} @files;
			push(@new_files, $self->_genesis_inherits($inherited_file,$file,@files,@new_files),$inherited_file);
		}
	}
	return(@new_files);
}

# }}}
# _init_yaml_file - build the initialization yaml file for merging and return the path to it {{{
sub _init_yaml_file {
	my $self       = shift;
	my $vault_path = $self->secrets_base =~ s#/?$##r; # backwards compatibility
	my $type       = $self->type;
	my $init_file  = $self->workpath("init.yml");

	if ($self->kit->feature_compatibility('2.6.13')) {
		mkfile_or_fail($init_file, 0644, <<EOF);
---
meta:
  vault: $vault_path
kit:
  features: []
exodus:  {}
genesis: {}
params:  {}
EOF
	} else {
		mkfile_or_fail($init_file, 0644, <<EOF);
---
meta:
  vault: $vault_path
kit:
  features: []
exodus: {}
genesis: {}
params:
  env:  (( grab genesis.env ))
  name: (( concat genesis.env || params.env "-$type" ))
EOF
	}
	return $init_file;
}

# }}}
# _cap_yaml_file - build the wrap-up yaml file for merging and return the path to it {{{
sub _cap_yaml_file {
	my $self       = shift;
	my $type       = $self->type;
	my $cap_file  = $self->workpath("fin.yml");

	my $now = strftime(EXODUS_TIME_FORMAT, gmtime());
	my $bosh_target = $self->use_create_env ? "~" : $self->bosh_env->{description};
	my $bosh_exodus_path = $self->use_create_env ? "~" : $self->bosh->exodus_path;
	mkfile_or_fail($cap_file, 0644, <<EOF);
---
name: (( concat genesis.env "-$type" ))
genesis:
  env:           ${\(scalar $self->lookup(['genesis.env','params.env'], $self->name))}
  type:          $type
  vault_env:     ${\($self->env_vault_slug)}
  secrets_mount: ${\($self->secrets_mount)}
  secrets_path:  ${\($self->secrets_slug)}
  secrets_base:  ${\($self->secrets_base)}
  exodus_mount:  ${\($self->exodus_mount)}
  exodus_path:   ${\($self->exodus_slug)}
  exodus_base:   ${\($self->exodus_base)}
  ci_mount:      ${\($self->ci_mount)}${\(
  ($self->use_create_env || $self->bosh_env->{description} eq $self->name) ? "" :
	"\n  bosh_env:      $bosh_target".
	"\n  bosh_exodus_base:  $bosh_exodus_path"
	)}${\(
	$self->is_ocfp
	? "\n  ocfp:          true".
		"\n  ocfp_env:      ".$self->ocfp_env .
		"\n  ocfp_config_mount:  ".$self->ocfp_config_mount .
		"\n  ocfp_config_base:   ".$self->ocfp_config_base
	: ''
	)}

exodus:
  version:        $Genesis::VERSION
  dated:          $now
  deployer:       (( grab \$CONCOURSE_USERNAME || \$USER || "unknown" ))
  kit_name:       ${\($self->kit->metadata->{name} || 'unknown')}
  kit_version:    ${\($self->kit->metadata->{version} || '0.0.0-rc0')}
  kit_is_dev:     ${\($self->kit->is_dev ? 'true' : 'false')}
  vault_base:     (( grab meta.vault ))
  bosh:           $bosh_target
  iaas:           ${\($self->iaas)}
  scale:          ${\($self->scale)}
  is_director:    ${\($self->is_bosh_director ? 'true' : 'false')}
  use_create_env: ${\($self->use_create_env ? 'true' : 'false')}
  features:       (( join "," kit.features ))
  services:       ${\(join(",", $self->kit->services) || '~')}
EOF
}

# }}}
# _cc_yaml_files - return the list of cloud config files needed to merge manifests {{{
sub _cc_yaml_files {
	my ($self,$skip_eval) = @_;

	my @cc;
	if ($self->use_create_env) {
		trace("[env $self->{name}] in _yaml_files(): IS a create-env, skipping cloud-config");
	} elsif ($skip_eval) {
		trace("[env $self->{name}] in _yaml_files(): skipping eval, no need for cloud-config");
		push @cc, $self->config_file('cloud') if $self->config_file('cloud'); # use it if its given
	} else {
		trace("[env $self->{name}] in _yaml_files(): not a create-env, we need cloud-config");

		my @cloud_configs = grep {$_ =~ /^cloud(\@.*)?$/} $self->required_configs('blueprint');
		if (@cloud_configs) {
			$self->download_required_configs('blueprint') if $self->missing_required_configs('blueprint');
			my @cc_files = uniq sort map {$self->config_file($_)} @cloud_configs;
			bail(
				"No cloud-config specified for this environment\n"
			) unless @cc_files;
			trace("[env $self->{name}] in _yaml_files(): cloud-configs: %s", join(", ", @cc_files));
			push @cc, @cc_files;
		}
	}
	return @cc;
}

# }}}
# _yaml_files - create genesis support yml files and return full ordered merge list {{{
sub _yaml_files {
	my ($self,$skip_eval) = @_;

	my @cc = $self->_cc_yaml_files($skip_eval);
	return (
		$self->_init_yaml_file(),
		$self->kit_files(1), # absolute
		@cc,
		$self->actual_environment_files(),
		$self->_cap_yaml_file(),
	);
}

# }}}
# _reactions - list of reactions specified in the environment file. {{{
sub _reactions {
	return @{
		$_[0]->_memoize(sub {
				my $reactions = $_[0]->lookup("genesis.reactions", {});
				bail(
					"Value of #y{genesis.reactions} must be a hashmap"
				) if ref($reactions) ne 'HASH';
				return [sort keys %$reactions];
			})
	};
}

# }}}
# _validate_reactions - ensure user hasn't specified any in valid reation types {{{
sub _validate_reactions {
	my @valid_reactions = qw/pre-deploy post-deploy/;
	my %reaction_validator; @reaction_validator{@valid_reactions} = ();
	my @invalid_reactions = grep ! exists $reaction_validator{$_}, ( $_[0]->_reactions );
	if (@invalid_reactions) {
		bail(
			"Unexpected reactions specified under #y{genesis.reactions}: #R{%s}\n".
			"Valid values: #G{%s}",
			join(', ', @invalid_reactions), join(', ',@valid_reactions)
		);
	}
	return;
}

# }}}
# _process_reactions - handle the specified environment reaction scripts {{{
sub _process_reactions {
	my ($self, $reaction, $reaction_vars) = @_;
	my $ok = 1;

	if ($self->lookup("genesis.reactions.$reaction")) {
		my %env_vars = $self->get_environment_variables('deploy');
		my $actions = $self->lookup("genesis.reactions.$reaction");
		info '';
		bail(
			"Value of #C{genesis.reactions.%s} must be a list of one or more hashmaps",
			$reaction
		) if ref($actions) ne "ARRAY" || scalar(@{$actions}) == 0;

		for my $action (@{$actions}) {
			bail(
				"Values in #C{genesis.reactions.i%s} list must be hashmaps",
				$reaction
			) if ref($action) ne "HASH";
			my @action_type = grep {my $i = $_; grep {$_ eq $i} qw/script addon/} keys(%{$action});
			bail(
				"Values in #C{genesis.reactions.%s} must have one #C{script} or #C{addon} key",
				$reaction
			) unless scalar(@action_type) == 1;
			my $script = $action->{$action_type[0]};
			if ($action_type[0] eq "script") {
				my @args = @{$action->{args}||[]};
				my @cmd = ('bin/'.$action->{script}, @args);
				info (
					"[#M{%s}/#c{%s}: #mi{%s}] Running script \`#G{%s}\` with %s:\n",
					$self->name, $self->type, uc($reaction), $cmd[0], (
						@args ? sprintf('arguments of [#C{%s}]', join(', ',map {"\"$_\""} @args)) : 'no arguments'
					)
				);
				my ($out, $rc) = run({
						dir => $env_vars{GENESIS_ROOT},
						eval_var_args => 1,
						interactive => 1,
						env => {%env_vars,%{$reaction_vars}}
					},
					@cmd
				);
				$ok = $rc == 0;
				if ($ok && defined($action->{var})) {
					$reaction_vars->{$action->{var}} = $out;
				}
			} else {
				bail(
					"#R{Kit %s does not provide an addon hook!}",
					$self->kit->id
				) unless $self->has_hook('addon');

				$self->download_required_configs('addon', "addon-$script");

				info(
					"[#M{%s}/#c{%s}: #mi{%s}] Running #G{%s} addon from kit #M{%s}:\n",
					$self->name,
					$self->type,
					uc($reaction),
					$script,
					$self->kit->id
				);
				$ok = $self->run_hook('addon', script => $script, args => $action->{args}, eval_var_args => 1, extra_vars => $reaction_vars);
			}
			info '';
			last unless $ok;
		}
	}
	return $ok;
}

# }}}
# _parse_bosh_env - parse the bosh env into its constituent parts, and returns a hashref {{{
sub _parse_bosh_env {
	my ($self, $bosh_env_description) = @_;
	bail("Undefined BOSH environment description") unless $bosh_env_description;

	# Pattern: <name>[/<type>][@[<url>]/<mount>]
	my ($name, $dep_type, $vault_url, $exodus_mount) =
		($bosh_env_description) =~ m/^([^\/\@]+)(?:\/([^\@]+))?(?:@(?:(https?:\/\/[^\/]+)?(?:\/|$))?(.*))?$/;

	return wantarray ? ($name, $dep_type, $vault_url, $exodus_mount) : {
		name         => $name,
		dep_type     => $dep_type,
		vault_url    => $vault_url,
		exodus_mount => $exodus_mount,
		description  => $bosh_env_description,
	};
}

# }}}
# _create_deployment_audit_log - create the audit log for the environment deployments and terminations {{{
sub _create_deployment_audit_log {
	my ($self, $action, $result, %audit_data) = @_;
	my $bails_with = delete($audit_data{bails_with});
	my $cleanup_cache = exists($audit_data{cleanup_cache}) ? delete($audit_data{cleanup_cache}) : 1;
	my $returns = delete($audit_data{returns});

	# Validate the action
	my @valid_actions = qw/deploy terminate/;
	bail(
		"Invalid action: %s.  Valid actions are: %s",
		$action, join(', ', @valid_actions)
	) unless in_array($action, @valid_actions);

	my ($out,$rc,$err) = $self->deployments->build(
		$action, $result,
		%audit_data,
	)->commit();

	bail(
		"Failed to set deployment audit data in exodus: %s\n%s",
		$out, $err
	) if $rc;

	if ($bails_with) {
		$bails_with = $bails_with->($self) if ref($bails_with) eq 'CODE';
		$bails_with = ['%s',$bails_with] if $bails_with && ref($bails_with) ne 'ARRAY';
		if ($bails_with) {
			$self->deployment_cache_cleanup if $cleanup_cache;
			bail(@$bails_with);
		}
	}

	$self->deployments->reset;
	return $returns
		? (ref($returns) eq 'CODE' ? $returns->($self, $out, $rc, $err) : $returns)
		: 1;
}

# }}}
# _get_stemcell_status - get the status of the stemcells {{{
sub _get_stemcell_status {
	# This will return an array of stemcell statuses (in the order given)
	# that will contain a hash of the following keys:
	#  - alias: the alias of the stemcell (specified in the manifest)
	#  - found: the stemcell that satisfies the request, or undef if not found
	#  - alt: the recommended stemcell to use if cpi not found
	#  - latest: true if searching for the latest.
	#  - cpi: the cpi name (or <default> if not specified)
	#  - search_type: exact, latest, or latest-minor
	#  - search_term: the stemcell version requested

	my ($self, $recalculate) = @_;
	require Service::BOSH::Stemcell;

	$self->{__stemcell_status} = undef if $recalculate;
	return wantarray ? @{$self->{__stemcell_status}} : $self->{__stemcell_status}
		if defined $self->{__stemcell_status};

	my $stemcells_to_check = $self->partial_manifest_lookup('stemcells');
	my %available = $self->bosh->stemcells;
	my %newest_by_os = ();
	for my $key (reverse sort {by_semver($available{$a}{version}, $available{$b}{version})} keys %available) {
		my ($os, $version) = split('@', $key, 2);
		push @{$newest_by_os{$os}}, $key;
	}
	my $cpi = $self->cpi_enabled ? $self->cpi_name : '<default>';
	my @results = ();

	for my $stemcell_info (@$stemcells_to_check) {
		my ($alias, $os, $version) = @$stemcell_info{qw/alias os version/};
		$alias //= "stemcell-$os-$version";
		my $newest = $newest_by_os{$os}->[0];
		my $result = {alias => $alias, os => $os, search_term => $version, cpi => $cpi};
		my ($wants_latest,$major_version) = $version =~ /^((?:(\d+)\.)?latest)$/;

		# Finding "latest" stemcells is a bit tricky, because we need to
		# ballance latest known version vs latest available version for
		# the CPI.  We also support getting the latest minor version of a
		# major version, so we need to check for that too.

		# TODO:  Should latest check for latest available upstream, or just local (current behavior)?
		if ($wants_latest) {
			$result->{latest} = 1;
			$result->{search_type} = 'latest';
			my @targets = exists($newest_by_os{$os}) ? ($newest_by_os{$os}->@*) : ();
			my $latest_major_version = @targets ? int($available{$targets[0]}{version}) : 0;
			if (defined($major_version) && $major_version != $latest_major_version) {
				$result->{search_type} = 'latest-minor';
				@targets = (
					grep {$major_version == int($available{$_}{version})}
					@targets
				);
			}
			# There exists one or more stemcells that match the desired latest version
			if (@targets) {
				# Check if the latest version is available for the desired CPI
				my @cpi_targets = grep {
					in_array($cpi, $available{$_}{cpis}->@*)
				} @targets;
				if (@cpi_targets) {
					$result->{found} = $available{$cpi_targets[0]};
				}
				if (!@cpi_targets || $cpi_targets[0] ne $targets[0]) {
					$result->{alt} = Service::BOSH::Stemcell->find(
						$self->iaas, $available{$targets[0]}->@{qw/os version/},
						scalar($self->lookup('bosh-configs.stemcells.type',undef))
					);
					$result->{alt_existing_cpis} = $available{$targets[0]}->{cpis};
				}
			} else {
				# No stemcells available for the desired os
				$result->{alt} = Service::BOSH::Stemcell->find(
					$self->iaas,
					$os,
					$version
				);
				$result->{alt_existing_cpis} = $available{$newest}{cpis};
			}

				# If using a non-default CPI, check if the latest version is available for it

		} else {
			$result->{search_type} = 'exact';
			my $key = "$os\@$version";
			my $match = $available{$key};
			if (in_array($cpi, $match->{cpis}->@*)) {
				$result->{found} = $match;
			} else {
				$result->{alt} = Service::BOSH::Stemcell->find(
					$self->iaas,
					$os,
					$version
				);
				$result->{alt_existing_cpis} = ($available{$key}//{})->{cpis};
			}
		}
		push @results, $result;
	}
	$self->{__stemcell_status} = \@results;
	return wantarray ? @results : \@results;
}

# }}}
# get_network_claims - get the network claims for the environment {{{
sub get_network_claims {
	my ($self) = @_;
	my @network_keys = $self->bosh->vault->keys($self->bosh->exodus_path.'/network');
	my $claims = {};
	my $name = $self->name;
	my $type = $self->type;
	for my $claim (grep {/:subnets\..*\.claims\.$name~$type~/} @network_keys) {
		my ($path, $key, $subnet, $network) = $claim =~ m/^([^:]*):(subnets\.(.*?)\.claims\.(?:.*)~net-([^~]*))$/;
		next unless $subnet && $path && $key && $network; # TODO: This should probably issue a warning at least
		# RISK: Assumes one claim per network/subnet, this may be naive
		$claims->{$network}{$subnet}{ips} = $self->bosh->vault->get($path,$key);
		$claims->{$network}{$subnet}{path} = "$path:$key";
	}
	return $claims;
}

# }}}
# rejoin_deployment - handle rejoining an interrupted deployment {{{
sub rejoin_deployment {
	my ($self, %opts) = @_;
	my $deployment_files = delete($opts{deployment_files});
	my $cache_path = $self->{__deployment_cache_path};
	my $humanized_cache_path = humanize_path($cache_path);

	# Count the files found
	my $file_count = scalar(keys %$deployment_files);
	my $file_list = join("\n", map {
			sprintf("[[  - >>%s", basename($_))
	} sort values %$deployment_files);

	# Log the detection
	$self->notify(
		"warning",
		"detected #y{%s} from a previous incomplete deployment",
		count_nouns($file_count, 'active deployment cache file'),
	);

	info(
		"\nThe following deployment cache files were found in:\n".
		"[[  >>#C{%s}\n".
		"%s\n\n".
		"This indicates that a previous deployment may have been interrupted or is still in progress.  ".
		"Genesis cannot safely continue without risking deployment state corruption; this is particularly ".
		"true when dealing with #Mu{create-env deployments} where the #Yu{state file} may have changed.\n\n".
		"#Wku{Options to resolve this:}\n".
		"[[  1. >>If you are certain the previous deployment is complete and these files are stale:\n".
		"[[     >>#G{rm -rf %s}\n\n".
		"[[  2. >>If the previous deployment failed and you want to retry but not lose the previous ".
		         "deployment data (ie a state.yml file for a create-env deployment):\n".
		"[[     >>#G{mv %s }#Gi{<target-dir>}\n".
		"[[     >>#G{%s deploy --STATE-FILE-PATH=}#Gi{<target-dir>/<state-file-name.yml>}\n\n".
		"[[  3. >>If you are unsure about the deployment state, consult with your platform team ".
		         "or Genesis support before proceeding.\n\n".
		"[[#Y{Note:} >>In the future, Genesis will support rejoining interrupted deployments, ".
		              "but this functionality is not yet implemented.",
		$humanized_cache_path,
		$file_list,
		$humanized_cache_path,
		$humanized_cache_path,
		scalar($self->get_call_path_with_env)
	);

	bail(
		"Cannot continue with active deployment cache files present.\n".
		"Please resolve the deployment state as described above."
	);
}
# }}}

# _cleanup_and_bail - cleanup the deployment cache and bail with a message {{{
sub _cleanup_and_bail {
	my $self = shift;
	$self->deployment_cache_cleanup;
	bail({offset => 1}, @_);
}

# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet foldmethod=marker foldlevel=1 nu
