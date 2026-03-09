package Genesis::Env::DeploymentManager;

use strict;
use warnings;
use 5.20.0;

use Genesis qw/
	bail debug bug
	flatten unflatten in_array deep_merge
	parse_fixed_width_table
	run lines
	EXODUS_TIME_FORMAT EXODUS_TIME_FORMAT_SHORT
/;
use Genesis::Env::Deployment;
use Genesis::Term;

use Digest::file qw/digest_file_hex/;
use JSON::PP qw//;
use Time::Piece;
use Time::HiRes qw/gettimeofday/;
use Time::Seconds qw/ONE_DAY/;

# new - create a new deployment manager for the given environment {{{
sub new {
	my ($class, $env) = @_;
	return bless {
		env => $env,
		__all_deployments => undef
	}, $class;
}
# }}}

# all - return an array of all deployment audits, sorted latest-first {{{
sub all {
	# Only return array context to protect against accidental modification
	my ($self) = @_;
	my @all = $self->_all(); # Forces array context
	return @all;
}
# }}}

# reset - reset the cached deployments {{{
sub reset {
	$_[0]->{__all_deployments} = undef;
}
# }}}

# find - find matching deployment audits {{{
sub find {
	my ($self, %options) = @_; # See POD for valid options

	my $env = $self->env;

	# Validate options
	my @invalid_options = grep { !/^(action|result|all|timestamps_only|limit|range)$/ } keys %options;
	bail(
		"Invalid options: %s",
		join(", ", @invalid_options)
	) if @invalid_options;
	$options{all} = 1 if $options{result}; # If result is specified, include all deployments

	# Get list of deployment - Don't get by ref, because we're likely going to modify it
	my @all_deployments = $self->all();
	return () unless @all_deployments;

	# Filter by range if specified
	my $deferred_range = $self->_filter_by_range(
		\@all_deployments,
		$options{range}
	) if $options{range};
	# Filter by action if specified
	@all_deployments = grep {
		$_->lookup('action') eq $options{action}
	} @all_deployments if $options{action};

	# Filter by result if specified
	@all_deployments = grep {
		$_->lookup('result') eq $options{result}
	} @all_deployments if $options{result};

	# Limit to successful deployments if not all
	@all_deployments = grep {
		$_->succeeded
	} @all_deployments unless ($options{all});

	# Filter by picks if given
	@all_deployments = reverse(
		(reverse @all_deployments)[@$deferred_range]
	) if ($deferred_range && @$deferred_range);

	# Limit the number of deployments if specified
	@all_deployments = splice(
		@all_deployments, 0, $options{limit}
	) if $options{limit};

	return $options{timestamps_only}
		? map { $_->timestamp } @all_deployments
		: @all_deployments;
}
# }}}

# at - get a deployment audit at a specific timestamp {{{
sub at {
	my ($self, $timestamp) = @_;
	my $deployments = $self->_all();
	return undef unless $deployments && @$deployments;

	my ($ts_deployment) = grep {
		$_->{timestamp} eq $timestamp;
	} $deployments->@*;
	return $ts_deployment; # Will be undef if not found
}
# }}}

# latest - get most recent deployment audit {{{
sub latest {
	my ($self, %options) = @_;
	my $deployments = $self->_all();
	return undef unless $deployments && @$deployments;

	for my $deployment ($deployments->@*) {
		next if $options{action} && $deployment->lookup('action') ne $options{action};
		next if $options{result} && $deployment->lookup('result') ne $options{result};
		next if !$options{include_failed} && $deployment->lookup('result') eq $deployment->action_failed;
		return $deployment;
	}
	return undef;
}
# }}}

# latest_successful - get the latest successful deployment {{{
sub latest_successful {
	my ($self, %options) = @_;
	# Get the latest successful deployment - find by default will return only successful actions

	my ($latest_successful) = $self->find(%options,limit => 1);
	return $latest_successful;
}
# }}}

# current_state - determine the current deployment state of the environment {{{
sub current_state {
	my ($self) = @_;

	my @deployments = $self->find();
	if (!@deployments) {
		# Check if there is exodus data - we're not checking if the manifest store is the repository,
		# because we may have just changed it to hybrid or exodus, but the old data is still there.
		my $exodus_data = $self->env->exodus_lookup('.', {});
		return 'deployed' if (keys %$exodus_data);
		return 'undeployed';
	}

	# FIXME: Cache, and clear on reset;
	return $deployments[0]->action eq 'deploy' ? 'deployed' : 'terminated';
}
# }}}

