package Genesis::Env;
use strict;
use warnings;

use Genesis;
use Genesis::Legacy; # but we'd rather not
use Genesis::BOSH;

use POSIX qw/strftime/;

sub new {
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
		or die "Bad environment name '$opts{name}': $@\n" if $@;

	# make sure .genesis is good to go
	die "No deployment type specified in .genesis/config!\n"
		unless $opts{top}->type;

	$opts{__tmp} = workdir;
	my $self = bless(\%opts, $class);
	$self->{prefix} ||= $self->_default_prefix;

	return $self;
}

sub load {
	my $self = new(@_);

	if (!-f $self->path("$self->{file}")) {
		die "Environment file $self->{file} does not exist.\n";
	}

	# determine our vault prefix
	$self->{prefix} = $self->lookup('params.vault', $self->_default_prefix);

	# reconstitute our kit via top
	$self->{kit} = $self->{top}->find_kit(
		$self->lookup('kit.name'),
		$self->lookup('kit.version'))
			or die "Unable to locate kit for '$self->{name}' environment.\n";

	return $self;
}

sub create {
	my $self = new(@_);

	# validate call
	for (qw(kit)) {
		bug("No '$_' specified in call to Genesis::Env->create!!")
			unless $self->{$_};
	}

	# environment must not already exist...
	if (-f $self->path("$self->{file}")) {
		die "Environment file $self->{file} already exists.\n";
	}

	## initialize the environment
	if ($self->has_hook('new')) {
		$self->run_hook('new', root  => $self->path,      # where does the yaml go?
		                       vault => $self->{prefix}); # where do the secrets go?

	} else {
		Genesis::Legacy::new_environment($self);
	}

	# generate all (missing) secrets ignoring any that exist
	# from a previous 'new' attempt.
	$self->add_secrets(recreate => 1);

	return $self;
}

# public accessors
sub name   { $_[0]->{name};   }
sub file   { $_[0]->{file};   }
sub prefix { $_[0]->{prefix}; }
sub kit    { $_[0]->{kit};    }

# delegations
sub type { $_[0]->{top}->type; }

sub path {
	my ($self, @rest) = @_;
	$self->{top}->path(@rest);
}

sub _default_prefix {
	my ($self) = @_;
	my $p = $self->{name};         # start with env name
	$p =~ s|-|/|g;                 # swap hyphens for slashes
	$p .= "/".$self->{top}->type;  # append '/type'
	return $p;
}

sub use_cloud_config {
	my ($self, $path) = @_;
	$self->{ccfile} = $path;
	return $self;
}

