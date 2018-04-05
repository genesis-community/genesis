package Genesis::Env;
use strict;
use warnings;

use Genesis::Utils;
use Genesis::Legacy; # but we'd rather not

sub new {
	my ($class, %opts) = @_;

	# validate call
	for (qw(name top)) {
		die "No '$_' specified in call to Genesis::Env->new; this is a bug in Genesis.\n"
			unless $opts{$_};
	}

	# drop the YAML suffix
	$opts{name} =~ m/\.yml$/;
	$opts{file} = "$opts{name}.yml";

	# environment names must be valid.
	eval { $class->validate_name($opts{name}) }
		or die "Bad environment name '$opts{name}': $@\n" if $@;

	# make sure .genesis is good to go
	die "No deployment type specified in .genesis/config!\n"
		unless $opts{top}->type;

	my $self = bless(\%opts, $class);
	$self->{prefix} ||= $self->default_prefix;

	return $self;
}

sub load {
	my $self = new(@_);

	if (!-f $self->{top}->path("$self->{file}")) {
		die "Environment file $self->{file} does not exist.\n";
	}

	# determine our vault prefix
	$self->{prefix} = $self->lookup('params.vault', $self->default_prefix);

	# reconstitute our kit via top
	$self->{kit} = $self->{top}->find_kit(
		$self->lookup('kit.name'),
		$self->lookup('kit.version'))
			or die "Unable to locate kit for $self->{name} environment.\n";

	return $self;
}

sub create {
	my $self = new(@_);

	# validate call
	for (qw(kit)) {
		die "No '$_' specified in call to Genesis::Env->create; this is a bug in Genesis.\n"
			unless $self->{$_};
	}

	# environment must not already exist...
	if (-f $self->{top}->path("$self->{file}")) {
		die "Environment file $self->{file} already exists.\n";
	}

	## initialize the environment
	if ($self->{kit}->has_hook('new')) {
		$self->{kit}->run_hook('new', root  => $self->{top}->path,  # where does the yaml go?
		                              env   => $self->{name},       # what is it called?
		                              vault => $self->{prefix});    # where do the secrets go?

	} else {
		Genesis::Legacy::new_environment($self);
	}

	$self->add_secrets();

	return $self;
}

# public accessors
sub name   { $_[0]->{name};      }
sub file   { $_[0]->{file};      }
sub prefix { $_[0]->{prefix};    }
sub path   { $_[0]->{top}->path; }

sub default_prefix {
	my ($self) = @_;
	my $p = $self->{name};         # start with env name
	$p =~ s|-|/|g;                 # swap hyphens for slashes
	$p .= "/".$self->{top}->type;  # append '/type'
	return $p;
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
	return $self->has_feature('proto')      || \
	       $self->has_feature('bosh-init')  || \
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
	return grep { -f $self->{top}->path($_) }
		$self->potential_environment_files;
}

# NOTE: not sure if this is how we want to do this, but
#       it does seem to be working for all callers.
sub lookup {
	my ($self, $key, $default) = @_;
	return lookup_in_yaml($self->params, $key, $default);
}

sub defines {
	my ($self, $key) = @_;
	my $params = $self->params();

	for (split /\./, $key) {
		return 0 unless exists $params->{$_};
		$params = $params->{$_};
	}
	return 1;
}

sub params {
	my ($self) = @_;
	if (!$self->{__params}) {
		my $out = Genesis::Run::get(
			{ onfailure => "Unable to merge $self->{name} environment files" },
			'spruce merge --skip-eval "$@" | spruce json',
			map { $self->{top}->path($_) } $self->actual_environment_files());
		$self->{__params} = JSON::PP->new->allow_nonref->decode($out);
	}
	return $self->{__params};
}

sub raw_manifest {
	my ($self, %opts) = @_;
	my $cache = $opts{redact} ? '__redacted' : '__unredacted';

	if (!$self->{$cache}) {
		local $ENV{REDACT} = $opts{redact} ? 'yes' : ''; # for spruce
		$self->{$cache} = Genesis::Run::get(
			{ onfailure => "Unable to merge $self->{name} manifest" },
			'spruce', 'merge', $self->mergeable_yaml_files($opts{'cloud-config'}));
	}
	return $self->{$cache};
}

sub write_manifest {
	my ($self, $file, %opts) = @_;
	file($file, mode     =>  0644,
	            contents => $self->raw_manifest(redact         => $opts{redact},
	                                            'cloud-config' => $opts{'cloud-config'}) . "\n");
}

sub mergeable_yaml_files {
	my ($self, $cc) = @_;
	my $tmp    = workdir;
	my $prefix = $self->default_prefix;
	my $type   = $self->{top}->type;

	file("$tmp/init.yml", mode => 0644, contents => <<EOF);
---
meta:
  vault: (( concat "secret/" params.vault || "$prefix" ))
exodus: {}
params:
  name: (( concat params.env "-$type" ))
name: (( grab params.name ))
EOF

	file("$tmp/fin.yml", mode => 0644, contents => <<EOF);
---
exodus:
  kit_name:    (( grab kit.name    || "unknown" ))
  kit_version: (( grab kit.version || "unknown" ))
  vault_base:  (( grab meta.vault ))
EOF

	return (
		"$tmp/init.yml",
		$self->kit_files,
		$cc || (),
		$self->actual_environment_files(),
		"$tmp/fin.yml",
	);
}

