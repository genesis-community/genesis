package Genesis::Hook::Blueprint;
use strict;
use warnings;

use parent qw(Genesis::Hook);

use Genesis;

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->{files} = [];
	return $obj
}

sub add_files {
	my $self = shift;
	push(@{$self->{files}}, @_);
}

sub results {
	return undef unless $_[0]->{complete}; # Should this be an error?
	return (@{$_[0]->{files}})
}
1;
