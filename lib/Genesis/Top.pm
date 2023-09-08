package Genesis::Top;
use strict;
use warnings;

use base 'Genesis::Base';

use Genesis;
use Genesis::Env;
use Genesis::Kit::Compiled;
use Genesis::Kit::Dev;
use Genesis::Kit::Provider;
use Genesis::Vault;
use Genesis::NoVault;
use Genesis::Config;

use Cwd ();
use File::Path qw/rmtree/;

### Class Methods {{{

# new - returns a new Genesis::Top Repository object {{{
sub new {
	my ($class, $root, %opts) = @_;
	my $top = bless({ root => Cwd::abs_path($root) }, $class);

	$ENV{GENESIS_ROOT}=$top->path();

	if ($opts{no_vault}) {
		debug "Top for $ENV{GENESIS_ROOT} requested with no vault support";
		$top->_set_memo('__vault', Genesis::NoVault->new());
		return $top;
	}

	if ($opts{vault}) {
		# TODO: #ADDVAULT
		# if ($opts{env}) {
		#   $top->add_vault($opts{vault},$opts{env})
		# } else {
		debug ("Overriding vault %s with user specified %s for this session", $top->vault->name, $opts{vault})
			if $top->has_vault;
		$top->set_vault(target => $opts{vault}, session_only => 1);
		#}
	}
	if ($top->vault()) {
		$ENV{GENESIS_TARGET_VAULT} = $ENV{SAFE_TARGET} = $top->vault->name;
	} elsif (!$ENV{GENESIS_NO_VAULT}) {
		debug "#R{WARNING} - could not find any #M{safe} target.  This may cause consequences later on";
	}
	return $top;
}

# }}}
# create - create a new Genesis repository at the specified location {{{
sub create {
	my ($class, $path, $name, %opts) = @_;
	debug("creating a new Genesis deployments repository named '$name' at $path...");

	# TODO: $opts{kit} does get passed in, and future versions will only allow one kit type per deployment
	# Need to determine how this gets added to the configuration and how it impacts the current use of deployment type
	# Probably becomes deployment-name and kit becomes the type (or drop type and use kit)

	$name =~ s/-deployments?//;
	bail "#R{[ERROR]} Invalid Genesis deployment repository name '$name'"
		unless $name =~ m/^[a-z][a-z0-9_-]+$/;

	debug("generating a new Genesis repo, named $name");

	my $dir = $opts{directory} || "${name}-deployments";
	bail "#R{[ERROR]} Repository directory name must only contain alpha-numeric characters, periods, hyphens and underscores"
		if $dir =~ /([^\w\.-])/;

	$path .= "/$dir";
	bail "#R{[ERROR]} Cannot create new deployments repository `$dir': already exists!"
		if -e $path;

	my $self = $class->new($path);
	$self->mkdir(".genesis");

	$self->{__kit_provider} = Genesis::Kit::Provider->init(%opts);
	$self->{__vault} = Genesis::Vault->target($opts{vault});

	eval { # to delete path if creation fails

		# Write new configuration
		$self->config->set('deployment_type',$name);
		$self->config->set('version',2);
		$self->config->set('creator_version', $Genesis::VERSION);

		$self->config->set('secrets_provider', {
			url       => $self->vault->url,
			insecure  => $self->vault->verify    ? Genesis::Config::FALSE : Genesis::Config::TRUE,
			namespace => $self->vault->namespace,
			strongbox => $self->vault->strongbox ? Genesis::Config::TRUE  : Genesis::Config::FALSE,
			alias     => $self->vault->name
		});

		$self->config->set('kit_provider', $self->kit_provider->config)
			unless ref($self->kit_provider) eq "Genesis::Kit::Provider::GenesisCommunity";

		$self->config->save;

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

To create a new environment (called `us-east-prod-$name`):

    genesis new us-east-prod

To build the full BOSH manifest for an environment:

    genesis manifest us-east-prod

... and then deploy it:

    genesis deploy us-east-prod

To rotate credentials for an environment:

    genesis rotate-secrets us-east-prod
    genesis deploy us-east-prod

To change the secrets provider for the environments in this repo:

    genesis secrets-provider --url https://example.com:8200 --insecure

... or clear it to use safe's currently targeted vault:

    genesis secrets-provider --clear

By default, the provider for kits is https://github.com/genesis-community, but
you can set this to another provider url via the `genesis kit-provider`
command:

    genesis kit-provider https://github.mycorp.com/mygenesiskits

This requires that url to provide releases in the same manner as github does.
You can see the current kit provider by calling it with no argument, or revert
back to default with the `--clear` option.

To update the Concourse Pipeline for this repo:

    genesis repipe

To check for updates for this kit:

    genesis list-kits -u

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

	};
	if ($@) {
		debug("removing incomplete Genesis deployments repository at #C{$path} due to failed creation");
		rmtree $path;
		die $@;
	}

	return $self;
}

