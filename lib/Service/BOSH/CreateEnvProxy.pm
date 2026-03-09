package Service::BOSH::CreateEnvProxy;

use base 'Service::BOSH';
use Genesis;

### Class Methods {{{

# new - create a new Service::BOSH::CreateEnvProxy object {{{
sub new {
	my ($class, $env) = @_;
	my $self = bless({}, $class);
	$self->{alias} = $env ? $env->name : 'create-env';
	return $self;
}

# }}}
# }}}

### Instance Methods {{{

# alias - specify the name of the bosh director {{{
sub alias {
	return $_[0]->{alias} || 'create-env';
}

# }}}

# create_env - create the environment for the given manifest {{{
sub create_env {
	my ($self, $manifest, %opts) = @_;
	bug("Missing deployment manifest in call to create_env()!!")
		unless $manifest;
	bug("Missing 'state' option in call to create_env()!!")
		unless $opts{state};

	$opts{flags} ||= [];
	push(@{$opts{flags}}, '--state', $opts{state});
	push(@{$opts{flags}}, '--vars-store', $opts{store}) if $opts{store} && -f $opts{store};
	push(@{$opts{flags}}, '-l', $opts{vars_file}) if ($opts{vars_file} && -f $opts{vars_file});

	return $self->execute( { interactive => 1},
		'create-env', @{$opts{flags}}, $manifest
	);
}

# }}}
# delete_env - delete the environment for the given manifest {{{
sub delete_env {
	my ($self, $manifest, %opts) = @_;
	bug("Missing deployment manifest in call to delete_env()!!")
		unless $manifest;
	bug("Missing 'state' option in call to delete_env()!!")
		unless $opts{state};

	$opts{flags} ||= [];
	push(@{$opts{flags}}, '--state', $opts{state});
	push(@{$opts{flags}}, '--vars-store', $opts{store}) if $opts{store} && -f $opts{store};
	push(@{$opts{flags}}, '-l', $opts{vars_file}) if $opts{vars_file} && -f $opts{vars_file};

	if ($opts{dryrun}) {
		$self->dryrun_of('delete-env', @{$opts{flags}}, $manifest);
		return wantarray ? (undef, 0, undef) : 1;
	}

	my ($out, $rc) = $self->execute( { interactive => 1},
		'delete-env', @{$opts{flags}}, $manifest
	);
	return wantarray ? ($out, $rc, undef) : $rc ? 0 : 1;
}

# }}}
# connect_and_validate - connect to the BOSH director and validate access {{{
sub connect_and_validate {
	my ($self) = @_;
	return $self if ref($self)->command;
	bail('Missing bosh cli command');
}

# }}}
# download_confgs - download configuration(s) of the given type (and optional name) {{{
sub download_configs {
	bail('create-env environments do not support configuration files');
}

# }}}
# }}}
1
# vim: fdm=marker:foldlevel=1:noet
