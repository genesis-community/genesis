package Genesis::Kit::Secret::Dhparams;
use strict;
use warnings;

use base "Genesis::Kit::Secret";

=construction arguments
version: <UUID Version - one of: v1, v3, v4, v5 or the equivalent descriptive version (time, md5, random, sha1)>
path: <relative location in secrets-store under the base>
namespace: <optional: UUID namespace, applicable to v3 and v4>
name: <optional: identifier, applicable to v3 and v4>
fixed: <boolean to specify if the secret can be overwritten>
=cut

# TODO: use _validate_constructor_opts for dynamic requirements 
sub _validate_constructor_opts {
  my ($self,$path,%opts) = @_;

  my $orig_opts = {%opts};
	my ($args, @errors);

	my $version = delete(%opts{version}) || 'v4';
	$version = lc($version);
	if ($version =~ m/^(v3|v5|md5|sha1)$/i) {
		$args->{namespace} = delete($opts{namespace}) if defined($opts{namespace});
		$args->{name} = delete($opts{name}) or
		  push @errors, "$version UUIDs require a name argument to be specified";
	} elsif ($version !~ m/^(v1|v4|time|random)$/i) {
		push(@errors, "Invalid version argument: expecting one of v1, v3, v4, or v5 (or descriptive name of time, md5, random, or sha1)")
	}
	$args->{version} = $version;
	$args->{fixed} = !!delete($opts{fixed});
	push(@errors, "Invalid '$_' argument specified for version $version") for grep {defined($opts{$_})} keys(%opts);
  return @errors
    ? ($orig_opts, \@errors)
    : ($args)
}

sub _description {
  my $self = shift;

  my @features;
	my $namespace = $self->{definition}{namespace} ? "ns:$self->{namespace}" : undef;
	$namespace =~ s/^ns:NS_/ns:@/ if $namespace;
	if ($self->{definition}{version} =~ /^(v1|time)/i) {
		@features = ('random:time based (v1)')
	} elsif ($self->{definition}{version} =~ /^(v3|md5)/i) {
		@features = (
			'static:md5-hash (v3)',
			"'$self->{name}'",
			$namespace
		);
	} elsif ($self->{definition}{version} =~ /^(v4|random)/i) {
		@features = ('random:system RNG based (v4)')
	} elsif ($self->{definition}{version} =~ /^(v5|sha1)/i) {
		@features = (
			'static:sha1-hash (v5)',
			"'$self->{name}'",
			$namespace,
		);
	}
	push(@features, 'fixed') if $self->{definition}{fixed};
  return ('UUID', @features);
}

1;