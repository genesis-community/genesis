package Service::BOSH::Stemcell;
use strict;
use warnings;

use Genesis qw/bail bug info by_semver count_nouns curl/;
use Genesis::Term qw/csprintf/;
use Genesis::UI qw/prompt_for_choice prompt_for_boolean/;

use Digest::SHA qw(sha1_hex);
use File::Temp qw(tempdir);
use File::Path qw(make_path);

use constant {
	# bosh.io API URL for stemcells
	default_stemcell_url => 'https://bosh.io/api/v1/stemcells/',
	valid_stemcell_types => [qw/regular light/],
};

# Class methods
# FIXME: References to CPI should be replaced with IaaS
sub available_stemcells {
	# List available stemcells for a given OS and CPI
	my ($class, %opts) = @_;
	my ($iaas, $os, $all, $type_filter) = @opts{qw/iaas os all type/};
	bug(
		"No IaaS specified for stemcell lookup"
	) unless $iaas;
	$iaas =~ s/-cpi$//; # Don't think anyone will use this, but just in case
	$os //= 'ubuntu-jammy';
	$all = $all ? 1 : 0;

	my $cpi = $opts{cpi} // $class->cpi_stemcell_prefix($iaas);
	bail(
		"No stemcells found for %s on the %s CPI",
		$os, $cpi
	) unless $cpi;

	# The agent suffix has been dropped for ubuntu-noble (and later?)
	my $agent= $opts{agent};
	$agent //= 'go_agent' if $os =~ m/^ubuntu-(trusty|xenial|bionic|focal|jammy)$/;
	$agent //= 'go_agent' if $os =~ m/^windows/;
	$agent = $agent ? "-$agent"  : '';

	my $url = ($opts{stemcell_url}//default_stemcell_url).
		"bosh-$cpi-$os$agent?all=$all";
	my ($status, $line, $data, $headers) = curl(
		'GET', $url, { 'Accept' => 'application/json' }
	);
	my $json = JSON::PP->new->utf8(1)->decode($data);
	my $stemcells = [];
	for my $data (@$json) {
		for my $type (valid_stemcell_types->@*) {
			next if $type_filter && $type ne $type_filter;
			next unless exists $data->{$type};
			my $stemcell = $class->new(
				iaas => $iaas,
				os => $os,
				type => $type,
				name => $data->{name},
				version => $data->{version},
				$data->{$type}->%{qw/md5 sha1 sha256 size url/},
			);
			push @$stemcells, $stemcell;
		}
	}
	return [sort {
		(by_semver($b,$a)) || # Newest (aka highest version number) first
		($a->{type} cmp $b->{type})          # light before regular
	} @$stemcells];
}

sub select_stemcell {
	# Choose a stemcell from the list of available stemcells
	my ($class, %opts) = @_;
	my $stemcells = $opts{stemcells} // $class->available_stemcells(%opts);
	my $type_filter = $opts{type};
	my %by_major_version = ();
	for my $stemcell (@$stemcells) {
		my $major_version = $stemcell->{version} =~ s/^(\d+)\..*$/$1/r;
		push @{$by_major_version{$major_version} //= []}, $stemcell;
	}

	my $selected_major = undef;
	if (keys %by_major_version > 1) {
		if ($type_filter) {
		}
		my @major_versions = sort { $a <=> $b } keys %by_major_version;
		my @labels = map {
			[sprintf("%s.x #Ki{(%s)}", $_, count_nouns(scalar(@{$by_major_version{$_}}), "version")), "$_.x"]
		} @major_versions;
		$selected_major = prompt_for_choice(
			"Select the major version of the stemcell you wish to upload:",
			\@major_versions, $major_versions[-1], \@labels, undef, 'stemcell major version'
		);
	} else {
		$selected_major = (keys %by_major_version)[0];
	}
	my $selected_stemcells = $by_major_version{$selected_major};
	# format the list of stemcells to show if they are light or regular
	my %grouped_by_minor = ();
	for my $stemcell (@$selected_stemcells) {
		my $minor = $stemcell->{version} =~ s/^\d+\.(\d+)\..*$/$1/r;
		my $type = $stemcell->{type};
		$grouped_by_minor{$minor}{$type} = $stemcell;
	}

	my $selected_minor = undef;
	if (keys %grouped_by_minor > 1) {
		my @minor_versions = sort by_semver keys %grouped_by_minor;
		my @labels = $type_filter
		? @minor_versions
		: map {
			[sprintf(
				"%s #Ki{(%s)}",
				$_,
				join(',', sort by_semver keys %{$grouped_by_minor{$_}}),
			), $_]
		} @minor_versions;

		$selected_minor = prompt_for_choice(
			"Select the ".($type_filter ? "$type_filter " : "")."stemcell you wish to upload:",
			\@minor_versions, $minor_versions[-1], \@labels, undef, 'stemcell version'
		);
	} else {
		($selected_minor) = keys %grouped_by_minor;
	}

	# Check if there are multiple stemcell types for the same version
	my @types = sort keys %{$grouped_by_minor{$selected_minor}};
	if ($type_filter || @types == 1) {
		return $grouped_by_minor{$selected_minor}{(keys %{$grouped_by_minor{$selected_minor}})[0]};
	} else {
		my $selected_type = prompt_for_choice(
			"Select the stemcell type you wish to upload:",
			\@types, $types[0], undef, undef, 'stemcell type'
		);
		return $grouped_by_minor{$selected_minor}{$selected_type};
	}
}

sub find {
	# Find a stemcell by name and version
	my ($class, $iaas, $os, $version, $type) = @_;
	my $stemcells = $class->available_stemcells(iaas => $iaas, os => $os, all => 1, type => $type);
	my ($major, $latest) = $version =~ m/^(?:(\d+)\.)?(latest)$/;

	if ($latest) {
		if (defined $major) {
			$version = ([
				grep { $_->{version} =~ m/^$major\./ } @$stemcells
			]->[0]//{})->{version};
		} else {
			$version = ($stemcells->[0]//{})->{version};
		}
	}
	return undef unless $version;

	my @matches = grep { $_->{version} eq $version } @$stemcells;
	return $matches[0];
}

# Constructor
sub new {
  my ($class, %description) = @_;
	my @valid_keys = qw/iaas os type url name version size sha1 md5 sha256/;
	my @required_keys = @valid_keys[0..5];
	my @invalid = grep { my $k = $_; !grep { $k eq $_ } @valid_keys } keys %description;
	my @missing = grep { !exists $description{$_} } @required_keys;
	if (@invalid || @missing) {
		my $msg = "Invalid stemcell description: ";
		$msg .= "Invalid keys: " . join(', ', @invalid) . ". " if @invalid;
		$msg .= "Missing keys: " . join(', ', @missing) . ". " if @missing;
		bug($msg);
	}
	return bless {
		%description
  }, $class;
}

sub cpi_stemcell_prefix {
  my ($self, $cpi) = @_;
  my %mapping = (
    'aws'         => 'aws-xen-hvm',
    'azure'       => 'azure-hyperv',
    'google'      => 'google-kvm',
    'openstack'   => 'openstack-kvm',
		'stackit'     => 'openstack-kvm',
    'vsphere'     => 'vsphere-esxi',
    'virtualbox'  => 'warden-boshlite',
    'warden'      => 'warden-boshlite',
  );

  return $mapping{$cpi} || '';
}

sub is_type { return $_[0]->{type} eq $_[1]; }
sub is_light { return $_[0]->{type} eq 'light'; }
sub is_full { return $_[0]->{type} eq 'regular'; }
sub is_local { return $_[0]->{url} !~ m/^https?:\/\//; }

sub download {
  my ($self, $file) = @_;
	# NYI: Need to implement this correctly
	bail(
		"Downloading stemcell from %s is not implemented yet",
		$self->{url}
	);
  return 1;
}

sub upload {
	my ($self, $bosh, %opts) = @_;
	my @cmd = ('upload-stemcell');
	push @cmd, '--fix' if $opts{fix};
	unless ($self->is_local) {
		push @cmd, '--sha1', $self->{sha1} if $self->{sha1};
		push @cmd, '--version', $self->{version};
		push @cmd, '--name', $self->{name};
	}
	push @cmd, $self->{url};

	if ($opts{dryrun}) {
		$bosh->dryrun_of(@cmd);
		return wantarray ? (undef, 0, undef) : 1;
	}

	my ($out, $rc, $err) = $bosh->execute({interactive => ($opts{silent} ? 0 : 1)}, @cmd);
	return wantarray ? ($out, $rc, $err) : $rc ? 0 : 1;
}

sub description {
	my ($self, $title) = @_;
	$title //= sprintf( # RISK: Anticipates string contains exactly one %s
		'Stemcell %s',
		$self->{name}
	);
	return csprintf("%s\n".
		"  #m\@{*} #mi{IaaS:}    #c{%s}\n".
		"  #m\@{*} #mi{OS:}      #c{%s}\n".
		"  #m\@{*} #mi{Type:}    #c{%s}\n".
		"  #m\@{*} #mi{Version:} #c{%s}\n".
		"  #m\@{*} #mi{%s}%s #ci{%s}\n".
		"  #m\@{*} #mi{Size:}    #c{%s}\n".
		"  #m\@{*} #mi{SHA1:}    #c{%s}\n",
		$title,
		$self->{iaas},
		$self->{os},
		$self->{type},
		$self->{version},
		$self->is_local ? ("File:","   ") : ("URL:","   "),
		$self->{url},
		$self->{size},
		$self->{sha1}
	);
}

1;
