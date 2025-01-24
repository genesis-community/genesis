package IPv4::Span;

use v5.20;
use feature 'signatures';
no warnings 'experimental::signatures';

require IPv4;

our $allow_oversized_mask = 1;

use overload
	'""'  => sub { shift->range() },
	'0+'  => sub { shift->size() },
	'-'   => 'subtract',
	'+'   => 'add',
	'<=>' => 'numeric_cmp',
	'cmp' => 'cmp',
	'eq'  => 'eq',
	'='   => 'clone',
	'<>'	=> sub { shift->next() },
	'@{}' => sub { [shift->addresses()] };

# This class is used to describe an inclusive span between two SIP addresses.
# It can initialized with a single address (regressive case), a CIDR block, or a
# starting address and an ending address.
#
# It can be used to return a list of all addresses in the span in either CIDR
# notation, a list of addresses, or a list of spans.
sub new($class, $span, $end=undef) { # TODO: Add seconds size argument that can be a count
	my $self = bless {}, $class;

	# Unravel array references
  if (ref($span) eq 'ARRAY' && scalar(@$span) == 2) {
		die "Invalid mix of arguments - array and end value" if defined($end);
		($span, $end) = @$span;
	}

	$span = IPv4->address($span) 
		if (ref($span) eq 'ARRAY' && scalar(@$span) == 4) || IPv4::__is_integer($span);
	$span = "$span"; # Force stringification of address or span objects
	my ($start,$mask) = ();
	if (defined($end)) {
    die "Invalid IPv4::Span arguments: '$span', '$end'"
      if ($span =~ m{[-/]});;

    $end = IPv4->address($end)
			if (ref($end) eq "ARRAY" && scalar(@$end) == 4) || IPv4::__is_integer($end);
		$end = "$end";

		if ($end =~ m{^/(\d+)$}) {
			$mask = $1;
			undef($end);
		} elsif ($end =~ m{^(\d+\.\d+\.\d+\.\d+)$}) {
			$end = IPv4->address($end);
		} else {
			die "Invalid IPv4::Span arguments: '$span', '$end'";
		}
	} else {
		($start, $mask, $end) = $span =~ m{^(\d+\.\d+\.\d+\.\d+)(?:(?:/(\d+))|(?:-)(\d+\.\d+\.\d+\.\d+))$};
		$end = IPv4->address($end) if defined($end);
	}

  # not uncoverable statement
	$start = IPv4->address($start ? $start : $span);
	if (defined($mask)) {
    my ($block_start, $block_end) = $start->in_cidr($mask);

    # Check if address is the start of the mask block
    die sprintf(
      "Address %s is not the start of the mask block %s/%d",
      $start->address(),
      $block_start->address(),
      $mask
    ) unless $start->eq($block_start) || $allow_oversized_mask;
		$start = $block_start;
		$end = $block_end;
	} else {
		$end = $start unless defined($end); 
		$mask = 32 if $start eq $end;
	}

	($start, $end) = ($end, $start) if $start gt $end;
	$self->{start} = $start;
	$self->{end} = $end;
	$self->{mask} = $mask;

	return $self;
}

sub clone($self) {
	return ref($self)->new($self->range());
}

sub simplify($self) {
	return $self->size() == 1 ? $self->start : $self;
}

# size() returns the number of addresses in the span - used as numeric representation of this object
sub size($self) {
	return $self->{end}->int() - $self->{start}->int() + 1;
}

sub range($self) {
	return $self->start->address() if $self->start->eq($self->end);
	return sprintf("%s-%s", $self->{start}->address(), $self->{end}->address());
}

sub spans($self) {
	return ($self);
}

sub start($self) {
	return $self->{start};
}

sub end($self) {
	return $self->{end};
}

sub contains($self, $obj) {
	$obj = IPv4::__autovivify($obj);
	return $self->start le $obj->start && $self->end ge $obj->end;
}

sub cmp($self, $other, $swap = 0) {
	my $result = 0;
	$other = IPv4::__autovivify($other);
	$result = $self->start->cmp($other->start) || $self->end->cmp($other->end) || $self->size <=> $other->size;
	return $swap ? -$result : $result;
}

# numeric_cmp() compares the size of the span to the given number or span
sub numeric_cmp($self, $other, $swap = 0) {
	my $other_size = 0;
	if (IPv4::__is_integer($other)) {
		$other_size = $other;
	} else {
		$other = IPv4::__autovivify($other);
		$other_size = $other->size;
	}
	return ($self->size <=> $other_size) * ($swap ? -1 : 1);
}

sub eq($self, $other, $swap = 0) {
	return "$self" eq "$other";
}

