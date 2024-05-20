package Genesis::Kit::Provider::Github;
use strict;
use warnings;

use base 'Genesis::Kit::Provider';
use Genesis;
use Genesis::UI;
use Genesis::Helpers;
use Service::Github;

use Digest::SHA qw/sha1_hex/;

use constant {
	DEFAULT_DOMAIN => 'github.com',
	DEFAULT_LABEL  => "Custom Github-based Kit Provider",
	DEFAULT_TLS    => 'yes'
};

### Class Methods {{{

# init - creates a new provider on repo init or change {{{
sub init {
	my ($class, %opts) = @_;
	my $label = $opts{"kit-provider-name"} || DEFAULT_LABEL;

	bail("$label kit provider requires specifying the organization using the --kit-provider-org option")
		unless $opts{"kit-provider-org"};
	
	$opts{"kit-provider-tls"} ||= DEFAULT_TLS;
	bail("Github kit provider option --kit-provider-tls only accepts: no, yes, and skip")
		unless $opts{"kit-provider-tls"} =~ /^(no|yes|skip)$/;
	$class->new(
		type         => 'github',
		label        => $label,
		domain       => $opts{'kit-provider-domain'},
		organization => $opts{'kit-provider-org'},
		tls          => $opts{'kit-provider-tls'}
	);
}

# }}}
# new - create a default github kit provider {{{
sub new {
	my ($class, %config) = @_;
	bless({
		label  => $config{label} || DEFAULT_LABEL,
		remote => Service::Github->new(
		            domain => $config{domain} || DEFAULT_DOMAIN,
		            org    => $config{organization},
		            tls    => $config{tls} || DEFAULT_TLS
		          )
	}, $class);
}

# }}}
# opts -  list of options supported by init method {{{
sub opts {
	qw/
		kit-provider-name=s
		kit-provider-domain=s
		kit-provider-org=s
		kit-provider-tls=s
		kit-provider-access-token=s
		/;
}

# }}}
# opts_help - specifies the new/update options understood by this provider {{{
sub opts_help {
	my ($self,%config) = @_;
	return '' unless grep {$_ eq 'github'} (@{$config{valid_types}});
	<<EOF
  Kit Provider `github`:

    This is a generic kit provider type for kits backed by Github or Github
    Enterprise, allowing you to specify the domain url and organization to
    target your specific provider location.  It supports the following options:

    --kit-provider-name <value> (optional, defaults to "Custom Github-based kit provider")
        Provide an understandable label that will be used to refer to this
        provider in messages

    --kit-provider-domain <value> (optional, defaults to "github.com")
        If you are using Github Enterprise, specify your github domain, without
        the www or api subdomain.

    --kit-provider-org <value> (required)
        The name of your github organization that owns the kit repositories.

    --kit-provider-tls <value> (optional, defaults to 'yes')
        Use this option to configure tls:
          no   - uses http protocol.
          yes  - uses https protocol and validates certificate.
          skip - uses https protocol, but skips validation.
EOF
}

# }}}
# }}}

### Instance Methods {{{

# Delegation to remote object
sub label        {$_[0]->{label};}
sub remote       {$_[0]->{remote};}
sub domain       {$_[0]->{remote}{domain};}
sub organization {$_[0]->{remote}{org};}
sub credentials  {$_[0]->{remote}{creds};}
sub tls          {$_[0]->{remote}{tls};}
sub check        {$_[0]->remote->check($_[1], $_[0]->label);}
sub repos_url    {shift->remote->repos_url(@_);}
sub releases_url {shift->remote->releases_url(@_);}
sub base_url     {$_[0]->remote->base_url();}

