package Genesis::Hook::Features;
use strict;
use warnings;

use parent qw(Genesis::Hook);

use Genesis;

sub init {
	my $class = shift;
	$class->check_for_required_args({@_}, qw/env kit features/);
	my $obj = $class->SUPER::init(@_);
	$obj->{all_features} = [];
	$obj->{has_feature} = {};
	return $obj
}

# REFACTOR:  The virtual_features functionality is not actually functional
#            because there is no distiction between + prefixed features when
#            adding to the list and the lookup.  Revisit this to see
#            if we can make it work.
#
#            The origin of this code, and it does function, is so that
#            if we have virtual features (prefixed with +) that we need
#            users to specify in their feature list (without the +), they
#            can be converted to the virtual feature when building the
#            features list.  This is useful for things like when they
#            have the ocfp feature but want to use the internal blobstore,
#            which is normally a virtual feature, but not the default
#            when ocfp is specified.


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

sub done {
	my $self = shift;
	return $self->SUPER::done($_[0]) if @_ == 1 and !$_[0];
	my $features = (@_)
		? @_ == 1 && ref($_[0]) eq 'ARRAY'
			? $_[0]
			: [@_]
		: [$self->build_features_list()];
	return $self->SUPER::done($features);
}

1;
