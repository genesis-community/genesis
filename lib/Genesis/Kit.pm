package Genesis::Kit;
use strict;
use warnings;

use Genesis;
use Genesis::Legacy; # but we'd rather not
use Genesis::Helpers;

sub url {
	my ($class, $name, $version) = @_;

	my $creds = "";
	if ($ENV{GITHUB_USER} && $ENV{GITHUB_AUTH_TOKEN}) {
		$creds = "$ENV{GITHUB_USER}:$ENV{GITHUB_AUTH_TOKEN}";
	}
	my ($code, $msg, $data) = curl("GET", "https://api.github.com/repos/genesis-community/$name-genesis-kit/releases", undef, undef, 0, $creds);
	if ($code == 404) {
		die "Could not find Genesis Kit $name on Github; does https://github.com/genesis-community/$name-genesis-kit/releases exist?\n";
	}
	if ($code != 200) {
		die "Could not find Genesis Kit $name release information; Github returned a ".$msg."\n";
	}

	my $releases;
	eval { $releases = load_json($data); 1 }
		or die "Failed to read releases information from Github: $@\n";

	if (!@$releases) {
		die "No released versions of Genesis Kit $name found at https://github.com/genesis-community/$name-genesis-kit/releases.\n";
	}

	for (map { @{$_->{assets} || []} } @$releases) {
		if (!$version or $version eq 'latest') {
			next unless $_->{name} =~ m/^\Q$name\E-(.*)\.(tar\.gz|tgz)$/;
			$version = $1;
		} else {
			next unless $_->{name} eq "$name-$version.tar.gz"
			         or $_->{name} eq "$name-$version.tgz";
		}
		return ($_->{browser_download_url}, $version);
	}

	die "$name/$version tarball asset not found on Github.  Oops.\n";
}

sub path {
	my ($self, $path) = @_;
	$self->extract;
	die "self->extract did not set self->{root}; this is a bug in Genesis!\n"
		unless $self->{root};

	return $self->{root} unless $path;

	$path =~ s|^/+||;
	return "$self->{root}/$path";
}