# }}}
# }}}

### Instance Methods {{{

# Kit Provider handling
# kit_provider - return the kit provider for the Top object {{{
sub kit_provider {
	my $ref = $_[0]->_memoize(sub {
		my ($self) = @_;
		return Genesis::Kit::Provider->new(%{$self->config->get("kit_provider", {})});
	});
	return $ref;
}

# }}}
# set_kit_provider - set the kit provider {{{
sub set_kit_provider {

	my ($self, %opts) = @_;
	my $new_provider;

	# TODO: If needed, provide an interactive wizard to enter provider type and details
	#	if ($opts{interactive}) {
	#		$new_provider = Genesis::Kit::Provider->target(undef);
	#	} else ...
	eval {
		waiting_on "\nSetting up new kit provider...";
		$new_provider = Genesis::Kit::Provider->init(%opts);
		explain "done.";
		waiting_on "Writing configuration....";
		$self->{__kit_provider} = $new_provider;
		if (ref($self->kit_provider) eq "Genesis::Kit::Provider::GenesisCommunity") {
			$self->config->clear('kit_provider',1)
		} else {
			$self->config->set('kit_provider', $self->kit_provider->config,1);
		}
		explain "done.";
	};
	return $@;
}

# }}}
# kit_provider_info - return that status of the kit provider {{{
sub kit_provider_info {
	my $self = shift;
	$self->kit_provider->status(@_);
}

# }}}

# Secrets provider handling
# vault - initialize connectivity to the vault specified by the secrets provider {{{
sub vault {
	my $ref = $_[0]->_memoize(sub {
		return Genesis::NoVault->new() if ($ENV{GENESIS_NO_VAULT});
		my ($self) = @_;
		if (in_callback && $ENV{GENESIS_TARGET_VAULT}) {
			return Genesis::Vault->rebind();
		} elsif ($self->has_vault) {
			my $namespace =  $self->config->get("secrets_provider.namespace");
			my $strongbox = $self->config->get("secrets_provider.strongbox");
			my %attach_opts = (
				url    => $self->config->get("secrets_provider.url"),
				verify => $self->config->get("secrets_provider.insecure") ? 0 : 1
			);
			$attach_opts{namespace} = $namespace if defined($namespace);
			$attach_opts{strongbox} = ($strongbox ? 1: 0) if defined($strongbox);
			return Genesis::Vault->attach(%attach_opts);
		} else {
			my $vault = Genesis::Vault::default;
			$vault->connect_and_validate()->ref_by_name() if $vault;
			return $vault;
		}
	});
	return $ref;
}

# }}}
# repo_vault - returns the repository vault if specified in config, or env vault otherwise {{{
# TODO: examine how this can work with multiple vaults (#ADDVAULT)
sub repo_vault {
	my $self = shift;
	return Genesis::Vault::default unless $self->has_vault();
	return $self->config->get("secrets_provider.insecure");
}

# }}}
# has_vault - returns true if the configuration has a vault defined {{{
sub has_vault {
	my ($self) = @_;
	defined($self->config->get("secrets_provider")) && ref($self->config->get("secrets_provider")) eq 'HASH' && scalar(%{$self->config->get("secrets_provider")}) > 0;
}

