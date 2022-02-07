package Genesis::Kit::Secret;
use strict;
use warnings;
use Genesis (qw/bug explain/);

sub new { 
  my ($class,$path,%opts) = @_;
  bug 'Cannot directly instantiate a Genesis::Kit::Secret - use build to instanciate a derived class'
    if $class eq __PACKAGE__;

  my ($args,$errors,$alt_path) = $class->validate_definition($path,%opts);
  if ($errors && ref($errors) eq 'ARRAY' and @{$errors}) {
    return $class->reject(
      "Errors in definition for ${class}->new call:".join("\n- ", '', @{$errors}),
      $path, $class->type(), $args
    );
  } else {
    return bless({
      path => $alt_path || $path,
      definition => $args,
      value => {}
    }, $class);
  }
}

sub build {
  my ($class,$path,$type,%definition) = @_;
  explain("called $type -> $path");
  bug ('Cannot call build on %s -- use build on %s', $class, __PACKAGE__)
    if $class ne __PACKAGE__;

  my $package = class_of($type);
  my $loaded = eval "require $package";
  return $class->reject(
    "No secret definition found for type $type - cannot parse.",
    $path, $type, {%definition}
  ) unless $loaded;


  my $secret = eval "$package->new(\$path,\%definition);";
  my $err = $@;
  return $class->reject(
    "$err", $path, $type, {%definition}
  ) if $err;
  return $secret;
}

sub reject {
  my ($class,$error, $path, $type, $args) = @_;
  explain("reporting error $type -> $path");
  require Genesis::Kit::Secret::Invalid;
  return Genesis::Kit::Secret::Invalid->new($type,$path,$error,$args);
}

sub validate_definition {
  my ($class, $path, %opts) = @_;

  unless ($ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION}) {
    return $class->_validate_constructor_opts($path, %opts) if $class->can('_validate_constructor_opts');

    my @errors;
    my @required_options = $class->_required_constructor_opts;
  	my @valid_options = (@required_options, $class->_optional_constructor_opts);
  	push(@errors, "Missing required '$_' argument") for grep {!$opts{$_}} @required_options;
  	push(@errors, "Unknown '$_' argument specified") for grep {my $k = $_; ! grep {$_ eq $k} @valid_options} keys(%opts);
    return (
      \%opts,
      \@errors, 
      $path,
    ) if @errors; 
  }
  return (\%opts, $path);
}

sub _required_constructor_opts {
  bug('%s did not define _required_contructor_opts', $_[0])
}

sub _optional_constructor_opts {
  bug('%s did not define _optional_constructor_opts', $_[0])
}

sub type {
  my $ref = shift;
  my $type = ref($ref) || $ref; # Handle class or object
  $type =~ s/.*:://;
  ({
    # Put exceptions here
  })->{$type} || lc($type);
}

sub class_of {
  my $type = shift;
  __PACKAGE__."::".(({
    ssh => 'SSH',
    rsa => 'RSA',# Put exceptions here
  })->{$type} || ucfirst($type));
}

# validate - return error if the secret definition is valid
sub validate {
  return 1; # Default is always valid - override in derived class
}

### Instance Methods {{{
# describe - english description of secret {{{
sub describe {
  
  my $self = shift;
  return $self->type . " secret" unless $self->can('_description'); # default, override in derived class

  my ($type,@features) = $self->_description();
  return wantarray
    ? ($self->{path}, $type, join (", ", grep {$_} @features))
    : (@features ? sprintf('%s (%s)', $type, join (", ", grep {$_} @features)) : $type);
}

sub definition {
  %{$_[0]->{definition}}
}

1;