sub features {
	my ($self) = @_;
	if ($self->defines('kit.features')) {
		return @{ $self->lookup('kit.features') };
	} else {
		return @{ $self->lookup('kit.subkits', []) };
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

sub _lookup {
	my ($what, $key, $default) = @_;

	for (split /\./, $key) {
		return $default if !exists $what->{$_};
		$what = $what->{$_};
	}
	return $what;
}
sub lookup {
	my ($self, $key, $default) = @_;
	return _lookup($self->params, $key, $default);
}

sub manifest_lookup {
	my ($self, $key, $default) = @_;
	my ($manifest, undef) = $self->_manifest(redact => 0);
	return _lookup($manifest, $key, $default);
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
	my $which = $opts{redact} ? '__redacted' : '__unredacted';
	my $path = "$self->{__tmp}/$which.yml";

	trace("[env $self->{name}] in _manifest(): looking for the '$which' cached manifest");
	if (!$self->{$which}) {
		trace("[env $self->{name}] in _manifest(): cache MISS; generating");
		trace("[env $self->{name}] in _manifest(): cwd is ".Cwd::cwd);
		trace("[env $self->{name}] in _manifest(): merging $_")
			for $self->_yaml_files;
		local $ENV{REDACT} = $opts{redact} ? 'yes' : ''; # for spruce

		pushd $self->path;
		debug("running spruce merge of all files, with evaluation, to generate a manifest");
		my $out = run({ onfailure => "Unable to merge $self->{name} manifest", stderr => 0 },
			'spruce', 'merge', $self->_yaml_files);
		popd;

		debug("saving #W{%s} manifest to $path", $opts{redact} ? 'redacted' : 'unredacted');
		mkfile_or_fail($path, 0400, $out);
		$self->{$which} = load_yaml($out);
	}
	return $self->{$which}, $path;
}

sub manifest {
	my ($self, %opts) = @_;

	# prune by default.
	$opts{prune} = 1 unless defined $opts{prune};

	my (undef, $path) = $self->_manifest(redact => $opts{redact});
	if ($opts{prune}) {
		my @prune = qw/meta pipeline params kit exodus compilation/;

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
		return run({ onfailure => "Failed to merge $self->{name} manifest", stderr => 0 },
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

sub _yaml_files {
	my ($self) = @_;
	my $prefix = $self->_default_prefix;
	my $type   = $self->{top}->type;

	my @cc;
	if (!$self->needs_bosh_create_env) {
		trace("[env $self->{name}] in _yaml_files(): not a create-env, we need cloud-config");
		die "No cloud-config specified for this environment\n"
			unless $self->{ccfile};

		trace("[env $self->{name}] in _yaml_files(): cloud-config at $self->{ccfile}");
		push @cc, $self->{ccfile};
	} else {
		trace("[env $self->{name}] in_yaml_files(): IS a create-env, skipping cloud-config");
	}

	mkfile_or_fail("$self->{__tmp}/init.yml", 0644, <<EOF);
---
meta:
  vault: (( concat "secret/" params.vault || "$prefix" ))
exodus: {}
params:
  name: (( concat params.env "-$type" ))
name: (( grab params.name ))
EOF

	my $now = strftime("%Y-%m-%d %H:%M:%S %z", gmtime());
	mkfile_or_fail("$self->{__tmp}/fin.yml", 0644, <<EOF);
---
exodus:
  version:     $Genesis::VERSION
  dated:       $now
  deployer:    (( grab \$CONCOURSE_USERNAME || \$USER || "unknown" ))
  kit_name:    (( grab kit.name    || "unknown" ))
  kit_version: (( grab kit.version || "unknown" ))
  vault_base:  (( grab meta.vault ))
EOF

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
	return $self->{kit}->source_yaml_files($self, $absolute),
}

sub _flatten {
	my ($final, $key, $val) = @_;

	if (ref $val eq 'ARRAY') {
		for (my $i = 0; $i < @$val; $i++) {
			_flatten($final, $key ? "$key.$i" : "$i", $val->[$i]);
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

sub exodus {
	my ($self) = @_;
	return _flatten({}, undef, $self->manifest_lookup('exodus', {}));
}

sub bosh_target {
	my ($self) = @_;
	return undef if $self->needs_bosh_create_env;

	my ($bosh, $source);
	if ($bosh = $ENV{GENESIS_BOSH_ENVIRONMENT}) {
			$source = "GENESIS_BOSH_ENVIRONMENT environment variable";

	} elsif ($bosh = $self->lookup('params.bosh')) {
			$source = "params.bosh in $self->{name} environment file";

	} elsif ($bosh = $self->lookup('params.env')) {
			$source = "params.env in $self->{name} environment file because no params.bosh was present";

	} else {
		die "Could not find the `params.bosh' or `params.env' key in $self->{name} environment file!\n";
	}

	Genesis::BOSH->ping($bosh)
		or die "Could not find BOSH Director `$bosh` (specified via $source).\n";

	return $bosh;
}

sub deployment {
	my ($self) = @_;
	if ($self->defines('params.name')) {
		return $self->lookup('params.name');
	}
	return $self->lookup('params.env') . '-' . $self->{top}->type;
}

sub has_hook {
	my $self = shift;
	return $self->kit->has_hook(@_);
}

sub run_hook {
	my ($self, $hook, %opts) = @_;
	return $self->kit->run_hook($hook, %opts, env => $self);
}

sub check {
	my ($self) = @_;
	$self->write_manifest("$self->{__tmp}/manifest.yml", redact => 0);

	if ($self->has_hook('check')) {
		return $self->run_hook('check', manifest => "$self->{__tmp}/manifest.yml");
	}
	return 1;
}

sub deploy {
	my ($self, %opts) = @_;

	my $ok;
	$self->write_manifest("$self->{__tmp}/manifest.yml", redact => 0);

	if ($self->needs_bosh_create_env) {
		debug("deploying this environment via `bosh create-env`, locally");
		$ok = Genesis::BOSH->create_env(
			"$self->{__tmp}/manifest.yml",
			state => $self->path(".genesis/manifests/$self->{name}-state.yml"));

	} else {
		$self->{__cloud_config} = "$self->{__tmp}/cloud.yml";
		Genesis::BOSH->download_cloud_config($self->bosh_target, $self->{__cloud_config});

		my @bosh_opts;
		push @bosh_opts, "--$_"             for grep { $opts{$_} } qw/fix recreate dry-run/;
		push @bosh_opts, "--no-redact"      if  !$opts{redact};
		push @bosh_opts, "--skip-drain=$_"  for @{$opts{'skip-drain'} || []};
		push @bosh_opts, "--$_=$opts{$_}"   for grep { defined $opts{$_} }
		                                          qw/canaries max-in-flight/;

		debug("deploying this environment to our BOSH director");
		$ok = Genesis::BOSH->deploy(
			$self->bosh_target,
			manifest   => "$self->{__tmp}/manifest.yml",
			deployment => $self->deployment,
			flags      => \@bosh_opts);
	}

	unlink "$self->{__tmp}/manifest.yml"
		or debug "Could not remove unredacted manifest $self->{__tmp}/manifest.yml";

	# bail out early if the deployment failed;
	# don't update the cached manifests
	return if !$ok;

	# deployment succeeded; update the cache
	$self->write_manifest($self->path(".genesis/manifests/$self->{name}.yml"), redact => 1);

	# track exodus data in the vault
	my $exodus = $self->exodus;
	debug("setting exodus data in the Vault, for use later by other deployments");
	return run(
		{ onfailure => "Could not save $self->{name} metadata to the Vault" },
		'safe', 'set', "secret/genesis/".$self->{top}->type."/$self->{name}",
		               map { "$_=$exodus->{$_}" } keys %$exodus);
}

sub add_secrets { # WIP - majorly broken right now.  sorry bout that.
	my ($self, %opts) = @_;

	if ($self->has_hook('secrets')) {
		$self->run_hook('secrets', action => $opts{recreate} ? 'new' : 'add',
		                           vault  => $self->{prefix});
	} else {
		Genesis::Legacy::vaultify_secrets($self->kit,
			env       => $self,
			prefix    => $self->{prefix},
			scope     => $opts{recreate} ? 'force' : 'add',
			features  => [$self->features]);
	}
}

sub check_secrets {
	my ($self) = @_;

	if ($self->has_hook('secrets')) {
		$self->run_hook('secrets', action => 'check',
		                           vault  => $self->{prefix});
		return 1; # FIXME
	} else {
		my $rc = Genesis::Legacy::check_secrets($self->kit,
			env       => $self,
			prefix    => $self->{prefix},
			features  => [$self->features]);
		return $rc == 0;
	}
}

sub rotate_secrets {
	my ($self, %opts) = @_;

	if ($self->has_hook('secrets')) {
		$self->run_hook('secrets', action => 'rotate',
		                           vault  => $self->{prefix});
	} else {
		Genesis::Legacy::vaultify_secrets($self->kit,
			env       => $self,
			prefix    => $self->{prefix},
			scope     => $opts{force} ? 'force' : '',
			features  => [$self->features]);
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
       kit  => $top->find_kit('some-kit', 'latest'),
    );

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

=item B<prefix>

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


=head2 prefix()

Retrieve the Vault prefix that this environment should store its secrets
under, based off of either its name (by default) or its C<params.vault>
parameter.

=head2 kit()

Retrieve the Genesis::Kit object for this environment.

=head2 path([$relative])

Returns the absolute path to the root directory, with C<$relative> appended
if it is passed.

=head2 use_cloud_config($file)

Use the given BOSH cloud-config (as defined in C<$file>) when merging this
environments manifest.  This must be called before calls to C<manifest()>,
C<write_manifest()>, or C<manifest_lookup()>.


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
or C<$default> if the key hasn't been defined.

    my $v = $env->lookup('kit.version', 'latest');
    print "using version $v...\n";

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
