package Genesis::BOSH::CreateEnvProxy;

use base 'Genesis::BOSH';
use Genesis;

### Class Methods {{{

# new - create a new Genesis::BOSH::CreateEnvProxy object {{{
sub new {
	my ($class) = @_;
	return bless({}, $class);
}

# }}}
# }}}

### Instance Methods {{{

# create_env - create the environment for the given manifest {{{
sub create_env {
	my ($self, $manifest, %opts) = @_;
	bug("Missing deployment manifest in call to create_env()!!")
		unless $manifest;
	bug("Missing 'state' option in call to create_env()!!")
		unless $opts{state};

	$opts{flags} ||= [];
	push(@{$opts{flags}}, '--state', $opts{state});
	push(@{$opts{flags}}, '--vars-store', $opts{store}) if $opts{store};
	push(@{$opts{flags}}, '-l', $opts{vars_file}) if ($opts{vars_file});

	return $self->execute( { interactive => 1},
		'bosh', 'create-env',  @{$opts{flags}}, $manifest
	);
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
	bail('#R{[ERROR]} create-env environments do not support configuration files');
}

# }}}
# }}}
1
# vim: fdm=marker:foldlevel=1:noet
