package IP4::Range;

use strict;
use warnings;
use v5.20;
use feature 'signatures';
no warnings 'experimental::signatures';

use IP4::Address;

# This class is used to describe a range of SIP addresses.  It can initialized
# with a single address, a CIDR block, a starting address and an ending address,
# a starting address and a mask, or a starting address and a number of addresses.
#
# It can be used to return a list of all addresses in the range in either CIDR
# notation, a list of addresses, or a list of ranges.
sub new($class, $range) { # TODO: Add seconds size argument that can be a count or a /[bits] mask if needed
	my $self = bless {}, $class;

	if (ref($range) eq 'ARRAY') {
		# Array of two IP4::Address objects or two strings
		my $start = ref($range->[0]) eq 'IP4::Address' ? $range->[0] : IP4::Address->new($range->[0]);
		my $end   = ref($range->[1]) eq 'IP4::Address' ? $range->[1] : IP4::Address->new($range->[1]);

		$self->{range} = sprintf("%s-%s", $start->address(), $end->address());
		$self->{start} = $start;
		$self->{end} = $end;
	} elsif ($range =~ m{^(\d+\.\d+\.\d+\.\d+)/(\d+)$}) {
		# CIDR block

		my $mask = $2;
		my $address = IP4::Address->new($1);
		my ($block_start, $block_end) = $address->in_cidr($mask);

		# Check if address is the start of the CIDR block
		if ($address->eq($block_start)) {
			$self->{range} = $address->address() . "/$mask";
			$self->{start} = $block_start;
			$self->{end} = $block_end;
			$self->{mask} = $mask;
		} else {
			# Is there a better way to handle this?
			die "Address `".$address->address."` is not the start of the CIDR block `".$block_start->address."/$mask`";
		}

	# Starting address and ending address
	} elsif ($range =~ m{^(\d+\.\d+\.\d+\.\d+)-(\d+\.\d+\.\d+\.\d+)$}) {
		$self->{range} = $range;
		($self->{start}, $self->{end}) = sort {$a->cmp($b)} (IP4::Address->new($1), IP4::Address->new($2));
		# Can/should we compute the mask here?  What if it crosses CIDR boundaries?  Can we do a list of cidr blocks?

	# Single address
	} elsif ($range =~ m{^(\d+\.\d+\.\d+\.\d+)$}) {
		$self->{range} = $range;
		$self->{start} = IP4::Address->new($range);
		$self->{end} = $self->{start};
		$self->{mask} = 32;

	# Host and mask
	} elsif ($range =~ m{^([a-zA-Z0-9\.-]+)/(\d+)$}) {
		# Support for multi-address hosts?
		my $address = IP4::Address->new($1);
		# Check if address is the start of the CIDR block
		$self->{range} = $address->address() . "/$2";
		$self->{start} = $address;
		$self->{end} = $self->{start}->add($2 - 1);
		$self->{mask} = $2;
	} else {
		require Genesis;
		Genesis::bail("Invalid range: `$range`");
	}
	return $self;
}

sub size($self) {
	return $self->{end}->int() - $self->{start}->int() + 1;
}
sub count($self) {
	return $self->size();
}

sub range($self) {
	return $self->start->address() if $self->start->eq($self->end);
	return sprintf("%s-%s", $self->{start}->address(), $self->{end}->address());
}

sub start($self) {
	return $self->{start};
}

sub end($self) {
	return $self->{end};
}

sub add($self, $other){
	my $ssi = $self->start->int();
	my $sei = $self->end->int();
	$other = IP4::Range->new($other) unless ref $other eq 'IP4::Range';
	my $osi = $other->start->int();
	my $oei = $other->end->int();

	my @sum = ();
	if ($osi <= $ssi && $oei >= $sei) {
		push @sum, $other;
	} elsif ($osi <= $ssi && $oei < $sei) {
		push @sum, IP4::Range->new(sprintf("%s-%s", $other->{start}->address(), $self->{end}->address()));
	} elsif ($osi > $ssi && $oei >= $sei) {
		push @sum, IP4::Range->new(sprintf("%s-%s", $self->{start}->address(), $other->{end}->address()));
	} else {
		push @sum, $self, $other;
	}
	return scalar(@sum) == 1 ? $sum[0] : IP4::MultiRange->new(@sum);
}

sub subtract($self, $other){
	return IP4::MultiRange->new($self)->subtract($other) if ref $other eq 'IP4::MultiRange';

	my $ssi = $self->start->int();
	my $sei = $self->end->int();
	$other = IP4::Range->new($other) unless ref $other eq 'IP4::Range';
	my $osi = $other->start->int();
	my $oei = $other->end->int();

	return $self if ($osi > $sei || $oei < $ssi);
	my @remaining = ();
	my ($nsi, $nei);
	if ($osi <= $ssi && $oei >= $sei) {
		return undef;
	} elsif ($osi <= $ssi && $oei < $sei) {
		$nsi = $other->{end}->add(1)->int();
		$nei = $sei;
	} elsif ($osi > $ssi && $oei >= $sei) {
		$nsi = $ssi;
		$nei = $other->{start}->subtract(1)->int();
	} else {
		$nsi = $ssi;
		$nei = $osi - 1;
		push @remaining, IP4::Range->new(sprintf("%s-%s", IP4::Address->new($nsi)->address(), IP4::Address->new($nei)->address()));
		$nsi = $other->{end}->add(1)->int();
		$nei = $sei;
	}
	push @remaining, IP4::Range->new(sprintf("%s-%s", IP4::Address->new($nsi)->address(), IP4::Address->new($nei)->address()));
	return scalar(@remaining) == 1 ? $remaining[0] : IP4::MultiRange->new(@remaining);
	
}

sub first($self, $count = 1) {
	return IP4::Range->new($self->{start}->address()) if $count == 1;
	return IP4::Range->new(sprintf("%s-%s", $self->{start}->address(), IP4::Address->new($self->{start}->int() + $count - 1)->address()));
}

sub last($self, $count = 1) {
	return IP4::Range->new($self->{end}->address()) if $count == 1;
	return IP4::Range->new(sprintf("%s-%s", IP4::Address->new($self->{end}->int() - $count + 1)->address(), $self->{end}->address()));
}

sub addresses($self) {
	my @ips = ();
	for (my $i = $self->{start}->int(); $i <= $self->{end}->int(); $i++) {
		push @ips, IP4::Address->new($i);
	}
	return @ips;
}

sub slice($self, $size, $offset = 0) {
	if ($size + $offset > $self->size) {
		my $slice = IP4::Range->new([$self->start->add($offset)->address, $self->end->address]);
		return ($slice, $size - $slice->size, $self->subtract($slice));
	}
	my $slice = IP4::Range->new([$self->start->add($offset)->address, $self->start->add($offset + $size - 1)->address]);
	return ($slice, 0, $self->subtract($slice));
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
			push @cidrs, sprintf("%s/%d", IP4::Address->new($last_start)->address(), $mask);
			$start = $last_end + 1;
			$mask = 32;
		} elsif ($block_end == $end) {
			push @cidrs, sprintf("%s/%d", IP4::Address->new($block_start)->address(), $mask);
			last;
		} else {
			$mask--;
		}
 		if ($mask > 32 || $mask < 0) {
			die "Error computing CIDR blocks for range `$self->{range}`";
		}
	}
	return @cidrs;
}

# Given an address and a mask, return the starting end ending addresses of the
# CIDR block.  Note that the starting address of the block is not necessarily
# the same as the address passed in.
sub _cidr_block($address, $mask) {
	my $start = IP4::Address->new($address);
	return $start->in_cidr($mask);
}

1;

