package Genesis::Kit::Secret::Invalid;
use strict;
use warnings;

use base "Genesis::Kit::Secret";

sub new { 
  my ($class,$type,$path,$error,$args) = @_;

  my %opts = ref($args) eq 'HASH' ? %$args : (args => $args);

  my $obj = $class->SUPER::new($path, %opts);
  $obj->{type} = $type;
  $obj->{error} = $error;
  return $obj;
}

sub _validate_constructor_opts {
  my ($self,$path,%opts) = @_;
  return (\%opts);
}

sub _description {
  my $self = shift;
  return ($self->{error});
}

1;