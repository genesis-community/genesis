package Genesis::Env;
use strict;
use warnings;

use Genesis::Utils;

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
	for (qw(kit vault)) {
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
		$self->_legacy_new_environment();
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
		$kit->_legacy_vaultify_secrets(
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
		$kit->_legacy_check_secrets(
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
		$kit->_legacy_vaultify_secrets(
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


#######################   here thar be legacy, dragons of yore!

sub _legacy_new_environment {
	my ($self) = @_;
	my ($k, $kit, $version) = ($self->{kit}, $self->name, $self->version);
	my $meta = $k->metadata;

	$k->run_hook('prereqs') if $k->has_hook('prereqs');

	my @features = $self->_legacy_prompt_for_env_features();
	my $params = $k->_legacy_process_params(
		env          => $self->{name},
		vault_prefix => $self->{prefix},
		features     => \@features,
	);
	if ($k->has_hook('params')) {
		$params = $k->run_hook('params', params => $params);
	}

	## create the environment file.
	my $file = "$self->{name}.yml";
	my ($parent, %existing_info);
	if ($self->{name} =~ m/-/) { # multi-level environment; make/use a top-level
		($parent = $file) =~ s/-.*\.yml/.yml/;
		if (-e $parent) {
			explain "Using existing #C{$parent} file as base config.";
			%existing_info = %{LoadFile($parent)};
		}
	}

	open my $fh, ">", $file or die "Couldn't write to $file: $!";
	print $fh "---";
	print $fh "\nkit:\n" if (
		!%existing_info ||
		$existing_info{kit}{name} ne $kit ||
		$existing_info{kit}{version} ne $version ||
		!same($existing_info{kit}{features}||[],\@features)
	);
	if (!%existing_info || $existing_info{kit}{name} ne $kit) {
		print $fh "  name:     $kit\n";
		error "#y{WARNING:} $parent specifies a different kit name ($existing_info{kit}{name})";
	}
	if (!%existing_info || $existing_info{kit}{version} ne $version) {
		print $fh "  version:  $version\n";
		error "#y{WARNING:} $parent specifies a different kit version ($existing_info{kit}{version})";
	}
	if (!%existing_info || !same($existing_info{kit}{features}||[],\@features)) {
		print $fh "  features:\n";
		print $fh "  - (( replace ))\n" if defined($existing_info{kit}{features});
		print $fh "  - $_\n" foreach (@features);
	}
	print $fh <<EOF;

params:
  env:   $self->{name}
  vault: $self->{prefix}
EOF
	if (defined($ENV{GENESIS_BOSH_ENVIRONMENT})) {
		print $fh <<EOF;
  bosh:  $ENV{GENESIS_BOSH_ENVIRONMENT}
EOF
	}

	for my $param (@$params) {
		print $fh "\n";
		my $indent = "  # ";
		if (defined $param->{comment}) {
			for my $line (split /\n/, $param->{comment}) {
				print $fh "${indent}$line\n";
			}
		}
		if (defined $param->{example}) {
			print $fh "${indent}(e.g. $param->{example})\n";
		}

		$indent = $param->{default} ? "  #" : "  ";

		for my $val (@{$param->{values}}) {
			my $k = (keys(%$val))[0];
			# if the value is a spruce operator, we know it's a string, and don't need fancy encoding of the value
			# this helps us not run into issues resolving the operator
			my $v = $val->{$k};
			if (defined $v && ! ref($v) && $v =~ m/^\(\(.*\)\)$/) {
				print $fh "${indent}$k: $v\n";
				next;
			}
			my $tmpdir = workdir;
			open my $tmpfile, ">", "$tmpdir/value_formatting";
			print $tmpfile encode_json($val);
			close $tmpfile;
			open my $spruce, "-|", "spruce merge $tmpdir/value_formatting";

			for my $line (<$spruce>) {
				chomp $line;
				next unless $line;
				next if $line eq "---";
				print $fh "${indent}$line\n";
			}
			close $spruce;
			die "Unable to convert JSON to spruce-compatible YAML. This is a bug\n"
				if $? >> 8;
		}
	}
	close $fh;
	explain "Created #C{$file} environment file";
}

sub _legacy_prompt_for_env_features {
	my ($self) = @_;
	my ($kit, $version) = ($self->{kit}{name}, $self->{kit}{version});
	my $meta = $self->{kit}->metadata;

	my @features;
	my $features_meta = $meta->{features} || $meta->{subkits} || [];
	my @meta_key = (defined $meta->{features}) ? 'feature' : 'subkit';
	foreach my $feature (@$features_meta) {
		my $prompt = $feature->{prompt}."\n";
		if (exists $feature->{choices}) {
			my (@choices,@labels,$default);
			foreach (@{$feature->{choices}}) {
				push @choices, $_->{feature} || $_->{subkit};
				push @labels,  $_->{label};
				$default = ($_->{feature} || $_->{subkit}) if $_->{default} && $_->{default} =~ /^(y(es)?|t(rue)?|1)$/i;
			}
			if (exists $feature->{pick}) {
				die "There is a problem with kit $kit/$version: $feature->{type} pick invalid.  Please contact the kit author for a fix"
					unless $feature->{pick} =~ /^\d+(-\d+)?$/;
				my ($min, $max) =  ($feature->{pick} =~ /-/)
					? split('-',$feature->{pick})
					: ($feature->{pick},$feature->{pick});
				my $selections = grep {$_} prompt_for_choices($prompt,\@choices,$min,$max,\@labels);
				push @features, @$selections;
			} else {
				push @features, grep {$_} (prompt_for_choice($prompt,\@choices,$default,\@labels));
			}
		} else {
			push(@features, ($feature->{feature} || $feature->{subkit})) if  prompt_for_boolean($prompt,$feature->{default});
		}
	}

	if ($self->{kit}->has_hook('subkits')) {
		@features = $self->{kit}->run_hook('subkits', features => \@features);
	}
	$self->{kit}->_legacy_validate_features(@features);
	return @features;
}

# generate (and optionally rotate) credentials.
#
## just rotate credentials
# vaultify_secrets $kit_metadata,
#                  target       => "my-vault",
#                  env          => "us-east-sandbox",
#                  prefix       => "us/east/sandbox",
#                  scope        => 'rotate'; # or scope => '' or undef
#
## generate all credentials (including 'fixed' creds)
# vaultify_secrets $kit_metadata,
#                  target       => "my-vault",
#                  env          => "us-east-sandbox",
#                  prefix       => "us/east/sandbox",
#                  scope        => 'force';
#
## generate only missing credentials
# vaultify_secrets $kit_metadata,
#                  target       => "my-vault",
#                  env          => "us-east-sandbox",
#                  prefix       => "us/east/sandbox",
#                  scope        => 'add';
#
sub _legacy_vaultify_secrets {
	my ($self, %options) = @_;
	my $meta = $self->metadata;

	$options{env} or die "vaultify_secrets() was not given an 'env' option.\n";

	my $creds = active_credentials($meta, $options{features} || {});
	if (%$creds) {
		explain " - auto-generating credentials (in secret/$options{prefix})...\n";
		for (safe_commands $creds, %options) {
			Genesis::Run::interact(
				{onfailure => "Failure autogenerating credentials."},
				'safe', @$_
			);
		}
	} else {
		explain " - no credentials need to be generated.\n";
	}

	my $certs = active_certificates($meta, $options{features} || {});
	if (%$certs) {
		explain " - auto-generating certificates (in secret/$options{prefix})...\n";
		for (cert_commands $certs, %options) {
			Genesis::Run::interact(
				{onfailure => "Failure autogenerating certificates."},
				'safe', @$_
			);
		}
	} else {
		explain " - no certificates need to be generated.\n";
	}
}

1;
