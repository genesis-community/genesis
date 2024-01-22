package Genesis::Secret::UUID;
use strict;
use warnings;

use base "Genesis::Secret";

use UUID::Tiny ();

### Construction arguments {{{
# version:   <UUID Version - one of: v1, v3, v4, v5 or the equivalent descriptive version (time, md5, random, sha1)>
# path:      <relative location in secrets-store under the base>
# namespace: <optional: UUID namespace, applicable to v3 and v4>
# name:      <optional: identifier, applicable to v3 and v4>
# fixed:     <boolean to specify if the secret can be overwritten>
# }}}

### Instance Methods {{{
# generate_value - generate a new UUID value {{{
sub generate_value {
	my $self = @_;
	my $version=(\&{"UUID::Tiny::UUID_".$self->get('version')})->();
	my $ns=(\&{"UUID::Tiny::UUID_".$self->get('namespace')})->()
		if ($self->get('namespace')||'') =~ m/^NS_/;
	$ns ||= $self->get('namespace');
	UUID::Tiny::create_uuid_as_string($version, $ns, $self->get('name'));
}

# }}}
sub process_command_output {
	my ($self, $action, $out) = @_;
	return $out unless $action eq 'add';
	join("\n",
		grep {
			my (undef, $key) = split(':',$self->path);
			$_ !~ /^$key: [a-f0-9]{8}(-[a-f0-9]{4}){4}[a-f0-9]{8}$/;
		} split("\n", $out)
	);
}
# }}}

### Polymorphic Instance Methods {{{
# label - specific label for this derived class {{{
sub label {'UUID'}
# }}}
# }}}

### Parent-called Support Instance Methods {{{
# _validate_constructor_opts - make sure secret definition is valid {{{
sub _validate_constructor_opts {
  my ($self,$path,%opts) = @_;

  my $orig_opts = {%opts};
	my ($args, @errors);

	my $version = delete($opts{version}) || 'v4';
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

# }}}
# _validate_value - validate the value conforms to described UUID parameters {{{
sub _validate_value {
	my ($self, $store) = @_;
	my $value = $self->value;;
	my %results;
	my @validations = qw/valid/;

	my $version = $self->get('version');
	if (UUID::Tiny::is_uuid_string $value) {
		$results{valid} = ['ok', "Valid UUID string"];
		push @validations, '';
		if ($version =~ m/^(v3|md5|v5|sha1)$/i) {
			my $v=(\&{"UUID::Tiny::UUID_$version"})->();
			my $ns=(\&{"UUID::Tiny::UUID_".$self->get('namespace')})->() if ($self->get('namespace')||'') =~ m/^NS_/;
			$ns ||= $self->get('namespace');
			my $uuid = UUID::Tiny::create_uuid_as_string($v, $ns, $self->get('name'));
			$results{hash} = [
				$uuid eq $value,
				"Correct for given name and namespace".($uuid eq $value ? '' : ": expected $uuid, got $value")
			];
			push @validations, 'hash';
		}
	} else {
		$results{valid} = ['error', "valid UUID: expecting xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxx, got ".$value];
	}
	return (\%results, @validations);
}

# }}}
# _description - return label and features to build describe output {{{
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

# }}}
# __get_safe_command_for_generate - get command components to add or rotate secret {{{
sub __get_safe_command_for_generate {
	my ($self, $action, %opts) = @_;
	my $uuid = $self->generate_value;
	my ($path, $key) = split(':',$self->path);
	my @cmd = ('set', $self->base_path.$path, "$key=$uuid");
	push(@cmd, '--no-clobber') if $action eq 'add' || $self->get(fixed => 0);
	return @cmd;
}

sub _get_safe_command_for_add    {shift->__get_safe_command_for_generate('add',@_)}
sub _get_safe_command_for_rotate {shift->__get_safe_command_for_generate('rotate',@_)}

# }}}
# }}}

1;
# vim: fdm=marker:foldlevel=1:noet
