use strict;
use warnings;

use lib 'lib';

use Test::More;
use Test::Exception;
require_ok "IPv4";
require_ok "IPv4::Address";
require_ok "IPv4::Span";
require_ok "IPv4::Range";

# Test IPv4->new
subtest 'IPv4' => sub {
  plan tests => 4;
  subtest 'new constructor' => sub {
    plan tests => 16;

    my $range = IPv4->new('192.168.0.1-192.168.0.15,192.168.11.8,192.168.24.0/27');
    isa_ok($range, 'IPv4::Range', 'IPv4->new returns IPv4::Range object');
    is($range->size, 48, 'IPv4->new returns correct size');

    my $span = IPv4->new('192.168.0.1/24');
    isa_ok($span, 'IPv4::Span', 'IPv4->new returns IPv4::Span object');
    is($span->size, 256, 'IPv4->new returns correct size');

    my $address = IPv4->new('10.0.0.10');
    isa_ok($address, 'IPv4::Address', 'IPv4->new returns IPv4::Address object');
    is($address->size, 1, 'IPv4->new returns correct size');

    my $address2 = IPv4->new($address);
    isa_ok($address2, 'IPv4::Address', 'IPv4->new returns IPv4::Address object');
    is($address2, '10.0.0.10', 'IPv4->new returns correct address when based on another address');

    my $range2 = IPv4::new($range,$address);
    isa_ok($range2, 'IPv4::Range', 'IPv4->new returns IPv4::Range object (non-class method)');
    is($range2->size, 49, 'IPv4->new returns correct size when based on another range');

    my $empty = IPv4::new();
    isa_ok($empty, 'IPv4::Range', 'IPv4->new returns IPv4::Range object when no arguments are provided (non-class method)');
    is($empty->size, 0, 'IPv4->new returns empty range when no arguments are provided');

    my $address3 = IPv4::new('localhost');
    isa_ok($address3, 'IPv4::Address', 'IPv4->new returns IPv4::Address object when hostname is provided (non-class method)');
    is($address3->range, '127.0.0.1', 'IPv4->new returns correct address when hostname is provided');

    dies_ok { IPv4->new('123.456.789.0') } 'IPv4->new with invalid address dies';
    like($@, qr/Invalid address: '123.456.789.0'/i, 'IPv4->new with invalid address dies with correct message');

  };

  # Test IPv4->address
  subtest 'IPv4->address factory' => sub {
    plan tests => 1;
    my $address = IPv4->address('192.168.0.1');
    isa_ok($address, 'IPv4::Address', 'IPv4->address returns IPv4::Address object');
  };

  # Test IPv4->span
  subtest 'IPv4->span factory' => sub {
    plan tests => 1;
    my $span = IPv4->span('192.168.0.1-192.168.0.10');
    isa_ok($span, 'IPv4::Span', 'IPv4->span returns IPv4::Span object');
  };

  # Test IPv4->range
  subtest 'IPv4->range factory' => sub {
    plan tests => 1;
    my $range = IPv4->range('192.168.0.1/24,192.168.3.1/24');
    isa_ok($range, 'IPv4::Range', 'IPv4->range returns IPv4::Range object');
  };
};