# }}}
# set_vault - set the secret provider to the specified vault. {{{
sub set_vault {
	my ($self,%opts) = @_;
	my $new_vault;
	if ($opts{interactive}) {
		my $current_vault = $self->config->get("secrets_provider");
		if ($current_vault) {
			$current_vault = (Genesis::Vault->find_by_target($current_vault->{url}))[0];
		}
		$new_vault = Genesis::Vault->target(undef, default_vault => $current_vault);
	} elsif (exists($opts{target})) {
		# TODO: allow the creation of a new safe target by parsing target string (#BETTERVAULTTARGET)
		my @candidates = Genesis::Vault->find_by_target($opts{target});
		return "#R{[Error]} No vault found that matches $opts{target}." unless @candidates;
		return "#R{[Error]} Target $opts{target} has URL that is not unique across the known vaults on this system."
			if scalar(@candidates) > 1;
		$new_vault = $candidates[0];
	} elsif ($opts{clear}) {
		$new_vault = undef;
	} elsif (ref($opts{vault}) eq "Genesis::Vault") {
		$new_vault = $opts{vault}
	} else {
		bug "#R{[Error]} Invalid call to Genesis::Top->set_vault"
	}
	$self->{__vault} = $new_vault;
	return if $opts{session_only};

	if ($new_vault) {
		$self->config->set('secrets_provider', {
			url       => $new_vault->url,
			insecure  => $new_vault->verify    ? Genesis::Config::FALSE : Genesis::Config::TRUE,
			strongbox => $new_vault->strongbox ? Genesis::Config::TRUE  : Genesis::Config::FALSE,
			namespace => $new_vault->namespace,
			alias     => $new_vault->name
		}, 1);
	} else {
		$self->config->clear('secrets_provider',1);
	}
	return;
}

