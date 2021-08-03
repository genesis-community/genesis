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

		for (qw/BOSH_ENVIRONMENT BOSH_CA_CERT BOSH_CLIENT BOSH_CLIENT_SECRET/) {
			$opts->{env}{$_} = undef unless defined($opts->{env}{$_}); # ensure using ~/.bosh/config via alias
		}
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
		BOSH_ENVIRONMENT   => $ENV{BOSH_ENVIRONMENT}   || $e->{url},
		BOSH_CA_CERT       => $ENV{BOSH_CA_CERT}       || $e->{ca_cert},
		BOSH_CLIENT        => $ENV{BOSH_CLIENT}        || $e->{username},
		BOSH_CLIENT_SECRET => $ENV{BOSH_CLIENT_SECRET} || $e->{password},
	} if (envset('GENESIS_HONOR_ENV'));
	return {
		BOSH_ENVIRONMENT   => $e->{url},
		BOSH_CA_CERT       => $e->{ca_cert},
		BOSH_CLIENT        => $e->{username},
		BOSH_CLIENT_SECRET => $e->{password},
	};
}

my $reping;
sub ping {
	my ($class, $env) = @_;
	return 1 if $ENV{GENESIS_BOSH_VERIFIED} eq $env;

	# TODO: once using vault-stored bosh targetting, we don't need to do this anymore
	debug "Checking BOSH at '$env' for connectivity";
	my $waiting=0;
	unless ($reping || in_callback || envset "GENESIS_TESTING") {;
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

	my $status = tcp_listening($host,$port);
	unless ($status eq 'ok') {
		error "#R{unreachable - $status!}\n" if $waiting;
		return 0;
	}
	my ($out,$rc) = read_json_from(_bosh('bosh', '-e', $env, 'env', '--json'));
	if ($rc) {
		error "#R{error!}\n\n$out\n" if $waiting;
		return 0;
	}
	my $user = $out->{Tables}[0]{Rows}[0]{user};
	if ($user eq "(not logged in)") {
		# Just because it says not logged in, doesn't mean you're not. It only
		# checks the access token, not the refresh token.  So try something that
		# does refresh the access token, then get the user after that.
		($out,$rc) = _bosh('bosh', '-e', $env, 'stemcells', '--json');
		($out,$rc) = read_json_from(_bosh('bosh', '-e', $env, 'env', '--json'));
		$user = $out->{Tables}[0]{Rows}[0]{user};
	}

	if ($user eq "(not logged in)") {
		error "#R{unauthenticated!}" if $waiting;
		return 0;
	}
	explain STDERR "#G{ok - authenticated as $user}" if $waiting;
	$ENV{GENESIS_BOSH_VERIFIED} = $env;
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


sub download_config {
	my ($class, $env, $path, $type, $name) = @_;
	$name ||= '*';

	my @configs;
	if ($name eq '*') {
		my ($configs_list,$rc,$err) = read_json_from(_bosh(
			{interactive => 0, stderr => 0},
			'bosh -e "$1" configs -r=1 --type="$2" --json | jq -r \'.Tables[0].Rows[]| {"type": .type, "name": .name}\' | jq -sMc',
			$env, $type
		));
		if ($rc || ! scalar(@$configs_list)) {
			$err ||= "No configurations found on BOSH director" unless scalar(@$configs_list);
			bail "#R{[ERROR]} Could not load #C{$type} configurations: $err";
		}
		for (@$configs_list) {
			my $label = $_->{name} eq "default" ? "base $_->{type} config" : "$_->{type} config '$_->{name}'";
			push @configs, {type => $_->{type}, name => $_->{name}, label => $label};
		}
	} else {
		my $label = $name eq "default" ? "$type config" : "$type config '$name'";
		push @configs, {type => $type, name => $name, label => $label};
	}

	my @config_contents;
	for (@configs) {
		my ($out,$rc,$err) = _bosh(
			{ interactive => 0},
			'bosh -e "$1" config --type "$2" --name "$3" --json',
			$env, $_->{type}, $_->{name}
		);

		my $json = eval {JSON::PP::decode_json($out)};
		my $json_err = $@;
		if ($json_err) {
			chomp $json_err;
			$json_err =~ s/ at lib\/Genesis\/BOSH.*//sm;
		}

		if ($rc || $json_err) {
			my $msg = $err;
			$msg = "#R{$json_err:}\n\n[36m$out[0m" if ($json_err && !$msg);
			$msg ||= join("\n", grep {$_ !~ /^Exit code/} grep {$_ !~ /^Using environment/} @{$json->{Lines}});
			$msg ||= "Could not understand 'BOSH config' json output:\n\n[36m$out[0m";
			$msg = "No $label found" if $msg eq 'No config';
			die $msg."\n";
		}

		bug("BOSH returned multiple entries for $label - Genesis doesn't know how to process this")
			if (@{$json->{Tables}} != 1 || @{$json->{Tables}[0]{Rows}} != 1);

		my $config = $json->{Tables}[0]{Rows}[0]{content};
		die "No $label contents\n" unless defined($config);
		push @config_contents, $config;
	}
	my $config;
	if (scalar(@config_contents) > 1) {
		($config, my $rc, my $err) = run(
			{interactive => 0, stderr=>0},
			'spruce merge --multi-doc --go-patch <(echo "$1")',
			join("\n---\n", @config_contents)
		);
		bail("Failed to converge the active $type configurations: $err") if $rc;
	} else {
		$config = $config_contents[0]
	}
	mkfile_or_fail($path,$config);
	return \@configs;
}

sub download_cloud_config {
	my ($class, $env, $path,) = @_;
	waiting_on STDERR "Downloading cloud config from '#M{$env}' BOSH director...";
	my $configs = $class->download_config($env,$path,"cloud","default");
	bail "#R{error!}  No cloud-config defined on '#M{$env}' BOSH director\n" unless (-s $path);
	explain STDERR "#G{ok}";
	return $configs;
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

sub stemcells {
	my ($class, $env) = @_;
	return lines(_bosh(
		q<bosh -e "$1" stemcells --json | jq -r '.Tables[0].Rows[] | "\(.os)@\(.version)" | sub("[^0-9]+$";"")'>,
		$env
	));
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
