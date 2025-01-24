package IPv4::Range;

use v5.20;
use feature 'signatures';
no warnings 'experimental::signatures';

require IPv4;

# This class is used to describe a collection of IPv4::Span objects.  It can be
# initialized with a list of spans, a list of addresses, a list of CIDR blocks,
# or a comma separated list of any of the above.
#
# It will provide utility methods for set union, intersection and exclusion so
# multiple spans can be combined or compared as well as against other Range
# objects.

# TODO:  Add migtrate function that will rehome a range to a new network

use overload
	'""'  => sub { shift->range() },
	'0+'  => sub { shift->size() },
	'-'   => '__minus',
	'+'   => sub { shift->add(shift) },
  'cmp' => 'cmp',
  'eq'  => 'eq',
	'<=>' => 'numeric_cmp',
	'=='  => 'numeric_eq',
	'!='  => sub { shift->numeric_eq(shift) ? 0 : 1 },
	'='   => 'clone',
	'<>'	=> sub { shift->next() },
	'@{}' => sub { [shift->addresses()] };

sub new($class, @spans) {
	my $self = bless {spans => []}, $class;

	for my $span (@spans) {
		if (ref($span) eq "IPv4::Range") {
			# Clone each span in the range and add it to the current range
			for my $range_span ($span->spans) {
				push @{$self->{spans}}, $range_span->clone;
			}
		} elsif (ref($span) eq "IPv4::Span") {
			# Add the span to the current range
			push @{$self->{spans}}, $span->clone;
		} elsif (ref($span) eq "IPv4::Address") {
			# Add the address to the current range
			push @{$self->{spans}}, IPv4->span($span->address);
		} elsif (ref($span) eq "ARRAY") {
			# 2 elements are spans, 4 elements are address octets
			if (scalar(@$span) == 2) {
				push @{$self->{spans}}, IPv4->span($span);
			} elsif (scalar(@$span) == 4) {
				push @{$self->{spans}}, IPv4->address($span);
			} else {
				die sprintf("Invalid span array: [%s]", join(',', @$span));
			}
		} elsif (ref($span) eq "") {
			for my $fragment (split /,\s*/,$span) {
				if ($fragment =~ m{^\d+\.\d+\.\d+\.\d+((-\d+\.\d+\.\d+\.\d+)|(/\d+))?$}) {
					push @{$self->{spans}}, IPv4->span($fragment);
				} else {
					# Lets see if its a valid address
					my $address;
					# Don't upconvert integers to addresses
					die sprintf("Invalid IPv4 literal: '%s'", $fragment) if ($fragment =~ /^\d+$/);
					eval { $address = IPv4->address($fragment) };
          die sprintf("Invalid IPv4 literal: '%s'", $fragment) if ($@);
					push @{$self->{spans}}, $address;
				}
			}
		} else {
			die sprintf("Invalid span type: '%s'", ref($span));
		}
	}
	$self->compact;
	return $self;
}

sub compact($self) {
	return unless $self->spans > 1;
	my @spans = sort { $a->start->cmp($b->start) } $self->spans;
	my @compacted = shift @spans;
	for my $span (@spans) {
		if ($span->start->int <= $compacted[-1]->end()->int()+1) {
			$compacted[-1]= IPv4->span($compacted[-1]->start->address.'-'.$span->end->address);
		} else {
			push @compacted, $span;
		}
	}
	$self->{spans} = \@compacted;
}

sub simplify($self) {
	$self->compact;
  my $obj = $self;
  if (scalar($obj->spans) == 1) {
    $obj = ($obj->spans)[0];
    if (ref($obj) eq 'IPv4::Span' && $obj->size() == 1) {
      $obj = $obj->start();
    }
  }
  return $obj;
}

sub spans($self) {
	return ( @{$self->{spans}} );
}

sub addresses($self) {
	return map { $_->addresses } $self->spans;
}

