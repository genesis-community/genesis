package Genesis::Hook::Features;
use strict;
use warnings;

use parent qw(Genesis::Hook);

use Genesis;

sub init {
	my $class = shift;
	$class->check_for_required_args(\@_, qw/env kit features/);
	my $obj = $class->SUPER::init(@_);
	$obj->{all_features} = [];
	$obj->{has_feature} = {};
	return $obj
}

sub add_feature {
	my ($self, $feature, $set) = @_;
	$set = 1 if (@_) < 3;
	push @{$self->{all_features}}, $feature;
	$self->{has_feature}{$feature} = $set;
}

sub has_feature {
	my ($self, $feature) = @_;
	return $self->{has_feature}{$feature};
}

sub delete_feature {
	my ($self, $feature) = @_;
	return delete $self->{has_feature}{$feature};
}

sub build_features_list {
	my ($self, %opts) = @_;
	my $virtual_features = $opts{virtual_features} || [];

	my @results = ();
	for my $feature (@{$self->{all_features}}) {
		if (grep { $feature eq $_ } @$virtual_features) {
			if ($self->has_feature("+$feature")) {
				push @results, "+$feature";
				$self->delete_feature("+$feature");
			}
		} elsif ($self->has_feature($feature)) {
			push @results, $feature ;
			$self->delete_feature($feature);
		}
	}
	return @results;
}

1;
