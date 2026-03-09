package Genesis::Kit::Dev;
use strict;
use warnings;

use base 'Genesis::Kit';
use Genesis;
use Genesis::Term;
use Genesis::Helpers;

sub new {
	my ($class, $path) = @_;
	bless({
		source => $path,
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
	return sprintf("%s/%s (dev)", $_[0]->metadata->{name} || 'unknown', $_[0]->metadata->{version} || 'in-development');
}

sub name {
	return "dev";
}

sub version {
	return "latest";
}

sub is_dev {
	return 1;
}

sub extract {
	my ($self) = @_;
	return if $self->{root};

	$self->{root} = workdir();
	run({ onfailure => 'Could not copy dev/ kit directory' },
		'cp -a "$1/" "$2/dev"', $self->{source}, $self->{root});
	$self->{root} .= "/dev";

	Genesis::Helpers->write("$self->{root}/.helper");
	return 1;
}

1;
