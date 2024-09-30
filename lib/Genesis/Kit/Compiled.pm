package Genesis::Kit::Compiled;
use strict;
use warnings;

use base 'Genesis::Kit';
use Genesis;
use Genesis::Term;
use Genesis::Helpers;

sub new {
	my ($class, %opts) = @_;
	bless({
		name     => $opts{name},
		version  => $opts{version},
		archive  => $opts{archive},
		provider => $opts{provider},
	}, $class);
}

sub local_kits {
	my ($class, $provider, $path) = @_;
	$path ||= '.';

	my %kits;
	for (glob("$path/*")) {
		next unless m{/([^/]*)-(\d+(\.\d+(\.\d+([.-]rc[.-]?\d+)?)?)?).t(ar.)?gz$};
		$kits{$1}{$2} = $class->new(
			name     => $1,
			version  => $2,
			archive  => $_,
			provider => $provider
		);
	}
	return \%kits;
}

sub kit_bug {
	my ($self, @msg) = @_;
	my @errs = (
		csprintf(@msg),
		csprintf("#R{This is a bug in the %s kit.}", $self->id));

	my @authors;
	if ($self->metadata->{authors}) {
		@authors = @{$self->metadata->{authors}};
	} elsif ($self->metadata->{author}) {
		@authors = ($self->metadata->{author});
	}

	my $url = $self->metadata->{code} || '';
	if ($url =~ m/github/) {
		push @errs, csprintf("Please file an issue at #C{%s/issues}", $url);
	} elsif (@authors) {
		push @errs, "Please contact the author(s):";
		push @errs, "  - $_" for @authors;
	}

	$! = 2; die join("\n", @errs)."\n\n";
}

sub location {
	my ($self) = @_;
	my $loc = humanize_path($self->{archive}, root_map => scalar(Genesis::deployment_roots_map()));
	$loc =~ s{.genesis/kits/.*}{}; # strip off the .genesis/kits/... part
	return "from deployment $loc";
}

sub unpack {
	my ($self, $dest) = @_;
	run({ onfailure => 'Could not read kit file' },
	    'tar -xz -C "$1" --strip-components 1 -f "$2"',
	    $dest, $self->{archive});
}

1;

=head1 NAME

Genesis::Kit::Compiled

=head1 DESCRIPTION

This class represents a compiled kit, and its distribution as a tarball
archive.  Most operators use kits in this format.

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
