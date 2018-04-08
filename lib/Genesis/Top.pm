package Genesis::Top;
use strict;
use warnings;

use Genesis;
use Genesis::Env;
use Genesis::Kit::Compiled;
use Genesis::Kit::Dev;

use Cwd ();

sub new {
	my ($class, $root) = @_;
	bless({ root => Cwd::abs_path($root) }, $class);
}

sub create {
	my ($class, $path, $name, %opts) = @_;

	$name =~ s/-deployments//;
	$name =~ m/^[a-z][a-z0-9_-]+$/
		or die "Invalid Genesis repo name '$name'\n";
	debug("generating a new Genesis repo, named $name");

	my $dir = $opts{directory} || "${name}-deployments";
	$path .= "/$dir";
	die "Cowardly refusing to create new deployments repository `$dir': one already exists.\n"
		if -e $path;

	my $self = $class->new($path);
	$self->mkdir(".genesis");

	$self->mkfile(".genesis/config", # {{{
<<EOF);
---
genesis: $Genesis::VERSION
deployment_type: $name
EOF

# }}}
	$self->mkfile("README.md", # {{{
<<EOF);
$name deployments
==============================

This repository contains the YAML templates that make up a series of
$name BOSH deployments, using the format prescribed by the
[Genesis][1] utility. These deployments are based off of the
[$name-genesis-kit][2].

Environment Naming
------------------

Each environment managed by this repository will have its own
deployment file, e.g. `us-east-prod.yml`. However, in many cases,
it can be desirable to share param configurations, or kit configurations
across all of the environments, or specific subsets. Genesis supports
this by splitting environment names based on hypthens (`-`), and finding
files with common prefixes to include in the final manifest.

For example, let's look at a scenario where there are three environments
deployed by genesis: `us-west-prod.yml`, `us-east-prod.yml`, and `us-east-dev.yml`.
If there were configurations that should be shared by all environments,
they should go in `us.yml`. Configurations shared by `us-east-dev` and `us-east-prod`
would go in `us-east.yml`.

To see what files are currently in play for an environment, you can run
`genesis <environment-name>`

Quickstart
----------

To create a new environment (called us-east-prod-$name):

    genesis new us-east-prod

To build the full BOSH manifest for an environment:

    genesis manifest us-east-prod

... and then deploy it:

    genesis deploy us-east-prod

To rotate credentials for an environment:

    genesis secrets us-east-prod
    genesis deploy us-east-prod

To update the Concourse Pipeline for this repo:

    genesis repipe

To download a new version of the kit, and deploy it:

    genesis download $name [version] # omitting version downloads the latest

    # update the environment yaml to use the desired kit version,
    # this might be in a different file if using CI to propagate
    # deployment upgrades (perhaps us.yml)
    vi us-east-prod.yml

    genesis deploy us-east-prod.yml     # or commit + git push to have
                                        # CI run through the upgrades

See the [Deployment Pipeline Documentation][3] for more
information on getting set up with Concourse deployment pipelines.

Helpful Links
-------------

- [$name-genesis-kit][2] - Details on the kit used in this repo,
  its features, prerequesites, and params.

- [Deployment Pipeline Documentation][3] - Docs on all the
  configuration options for `ci.yml`, and how the automated
  deployment pipelines behave.

[1]: https://github.com/starkandwayne/genesis
[2]: https://github.com/genesis-community/$name-genesis-kit
[3]: https://github.com/starkandwayne/genesis/blob/master/docs/PIPELINES.md

Repo Structure
--------------

Most of the meat of the deployment repo happens at the base level.
Envirionment YAML files, shared YAML files, and the CI
configuration YAML file will all be here.

The `.genesis/manifests` directory saves redacted copies of the
deployment manifests as they are deployed, for posterity, and to
keep track of any `my-env-name-state.yml` files from `bosh create-env`.

The `.genesis/cached` directory is used by CI to propagate changes
for shared YAML files along the pipelines. To aid in CI deploys, the
`genesis/bin` directory contains an embedded copy of genesis.

`.genesis/kits` contains copies of the kits that have been used in
this deployment. Once a kit is no longer used in any environment,
it can be safely removed.

`.genesis/config` is used internally by `genesis` to understand
what is being deployed, and how.
EOF

# }}}

	return $self;
}

sub link_dev_kit {
	my ($self, $path) = @_;
	my $abs = Cwd::abs_path($path)
		or die "Unable to locate $path from ".Cwd::getcwd."\n";

	my $dev = $self->path('dev');
	unlink($dev) if -l $dev; # overwrite the link
	die "dev/ already exists, and is not a symbolic link\n"
		if -e $dev;

	symlink_or_fail($abs, $dev);
	return $self;
}