subtest 'IPv4::Address' => sub {
  plan tests => 5;
  subtest 'new constructor' => sub {
    plan tests => 25;
    # Test new constructor with integer input
    my $ip1 = IPv4::Address->new(3232235777); # 192.168.1.1
    is($ip1->{address}, '192.168.1.1', 'new() with integer input');
    is($ip1->int, 3232235777, 'new() with dotted decimal input - int');
    is_deeply($ip1->{octets}, [192, 168, 1, 1], 'new() with integer input - octets');

    # Test new constructor with dotted decimal input
    my $ip2 = IPv4::Address->new('192.168.1.1');
    is($ip2->{address}, '192.168.1.1', 'new() with dotted decimal input');
    is($ip2->int, 3232235777, 'new() with dotted decimal input - int');
    is_deeply($ip2->{octets}, [192, 168, 1, 1], 'new() with dotted decimal input - octets');

    # Test new constructor with hostname input
    my $ip3 = IPv4::Address->new('localhost');
    is($ip3->{address}, '127.0.0.1', 'new() with hostname input');
    is($ip3->int, 2130706433, 'new() with hostname input - int');
    is_deeply($ip3->{octets}, [127, 0, 0, 1], 'new() with hostname input - octets');
    is($ip3->{host}, 'localhost', 'new() with hostname input - host');

    dies_ok { IPv4::Address->new('invalid.hostname') } 'new() with invalid hostname dies';
    like($@, qr/invalid address: 'invalid.hostname'/i, 'new() with invalid hostname dies with correct message');

    my $localhost = IPv4::Address->new('localhost');
    is($localhost->range, '127.0.0.1', "new() with 'localhost' hostname input sets correct address");
    is(IPv4::Address->new("$localhost")->hostname, 'localhost', "IPv4::Address set to '127.0.0.1' returns 'localhost' as hostname");


    ok(! defined(IPv4::Address->new('192.168.90.1')->hostname), 'new() with dotted decimal input does not set host');
    
    my $ip4 = IPv4::Address->new([192,168,0,1]);
    isa_ok($ip4, 'IPv4::Address', 'IPv4->new returns IPv4::Address object when array of octets is provided (non-class method)'); 

    dies_ok { IPv4::Address->new([192,168,0]) } 'new() with invalid octets array dies';
    like($@, qr/invalid address array; expected 4 octets, got \[192 168 0\]/i, 'new() with invalid octets array dies with correct message');

    dies_ok { IPv4::Address->new([12,34,56,78,-56,999]) } 'IPv4->new with invalid octets array dies';
    like($@, qr/invalid address array; expected 4 octets/i, 'IPv4->new with invalid octets array dies with correct message');

    dies_ok { IPv4::Address->new([12,34,-56,999]) } 'IPv4->new with invalid octets array dies';
    like($@, qr/invalid address array; expected 4 octets/i, 'IPv4->new with invalid octets array dies with correct message');

    my $ip5 = $ip4->clone();
    cmp_ok($ip5, 'eq', $ip4, 'clone() returns identical address');
    $ip5 += 4;
    cmp_ok($ip5, 'gt', $ip4, 'clone() returns different address when modified');
    is("$ip5", '192.168.0.5', 'clone() returns correct address when modified');
  };

  subtest 'information methods' => sub {
    plan tests => 24;
    my $ip = IPv4::Address->new('192.168.1.1');
    my @octets = $ip->octets();
    is_deeply(\@octets, [192, 168, 1, 1], 'octets() returns correct octets array');

    $ip = IPv4::Address->new('10.0.0.1') + 256;
    @octets = $ip->octets();
    is_deeply(\@octets, [10, 0, 1, 1], 'octets() returns correct octets array for an address that has been modified');

    my $int = $ip->int();
    is($int, 167772417, 'int() returns correct integer value');

    my $address = $ip->range();
    is($address, '10.0.1.1', 'address() returns correct dotted decimal address');

    my $span = IPv4::Span->new('192.168.1.1', '192.168.1.10');
    $address = IPv4::Address->new('192.168.1.1');
    ok($span->contains($address), 'contains() returns true for address that matches the start of the span');
    is($span->cmp($address), '1', 'cmp() returns 1 for address that shares the start of the span, but the span has more addresses');
    is($address->cmp($span), '-1', 'cmp() returns -1 for address that shares the start of the span, but the span has more addresses (swapped positions)');
    is($address ne $span, 1, 'overloaded `ne` operator returns true when span and address start with the same IP address');
    $span -= 9;
    is($address eq $span, 1, 'overloaded `eq` operator returns true when span and address start with the same IP address and the span only contains the address');

    # Test addresses method
    $ip = IPv4::Address->new('172.16.24.1');
    my @addresses = $ip->addresses();
    is(scalar @addresses, 1, 'addresses() returns single address');
    is($addresses[0]->range, '172.16.24.1', 'addresses() returns correct address');

    # Test spans method
    my @spans = $ip->spans();
    is(scalar @spans, 1, 'spans() returns single span');
    isa_ok($spans[0], 'IPv4::Span', 'spans() returns IPv4::Span object');
    is($spans[0]->range, '172.16.24.1', 'spans() returns correct span');

    # Test next and reset methods
    my $next = $ip->next();
    is($next->range, '172.16.24.1', 'next() returns correct first address');
    $next = $ip->next();
    is($next, undef, 'next() returns undef after exhausting addresses');
    
    $ip->next();
    $ip->reset();
    $next = $ip->next();
    is($next->range, '172.16.24.1', 'next() returns correct address after reset');

    @addresses = ();
    $ip->reset();
    push @addresses, "$_" while <$ip>;
    is_deeply(\@addresses, ['172.16.24.1'], 'overloaded <> operator iterates over single address');

    # Test contains method
    ok($ip->contains('172.16.24.1'), 'contains() returns true for same address (string)');
    ok($ip->contains($ip), 'contains() returns true for same address (object)');
    ok(!$ip->contains('172.16.24.2'), 'contains() returns false for different address');
    ok($ip->contains(IPv4::Span->new('172.16.24.1')), 'contains() returns true for span of same address');
    ok(!$ip->contains(IPv4::Span->new('172.16.24.1-172.16.24.2')), 'contains() returns false for span larger than single address');
    ok(IPv4::Span->new('172.16.24.1-172.16.24.2')->contains($ip),'contains() returns true for a span that contains the address (swap of previous test)');
  };

  # Test calculation methods
  subtest 'calculation methods' => sub {
    plan tests => 36;
    my $ip1 = IPv4::Address->new(3232235777); # 192.168.1.1
    is($ip1->add(256)->range, '192.168.2.1', 'add() adds correct number of addresses');
    is($ip1->subtract(258)->range, '192.167.255.255', 'subtract() subtracts correct number of addresses');

    my $ip2 = IPv4::Address->new(3232235789); # 192.168.1.13
    is($ip2->diff($ip1), 12, 'diff() returns correct difference');
    dies_ok { $ip1->diff(4) } 'diff() with non-IPv4::Address dies';
    like($@, qr/Cannot diff an address with an integer/i, 'diff() with non-IPv4::Address dies with correct message');

    is($ip1->cmp($ip2), -1, 'cmp() returns correct comparison result');
    is($ip1->cmp('192.168.0.0'), 1, 'cmp() returns correct comparison result (string)');
    is('192.168.0.0' cmp $ip1, -1, 'overloaded cmp returns correct comparison result (string - swapped positions)');
    is($ip1->eq($ip2), '', 'eq() returns false for different addresses');
    is($ip1->eq($ip1), 1, 'eq() returns true for equal addresses');
    is($ip1->eq('192.168.1.0'), '', 'eq() returns false for different addresses (string)');
    is($ip1->eq('192.168.1.1'), 1, 'eq() returns true for equal addresses (string)');
    ok($ip1->eq(IPv4->range('192.168.1.1')), 'eq() returns true for different object types with equivalent value');
    dies_ok {$ip1 ne $ip1->int} 'overloaded `ne` operator with integer-equivalent address dies';
    like($@, qr/Invalid IPv4 literal or object '3232235777'/i, 'overloaded `ne` operator with integer-equivalent address dies with correct message');
    ok($ip1 ne '192.168.1.2', 'overloaded `ne` operator returns true for different addresses');
    
    my ($start, $end) = $ip2->in_cidr(16);
    is($start->range, '192.168.0.0', 'in_cidr() returns correct start address');
    is($end->address, '192.168.255.255', 'in_cidr() returns correct end address');

    my $range = $ip2->to($ip1);
    isa_ok($range, 'IPv4::Span', 'to() returns an IPv4::Span object');
    is($range->range, '192.168.1.1-192.168.1.13', 'to() returns correct range in smallest to largest order');

    $range = $ip2->to($ip1->address);
    isa_ok($range, 'IPv4::Span', 'to() returns an IPv4::Span object');
    is($range->range, '192.168.1.1-192.168.1.13', 'to() returns correct range in smallest to largest order (string)');

    my $span = $ip2->to($ip2+10);
    $range = $ip1->__plus($span,1);
    isa_ok($range, 'IPv4::Range', 'overloaded + operator returns IPv4::Range object when adding an address to a span');
    is($range->range, '192.168.1.1,192.168.1.13-192.168.1.23', 'overloaded + operator returns correct range when adding an address to a span');
    $range = $ip1 + $span;
    isa_ok($range, 'IPv4::Range', 'overloaded + operator returns IPv4::Range object when adding a span to an address');
    is($range->range, '192.168.1.1,192.168.1.13-192.168.1.23', 'overloaded + operator returns correct range when adding an address to a span');

    $range = $ip1 + $ip2;
    isa_ok($range, 'IPv4::Range', 'overloaded + operator returns IPv4::Range object when adding two addresses');
    is($range->range, '192.168.1.1,192.168.1.13', 'overloaded + operator returns correct range when adding two addresses');

    $range = $ip1 + '192.168.1.2';
    isa_ok($range, 'IPv4::Span', 'overloaded + operator returns IPv4::Span object when adding the next address as a string to a single address');
    is($range->range, '192.168.1.1-192.168.1.2', 'overloaded + operator returns correct range when adding the next address as a string to a single address');

    # Overflow and underflow tests
    dies_ok { IPv4::Address->new('255.255.255.1') + 256} 'add() with overflow dies';
    like($@, qr/IPv4 Address space overflow when adding 256 to 255.255.255.1/i, 'add() with overflow dies with correct message');
    dies_ok { IPv4::Address->new([0,0,0,5]) - 10 } 'subtract() with underflow dies';
    like($@, qr/IPv4 Address space underflow when subtracting 10 from 0.0.0.5/i, 'subtract() with underflow dies with correct message');

    # Autovivification tests not implicitly covered by other tests
    my $ip3 = IPv4::Address->new('1.2.3.4');
    dies_ok { $ip3->subtract('invalid') } 'subtract() with invalid argument dies';

    use JSON::PP;
    dies_ok { $ip3->add(JSON::PP::true) } 'add() with an incompatible object dies';

  };

  # Test overloaded operators
  subtest 'overloaded operators' => sub {
    plan tests => 23;
    my $ip1 = IPv4::Address->new(3232235777);
    my $ip2 = IPv4::Address->new(3232235789);

    is_deeply([@$ip1], ['192.168.1.1'], 'overloaded @{} operator returns single address array reference');

    is($ip1 - $ip2, -12, 'overloaded - operator returns correct difference');
    is(ref($ip1 - 12), 'IPv4::Address', 'overloaded - operator returns IPv4::Address object');
    is(($ip2 - 12).'', '192.168.1.1', 'overloaded - operator returns correct address (via stringification)');

    is(ref($ip1 + 256), 'IPv4::Address', 'overloaded + operator returns IPv4::Address object');
    is(($ip1 + 256).'', '192.168.2.1', 'overloaded + operator returns correct address (via stringification)');

    is(ref($ip1 + $ip2), 'IPv4::Range', 'overloaded + operator returns IPv4::Range object when adding two addresses');

    my $range = $ip1->to($ip1+256);
    is(ref($range - $ip1), 'IPv4::Span', 'overloaded - operator returns IPv4::Span object when subtracting the first address from the range');
    is(($range - $ip1)->range, '192.168.1.2-192.168.2.1', 'overloaded - operator returns correct range when subtracting the first address from the range');

    is(ref($range - $ip2), 'IPv4::Range', 'overloaded - operator returns IPv4::Range object when subtracting the first address from the range');
    is(($range - $ip2)->range, '192.168.1.1-192.168.1.12,192.168.1.14-192.168.2.1', 'overloaded - operator returns correct range when subtracting the first address from the range');

    dies_ok { 4 - $ip1 } 'overloaded - operator with non-IPv4::Address dies';
    like($@, qr/Cannot subtract an address from an integer/i, 'overloaded - operator with non-IPv4::Address dies with correct message');

    dies_ok { 4 + $ip1 } 'overloaded + operator with non-IPv4::Address dies';
    like($@, qr/Cannot add an address to an integer/i, 'overloaded + operator with non-IPv4::Address dies with correct message');

    cmp_ok($ip1 + 12, 'eq', $ip2, 'overloaded eq operator returns true for equal addresses');
    cmp_ok($ip1, 'ne', $ip2, 'overloaded ne operator returns false for different addresses');
    cmp_ok($ip1, 'lt', $ip2, 'overloaded lt operator returns true for lesser address');
    cmp_ok($ip1, '==', 1, 'overloaded == operator returns true for integer size comparison');

    cmp_ok('192.168.1.4', '==', $ip1, 'overloaded == operator returns true for size (string)');
    cmp_ok('192.168.1.4', 'eq', $ip1+3, 'overloaded == operator returns true for same address (string)'); cmp_ok('192.168.1.2', 'gt', $ip1, 'overloaded gt operator returns true for greater address (string)');

    my $ip4 = $ip1;
    $ip4++;
    cmp_ok($ip4, 'eq', $ip1+1, 'overloaded eq operator returns true after incrementing a clone of an address');

  };

  # Test all_for_host method
  subtest 'all_for_host method' => sub {
    plan tests => 8;
    my @ips = IPv4::Address->all_for_host('localhost');
    is(scalar @ips, 1, 'all_for_host() returns correct number of addresses');
    is($ips[0]->address, '127.0.0.1', 'all_for_host() returns correct address');

    @ips = IPv4::Address->all_for_host('amazon.com');
    cmp_ok(scalar @ips, '>', 1, 'all_for_host() returns correct number of addresses');

    my $host = $ips[0]->hostname;
    is($host, 'amazon.com', 'all_for_host() returns correct hostname');

    my $ip = IPv4::Address->new(IPv4::Address->new('wikimedia.org')->address);
    like($ip->hostname, qr/wikimedia.org$/, 'hostname() returns correct hostname using lookup');

    my $ipref = IPv4::Address->all_for_host('amazon.com');
    is(ref($ipref), 'ARRAY', 'all_for_host() returns array reference');
    cmp_ok(scalar @$ipref, '>', 1, 'all_for_host() returns correct number of addresses');

    dies_ok { IPv4::Address->all_for_host('invalid.hostname') } 'all_for_host() with invalid hostname dies';
  };
};


