package Genesis::BOSH;

use Genesis;

sub _bosh {
	my @args = @_;

	die "Unable to determine where the bosh CLI lives.  This is a bug, please report it.\n"
		unless $ENV{GENESIS_BOSH_COMMAND};

	my $opts = (ref($args[0]) eq 'HASH') ? shift @args : {};
	$opts->{env} ||= {};

	# Clear out the BOSH env vars unless we shouldn't
	unless ($ENV{GENESIS_HONOR_ENV}) {
		$opts->{env}{HTTPS_PROXY} = ''; # bosh dislikes this env var
		$opts->{env}{https_proxy} = ''; # bosh dislikes this env var

		$opts->{env}{BOSH_ENVIRONMENT}   ||= ''; # ensure using ~/.bosh/config via alias
		$opts->{env}{BOSH_CA_CERT}       ||= '';
		$opts->{env}{BOSH_CLIENT}        ||= '';
		$opts->{env}{BOSH_CLIENT_SECRET} ||= '';
	}

	if ($args[0] =~ m/^bosh(\s|$)/) {
		# ('bosh', 'do', 'things') or 'bosh do things'
		$args[0] =~ s/^bosh/$ENV{GENESIS_BOSH_COMMAND}/;

	} elsif ($args[0] =~ /\$\{?[\@0-9]/) {
		# ('deploy "$1" | jq -r .whatever', $d)
		$args[0] = "$ENV{GENESIS_BOSH_COMMAND} $args[0]";

	} else {
		# ('deploy', $d)
		unshift @args, $ENV{GENESIS_BOSH_COMMAND};
	}

	return run($opts, @args);
}

sub config {
	my ($class, $alias) = @_;

	return {} unless -f "$ENV{HOME}/.bosh/config";
	my $bosh = load_yaml_file("$ENV{HOME}/.bosh/config")
		or return {};

	for my $e (@{ $bosh->{environments} || []  }) {
		return $e if $e->{alias} eq $alias;
	}

	return {};
}

sub environment_variables {
	my ($class, $alias) = @_;

	my $e = $class->config($alias);
	return {} unless %$e;
	return {
		BOSH_ENVIRONMENT   => $e->{url},
		BOSH_CA_CERT       => $e->{ca_cert},
		BOSH_CLIENT        => $e->{username},
		BOSH_CLIENT_SECRET => $e->{password},
	}
}

my $reping;
sub ping {
	my ($class, $env) = @_;
	# TODO: once using vault-stored bosh targetting, we don't need to do this anymore
	debug "Checking BOSH at '$env' for connectivity";
	my $waiting=0;
	unless ($reping || envset "GENESIS_TESTING") {;
		waiting_on STDERR "Checking availability of the '#M{$env}' BOSH director...";
		$waiting=1;
	}
	$reping = 1;

	my ($host,$port);
	if ($env =~ qr(^http(s?)://(.*?)(?::([0-9]*))?$)) {
		$host = $2;
		$port = $3 || 25555;
	} else {
		my $config = $class->config($env);
		bail("#R{error!}\n\nCannot find bosh environment '#M{$env}' in the local ~/.bosh/config\n")
			unless %$config;

		$config->{url} =~ qr(^http(s?)://(.*?)(?::([0-9]*))?$) or
			bail("#R{error!}\n\nInvalid BOSH director URL #C{%s}: expecting http(s)://ip-or-domain(:port)\n", $config->{url});
		$host = $2;
		$port = $3 || 25555;
	}

	unless (tcp_listening($host,$port)) {
		error "#R{unreachable!}\n" if $waiting;
		return 0;
	}
	my ($out,$rc) = _bosh('bosh', '-e', $env, 'env');
	if ($rc) {
		error "#R{error!}\n\n$out\n" if $waiting;
		return 0;
	}
	explain STDERR "#G{ok}" if $waiting;
	return 1;
}

sub env {
	my ($class, $env) = @_;
	return _bosh({ interactive => 1, passfail => 1 },
		'bosh', '-e', $env, 'env');
}

sub create_env {
	my ($class, $manifest, %opts) = @_;
	bug("Missing deployment manifest in call to create_env()!!")
		unless $manifest;
	bug("Missing 'state' option in call to create_env()!!")
		unless $opts{state};

	$opts{flags} ||= [];
	push(@{$opts{flags}}, '--state', $opts{state});
	push(@{$opts{flags}}, '-l', $opts{vars_file}) if ($opts{vars_file});

	return _bosh({ interactive => 1, passfail => 1 },
		'bosh', $ENV{BOSH_NON_INTERACTIVE} ? '-n' : (),
		'create-env',  @{$opts{flags}}, $manifest);
}

sub download_cloud_config {
	my ($class, $env, $path) = @_;
	waiting_on STDERR "Downloading cloud config from '#M{$env}' BOSH director...";
	_bosh({ interactive => 1, onfailure => "Could not download cloud-config from $env BOSH director" },
		'bosh -e "$1" cloud-config > "$2"', $env, $path);

	bail "#R{error!}  No cloud-config defined on '#M{$env}' BOSH director\n" unless (-s $path);
	explain STDERR "#G{ok}";
	return 1;
}

sub deploy {
	my ($class, $env, %opts) = @_;
	bug("Missing BOSH environment name in call to deploy()!!")
		unless $env;

	for my $o (qw(manifest deployment)) {
		bug("Missing '$o' option in call to deploy()!!")
			unless $opts{$o};
	}
	$opts{flags} ||= [];
	push(@{$opts{flags}}, "-l", $opts{vars_file}) if ($opts{vars_file});

	return _bosh({ interactive => 1, passfail => 1 },
		'bosh', '-e', $env, '-d', $opts{deployment},
		$ENV{BOSH_NON_INTERACTIVE} ? '-n' : (),
		'deploy', @{$opts{flags}}, $opts{manifest});
}

sub alias {
	my ($class, $alias) = @_;
	_bosh({ interactive => 1, onfailure => "Could not create BOSH alias for '$_[0]'" },
		'bosh', 'alias-env', $alias);
}

sub run_errand {
	my ($class, $env, %opts) = @_;
	bug("Missing BOSH environment name in call to run_errand()!!")
		unless $env;

	for my $o (qw(deployment errand)) {
		bug("Missing '$o' option in call to run_errand()!!")
			unless $opts{$o};
	}

	_bosh({ interactive => 1, onfailure => "Failed to run errand '$opts{errand}' ($opts{deployment} deployment on $env BOSH director)" },
		'bosh', '-n', '-e', $env, '-d', $opts{deployment}, 'run-errand', $opts{errand});

	return 1;
}

1;

=head1 NAME

Genesis::BOSH

=head1 DESCRIPTION

This module provides (namespaced) wrapper functions for running commands
against a BOSH director, with the appropriate error and environment
handling.

All of these functions should be called as class methods, like so:

    use Genesis::BOSH;
    Genesis::BOSH->ping('https://10.0.0.4:25555')
      or die "Unable to talk to BOSH!\n";

Most of these functions will die() if they encounter any issues running the
given BOSH command (with C<ping()> being a notable exception!)

=head1 CLASS METHODS

=head2 environment_variables($alias)

Returns a hash ref of environment variables and values corresponding to the
BOSH Director matching the specified alias name.  Returns an empty hash ref if
no alias matches or if the ~/.bosh/config file is unreadable.

=head2 ping($env)

Try to contact the BOSH director at C<$env>, and report success or failure.

=head2 env($env)

Similar to C<ping>, this tries to contact the BOSH director at C<$env>, and
reports success or failure.  However, this function prints its output to the
user, so it is useful in presenting the environment's details.

=head2 create_env($manifest, %opts)

Run a C<bosh create-env> of the given manifest.  The only supported option
is B<state>, which holds the path to the persistent state file, and is
required.  If the C<$BOSH_NON_INTERACTIVE> environment variable is set, this
will run with a C<-n> flag as well, to avoid prompting the user.


=head2 download_cloud_config($env, $file)

Downloads the current cloud-config from the BOSH director, and stores it in
the given C<$file>.


=head2 deploy($manifest, %opts)

Deploy the given C<$manfiest> to a BOSH director.  Supported options are:

=over

=item target

The name or URL of the BOSH director to deploy to.  This option is required.

=item deployment

The name of the deployment to deploy.  This option is required, and must
match the C<name> property in C<$manifest>.

=item options

An arrayref of flags and their values, to pass through to the underlying
C<bosh> command invocation.

=back


=head2 alias($env)

Creates a new BOSH alias via C<bosh alias-env>.  This function takes no
arguments, and expects all of the settings for things like IP, CA
certificate, etc. to be found in the environment variables.

This is probably bad and we should change it.  (FIXME)


=head2 run_errand($env, $deployment, $errand)

Runs the named C<$errand> against the given C<$deployment>, and bails if the
errand doesn't succeed.


=head1 INTERNAL FUNCTIONS

These functions are implementation details of this module, and should not
concern anyone else, ever.


=head2 _bosh(...)

This is a wrapper function to Genesis::Utils's C<run()> function.  It
does things that are useful if you are running the C<bosh> CLI, and not
anything else.  Specifically, it:

=over

=item 1.

Clears the https proxy environment variables because this does bad things to
BOSH.  It clears out both the lowercase (https_proxy) and upercase
(HTTPS_PROXY) versions.

=item 2.

Clears the BOSH_ENVIRONENT, BOSH_CA_CERT, BOSH_CLIENT, and
BOSH_CLIENT_SECRET unless explicitly sent in via the C<env> option.  This
allows B<Genesis> to specify these values when needed, but removes any
exposure to these set from the caller's environment.

=item 3.

Runs the command with the correct version of the BOSH CLI executable.  The
command may or may not be provided with C<bosh> as the first item; if it
does, it is replaced with the correct path, if not, the correct path is
prepended to the command before it is called.

=back

Otherwise it is exactly the same as the C<run> command, and supports all the
same syntax and options -- see C<run>'s documentation for more details.

Note that you can leave off the actual "bosh" token in your command, and
C<_bosh()> will do what you mean:

    # this:
    _bosh('bosh deploy -d concourse manifest.yml');

    # is equivalent to:
    _bosh('deploy -d concourse manifest.yml');

This comes in handy because sometimes it looks weird to omit the leading
C<bosh> token, as in:

    _bosh({ onfailure => 'oops; stuff broke' },
          '-e', $env, '-n', @etc);

=cut
