package IPv4::Address;

use v5.20;
use feature 'signatures';
no warnings 'experimental::signatures';

use base 'IPv4';

use Socket;

use overload 
	'""'  => sub { shift->range() },
	'0+'  => sub { shift->size() },
	'<=>' => 'numeric_cmp',
	'cmp' => 'cmp',
	'-'   => '__minus',
	'+'   => '__plus',
	'='   => 'clone',
  '<>'	=> sub { shift->next() },
	'@{}' => sub { [shift] };

# Constructors

sub new($class, $address) {
	my $self = bless {}, $class;
	if (ref($address) eq 'ARRAY') {
		if (scalar(@$address) == 4 && scalar(grep {$_ =~ /^\d+/ && $_ <= 255} @$address) == 4) {
			$self->{address} = join '.', @$address;
			$self->{octets} = [@$address];
		} else {
			die "Invalid address array; expected 4 octets, got [@$address]";
		}
	} elsif ($address =~ m{^(\d+)\.(\d+)\.(\d+)\.(\d+)$}) {
    $self->{octets} = [ $1, $2, $3, $4 ];
		die "Invalid address: '$address'" if grep { $_ > 255 } @{$self->{octets}}; # can't be negative because of the regex
		$self->{address} = $address;
	} elsif ($address =~ m{^\d+$}) {
		$self->{address} = join '.', map { ($address >> (8 * (3 - $_))) & 0xFF } 0 .. 3;
		$self->{octets} = [ map { ($address >> (8 * (3 - $_))) & 0xFF } 0 .. 3 ];
	} else {
		my @addresses = gethostbyname($address);
		if (@addresses) {
			$self->{address} = inet_ntoa($addresses[4]);
			$self->{octets} = [ split /\./, $self->{address} ];
			$self->{host} = $address;
		} else {
			die "Invalid address: '$address'";
		}
	}
	return $self;
}

sub all_for_host($class, $host) {
	my @addresses = gethostbyname($host);
  die "Invalid host: `$host`" if (!@addresses);
	@addresses = map { inet_ntoa($_) } @addresses[4 .. $#addresses];
	my @host_addresses =  map { my $a = $class->new($_); $a->{host} = $host; $a } @addresses;
	return wantarray ? @host_addresses : \@host_addresses;
}

# Address-specific methods

sub address($self) {
	return $self->{address};
}

sub int($self) {
  return unpack('N', inet_aton($self->{address}));
}

sub octets($self) {
	return @{$self->{octets}};
}

sub hostname($self) {
	return 'localhost' if $self->{address} eq '127.0.0.1';
	return $self->{host} // gethostbyaddr(inet_aton($self->{address}), AF_INET);
}

sub in_cidr($self, $mask) {
  my $block_start = $self->int() & (0xFFFFFFFF << (32 - $mask));
  my $block_end = $block_start + (2 ** (32 - $mask) - 1);
  return (ref($self)->new($block_start), ref($self)->new($block_end));
}

sub diff($self, $other) {

	die "Cannot diff an address with an integer - did you mean to call `->subtract`?" if IPv4::__is_integer($other);
  return $self->__minus(IPv4::__autovivify($other), 0);
}

sub to($self, $other) {
  $other = ref($other) eq 'IPv4::Address' ? $other : IPv4::Address->new($other);
  require IPv4::Span;
  return IPv4::Span->new([$self, $other]);
}

# Common methods for all IPv4 objects

sub clone($self) {
  return ref($self)->new($self->{address});
}

sub simplify($self) {
	return $self;
}

sub range($self) {
  return $self->{address};
}

sub start($self) {
	return $self;
}

sub end($self) {
	return $self;
}

sub size($self) {
	return 1;
}

sub addresses($self) {
	return ($self);
}

sub spans($self) {
	return (IPv4->span($self));
}

sub next($self) { 
  $self->{next} //= 0;
  return ($self->{next} = undef) unless $self->{next} < $self->size;
  return $self->start + $self->{next}++;
}

sub reset($self) {
  $self->{next} = undef;
}

sub contains($self, $address) {
	return IPv4->span($self)->contains(IPv4::__autovivify($address));
}

sub add($self, $count) {
	return $self->__plus($count, 0);
}

sub subtract($self, $count) {
	return $self->__minus($count, 0);
}

sub cmp($self, $other, $swap=0) {
	$other = IPv4::__autovivify($other);
	my $r = $self->start->int <=> $other->start->int || $self->size <=> $other->size;
	return $swap ? -$r : $r;
}

sub eq($self, $other) {
	return $self->cmp($other) == 0;
}

sub numeric_cmp($self, $other, $swap=0) {
	$other = IPv4::__autovivify($other) unless IPv4::__is_integer($other);
	my $r = $self->size <=> CORE::int($other);
	return $swap ? -$r : $r;
}

sub __minus($self, $other, $swap=0) {
	if (IPv4::__is_integer($other)) {
		die "Cannot subtract an address from an integer" if $swap;
    die sprintf(
			"IPv4 Address space underflow when subtracting %d from %s",
			$other,
			$self->range()
		) if $other > $self->int();
		return ref($self)->new($self->int() - $other);
	}

	$other = IPv4::__autovivify($other);
	return $self->int() - $other->int();
}

sub __plus($self, $other, $swap=0) {

	if (IPv4::__is_integer($other)) {
		die "Cannot add an address to an integer" if $swap;
		die sprintf(
			"IPv4 Address space overflow when adding %d to %s",
			$other,
			$self->range()
		) if $other + $self->int() > 0xFFFFFFFF;
		return ref($self)->new($self->int() + $other);
	}

	$other = IPv4::__autovivify($other);
	return $other->add($self)	if (ref($other) =~ /^IPv4::(Span|Range)$/);
	return IPv4->range($self, $other)->simplify();
}

1;