# build - build a new deployment audit object {{{
sub build {
	my ($self, $action, $result, %options) = @_;
	my $env = $self->env;

	# TODO: Do we strip the timestamp and sequence number from the options,
	#       as they are set on commit?  Or should they (or at least the timestamp)
	#       be allowed to be set by the caller?

	# Merge in deployment contents to base deployment data
	my $base_content = $self->_base_deployment_content($action, $result);
	my $data = deep_merge($base_content, \%options);

	return Genesis::Env::Deployment->new($env, %$data);
}
# }}}

# next_sequence_number - get the next sequence number for deployments {{{
sub next_sequence_number {
	my ($self) = @_;
	# Get the latest deployment
	my $latest = $self->latest();
	return 1 unless $latest; # If no deployments, return 1
	return scalar($self->all)+1 unless $latest->sequence;
	return $latest->sequence + 1; # Return the next sequence number
}
# }}}

# REFACTOR: This is the old get_next_deployment_sequence_number from Genesis::Env from before it was broken out
# to the Genesis::Env::Deployment and Genesis::Env::DeploymentManager classes.  It has a more complex
# logic to handle backfilling the deployment audit data, so it is kept here for now as a POD block, but it,
# and the _backfill_deployment_audit_data method, needs to be re-analyzed and and determined if it is still
# needed, and in what capacity.


# env - return the environment associated with this deployment manager {{{
sub env {
	return $_[0]->{env};
}
# }}}

# synthesize_from_exodus - synthesize a deployment audit from the exodus data {{{
sub synthesize_from_exodus {
	my ($self, $exodus_data) = @_;
	# Synthesize a deployment audit from the exodus data
	# This is used to create a deployment audit from the exodus data
	# when the environment has been deployed prior to Genesis supporting
	# deployment audits
	my $env = $self->env;
	$exodus_data //= $env->exodus_lookup('.', {});

	if (! keys %$exodus_data) {
		# The environment is either undeployed or terminated, but with no data,
		# assume never deployed.
		return undef;
	}

	# TODO: Incorporate the artifacts from the repo into the synthesized deployment
	# audit, if they exist.

	# Create a new deployment object with the exodus data
	return Genesis::Env::Deployment->new(
		$env,
		action => 'deploy',
		result => Genesis::Env::Deployment::action_succeeded,
		reason => $exodus_data->{reason} // 'unknown - synthesized from previous exodus data',
		started => $exodus_data->{dated},
		completed => $exodus_data->{completed} // $exodus_data->{dated},
		genesis_version => $exodus_data->{version} // 'unknown',
		create_env => $exodus_data->{use_create_env} ? JSON::PP::true : JSON::PP::false,
		bosh_target => {
			name => $exodus_data->{bosh}
		},
		kit => {
			id => $exodus_data->{kit_id} // sprintf(
				"%s/%s%s",
				$exodus_data->{kit_name},
				$exodus_data->{kit_version},
				$exodus_data->{kit_is_dev} ? ' (dev)' : ''
			),
			name => $exodus_data->{kit_name},
			version => $exodus_data->{kit_version},
			is_dev => $exodus_data->{kit_is_dev} ? JSON::PP::true : JSON::PP::false,
			features => $exodus_data->{features} // '',
		},
		user => {
			shell => $exodus_data->{deployer} // 'unknown',
			vault => 'unknown',
			git => 'unknown',
			concourse => 'unknown',
			bosh => 'unknown',
		},
		manifest => {
			type => $exodus_data->{manifest_type} // 'unknown',
			sha2 => $exodus_data->{manifest_sha1} // 'unknown',
			sha1 => $exodus_data->{manifest_sha1} // 'unknown',
			using_sha1 => 1, # sha2 contains SHA-1 data from legacy exodus
		},
	);
}

### Private Instance Methods

# _all - get all deployment audits in list or scalar context - for internal use only
sub _all {
	my ($self) = @_;
	my $env = $self->env;
	unless ($self->{__all_deployments}) {
		# Get list of deployments from vault
		# REFACTOR: Would like to lazy load artifacts, but can't do that with a massive export
		my $deployments = $env->vault->get_path($env->exodus_base.'/deployments');
		unless ($deployments && keys %$deployments) {
			$self->{__all_deployments} = [];
			return wantarray ? () : [];
		}

		# Create a new deployment object for each deployment
		my @deployments = map {
			Genesis::Env::Deployment->new(
				$env,
				timestamp => $_,
				%{$deployments->{$_}}
			)
		} sort {$b cmp $a} keys %{$deployments};

		$self->{__all_deployments} = \@deployments;
	}
	return wantarray
		? @{$self->{__all_deployments}}
		: $self->{__all_deployments}; # return ref for efficiency if requested
}
# }}}

