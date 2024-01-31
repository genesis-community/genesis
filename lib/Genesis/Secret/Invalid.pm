package Genesis::Secret::Invalid;
use strict;
use warnings;
no warnings 'once';

use base "Genesis::Secret";

use Genesis::Term qw(csprintf);

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
	if (ref($self->get('data'))) {
		eval {
			require YAML;
			local $YAML::UseBlock = 1;
			local $YAML::UseHeader = 0;
			local $YAML::UseAliases = 0;
			local $YAML::Stringify = 1;
			$fmt_defn = YAML::Dump($self->get('data'));
			$fmt_defn =~ s/\s*\z//ms;
			$fmt_defn =~ s/\n/\n[[        >>/msg;
		};
		if ($@) {
			require JSON::PP;
			$fmt_defn = JSON::PP->new->pretty(1)->encode($self->get('data'));
			$fmt_defn =~ s/\s*\z//ms;
			$fmt_defn =~ s/\n/\n[[        >>/msg;
		}
		$fmt_defn //= "#Ri{<invalid yaml>}" ;
	} else {
		$fmt_defn = $self->get('data' => "#yi{<undefined>}");
	}
	my $path = $self->path;
	$path = ($path =~ /:/)
		? csprintf("#C{%s}:#c{%s}", split(/:/, $path, 2))
		: csprintf("#C{%s}", $path);

	$path .= sprintf("#Ki{ (for '%s' feature in kit.yml)}",$self->{feature})
		if $self->from_kit;
	$path .= sprintf("#Ki{ (from variables.%s in manifest)}",$self->{var_name})
		if $self->from_manifest;
	my $msg = sprintf(
		"Invalid definition for %s secret:\n".
		"%s\n".
		csprintf("[[  #Ki{path:} >>%%s\n").
		csprintf("[[  #Ki{data: >>%%s}\n"),
		$self->get('subject' => "Unknown"),
		join("\n", map {
				my $err = $_;
				"[[- >>".join("\n[[  >>",split(/\n/,$err))
			} @{$self->get('errors' => ["Invalid secret definition"])}),
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
