package Genesis::Kit;
use strict;
use warnings;

use base 'Genesis::Base'; # for _memoize

use Genesis;
use Genesis::State;
use Genesis::Helpers;

### Class Methods {{{

# new - abstract class only, expects derived class to specify new body {{{
sub new {
	my ($class,$provider) = @_;
	bug "Attempt to initialize abstract class Genesis::Kit"
		if ($class == __PACKAGE__);
}
# }}}
# }}}

### Instance Methods {{{

# path - {{{
sub path {
	my ($self, $path) = @_;
	$self->extract;
	bug("self->extract did not set self->{root}!!")
		unless $self->{root};

	return $self->{root} unless $path;

	$path =~ s|^/+||;
	return "$self->{root}/$path";
}

# }}}
# glob - {{{
sub glob {
	my ($self, $glob, $absolute) = @_;
	$glob =~ s|^/+||;

	$self->extract;
	bug("self->extract did not set self->{root}!!")
		unless $self->{root};

	if ($absolute) {
		return glob "$self->{root}/$glob";
	}

	# do a relative glob by popping into the root
	# and processing the glob from there.
	#
	pushd $self->{root};
	my @l = glob $glob;
	popd;
	return @l;
}

# }}}
# has_hook - {{{
sub has_hook {
	my ($self, $hook) = @_;
	return $self->{__hook_check}{$hook} if exists($self->{__hook_check}{$hook});
	trace("checking the kit for a(n) '$hook' hook");
	$self->{__hook_check}{$hook} = -f $self->path("hooks/$hook") || (
		 !envset('GENESIS_NO_MODULE_HOOKS') && -f $self->path("hooks/${hook}.pm"
	));
}

