package Genesis::Kit::Compiled;
use strict;
use warnings;

use base 'Genesis::Kit';
use Genesis;
use Genesis::Helpers;

sub new {
	my ($class, %opts) = @_;
	bless({
		name    => $opts{name},
		version => $opts{version},
		archive => $opts{archive},
	}, $class);
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

sub id {
	my ($self) = @_;
	return "$self->{name}/$self->{version}";
}

sub name {
	my ($self) = @_;
	return $self->{name};
}

sub version {
	my ($self) = @_;
	return $self->{version};
}

sub extract {
	my ($self) = @_;
	return if $self->{root};
	$self->{root} = workdir();
	run({ onfailure => 'Could not read kit file' },
	    'tar -xz -C "$1" --strip-components 1 -f "$2"',
	    $self->{root}, $self->{archive});

	Genesis::Helpers->write("$self->{root}/.helper");
	return 1;
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

=head2 extract()

Extracts the compiled kit tarball to a temporary workspace, and installs the
Genesis hooks helper script.

This method is memoized; subsequent calls to C<extract> will have no effect.

=cut
