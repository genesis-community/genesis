package Genesis::Kit::Secret::Provided;
use strict;
use warnings;

use base "Genesis::Kit::Secret";

=construction arguments
prompt: <user prompt>
sensitive: <boolean, optional: will hide input, and require confirmation, if true>
multiline: <boolean, optional: will provide multi-line input support if true>
subtype: <future-proofing; may alter construction or behaviour (ie for providing x509 certs) >
fixed: <boolean to specify if the secret can be overwritten>
=cut

sub _required_constructor_opts {
  qw/prompt/
}

sub _optional_constructor_opts {
  qw/sensitive multiline subtype fixed/
}

sub _description {
  my $self = shift;
  return (
    "user-provided secret",
    $self->{definition}{prompt},
    $self->{definition}{fixed} ? 'fixed' : undef
  );
}

1;