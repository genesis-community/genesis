package MockWrapper;

# MockWrapper
#
# A mock object that delegates to a wrapped object for methods not explicitly
# defined. This allows testing code that uses complex objects by wrapping the
# real object and overriding only specific methods.
#
# Usage:
# my $wrapper = MockWrapper->new($real_object,
#   source_yaml_files => sub { return () },  # Override this method
# );
#
# $wrapper->source_yaml_files();  # Returns () from override
# $wrapper->other_method();       # Delegates to $real_object->other_method()
#
# For hash access, use _get/$key) or access wrapped object directly via _defer_to

use parent 'Mock';

sub new {
	my ($class, $defer_to, %args) = @_;
	my $self = $class->SUPER::new(%args);
	$self->{__defer_to} = $defer_to;
	return $self;
}

# Access hash key - checks local first, then deferred object
sub _get {
	my ($self, $key) = @_;
	return $self->{$key} if exists $self->{$key};
	return $self->{__defer_to}{$key} if $self->{__defer_to} && exists $self->{__defer_to}{$key};
	return undef;
}

# Get the wrapped object directly
sub _defer_to {
	my ($self) = @_;
	return $self->{__defer_to};
}

sub _mock_get_response {
	my ($self, $method, @args) = @_;

	# First check if we have a response set or a defined method in our overrides
	if (exists $self->{__responses}{$method} || exists $self->{$method}) {
		return $self->SUPER::_mock_get_response($method, @args);
	}

	# Otherwise delegate to the wrapped object
	if ($self->{__defer_to} && $self->{__defer_to}->can($method)) {
		return $self->{__defer_to}->$method(@args);
	}

	# Fall back to parent behavior (will die with error)
	return $self->SUPER::_mock_get_response($method, @args);
}

1;
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
