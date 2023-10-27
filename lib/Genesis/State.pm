package Genesis::State;
use strict;
use warnings;

use base 'Exporter';
our @EXPORT = qw/
	envset
	envdefault
	in_callback
	under_test
/;

sub envset {
	my $var = shift;
	(defined $ENV{$var} and scalar($ENV{$var} =~ m/^([1-9][0-9]*|y|yes|true)$/i)) ? 1 : 0;
}

sub envdefault {
	my ($var, $default) = @_;
	return defined $ENV{$var} ? $ENV{$var} : $default;
}

sub in_callback {
	envset('GENESIS_IS_HELPING_YOU');
}

sub under_test {
	envset('GENESIS_TESTING');
}

1;
