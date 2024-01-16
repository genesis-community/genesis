package Genesis::Secret::Invalid;
use strict;
use warnings;
no warnings 'once';

use base "Genesis::Secret";

sub new {
	my $obj = shift->SUPER::new(@_);
	return $obj;
}

sub valid {0}

sub _validate_constructor_opts {
  my ($self,$path,%opts) = @_;
  return (\%opts, $path);
}

sub describe {
	my $self = shift;
	my $fmt_defn;
	{
		require YAML;
		local $YAML::UseBlock = 1;
		local $YAML::UseHeader = 0;
		local $YAML::UseAliases = 0;
		local $YAML::Stringify = 1;
		$fmt_defn = YAML::Dump($self->get('data' => '#w_{<undefined>}')) =~ s/\n/\n        /rmsg;
	}
	my $path = $self->path;
	$path .= sprintf(" (for '%s' feature in kit.yml)",$self->{feature})
		if $self->from_kit;
	$path .= sprintf(" (from variables.%s in manifest)",$self->{var_name})
		if $self->from_manifest;
	my $msg = sprintf(
		"Invalid definition for %s secret: %s\n".
		"  path: %s\n".
		"  data: %s\n",
		$self->get('subject' => "Credential at '$path'"),
		$self->get('error' => "Invalid secret definition"),
		$path,
		$fmt_defn
	);
  return wantarray
    ? ($self->{path}, $self->label, $msg)
    : $msg;
}

sub _description {
  my $self = shift;
  return ($self->{subject}, $self->{error});
}

1;
