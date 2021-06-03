package Genesis::Github;
use strict;
use warnings;

use Genesis;
use Genesis::UI;

use Digest::SHA qw/sha1_hex/;

use constant {
	DEFAULT_DOMAIN => 'github.com',
	DEFAULT_ORG    => 'genesis-community',
	DEFAULT_TLS    => 'yes'
};
### Class Methods {{{

# new - create a default github kit provider {{{
sub new {
	my ($class, %config) = @_;
	my $tls = $config{tls} || DEFAULT_TLS;
	$tls = "skip" unless $tls =~ /^(no|yes|skip)$/;
	
	my $creds;
	if ($ENV{GITHUB_USER} && $ENV{GITHUB_AUTH_TOKEN}) {
		$creds = "$ENV{GITHUB_USER}:$ENV{GITHUB_AUTH_TOKEN}";
	}
	bless({
		domain => $config{domain} || DEFAULT_DOMAIN,
		org    => $config{org}    || DEFAULT_ORG,
		creds  => $creds,
		tls    => $tls,
		label  => $config{label}
	}, $class);
}

# }}}
# }}}

### Instance Methods {{{

# check - checks the availability of this provider {{{
sub check {
	my ($self, $url, $ref) = @_;
	my $status;
	$url ||= $self->repos_url;
	$ref ||= $url;
	my ($code, $msg) = curl("HEAD", $url, undef, undef, 0, $self->{creds});
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
# label - description of the current github connection, defaults to domain/org {{{
sub label {
	return $_[0]->{label} || $_[0]->{domain}."/".$_[0]->{org};
}

# }}}
# repos_url - The url required to fetch the repos for this provider {{{
sub repos_url {
	my ($self, $page) = @_;
	my $url = sprintf("%s/users/%s/repos", $self->base_url, $self->{org});
	$url .= "?page=$page" if $page;
	return $url;
}

# }}}
# releases_url - The url required to fetch the list of releases for a given kit on this provider {{{
sub releases_url {
	my ($self, $name, $page) = @_;
	my $url = sprintf("%s/repos/%s/%s/releases",$self->base_url,$self->{org},$name);
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
# repos - contents of the github orgs repos {{{
sub repos {
	my ($self,$refresh) = @_;
	unless (defined($self->{_repos}) && !$refresh) {
		my $status = $self->check;
		bail $status."\n" if $status;

		$self->{_repos} = [];
		my $page = 1;
		while (1) {
			my ($code, $msg, $data) = curl("GET", $self->repos_url($page), undef, undef, 0, $self->{creds});
			my $results;
			eval {
				$results = load_json($data);
				1
			} or bail("#R{error!}\nFailed to read repository information from #M{%s} org: %s", $self->label, $@);
			last unless ref($results) eq "ARRAY" && scalar(@$results) > 0;
			push @{$self->{_repos}}, @$results;
			$page++;
		}
	}
	return $self->{_repos};
}

# }}}
# repo_names - return a list of repositories under the organization {{{
sub repo_names {
	my ($self, $filter) = @_;
	$filter ||= qr/.*/;
	return [
		grep {$_ =~ $filter}
		map  {$_->{name}}
		@{$self->repos}
	];
}

# }}}
# releases - retrieves a list of releases for a repository {{{
sub releases {
	my ($self, $name) = @_;

	bail("Missing repository name") unless $name;

	$self->{_releases} ||= {};
	unless (defined($self->{_releases}{$name})) {
		my $url = $self->releases_url($name);
		my ($code, $status) = $self->check($url);
		if ($code == 404) {
			# Check if kit exists, for a better error message
			bail("No repository named #C{%s} exists under #M{%s}", $name, $self->label)
				if (! grep {$_ eq $name} ($self->repo_names));
		}
		bail "$status"."\n" if $status;
		trace "About to get releases from Github";

		waiting_on STDERR "Retrieving list of available releases for #M{%s} kit on #C{%s} ...",$name,$self->label;
		$self->{_releases}{$name} = $self->get_release_info($name);
		explain STDERR "#G{ done.}";
	}

	return @{$self->{_releases}{$name}};
}

# }}}
# get_release_info - fetch all release information for the given repository {{{
sub get_release_info {
	my ($self, $name, $label) = @_;
	$label ||= "repository #C{$name}";
	my ($code,$msg,$data,$headers,@results);
	my $url = $self->releases_url($name);
	while (1) {
		($code, $msg, $data, $headers) = curl("GET", $url, undef, undef, 0, $self->{creds});
		bail("#R{error!}\nCould not find  %s release information; Github rsponded with a %s status:\n%s",$label,$code,$msg)
			unless $code == 200;

		my $results;
		eval {
			$results = load_json($data);
			1;
		} or bail("Failed to read releases information from Github: %s\n",$@);
		push(@results, @{$results});

		my ($links) = grep {$_ =~ s/^Link: //i} split(/[\r\n]+/, $headers);
		last unless $links;
		$url = (grep {$_ =~ s/^<(.*)>; rel="next"/$1/} split(', ', $links))[0];
		last unless $url;
		waiting_on STDERR '.';
	}
	return \@results;
}

# }}}
# versions - retrieves a list of versions for the given repository name{{{
sub versions {
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
		$self->releases($name);

	if (defined $opts{latest}) {
		my $latest = $opts{latest} || 1;
		my @versions = (reverse sort by_semver (map {$_->{tag_name}} @releases))[0..($latest-1)];
		@releases = grep {my $v = $_->{tag_name}; grep {$_ eq $v} @versions} @releases;
	}
	my $asset_filter=$opts{"asset_filter"} || qr/^$name$/;
	return map {
		my $r = $_;
		(my $v = $r->{tag_name}) =~ s/^v//;
		(my $af = $asset_filter) =~ s/\[#version#\]/$v/;
		my $asset = (grep {$_->{name} =~ $af} @{$r->{assets}})[0];
		scalar({
			version    => $v,
			body       => $r->{body},
			draft      => !!$r->{draft},
			prerelease => !!$r->{prerelease},
			date       => $r->{published_at} || $r->{created_at},
			url        => $asset->{browser_download_url} || "",
			filename   => $asset->{name} || ""
		});
	} @releases;
}
# fetch_release - fetches the release tarball for the specified version of the given repository {{{
sub fetch_release {
	my ($self, $name, $version, $path, $force) = @_;

	if (!defined($version) || $version eq 'latest') {
		# Better to call `latest_version` prior to this, but this is a safety valve.
		$version = $self->latest_version_of($name);
		bail("No latest version of $name repository found with a downloadable release")
			unless $version;
	} else {
		$version =~ s/^v//;
	}

	my $version_info = (
		grep {$_->{version} eq $version}
		$self->versions($name, include_drafts => 1, include_prereleases => 1)
	)[0];
	bail(
		"\n#R{[ERROR]} Release %s/%s was not found\n",
		$name, $version
	) unless $version_info && ref($version_info) eq 'HASH';

	my $url = $version_info->{url};
	bail(
		"\n#R{[ERROR]} Release %s/%s was found but is missing its resource url.".
		"\n        It may have been revoked (see release notes below):\n\n%s\n",
		$name, $version, $version_info->{body}
	) unless $url;

	waiting_on "Downloading v%s of #M{%s} from #C{%s} ... ",$version,$name,$self->label;
	my ($code, $msg, $data) = curl("GET", $url);
	bail "\n#R{error!}\nFailed to download %s/%s from %s: returned a %s status code\n", $name, $version, $self->label, $code
		unless $code == 200;
	explain "#G{done.}";

	my $file = "$path/$version_info->{filename}";
	if (-f $file) {
		if (! $force) {
			my $old_data = slurp($file);
			if (sha1_hex($data) eq sha1_hex($old_data)) {
				bail "#Y{[WARNING]} Exact same release already exists under #C{%s} - no change.\n", humanize_path($path);
			} else {
				error "#R{[ERROR]} Release $name/$version already exists, but is different!";
				die_unless_controlling_terminal;
				my $overwrite = prompt_for_boolean("Do you want to overwrite the existing file with the content downloaded from\n$self->{label}",0);
				bail "Aborted!\n" unless $overwrite;
			}
		}
		chmod_or_fail(0600, $file);
	}
	mkfile_or_fail($file, 0400, $data);

	# TODO: Add to gt
	debug("downloaded release #M{%s}/#C{%s}: %s bytes", $name, $version, length($data));

	return ($name,$version,$file);
}
# }}}
# latest_version_of - The actual version for the latest release of the given repository {{{
sub latest_version_of {
	my ($self, $name, %opts) = @_;
	bail("Missing name for retrieving release") unless $name;
	my $version = (
		grep {$_->{url}}
		$self->versions($name, latest => 1, include_drafts => $opts{include_drafts}, include_prerelease => $opts{include_prereleases})
	)[0];
	return $version && $version->{version};
}

# }}}
# }}}

1;
# vim: fdm=marker:foldlevel=1:noet
