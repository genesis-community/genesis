package Genesis::Kit::Unpacked;
use strict;
use warnings;

use base 'Genesis::Kit';
use Genesis;
use Genesis::Term;
use Genesis::Helpers;

sub new {
	my ($class, $path, $name, $version) = @_;
	bless({
		path => $path,
		name => $name,
		version => $version,
	}, $class);
}

sub kit_bug {
	my ($self, @msg) = @_;
	$! = 2; die csprintf(@msg)."\n".
	            csprintf("#R{This is a bug in the unpacked kit located in #C{%s}.}\n", $self->path).
	            csprintf("Please contact the author(s):\n").
	            csprintf("  - you\n\n"); # you're welcome, Tom
}

sub name {
	my $self = shift;
	return $self->{metadata}->{name} || $self->{name};
}

sub version {
	my $self = shift;
	return $self->{metadata}->{version} || $self->{version};
}

sub id {
	my $self = shift;
	return sprintf("%s/%s (unpacked)", $self->name, $self->version);
}

sub location {
	return 'in '.humanize_path($_[0]->{path});
}

sub unpack {
	my ($self, $dest) = @_;
	run({ onfailure => 'Could not copy unpacked kit directory' },
		'cp -a "$1/" "$2"', $self->{path}, $dest);
}

1;

=head1 NAME

Genesis::Kit::Dev

=head1 DESCRIPTION

This class represents a "dev" kit, one that exist as a directory on-disk,
and not as a compiled tarball archive.  Kit authors use dev kits whenever
they are updating or modifying kits, and operators may opt to use dev kits
if they are experimenting, or working outside the capabilities of existing
kits.

=head1 CONSTRUCTORS

=head2 new($path)

Instantiates a new dev kit, using source files in C<$path>.


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
