package Genesis::Kit::Dev;
use strict;
use warnings;

use base 'Genesis::Kit';
use Genesis::Utils;
use Genesis::Helpers;
use Genesis::Run;

sub new {
	my ($class, $path) = @_;
	bless({
		path => $path,
	}, $class);
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