# _base_deployment_content - generates base deployment audit content {{{
sub _base_deployment_content {
	my ($self, $action, $result) = @_;
	my $env = $self->env;

	my $base = {
		action          => $action,
		result          => $result,
		genesis_version => $Genesis::VERSION,
		reason          => 'unspecified',
	};

	unless ($result eq 'assumed') { # TODO: Handles backfilling of assumed deployments and terminations

		$base->{kit} = {
			id            => $env->kit->id,
			name          => $env->kit->name,
			version       => $env->kit->version,
			is_dev        => $env->kit->is_dev ? JSON::PP::true : JSON::PP::false,
			features      => join(',', $env->lookup('kit.features', [])->@*),
			create_env    => $env->use_create_env ? JSON::PP::true : JSON::PP::false,
		};
		$base->{bosh_target} = { map { $_ => $env->bosh_env->{$_} } grep { defined $env->bosh_env->{$_} } keys %{$env->bosh_env} };

		my $user_data = parse_fixed_width_table({array_rows => 1},
			lines(run({stderr => '/dev/null'},'who', '-mH'))
		)->[1] // [];
		my $user = $user_data->[0] // $ENV{USER};
		delete($user_data->[3]) if $user_data->[3] && $user_data->[3] =~ /^tmux\(/; # Remove tmux session name if present)'
		$user .= (" ".$user_data->[3]) if $user_data->[3];
		$base->{user} = {
			shell         => $user,
			repo          => scalar($env->top->kit_provider->remote->get_authorized_user), # FIXME: only works for git-based kit providers
			vault         => scalar($env->vault->user),
			concourse     => $ENV{CONCOURSE_USERNAME} || undef,
			bosh          => $ENV{BOSH_USERNAME} || $ENV{BOSH_USER} || $ENV{BOSH_CLIENT} || undef,
		};

		$base->{artifacts} = $self->_base_artifacts($action);

		if ($action eq 'deploy') {
			$base->{parameters} = {
				iaas         => $env->iaas,
				cloud_config => $env->can_build_cloud_configs ? JSON::PP::true : JSON::PP::false,
				cpi          => $env->cpi_name,
				scale        => $env->scale,
				is_ocfp      => $env->is_ocfp ? JSON::PP::true : JSON::PP::false,
			};
			$base->{manifest} = {
				type => $env->manifest_provider->deployment->type,
				sha2 => digest_file_hex(
					$env->deployment_cache_path_lookup('manifest'), 'SHA-256'
				)
			};
		}
	};
	return $base;
}
# }}}

# _base_artifacts - return a hashref of artifacts based on the action {{{
sub _base_artifacts {
	my ($self, $action) = @_;
	my $env = $self->env;
	# Return a hashref of artifacts based on the action
	if ($action eq 'deploy') {
		return {
			log      => $env->deployment_cache_path_lookup('deploy_log'),
			manifest => $env->deployment_cache_path_lookup('manifest'),
			unpruned => $env->deployment_cache_path_lookup('unpruned_manifest'),
			vars     => $env->deployment_cache_path_lookup('vars'),
			state    => $env->deployment_cache_path_lookup('state'),
			store    => $env->deployment_cache_path_lookup('store'),
			secrets  => [keys($env->manifest_provider->vault_paths(notify => 0)->%*)],
			# TODO: add the dev kit, the ops directory and the env and its ancestors.
		};
	} elsif ($action eq 'terminate') {
		return {
			log      => $env->deployment_cache_path_lookup('deploy_log'),
			state    => $env->deployment_cache_path_lookup('state'),
		};
	} else {
		bail("Invalid action: %s", $action);
	}
}
# }}}

# filter_by_range - filter deployments by a given range {{{
sub _filter_by_range {
	my ($self, $deployments, $range) = @_;

	# Quick sanity check that the deployments are sorted by timestamp in latest-first order
	$self->_confirm_deployments_sorted($deployments);

	if ($range =~ /^(-?\d{1,3})(?:\.\.\.(-?\d{1,3}))?$/) {
		# Integer index range: N or N...M (0-based, negative counts from end)
		# Negative indices work via Perl array slice semantics (-1 = last, -2 = second-to-last)
		my ($start, $end) = ($1, $2);
		$end //= $start;
		# This gets applied after all the other filters, just store it for now
		return $start < $end ? [$start..$end] : [reverse($end..$start)];
	} else {
		my ($before, $after) = ();
		if ($range =~ /^(.*?)(<(?:=?)x<(?:=?))(.*?)$/) {
			# Format: <timestamp><x<timestamp> or <timestamp><=x<=timestamp>
			my ($low, $separator, $high) = ($1, $2, $3);
			my ($loweql, $higheql) = $separator =~ /<(=?)x<(=?)/;
			$after = _parse_into_timestamp_gt_cmp($low, '>'.$loweql);
			$before = _parse_into_timestamp_gt_cmp($high, '<'.$higheql);
		} elsif ($range =~ /^([<>])(=?)(\d.*)$/) {
			my ($cmp, $eq, $ts) = ($1, $2, $3);
			if ($cmp eq '<') {
				$before = _parse_into_timestamp_gt_cmp($ts, '<'.$eq);
			}
			if ($cmp eq '>') {
				$after = _parse_into_timestamp_gt_cmp($ts, '>'.$eq);
			}
		} elsif ($range =~ /^(=?)(\d.*)$/) {
			my ($eq, $ts) = ($1, $2);
			$before = _parse_into_timestamp_gt_cmp($ts, '<=');
			$after = _parse_into_timestamp_gt_cmp($ts, '>=');
		} else {
			bail(
				"Invalid range format: %s",
				$range
			)
		}

		# Pop off the first deployment that is after the `before` timestamp
		shift @$deployments while (@$deployments && defined($before) && $deployments->[0]->timestamp gt $before);

		# Now step through the deployments until you reach the `after` limit or the end
		return unless defined($after); # If no after limit, just return the deployments

		my $idx = 0;
		$idx++ while ($idx < @$deployments && $deployments->[$idx]->timestamp gt $after);

		# Clear any deployments that are after the `after` timestamp idx
		splice(@$deployments, $idx) if $idx < @$deployments;
	}
	return undef; # No deferred range, and we altered the deployments array passed in in place.
}

# }}}

# _confirm_deployments_sorted - check if deployments are sorted by timestamp in latest-first order {{{
sub _confirm_deployments_sorted {
	my ($self, $deployments) = @_;
	# Check if the deployments are sorted by timestamp in latest-first order
	$deployments //= $self->_all();
	return 1 if @$deployments <= 1; # An array with 1 or 0 elements is considered sorted
	my $idx = 1;
	$idx++ while (
		$idx < @$deployments &&
		$deployments->[$idx]->timestamp le $deployments->[$idx - 1]->timestamp
	);
	bug(
		"Deployments are not sorted by timestamp in latest-first order!\n\nDeployment %s at index %s is after Deployment %s at index %s",
		$deployments->[$idx]->timestamp, $idx,
		$deployments->[$idx - 1]->timestamp, $idx - 1
	) if $idx < @$deployments;
	return 1;
}
# }}}

### Private Package Functions

# _get_last_day_of_month - utility function to calculate the last day of a given month {{{
sub _get_last_day_of_month {
	my ($year, $month) = @_;
	# Create the first day of the next month
	my $next_month = ($month == 12)
		? Time::Piece->strptime(($year + 1) . "-01-01", "%Y-%m-%d")
		: Time::Piece->strptime($year . "-" . sprintf("%02d", $month + 1) . "-01", "%Y-%m-%d");
	return ($next_month - ONE_DAY)->day_of_month;
}
# }}}

# _parse_into_timestamp_cmp - parse a timestamp string into a comparable timestamp {{{
sub _parse_into_timestamp_gt_cmp {
	my ($ts, $cmp_op) = @_;
	my ($ty,$tm,$td,$tH,$tM,$tS,$tz) = (
		$ts =~ /(\d{4})(?:-?(\d{2})(?:-?(\d{2})(?:[T ]?(\d{2})(?::?(\d{2})(?::?(\d{2})(?:[Z ]?([+-]\d{4}))?)?)?)?)?)?$/
	);
	my $gt = $cmp_op =~ /^>/ ? 1 : 0;
	my $eq = $cmp_op =~ /=$/ ? 1 : 0;
	my $eff_gt = $gt ^ $eq; # Effective direction for boundary fill values
	my ($dm,$dd,$dH,$dM,$dS,$dtz) = $eff_gt
	? (12, $tm ? _get_last_day_of_month($ty,$tm) : 31, 23, 59, 59, '+0000')
	: (1, 1, 0, 0, 0, '+0000');
	my $time = Time::Piece->strptime(
		sprintf(
			"%04d-%02d-%02d %02d:%02d:%02d %s",
			$ty, $tm//$dm, $td//$dd, $tH//$dH, $tM//$dM, $tS//$dS, $tz//$dtz
		),
		EXODUS_TIME_FORMAT
	);

	# Adjust by 1 second: subtract when using start-of-period fills
	$time -= 1 unless $eff_gt;

	my $ts_str = $time->gmtime($time->epoch)->strftime(EXODUS_TIME_FORMAT_SHORT);
	return $ts_str;
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
