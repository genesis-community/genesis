package IP4::MultiRange;

use strict;
use warnings;
use v5.20;
use feature 'signatures';
no warnings 'experimental::signatures';

use IP4::Address;
use IP4::Range;

# This class is used to describe a collection of IP4::Range objects.  It can be
# initialized with a list of ranges, a list of addresses, a list of CIDR blocks,
# or a comma separated list of any of the above.
#
# It will provide utility methods for set union, intersection and exclusion so
# multiple ranges can be combined or compared as well as against other MultiRange
# objects.

sub new($class, @ranges) {
	my $self = bless [], $class;

	for my $range_group (@ranges) {
		if (ref $range_group eq 'IP4::Range') {
			push @$self, $range_group;
			next;
		}
		for my $range (split /,/, $range_group) {
			push @$self, IP4::Range->new($range);
		}
	}
	$self->compact(); # Combine overlapping or contiguous ranges

	return $self;
}

sub compact($self) {
	my @ranges = sort { $a->start->cmp($b->start) } @$self;
	my @compacted = shift @ranges;
	for my $range (@ranges) {
		if ($range->start->int <= $compacted[-1]->end()->int()+1) {
			$compacted[-1]= IP4::Range->new($compacted[-1]->start->address.'-'.$range->end->address);
		} else {
			push @compacted, $range;
		}
	}

	@$self = @compacted;
}

sub ranges($self) {
	return ( @$self );
}

sub size($self) {
	my $size = 0;
	for my $range (@$self) {
		$size += $range->size();
	}
	return $size;
}

# Return a range object that starts at the lowest address in the MultiRange and
# ends at the highest address in the MultiRange.
sub span($self) {
	my $start = $self->[0]->start;
	my $end = $self->[-1]->end;
	return IP4::Range->new($start->address.'-'.$end->address);
}

sub exclude($self, $range) {
	my @subtracted = ();
	for my $r (@$self) {
		push @subtracted, $r->subtract($range);
	}
	return IP4::MultiRange->new(@subtracted);
}

sub expand($self, $range) {
}

1;