subtest 'IPv4::Span' => sub {
  plan tests => 13;
  subtest 'new constructor' => sub {
    plan tests => 30;
    my $span1 = IPv4::Span->new('192.168.1.1-192.168.1.10');
    isa_ok($span1, 'IPv4::Span', 'new() creates an IPv4::Span object using range string');
    is($span1->start->address, '192.168.1.1', 'new() using range string sets correct start address');
    is($span1->end->address, '192.168.1.10', 'new() using range string sets correct end address');
    is($span1->size, 10, 'new() using range string sets correct size');

    my $span2 = IPv4::Span->new('192.168.0.0/28');
    isa_ok($span2, 'IPv4::Span', 'new() creates an IPv4::Span object using ip/mask');
    is($span2->start->address, '192.168.0.0', 'new() using ip/mask sets correct start address');
    is($span2->end->address, '192.168.0.15', 'new() using ip/mask sets correct end address');
    is($span2->size, 16, 'new() using ip/mask sets correct size');

    my $span3 = IPv4::Span->new(IPv4::Address->new('127.0.0.1'));
    isa_ok($span3, 'IPv4::Span', 'new() creates an IPv4::Span object using single address');
    is($span3->start->address, '127.0.0.1', 'new() using single address sets correct start address');
    is($span3->end->address, '127.0.0.1', 'new() using single address sets correct end address');
    is($span3->size, 1, 'new() using single address sets correct size');

    my $span4 = IPv4::Span->new(['192.168.24.24', '192.168.12.12']);
    isa_ok($span4, 'IPv4::Span', 'new() creates an IPv4::Span object using array of addresses');
    is($span4->start->address, '192.168.12.12', 'new() using array of addresses sets correct start address');
    is($span4->end->address, '192.168.24.24', 'new() using array of addresses sets correct end address');
    is(int($span4), 12*256+13, 'new() using array of addresses sets correct size (integer context)');

    my $span5 = IPv4::Span->new([192, 168, 1, 1], [192, 168, 1, 10]);
    isa_ok($span5, 'IPv4::Span', 'new() creates an IPv4::Span object using array of octets');
    is($span5->range, '192.168.1.1-192.168.1.10', 'new() using array of octets sets correct range');

    my $span6 = IPv4::Span->new([3232235782, [192, 168, 1, 1]]);
    isa_ok($span6, 'IPv4::Span', 'new() creates an IPv4::Span object using mixed array of integers and octets');
    is($span6->range, '192.168.1.1-192.168.1.6', 'new() using mixed array of integers and octets sets correct range');

    my $span7 = IPv4::Span->new(3232235790, '/24');
    isa_ok($span7, 'IPv4::Span', 'new() creates an IPv4::Span object using integer and mask');
    is($span7->range, '192.168.1.0-192.168.1.255', 'new() using integer and mask sets correct range');

    # Invalid combinations of arguments
    dies_ok { IPv4::Span->new('10.0.0.0/24','10.0.1.0/24') } 'new() with multiple CIDR blocks dies';
    like($@, qr/Invalid IPv4::Span arguments: '10.0.0.0\/24', '10.0.1.0\/24'/i, 'new() with multiple CIDR blocks dies with correct message');

    dies_ok { IPv4::Span->new(['192.168.0.1','192.168.0.10'],'192.168.0.11') } 'new() with multiple ranges dies';
    like($@, qr/Invalid mix of arguments - array and end value/i, 'new() with multiple ranges dies with correct message');

    dies_ok { IPv4::Span->new([192,168,0], [192,169,0]) } 'new() with invalid octets array dies';
    like($@, qr/Invalid IPv4::Span arguments: /i, 'new() with invalid octets array dies with correct message');

    {
      no warnings 'once';
      local $IPv4::Span::allow_oversized_mask = 0;
      dies_ok { IPv4::Span->new('192.168.1.1/24') } 'new() with oversized mask dies';
      like($@, qr/Address 192.168.1.1 is not the start of the mask block 192.168.1.0\/24/i, 'new() with oversized mask dies with correct message');
    }
  };

  subtest 'range method' => sub {
    plan tests => 2;
    my $span = IPv4::Span->new('192.168.1.1', '192.168.1.10');
    is($span->range, '192.168.1.1-192.168.1.10', 'range() returns correct range');
    is($span.'' eq $span->range, 1, 'stringification returns same value as range()');
  };

  subtest 'size method' => sub {
    plan tests => 2;
    my $span = IPv4::Span->new('192.168.1.1', '192.168.1.10');
    is($span->size, 10, 'size() returns correct size');
    ok($span == 10, 'numeric context returns correct size');
  };

  subtest 'clone method' => sub {
    plan tests => 4;
    my $span1 = IPv4::Span->new('192.168.1.1', '192.168.1.5');
    my $span2 = $span1->clone();
    is($span2->range, '192.168.1.1-192.168.1.5', 'clone() returns correct cloned span');

    # This tests the clone on assignment overload -- it does not create a new object on assignment, so if the original object is altered directly through manipuating internal properties, the cloned object will also be altered until the cloned object is modified through an assignment operation.  Similarly, if the cloned object is modified, it will modify the original object.

    my $span4 = my $span3 = $span1;
    is($span4->range, '192.168.1.1-192.168.1.5', 'clone operator returns correct cloned span');

    $span4++;
    cmp_ok($span4, '!=', $span3, 'cloned span is not the same as the original span after being modified (clone on assignment)');
    $span1--;
    cmp_ok($span1, '!=', $span3, 'cloned span is not equal to the original span after original span is modified (clone on assignment)');
  };

  subtest 'subtract method' => sub {
    plan tests => 32;
    my $span1 = IPv4::Span->new('192.168.1.1', '192.168.1.10');
    my $span2 = IPv4::Span->new('192.168.1.5', '192.168.1.7');
    my $result = $span1->subtract($span2);
    isa_ok($result, 'IPv4::Range', 'subtract() returns IPv4::Range object when gaps in range due to subtraction');
    is(scalar $result->spans, 2, 'subtract() returns correct number of spans');
    is(($result->spans)[0]->range, '192.168.1.1-192.168.1.4', 'subtract() returns correct first span');
    is(($result->spans)[1]->range, '192.168.1.8-192.168.1.10', 'subtract() returns correct second span');

    $result = $span1->subtract('192.168.1.10');
    isa_ok($result, 'IPv4::Span', 'subtract() returns IPv4::Span object when subtracting a single address (string) from the end of the span');
    is($result->range, '192.168.1.1-192.168.1.9', 'subtract() returns correct span when subtracting a single address (string) from the end of the span');

    $result = $span1->subtract('192.168.0.0,192.168.1.5,192.168.1.100');
    isa_ok($result, 'IPv4::Range', 'subtract() returns IPv4::Range object when subtracting multiple addresses (string) from the span');
    is($result->size, 9, 'subtract() returns correct size when subtracting multiple addresses (string) from the span, some of which are not in the span');

    # Test subtracting a span from itself
    $result = $span1->subtract($span1);
    isa_ok($result, 'IPv4::Range', 'subtract() returns IPv4::Range object when subtracting a span from itself');
    is($result->size, 0, 'subtract() returns empty range when subtracting a span from itself');

    # Test subtracting a quantity from the span
    $result = $span1->subtract(5);
    isa_ok($result, 'IPv4::Span', 'subtract() returns IPv4::Span object when subtracting a quantity from the end of the span');
    is($result->range, '192.168.1.1-192.168.1.5', 'subtract() returns correct span when subtracting a quantity from the end of the span');
    $result = $span1->subtract(20);
    isa_ok($result, 'IPv4::Range', 'subtract() returns an empty IPv4::Range object when subtracting a quantity that is greater than the span');
    is($result->size, 0, 'subtract() returns empty range when subtracting a quantity that is greater than the span');

    dies_ok { 20 - $span1 } 'overloaded - operator with non-IPv4::Span dies when subtracting a span from a number';
    dies_ok { 'sandwich' - $span1} 'overloaded - operator with non-IPv4::Span dies when subtracting a span from a non-ip string';

    # Test subtracting multiple arguments from the span
    $result = $span1->subtract('192.168.1.2', '192.168.1.4', '192.168.1.8');
    isa_ok($result, 'IPv4::Range', 'subtract() returns IPv4::Range object when subtracting multiple addresses');
    is($result->range, '192.168.1.1,192.168.1.3,192.168.1.5-192.168.1.7,192.168.1.9-192.168.1.10', 'subtract() returns correct range when subtracting multiple addresses');

    # Test subtracting positive and negative numbers from the span
    $result = $span1->subtract(2,-2);
    isa_ok($result, 'IPv4::Span', 'subtract() returns IPv4::Span object when subtracting a positive and negative number');
    is($result->range, '192.168.1.3-192.168.1.8', 'subtract() returns correct range when subtracting a positive and negative number');

    # Test subtracting spans that are not exclusively within the original span, or completely outside the original span
    my $span3 = IPv4::Span->new('192.168.0.0','192.168.1.3');
    is($span1->subtract($span3)->range, '192.168.1.4-192.168.1.10', 'subtract() returns correct range when subtracting span that is not completely inside original span');
    is($span2->subtract($span3)->range, $span2->range, 'subtract() returns original range when subtracting span that is completely outside original span');

    # Overloaded subtraction operator behavior
    $result = $span1 - $span2;
    is(ref($result), 'IPv4::Range', 'overloaded - operator returns IPv4::Range object when gaps in range due to subtraction');
    ok($result == 7, 'overloaded - operator returns correct size when gaps in range due to subtraction');

    $result = "192.168.0.0/16" - $span1;
    is(ref($result), 'IPv4::Range', 'overloaded - operator returns IPv4::Range object when subtracting a span from a ip/mask string');
    is($result->range, '192.168.0.0-192.168.1.0,192.168.1.11-192.168.255.255', 'overloaded - operator returns correct range when subtracting a span from a ip/mask string');

    my $span4 = IPv4::Span->new('192.168.12.0/24');
    is($span4->subtract(16)->range, '192.168.12.0-192.168.12.239', 'subtract() returns correct range when subtracting number from CIDR block');
    is(($span4 - -16)->range, '192.168.12.16-192.168.12.255', 'overloaded - operator returns correct range when subtracting negative number from CIDR block');

    $span4 = IPv4::Span->new('192.168.12.0/24');
    $span4 -= 16;
    is($span4 eq '192.168.12.0-192.168.12.239', 1, 'overloaded -= operator returns correct range when subtracting number from CIDR block');
    $span4 -= -16;
    is($span4 eq '192.168.12.16-192.168.12.239', 1, 'overloaded -= operator returns correct range when subtracting negative number from CIDR block');
    is($span4-- eq '192.168.12.16-192.168.12.239', 1, 'overloaded -- operator returns correct range when subtracting negative number from CIDR block');
    is($span4 == 223, 1, 'overloaded -= and -- operators correctly modifies original span');
  };

  subtest 'add method' => sub {
    plan tests => 32;
    my $span1 = IPv4::Span->new('192.168.1.1', '192.168.1.5');
    my $span2 = IPv4::Span->new('192.168.1.6', '192.168.1.10');
    my $result = $span1->add($span2);
    isa_ok($result, 'IPv4::Span', 'add() returns IPv4::Span object when adding two consecutive spans (after end)');
    is($result->range, '192.168.1.1-192.168.1.10', 'add() returns correct span');
    $result = $span1->add('192.168.2.0'); # Add a single address on the end
    isa_ok($result, 'IPv4::Range', 'add() returns IPv4::Range object when adding a single address to a span that isn\'t consecutive (after end)');

    # Test adding multiple arguments to a span
    $result = $span1->add('192.168.1.11', '192.168.1.12');
    isa_ok($result, 'IPv4::Range', 'add() returns IPv4::Range object when adding multiple addresses');
    is($result->range, '192.168.1.1-192.168.1.5,192.168.1.11-192.168.1.12', 'add() returns correct range when adding multiple addresses');

    $result = $span1->add('192.168.1.0/30', '192.168.1.8/30');
    isa_ok($result, 'IPv4::Range', 'add() returns IPv4::Range object when adding multiple CIDR blocks');
    is($result->range, '192.168.1.0-192.168.1.5,192.168.1.8-192.168.1.11', 'add() returns correct range when adding multiple CIDR blocks');

    $result = $span1->add(-4,4);
    isa_ok($result, 'IPv4::Span', 'add() returns IPv4::Span object when adding multiple numbers');
    is($result->range, '192.168.0.253-192.168.1.9', 'add() returns correct range when adding negative and positive numbers to expand the size of the span');
    is($result->size, $span1->size + 8, 'add() returns correct size when adding negative and positive numbers to expand the size of the span');

    # Test A contains B, A is contained in B, and A and B are equal
    $span1 = IPv4::Span->new('10.0.0.0/24');
    $span2 = IPv4::Span->new('10.0.0.10-10.0.0.30');
    is($span1->add($span2), $span1, 'add() returns correct span when adding a span that is completely contained in the original span');
    is($span2->add($span1), $span1, 'add() returns correct span when adding a span that completely contains the original span');
    is($span2->add($span2), $span2, 'add() returns correct span when adding a span that is equal to the original span');

    # Test that adding spans that overlap results in a single span that covers both
    $span1 = IPv4::Span->new('10.0.0.0-10.0.1.255');
    $span2 = IPv4::Span->new('10.0.1.0-10.0.3.255');
    is($span1->add($span2)->range, '10.0.0.0-10.0.3.255', 'add() returns correct range when adding two overlapping spans');
    is($span2->add($span1)->range, '10.0.0.0-10.0.3.255', 'add() returns correct range when adding two overlapping spans in reverse order');

    # Overloaded addition operator behavior
    $span1 = IPv4::Span->new('192.168.1.1', '192.168.1.5');
    $span2 = IPv4::Span->new('192.168.1.6', '192.168.1.10');
    $result = $span1 + $span2;
    is(ref($result), 'IPv4::Span', 'overloaded - operator returns IPv4::Span object when adding two consecutive spans');
    is($result->range, '192.168.1.1-192.168.1.10', 'overloaded - operator returns correct range when adding two consecutive spans');

    my $span3 = IPv4::Span->new('192.168.0.1', '192.168.0.6');
    $result = $span1 + $span3 + $span2;
    is(ref($result), 'IPv4::Range', 'overloaded - operator returns IPv4::Range object when adding at least one non-consecutive span');
    is($result->range, '192.168.0.1-192.168.0.6,192.168.1.1-192.168.1.10', 'overloaded - operator returns correct range when adding at least one non-consecutive span in the correct order');
    is($result->spans, 2, 'overloaded - operator returns correct number of spans when adding a mix of consecutive and non-consecutive spans');

    # Test adding quantity to a span
    my $span4 = IPv4::Span->new('192.168.12.0/24');
    is($span4->add(16)->range, '192.168.12.0-192.168.13.15', 'add() returns correct span when adding number to CIDR block');
    is(($span4 + -16)->range, '192.168.11.240-192.168.12.255', 'overloaded + operator returns correct span when adding negative number to CIDR block');

    # Test with addresses and ranges
    my $range = $span4 + '192.168.0.0,192.168.2.0';
    isa_ok($range, 'IPv4::Range', 'overloaded + operator returns IPv4::Range object when adding disjointed addresses to a span');

    $span4 += 16;
    is($span4 eq '192.168.12.0-192.168.13.15', 1, 'overloaded -= operator returns correct range when adding number from CIDR block');
    $span4 += -16;
    is($span4 eq '192.168.11.240-192.168.13.15', 1, 'overloaded -= operator returns correct range when adding negative number from CIDR block');
    is(++$span4 eq '192.168.11.240-192.168.13.16', 1, 'overloaded -- operator returns correct range when adding negative number from CIDR block');
    is($span4 == 289, 1, 'overloaded += and ++ operators correctly modifies original span');

    dies_ok { $span4 + 'invalid' } 'overloaded + operator with non-IPv4::Span dies';
    like($@, qr/Invalid IPv4 literal or object 'invalid'/i, 'overloaded + operator with non-IPv4::Span dies with correct message');

    dies_ok { 8 + $span4 } 'adding a span to a number with overloaded + operator dies';
    like($@, qr/Cannot add an IPv4::Span object to a number/i, 'adding a span to a number with overloaded + operator dies with correct message');

    # Regression tests for adding a range to a span where the first span in the range is a subset of the span
    my $span5 = IPv4::Span->new('10.0.1.0-10.0.1.36');
    my $range2 = IPv4::Range->new('10.0.1.0-10.0.1.15,10.0.1.250-10.0.1.255');
    is($span5 + $range2, '10.0.1.0-10.0.1.36,10.0.1.250-10.0.1.255', 'can add a range to a span where the first span in the range is a subset of the span');
  };

  subtest 'contains method' => sub {
    plan tests => 10;
    my $span = IPv4::Span->new('192.168.1.1', '192.168.1.10');
    my $address1 = IPv4::Address->new('192.168.1.5');
    my $address2 = IPv4::Address->new('192.168.1.11');
    my $span2 = IPv4::Span->new('192.168.1.3', '192.168.1.8');
    my $span3 = IPv4::Span->new('192.168.1.3', '192.168.1.12');

    ok($span->contains($address1), 'contains() returns true for address within span');
    ok($span->contains($address1+5), 'contains() returns true for address within span (upper boundary)');
    ok(!$span->contains($address2), 'contains() returns false for address outside span');
    ok($span->contains($span2), 'contains() returns true for span within span');
    ok(!$span->contains($span3), 'contains() returns false for span outside span');
    ok($span->contains('192.168.1.1'), 'contains() returns true for address string within span (lower boundary)');
    ok(!$span->contains('192.168.1.0'), 'contains() returns false for address string outside span');

    ok($span->contains($span), 'contains() returns true for span within itself');
    ok(!$span->contains('192.168.1.0-192.168.1.24'), 'contains() returns false for span (string) outside itself');
    ok($span->contains('192.168.1.1,192.168.1.3-192.168.1.5,192.168.1.10'), 'contains() returns true for range (string) within itself');
  };

  subtest 'cmp method' => sub {
    plan tests => 24;
    my $span1 = IPv4::Span->new('192.168.1.1', '192.168.1.5');
    my $span2 = IPv4::Span->new('192.168.1.6', '192.168.1.10');
    my $span3 = IPv4::Span->new('192.168.1.1', '192.168.1.10');

    is($span1->cmp($span1) => 0, 'span is equal to itself');
    is($span1->cmp($span2), '-1', 'cmp() returns correct comparison result: span1 is less than span2');
    is($span2->cmp($span2), '0', 'cmp() returns correct comparison result: equal spans');
    is($span2->cmp($span1), '1', 'cmp() returns correct comparison result: span2 is greater than span1');
    is($span1->cmp($span3), '-1', 'cmp() returns correct comparison result: spans with same start address but different end addresses');
    is($span2->cmp($span3), '1', 'cmp() returns correct comparison result: spans with same end address but different start addresses');
    is(join(',', map {$_->range} sort @{[$span3, $span2, $span1]}), sprintf("%s,%s,%s",$span1, $span3, $span2), 'cmp() returns correct comparison order using overloaded cmp() operator');
    cmp_ok($span2, 'gt', $span3, 'overloaded comparison operator returns correct comparison result for greater than (starting address)');
    cmp_ok($span1, 'lt', $span3, 'overloaded comparison operator returns correct comparison result for less than (ending address)');

    is($span1->numeric_cmp($span2), 0, 'numeric_cmp() returns correct comparison result: span1 is equal to span2 in size');
    ok(7 > $span1, 'overloaded comparison operator returns correct comparison result for greater than (size of range - number on left)');
    ok($span1 < 7, 'overloaded comparison operator returns correct comparison result for less than (size of range - number on right)');

    cmp_ok($span1, '==', $span2, 'overloaded comparison operator returns correct comparison result for equal to (size of range)');
    cmp_ok($span3, '>', $span1, 'overloaded comparison operator returns correct comparison result for greater than (size of range)');
    cmp_ok($span2, '<', $span3, 'overloaded comparison operator returns correct comparison result for less than (size of range)');

    cmp_ok('192.168.0.1', 'lt', $span1, 'overloaded comparison operator returns correct comparison result for less than (string string with lower start address)');
    cmp_ok('192.168.2.1', 'gt', $span1, 'overloaded comparison operator returns correct comparison result for greater than (string with higher start address)');
    cmp_ok('192.168.1.1-192.168.1.10', 'gt', $span1, 'overloaded comparison operator returns correct comparison result for less than (string with different end address)');
    cmp_ok('192.168.1.0-192.168.1.10', 'lt', $span1, 'overloaded comparison operator returns correct comparison result for less than (string with different start address)');

    cmp_ok('192.168.0.1', '<', $span1, 'overloaded numeric comparison operator returns correct comparison result for less than (string with lower start address)');
    cmp_ok('192.168.2.1', '<', $span1, 'overloaded numeric comparison operator returns correct comparison result for less than (string with higher start address)');
    cmp_ok('192.168.1.2-192.168.1.3', '<', $span1, 'overloaded numeric comparison operator returns correct comparison result for less than (string with higher end address but smaller size)');
    cmp_ok('192.168.1.0-192.168.1.10', '>', $span1, 'overloaded numeric comparison operator returns correct comparison result for greater than (string with lower start address, but more addresses)');

    cmp_ok($span1, 'gt', '192.168.1.1-192.168.1.3,192.168.1.5', 'overloaded comparison operator returns true for greater than when comparing to a range with the same start and end addresses, but missing an address');
  };

  subtest 'eq method' => sub {
    plan tests => 16;
      my $span1 = IPv4::Span->new('192.168.1.1', '192.168.1.5');
      my $span2 = IPv4::Span->new('192.168.1.1', '192.168.1.5');
      my $span3 = IPv4::Span->new('192.168.0.1', '192.168.0.5');
      my $span4_string = '192.168.1.0-192.168.1.6';
      my $span4 = IPv4::Span->new($span4_string);
      ok($span1->eq($span2), 'eq() returns true for equal spans');
      ok(!$span1->eq($span3), 'eq() returns false for different spans of the same size');
      ok(!$span1->eq($span4), 'eq() returns false for a span contained in the other span - b contains a');
      ok(!$span4->eq($span1), 'eq() returns false for a span contained in the other span - a contains b');

      ok($span1 eq $span2, 'eq operator returns true for equal spans using overloaded eq() operator');
      ok($span1 ne $span3, 'ne operator returns true for different spans of the same size using overloaded eq() operator');

      ok($span1 == $span2, '== operator returns true for equal spans');
      ok($span1 == $span3, '== operator returns true for different spans of the same size');
      ok($span1 != $span4, '!= operator returns true for spans of different sizes');

      ok($span4 eq $span4_string, 'eq operator returns true for equal spans using overloaded eq() operator (string)');
      ok($span4_string eq $span4, 'eq operator returns true for equal spans using overloaded eq() operator (string in first position)');

      ok($span4_string == $span4, 'eq operator returns true for equal spans using overloaded == operator (string)');
      ok($span4 != IPv4::Range->new($span4->start, $span4->end), '!= operator returns true for different objects with the same start and end addresses, but different sizes');
      ok($span1 == IPv4->new('192.168.1.1-192.168.1.4,192.168.1.6'), '== operator returns true for different objects with the same start and size, but different end addresses');

      dies_ok { $span1 == 'Golden Gate Bridge' } 'eq operator with non-IPv4::Span dies';
      like($@, qr/Invalid IPv4 literal or object 'Golden Gate Bridge'/i, 'eq operator with non-IPv4::Span dies with correct message');
  };

  subtest 'addresses method' => sub {
    plan tests => 2;
    my $span = IPv4::Span->new('192.168.1.1', '192.168.1.3');
    my @addresses = $span->addresses();
    is_deeply([map { $_->range } @addresses], ['192.168.1.1', '192.168.1.2', '192.168.1.3'], 'addresses() returns correct list of addresses');
    is_deeply([map { "$_" } @$span], ['192.168.1.1', '192.168.1.2', '192.168.1.3'], 'overloaded array context returns correct list of addresses');
  };

  subtest 'next method' => sub {
    plan tests => 6;
    my $span = IPv4::Span->new('192.168.1.1', '192.168.1.3');
    my $next = $span->next();
    isa_ok($next, 'IPv4::Address', 'IPV4::Span::next()' );
    is($next->range, '192.168.1.1', 'next() returns correct first address');

    $next = $span->next();
    is($next->range, '192.168.1.2', 'next() returns correct second address');

    $span->reset();
    $next = $span->next();
    is($next->range, '192.168.1.1', 'next() returns correct first address after reset');

    my @addresses = ();
    while (my $address = $span->next()) {
      push @addresses, $address;
    }
    is_deeply([map { $_->range } @addresses], ['192.168.1.2', '192.168.1.3'], 'next() returns correct list of addresses, then returns undef');

    @addresses = ();
    push @addresses, $_ while (<$span>);
    is_deeply([map { $_->range } @addresses], ['192.168.1.1', '192.168.1.2', '192.168.1.3'], 'overloaded iterator returns correct list of addresses');
  };

  subtest 'slice method' => sub {
    plan tests => 15;
    my $span = IPv4::Span->new('192.168.1.1', '192.168.1.10');
    my $slice = $span->slice(3);
    isa_ok($slice, 'IPv4::Span', 'slice() returns IPv4::Span object');
    is($slice->range, '192.168.1.1-192.168.1.3', 'slice() returns correct slice');

    $slice = $span->slice(3, 2);
    isa_ok($slice, 'IPv4::Span', 'slice() with offset returns IPv4::Span object');
    is($slice->range, '192.168.1.3-192.168.1.5', 'slice() with offset returns correct slice');

    # Test slice with too large of an offset
    $slice = $span->slice(3, 10);
    isa_ok($slice, 'IPv4::Range', 'slice() with offset greater than size returns IPv4::Range object');
    is($slice->size, 0, 'slice() with offset greater than size returns empty range');

    $slice = $span->slice(3, -1);
    isa_ok($slice, 'IPv4::Span', 'slice() with negative offset returns IPv4::Span object');
    is($slice->range, '192.168.1.8-192.168.1.10', 'slice() with negative offset returns correct slice');

    # Test a slice that wants more addresses than are available
    $slice = $span->slice(3, 8); 
    isa_ok($slice, 'IPv4::Span', 'slice() with size greater than available addresses returns IPv4::Span object');
    is($slice->size, 2, 'slice() with size greater than available addresses returns the remaining addresses');
    is($slice->range, '192.168.1.9-192.168.1.10', 'slice() with size greater than available addresses returns correct slice');

    $slice = IPv4::Span->new('192.168.1.1-192.168.1.5')->slice(10, -1);
    is($slice->size, 5, 'slice() with negative offset and a greater size than available addresses returns the remaining addresses');
    is($slice->range, '192.168.1.1-192.168.1.5', 'slice() with negative offset and a greater size than available addresses returns correct slice');

    $slice = $span->slice(0);
    isa_ok($slice, 'IPv4::Range', 'slice() with offset of 0 returns IPv4::Range object');
    is($slice->size, 0, 'slice() with offset of 0 returns empty range');

  }; 

  subtest 'cidrs method' => sub {
    plan tests => 6;  # update test count
    
    # Single IP Address
    my $span = IPv4::Span->new('192.168.1.1', '192.168.1.1');
    my @cidrs = $span->cidrs();
    is_deeply(\@cidrs, ['192.168.1.1/32'], 'Single IP address returns correct CIDR');

    # Contiguous Range
    $span = IPv4::Span->new('192.168.1.0', '192.168.1.255');
    @cidrs = $span->cidrs();
    is_deeply(\@cidrs, ['192.168.1.0/24'], 'Contiguous range returns correct CIDR');

    # Multiple CIDR blocks
    $span = IPv4::Span->new('192.168.1.0', '192.168.1.128');
    @cidrs = $span->cidrs();
    is_deeply(\@cidrs, ['192.168.1.0/25', '192.168.1.128/32'], 'Range requiring multiple CIDR blocks returns correct CIDRs');

    # Test with large and small ranges
    $span = IPv4::Span->new('7.255.255.255', '12.0.0.63');
    @cidrs = $span->cidrs();
    is_deeply(\@cidrs, ['7.255.255.255/32','8.0.0.0/6','12.0.0.0/26'], 'Larger range returns correct CIDR');

    # Test case where blocks get progressively larger
    $span = IPv4::Span->new('192.168.1.129', '192.168.1.255');
    @cidrs = $span->cidrs();
    is_deeply(\@cidrs, [
      '192.168.1.129/32',
      '192.168.1.130/31',
      '192.168.1.132/30',
      '192.168.1.136/29',
      '192.168.1.144/28',
      '192.168.1.160/27',
      '192.168.1.192/26'
    ], 'CIDR block calculation handles non-aligned start address');

    # Test case where blocks get progressively smaller
    $span = IPv4::Span->new('192.168.1.0', '192.168.1.126');
    @cidrs = $span->cidrs();
    is_deeply(\@cidrs, [
      '192.168.1.0/26',
      '192.168.1.64/27',
      '192.168.1.96/28',
      '192.168.1.112/29',
      '192.168.1.120/30',
      '192.168.1.124/31',
      '192.168.1.126/32'
    ], 'CIDR block calculation handles non-aligned end address');
  };
};

