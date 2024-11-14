#!/usr/bin/env perl
package Genesis::Hook::CloudConfig::LookupRef;

use strict;
use warnings;

sub new {
	my ($class, $paths, $default) = @_;
	$paths = [ $paths ] unless ref($paths) eq 'ARRAY';
	return bless({
		paths => $paths,
		default => $default
	}, $class);
}

sub paths {
	my ($self) = @_;
	return @{$self->{paths}};
}

sub default {
	my ($self) = @_;
	return $self->{default};
}
1;
