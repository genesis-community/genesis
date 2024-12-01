package IP4::Address;

use strict;
use warnings;
use v5.20;
use feature 'signatures';
no warnings 'experimental::signatures';

use Socket;

sub new($class, $address) {
	my $self = bless {}, $class;
	if ($address =~ m{^\d+$}) {
		$self->{address} = join '.', map { ($address >> (8 * (3 - $_))) & 0xFF } 0 .. 3;
		$self->{octets} = [ map { ($address >> (8 * (3 - $_))) & 0xFF } 0 .. 3 ];
	} elsif ($address =~ m{^(\d+)\.(\d+)\.(\d+)\.(\d+)$}) {
		$self->{address} = $address;
		$self->{octets} = [ $1, $2, $3, $4 ];
	} else {
		my @addresses = gethostbyname($address);
		if (@addresses) {
			$self->{address} = inet_ntoa($addresses[4]);
			$self->{octets} = [ split /\./, $self->{address} ];
			$self->{host} = $address;
		} else {
			die "Invalid address: `$address`";
		}
	}
	return $self;
}

sub all_for_host($class, $host) {
	my @addresses = gethostbyname($host);
	if (!@addresses) {
		die "Invalid host: `$host`";
	}
	@addresses = map { inet_ntoa($_) } @addresses[4 .. $#addresses];
	my @host_addresses =  map { my $a = $class->new($_); $a->{host} = $host; $a } @addresses;
	return wantarray ? @host_addresses : \@host_addresses;
}

sub hostname($self) {
	return $self->{host} // gethostbyaddr(inet_aton($self->{address}), AF_INET);
}

sub address($self) {
	return $self->{address};
}

sub octets($self) {
	return @{$self->{octets}};
}

sub int($self) {
	return unpack('N', inet_aton($self->{address}));
}

sub in_cidr($self, $mask) {
	my $block_start = $self->int() & (0xFFFFFFFF << (32 - $mask));
	my $block_end = $block_start + (2 ** (32 - $mask) - 1);
	return (IP4::Address->new($block_start), IP4::Address->new($block_end));
}

sub add($self, $count) {
	return IP4::Address->new($self->int() + $count);
}

sub subtract($self, $count) {
	return IP4::Address->new($self->int() - $count);
}

sub diff($self, $other) {
	return $self->int() - $other->int();
}

sub cmp($self, $other) {
	return $self->int() <=> $other->int();
}

sub eq($self, $other) {
	return $self->int() == $other->int();
}

sub to($self, $other) {
	$other = ref($other) eq 'IP4::Address' ? $self : IP4::Address->new($other);
	require IP4::Range;
	return IP4::Range->new([$self, $other]);
}

1;
