package Genesis::BOSH;

use Genesis::Utils;

sub ping {
	my ($class, $env) = @_;
	return bosh({ interactive => 1, passfail => 1 },
		'bosh', '-e', $env, 'env');
}

sub create_env {
	my ($class, $manifest, %opts) = @_;

	return bosh({ interactive => 1, passfail => 1 },
		'bosh', 'create-env', '--state', $opts{state},
		$ENV{BOSH_NON_INTERACTIVE} ? '-n' : (),
		$manifest);
}

sub download_cloud_config {
	my ($class, $env, $path) = @_;
	bosh({ interactive => 1, onfailure => "Could not download cloud-config from '$env' BOSH director" },
		'bosh -e "$1" cloud-config > "$2"', $env, $path);

	die "No cloud-config defined on '$env' BOSH director\n"
		unless -s $path;
}

sub deploy {
	my ($class, $manifest, %opts) = @_;
	return bosh({ interactive => 1, passfail => 1 },
		'bosh', '-e', $opts{target}, '-d', $opts{deployment},
		$ENV{BOSH_NON_INTERACTIVE} ? '-n' : (),
		'deploy', @{ $opts{options} || [] });

}

sub alias {
	my ($class, $alias) = @_;
	bosh({ interactive => 1, onfailure => "Could not create BOSH alias for '$_[0]'" },
		'bosh', 'alias-env', $alias);
}

sub run_errand {
	my ($class, $env, $deployment, $errand) = @_;
	bosh({ interactive => 1, onfailure => "Failed to run errand '$errand' ($deployment deployment on $env BOSH)" },
		'bosh', '-n', '-e', $env, '-d', $deployment, 'run-errand', $errand);
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

=head2 ping($env)

Try to contact the BOSH director at C<$env>, and report success or failure.


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

=cut
