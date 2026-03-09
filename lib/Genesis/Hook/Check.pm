package Genesis::Hook::Check;
use strict;
use warnings;

use parent qw(Genesis::Hook);

use Genesis qw/info error bail new_enough count_nouns in_array uniq/;
use Genesis::Term qw/bullet/;

sub init {
	my $class = shift;
	$class->check_for_required_args({@_}, qw/env kit/);
	my $obj = $class->SUPER::init(@_);
	return $obj
}

sub start_check {
	my ($self, $type) = @_;
	info("[[  - >>checking %s...", $type =~ s/[-_]/ /gr);
}

sub check_result {
	my ($self, $config, $result, $message) = @_;
	if (!defined $result) {
		# If result isn't explicitly set, check the results of has_entry
		# Given the structure of $self->{__entry_checks}{config}{type}{name},
		# we need to check if any of the entries are false
		# REFACTOR: Alternatively, we just keep a count of failed checks per config type
		$result = (grep {!$_ } map { values %$_ } values %{$self->{__entry_checks}{$config}}) ? 'failed' : 'passed';
	}

	# Standardize the result to a common set of values
	$result = 'failed' if $result eq 'error' || !$result;
	$result = 'passed' if $result eq 'ok' || $result eq 'passed' || $result eq '1';

	info(
		"[[  - >>#C{%s} #%s{%s}%s",
		$config =~ s/[-_]/ /gr,
		$result eq 'passed' ? 'G' : $result eq 'failed' ? 'R' : 'Y',
		$result,
		$message ? " - $message" : ''
	);
	return $result eq 'failed' ? 0 : 1;
}


sub has_entry {
	my ($self, $config, $type, $name, @args) = @_;
	my $has_entry = undef;
	my @msg = ();
	if ($config eq 'cloud-config') {
		($has_entry, @msg) = $self->has_cloud_config_entry($type, $name, @args);
	} elsif ($config eq 'runtime-config') {
		($has_entry, @msg) = $self->has_runtime_config_entry($type, $name, @args);
	} elsif ($config eq 'environment') {
		($has_entry, @msg) = $self->has_environment_entry($type, $name, @args);
	} else {
		error("Unknown check type: %s - expecting 'cloud-config', 'runtime-config' or 'environment'", $config);
		return 0;
	}
	$self->{__entry_checks}{$config}{$type}{$name} = $has_entry;
	@msg = (
		"#Y{%s} %s",
		$type =~ s/[-_]/ /gr,
		$name
	) unless @msg;
	info(
		"[[    %s>>".shift(@msg),
		bullet($has_entry ? 'good' : 'bad','',box => 1),
		@msg
	)
}

sub has_cloud_config_entry {
	my ($self, $type, $name, @args) = @_;
	$self->{__cloud_config} //= $self->env->config_contents(type => 'cloud');
	my $type_lookup= count_nouns(2, $type, suppress_count => 1);
	return (grep {$_->{name} eq $name} @{$self->{__cloud_config}{$type_lookup}//[]}) ? 1 : 0;
}

sub has_runtime_config_entry {
	my ($self, $type, $name, @args) = @_;
	$self->{__runtime_config} //= $self->env->config_contents(type => 'runtime');
	my $contents = $self->{__runtime_config}{addons} // [];
	if ($type eq 'job') {
		my $jobs = $self->{__runtime_config_jobs} //= [
			uniq map {$_->{name}} map {$_->{jobs}->@*} ($self->{__runtime_config}{addons}->@*)
		];
		return (
			in_array($name, @$jobs) ? 1 : 0,
			"#Y{%s} job exists", # TODO: in addon xxx
			$name
		)

	} else {
		bug("Unknown check type: %s - expecting 'job' (might have to add %s implementation)", $type, $type);
	}
}

sub has_environment_entry {
	my ($self, $type, $name, @args) = @_;
	$self->{__environment} //= $self->env->lookup();

	if ($type eq 'params') {
		# Support for params under environment
		my $param = $self->{__environment}{params}{$name};
		my %opts = @args;
		if (exists($opts{type})) {
			my $reqtype = $opts{type};
			my $actualtype = lc(ref($param) || defined($param) ? 'string' : 'undefined'); # expand to non-empty-string, number, ip, domain, etc.
			if ($reqtype) {
				return (
					($actualtype eq $reqtype) ? 1 : 0,
					"params.#Y{%s}%s",
					$opts{msg} || "is ".($reqtype eq 'undefined' ? 'undefined' : "a $reqtype"),
				);
			}
		}
		if ($opts{value_in}) {
			return (
				defined($param) && in_array($param, $opts{value_in}->@*) ? 1 : 0,
				"params.#Y{%s}%s",
				$opts{msg} || "must be one of ".join(', ', $opts{value_in}->@*),
			);
		}
		if ($opts{retired}) {
			# FIXME: Should this take another parameter for what it changed to?
			return (
				defined($param) ? 0 : 1,
				"params.#Y{%s}%s",
				$opts{msg} || "has been retired and no longer supported",
			);
		}
		# Add support for other checks here: exclusivity of params, ranges, etc.
		return (
			defined($param) ? 1 : 0,
			"params.#Y{%s}%s",
			$opts{msg} || "is provided",
		);
	} elsif ($type eq 'exodus') {
		my %opts = @args;

		return (
			defined($self->exodus_data->{name}) ? 1 : 0,
			"#Y{%s} exodus entry exists",
			$opts{msg} || $name,
		) unless (@opts{qw/env deployment/});

		my $for = ($opts{env}//$self->env->name).'/'.$opts{deployment};
		my $value = $self->env->exodus_lookup($name,undef, $for);
		return (
			defined($value) ? 1 : 0,
			"#Y{%s} exodus entry exists under #M{%s}",
			$opts{msg} || ($name, $for)
		);

	} else {
		bug("Unknown check type: %s - expecting 'params' (might have to add %s implementation)", $type, $type);
	}
}

1;