# config - provides the config hash used to specify this provider {{{
sub config {
	my ($self) = @_;
	my $config = {
		type         => 'github',
		organization => $self->organization,
	};
	$config->{label}  = $self->label  unless $self->label  eq DEFAULT_LABEL;
	$config->{tls}    = $self->tls    unless $self->tls    eq DEFAULT_TLS;
	$config->{domain} = $self->domain unless $self->domain eq DEFAULT_DOMAIN;
	return %$config;
}
# }}}
# kit_names - retrieves list of kit names available from this provider {{{
sub kit_names {
	my ($self, $filter) = @_;

	unless (defined($self->{_kits})) {
		my $status = $self->check;
		bail $status."\n" if $status;

		info {pending=> 1}, "Retrieving list of available kits from #C{%s} ...",$self->label;
		$self->{_kits} = [
			map  {(my $k = $_) =~ s/-genesis-kit$//; $k}
			@{$self->remote->repo_names(qr/.*-genesis-kit$/)}
		]
	}
	my @kits = @{$self->{_kits}};
	@kits = grep {$_ =~ qr/$filter/} @kits if $filter;
	if (@kits) {
		info "#G{ done.}";
		return @kits
	}

	info "#R{failed.}";

	my $err = "No genesis kit repositories found on $self->label";
	$err .= "that match the pattern /$filter/" if $filter;
	$err .= "\nYou will need to provide your credentials via GITHUB_USER and GITHUB_AUTH_TOKEN to see private repositories"
		unless $self->{credentials};
	bail $err."\n";
}

# }}}
# kit_releases - retrieves a list of releases for a kit {{{
sub kit_releases {
	my ($self, $name) = @_;

	bail("Missing name for retrieving kit releases") unless $name;

	$self->{_releases} ||= {};
	unless (defined($self->{_releases}{$name})) {
		my $url = $self->remote->releases_url($name."-genesis-kit");
		my ($code, $status) = $self->check($url,$self->label);
		if ($code == 404) {
			# Check if kit exists, for a better error message
			bail("No kit named #C{%s} exists under %s", $name, $self->label)
				if (! grep {$_ eq $name} ($self->kit_names));
		}
		bail "$status"."\n" if $status;
		trace "About to get releases from Github";

		info {pending=>1}, "Retrieving list of available releases for #M{%s} kit on #C{%s} ...",$name,$self->label;
		$self->{_releases}{$name} = $self->remote->get_release_info($name."-genesis-kit", "Genesis Kit $name");
		info "#G{ done.}";
	}

	return @{$self->{_releases}{$name}};
}

# }}}
# kit_versions - retrieves a list of versions for the given kit name {{{
sub kit_versions {
	my ($self, $name, %opts) = @_;
	$opts{asset_filter} = qr/$name-[#version#]\.t(ar\.)?gz/;
	return $self->remote->versions($name."-genesis-kit", %opts);
}

# }}}
# fetch_kit_version - fetches a tarball for the named kit and version from this provider {{{
sub fetch_kit_version {
	my ($self, $name, $version, $path, $force) = @_;

	if (!defined($version) || $version eq 'latest') {
		# Better to call `latest_version` prior to this, but this is a safety valve.
		$version = $self->latest_version_of($name);
		bail("No latest version of $name kit found with a downloadable release")
			unless $version;
	} else {
		$version =~ s/^v//;
	}

	my $version_info = (
		grep {$_->{version} eq $version}
		$self->kit_versions($name, include_drafts => 1, include_prereleases => 1)
	)[0];
	bail(
		"Version %s/%s was not found\n",
		$name, $version
	) unless $version_info && ref($version_info) eq 'HASH';

	my $url = $version_info->{url};
	bail(
		"Version %s/%s was found but is missing its resource url.".
		"It may have been revoked (see release notes below):\n\n%s\n",
		$name, $version, $version_info->{body}
	) unless $url;

	info {pending=> 1}, "Downloading v%s of #M{%s} kit from #C{%s} ... ",$version,$name,$self->label;
	my ($code, $msg, $data) = curl("GET", $url, undef, undef, 0, $self->credentials);
	bail(
		"Failed to download %s/%s from %s: returned a %s status code\n",
		$name, $version, $self->label, $code
	) unless $code == 200;
	info "#G{done.}";
	my $file = "$path/$name-$version.tar.gz";
	if (-f $file) {
		if (! $force) {
			my $old_data = slurp($file);
			if (sha1_hex($data) eq sha1_hex($old_data)) {
				warning(
					"Exact same kit already exists under #C{%s} - no change.\n",
					humanize_path($path)
				);
				exit 0;
			} else {
				error "Kit $name/$version already exists, but is different!";
				die_unless_controlling_terminal;
				my $overwrite = prompt_for_boolean("Do you want to overwrite the existing file with the content downloaded from\n$self->{label}",0);
				bail "Aborted!\n" unless $overwrite;
			}
		}
		chmod_or_fail(0600, $file);
	}
	mkfile_or_fail($file, 0444, $data);

	# TODO: Add to gt
	debug("downloaded kit #M{%s}/#C{%s}: %s bytes", $name, $version, length($data));

	return ($name,$version,$file);
}
# }}}
# latest_version_of - The actual version for the latest release of the given kit name {{{
sub latest_version_of {
	my ($self, $name, %opts) = @_;
	bail("Missing name for retrieving kit releases") unless $name;
	my $version = (
		grep {$_->{url}}
		$self->kit_versions($name, latest => 1, include_drafts => $opts{include_drafts}, include_prerelease => $opts{include_prereleases})
	)[0];
	return $version && $version->{version};
}

# }}}
# status - The human-understandable label for messages and errors {{{
sub status {
	my ($self,$verbose) = @_;
	my ($code,$msg) = $self->check();

	# Reinterperete message for clearer status
	if ($code == 404) {
		($code,$msg) = $self->check($self->base_url);
		if ($code == 404) {
			$msg = "Cannot find API endpoint for ".$self->domain;
		} else {
			$msg = sprintf("Cannot find organization %s on %s", $self->organization, $self->domain);
		}
	} elsif ($code == 403 && !$self->credentials) {
		$msg = "Unable to access - throttling may be effect, or you may not have permission to access this organization.  Credentials may need to be set in environment vars GITHUB_USER & GITHUB_AUTH_TOKEN";
	} elsif ($code != 200) {
		$msg =~ s/^.*:/HTTP Error $code while accessing:/;
	}

	my $kits;
	if ($code == 200) {
		# Get kit counts
		my @kit_names = sort $self->kit_names;
		if ($verbose) {
			$kits = {};
			info {pending=>1}, "\n";
			for my $name (@kit_names) {
				info {pending=>1}, "  - ";
				my @releases = $self->kit_releases($name);
				my $num_drafts = scalar(grep {$_->{draft}} @releases);
				my $num_prereleases = scalar(grep {!$_->{draft} && $_->{prerelease}} @releases);
				my $num_releases = scalar(@releases) - $num_prereleases - $num_drafts;
				$kits->{$name}      = sprintf("#%s{%d release%s}", ($num_releases ? "G" : "R"), $num_releases, $num_releases == 1 ? "" : "s") .
					($num_prereleases ? sprintf(", %d pre-release%s", $num_prereleases, $num_prereleases == 1 ? "" : "s") : '') .
					($num_drafts      ? sprintf(", %d draft%s", $num_drafts, $num_drafts == 1 ? "" : "s") : '');
			}
		} else {
			$kits = [@kit_names];
		}
	}

	my $info = {
		type      => 'github',
		extras    => ["Name", "Domain", "Org", "Use TLS"],
		"Name"    => $self->label,
		"Domain"  => $self->domain,
		"Org"     => $self->organization,
		"Use TLS" => $self->tls,

		status    => $msg || 'ok',
		kits      => $kits
	};
	return %$info;
}

# }}}

# }}}
1;

=head1 NAME

Genesis::Kit::Provider::Github

=head1 DESCRIPTION


=head1 CONSTRUCTORS

=head2 new(%opts)

Instantiates a new Kit::Compiled object.

The following options are recognized:

=over

=item name

The name of the kit.  This option is B<required>.

=item version

The version of the kit.  This option is B<required>.

=item archive

The absolute path to the compiled kit tarball.  This option is B<required>.

=back


=head1 METHODS

=head2 id()

Returns the identity of the kit, in the form C<$name/$verison>.  This is
useful for error messages and reporting.

=head2 name()

Returns the name of the kit.

=head2 version()

Returns the version of the kit.

=head2 kit_bug($fmt, ...)

Prints an error to the screen, complete with details about how the problem
at hand is not the operator's fault, and that they should file a bug against
the kit's Github page, or contact the authors.

=head2 extract()

Extracts the compiled kit tarball to a temporary workspace, and installs the
Genesis hooks helper script.

This method is memoized; subsequent calls to C<extract> will have no effect.

=cut
# vim: fdm=marker:foldlevel=1:noet