sub embed {
	my ($self, $bin) = @_;

	$self->mkdir(".genesis/bin");
	copy_or_fail($bin, $self->path(".genesis/bin/genesis"));
	chmod_or_fail(0755, $self->path(".genesis/bin/genesis"));
	return 1;
}

sub download_kit {
	my ($self, $spec) = @_;

	my ($name, $version) = $spec =~ m{(.*)/(.*)} ? ($1, $2)
	                                             : ($spec, 'latest');

	if ($version eq 'latest') {
		explain("Downloading Genesis kit #M{$name} (#Y{latest} version)");
	} else {
		explain("Downloading Genesis kit #M{$name}, version #C{$version}");
	}

	(my $url, $version) = Genesis::Kit->url($name, $version);

	mkdir_or_fail($self->path(".genesis"));
	mkdir_or_fail($self->path(".genesis/kits"));
	my ($code, $msg, $data) = curl("GET", $url);
	if ($code != 200) {
		die "Failed to download $name/$version from $url: Github returned an HTTP ".$msg."\n";
	}
	mkfile_or_fail($self->path(".genesis/kits/$name-$version.tar.gz"), 0400, $data);
	debug("downloaded kit #M{$name}/#C{$version}");

	return $self;
}

sub path {
	my ($self, $relative) = @_;
	return $relative ? "$self->{root}/$relative"
	                 :  $self->{root};
}

sub mkfile {
	my ($self, $file, @rest) = @_;
	mkfile_or_fail($self->path($file), @rest);
}

sub mkdir {
	my ($self, $dir, @rest) = @_;
	mkdir_or_fail($self->path($dir), @rest);
}

sub config {
	my ($self) = @_;
	return $self->{__config} ||= load_yaml_file($self->path(".genesis/config"));
}

sub type {
	my ($self) = @_;
	return $self->config->{deployment_type};
}

sub has_dev_kit {
	my ($self) = @_;
	return -d $self->path("dev");
}

sub load_env {
	my ($self, $name) = @_;
	return Genesis::Env->load(
		top  => $self,
		name => $name,
	);
}

sub create_env {
	my ($self, $name, $kit, %opts) = @_;
	return Genesis::Env->create(
		%opts,
		top  => $self,
		name => $name,
		kit  => $kit,
	);
}

sub compiled_kits {
	my ($self) = @_;

	my %kits;
	for (glob("$self->{root}/.genesis/kits/*")) {
		next unless m{/([^/]*)-(\d+(\.\d+(\.\d+([.-]rc[.-]?\d+)?)?)?).t(ar.)?gz$};
		$kits{$1}{$2} = $_;
	}

	return \%kits;
}

sub _semver {
	my ($v) = @_;
	if ($v =~  m/^(\d+)(?:\.(\d+)(?:\.(\d+)(?:[.-]rc[.-]?(\d+))?)?)?$/) {
		return  $1       * 1000000000
		     + ($2 || 0) * 1000000
		     + ($3 || 0) * 1000
		     + ($4 || 0) * 1;
	}
	return 0;
}

sub find_kit {
	my ($self, $name, $version) = @_;

	# find_kit('dev')
	if ($name and $name eq 'dev') {
		return $self->has_dev_kit ? Genesis::Kit::Dev->new($self->path("dev"))
		                          : undef;
	}

	# find_kit() with a dev/ directory
	if (!$name and !$version and $self->has_dev_kit) {
		return Genesis::Kit::Dev->new($self->path("dev"));
	}

	#    find_kit() without a dev/ directory
	# or find_kit($name, $version)
	my $kits = $self->compiled_kits();

	# we either need a $name, or only one kit type
	# (i.e. we can autodetect $name for the caller)
	if (!$name) {
		return undef unless (keys %$kits) == 1;
		$name = (keys %$kits)[0];

	} else {
		return undef unless exists $kits->{$name};
	}

	if (defined $version and $version ne 'latest') {
		return exists $kits->{$name}{$version}
		     ? Genesis::Kit::Compiled->new(
		         name    => $name,
		         version => $version,
		         archive => $kits->{$name}{$version})
		     : undef;
	}

	my @versions = reverse sort { $a->[1] <=> $b->[1] }
	                       map  { [$_, _semver($_)] }
	                       keys %{$kits->{$name}};
	$version = $versions[0][0];
	return Genesis::Kit::Compiled->new(
		name    => $name,
		version => $version,
		archive => $kits->{$name}{$version});
}

