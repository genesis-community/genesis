package Genesis::Kit::Provider;
use strict;
use warnings;

use Genesis;
use Genesis::Helpers;
use Genesis::Top;
use Getopt::Long qw/GetOptionsFromArray/;

### Class Methods {{{

# new -  builder for creating new instance of derived class based on config {{{
sub new {
	my ($class,%config) = @_;
	bug("%s->new is calling %s->new illegally",$class, __PACKAGE__)
		if ($class ne __PACKAGE__);

	if (!%config || !defined($config{type}) || $config{type} eq "genesis_community") {
		use Genesis::Kit::Provider::GenesisCommunity;
		return Genesis::Kit::Provider::GenesisCommunity->new(%config);
	} elsif ($config{type} eq 'github') {
		use Genesis::Kit::Provider::Github;
		return Genesis::Kit::Provider::Github->new(%config);
	} else {
		bail("Unknown kit provider type '$config{type}'");
	}
}

# }}}
# init - builder for creating new instance based on options {{{
sub init {
	my ($class, %opts) = @_;
	bug("%s->init is calling %s->init illegally",$class, __PACKAGE__)
		if ($class ne __PACKAGE__);

	if (defined($opts{'kit-provider-config'})) {
		my $provider;
		if (-d $opts{'kit-provider-config'} && -f $opts{'kit-provider-config'}.'/.genesis/config') {
			# Pointing at existing genesis repo
			$provider = Genesis::Top->new($opts{'kit-provider-config'})->kit_provider();
		} elsif (-f $opts{'kit-provider-config'} ) {
			# specific yaml file
			my $config = Genesis::IO->LoadFile($opts{'kit-provider-config'});
			$provider = Genesis::Kit::Provider->new(%$config);
		} else {
			bail("Unable to read kit-provider config: expecting either a Genesis deployment repo or a YAML/JSON file");
		}
		# TODO: Allow other options to update/override config values
		return $provider;
	} elsif (!defined($opts{'kit-provider'}) || $opts{'kit-provider'} eq "genesis-community") {
		use Genesis::Kit::Provider::GenesisCommunity;
		return Genesis::Kit::Provider::GenesisCommunity->init(%opts);
	} elsif ($opts{'kit-provider'} eq 'github') {
		use Genesis::Kit::Provider::Github;
		return Genesis::Kit::Provider::Github->init(%opts);
	} else {
		bail("Unknown kit provider type '$opts{'kit-provider'}'");
	}
}

# }}}
# opts -  list of options supported by init method {{{
sub opts {
	qw/
		/;
}

# }}}
# opts_help - specifies the new/update options understood by this provider {{{
sub opts_help {
	my ($class,%config) = @_;
	bug("%s->new is calling %s->new illegally",$class, __PACKAGE__)
		if ($class ne __PACKAGE__);
	use Genesis::Kit::Provider::GenesisCommunity;
	use Genesis::Kit::Provider::Github;

	$config{type_default_msg} ||= '(optional, defaults to "genesis-community")';
	$config{valid_types} ||= [qw(genesis-community github)];

	<<EOF
KIT PROVIDERS

While the Genesis Community Github organization is the primary source, kits are
available from various kit providers, each requiring their specific options.

  General Kit Provider Options:

    --kit-provider <type> (optional, defaults to "genesis-community")
        The type of kit provider you want to use.  Each provider has further
        options it accepts.

    --kit-provider-config <file> (optional)
        Instead of specifying all the separate kit provider options, you can
        specify an existing configuration to use, or an existing Genesis
        deployment repository.

${\Genesis::Kit::Provider::GenesisCommunity->opts_help(%config)
}${\Genesis::Kit::Provider::Github->opts_help(%config)
}
EOF
}

# }}}
# parse_opts - parses options based on the type of kit provider specified {{{
sub parse_opts {
	my ($class,$args,$kit_opts) = @_;
  Getopt::Long::Configure(qw(pass_through permute no_auto_abbrev no_ignore_case bundling));

	# Make sure to stop once a '--' is encountered.
	my $opt_args = [];
	while (scalar(@$args) && $args->[0] ne '--') {push(@$opt_args, shift(@$args))};

	GetOptionsFromArray($opt_args, $kit_opts, qw/kit-provider=s/);
	my $type = $kit_opts->{'kit-provider'};

	my @extra_opts = ();
	if (!$type || $type eq 'genesis-community') {
		use Genesis::Kit::Provider::GenesisCommunity;
		@extra_opts = Genesis::Kit::Provider::GenesisCommunity->opts();
	} elsif ($type eq 'github') {
		use Genesis::Kit::Provider::Github;
		@extra_opts =  Genesis::Kit::Provider::Github->opts();
	} else {
		bail("Unknown kit provider type '$type'");
	}

	GetOptionsFromArray($opt_args, $kit_opts, @extra_opts) if scalar(@extra_opts);

	# Shove the non-opts back into the args passed in
	while (scalar(@$opt_args)) {unshift(@$args,pop(@$opt_args))};

	return 1;
}

# }}}

# }}}

### Instance Methods {{{

# label - unified access for identifying name for this provider in human-readable form {{{
sub label {
	$_[0]->{label};
}
# }}}
# config - provides the config hash used to specify this provider (abstract) {{{
sub config {
	my ($self) = @_;
	bug("Abstract Method: Expecting %s class to define concrete '%' method", ref($self), 'config');
	# Input expected:
	#		No arguments>
	#
	# Output expected:
	#   Hash of config items that would be expected to create an object of this
	#   class as arguments to its new method
	
}
# }}}
# check - checks the availability of this provider (abstract) {{{
sub check {
	my ($self) = @_;
	bug("Abstract Method: Expecting %s class to define concrete '%' method", ref($self), 'config');
	# Input expected:
	#		No arguments, but can allow alternate url>
	#
	# Output expected:
	#   Error message if error encountered, otherwise undef or empty string
}

