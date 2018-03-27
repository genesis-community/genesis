package Genesis::Root;
use strict;
use warnings;

use Genesis::Kit;

sub new {
	my ($class, $root) = @_;
	bless({ root => $root }, $class);
}

sub has_dev_kit {
	my ($self) = @_;
	return -d "$self->{root}/dev";
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

	# FIXME: dev kit!

	my $kits = $self->compiled_kits();
	return undef unless exists $kits->{$name};

	if (defined $version and $version ne 'latest') {
		return exists $kits->{$name}{$version}
		     ? Genesis::Kit->new($name, $version, $kits->{$name}{$version})
		     : undef;
	}

	my @versions = reverse sort { $a->[1] <=> $b->[1] }
	                       map  { [$_, _semver($_)] }
	                       keys %{$kits->{$name}};
	$version = $versions[0][0];
	return Genesis::Kit->new($name, $version, $kits->{$name}{$version});
}

1;

=head1 NAME

Genesis::Root

=head1 DESCRIPTION

Several interactions with Genesis have to take place in the context of a
I<root> directory.  Often, this is the something-deployments git repository.

This module abstracts out operations on that root directory, so that other
parts of the codebase can stop worrying about things like file paths, and
instead can carry around a Root context object which handles it for them.

=head1 CONSTRUCTORS

=head2 new($path)

Create a new root, at C<$path>.

=head1 METHODS

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

=head2 find_kit($name, [$version])

Looks through the list of compiled kits and returns the correct Genesis::Kit
object for the requested name/version combination.  Returns C<undef> if no
kit was found to satisfy the requirements.

If C<$version> is not given (i.e. C<undef>), or is "latest", an analysis of
the named kit will be done to determine the latest version, per semver.

=cut
