package Genesis::Kit

sub download {
	my ($class, $name, $want) = @_;


sub find {
	my ($class, $name, $version) = @_;

	return $class->new($name, $version);
}

sub new {
	my ($class, $name, $version) = @_;

	bless({
		name    => $name,
		version => $version,
	}, $class);
}

sub local {
	my $self = new(@_);
	return -f $self->tarball ? undef
	                         : $self;
}

sub id {
	my ($self) = @_;
	return "$self->{name}/$self->{version}";
}

sub url {
	my ($self) = @_;

	my $creds = "";
	if ($ENV{GITHUB_USER} && $ENV{GITHUB_AUTH_TOKEN}) {
		$creds = "$ENV{GITHUB_USER}:$ENV{GITHUB_AUTH_TOKEN}";
	}
	my ($code, $msg, $data) = curl "GET", "https://api.github.com/repos/genesis-community/$name-genesis-kit/releases", undef, undef, 0, $creds;
	if ($code == 404) {
		die "Could not find Genesis Kit $name on Github; does https://github.com/genesis-community/$name-genesis-kit/releases exist?\n";
	}
	if ($code != 200) {
		die "Could not find Genesis Kit $name release information; Github returned a ".$msg."\n";
	}

	my $releases;
	eval { $releases = decode_json($data); 1 }
		or die "Failed to read releases information from Github: $@\n";

	if (!@$releases) {
		die "No released versions of Genesis Kit $name found at https://github.com/genesis-community/$name-genesis-kit/releases.\n";
	}

	for (map { @{$_->{assets} || []} } @$releases) {
		if ($version eq 'latest') {
			next unless $_->{name} =~ m/^\Q$name\E-(.*)\.(tar\.gz|tgz)$/;
			$version = $1;
		} else {
			next unless $_->{name} eq "$name-$version.tar.gz"
			         or $_->{name} eq "$name-$version.tgz";
		}
		return ($_->{browser_download_url}, $version);
	}

	die "$name/$version tarball asset not found on Github.  Oops.\n";
}

sub tarball {
	my ($self) = @_;
	return ".genesis/kits/$self->{name}-$self->{version}.tar.gz";
}

sub extract {
	my ($self) = @_;
	return if $self->{__cache};
	$self->{__cache} = tempdir(CLEANUP => 1);
	run({ onfailure => 'Could not read kit file' },
	    'tar -xz -C "$1" --strip-components 1 -f "$2"',
	    $self->{__cache}, $self->tarball);

	Genesis::Helpers->write("$self->{__cache}/.helper");
	return 1;
}

sub path {
	my ($self, $path) = @_;
	$path =~ s|^/+||;

	$self->extract;
	return $self->{__cache}."/$path";
}

sub check_prereqs {
	my ($self) = @_;
}

sub has_hook {
	my ($self, $hook) = @_;
	return -f $self->path("hooks/$hook");
}

sub run_hook {
	my ($self, $hook, %opts) = @_;
	$self->extract;

	my @args;
	if ($hook eq 'new') {
		# hooks/new root-path env-name vault-prefix
		@args = (
			$opts{root},
			$opts{env},
			$opts{vault},
		);

	} elsif ($hook eq 'secrets') {
		# hook/secret action env-name vault-prefix
		@args = (
			$opts{action},
			$opts{env},
			$opts{vault},
		);

	} elsif ($hook eq 'blueprint') {
		# hooks/blueprint
		@args = ();

	} elsif ($hook eq 'info') {
		# hooks/info env-name
		@args = (
			$opts{env},
		);

	} elsif ($hook eq 'addon') {
		# hooks/addon script [user-supplied-args ...]
		@args = (
			$opts{script},
			@{$opts{args} || []},
		);

	} else {
		die "Unrecognized hook '$hook'\n";
	}

	my ($out, $rc) = run(
		'cd "$1"; source .helper; hook=$2; shift 2; ./hooks/$hook "$@"',
		$self->{__cache}, $hook, @args);

	if ($hook eq 'new') {
		if ($rc != 0) {
			die "Could not create new env $args[0]\n";
		}
		if (! -f "$args[0].yml") {
			die "Could not create new env $args[0]\n";
		}
	}

	if ($rc != 0) {
		die "Could not run '$hook' hook successfully\n";
	}

	return 1;
}

1;
