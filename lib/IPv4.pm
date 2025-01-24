package IPv4;
use v5.20;
use feature 'signatures';
no warnings 'experimental::signatures';

sub new(@args) {
    require IPv4::Range;
    return IPv4::Range->new( __strip_call_ref(@args) )->simplify();
}

sub address(@args) {
    require IPv4::Address;
    return IPv4::Address->new( __strip_call_ref(@args) );
}

sub span(@args) {
    require IPv4::Span;
    return IPv4::Span->new( __strip_call_ref(@args) );
}

sub range(@args) {
    require IPv4::Range;
    return IPv4::Range->new( __strip_call_ref(@args) );
}

sub __strip_call_ref(@args) {

    return () unless @args;

    my $ref = shift @args;
    if ( $ref eq __PACKAGE__ ) {
        return @args;
    }
    else {
        return ( $ref, @args );
    }
}

sub __is_integer($value) {
	return ref($value) eq '' && $value =~ /^-?\d+$/;
}

sub __autovivify($value) {
	return $value->simplify if ref($value) =~ /^IPv4::(Address|Span|Range)$/;
	my $obj = undef;
	eval { $obj = IPv4->new($value) };
  my $err = $@;
  if ($err) {
    my $msg = sprintf(
      "Invalid IPv4 literal or object %s",
      ref($value) eq '' ? "'$value'" : ref($value).' type',
    );
    $msg .= ": $err" if $err !~ /Invalid IPv4 literal/;
    die $msg;
  }
	return $obj;
}

1;