sub kit_files {
	my ($self) = @_;
	return $self->{kit}->source_yaml_files($self->features),
}

sub exodus {
	my ($self) = @_;

	my $data = $self->lookup('exodus', {});
	my (@args, %final);

	for my $key (keys %$data) {
		my $val = $data->{$key};

		# convert arrays -> hashes
		if (ref $val eq 'ARRAY') {
			my $h = {};
			for (my $i = 0; $i < @$val; $i++) {
				$h->{$i} = $val->[$i];
			}
			$val = $h;
		}

		# flatten hashes
		if (ref $val eq 'HASH') {
			for my $k (keys %$val) {
				if (ref $val->{$k}) {
					explain "#Y{WARNING:} The kit has specified the genesis.$key.$k\n".
					        "metadata item, but the given value is not a simple scalar.\n".
					        "Ignoring this metadata value.\n";
					next;
				}
				$final{"$key.$k"} = $val->{$k};
			}

		} else {
			$final{$key} = $data->{$key};
		}
	}

	return \%final;
}

sub bosh_target {
	my ($self) = @_;
	return "create-env" if $self->needs_bosh_create_env;

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

	Genesis::Run::interactive_bosh(
		{ onfailure => "Could not find BOSH Director `$bosh` (specified via $source).",
		  env       => { BOSH_ENVIRONMENT => $bosh } },
		'env');

	return $bosh;
}

sub deployment {
	my ($self) = @_;
	if ($self->defines('params.name')) {
		return $self->lookup('params.name');
	}
	return $self->lookup('params.env') . '-' . $self->{top}->type;
}

sub deploy {
	my ($self, %opts) = @_;

	my $ok;
	my $tmp = workdir;
	$self->write_manifest("$tmp/manifest.yml", redact => 0);

	if ($self->needs_bosh_create_env) {
		$ok = Genesis::BOSH->create_env(
			"$tmp/manifest.yml",
			state => $self->path(".genesis/manifests/$self->{name}-state.yml"));

	} else {
		$self->{__cloud_config} = "$tmp/cloud.yml";
		Genesis::BOSH->download_cloud_config($self->bosh_target, $self->{__cloud_config});

		my @bosh_opts;
		push @bosh_opts, "--$_"             for grep { $opts{$_} } qw/fix recreate dry-run/;
		push @bosh_opts, "--no-redact"      if  !$opts{redact};
		push @bosh_opts, "--skip-drain=$_"  for @{$opts{'skip-drain'} || []};
		push @bosh_opts, "--$_=$opts{$_}"   for grep { defined $opts{$_} }
		                                          qw/canaries max-in-flight/;

		$ok = Genesis::BOSH->deploy("$tmp/manifest.yml",
			target     => $self->bosh_target,
			deployment => $self->deployment,
			options    => \@bosh_opts);
	}

	unlink "$tmp/manifest.yml"
		or debug "Could not remove unredacted manifest $tmp/manifest.yml";

	# bail out early if the deployment failed;
	# don't update the cached manifests
	return if !$ok;

	# deployment succeeded; update the cache
	$self->write_manifest($self->{top}->path(".genesis/manifests/$self->{name}.yml"), redact => 1);
	# track exodus data in the vault
	my $exodus = $self->exodus;
	return run(
		{ onfailure => "Could not save $self->{name} metadata to the Vault" },
		'safe', 'set', "secret/genesis/".$self->{top}->type."/$self->{name}",
		               map { "$_=$exodus->{$_}" } keys %$exodus);
}

sub add_secrets { # WIP - majorly broken right now.  sorry bout that.
	my ($self, %opts) = @_;
	my $kit = $self->{kit};

	if ($kit->has_hook('secrets')) {
		$kit->run_hook('secrets', action   => 'add',
		                          recreate => $opts{recreate},
		                          env      => $self->{name},
		                          vault    => $self->{prefix});
	} else {
		my @features = []; # FIXME
		Genesis::Legacy::vaultify_secrets($kit,
			env       => $self->{name},
			prefix    => $self->{prefix},
			scope     => $opts{recreate} ? 'force' : 'add',
			features  => \@features);
	}
}

sub check_secrets {
	my ($self) = @_;
	my $kit = $self->{kit};

	if ($kit->has_hook('secrets')) {
		$kit->run_hook('secrets', action => 'check',
		                          env    => $self->{name},
		                          vault  => $self->{prefix});
	} else {
		my @features = []; # FIXME
		Genesis::Legacy::vaultify_secrets($kit,
			env       => $self->{name},
			prefix    => $self->{prefix},
			features  => \@features);
	}
}

sub rotate_secrets {
	my ($self, %opts) = @_;
	my $kit = $self->{kit};

	if ($kit->has_hook('secrets')) {
		$kit->run_hook('secrets', action => 'rotate',
		                          force  => $opts{force},
		                          env    => $self->{name},
		                          vault  => $self->{prefix});
	} else {
		my @features = []; # FIXME
		Genesis::Legacy::vaultify_secrets($kit,
			env       => $self->{name},
			prefix    => $self->{prefix},
			scope     => $opts{force} ? 'force' : '',
			features  => \@features);
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

=cut