# }}}
# kit_names - retrieves list of kit names available from this provider (abstract) {{{
sub kit_names {
	my ($self, $filter) = @_;
	bug("Abstract Method: Expecting %s class to define concrete '%' method", ref($self), 'kits');
	# Input expected:
	#		$filter <regular expression to match kit names against>
	#
	# Output expected:
	#   List of kit names as strings, not including the '-genesis-kit' suffix.
	
}

# }}}
# kit_releases - retrieves a list of releases for a kit (abstract) {{{
sub kit_releases {
	# TODO: This should create (and cache) a list of Genesis::Kit:<Provider-centric-remote-type>
	my ($self, $name) = @_;
	bug("Abstract Method: Expecting %s class to define concrete '%' method", ref($self), 'kit_releases');
	# Input expected:
	#		$name: <kit name>
	#
	# Output expected:
	#   List of release objects, definition determined by provider class.
}

# }}}
# kit_versions - retrieves a list of versions for the given kit name (abstract) {{{
sub kit_versions {
	my ($self, $name, %opts) = @_;
	bug("Abstract Method: Expecting %s class to define concrete '%' method", ref($self), 'kit_versions');
	# Input expected:
	#		$name: <kit name>
	#		%opts: Hash that must except at least:
	#		  draft:      <boolean: include draft releases>
	#		  prerelease: <boolean: include draft releases>
	#		  latest:     <integer: number of versions to retrieve, decending order of version>
	#
	# Output expected:
	#   [
	#     {
	#       version:    <semver>,
	#       body:       <release notes>,
	#       draft:      <boolean: version is a draft>,
	#       prerelease: <boolean: version is a draft>,
	#       date:       <date of release creation>,
	#       url:        <optional: download url>
	#     }, ...
	#   ]
}

# }}}
# fetch_kit_version - fetches a tarball for the named kit and version from this provide (abstract) {{{
sub fetch_kit_version {
	my ($self, $name, $version, $path, $force) = @_;
	bug("Abstract Method: Expecting %s class to define concrete '%' method", ref($self), 'fetch_kit_version');
	# Input expected:
	#		$name:    <kit name>
	#		$version: <kit version, or 'latest'>
	#		$path:    <directory to store kit tarball>
	#
	# Output expected:
	#   ( <kit_name>, <actual_version>, <path/filename to where tarball was saved> )
}
# }}}
# latest_version_of - The latest version number,  {{{
sub latest_version_of {
	my ($self, $name, %opts) = @_;
	bail("Missing name for retrieving kit releases") unless $name;
	my $version = ($self->kit_versions($name, latest => 1, %opts))[0];
	return $version && $version->{version};
}

# }}}
# kit_version_info - The version information for a specific version {{{
sub kit_version_info {
	my ($self, $name, $version) = @_;
	bail("Missing name for retrieving kit releases") unless $name;
	($self->kit_versions($name, version => $version))[0];
}

# }}}

# }}}

1;

=head1 NAME

Genesis::Kit::Provider

=head1 DESCRIPTION

This class represents a Genesis Kit Provider.  This provider knows how to list
and fetch kits and their versions provided by that provider.

=head1 CONSTRUCTORS

=head2 new($path)

Instantiates a new dev kit, using source files in C<$path>.

=head2 downloadable($filter)

Lists the known downloadable compiled kits on the Genesis Community Github
organization.  If a filter is given, it will be used to limit the kit names to
match that filter as a regular expression.

An error will be thrown if it cannot reach the github api endpoint for
genesis-community organization, if the response is not valid JSON, or for
any other communication error.

=head2 releases($name)

Returns the list of releases for a given repository under the Genesis Community
Github organization.  This is the full response from Github, converted from
JSON, and includes all the information for all releases under the given
repository.  This is primarily a low-level function for C<url> and C<versions>

An error will be thrown if it cannot reach the github api endpoint for
genesis-community organization, if the repository does not exist,  if the
response is not valid JSON, or for any other communication error.

=head2 versions($name)

Returns a hash of tag,name,draft,prerelease,body and timestamp for each version
for the named repository under the Genesis Community Github organization.

An error will be thrown if it cannot reach the github api endpoint for
genesis-community organization, if the repository does not exist,  if the
response is not valid JSON, or for any other communication error.

=head2 url($name, $version)

Determines the download URL for this kit, by consulting Github.
Right now, this is limited to just the C<genesis-community> organization.

If you omit C<$version>, or set it to "latest", the most recent released
version on Github will be used.  Otherwise, the URL for the given version
will be used.

An error will be thrown if the version in question does not exist on Github.


=head1 METHODS

=head2 id()

Returns the identity of the dev kit, which is always C<(dev kit)>.  This is
useful for error messages and reporting.

=head2 name()

Returns the name of the dev kit, which is always C<dev>.

=head2 version()

Returns the version of the dev kit, which is always C<latest>.

=head2 kit_bug($fmt, ...)

Prints an error to the screen, complete with details about how the problem
at hand is a problem with the (local) development kit.

=head2 extract()

Copies the contents of the dev/ working directory to a temporary workspace,
and installs the Genesis hooks helper script.  The copy is done to avoid
accidental modifications to pristine dev kit sources, and to ensure that we
can safely write the hooks helper.

This method is memoized; subsequent calls to C<extract> will not re-copy the
dev/ working directory to the temporary workspace.

=cut
# vim: fdm=marker:foldlevel=1:noet