# }}}
# run_hook - {{{
sub run_hook {
	my ($self, $hook, %opts) = @_;

	my $is_shell=($hook eq 'shell');
	my $is_edit=($hook eq 'edit');
	if ($is_shell) {
		$hook=$opts{hook}||'shell';
	} elsif ($is_edit) {
		$opts{editor} ||= $ENV{EDITOR}||'vim';
	} elsif (! $self->has_hook($hook)) {
		bail("No '$hook' hook script found")
	}

	trace ("preparing to run the '$hook' kit hook");
	local %ENV = %ENV;

	$ENV{GENESIS_KIT_ID}      = $self->id;
	$ENV{GENESIS_KIT_NAME}    = $self->name;
	$ENV{GENESIS_KIT_VERSION} = $self->version;
	$ENV{GENESIS_KIT_PATH}    = $self->path;
	$ENV{GENESIS_KIT_HOOK}    = $hook;

	# TODO: Remove secrets hooks

	bug("Unrecognized hook '$hook'\n") unless grep {
		$_ eq $hook
	} qw/new blueprint secrets info addon check prereqs pre-deploy post-deploy features shell edit/;

	if ($opts{env}) {
		my %env_vars = $opts{env}->get_environment_variables($hook);
		$ENV{$_} = $env_vars{$_} for (keys %env_vars);
		trace ('got env info');
		if ($opts{extra_vars}) {
			trace ('got extra env info');
			for (keys %{$opts{extra_vars}}) {
				trace(
					"Overwriting env var #M{%s} with #C{%s} (was #C{%s})",
					$_, $opts{extra_vars}{$_}, $ENV{$_}
				) if exists($ENV{$_});
				$ENV{$_} = $opts{extra_vars}{$_}
			}
		}
	} else {
		bug("The 'env' option to run_hook is required for the '$hook' hook!!")
			if (grep { $_ eq $hook } qw/new secrets info addon check blueprint pre-deploy post-deploy features/);
	}

	my (@args, %module_options);
	if ($hook eq 'new') {
		$ENV{GENESIS_MIN_VERSION} = (reverse sort by_semver(
			$ENV{GENESIS_MIN_VERSION}||'0.0.0', $self->genesis_version_min
		))[0];

		@args = (
			$ENV{GENESIS_ROOT},           # deprecated in 2.6.13!
			$ENV{GENESIS_ENVIRONMENT},    # deprecated in 2.6.13!
			$ENV{GENESIS_VAULT_PREFIX},   # deprecated in 2.6.13!
		) unless $self->feature_compatibility('2.6.13');

	} elsif ($hook eq 'secrets') {
		$ENV{GENESIS_SECRET_ACTION} = $opts{action};
		$ENV{GENESIS_SECRETS_DATAFILE} = $opts{env}->workpath("secrets");

	} elsif ($hook eq 'addon') {
		$ENV{GENESIS_ADDON_SCRIPT} = $opts{script};
		@args = @{$opts{args} || []};
		%module_options = (
			script => $opts{script},
			args => \@args,
		);
	} elsif ($hook eq 'check') {
		# Nothing special needed

	} elsif ($hook eq 'pre-deploy') {
		$ENV{GENESIS_PREDEPLOY_DATAFILE} = $opts{env}->workpath("data");
		$ENV{GENESIS_MANIFEST_FILE} = $opts{manifest};
		$ENV{GENESIS_BOSHVARS_FILE} = $opts{vars_file};

	} elsif ($hook eq 'post-deploy') {
		$ENV{GENESIS_DEPLOY_RC} = defined $opts{rc} ? $opts{rc} : 255;
		my $fn = $opts{env}->workpath("data");
		mkfile_or_fail($fn, $opts{data}) if ($opts{data});
		$ENV{GENESIS_PREDEPLOY_DATAFILE} = $fn;

	} elsif ($hook eq 'features') {
		bug("The 'features' option to run_hook is required for the '$hook' hook!!")
			unless $opts{features};
		$ENV{GENESIS_REQUESTED_FEATURES} = join(" ", @{ $opts{features} });
	}

	my ($hook_name,$hook_file,$hook_module) = ($hook,undef,undef);
	if ($is_shell) {
		@args = ();
		$hook_file =
		$hook_name = $opts{shell} || '/bin/bash';

	} elsif ($is_edit) {
		@args = ();
		$hook_file = $opts{env}->workpath("edit-env");
		mkfile_or_fail($hook_file, <<EOF);
#/bin/bash
set -ue
offer_environment_editor true
exit 0
EOF
		chmod 0755, $hook_file;
		$ENV{EDITOR}=$opts{editor};

	} else {
		if ($hook eq 'addon') {
			# Check if its a perl module
			($hook_file) =
				grep {/(\/addon-$opts{script}(~.*)?|~$opts{script})\.pm$/}
				glob($self->path('hooks/addon*'));
			if (
				($hook_file//'') =~ m/\/addon-([^~]*)(?:~(.*))?\.pm$/
				&& ! envset('GENESIS_NO_MODULE_HOOKS')
			) {
				$hook_name = "hook/addon ".($2 ? "'$1/$2'" : "'$1'");
				my $addon_label = $2 ? "$1/$2" : $1;
				info(
					"[1ARunning #G{%s} addon for #C{%s} #M{%s} deployment",
					$addon_label, $opts{env}->name, $self->id
				);
			} else {
				$hook_file = $self->path("hooks/addon.sh");
				$hook_name = "hook/addon '$opts{script}'";
			}
		} else {
			$hook_file = $self->path("hooks/${hook}.pm");
			$hook_name = "hook/$hook";
		}

		if (-f $hook_file && !envset('GENESIS_NO_MODULE_HOOKS')) {
			open my $fh, '<', $hook_file;
			my $line = <$fh>;
			$line = <$fh> while ($line =~/^\s*(#.*)?$/);
			close $fh;

			if ($line =~ /^package (Genesis::Hook::[^ ]*)/) {
				$hook_module = $1;
			}
		}

		unless ($hook_module) {
			$hook_file = $self->path("hooks/$hook");
			if (envset('GENESIS_TRACE')) {
				open my $file, '<', $hook_file;
				my $firstLine = <$file>;
				close $file;
				if ($firstLine =~ /(^#!\s*\/bin\/bash(?:$| .*$))/) {
					run('(echo "$1"; echo "set -x"; cat "$2") > "$3"', $1, $hook_file, "$hook_file-trace");
					$hook_file .= '-trace';
					$hook_name .= '-trace';
				}
			}
			chmod 0755, $hook_file;
		}
	}

	debug ("Running hook now in ".$self->path);
	if ($hook_module) {
		eval {require $hook_file};
		$module_options{file} = $opts{$hook_file};
		$module_options{label} = $hook_name =~ s/^hook\/addon '([^'])'.*/$1/r =~ s{/}{|}r;
		bail(
			"Could not load Perl module %s to run hook %s in kit %s: %s",
			$hook_file, $hook_name, $self->id, $@
		) if $@;

		my $hook_obj = $hook_module->init(env => $opts{env}, kit => $self, %module_options);
		# TODO: wrap in an eval, give better error messages

		my $ok = $hook =~ /^addon/ && scalar(grep {$_ =~ /^(?:-h|--help)$/} @args)
			? $hook_obj->help()
			: $hook_obj->perform();
		bail(
			"Could not run '%s' hook successfully!",
			$hook
		) unless $ok;
		return $hook_obj->results();
	}

	$ENV{GENESIS_IS_HELPING_YOU} = 'yes';
	my $interactive = ($is_shell || $is_edit || scalar($hook =~ m/^(addon|new|info|check|secrets|post-deploy|pre-deploy)$/)) ? 1 : 0;
	my ($out, $rc, $err) = run({
			interactive => $interactive, stderr => undef, eval_var_args => $opts{eval_var_args}
		},
		'cd "$1"; source .helper; hook=$2; shift 2; $hook "$@"',
		$self->path, $hook_file, @args
	);

	exit $rc if $is_shell;

	if ($hook eq 'new') {
		bail(
			"Could not create new env #C{%s} (in %s): 'new' hook exited %d",
			$ENV{GENESIS_ENVIRONMENT}, humanize_path($ENV{GENESIS_ROOT}), $rc,
		)	unless ($rc == 0);

		bail(
			"Could not create new env #C{%s} (in %s): 'new' hook did not create #M{%1\$s}",
			$ENV{GENESIS_ENVIRONMENT}, humanize_path($ENV{GENESIS_ROOT})
		)	unless -f sprintf("%s/%s.yml", $ENV{GENESIS_ROOT}, $ENV{GENESIS_ENVIRONMENT});

		return 1;
	}

	if ($hook eq 'blueprint') {
		bail(
			"Could not determine which YAML files to merge: 'blueprint' hook exited with %d:".
			"\n\n#u{stdout:}\n%s\n\n",
			$rc, $out||"#i{No stdout provided}"
		) if ($rc != 0);

		$out =~ s/^\s+//;
		my @manifests = split(/\s+/, $out);
		bail(
			"Could not determine which YAML files to merge: 'blueprint' specified no files"
		) unless @manifests;
		return @manifests;
	}

	if (grep { $_ eq $hook}  qw/features/) {
		bail(
			"Could not run feature hook in kit %s:".
			"\n\n#u{stdout:}\n%s\n\n",
			$self->id, $out||"#i{No stdout provided}"
		) unless $rc == 0;
		$out =~ s/^\s+//;
		return split(/\s+/, $out);
	}

	if ($hook eq 'pre-deploy') {
		bail(
			"Cannot continue with deployment: 'pre-deploy' hook for #C{%s} environment exited %d.",
			$ENV{GENESIS_ENVIRONMENT}, $rc,
		) unless ($rc == 0);
		my $contents;
		my $fn = $opts{env}->workpath("data");
		if ( -f $fn ) {
			$contents = slurp($fn) if -s $fn;
			unlink $fn;
		}
		return (($rc == 0 ? 1 : 0), $contents);
	}

	if ($hook eq 'post-deploy') {
		unlink $opts{env}->workpath("data")
			if -f $opts{env}->workpath("data");
	}

	return ($rc == 0 ? 1 : 0) if (
		$hook eq 'addon' ||
		$hook eq 'check' ||
		($hook eq 'secrets' && $opts{action} eq 'check')
	);

	if ($rc != 0) {
		if (defined($out)) {
			bail(
				"Could not run '%s' hook successfully - exited with %d:".
				"\n\n#u{stdout:}\n%s\n\n",
				$hook, $rc, $out||"#i{No stdout provided}"
			);
		} else {
			bail("Could not run '%s' hook successfully - exited with %d", $hook, $rc);
		}
	}
	return 1;
}

# }}}
# metadata - {{{
sub metadata {
	my ($self,@keys) = @_;
	if (! $self->{__metadata}) {
		if (! -f $self->path('kit.yml')) {
			warning({level => 'debug'},
				"Kit %s is missing it's kit.yml file -- cannot load metadata",
				$self->name
			);
			return {}
		}
		my @kit_files = ($self->path('kit.yml'));
		if ($ENV{PREVIOUS_ENV} && -f ".genesis/cached/$ENV{PREVIOUS_ENV}/kit-overrides.yml") {
			push @kit_files, ".genesis/cached/$ENV{PREVIOUS_ENV}/kit-overrides.yml";
		} elsif ( -f "./kit-overrides.yml" ) {
			push @kit_files, "./kit-overrides.yml";
		}
		if ($self->{__overrides} && ref($self->{__overrides}) eq 'ARRAY') {
			push @kit_files, @{$self->{__overrides}};
		}
		$self->{__metadata} = read_json_from(run(
				{onfailure => "#R{[ERROR] Could not read kit metadata"},
				'spruce merge --go-patch --multi-doc "$@" | spruce json',
				@kit_files
		));
	}
	return $self->{__metadata} unless @keys;
	return $self->{__metadata}->{$keys[0]} if @keys == 1;
	return get_opts($self->{__metadata}, @keys);
}

# }}}
# apply_env_overrides - apply environment-specific override files to the kit {{{
sub apply_env_overrides {
	my ($self, @overrides) = @_;
	$self->{__overrides} = [@overrides];
	# Clear the loaded metadata
	$self->{__metadata} = undef;
}

# }}}
# env_override_files - return the list of environment kit overrides {{{
sub env_override_files {
	return @{$_[0]->{__overrides} || []};
}

# }}}
# secrets_store - what secrets_store does this kit use ('vault','credhub') {{{
sub secrets_store {
	my ($self) = @_;
	$self->metadata->{secrets_store} ? $self->metadata->{secrets_store} : 'vault';
}

# }}}
# uses_credhub - does this kit use credhub instead of vault {{{
sub uses_credhub { return $_[0]->secrets_store eq "credhub"; }

# }}}
# required_configs - what configs does this kit require from BOSH? {{{
sub required_configs {
	my ($self,@hooks) = @_;
	my $required_configs = $self->metadata->{required_configs};
	unless ($required_configs) {
		return ('cloud') if (grep {$_ eq 'manifest'} @hooks); # Erroneous, should be blueprint - need to fix in callers
		return ('cloud') if (grep {$_ eq 'blueprint'} @hooks);
		return ('cloud') if (grep {$_ eq 'check'} @hooks) && !$ENV{GENESIS_CONFIG_NO_CHECK};
		return ();
	}
	return @{$required_configs} if ref($required_configs) eq 'ARRAY';

	my @configs;
	for my $config (keys %{$required_configs}) {
		if (ref($required_configs->{$config}) eq 'ARRAY') {
			my $needed;
			if (@hooks) {
				for my $hook (@{$required_configs->{$config}}) {
					$needed = scalar(grep {$_ eq $hook} @hooks);
					last if $needed;
				}
			} else {
				$needed = 1;
			};
			push(@configs, $config) if $needed;
		} else {
			push(@configs, $config) if $required_configs->{$config};
		}
	}
	return @configs;
}

# }}}
# required_connectivity - what connectivity does this kit require to do its job? {{{
sub required_connectivity {
	my ($self,@hooks) = @_;
	my $required_conns = $self->metadata->{required_connectivity};
	return () unless ($required_conns);
	return @{$required_conns} if ref($required_conns) eq 'ARRAY';

	my @conns;
	for my $conn (keys %{$required_conns}) {
		if (ref($required_conns->{$conn}) eq 'ARRAY') {
			my $needed;
			if (@hooks) {
				for my $hook (@{$required_conns->{$conn}}) {
					$needed = scalar(grep {$_ eq $hook} @hooks);
					last if $needed;
				}
			} else {
				$needed = 1;
			};
			push(@conns, $conn) if $needed;
		} else {
			push(@conns, $conn) if $required_conns->{$conn};
		}
	}
	return @conns;
}

# }}}
# feature_compatibility - {{{
sub feature_compatibility {
	# Assume feature compatibility with specified min genesis version.
	my ($self,$version) = @_;
	my $id = $self->id;
	my $kit_min = $self->genesis_version_min();

	bug("Invalid base version provided to Genesis::Kit::feature_compatibility") unless semver($version);
	trace("Comparing %s kit min to %s feature base", $kit_min, $version);
	return new_enough($kit_min,$version);
}

# }}}
# genesis_version_min -- minimum version of genesis required to be used for this kit {{{
sub genesis_version_min {
	return $_[0]->_memoize('__genesis_version_min',sub{
		my ($self) = @_;
		my $kit_min = $self->metadata->{genesis_version_min};
		dump_var kit_min_version => $kit_min || "undefined";
		dump_var kit_metadata =>$self->metadata;
		$kit_min = '0.0.0' unless ($kit_min && semver($kit_min));
		return $kit_min;
	})
}

# }}}
# check_prereqs - check that the {{{
sub check_prereqs {
	my ($self,$env) = @_;
	my $id = $self->id;

	my $ok = 1;
	my $min = $self->metadata->{genesis_version_min};
	if ($min && semver($min)) {
		if (!semver($Genesis::VERSION)) {
			warning(
				"#Y{Using a development version of Genesis.}\n".
				"\n".
				"Cannot determine if it meets or exceeds the minimum version ".
				"requirement (v$min) for $id."
			)	unless (under_test && !envset 'GENESIS_TESTING_DEV_VERSION_DETECTION');
		} elsif (!new_enough($Genesis::VERSION, $min)) {
			error(
				"$id requires Genesis version $min, but this Genesis is version ".
				"$Genesis::VERSION.\n".
				"\n".
				"Please upgrade Genesis.  Don't forget to run \`genesis embed\` ".
				"afterward, to update the version embedded in your deployment ".
				"repository."
			);
			$ok = 0
		}
	}

	if ($self->has_hook('prereqs')) {
		my ($out,$rc) = run_hook('prereqs',env => $env);
		if ($rc > 0) {
			error("Prerequisite check for kit #C{$id} failed with exit code $rc");
			$ok = 0;
		}
	}

	return $ok;
}

# }}}
# source_yaml_files - list the yaml files that will be merged in order for manifest {{{
sub source_yaml_files {
	my ($self, $env, $absolute) = @_;

	bail(
		"Kit %s is not supported by Genesis %s (no hooks/blueprint script).  ".
		"Check for newer version of this kit.",
		$self->id, $Genesis::VERSION
	) unless ($self->has_hook('blueprint'));

	my @files = $self->run_hook('blueprint', env => $env);
	if ($absolute) {
		my $env_path = $env->path();
		@files = map { $_ =~ qr(^$env_path) ? $_ : $self->path($_) } @files;
	}
	return @files;
}
# }}}
# dereferenced_metadata - fill in kit metadata with source parameters {{{
sub dereferenced_metadata {
	my ($self, $lookup, $fatal) = @_;
	unless (defined($self->{__deref_metadata})) {
		$self->{__deref_cache} = {};
		$self->{__deref_metadata} = $self->_deref_metadata($self->metadata,$lookup);
	}
	if ($fatal && scalar @{$self->{__deref_miss}||[]}) {
		bail "Could not dereference the following values specified in the metadata:\n  - ".
		     join("\n  - ", @{$self->{__deref_miss}});
	}
	$self->{__deref_metadata};
}

# }}}
# }}}

### Private Methods {{{

# _deref_metadata - recursively dereference metadata structure {{{
sub _deref_metadata {
	my ($self,$metadata, $lookup) = @_;
	if (ref $metadata eq 'ARRAY') {
		# Have to strip out maybe's
		my @results;
		for (@$metadata) {
			eval {push @results, $self->_deref_metadata($_,$lookup)};
			die $@ if ($@ && $@ ne "metadata not found\n");
		}
		return [@results];
	} elsif (ref $metadata eq 'HASH') {
		my %h = ();
		for (keys %$metadata) {
			eval {$h{$_} = $self->_deref_metadata($metadata->{$_},$lookup)};
			die $@ if ($@ && $@ ne "metadata not found\n");
		}
		return \%h;
	} elsif (ref(\$metadata) eq 'SCALAR' && defined($metadata)) {
		$metadata =~ s/\$\{(.*?)(?:\|\|(.*?))?\}/$self->_dereference_param($lookup, $1, $2)/ge;
		return $metadata;
	} else {
		return $metadata;
	}
}

# }}}
# _dereference_param - derefernce a referenced parameter {{{
sub _dereference_param {
	my ($self,$lookup,$key,$default) = @_;
	trace "Dereferencing kit param: %s [default: %s]", $key, defined($default) ? $default : 'null';
	if (defined(($self->{__deref_cache}||{})->{$key})) {
		trace "Genesis::Kit->_dereference_param: cache hit '%s'=>'%s'", $key, $self->{__deref_cache}{$key};
		return $self->{__deref_cache}{$key};
	}
	if ($key =~ m/^maybe:/) {
		$key =~ s/^maybe://;
		$default = bless({},"missing_value");
	}
	my $val = $lookup->($key, $default);
	die "metadata not found\n" if (ref($val) eq "missing_value");
	while (defined($val) && $val =~ /\(\( grab \s*(\S*?)(?:\s*\|\|\s*(.*?))?\s*\)\)/) {
		$key = $1;
		my $remainder = $2;
		if ($remainder && $remainder =~ /^"([^"]*)"$/) {
			$default = $1;
			$remainder = "";
		} else {
			$default = undef;
		}
		trace "Dereferencing kit param [intermediary]: %s [default: %s]", $key, defined($default) ? $default : 'null';
		$val = $lookup->($key, $default);
		$val = "(( grab $remainder ))" if $remainder && !$val;
	}
	if (!defined($val)) {
		push @{($self->{__deref_miss}||=[])}, $key;
		return "\${$key}"
	}
	trace "Dereference: got %s", $val;
	($self->{__deref_cache}||={})->{$key} = $val;
	return $val; # TODO: maybe change unquoted ~ to undef, and remove quotes from default
}

