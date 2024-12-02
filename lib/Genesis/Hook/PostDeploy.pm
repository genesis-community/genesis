package Genesis::Hook::PostDeploy;
use strict;
use warnings;

use parent qw(Genesis::Hook);

use Genesis;
use Time::HiRes qw/gettimeofday/;

sub init {
	my ($class, %ops) = @_;
	my @missing = grep {!defined($ops{$_})} qw/env rc/;
	bug(
		"Missing required arguments for a perl-based kit hook call: %s",
		join(", ", @missing)
	) if @missing;
	
	my $obj = $class->SUPER::init(%ops);
	return $obj;
}

sub deploy_successful {
	return $_[0]->{rc} == 0;
}

sub update_director_network_config {
	my $self = shift;
	my $env = $self->env;

	return unless $env->can_build_cloud_configs;

	# Run the director-cloud-config hook to generate and apply the cloud-config
	$env->notify("Generating the Network space for the BOSH Director");
	info({pending => 1}, "[[  - >>building director cloud-config...");
	my $tstart = gettimeofday;
	my ($config, $network) = $env->run_hook('cloud-config', purpose => 'director');
	info("#G{done}" . pretty_duration(gettimeofday - $tstart, 5, 10));

	# FIXME: Do a check and compare, and ask if different (or just do it if $BOSH_NON_INTERACTIVE is set)
	# or at least show the diff (maybe too late to ask if bosh is already deployed)
	#
	info({pending => 1}, "[[  - >>uploading #c{%s.%s.director} cloud-config...", $env->name, $env->type);
	my $bosh = $env->get_target_bosh({self => !$env->use_create_env});
	my $config_name = join('.',$env->name, $env->type, 'director');
	$tstart = gettimeofday;
	$bosh->upload_config($config, 'cloud', $config_name);
	info("#G{done}" . pretty_duration(gettimeofday - $tstart, 5, 10));

	# Check if network has changes, and if so, show them and store them in exodus
	
	info({pending => 1}, "[[  - >>storing director network details in exodus...");
	$tstart = gettimeofday;
	$env->vault->set_path($env->exodus_base.'/network', $network, flatten => 1, clear => 1);
	info("#G{done}" . pretty_duration(gettimeofday - $tstart, 1, 3));
}

sub command {
	my $self = shift;
	my @cmd = ($ENV{GENESIS_CALL_ENV} ||$ENV{GENESIS_CALL});
	for my $arg (@_) {
		$arg = "'$arg'" if ($arg =~ / \(\)!\*\?/);
		push @cmd, $arg;
	}
	return join(" ", @cmd);
}

sub help {
	my ($self, %addons) = @_;

	if ($self->can('cmd_details')) {
		info (
			"\n#Gu{%s}\n[[  >>%s\n",
			$self->{label}, join("\n[[  >>", split("\n",$self->cmd_details()))
		);
		return 1;
	}

	# FIXME: The code below is not being called yes, so may contain errors:
	# - the passed in %addons does not seem compatible with the code below
	#   due to the includsion of $addons{$cmd} already containing the help
	#   output.

	# Loook for any extended addon hooks
	my @module_files = glob($self->kit->path("hooks/addon-*.pm"));
	foreach my $file (@module_files) {
		my $class = $self->load_hook_module($file, $self->kit);
		next unless $class && $class->can('cmd_details');
		my ($cmd) = $file =~ m{addon-(.*)\.pm};
		$addons{"$cmd"} = $class->cmd_details() // 'No help available';
	}

	unless (keys %addons) {
		info "No addons are defined for the %s kit.", $self->env->kit->id;
		return 0
	}

	my ($label, $short, $msg);
	info "The following addons are defined for the %s kit:", $self->env->kit->id;

	foreach my $cmd (sort keys %addons) {
		$label = $cmd =~ s/([^~]*).*/$1/r;
		$short = $cmd =~ s/([^~]*)(~(.*))?/$3/r;
		$short = "|$short" if $short;
		info(
			"\n  #Gu{%s%s}\n[[    >>%s",
			$label, $short, join("\n[[    >>", split("\n",$addons{$cmd}))
		);
	}
}

sub results {
	return 1;
}
1;
