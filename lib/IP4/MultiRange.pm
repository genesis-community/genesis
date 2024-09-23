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

	for my $range_group (grep {$_} @ranges) {
		if (ref $range_group eq 'IP4::MultiRange') {
			push @$self, @$range_group;
			next;
		}
		if (ref $range_group eq 'IP4::Range') {
			push @$self, $range_group;
			next;
		}
		for my $range (split /,/, $range_group) {
			push @$self, IP4::Range->new($range);
		}
	}
	return $self unless @$self > 1;
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

sub range($self) {
	return join ',', map { $_->range } @$self;
}

sub size($self) {
	my $size = 0;
	for my $range (@$self) {
		$size += $range->size();
	}
	return $size;
}

sub slice($self, $size, $offset=0) {
	my $slice = IP4::MultiRange->new();
	for my $range (@$self) {
		if ($offset > $range->size) {
			$offset -= $range->size;
			next;
		}
		(my $s,$size) = $range->slice($size, $offset);
		$slice = $slice->add($s);
		$offset = 0;
		last unless $size;
	}
	return ($slice, $size, $self->subtract($slice));
}

# Return a range object that starts at the lowest address in the MultiRange and
# ends at the highest address in the MultiRange.
sub span($self) {
	my $start = $self->[0]->start;
	my $end = $self->[-1]->end;
	return IP4::Range->new($start->address.'-'.$end->address);
}

sub add($self, @ranges) {
	return IP4::MultiRange->new($self->ranges,@ranges);
}

sub subtract($self, @args) {
	my @ranges = @$self;
	my @ranges_to_remove = map { ref $_ eq 'IP4::MultiRange' ? @$_ : $_ } @args;
	my @subtracted = ();
	for my $r2 (@ranges_to_remove) {
		for my $r1 (@ranges) {
			my $diff = $r1->subtract($r2);
			if (ref $diff eq 'IP4::MultiRange') {
				push @subtracted, @{$diff};
			} else {
				push @subtracted, $diff;
			}
		}
		@ranges = @subtracted;
		@subtracted = ();
	}
	return IP4::MultiRange->new(grep {$_} @ranges);
}

1;
