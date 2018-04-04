package Genesis::Kit::Compiled;
use strict;
use warnings;

use base 'Genesis::Kit';
use Genesis::Utils;
use Genesis::Helpers;
use Genesis::Run;

sub new {
	my ($class, %opts) = @_;
	bless({
		name    => $opts{name},
		version => $opts{version},
		archive => $opts{archive},
	}, $class);
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
