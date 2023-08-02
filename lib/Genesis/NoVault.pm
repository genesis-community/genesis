package Genesis::NoVault;
use strict;
use warnings;

use Genesis;

### Class Variables {{{
# }}}

### Class Methods {{{

# new - raw instantiation of a no-vault object {{{
sub new {
	my ($class, @args) = @_;
	return bless({}, $class);
}
# }}}
# }}}

### Instance Methods {{{

sub DESTROY {} # Prevents AUTOLOAD from causing a problem

sub name {return ''}

# AUTOLOAD - errors out when a normal vault method is called {{{
our $AUTOLOAD;
sub AUTOLOAD {

	my ($class, @args) = @_;
	my $field = $AUTOLOAD;
	$field =~ s/.*:://;

	bug("The command $ENV{GENESIS_COMMAND} should not need a vault, but is asking for one");
}

# }}}
# }}}

1

# vim: fdm=marker:foldlevel=1:noet
