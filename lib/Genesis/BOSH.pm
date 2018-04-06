package Genesis::BOSH;

sub ping {
	my ($class, $target) = @_;
	return bosh({ interactive => 1, passfail => 1 },
		'bosh', '-e', $target, 'env');
}

sub create_env {
	my ($class, $manifest, %opts) = @_;

	return bosh({ interactive => 1, passfail => 1 },
		'create-env', '--state', $opts{state},
		$ENV{BOSH_NON_INTERACTIVE} ? '-n' : (),
		$manifest);
}

sub download_cloud_config {
	my ($class, $target, $path) = @_;
	bosh({ interactive => 1, onfailure => "Could not download cloud-config from '$target' BOSH director" },
		'bosh', '-e "$1" cloud-config > "$2"', $target, $path);

	die "No cloud-config defined on '$target' BOSH director\n"
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
	my ($class, $target, $deployment, $errand) = @_;
	bosh({ interactive => 1, onfailure => "Failed to run errand '$errand' ($deployment deployment on $target BOSH)" },
		'bosh', '-n', '-e', $target, '-d', $deployment, 'run-errand', $errand);
}

1;
