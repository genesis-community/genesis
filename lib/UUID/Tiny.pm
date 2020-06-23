package UUID::Tiny;

# Derived from https://metacpan.org/pod/UUID::Tiny
# See it for POD docs and further details

use 5.008;
use warnings;
use strict;
use Carp;
use Digest::MD5;
use MIME::Base64;
use Time::HiRes;
use POSIX;

my $SHA1_CALCULATOR = undef;

{
	# Check for availability of SHA-1 ...
	local $@; # don't leak an error condition
	eval { require Digest::SHA;  $SHA1_CALCULATOR = Digest::SHA->new(1) } ||
	eval { require Digest::SHA1; $SHA1_CALCULATOR = Digest::SHA1->new() } ||
	eval {
		require Digest::SHA::PurePerl;
		$SHA1_CALCULATOR = Digest::SHA::PurePerl->new(1)
	};
};

my $MD5_CALCULATOR = Digest::MD5->new();

use Exporter;
our @ISA = qw(Exporter);
our @EXPORT;
our %EXPORT_TAGS = (
	std =>         [qw(
		UUID_NIL
		UUID_NS_DNS UUID_NS_URL UUID_NS_OID UUID_NS_X500
		UUID_V1 UUID_TIME
		UUID_V3 UUID_MD5
		UUID_V4 UUID_RANDOM
		UUID_V5 UUID_SHA1
		UUID_SHA1_AVAIL
		create_uuid create_uuid_as_string
		is_uuid_string
		uuid_to_string string_to_uuid
		version_of_uuid time_of_uuid clk_seq_of_uuid
		equal_uuids
		)]
);

Exporter::export_ok_tags('std');

use constant UUID_NIL     => "\x00" x 16;
use constant UUID_NS_DNS  => "\x6b\xa7\xb8\x10\x9d\xad\x11\xd1\x80\xb4\x00\xc0\x4f\xd4\x30\xc8";
use constant UUID_NS_URL  => "\x6b\xa7\xb8\x11\x9d\xad\x11\xd1\x80\xb4\x00\xc0\x4f\xd4\x30\xc8";
use constant UUID_NS_OID  => "\x6b\xa7\xb8\x12\x9d\xad\x11\xd1\x80\xb4\x00\xc0\x4f\xd4\x30\xc8";
use constant UUID_NS_X500 => "\x6b\xa7\xb8\x14\x9d\xad\x11\xd1\x80\xb4\x00\xc0\x4f\xd4\x30\xc8";

use constant UUID_V1 => 1; use constant UUID_TIME   => 1;
use constant UUID_V3 => 3; use constant UUID_MD5    => 3;
use constant UUID_V4 => 4; use constant UUID_RANDOM => 4;
use constant UUID_V5 => 5; use constant UUID_SHA1   => 5;

sub UUID_SHA1_AVAIL {
    return defined $SHA1_CALCULATOR ? 1 : 0;
}

sub create_uuid {
	use bytes;
	my ($v, $arg2, $arg3) = (shift || UUID_V4, shift, shift);
	my $uuid    = UUID_NIL;
	my $ns_uuid = string_to_uuid(defined $arg3 ? ($arg2 || UUID_NIL) : UUID_NIL);
	my $name    = defined $arg3 ? $arg3 : $arg2;

	my $fn="_create_v${v}_uuid";
	croak __PACKAGE__ . "::create_uuid(): Invalid UUID version '$v'!\n"
		unless (exists &{$fn});

	$uuid = (\&{$fn})->($ns_uuid, $name);
	substr $uuid, 8, 1, chr(ord(substr $uuid, 8, 1) & 0x3f | 0x80);
	return $uuid;
}

sub _create_v1_uuid {
	my $uuid = '';

	# Create time and clock sequence ...
	my $timestamp = Time::HiRes::time();
	my $clk_seq   = _get_clk_seq($timestamp);

	# hi = time mod (1000000 / 0x100000000)
	my $hi = floor( $timestamp / 65536.0 / 512 * 78125 );
	$timestamp -= $hi * 512.0 * 65536 / 78125;
	my $low = floor( $timestamp * 10000000.0 + 0.5 );

	# MAGIC offset: 01B2-1DD2-13814000
	if ( $low < 0xec7ec000 ) {
		$low += 0x13814000;
	} else {
		$low -= 0xec7ec000;
		$hi++;
	}

	if ( $hi < 0x0e4de22e ) {
		$hi += 0x01b21dd2;
	} else {
		$hi -= 0x0e4de22e;    # wrap around
	}

	# Set time in UUID ...
	substr $uuid, 0, 4, pack( 'N', $low );            # set time low
	substr $uuid, 4, 2, pack( 'n', $hi & 0xffff );    # set time mid
	substr $uuid, 6, 2, pack( 'n', ( $hi >> 16 ) & 0x0fff );    # set time high

	# Set clock sequence in UUID ...
	substr $uuid, 8, 2, pack( 'n', $clk_seq );

	# Set random node in UUID ...
	substr $uuid, 10, 6, _random_node_id();

	return _set_uuid_version($uuid, 0x10);
}