sub glob {
	my ($self, $glob, $absolute) = @_;
	$glob =~ s|^/+||;

	$self->extract;
	die "self->extract did not set self->{root}; this is a bug in Genesis!\n"
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

sub has_hook {
	my ($self, $hook) = @_;
	return -f $self->path("hooks/$hook");
}

sub run_hook {
	my ($self, $hook, %opts) = @_;

	die "No '$hook' hook script found\n"
		unless $self->has_hook($hook);

	local %ENV = %ENV;
	$ENV{GENESIS_KIT_NAME}     = $self->name;
	$ENV{GENESIS_KIT_VERSION}  = $self->version;

	die "Unrecognized hook '$hook'\n"
		unless grep { $_ eq $hook } qw/new blueprint secrets info addon
		                               prereq subkit/;

	if (grep { $_ eq $hook } qw/new secrets info addon prereq/) {
		# env is REQUIRED
		die "The 'env' option to run_hook is required for the '$hook' hook.  This is a bug in Genesis.\n"
			unless $opts{env};

		$ENV{GENESIS_ROOT}         = $opts{env}->path;
		$ENV{GENESIS_ENVIRONMENT}  = $opts{env}->name;
		$ENV{GENESIS_VAULT_PREFIX} = $opts{env}->prefix;

	} elsif (grep { $_ eq $hook } qw/blueprint subkit/) {
		# features is REQUIRED
		die "The 'features' option to run_hook is required for the '$hook' hook.  This is a bug in Genesis.\n"
			unless $opts{features};

	} else {
		die "Unrecognized hook '$hook'\n";
	}

	my @args;
	if ($hook eq 'new') {
		@args = (
			$ENV{GENESIS_ROOT},           # deprecate!
			$ENV{GENESIS_ENVIRONMENT},    # deprecate!
			$ENV{GENESIS_VAULT_PREFIX},   # deprecate!
		);

	} elsif ($hook eq 'secrets') {
		@args = ($opts{action});

	} elsif ($hook eq 'blueprint') {
		$ENV{GENESIS_REQUESTED_FEATURES} = join(' ', @{$opts{features}});

	} elsif ($hook eq 'addon') {
		$ENV{GENESIS_ADDON_SCRIPT} = $opts{script};
		@args = @{$opts{args} || []};

	##### LEGACY HOOKS
	} elsif ($hook eq 'subkit') {
		@args = @{ $opts{features} };
	}

	chmod 0755, $self->path("hooks/$hook");
	my ($out, $rc) = run({ interactive => scalar $hook =~ m/^(addon|new|info)$/,
	                       stderr => '&2' },
		'cd "$1"; source .helper; hook=$2; shift 2; ./hooks/$hook "$@"',
		$self->path, $hook, @args);

	if ($hook eq 'new') {
		if ($rc != 0) {
			die "Could not create new env $args[1] (in $args[0]): 'new' hook exited $rc\n";
		}
		if (! -f "$args[0]/$args[1].yml") {
			die "Could not create new env $args[1] (in $args[0]): 'new' hook did not create $args[1].yml\n";
		}
		return 1;
	}

	if ($hook eq 'blueprint') {
		if ($rc != 0) {
			die "Could not determine which YAML files to merge: 'blueprint' hook exited $rc\n";
		}
		$out =~ s/^\s+//;
		my @manifests = split(/\s+/, $out);
		if (!@manifests) {
			die "Could not determine which YAML files to merge: 'blueprint' specified no files\n";
		}
		return @manifests;
	}

	if ($hook eq 'subkit') {
		if ($rc != 0) {
			die "Could not determine which auxiliary subkits (if any) needed to be activated\n";
		}
		$out =~ s/^\s+//;
		return split(/\s+/, $out);
	}

	if ($rc != 0) {
		die "Could not run '$hook' hook successfully\n";
	}
	return 1;
}

sub metadata {
	my ($self) = @_;
	return $self->{__metadata} ||= load_yaml_file($self->path('kit.yml'));
}

sub source_yaml_files {
	my ($self, $features, $absolute) = @_;
	$features ||= [];

	my @files;
	if ($self->has_hook('blueprint')) {
		@files = $self->run_hook('blueprint', features => $features);
		if ($absolute) {
			@files = map { $self->path($_) } @files;
		}

	} else {
		Genesis::Legacy::validate_features($self, @$features);
		@files = $self->glob("base/*.yml", $absolute);
		push @files, map { $self->glob("subkits/$_/*.yml", $absolute) } @$features;
	}

	return @files;
}

1;

=head1 NAME

Genesis::Kit

=head1 DESCRIPTION

This module encapsulates all of the logic for dealing with Genesis Kits in
the abstract.  It does not handle the concrete problems of dealing with
tarballs (Genesis::Kit::Compiled) or dev/ directories (Genesis::Kit::Dev).

=head1 CLASS METHODS

=head2 url($name, $version)

Determines the download URL for this kit, by consulting Github.
Right now, this is limited to just the C<genesis-community> organization.

If you omit C<$version>, or set it to "latest", the most recent released
version on Github will be used.  Otherwise, the URL for the given version
will be used.

An error will be thrown if the version in question does not exist on Github.


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

=head2 has_hook($name)

Returns true if the kit has defined the given hook.

=head2 run_hook($name, %opts)

Executes the named hook and returns something useful to the caller.  It is
an error if the kit does not define the kit; use C<has_hook> to avoid that.

The specific composition of C<%opts>, as well as the return value / side
effects of running a hook are wholly hook-dependent.  Refer to the section
B<GENESIS KIT HOOKS>, later, for more detail.

=head2 source_yaml_files(\@features, $absolute)

Determines, by way of either C<hooks/blueprint>, or the legacy subkit
detection logic, which kit YAML files need to be merged together, and
returns there paths.

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

=head2 secret

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
