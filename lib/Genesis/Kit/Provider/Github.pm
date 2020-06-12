package Genesis::Kit::Provider::Github;
use strict;
use warnings;

use base 'Genesis::Kit::Provider';
use Genesis;
use Genesis::UI;
use Genesis::Helpers;

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
		label         => $label,
		domain       => $opts{'kit-provider-domain'},
		organization => $opts{'kit-provider-org'},
		tls          => $opts{'kit-provider-tls'}
	);
}

# }}}
# new - create a default github kit provider {{{
sub new {
	my ($class, %config) = @_;
	my $credentials;
	if ($ENV{GITHUB_USER} && $ENV{GITHUB_AUTH_TOKEN}) {
		$credentials = "$ENV{GITHUB_USER}:$ENV{GITHUB_AUTH_TOKEN}";
	}
	bless({
		domain          => $config{domain} || DEFAULT_DOMAIN,
		organization    => $config{organization},
		credentials     => $credentials,
		label           => $config{label} || DEFAULT_LABEL,
		tls             => $config{tls} || DEFAULT_TLS,
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

# config - provides the config hash used to specify this provider {{{
sub config {
	my ($self) = @_;
	my $config = {
		type         => 'github',
		organization => $self->{organization},
	};
	$config->{label}   = $self->{label} unless $self->{label} eq DEFAULT_LABEL;
	$config->{tls}    = $self->{tls} unless $self->{tls} eq DEFAULT_TLS;
	$config->{domain} = $self->{domain} unless $self->{domain} eq DEFAULT_DOMAIN;
	return %$config;
}
# }}}
# check - checks the availability of this provider {{{
sub check {
	my ($self, $url) = @_;
	my $ref = $self->label();
	my $status;
	$url ||= $self->repos_url;
	my ($code, $msg) = curl("HEAD", $url, undef, undef, 0, $self->{credentials});
	if ($code == 404) {
		$status =  "Could not find $ref; are you able to route to the Internet?\n";
	} elsif ($code == 403) {
		$status = "Access forbidden trying to reach $ref; throttling may be in effect.  Set your GITHUB_USER and GITHUB_AUTH_TOKEN to prevent throttling.\n";
	} elsif ($code != 200) {
		$status = "Could not read $ref at $url; returned ($code):\n ".$msg."\n";
	}
	return wantarray ? ($code,$status) : $status;
}

# }}}
# kits - retrieves list of kit names available from this provider {{{
sub kit_names {
	my ($self, $filter) = @_;

	unless (defined($self->{_kits})) {
		my $status = $self->check;
		bail $status."\n" if $status;

		waiting_on "Retrieving list of available kits from #C{%s} ... ",$self->label;
		my ($code, $msg, $data) = curl("GET", $self->repos_url, undef, undef, 0, $self->{credentials});
		my $results;
		eval {
			$results = load_json($data);
			1
		} or bail("#R{error!}\nFailed to read repository information from %s: %s", $self->label, $@);
		explain '#G{done.}';

		$self->{_kits} = [
			map  {(my $k = $_) =~ s/-genesis-kit$//; $k}
			grep {$_ =~ qr/.*-genesis-kit$/}
			map  {$_->{name}}
			@$results
		]
	}
	my @kits = @{$self->{_kits}};

	@kits = grep {$_ =~ qr/$filter/} @kits if $filter;
	return @kits if scalar(@kits);

	my $err = "No genesis kit repositories found on $self->{label}";
	$err .= "that match the pattern /$filter/" if $filter;
	$err .= "\nYou will need to provide your credentials via GITHUB_USER and GITHUB_AUTH_TOKEN to see private repositories"
		unless $self->{credentials};
	bail $err."\n";
}

# }}}
# releases - retrieves a list of releases for a kit {{{
sub kit_releases {
	my ($self, $name) = @_;

	bail("Missing name for retrieving kit releases") unless $name;

	$self->{_releases} ||= {};
	unless (defined($self->{_releases}{$name})) {
		my $url =	$self->releases_url($name);
		my ($code, $status) = $self->check($url);
		if ($code == 404) {
			# Check if kit exists, for a better error message
			my $kits = $self->kit_names;
			if (! grep {$_ eq $name} ($self->kit_names)) {
				$status = "No kit named #C{$name} exists under $self->{label}";
			}
		}
		bail "$status"."\n" if $status;
		trace "About to get releases from Github";

		my ($msg,$data,$headers,@results);
		waiting_on STDERR "Retrieving list of available releases for #M{%s} kit on #C{%s} ...",$name,$self->label;
		while (1) {
			($code, $msg, $data, $headers) = curl("GET", $url, undef, undef, 0, $self->{credentials});
			bail("#R{error!}\nCould not find Genesis Kit %s release information; Github rsponded with a %s status:\n%s",$name,$code,$msg)
				unless $code == 200;

			my $results;
			eval {
				$results = load_json($data);
				1;
			} or bail("Failed to read releases information from Github: %s\n",$@);
			push(@results, @{$results});

			my ($links) = grep {$_ =~ s/^Link: //} split(/[\r\n]+/, $headers);
			last unless $links;
			$url = (grep {$_ =~ s/^<(.*)>; rel="next"/$1/} split(', ', $links))[0];
			last unless $url;
			waiting_on STDERR '.';
		}
		explain STDERR "#G{ done.}";
		$self->{_releases}{$name} = \@results;
	}

	return @{$self->{_releases}{$name}};
}

# }}}
# kit_versions - retrieves a list of versions for the given kit name {{{
sub kit_versions {
	my ($self, $name, %opts) = @_;

	# If specific version is specified, normalize it, and don't filter out drafts
	# or prereleases
	if ($opts{version}) {
		if ($opts{version} eq 'latest') {
			$opts{latest} = 1;
			$opts{version} = undef;
		} else {
			$opts{version} =~ s/^v//;
			$opts{drafts} = $opts{prerelease} = 1;
		}
	}

	my @releases =
		grep {!$opts{version}   || $_->{tag_name} =~qr/^v?$opts{version}$/}
		grep {!$_->{draft}      || $opts{'include_drafts'}}
		grep {!$_->{prerelease} || $opts{'include_prereleases'}}
		$self->kit_releases($name);

	if (defined $opts{latest}) {
		my $latest = $opts{latest} || 1;
		my @versions = (reverse sort by_semver (map {$_->{tag_name}} @releases))[0..($latest-1)];
		@releases = grep {my $v = $_->{tag_name}; grep {$_ eq $v} @versions} @releases;
	}
	return map {
		my $r = $_;
		(my $v = $r->{tag_name}) =~ s/^v//;
		my $url = (map {$_->{browser_download_url}} grep {$_->{name} =~ /$name-$v\.t(ar\.)?gz/} @{$r->{assets}})[0];
		scalar({
			version => $v,
			body => $r->{body},
			draft=> !!$r->{draft},
			prerelease => !!$r->{prerelease},
			date => $r->{published_at} || $r->{created_at},
			url => $url || ""
		});
	} @releases;
}

# }}}
# fetch_kit_version - fetches a tarball for the named kit and version from this provide {{{
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
		grep {$_->{url}}
		$self->kit_versions($name, include_drafts => 1, include_prereleases => 1)
	)[0];
	bail "Version $name/$version was not found" unless $version_info && ref($version_info) eq 'HASH';
	
	my $url = $version_info->{url};
	bail "Version $name/$version does not have a downloadable release\n" unless $url;

	waiting_on "Downloading v%s of #M{%s} kit from #C{%s} ... ",$version,$name,$self->label;
	my ($code, $msg, $data) = curl("GET", $url);
	bail "#R{error!}\nFailed to download %s/%s from %s: returned a %s status code\n", $name, $version, $self->label, $code
		unless $code == 200;
	explain "#G{done.}";
	my $file = "$path/$name-$version.tar.gz";
	if (-f $file) {
		if (! $force) {
			my $old_data = slurp($file);
			if (sha1_hex($data) eq sha1_hex($old_data)) {
				bail "#Y{[WARNING]} Exact same kit already exists under #C{%s} - no change.\n", humanize_path($path);
			} else {
				error "#R{[ERROR]} Kit $name/$version already exists, but is different!";
				die_unless_controlling_terminal;
				my $overwrite = prompt_for_boolean("Do you want to overwrite the existing file with the content downloaded from\n$self->{label}",0);
				bail "Aborted!\n" unless $overwrite;
			}
		}
		chmod_or_fail(0600, $file);
	}
	mkfile_or_fail($file, 0400, $data);

	# TODO: Add to gt
	debug("downloaded kit #M{%s}/#C{%s}: %s bytes", $name, $version, length($data));

	return ($name,$version,$file);
}
# }}}
# latest_kit_version - The human-understandable label for messages and errors {{{
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
			$msg = "Cannot find API endpoint for $self->{domain}";
		} else {
			$msg = "Cannot find organization $self->{organization} on $self->{domain}";
		}
	} elsif ($code == 403 && !$self->{credentials}) {
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
			for my $name (@kit_names) {
				waiting_on('.');
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
		"Name"    => $self->{label},
		"Domain"  => $self->{domain},
		"Org"     => $self->{organization},
		"Use TLS" => $self->{tls},

		status    => $msg || 'ok',
		kits      => $kits
	};
	return %$info;
}

# }}}
# label - The human-understandable label for messages and errors {{{
sub label {
	$_[0]->{label};
}

# }}}
# repos_url - The url required to fetch the repos for this provider {{{
sub repos_url {
	sprintf("%s/users/%s/repos", $_[0]->base_url, $_[0]->{organization})
}

# }}}
# releases_url - The url required to fetch the list of releases for a given kit on this provider {{{
sub releases_url {
	my ($self, $name, $page) = @_;
	my $url = sprintf("%s/repos/%s/%s-genesis-kit/releases",$self->base_url,$self->{organization},$name);
	$url .= "?page=$page" if $page;
	return $url;
}
# }}}
# base_url - the base url under which all requests are made {{{
sub base_url {
	my ($self) = @_;
	sprintf("%s://api.%s", ($self->{tls} eq 'no' ? "http" : "https"), $self->{domain});
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