sub _create_v3_uuid {
	my $ns_uuid = shift;
	my $name    = shift;
	my $uuid    = '';

	# Create digest in UUID ...
	$MD5_CALCULATOR->reset();
	$MD5_CALCULATOR->add($ns_uuid);

	if ( ref($name) =~ m/^(?:GLOB|IO::)/ ) {
		$MD5_CALCULATOR->addfile($name);
	}
	elsif ( ref $name ) {
		croak __PACKAGE__
		. '::create_uuid(): Name for v3 UUID'
		. ' has to be SCALAR, GLOB or IO object, not '
		. ref($name) .'!'
		;
	}
	elsif ( defined $name ) {
		$MD5_CALCULATOR->add($name);
	}
	else {
		croak __PACKAGE__
		. '::create_uuid(): Name for v3 UUID is not defined!';
	}

	# Use only first 16 Bytes ...
	$uuid = substr( $MD5_CALCULATOR->digest(), 0, 16 ); 

	return _set_uuid_version( $uuid, 0x30 );
}

sub _create_v4_uuid {
	# Create random value in UUID ...
	my $uuid = '';
	for ( 1 .. 4 ) {
		$uuid .= pack 'I', _rand_32bit();
	}

	return _set_uuid_version($uuid, 0x40);
}

sub _create_v5_uuid {
	my $ns_uuid = shift;
	my $name    = shift;
	my $uuid    = '';

	if (!$SHA1_CALCULATOR) {
		croak __PACKAGE__
		. '::create_uuid(): No SHA-1 implementation available! '
		. 'Please install Digest::SHA1, Digest::SHA or '
		. 'Digest::SHA::PurePerl to use SHA-1 based UUIDs.'
		;
	}

	$SHA1_CALCULATOR->reset();
	$SHA1_CALCULATOR->add($ns_uuid);

	if ( ref($name) =~ m/^(?:GLOB|IO::)/ ) {
		$SHA1_CALCULATOR->addfile($name);
	} elsif ( ref $name ) {
		croak __PACKAGE__
		. '::create_uuid(): Name for v5 UUID'
		. ' has to be SCALAR, GLOB or IO object, not '
		. ref($name) .'!'
		;
	} elsif ( defined $name ) {
		$SHA1_CALCULATOR->add($name);
	} else {
		croak __PACKAGE__ 
		. '::create_uuid(): Name for v5 UUID is not defined!';
	}

	# Use only first 16 Bytes ...
	$uuid = substr( $SHA1_CALCULATOR->digest(), 0, 16 );

	return _set_uuid_version($uuid, 0x50);
}

sub _set_uuid_version {
	my $uuid = shift;
	my $version = shift;
	substr $uuid, 6, 1, chr( ord( substr( $uuid, 6, 1 ) ) & 0x0f | $version );

	return $uuid;
}

sub create_uuid_as_string {
    return uuid_to_string(create_uuid(@_));
}

our $IS_UUID_STRING = qr/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/is;
our $IS_UUID_HEX    = qr/^[0-9a-f]{32}$/is;
our $IS_UUID_Base64 = qr/^[+\/0-9A-Za-z]{22}(?:==)?$/s;

sub is_uuid_string {
    my $uuid = shift;
    return $uuid =~ m/$IS_UUID_STRING/;
}

sub uuid_to_string {
    my $uuid = shift;
    use bytes;
    return $uuid
        if $uuid =~ m/$IS_UUID_STRING/;
    croak __PACKAGE__ . "::uuid_to_string(): Invalid UUID!"
        unless length $uuid == 16;
    return  join '-',
            map { unpack 'H*', $_ }
            map { substr $uuid, 0, $_, '' }
            ( 4, 2, 2, 2, 6 );
}

sub string_to_uuid {
    my $uuid = shift;

    use bytes;
    return $uuid if length $uuid == 16;
    return decode_base64($uuid) if ($uuid =~ m/$IS_UUID_Base64/);
    my $str = $uuid;
    $uuid =~ s/^(?:urn:)?(?:uuid:)?//io;
    $uuid =~ tr/-//d;
    return pack 'H*', $uuid if $uuid =~ m/$IS_UUID_HEX/;
    croak __PACKAGE__ . "::string_to_uuid(): '$str' is no UUID string!";
}

sub version_of_uuid {
    my $uuid = shift;
    use bytes;
    $uuid = string_to_uuid($uuid);
    return (ord(substr($uuid, 6, 1)) & 0xf0) >> 4;
}

sub time_of_uuid {
    my $uuid = shift;
    use bytes;
    $uuid = string_to_uuid($uuid);
    return unless version_of_uuid($uuid) == 1;

    my $low = unpack 'N', substr($uuid, 0, 4);
    my $mid = unpack 'n', substr($uuid, 4, 2);
    my $high = unpack('n', substr($uuid, 6, 2)) & 0x0fff;

    my $hi = $mid | $high << 16;

    # MAGIC offset: 01B2-1DD2-13814000
    if ($low >= 0x13814000) {
        $low -= 0x13814000;
    }
    else {
        $low += 0xec7ec000;
        $hi --;
    }

    if ($hi >= 0x01b21dd2) {
        $hi -= 0x01b21dd2;
    }
    else {
        $hi += 0x0e4de22e;  # wrap around
    }

    $low /= 10000000.0;
    $hi  /= 78125.0 / 512 / 65536;  # / 1000000 * 0x10000000

    return $hi + $low;
}