# IPv4::Range Tests
#
# This test suite is designed to validate the functionality of the IPv4::Range module.
# It includes a series of tests to ensure that the module correctly handles various
# operations related to IPv4 address ranges, such as creation, comparison, and manipulation
# of IP ranges.
#
# Tests:
# - Test creation of IPv4 ranges
# - Test comparison of IPv4 ranges
# - Test manipulation of IPv4 ranges
subtest 'IPv4::Range' => sub {
  plan tests => 13;

  subtest 'new constructor' => sub {
    plan tests => 24;
    my $range = IPv4::Range->new('192.168.1.1-192.168.1.10', '192.168.2.1-192.168.2.10');
    isa_ok($range, 'IPv4::Range', 'new() creates an IPv4::Range object');
    is($range->size, 20, 'new() returns correct size for multiple spans');
    is($range->spans, 2, 'new() returns correct number of spans');

    my $single_address = IPv4::Range->new('192.168.1.1');
    isa_ok($single_address, 'IPv4::Range', 'new() creates an IPv4::Range object from single address');
    is($single_address->size, 1, 'new() returns correct size for single address');

    my $cidr = IPv4::Range->new('192.168.1.0/24');
    isa_ok($cidr, 'IPv4::Range', 'new() creates an IPv4::Range object from CIDR');
    is($cidr->size, 256, 'new() returns correct size for CIDR');

    $ENV{PRY} = 1;
    my $mixed = IPv4::Range->new('192.168.1.1', [192,168,2,1], IPv4::Address->new('192.168.3.1'));
    isa_ok($mixed, 'IPv4::Range', 'new() creates an IPv4::Range object from mixed input types');
    is($mixed->size, 3, 'new() returns correct size for mixed input types');

    my $from_array = IPv4::Range->new(['192.168.1.1', '192.168.1.10'], [192,168,2,1]);
    isa_ok($from_array, 'IPv4::Range', 'new() creates an IPv4::Range object from spand and address arrays');
    is($from_array->size, 11, 'new() returns correct size for array input');

    my $from_span = IPv4::Range->new(IPv4::Span->new('192.168.1.1-192.168.1.10'));
    isa_ok($from_span, 'IPv4::Range', 'new() creates an IPv4::Range object from IPv4::Span');
    is($from_span->size, 10, 'new() returns correct size for span input');

    my $from_range = IPv4::Range->new($from_span);
    isa_ok($from_range, 'IPv4::Range', 'new() creates an IPv4::Range object from another IPv4::Range');
    is($from_range->size, 10, 'new() returns correct size when cloning range');

    my $comma_sep = IPv4::Range->new('192.168.1.1,192.168.1.5-192.168.1.10,192.168.2.0/24');
    isa_ok($comma_sep, 'IPv4::Range', 'new() creates an IPv4::Range object from comma-separated string');
    is($comma_sep->size, 263, 'new() returns correct size for comma-separated string');

    dies_ok { IPv4::Range->new('invalid') } 'new() with invalid input dies';
    like($@, qr/Invalid IPv4 literal: 'invalid'/i, 'new() with invalid input dies with correct message');

    dies_ok { IPv4::Range->new([]) } 'new() with empty array dies';
    like($@, qr/Invalid span array: \[\]/i, 'new() with empty array dies with correct message');

    dies_ok { IPv4::Range->new(['192.168.90.1']) } 'new() with single-element array dies';
    like($@, qr/Invalid span array: \[192.168.90.1\]/i, 'new() with single-element array dies with correct message');

    dies_ok { IPv4::Range->new(bless({}, 'Unknown')) } 'new() with invalid object type dies';
  };

  subtest 'compact method' => sub {
    plan tests => 4;
    my $range = IPv4::Range->new(
      '192.168.1.1-192.168.1.5',
      '192.168.1.6-192.168.1.10',
      '192.168.1.4-192.168.1.8'
    );
    $range->compact();
    is($range->spans, 1, 'compact() combines overlapping spans');
    is($range->range, '192.168.1.1-192.168.1.10', 'compact() returns correct range after combining');

    $range = IPv4::Range->new(
      '192.168.1.1-192.168.1.5',
      '192.168.2.1-192.168.2.5'
    );
    $range->compact();
    is($range->spans, 2, 'compact() maintains separate non-contiguous spans');
    is($range->range, '192.168.1.1-192.168.1.5,192.168.2.1-192.168.2.5', 'compact() returns correct range for non-contiguous spans');
  };

  subtest 'simplify method' => sub {
    plan tests => 6;
    my $range = IPv4::Range->new('192.168.1.1-192.168.1.10');
    my $simplified = $range->simplify();
    isa_ok($simplified, 'IPv4::Span', 'simplify() returns IPv4::Span for single contiguous range');

    $range = IPv4::Range->new('192.168.1.1');
    $simplified = $range->simplify();
    isa_ok($simplified, 'IPv4::Address', 'simplify() returns IPv4::Address for single address');

    $range = IPv4::Range->new('192.168.1.1-192.168.1.10', '192.168.2.1-192.168.2.10');
    $simplified = $range->simplify();
    isa_ok($simplified, 'IPv4::Range', 'simplify() returns IPv4::Range for multiple spans');
    is($simplified->spans, 2, 'simplify() maintains multiple spans when necessary');

    $range = IPv4::Range->new();
    $simplified = $range->simplify();
    isa_ok($simplified, 'IPv4::Range', 'simplify() returns IPv4::Range for empty range');
    is($simplified->size, 0, 'simplify() maintains empty range');
  };

  subtest 'spans method' => sub {
    plan tests => 4;
    my $range = IPv4::Range->new('192.168.1.1-192.168.1.5', '192.168.2.1-192.168.2.5');
    my @spans = $range->spans();
    is(scalar @spans, 2, 'spans() returns correct number of spans');
    isa_ok($spans[0], 'IPv4::Span', 'spans() returns IPv4::Span objects');
    is($spans[0]->range, '192.168.1.1-192.168.1.5', 'spans() returns correct first span');
    is($spans[1]->range, '192.168.2.1-192.168.2.5', 'spans() returns correct second span');
  };

  subtest 'address methods' => sub {
    plan tests => 9;
    my $range = IPv4::Range->new('192.168.1.1-192.168.1.3', '192.168.2.1-192.168.2.2');
    my @addresses = $range->addresses();
    is(scalar @addresses, 5, 'addresses() returns correct number of addresses');
    is_deeply([map {$_->range} @addresses],
      ['192.168.1.1', '192.168.1.2', '192.168.1.3', '192.168.2.1', '192.168.2.2'],
      'addresses() returns correct addresses');

    is($range->start->range, '192.168.1.1', 'start() returns correct first address');
    is($range->end->range, '192.168.2.2', 'end() returns correct last address');

    my $mixed_range = IPv4::Range->new('192.168.1.1', '192.168.2.1-192.168.2.3', '192.168.3.1');
    my @items = ();
    #$ENV{PRY} = 1;
    push @items, $_ while (<$mixed_range>);
    is(scalar @items, 5, 'diamond operator returns correct number of addresses from mixed range');
    is_deeply([map {$_->range} @items],
      ['192.168.1.1', '192.168.2.1', '192.168.2.2', '192.168.2.3', '192.168.3.1'],
      'diamond operator returns addresses in correct order from mixed range');

    my $addr = $mixed_range->next();
    is($addr->range, '192.168.1.1', 'next() returns correct first address from mixed range');
    $mixed_range->reset();
    my $first = <$mixed_range>;
    is($first->range, '192.168.1.1', 'diamond operator returns correct first address after reset');
    my $last = undef;
    $last = $_ while (<$mixed_range>);
    is($last->range, '192.168.3.1', 'diamond operator returns correct last address');
  };

  subtest 'range and size methods' => sub {
    plan tests => 4;
    my $range = IPv4::Range->new('192.168.1.1-192.168.1.5', '192.168.2.1-192.168.2.5');
    is($range->range, '192.168.1.1-192.168.1.5,192.168.2.1-192.168.2.5', 'range() returns correct string representation');
    is($range->size, 10, 'size() returns correct total size');

    # Test overloaded stringification and numeric context
    is("$range", '192.168.1.1-192.168.1.5,192.168.2.1-192.168.2.5', 'stringification returns correct string');
    is(int($range), 10, 'numeric context returns correct size');
  };

  subtest 'clone method' => sub {
    plan tests => 3;
    my $range = IPv4::Range->new('192.168.1.1-192.168.1.5', '192.168.2.1-192.168.2.5');
    my $clone = $range->clone();
    isa_ok($clone, 'IPv4::Range', 'clone() returns IPv4::Range object');
    is($clone->range, $range->range, 'clone() creates identical range');
    
    $clone = IPv4::Range->new('192.168.3.1-192.168.3.5');
    isnt($clone->range, $range->range, 'cloned object can be modified independently');
  };

  subtest 'slice method' => sub {
    plan tests => 12;
    my $range = IPv4::Range->new('192.168.1.1-192.168.1.3', '192.168.2.1-192.168.2.2');
    my $slice = $range->slice(2);
    isa_ok($slice, 'IPv4::Range', 'slice() returns IPv4::Range object');
    is($slice->range, '192.168.1.1-192.168.1.2', 'slice() returns correct slice');

    $slice = $range->slice(2, 2);
    is($slice->range, '192.168.1.3,192.168.2.1', 'slice() with offset returns correct slice');

    $slice = $range->slice(10);
    is($slice->range, '192.168.1.1-192.168.1.3,192.168.2.1-192.168.2.2', 'slice() with size larger than range returns entire range');
    is($slice->size, 5, 'slice() with size larger than range returns correct size');

    $slice = $range->slice(10, 2);
    is($slice->range, '192.168.1.3,192.168.2.1-192.168.2.2', 'slice() with size larger than range and offset returns correct slice');
    is($slice->size, 3, 'slice() with size larger than range and offset returns correct size');

    $slice = $range->slice(4, -1);
    is($slice->range, '192.168.1.2-192.168.1.3,192.168.2.1-192.168.2.2', 'slice() with negative offset returns correct slice');
    is($slice->size, 4, 'slice() with negative offset returns correct size');

    $slice = $range->slice(4, -3);
    is($slice->range, '192.168.1.1-192.168.1.3', 'slice() with negative offset and size returns correct slice');
    is($slice->size, 3, 'slice() with negative offset and size returns correct size');

    $slice = $range->slice(4, 10);
    is($slice->size, 0, 'slice() with offset greater than size returns empty range');
  };

  subtest 'span method' => sub {
    plan tests => 3;
    my $range = IPv4::Range->new('192.168.1.1-192.168.1.5', '192.168.2.1-192.168.2.5');
    my $span = $range->span();
    isa_ok($span, 'IPv4::Span', 'span() returns IPv4::Span object');
    is($span->start->range, '192.168.1.1', 'span() returns correct start address');
    is($span->end->range, '192.168.2.5', 'span() returns correct end address');
  };

  subtest 'add method' => sub {
    plan tests => 14;
    my $range = IPv4::Range->new('192.168.1.1-192.168.1.5');
    my $result = $range->add('192.168.1.6-192.168.1.10');
    isa_ok($result, 'IPv4::Range', 'add() returns IPv4::Range for contiguous addition');
    is($result->spans, 1, 'add() returns correct number of spans when a contiguous span is added');
    is($result->range, '192.168.1.1-192.168.1.10', 'add() returns correct range for contiguous addition');

    $result = $range + '192.168.2.1-192.168.2.5';
    isa_ok($result, 'IPv4::Range', 'overloaded + returns IPv4::Range for non-contiguous addition');
    is($result->range, '192.168.1.1-192.168.1.5,192.168.2.1-192.168.2.5', 'overloaded + returns correct range');

    my $addr = IPv4::Address->new('192.168.1.6');
    $result = $range + $addr;
    is($result->range, '192.168.1.1-192.168.1.6', 'can add IPv4::Address objects');

    $result = $range + '192.168.1.6';
    is($result->range, '192.168.1.1-192.168.1.6', 'can add address strings');

    dies_ok { 0 + $range } 'overloaded addition operator with range dies when integer is on the left side of the operator';
    like($@, qr/Invalid IPv4 literal: '0'/i, 'overloaded addition operator with range dies with correct message');

    dies_ok { $range + 2 } 'overloaded addition operator with integer dies when integer is on the right side of the operator';
    like($@, qr/Invalid IPv4 literal: '2'/i, 'overloaded addition operator with an integer on the right side of the operator dies with correct message');

    dies_ok { $range + 'invalid' } 'add() with invalid input dies';
    like($@, qr/Invalid IPv4 literal: 'invalid'/i, 'add() with invalid input dies with correct message');

    # Regression tests for adding a range to another range where the first span in the range being added is a subset of the single span in the range being added to
    my $span5 = IPv4::Range->new('10.0.1.0-10.0.1.36');
    my $range2 = IPv4::Range->new('10.0.1.0-10.0.1.15,10.0.1.250-10.0.1.255');
    is($span5 + $range2, '10.0.1.0-10.0.1.36,10.0.1.250-10.0.1.255', 'can add a range to a span where the first span in the range is a subset of the span');
  };

  subtest 'subtract method' => sub {
    plan tests => 11;
    my $range = IPv4::Range->new('192.168.1.1-192.168.1.10');
    my $result = $range->subtract('192.168.1.4-192.168.1.6');
    isa_ok($result, 'IPv4::Range', 'subtract() returns IPv4::Range');
    is($result->range, '192.168.1.1-192.168.1.3,192.168.1.7-192.168.1.10', 'subtract() returns correct range');

    $result = $range - '192.168.1.1';
    is($result->range, '192.168.1.2-192.168.1.10', 'can subtract single address');

    $result = $range - '192.168.1.1-192.168.1.10';
    isa_ok($result, 'IPv4::Range', 'subtracting entire range returns empty IPv4::Range');
    is($result->size, 0, 'subtracting entire range returns empty range');

    my $multi_range = IPv4::Range->new('192.168.1.1-192.168.1.10', '192.168.2.1-192.168.2.10');
    $result = $multi_range - '192.168.1.4-192.168.2.4';
    is($result->range, '192.168.1.1-192.168.1.3,192.168.2.5-192.168.2.10', 'can subtract from multiple spans');
    $result = '192.168.1.4-192.168.2.4, 10.0.0.0-10.0.0.64' - $multi_range;
    is($result->range, '10.0.0.0-10.0.0.64,192.168.1.11-192.168.2.0', 'can subtract from multiple spans');

    dies_ok { 99 - $range } 'overloaded addition operator with range dies when integer is on the left side of the operator';
    like($@, qr/Invalid subtraction between IPv4::Range and integer/i, 'overloaded addition operator with range dies with correct message');

    dies_ok { $range - -2 } 'overloaded addition operator with integer dies when integer is on the right side of the operator';
    like($@, qr/Invalid subtraction between IPv4::Range and integer/i, 'overloaded addition operator with an integer on the right side of the operator dies with correct message');
  };

  subtest 'comparison methods' => sub {
    plan tests => 64;
    my $range1 = IPv4::Range->new('192.168.1.1-192.168.1.5');
    my $range2 = IPv4::Range->new('192.168.1.1-192.168.1.5');
    my $range3 = IPv4::Range->new('192.168.1.6-192.168.1.10');

    is($range1->cmp($range1) => 0, 'range is equal to itself');
    ok($range1->eq($range2), 'eq() returns true for identical ranges');
    ok($range1 lt $range3, 'overloaded ne operator returns true for different ranges');
    ok($range1 ne $range3, 'overloaded ne operator returns true for different ranges');

    ok($range1->numeric_eq($range2), 'numeric_eq() returns true for identical ranges');
    ok($range1->numeric_eq(5), 'numeric_eq() can compare with size');
    ok($range1 == $range2, 'overloaded == operator returns true for identical ranges');
    ok(!($range1 != $range3), 'overloaded != operator returns false for different ranges of same size');

    my $range4 = IPv4::Range->new('192.168.1.1-192.168.1.5', '192.168.2.1-192.168.2.5');
    ok($range1->cmp($range3) < 0, 'cmp() returns correct comparison result');
    ok($range4->cmp($range1) > 0, 'cmp() returns correct comparison result for multiple spans');
    ok($range1->numeric_cmp($range3) == 0, 'numeric_cmp() returns correct comparison result');
    ok($range4->numeric_cmp($range1) > 0, 'numeric_cmp() returns correct comparison result for multiple spans');

    # Test comparing range objects to other IPv4 objects
    my $span = IPv4::Span->new('192.168.1.1-192.168.1.5');
    my $addr = IPv4::Address->new('192.168.1.1');
    my $range = IPv4::Range->new($span);

    ok($range eq $span, 'range equals identical span');
    ok($range ne $addr, 'range not equal to single address that matches start');
    ok($range > $addr, 'range greater than single address (object comparison)');
    ok($range == $span, 'range numerically equal to identical span');
    ok($range > $addr, 'range numerically greater than single address');

    $range2 = IPv4::Range->new($span, '192.168.2.1');
    ok($range2 > $range, 'range with more spans greater than range with single span');
    ok($range2 > $span, 'range with multiple spans greater than single span');
    ok($range2 != $span, 'range with multiple spans numerically not equal to single span');

    my $addr2 = IPv4::Address->new('192.168.2.1'); 
    ok($range2 > $addr2, 'range greater than highest address in range (object comparison)');
    ok($range2 > $addr2, 'range numerically greater than single address in range');

    my $span2 = IPv4::Span->new('192.168.0.1-192.168.0.5');
    ok($range gt $span2, 'range greater than span with lower addresses');
    ok($range == $span2, 'range numerically equal to span with same size');

    my $range5 = IPv4::Range->new($addr);
    ok($range5 eq $addr, 'range equal to single address');
    ok($range5 == $addr, 'range numerically equal to single address');

    cmp_ok($range5, 'lt', $addr + 1, 'range less than address with higher value');
    cmp_ok($range5, 'gt', $addr - 1, 'range greater than address with lower value');
    cmp_ok($range5, '==', $addr, 'range equal to single address regardless of address value');

    # Test comparing ranges with different numbers of spans
    my $empty = IPv4::Range->new();
    my $single = IPv4::Range->new('192.168.1.1');
    my $double = IPv4::Range->new('192.168.1.1,192.168.1.3');
    my $triple = IPv4::Range->new('192.168.1.1-192.168.1.2,192.168.1.4,192.168.1.5,192.168.1.10');

    ok($empty < $single, 'empty range less than single address range');
    ok($single < $double, 'single address range less than double address range');
    ok($double < $triple, 'double address range less than triple address range');
    ok($empty == 0, 'empty range equals 0 numerically');
    ok($empty eq '', 'empty range stringifies to empty string');
    ok($empty eq undef, 'empty range equals undef - autovivification of undef to empty range');

    # Test spans() count comparisons
    ok($empty->spans == 0, 'empty range has 0 spans');
    ok($single->spans == 1, 'single address range has 1 span');
    ok($double->spans == 2, 'double address range has 2 spans');
    ok($triple->spans == 3, 'triple address range has 2 spans (optimized)');

    # Test comparison with string representations of ranges, spans, and addresses
    $range = IPv4::Range->new('192.168.1.1-192.168.1.10');

    ok($range eq '192.168.1.1-192.168.1.10', 'range equals string representation of span');
    ok('192.168.1.1-192.168.1.10' eq $range, 'string representation of span equals range');
    ok($range ne '192.168.1.1-192.168.1.11', 'range not equal to different string span');
    ok('192.168.1.1-192.168.1.11' ne $range, 'different string span not equal to range');

    ok($range gt '192.168.1.1', 'range greater than single address string');
    ok('192.168.1.11' gt $range, 'higher address string greater than range');
    ok($range lt '192.168.1.11', 'range less than higher address string');
    ok('192.168.1.1' lt $range, 'lower address string less than range');

    is($range cmp '192.168.1.1', 1, 'cmp returns 1 when range greater than string');
    is('192.168.1.11' cmp $range, 1, 'cmp returns 1 when string greater than range');

    ok($range == '192.168.1.1-192.168.1.10', 'range numerically equals string of same size');
    ok('192.168.1.1-192.168.1.10' == $range, 'string numerically equals range of same size'); 
    ok($range != '192.168.1.1', 'range not numerically equal to string of different size');
    ok('192.168.1.1' != $range, 'string not numerically equal to range of different size');

    ok($range > '192.168.1.1', 'range numerically greater than smaller string');
    ok('192.168.1.1-192.168.1.20' > $range, 'larger string numerically greater than range');
    ok($range < '192.168.1.1-192.168.1.20', 'range numerically less than larger string');  
    ok('192.168.1.1' < $range, 'smaller string numerically less than range');

    is($range <=> '192.168.1.1', 1, 'spaceship returns 1 when range numerically greater');
    is('192.168.1.1-192.168.1.20' <=> $range, 1, 'spaceship returns 1 when string numerically greater');

    # Test comparison with invalid input
    dies_ok { $range cmp 0 } 'cmp with invalid input dies';
    dies_ok { $range gt 'invalid' } 'gt with invalid input dies';

    is($range eq bless({}, 'Unknown'), '', 'range not equal to invalid object, but does not die');
    is($range->eq(0), '', 'range->eq() not equal to integer, but does not die');

    my $more_spans = $range + '192.168.99.99';
    is($range cmp $more_spans, -1, 'range that is identical with another range except that the second range has one higher span is less than that other range');
  };

  subtest 'contains method' => sub {
    plan tests => 6;
    my $range = IPv4::Range->new('192.168.1.1-192.168.1.10');
    my $address = IPv4::Address->new('192.168.1.5');
    my $span = IPv4::Span->new('192.168.1.3-192.168.1.8');
    my $range2 = IPv4::Range->new('192.168.1.3-192.168.1.8');

    ok($range->contains($address), 'contains() returns true for address within range');
    ok($range->contains($span), 'contains() returns true for span within range');
    ok($range->contains($range2), 'contains() returns true for range within range');
    ok(!$range->contains('192.168.1.11'), 'contains() returns false for address outside range');
    ok(!$range->contains('192.168.1.0-192.168.1.12'), 'contains() returns false for span outside range');
    ok(!$range->contains('192.168.1.0-192.168.1.12,192.168.2.0'), 'contains() returns false for range outside range');
  };
};

done_testing();
