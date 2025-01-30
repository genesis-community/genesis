package Genesis::Hook::Blueprint;
use strict;
use warnings;

use parent qw(Genesis::Hook);

use Genesis;

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->{features} = [$obj->env->features];
	$obj->{files} = [];
	return $obj
}

sub validate_features {
	my ($self, @features) = @_;
	return 1
}

sub add_files {
	my $self = shift;
	push(@{$self->{files}}, @_);
}

sub results {
	bail(
		"Blueprint hook could not be run"
	) unless $_[0]->{complete};
	bail(
		"Could not determine which YAML files to merge: 'blueprint' specified no files"
	) unless scalar(@{$_[0]->{files}});
	return $_[0]->{files}
}
1;