# }}}
# }}}

1;

=head1 NAME

Genesis::Kit

=head1 DESCRIPTION

This module encapsulates all of the logic for dealing with Genesis Kits in
the abstract.  It does not handle the concrete problems of dealing with
tarballs (Genesis::Kit::Compiled) or dev/ directories (Genesis::Kit::Dev).

=head1 CLASS METHODS

=head2 new()

This is an abstract method, placeholder for derived classes to provide their
own constructors.

=head1 INSTANCE METHODS

=head2 path([$relative])

Returns a fully-qualified, absolute path to a file inside the kit workspace.
If C<$relative> is omitted, the workspace root is returned.

=head2 glob($pattern)

Returns the absolute paths to all files inside the kit workspace that match
the given C<$pattern> file glob.

=head2 metadata()

Returns the parsed metadata from this kit's C<kit.yml> file.  This call is
moemoized, so it only actually touches the disk once.

=head2 check_prereqs()

Checks the prerequisites of the kit, notably the C<genesis_version_min>
assertion, against the executing environment.

=head2 has_hook($name)

Returns true if the kit has defined the given hook.

=head2 run_hook($name, %opts)

Executes the named hook and returns something useful to the caller.  It is
an error if the kit does not define the kit; use C<has_hook> to avoid that.

The specific composition of C<%opts>, as well as the return value / side
effects of running a hook are wholly hook-dependent.  Refer to the section
B<GENESIS KIT HOOKS>, later, for more detail.

