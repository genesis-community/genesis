package Genesis::Env;
use strict;
use warnings;

use Genesis::Utils;
use Genesis::Legacy; # but we'd rather not

sub new {
	my ($class, %opts) = @_;

	# validate call
	for (qw(name top)) {
		die "No '$_' specified in call to Genesis::Env->new; this is a bug in Genesis.\n"
			unless $opts{$_};
	}

	# drop the YAML suffix
	$opts{name} =~ m/\.yml$/;
	$opts{file} = "$opts{name}.yml";

	# environment names must be valid.
	eval { $class->validate_name($opts{name}) }
		or die "Bad environment name '$opts{name}': $@\n" if $@;

	# make sure .genesis is good to go
	die "No deployment type specified in .genesis/config!\n"
		unless $opts{top}->config->{deployment_type};

	# provide default prefix
	if (!$opts{prefix}) {
		$opts{prefix} = $opts{name};
		$opts{prefix} =~ s|-|/|g;
		$opts{prefix} .= "/".$opts{top}->config->{deployment_type};
	}

	# here ya go
	return bless(\%opts, $class);
}

sub load {
	my $self = new(@_);

	if (!-f $self->{top}->path("$self->{file}")) {
		die "Environment file $self->{file} does not exist.\n";
	}

	# do other stuff:
	#  - override prefix
	#  - populate self->kit

	return $self;
}

sub create {
	my $self = new(@_);

	# validate call
	for (qw(kit)) {
		die "No '$_' specified in call to Genesis::Env->create; this is a bug in Genesis.\n"
			unless $self->{$_};
	}

	# environment must not already exist...
	if (-f $self->{top}->path("$self->{file}")) {
		die "Environment file $self->{file} already exists.\n";
	}

	## initialize the environment
	if ($self->{kit}->has_hook('new')) {
		$self->{kit}->run_hook('new', root  => $self->{top}->path,  # where does the yaml go?
		                              env   => $self->{name},       # what is it called?
		                              vault => $self->{prefix});    # where do the secrets go?

	} else {
		Genesis::Legacy::new_environment($self);
	}

	$self->add_secrets();

	return $self;
}

sub relate {
	my ($self, $them, $common_base, $unique_base) = @_;
	$common_base ||= '.';
	$unique_base ||= '.';
	$them ||= '';

	my @a = split /-/, $self->{name};
	my @b = split /-/, ref($them) ? $them->{name} : $them;
	my @c = (); # common

	while (@a and @b) {
		last unless $a[0] eq $b[0];
		push @c, shift @a; shift @b;
	}
	# now @c contains common tokens (us, west, 1)
	# and @a contains unique tokens (preprod, a)

	my (@acc, @common, @unique);
	for (@c) {
		# accumulate tokens: (us, us-west, us-west-1)
		push @acc, $_;
		push @common, "$common_base/".join('-', @acc).".yml";
	}
	for (@a) {
		# accumulate tokens: (us-west-1-preprod,
		#                     us-west-1-preprod-a)
		push @acc, $_;
		push @unique, "$unique_base/".join('-', @acc).".yml";
	}

	return wantarray ? (@common, @unique)
	                 : { common => \@common,
	                     unique => \@unique };

	# $a = Genesis::Env->new(name => 'us-west-1-preprod-a')
	# $b = Genesis::Env->new(name => 'us-west-1-prod-b-ftw')
	#
	# $a->relate($b, '.cache', '') # list context
	#   -> (.cache/us.yml,
	#       .cache/us-west.yml,
	#       .cache/us-west-1.yml,
	#       us-west-1-preprod.yml,
	#       us-west-1-preprod-a.yml)
	#
	# $a->relate($b, '.cache', '') # scalar context
	#   -> { common => [.cache/us.yml,
	#                   .cache/us-west.yml,
	#                   .cache/us-west-1.yml],
	#        unique => [us-west-1-preprod.yml,
	#                   us-west-1-preprod-a.yml] };
	#
	# $a->relate(common => $b)
	#   # return (us, west, 1)
	# $a->relate(unique => $b)
	#   # return (us-west-1, preprod, a)
	# $a->relate($v)
	#   # return [(us, west, 1), (preprod, a)]
	#
}

sub environment_files {
	my ($self) = @_;

	# ci pipelines need to pull cache for previous envs
	my $env = $ENV{PREVIOUS_ENV} || '';
	return $self->relate($env, ".genesis/cached/$env");
}

# NOTE: not sure if this is how we want to do this, but
#       it does seem to be working for all callers.
sub lookup {
	my ($self, $key, $default) = @_;
	my $params = $self->params();

	for (split /\./, $key) {
		return $default if !exists $params->{$_};
		$params = $params->{$_};
	}
	return $params;
}

sub defines {
	my ($self, $key) = @_;
	my $params = $self->params();

	for (split /\./, $key) {
		return 0 unless exists $params->{$_};
		$params = $params->{$_};
	}
	return 1;
}

sub params {
	my ($self) = @_;
	if (!$self->{__params}) {
		my $out = Genesis::Run::get(
			{ onfailure => "Unable to merge $self->{name} environment files" },
			'spruce merge --skip-eval "$@" | spruce json',
			map { $self->{top}->path($_) } $self->environment_files());
		$self->{__params} = JSON::PP->new->allow_nonref->decode($out);
	}
	return $self->{__params};
}

sub add_secrets { # WIP - majorly broken right now.  sorry bout that.
	my ($self, %opts) = @_;
	my $kit = $self->{kit};

	if ($kit->has_hook('secrets')) {
		$kit->run_hook('secrets', action   => 'add',
		                          recreate => $opts{recreate},
		                          env      => $self->{name},
		                          vault    => $self->{prefix});
	} else {
		my @features = []; # FIXME
		Genesis::Legacy::vaultify_secrets($kit,
			env       => $self->{name},
			prefix    => $self->{prefix},
			scope     => $opts{recreate} ? 'force' : 'add',
			features  => \@features);
	}
}

sub check_secrets {
	my ($self) = @_;
	my $kit = $self->{kit};

	if ($kit->has_hook('secrets')) {
		$kit->run_hook('secrets', action => 'check',
		                          env    => $self->{name},
		                          vault  => $self->{prefix});
	} else {
		my @features = []; # FIXME
		Genesis::Legacy::vaultify_secrets($kit,
			env       => $self->{name},
			prefix    => $self->{prefix},
			features  => \@features);
	}
}

sub rotate_secrets {
	my ($self, %opts) = @_;
	my $kit = $self->{kit};

	if ($kit->has_hook('secrets')) {
		$kit->run_hook('secrets', action => 'rotate',
		                          force  => $opts{force},
		                          env    => $self->{name},
		                          vault  => $self->{prefix});
	} else {
		my @features = []; # FIXME
		Genesis::Legacy::vaultify_secrets($kit,
			env       => $self->{name},
			prefix    => $self->{prefix},
			scope     => $opts{force} ? 'force' : '',
			features  => \@features);
	}
}

sub validate_name {
	my ($class, $name) = @_;

	die "names must not be empty.\n"
		if !$name;

	die "names must not contain whitespace.\n"
		if $name =~ m/\s/;

	die "names can only contain lowercase letters, numbers, and hyphens.\n"
		if $name !~ m/^[a-z0-9_-]+$/;

	die "names must start with a (lowercase) letter.\n"
		if $name !~ m/^[a-z]/;

	die "names must not end with a hyphen.\n"
		if $name =~ m/-$/;

	die "names must not contain sequential hyphens (i.e. '--').\n"
		if $name =~ m/--/;
}

1;
