package Genesis::Base;

use strict;
use warnings;
use utf8;

# _memoize - cache value to be returned on subsequent calls {{{
sub _memoize {
	my ($self, $token, $initialize) = @_;
	if (ref($token) eq 'CODE') {
		$initialize = $token;
		($token = (caller(1))[3]) =~ s/^(.*::)?/__/g;
	}
	return $self->{$token} if defined($self->{$token});
	$self->{$token} = $initialize->($self);
}

1;
