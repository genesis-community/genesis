package Genesis::Top;
use strict;
use warnings;

use Genesis::IO;
use Genesis::Env;
use Genesis::Kit::Compiled;
use Genesis::Kit::Dev;

sub new {
	my ($class, $root) = @_;
	bless({ root => $root }, $class);
}

sub path {
	my ($self, $relative) = @_;
	return $relative ? "$self->{root}/$relative"
	                 :  $self->{root};
}

sub config {
	my ($self) = @_;
	return $self->{__config} ||= LoadFile($self->path(".genesis/config"));
}

sub has_dev_kit {
	my ($self) = @_;
	return -d $self->path("dev");
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

=cut
