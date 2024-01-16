package Genesis::Env::Secrets::Parser;

use strict;
use warnings;

use Genesis;

# Class Methods

sub new {
	my ($class, $env) = @_;

	my $self= bless({
		env => $env,
	},$class);
}

# Instance Methods

sub env {$_[0]->{env}}

sub parse {}

1;
# vim: fdm=marker:foldlevel=1:noet
