package Genesis::Kit::Secret::SSH;
use strict;
use warnings;

use base "Genesis::Kit::Secret";

=construction arguments
size: <positive integer>
path: <relative location in secrets-store under the base>
fixed: <boolean to specify if the secret can be overwritten>
=cut

sub _validate_constructor_opts {
  my ($self,$path,%opts) = @_;

  my $orig_opts = {%opts};
	my ($args, @errors);

  $args->{size} = delete($opts{size}) or
    push @errors, "Missing required 'size' argument";
	push(@errors, "Invalid size argument: expecting 1024-16384, got $args->{size}")
		if ($args->{size} && ($args->{size} !~ /^\d+$/ || $args->{size} < 1024 ||  $args->{size} > 16384));

  $args->{fixed} = !!delete($opts{fixed});
  push(@errors, "Invalid '$_' argument specified") for grep {defined($opts{$_})} keys(%opts);
  return @errors
    ? ($orig_opts, \@errors)
    : ($args)

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