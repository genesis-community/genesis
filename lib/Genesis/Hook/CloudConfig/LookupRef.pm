#!/usr/bin/env perl
package Genesis::Hook::CloudConfig::LookupRef;

use strict;
use warnings;

use Genesis qw(struct_lookup);

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

sub resolve {
	my ($self, $config) = @_;
	my $value = struct_lookup($config, $self->paths, $self->default);
	return $value;
}
1;
