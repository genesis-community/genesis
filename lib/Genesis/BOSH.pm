package Genesis::BOSH;

sub create_env {
	my ($class, $manifest, %opts) = @_;

	return Genesis::Run::interactive_bosh(
		'create-env', '--state', $opts{state},
		$ENV{BOSH_NON_INTERACTIVE} ? '-n' : (),
		$manifest);
}

sub download_cloud_config {
	my ($class, $target, $path) = @_;
	Genesis::Run::interactive_bosh(
		{ onfailure => "Could not download cloud-config from '$target' BOSH director" },
		'-e "$1" cloud-config > "$2"', $target, $path);
	die "No cloud-config defined on '$target' BOSH director\n"
		unless -s $path;
}

sub deploy {
	my ($class, $manifest, %opts) = @_;
	return Genesis::Run::interactive_bosh(
		'-e', $opts{target}, '-d', $opts{deployment},
		$ENV{BOSH_NON_INTERACTIVE} ? '-n' : (),
		'deploy', @{ $opts{options} || [] });

}

sub alias {
	my ($class, $alias) = @_;
	return Genesis::Run::interactive_bosh(
		{ onfailure => "Could not create BOSH alias for '$_[0]'" },
		'alias-env', $alias);
}

sub run_errand {
	my ($class, $target, $deployment, $errand) = @_;
	return Genesis::Run::interactive_bosh(
		{ onfailure => "Failed to run errand '$errand' ($deployment deployment on $target BOSH)" },
		"-n", "-e", $target, "-d", $deployment, "run-errand", $errand);
}

1;