1;

=head1 NAME

Genesis::Top

=head1 DESCRIPTION

Several interactions with Genesis have to take place in the context of a
I<root> directory.  Often, this is the something-deployments git repository.

This module abstracts out operations on that root directory, so that other
parts of the codebase can stop worrying about things like file paths, and
instead can carry around a C<Top> context object which handles it for them.

=head1 CONSTRUCTORS

=head2 new($path)

Instantiate a new Top object, pointing at C<$path>.

=head2 create($path, $name, %opts)

Creates a new deployment repository in C<$path>/C<$name>-deployments,
initializes it by creating the C<.genesis/> directory hierarchy, and returns
a new Top object pointing to that root directory.

The following options are currently supported:

=over

=item directory

Override the name of the new directory (which defaults to
C<$name>-deployments).

=back


=head1 METHODS

=head2 link_dev_kit($path)

Creates a symbolic link from C<dev/> to C<$path> (re-interpreted as an
absolute path).  This allows callers to correctly install the link for
Genesis to find a development kit source directory.

=head2 embed($bin)

Embeds the file C<$bin> into C<.genesis/bin/genesis>, and chmods it
properly.  This embedded copy of (probably Genesis) is used by the CI/CD
pipelines to avoid having to stuff versions into docker images.

=head2 download_kit($name, $version)

Contact Github, search through the B<genesis-community> organization, and
download the named kit and version (or latest) and stuff it in the
.genesis/kits directory.  This is the magic behind C<genesis download>.

=head2 path([$relative])

Qualifies and returns C<$relative> as an absolute path.

=head2 mkfile($file, [$mode], $contents)

Creates a file, relative to the Top root directory, using C<mkfile_or_fail>.

=head2 mkdir($file, [$mode])

Creates a directory, relative to the Top root directory, using
C<mkfile_or_fail>.

=head2 config()

Parses and returns the Genesis deployments repository configuration, found
in C<$root/.genesis/config>.

=head2 type()

Returns the deployment type of this Genesis root directory, which is used in
naming deployment environments.

=head2 has_dev_kit()

Returns true if the root directory has a so-called I<dev kit>, an uncompiled
directory that contains all of the kit files, for use in buiding and testing
Genesis kits.  The presence or absence of dev kits modifies the behavior of
Genesis substantially.

=head2 compiled_kits()

Returns a two-level hashref, associating kit names to their versions, to
their compiled tarball paths.  For example:

    {
      'bosh' => {
        '0.2.0' => 'root/path/to/bosh-0.2.0.tar.gz',
        '0.2.1' => 'root/path/to/bosh-0.2.1.tgz',
      },
    }

=head2 find_kit([$name, [$version]])

Looks through the list of compiled kits and returns the correct Genesis::Kit
object for the requested name/version combination.  Returns C<undef> if no
kit was found to satisfy the requirements.

If C<$name> is not given (or passed explicitly as C<undef>), this function
will look for the given C<$version> (pursuant to the rules in the following
paragraph), and expect only a single type of kit to exist in .genesis/kits.
If C<$name> is the string "dev", the development kit (in dev/) will be used
if it exists, or no kit will be returned (without checking compiled kits).

If C<$version> is not given (i.e. C<undef>), or is "latest", an analysis of
the named kit will be done to determine the latest version, per semver.

Some examples may help to clarify:

    # find the 1.0 concourse kit:
    $top->find_kit(concourse => '1.0');

    # find the latest concourse kit:
    $top->find_kit(concourse => 'latest');

    # find the latest version of whatever kit we have
    $top->find_kit(undef, 'latest');

    # find version 2.0 of whatever kit we have
    $top->find_kit(undef, '2.0');

    # explicitly use the dev/ kit
    $top->find_kit('dev');

    # use whatever makes the most sense.
    $top->find_kit();

Note that if you omit C<$name>, there is a semantic difference between
passing C<$version> as "latest" and not passing it (or passing it as
C<undef>, explicitly).  In the former case (version = "latest"), the latest
version of the singleton compiled kit is returned.  In the latter case,
C<find_kit> will check for a dev/ directory and use that if available.

=head2 load_env($name)

Loads a new Genesis::Env object, named $name, from the root directory.
This wraps a call to Genesis::Env->load().

=head2 create_env($name, $kit, %opts)

Creates a new Genesis::Env object, which will go through provisioning.
This wraps a call to Genesis::Env->create().

=cut
