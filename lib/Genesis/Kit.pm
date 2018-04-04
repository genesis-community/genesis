package Genesis::Kit;
use strict;
use warnings;

use Genesis::Utils;
use Genesis::IO;
use Genesis::Run;
use Genesis::Helpers;

sub url {
	my ($self) = @_;

	my $creds = "";
	if ($ENV{GITHUB_USER} && $ENV{GITHUB_AUTH_TOKEN}) {
		$creds = "$ENV{GITHUB_USER}:$ENV{GITHUB_AUTH_TOKEN}";
	}
	my ($code, $msg, $data) = curl("GET", "https://api.github.com/repos/genesis-community/$self->{name}-genesis-kit/releases", undef, undef, 0, $creds);
	if ($code == 404) {
		die "Could not find Genesis Kit $self->{name} on Github; does https://github.com/genesis-community/$self->{name}-genesis-kit/releases exist?\n";
	}
	if ($code != 200) {
		die "Could not find Genesis Kit $self->{name} release information; Github returned a ".$msg."\n";
	}

	my $releases;
	eval { $releases = decode_json($data); 1 }
		or die "Failed to read releases information from Github: $@\n";

	if (!@$releases) {
		die "No released versions of Genesis Kit $self->{name} found at https://github.com/genesis-community/$self->{name}-genesis-kit/releases.\n";
	}

	for (map { @{$_->{assets} || []} } @$releases) {
		if ($self->{version} eq 'latest') {
			next unless $_->{name} =~ m/^\Q$self->{name}\E-(.*)\.(tar\.gz|tgz)$/;
			$self->{version} = $1;
		} else {
			next unless $_->{name} eq "$self->{name}-$self->{version}.tar.gz"
			         or $_->{name} eq "$self->{name}-$self->{version}.tgz";
		}
		return ($_->{browser_download_url}, $self->{version});
	}

	die "$self->{name}/$self->{version} tarball asset not found on Github.  Oops.\n";
}

sub path {
	my ($self, $path) = @_;
	$self->extract;
	die "self->extract did not set self->{root}; this is a bug in Genesis!\n"
		unless $self->{root};

	return $self->{root} unless $path;

	$path =~ s|^/+||;
	return "$self->{root}/$path";
}

sub glob {
	my ($self, $glob) = @_;
	$glob =~ s|^/+||;

	$self->extract;
	die "self->extract did not set self->{root}; this is a bug in Genesis!\n"
		unless $self->{root};
	return glob "$self->{root}/$glob";
}

sub has_hook {
	my ($self, $hook) = @_;
	return -f $self->path("hooks/$hook");
}

sub run_hook {
	my ($self, $hook, %opts) = @_;

	die "No '$hook' hook script found\n"
		unless $self->has_hook($hook);

	local %ENV = %ENV;
	$ENV{GENESIS_KIT_NAME}     = $self->{name};
	$ENV{GENESIS_KIT_VERSION}  = $self->{version};
	$ENV{GENESIS_ROOT}         = $opts{root};  # to be replaced with ::Env
	$ENV{GENESIS_ENVIRONMENT}  = $opts{env};   # to be replaced with ::Env
	$ENV{GENESIS_VAULT_PREFIX} = $opts{vault}; # to be replaced with ::Env

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

	##### LEGACY HOOKS
	} elsif ($hook eq 'prereqs') {
		# hooks/prereqs
		@args = ();

	} elsif ($hook eq 'subkit') {
		# hooks/subkits
		@args = @{$opts{features} || []};

	} else {
		die "Unrecognized hook '$hook'\n";
	}

	chmod 0755, $self->path("hooks/$hook");
	my ($out, $rc) = run({ interactive => $hook eq 'new' },
		'cd "$1"; source .helper; hook=$2; shift 2; ./hooks/$hook "$@"',
		$self->path, $hook, @args);

	if ($hook eq 'new') {
		if ($rc != 0) {
			die "Could not create new env $args[0]\n";
		}
		if (! -f "$args[0].yml") {
			die "Could not create new env $args[0]\n";
		}
		return 1;
	}

	if ($hook eq 'blueprint') {
		if ($rc != 0) {
			die "Could not determine what YAML files to merge from the kit blueprint\n";
		}
		$out =~ s/^\s+//;
		return split(/ /, $out); # FIXME broken
	}

	if ($hook eq 'subkits') {
		if ($rc != 0) {
			die "Could not determine what auxiliary kits (if any) needed to be activated\n";
		}
		$out =~ s/^\s+//;
		return split(/ /, $out); # FIXME broken
	}

	if ($rc != 0) {
		die "Could not run '$hook' hook successfully\n";
	}
	return 1;
}

sub metadata {
	my ($self) = @_;
	return $self->{__metadata} ||= LoadFile($self->path('kit.yml'));
}

sub source_yaml_files {
	my ($self, @features) = @_;

	my @files;
	if ($self->has_hook('blueprint')) {
		local $ENV{GENESIS_REQUESTED_FEATURES} = join(' ', @features);
		@files = $self->run_hook('blueprint');

	} else {
		@files = $self->glob("base/*.yml");
		push @files, map { $self->glob("subkits/$_/*.yml") } @features;
	}

	return @files;
}

1;