sub start($self) {
	return $self->{spans}->[0]->start;
}

sub end($self) {
	return $self->{spans}->[-1]->end;
}

sub range($self) {
	return join ',', map { $_->range } $self->spans;
}

sub size($self) {
	my $size = 0;
	for my $span ($self->spans) {
		$size += $span->size();
	}
	return $size;
}

sub next($self) {
	$self->{next} //= 0;
	return ($self->{next} = undef) unless $self->{next} < $self->size;
	return $self->slice(1, $self->{next}++)->simplify
}

sub reset($self) {
	$self->{next} = undef;
}

sub clone($self) {
	return IPv4->range(map {$_->clone} $self->spans);
}

sub slice($self, $size, $offset=0) {
	# Check if the offset is negative
	if ($offset < 0) {
		# Calculate the positive offset based on the requested size and the size of the span
		$offset = $self->size - $size + $offset + 1;
		# Reduce size if offset is still negative
		if ($offset < 0) {
			$size += $offset;
			$offset = 0;
		}
	} elsif ($offset + $size > $self->size) {
		# Reduce size if the offset is greater than the size of the span
		$size = $self->size - $offset;
	}
	
  my $slice = IPv4->range();
	for my $span ($self->spans) {
		if ($offset > $span->size -1) {
			$offset -= $span->size;
			next;
		}
		my $s = $span->slice($size, $offset);
		$size -= $s->size;
		push @{$slice->{spans}}, $s;
		$offset = 0;
		last unless $size;
	}
	$slice->compact;
	return ($slice);
}

# Return a span object that starts at the lowest address in the Range and
# ends at the highest address in the Range.
sub span($self) {
	my $start = $self->[0]->start;
	my $end = $self->[-1]->end;
	return IPv4->span($start->address.'-'.$end->address);
}

sub add($self, @spans) {
	return IPv4->range($self->spans, @spans);
}

sub subtract($self, @args) {
	my @spans = $self->spans;
	my $obj = IPv4->range(@args);
	my @subtracted = ();
	for my $r2 ($obj->spans) {
    push(@subtracted, $_->subtract($r2)->spans) for (@spans);
		@spans = @subtracted;
		@subtracted = ();
	}
	return IPv4->range(grep {$_} @spans);
}

sub __minus($self, $other, $swap = 0) {
	die "Invalid subtraction between IPv4::Range and integer"
		if (IPv4::__is_integer($other));
	
	my $obj = IPv4::__autovivify($other);
	return $swap ? $obj->subtract($self) : $self->subtract($obj);
}

sub cmp($self, $other, $swap = 0) {
	$other = IPv4::__autovivify($other);
	my $adjuster = $swap ? -1 : 1;
	my @my_spans = $self->spans;
	my @other_spans = $other->spans;
	for my $i (0..$#my_spans) {
		return 1 * $adjuster unless defined $other_spans[$i];
		my $cmp = $my_spans[$i]->cmp($other_spans[$i]);
		return $cmp * $adjuster if $cmp;
	}
	return ((scalar(@other_spans) > scalar(@my_spans)) ? -1 : 0) * $adjuster;
}

sub eq($self, $other, $swap = 0) {
	return "$self" eq "$other";
}

sub numeric_eq($self, $other, $swap = 0) {
	return $self <=> $other ? 0 : 1;
}

sub numeric_cmp($self, $other, $swap = 0) {
	$other = IPv4::__autovivify($other) unless IPv4::__is_integer($other);
	return ($self->size <=> $other) * ($swap ? -1 : 1);
}

sub contains($self, $obj) {
	$obj = IPv4::__autovivify($obj);
	my @other_spans = $obj->spans;
	for my $other_span (@other_spans) {
		my $contained = 0;
		for my $span ($self->spans) {
			if ($span->contains($other_span)) {
				$contained = 1;
				last;
			}
		}
		return 0 unless $contained;
	}
	return 1;
}

1;
