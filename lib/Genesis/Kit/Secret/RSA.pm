package Genesis::Kit::Secret::RSA;
use strict;
use warnings;

use base "Genesis::Kit::Secret";

=construction arguments
size: <positive integer>
path: <relative location in secrets-store under the base>
fixed: <boolean to specify if the secret can be overwritten>
=cut

sub _required_constructor_opts {
  qw/size/
}

sub _optional_constructor_opts {
  qw/fixed/
}

sub _description {
  my $self = shift;

  return (
    uc($self->type)." public/private keypair",
    $self->{definition}{size} . ' bytes',
    $self->{definition}{fixed} ? 'fixed' : undef
  );
}

1;