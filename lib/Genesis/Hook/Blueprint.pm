package Genesis::Hook::Blueprint;

use v5.20;
use warnings;

use parent qw(Genesis::Hook);

use Genesis;

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->{features} = [$obj->env->features];
	$obj->{files} = [];
	return $obj
}

sub add_files {
	my $self = shift;
	push(@{$self->{files}}, @_);
}


sub add_files_if_wants {
	my ($self, $feature_test, @files) = @_;
	return unless $self->want_feature($feature_test);
	$self->add_files(@files);
}

sub add_files_if_exists {
	my ($self, @files) = @_;
	for my $file (@files) {
		my $absfile = $file;
		if ($file =~ m{^/}) {
			my $env_base = $self->env->path();
			# Check if the path is under the env base dir
			if ($file !~ qr/^\Q$env_base\E/) {
				debug("Refusing to add absolute path outside of env: %s", $file);
				next;
			}
		} else {
			$absfile = $self->kit->path($file);
		}
		$self->add_files($file) if -f $absfile
	}
}

# TODO: Add a generalized add_files method that takes an option hashref as first argument
# if_wants => want_feature_match,
# if_exists => 1,
# before => file-match, -or- after => file-match

sub remove_files {
	my $self = shift;
	my @files = @_;
	($self->{files}) = compare_arrays(
		$self->{files},
		\@files
	);
}

sub exchange_files {
	my ($self, %exchange) = @_;
	# Exchange in place any files that match the keys with the values
	for my $i (0 .. $#{$self->{files}}) {
		$self->{files}[$i] = delete $exchange{$self->{files}[$i]}
			if (exists $exchange{$self->{files}[$i]});
		last if (scalar(keys %exchange) == 0);
	}
}

sub ops_dir {
	return $_[0]->env->lookup('genesis.ops_dir') // 'ops';
}

sub upstream_dir {
	my $self = shift;
	return unless $self->{upstream_dir};
	return $self->{upstream_dir} =~ s{/?$}{/}r; # Ensure it ends with a slash
}

sub upstream_pattern_match {
	return $_[0]->{upstream_pattern_match} // qr/^operations\/(.*)$/;
}

# validate_features - Process feature validation {{{
sub validate_features {
	my ($self, %opts) = @_;

	# Keep a backup of the raw features as an array ref
	$self->{raw_features} //= [ $self->features ];

	my @curated_features            = ();
	my @warnings                    = $opts{warnings} ? $opts{warnings}->@* : ();
	my @errors                      = $opts{errors}   ? $opts{errors}->@*   : ();
	my $deprecated_features         = $opts{deprecated_features}           // {};
	my $mutually_exclusive_features = $opts{mutually_exclusive_features}   // {};

	my %valid_features = ref($opts{valid_features}) eq 'HASH'
		? $opts{valid_features}->%*
		: ref($opts{valid_features}) eq 'ARRAY'
		? map { $_ => 1 } $opts{valid_features}->@*
		: bail(
			"Invalid valid_features parameter: expected a hash or array reference, got %s",
			ref($opts{valid_features})       ? ref($opts{valid_features})
			: defined($opts{valid_features}) ? "#B{$opts{valid_features}}"
			: '#R{<undef>}'
		);

	my $ops_dir = $self->ops_dir;

	for my $feature (@{$self->{raw_features}}) {
		if ($valid_features{$feature}) {
			# Valid feature, add it to the curated list
			push @curated_features, $feature;

		} elsif (exists($deprecated_features->{$feature})) {
			my $resolution = $deprecated_features->{$feature}//{};
			$self->_handle_deprecated_feature(
				$feature, $resolution,
				\@curated_features, \@warnings, \@errors
			);

		} elsif ($self->upstream_dir && $feature =~ $self->upstream_pattern_match) {
			if (-f $self->kit->path($self->upstream_dir.$feature.'.yml')) {
				# Custom ops file from the kit
				push @curated_features, $feature;
			} else {
				push @errors, "Invalid upstream operation requested: #c{$feature}";
			}

		} elsif (-f $self->env->path("$ops_dir/$feature.yml")) {
			# Custom ops file from the environment
			push @curated_features, $feature;

		} else {
			push @errors, "Invalid feature requested: #c{$feature}";
		}
	}


	$self->set_features(@curated_features);

	# Process mutually exclusive features
	for my $group (keys %$mutually_exclusive_features) {
		my @group_features = $mutually_exclusive_features->{$group}->@*;
		my @features_in_group = grep {$self->want_feature($_)} @group_features;
		if (@features_in_group > 1) {
			push @errors, sprintf(
				"Cannot set multiple #M{%s} features: %s",
				$group,
        join(', ', map {"#c{$_}"} @features_in_group)
			);
		}
	}

	warning(
		"\nFeature validation encountered the following warnings:\n%s",
		join('', map {"[[  - >>$_\n"} @warnings)
	) if @warnings;

	bail(
		"\nFeature validation encountered the following errors:\n%s",
		join('', map {"[[  - >>$_\n"} @errors)
	) if @errors;

}

# }}}

# _handle_deprecated_feature - Handle deprecated features {{{
sub _handle_deprecated_feature {
	my ($self, $feature, $resolution, $curated_features, $warnings_ref, $errors_ref) = @_;
	my $msg = undef;
	my $replacement = undef;

	$resolution = {replace => $resolution} unless ref($resolution) eq 'HASH';

	if (!exists($resolution->{params})) {
		$msg = $resolution->{msg};
		$replacement = $resolution->{replace};
	} else {
		# TODO: Deal with features that have been replaced by env params
		bail("Feature replacement by params not yet implemented for $feature");
	}

	if (ref($replacement) eq 'ARRAY') {
		# Multiple replacements
		if (!@$replacement) {
			push @$warnings_ref, sprintf(
				"The #g{%s} feature is now the default behaviour %s",
				$feature,
				$msg // "and no longer needs to be specified."
			);
		} else {
			push @$warnings_ref, sprintf(
				"The #y{%s} feature has been deprecated %s",
				$feature,
				$msg // "and should be replaced with ". sentence_join(map {"#c{$_}"} @$replacement)
			);
			push @$curated_features, @$replacement;
		}
	} elsif (!defined($replacement)) {
		push @$errors_ref, sprintf(
			"The #r{%s} feature is no longer supported and has been removed.%s",
			$feature,
			$msg ? " $msg" : ""
		);
	} else {
		# Single replacement
		push @$warnings_ref, sprintf(
			"The #c{%s} feature has been replaced with #c{%s}",
			$feature, $replacement
		);
		push @$curated_features, $replacement;
	}
	return 1;
}

sub results {
	bail(
		"Blueprint hook could not be run"
	) unless $_[0]->{complete};
	bail(
		"Could not determine which YAML files to merge: 'blueprint' specified no files"
	) unless scalar(@{$_[0]->{files}});
	return $_[0]->{files}
}
1;
