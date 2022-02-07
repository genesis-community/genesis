package Genesis::Kit::Secret::Random;
use strict;
use warnings;

use base "Genesis::Kit::Secret";

=construction arguments
size: <positive integer>
format: <optional: alternative format - one of base64, bcrypt, crypt-md5, crypt-sha256, or crypt-sha512
destination: <optional, only legal if format specified: path relative to secrets-store base to store the formatted value>
valid_chars: <optional, specify a subset of characters that can be used to generate the value>
fixed: <boolean to specify if the secret can be overwritten>
=cut

sub _validate_constructor_opts {
  my ($self,$path,%opts) = @_;

  my @errors;
  my %orig_opts = %opts;
  my $args = {};
  $args->{size} = delete($opts{size}) or 
    push @errors, "Requires a non-zero positive integer for 'size'";
  if ($args->{format} = delete($opts{format})) {
    $args->{destination} = delete($opts{destination}) if defined($opts{destination});
  }
  $args->{valid_chars} = delete($opts{valid_chars}) if defined($opts{valid_chars});
  $args->{fixed} = !!delete($opts{fixed});

  use Pry; pry if $path eq 'blobstore/agent:password';
  push(@errors, "Invalid '$_' argument specified") for grep {defined($opts{$_})} keys(%opts);
  return @errors
    ? (\%orig_opts, \@errors)
    : ($args)

}

sub _description {
  my $self = shift;
  return (
    "random password",
    $self->{definition}{size} . ' bytes',
    $self->{definition}{fixed} ? 'fixed' : undef
  );
}

1;