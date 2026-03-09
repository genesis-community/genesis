package Mock;

# Mock
#
# A simple mock object for testing purposes.  This object can be used to mock
# any object, and can be used to set responses for methods, or to set a value
# for a method.  The mock object will return the value set for a method, or
# will return a value set for the object itself.  If a method is called that
# has not been set, the mock object will die with an error message.
#
# Usage:
# my $mock = Mock->new(
#   property => 'value1',
#   method => sub { return 'value2' },
# );
#
# $mock->method(); # returns 'value2'
# $mock->property; # returns 'value1'
#
# $mock->_mock_set_responses('property', 'value3', 'value4');
# $mock->property; # returns 'value3'
# $mock->property; # returns 'value4'
# $mock->property; # returns 'value1'
#
# Note:  When defining a mock object, don't include a property that is using Mock->new to define it, or "Weird things will happen." . Create a new variable to hold that mock object, and then set the property to that variable.


sub new {
	my ($class, %args) = @_;
	return bless \%args, $class;
}

# Responses are an array of hashes, with each hash having a value and a count (defaults to 1, 0 or less means infinite)
sub _mock_set_responses {
	my ($self, $method, @responses) = @_;
	my $counts = scalar(@responses) > 1 ? 1 : 0;
	for (@responses) {
		$_ = {value => $_} unless ref($_) eq 'HASH' && exists $_->{value};
		$_->{count} //= $counts;
	}	
	$self->{__responses}{$method} = \@responses;
}

sub _mock_remove_responses {
	my ($self, $method) = @_;
	delete $self->{__responses}{$method};
}

sub _mock_get_response {
	my ($self, $method, @args) = @_;
	my $value;
	if (exists $self->{__responses}{$method}) {
		if (ref($self->{__responses}{$method}) eq 'ARRAY') {
			my $response = $self->{__responses}{$method}[0];
			if (ref($response) eq 'HASH') {
				$value = $response->{value};
				($response->{count} //= 1) -= 1;
				shift @{$self->{__responses}{$method}} if $response->{count} == 0;
				delete $self->{__responses}{$method} unless scalar(@{$self->{__responses}{$method}});
			} else {
				$value = $response;
				shift @{$self->{__responses}{$method}};
			}
		} else {
			$value = $self->{__responses}{$method};
		}
	} elsif (exists $self->{$method}) {
		$value = $self->{$method};
	} else {
		my $class = ref($self);
		use Carp qw/confess/;
		confess "Invalid method $method called on mock $class object";
	}

	return $value = $value->($self, @args) if (ref($value) eq 'CODE');
	return $value->value if ref($value) eq 'Mock::ReferencedValue';
	return $value;
}

our $AUTOLOAD;
sub AUTOLOAD {
	my $self = shift;
	my $method = $AUTOLOAD;
	$method =~ s/.*:://;
	return if ($method eq 'DESTROY');
	return $self->_mock_get_response($method, @_);
}

package Mock::ReferencedValue;
sub new {
	my ($class, $value) = @_;
	return bless {value => $value}, $class;
}
sub value {
	my $self = shift;
	my $value = $self->{value};
	return @$value if ref($value) eq 'ARRAY';
	return %$value if ref($value) eq 'HASH';
	return $$value if ref($value) eq 'SCALAR';
	return $value;
}

1;
