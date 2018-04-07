package Genesis::Kit::Dev;
use strict;
use warnings;

use base 'Genesis::Kit';
use Genesis;
use Genesis::Helpers;

sub new {
	my ($class, $path) = @_;
	bless({
		path => $path,
	}, $class);
}

sub kit_bug {
	my ($self, @msg) = @_;
	$! = 2; die csprintf(@msg)."\n".
	            csprintf("#R{This is a bug in your dev/ kit.}\n").
	            csprintf("Please contact the author(s):\n").
	            csprintf("  - you\n\n"); # you're welcome, Tom
}

sub id {
	return "(dev kit)";
}

sub name {
	return "dev";
}

sub version {
	return "latest";
}

sub extract {
	my ($self) = @_;
	return if $self->{root};

	$self->{root} = workdir();
	run({ onfailure => 'Could not copy dev/ kit directory' },
		'cp -a "$1/" "$2/dev"', $self->{path}, $self->{root});
	$self->{root} .= "/dev";

	Genesis::Helpers->write("$self->{root}/.helper");
	return 1;
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

=head2 extract()

Copies the contents of the dev/ working directory to a temporary workspace,
and installs the Genesis hooks helper script.  The copy is done to avoid
accidental modifications to pristine dev kit sources, and to ensure that we
can safely write the hooks helper.

This method is memoized; subsequent calls to C<extract> will not re-copy the
dev/ working directory to the temporary workspace.

=cut
