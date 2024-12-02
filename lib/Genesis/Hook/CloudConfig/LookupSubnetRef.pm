#!/usr/bin/env perl
package Genesis::Hook::CloudConfig::LookupSubnetRef;

use strict;
use warnings;

use Genesis qw(bail);

sub new {
	my ($class, $ref, $lookup_method, @lookup_args) = @_;
	return bless({
		ref => $ref,
		lookup_method => $lookup_method,
		lookup_args => \@lookup_args
	}, $class);
}

sub resolve {
	my ($self, $config, $subnet_data) = @_;
	my $ref = $self->{ref};
	my $lookup_method = $self->{lookup_method};
	if ($lookup_method && $config->can($lookup_method)) {
		return $config->$lookup_method($subnet_data, $ref, @{$self->{lookup_args}});
	} elsif (exists($subnet_data->{$ref})) {
		return $subnet_data->{$ref};
	} else {
		bail(
			"Could not resolve reference '$ref' in subnet data. ",
			"Please ensure the reference exists and is spelled correctly."
		);
	}
}

1;