# }}}
# add_vault - TODO: #ADDVAULT add ability to support multiple vaults, default, base and per env {{{
sub add_vault {
}
# }}}
# vault_status - get the status for the associated secret-provider vault {{{
sub vault_status {
	my ($self) = @_;
	return () unless $self->has_vault;

	my $info = $self->config->get("secrets_provider");
	$info->{security} = ($info->{url} =~ /^https/)
		? ($info->{insecure} ? "#Y{(noverify)}" : "")
		: "#Y{(insecure)}";

	my @candidates = Genesis::Vault->find(url => $info->{url});
	if (! scalar(@candidates)) {
		$info->{alias_error} = "No alias for this URL found on local system";
		$info->{status} = qq(Run 'safe target "$info->{url}" "}#Ri{<alias>}#R{") . ($info->{insecure} ? " -k" : "") . "' to create an alias for this URL";
		return %$info;
	}

	if (scalar(@candidates) > 1) {
		$info->{alias_error} = "Multiple aliases for this URL found on local system";
		$info->{status} = "Remove all but one of the following safe targets: ".join(", ", map {$_->{name}} @candidates);
		return %$info;
	}

	my $vault = $candidates[0];
	local $ENV{QUIET} = 1;
	$info->{alias} = $vault->name;
	$info->{status} = $vault->status;
	return %$info;
}

# }}}
# get_ancestral_vault {{{
sub get_ancestral_vault {
	my ($self, $env) = @_;
	return Genesis::Env->new(name=>$env, top=>$self)->get_ancestral_vault();
}

sub reset_vault {
	my $self = shift;
	my $no_vault = defined($_[0]) && $_[0] eq 'no-vault';

	$self->_clear_memo('__vault');
	$ENV{GENESIS_NO_VAULT}=($no_vault ? '1' : '')
}

# }}}

# Repository management
# link_dev_kit - build a symbolic link to the specified path as a dev kit {{{
sub link_dev_kit {
	my ($self, $path) = @_;
	debug("linking dev kit '$path'");
	my $abs = Cwd::abs_path($path)
		or die "Unable to locate $path from ".Cwd::getcwd."\n";

	my $dev = $self->path('dev');
	unlink($dev) if -l $dev; # overwrite the link
	die "dev/ already exists, and is not a symbolic link\n"
		if -e $dev;

	symlink_or_fail($abs, $dev);
	return $self;
}

# }}}
# embed - embed the current version of genesis in the repository for CI pipeline usage {{{
sub embed {
	my ($self, $bin) = @_;
	debug("embedding `genesis' binary installed at $bin...");

	$self->mkdir(".genesis/bin");
	copy_or_fail(Cwd::abs_path($bin), $self->path(".genesis/bin/genesis"));
	chmod_or_fail(0755, $self->path(".genesis/bin/genesis"));
	return 1;
}

# }}}
# path - return the path of the repo, or absolute path of the specified relative path {{{
sub path {
	my ($self, $relative) = @_;
	return $relative ? "$self->{root}/$relative"
	                 :  $self->{root};
}

# }}}
# mkfile - make a file with the given content relative to the root of the repo {{{
sub mkfile {
	my ($self, $file, @rest) = @_;
	mkfile_or_fail($self->path($file), @rest);
}

# }}}
# mkdir - make a directory relative to the root of the repo {{{
sub mkdir {
	my ($self, $dir, @rest) = @_;
	mkdir_or_fail($self->path($dir), @rest);
}

# }}}
# config - read the configuration of the repo {{{
sub config {
	my ($self) = @_;
	my $ref = $self->_memoize(sub {
		my ($self) = @_;
		return Genesis::Config->new($self->path(".genesis/config"));
	});
	return $ref;
}

# }}}
# type - return the deployment type {{{
sub type {
	my ($self) = @_;
	return $self->config->get("deployment_type");
}

# }}}
# version - return the version of the cofiguration schema {{{
sub version {
	my ($self) = @_;
	return $self->config->get("version") if ($self->config->get("version")||'') =~ /^\d+$/;
	return 1;
}

# }}}
# genesis_version - return the genesis version that initialized the repo {{{
sub genesis_version {
   my ($self) = @_;
	 return $self->config->get("creator_version") if $self->config->get("creator_version");
   return $self->config->get("genesis_version") if $self->config->get("genesis_version");
   return $self->config->get("version") if $self->config->get("version") !~ /^\d+$/;
   return "Unknown";
}
# }}}
# warnings - return comma-separated list of the warnings that are configured for this environment {{{
sub warnings {
   my $self = @_;
   return defined($self->config->get("warnings")) ? $self->config->get("warnings") : "deprecation,configuration,secrets";
}

# }}}
# warn_on - return true if the repo is set to warn on the specified condition {{{
sub warn_on {
   my ($self,$type) = @_;
   return scalar(grep {$type eq $_} split(/\s*,\s*/, $self->warnings));
}
#}}}
# has_dev_kit - returns true if the repo has an embedded dev kit {{{
sub has_dev_kit {
	my ($self) = @_;
	return -d $self->path("dev");
}

# }}}

# Environment handling
# load_env - return a Genesis::Env object for the specified environment in the repo {{{
sub load_env {
	my ($self, $name) = @_;
	$name =~ s/.yml$//;
	debug("loading environment #C{%s}", $name);
	if ($self->has_env($name)) {
		return Genesis::Env->load(top  => $self, name => $name);
	} elsif (in_callback() && $name eq $ENV{'GENESIS_ENVIRONMENT'}) {
		return Genesis::Env->from_envvars($self);
	} else {
		bail "#R{[ERROR]} Environment file #C{%s} does not exist", humanize_path($self->path($name.".yml"));
	}
}

# }}}
# has_env - returns true if the repo has an enviroment of the given name {{{
sub has_env {
	my ($self, $name) = @_;
	$name =~ s/.yml$//;
	return Genesis::Env->exists(
		top => $self,
		name => $name
	);
}

# }}}
# create_env - create a new environment of the given name in the repo {{{
sub create_env {
	my ($self, $name, $kit, %opts) = @_;
	debug("setting up new environment #C{%s}", $name);
	return Genesis::Env->create(
		%opts,
		top  => $self,
		name => $name,
		kit  => $kit,
	);
}

# }}}

# Kit handling
# local_kits - return the list of the kits available locally {{{
sub local_kits {
	my ($self) = @_;
	return Genesis::Kit::Compiled->local_kits(
		$self->kit_provider(),
		$self->path(".genesis/kits"),
	);
}

# }}}
# local_kit_version - return the Genesis::Kit object for the given name and version {{{
sub local_kit_version {
	my ($self, $name, $version) = @_;

	($name, $version) = ($1, $2)
		if (!defined($version) && defined($name) && $name =~ m{(.*)/(.*)});

	# local_kit_version('dev') or local_kit_version() with a dev kit present
	return Genesis::Kit::Dev->new($self->path("dev"))
		if ((!$name && !$version) || ($name && $name eq 'dev')) && $self->has_dev_kit;
	return undef if ($name and $name eq 'dev');

	#    local_kit_version() without a dev/ directory
	# or local_kit_version($name, $version)
	my $kits = $self->local_kits();

	# we either need a $name, or only one kit type
	# (i.e. we can autodetect $name for the caller)
	$name = (keys %$kits)[0] if (!$name && keys(%$kits) == 1);
	return undef unless $kits->{$name};

	$version = (reverse sort by_semver keys %{$kits->{$name}})[0]
		if (!defined($version) || $version eq 'latest');
	return $kits->{$name}{$version};
}

# }}}
# remote_kit_names - get available kit names from kit provider {{{
sub remote_kit_names {
	my $self = shift;
	$self->kit_provider->kit_names(@_);
}

# }}}
# remote_kit_versions - get versions available for a remote kit from the kit provider {{{
sub remote_kit_versions {
	my $self = shift;
	$self->kit_provider->kit_versions(@_);
}

# }}}
# remote_kit_version_info - return the metadata about the specified remote kit version {{{
sub remote_kit_version_info {
	my ($self, $name, $version) = @_;
	($name, $version) = ($1, $2)
		if (!defined($version) && defined($name) && $name =~ m{(.*)/(.*)});
	$version = $self->kit_provider->latest_version_of($name) unless $version && $version ne 'latest';
  $self->kit_provider->kit_versions($name, version => $version);
}

# }}}
# download_kit - install remote kit into the local repository {{{
sub download_kit {
	my ($self, $id, %opts) = @_;
	my ($name, $version) = ($1, $2) if $id =~ m/([^\/]+)(?:\/(.*))?/;
	$version = $self->kit_provider->latest_version_of($name) unless $version && $version ne 'latest';

	my $target;
	if ($opts{to}) {
		$target = $opts{to};
		bail("#R{[ERROR]} #C{%s} is not a directory", $opts{to}) unless -d $opts{to};
		bail "#R{[ERROR]} #C{%s} is not writable", $opts{to} unless -w $opts{to};
	} elsif ($opts{'as-dev'}) {
		$target = workdir;
	} else {
		$target = $self->path(".genesis/kits");
		mkdir_or_fail($target);
	}

	$self->kit_provider->fetch_kit_version($name,$version,$target,$opts{force});
}

# }}}
# }}}

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

=head2 download_kit($spec)

Takes a kit spec (name or name/version) and attempts to download the release
matching the spec from Github.

Contact Github, search through the B<genesis-community> organization, and
download the named kit and version (or latest) and stuff it in the
.genesis/kits directory.  This is the magic behind C<genesis download>.

This returns the actual kit name and version that was downloaded (useful when
no version specified or was specified as "latest")

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

=head2 local_kit_version([$name || $spec, [$version]])

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
    $top->local_kit_version(concourse => '1.0');

    # find the latest concourse kit:
    $top->local_kit_version(concourse => 'latest');

    # find the latest version of whatever kit we have
    $top->local_kit_version(undef, 'latest');

    # find version 2.0 of whatever kit we have
    $top->local_kit_version(undef, '2.0');

    # find using kit spec string
    $top->local_kit_version('concourse/1.0.3');

    # explicitly use the dev/ kit
    $top->local_kit_version('dev');

    # use whatever makes the most sense.
    $top->local_kit_version();

Note that if you omit C<$name>, there is a semantic difference between
passing C<$version> as "latest" and not passing it (or passing it as
C<undef>, explicitly).  In the former case (version = "latest"), the latest
version of the singleton compiled kit is returned.  In the latter case,
C<local_kit_version> will check for a dev/ directory and use that if available.

=head2 load_env($name)

Loads a new Genesis::Env object, named $name, from the root directory.
This wraps a call to Genesis::Env->load().

=head2 has_env($name)

Returns true if an environment by the given name exists under the repo.

=head2 create_env($name, $kit, %opts)

Creates a new Genesis::Env object, which will go through provisioning.
This wraps a call to Genesis::Env->create().

=cut
# vim: fdm=marker:foldlevel=1:noet