=head2 source_yaml_files(\@features, $absolute)

Determines, by way of either C<hooks/blueprint> which kit YAML files need to be
merged together, and returns there paths.

If you pass C<$absolute> as a true value, the paths returned by this
function will be absolutely qualified to the Kit's Top object root.  This is
necessary for merging from a different directory (i.e. the deployment root,
when blueprint is going to return paths relative to the kit working space).

If C<\@features> is omitted, it defaults to the empty arrayref, C<[]>.

=head1 GENESIS KIT HOOKS

Genesis defines the following hooks:

=head2 new

Provisions a new environment, by interrogating the environment or asking the
operator for information.

=head2 blueprint

Maps feature flags in an environment onto manifest fragment YAML files in
the kit, prescribing order and augmenting feature selection with additional
logic as needed.

=head2 secrets

Manages automatic generation of non-Credhub secrets that are stored in the
shared Genesis Vault.  This hook is repoonsible for determining if secrets
are missing (i.e. after an upgrade), adding them if they are, and rotating
what is safe to rotate.

=head2 info

Prints out a kit-specific summary of a single environment.  This could
include IP addresses, certificates, passwords, and URLs.

=head2 addon

Executes arbitrary actions.  This allows kit authors to enrich the Genesis
expierience in highly kit-specific ways by giving operators new commands to
run.  For example, the BOSH kit defines a C<login> addon that sets up a BOSH
CLI alias and authenticates to the BOSH director, transparently pulling
secrets from the Vault.

=cut

# vim: fdm=marker:foldlevel=1:noet