sub add($self, $other, $swap = 0) {

	if (IPv4::__is_integer($other)) { 
		die "Cannot add an IPv4::Span object to a number" if $swap;
		return $other > 0
			? ref($self)->new([$self->start->int(), $self->end->int() + $other])
			: ref($self)->new([$self->start->int() + $other, $self->end->int()]);
	}

	$other = IPv4::__autovivify($other);
	return $other->add($self) if $other->isa('IPv4::Range');

	my $ssi = $self->start->int();
	my $sei = $self->end->int();
	my $osi = $other->start->int();
	my $oei = $other->end->int();

  # Return a new range containing both spans if there is no overlap
  return IPv4->range($self,$other) if ($osi-1 > $sei || $oei+1 < $ssi);

	if ($osi >= $ssi) {
		return $self if $oei <= $sei;
		return ref($self)->new(sprintf("%s-%s", $self->start, $other->end));
	} else {
		return $other if $sei <= $oei;
		return ref($self)->new(sprintf("%s-%s", $other->start, $self->end));
	}
}

sub subtract( $self, $other, $swap = 0 ) {

	if ( IPv4::__is_integer($other) ) {
		die "Cannot subtract an IPv4::Span object from a number" if $swap;
		return IPv4->range() if ( abs($other) > $self->size );
		return $other > 0
			? ref($self)->new( [ $self->start->int(), $self->end->int() - $other ] )
			: ref($self)->new( [ $self->start->int() - $other, $self->end->int() ] );
	}

	$other = IPv4::__autovivify($other);
	return $other->subtract($self) if $swap;

	if ($other->isa('IPv4::Range')) {
		my $result = $self->clone();
		$result = $result->subtract($_) for ($other->spans);
		return $result;
	}

	my ($minuend, $subtrahend) = ($self, $other);

	my $msi = $minuend->start->int();
	my $mei = $minuend->end->int();
	my $ssi = $subtrahend->start->int();
	my $sei = $subtrahend->end->int();

	return $minuend if ($ssi > $mei || $sei < $msi);
	return IPv4->range() if ($ssi <= $msi && $sei >= $mei);

	my @remaining = ();
	my ($rsi, $rei);
	if ($ssi <= $msi) {
		$rsi = $subtrahend->end->add(1)->int();
		$rei = $mei;
	} elsif ($sei >= $mei) {
		$rsi = $msi;
		$rei = $subtrahend->start->subtract(1)->int();
	} else {
		$rsi = $msi;
		$rei = $ssi - 1;
		push @remaining, IPv4->span(sprintf("%s-%s", IPv4->address($rsi)->address(), IPv4->address($rei)->address()));
		$rsi = $subtrahend->end->add(1)->int();
		$rei = $mei;
	}
	push @remaining, IPv4->span(sprintf("%s-%s", IPv4->address($rsi)->address(), IPv4->address($rei)->address()));
	return scalar(@remaining) == 1 ? $remaining[0] : IPv4->range(@remaining);
}

# Iterations...
sub next($self) { 
	$self->{next} //= 0;
	return ($self->{next} = undef) unless $self->{next} < $self->size;
	return $self->start + $self->{next}++;
}

sub reset($self) {
	$self->{next} = undef;
}

sub addresses($self) {
	my @ips = ();
	for (my $i = $self->{start}->int(); $i <= $self->{end}->int(); $i++) {
		push @ips, IPv4->address($i);
	}
	return @ips;
}

=head2 slice

Given a size and an optional offset, returns a new span of the given size starting at the offset.  If the offset is negative, the slice will end at the given offset, with the start being the nth address before the end of the span that accommodates the given size.  An offset of -1 will represent the last address in the span.

If there is not enough space in the span to accommodate the requested size and offset, the offset will be maintained, while the size will be reduced to the maximum possible size.
=cut
sub slice($self, $size, $offset = 0) {
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
	return IPv4->range() if ($offset >= $self->size || $size == 0);

	# Calculate the starting and ending addresses of the slice
	my $slice_start = $self->{start} + $offset;
	my $slice_end = $slice_start + $size - 1;
	return IPv4->span([$slice_start, $slice_end]);
}

sub cidrs($self) {
	my @cidrs = ();
	my $min = my $start = $self->{start}->int();
	my $max = my $end = $self->{end}->int();
	my $mask = 32;
	my ($block_start, $block_end);
	while ($start <= $end) {
		my ($last_start, $last_end) = ($block_start, $block_end);
		($block_start, $block_end) = map {$_->int} _cidr_block($start, $mask);
		if ($block_start < $start || $block_end > $end) {
			$mask++;
			push @cidrs, sprintf("%s/%d", IPv4->address($last_start)->address(), $mask);
			$start = $last_end + 1;
			$mask = 32;
		} elsif ($block_end == $end) {
			push @cidrs, sprintf("%s/%d", IPv4->address($block_start)->address(), $mask);
			last;
		} else {
			$mask--;
		}

    # uncoverable branch true - condition shouldn't be possible
		# uncoverable condition left
		# uncoverable condition right
		die sprintf(
			"Error computing CIDR blocks for span '%s'",
			$self
		) if ($mask > 32 || $mask < 0);
	}
	return @cidrs;
}

# Given an address and a mask, return the starting end ending addresses of the
# CIDR block.  Note that the starting address of the block is not necessarily
# the same as the address passed in.
sub _cidr_block($address, $mask) {
	my $start = IPv4->address($address);
	return $start->in_cidr($mask);
}

1;