sub clk_seq_of_uuid {
    use bytes;
    my $uuid = shift;
    $uuid = string_to_uuid($uuid);
    return unless version_of_uuid($uuid) == 1;

    my $r = unpack 'n', substr($uuid, 8, 2);
    my $v = $r >> 13;
    my $w = ($v >= 6) ? 3 # 11x
          : ($v >= 4) ? 2 # 10-
          :             1 # 0--
          ;
    $w = 16 - $w;

    return $r & ((1 << $w) - 1);
}

sub equal_uuids {
    my ($u1, $u2) = @_;
    return unless defined $u1 && defined $u2;
    return string_to_uuid($u1) eq string_to_uuid($u2);
}

# Private functions ...
#
my $Last_Pid;
my $Clk_Seq :shared;

# There is a problem with $Clk_Seq and rand() on forking a process using
# UUID::Tiny, because the forked process would use the same basic $Clk_Seq and
# the same seed (!) for rand(). $Clk_Seq is UUID::Tiny's problem, but with
# rand() it is Perl's bad behavior. So _init_globals() has to be called every
# time before using $Clk_Seq or rand() ...

sub _init_globals {
    lock $Clk_Seq;

    if (!defined $Last_Pid || $Last_Pid != $$) {
        $Last_Pid = $$;
        # $Clk_Seq = _generate_clk_seq();
        # There's a slight chance to get the same value as $Clk_Seq ...
        for (my $i = 0; $i <= 5; $i++) {
            my $new_clk_seq = _generate_clk_seq();
            if (!defined($Clk_Seq) || $new_clk_seq != $Clk_Seq) {
                $Clk_Seq = $new_clk_seq;
                last;
            }
            if ($i == 5) {
                croak __PACKAGE__
                    . "::_init_globals(): Can't get unique clk_seq!";
            }
        }
        srand();
    }

    return;
}

my $Last_Timestamp :shared;

sub _get_clk_seq {
    my $ts = shift;
    _init_globals();

    lock $Last_Timestamp;
    lock $Clk_Seq;

    #if (!defined $Last_Timestamp || $ts <= $Last_Timestamp) {
    if (defined $Last_Timestamp && $ts <= $Last_Timestamp) {
        #$Clk_Seq = ($Clk_Seq + 1) % 65536;
        # The old variant used modulo, but this looks unnecessary,
        # because we should only use the significant part of the
        # number, and that also lets the counter circle around:
        $Clk_Seq = ($Clk_Seq + 1) & 0x3fff;
    }
    $Last_Timestamp = $ts;

    #return $Clk_Seq & 0x03ff; # no longer needed - and it was wrong too!
    return $Clk_Seq;
}

sub _generate_clk_seq {
    my $self = shift;
    # _init_globals();

    my @data;
    push @data, ''  . $$;
    push @data, ':' . Time::HiRes::time();

    # 16 bit digest
    # We should return only the significant part of the number!
    return (unpack 'n', _digest_as_octets(2, @data)) & 0x3fff;
}

sub _random_node_id {
    my $self = shift;

    my $r1 = _rand_32bit();
    my $r2 = _rand_32bit();

    my $hi = ($r1 >> 8) ^ ($r2 & 0xff);
    my $lo = ($r2 >> 8) ^ ($r1 & 0xff);

    $hi |= 0x80;

    my $id  = substr pack('V', $hi), 0, 3;
       $id .= substr pack('V', $lo), 0, 3;

    return $id;
}

sub _rand_32bit {
    _init_globals();
    my $v1 = int(rand(65536)) % 65536;
    my $v2 = int(rand(65536)) % 65536;
    return ($v1 << 16) | $v2;
}

sub _fold_into_octets {
    use bytes;
    my ($num_octets, $s) = @_;

    my $x = "\x0" x $num_octets;

    while (length $s > 0) {
        my $n = '';
        while (length $x > 0) {
            my $c = ord(substr $x, -1, 1, '') ^ ord(substr $s, -1, 1, '');
            $n = chr($c) . $n;
            last if length $s <= 0;
        }
        $n = $x . $n;

        $x = $n;
    }

    return $x;
}

sub _digest_as_octets {
    my $num_octets = shift;

    $MD5_CALCULATOR->reset();
    $MD5_CALCULATOR->add($_) for @_;

    return _fold_into_octets($num_octets, $MD5_CALCULATOR->digest);
}


=head1 COPYRIGHT & LICENSE

Copyright 2009, 2010, 2013 Christian Augustin, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

ITO Nobuaki has very graciously given me permission to take over copyright for
the portions of code that are copied from or resemble his work (see
rt.cpan.org #53642 L<https://rt.cpan.org/Public/Bug/Display.html?id=53642>).

=cut

1; # End of UUID::Tiny

