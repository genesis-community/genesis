package Genesis::CI::Provider;
use strict;
use warnings;

use Genesis;
use Getopt::Long qw/GetOptionsFromArray/;

### Class Methods {{{

# new - builder for creating new instance of derived class based on config {{{
sub new {
	my ($class, %config) = @_;
	bug("%s->new is calling %s->new illegally", $class, __PACKAGE__)
		if $class ne __PACKAGE__;

	my $type = $config{type} || 'manual';

	my $obj;
	if ($type eq 'concourse') {
		require Genesis::CI::Provider::Concourse;
		$obj = Genesis::CI::Provider::Concourse->new(%config);
	} elsif ($type eq 'github-actions') {
		require Genesis::CI::Provider::GithubActions;
		$obj = Genesis::CI::Provider::GithubActions->new(%config);
	} elsif ($type eq 'manual') {
		require Genesis::CI::Provider::Manual;
		$obj = Genesis::CI::Provider::Manual->new(%config);
	} else {
		bail("Unknown CI provider type '%s'. Valid types: concourse, github-actions, manual", $type);
	}

	my @errors = $obj->validate_config;
	bail(
		"Invalid CI provider configuration for type '%s':\n%s",
		$type, join("\n", map { "  - $_" } @errors)
	) if @errors;

	return $obj;
}

# }}}
# init - builder for creating new instance based on CLI options {{{
sub init {
	my ($class, %opts) = @_;
	bug("%s->init is calling %s->init illegally", $class, __PACKAGE__)
		if $class ne __PACKAGE__;

	my $type = $opts{'ci-provider'} || 'manual';

	if ($type eq 'concourse') {
		require Genesis::CI::Provider::Concourse;
		return Genesis::CI::Provider::Concourse->init(%opts);
	} elsif ($type eq 'github-actions') {
		require Genesis::CI::Provider::GithubActions;
		return Genesis::CI::Provider::GithubActions->init(%opts);
	} elsif ($type eq 'manual') {
		require Genesis::CI::Provider::Manual;
		return Genesis::CI::Provider::Manual->init(%opts);
	} else {
		bail("Unknown CI provider type '%s'. Valid types: concourse, github-actions, manual", $type);
	}
}

# }}}
# parse_opts - two-pass extraction: first --ci-provider, then provider-specific flags {{{
sub parse_opts {
	my ($class, $args, $ci_opts) = @_;
	Getopt::Long::Configure(qw(pass_through permute no_auto_abbrev no_ignore_case bundling));

	# Stop at '--'
	my $opt_args = [];
	while (scalar(@$args) && $args->[0] ne '--') {
		push @$opt_args, shift @$args;
	}

	# First pass: extract --ci-provider
	GetOptionsFromArray($opt_args, $ci_opts, qw/ci-provider=s/);
	my $type = $ci_opts->{'ci-provider'};

	# Second pass: extract provider-specific flags
	my @extra_opts;
	if (!$type || $type eq 'manual') {
		require Genesis::CI::Provider::Manual;
		@extra_opts = Genesis::CI::Provider::Manual->opts();
	} elsif ($type eq 'concourse') {
		require Genesis::CI::Provider::Concourse;
		@extra_opts = Genesis::CI::Provider::Concourse->opts();
	} elsif ($type eq 'github-actions') {
		require Genesis::CI::Provider::GithubActions;
		@extra_opts = Genesis::CI::Provider::GithubActions->opts();
	} else {
		bail("Unknown CI provider type '%s'. Valid types: concourse, github-actions, manual", $type);
	}

	GetOptionsFromArray($opt_args, $ci_opts, @extra_opts) if @extra_opts;

	# Return non-option args to $args
	while (scalar(@$opt_args)) { unshift @$args, pop @$opt_args }

	return 1;
}

# }}}
# opts_slot - key name for this handler's parsed options in $COMMAND_OPTIONS {{{
sub opts_slot { 'ci_provider' }

# }}}
# opts - base class has no options of its own {{{
sub opts {
	qw//;
}

# }}}
# opts_help - aggregate usage docs from all providers {{{
sub opts_help {
	my ($class, %config) = @_;
	bug("%s->opts_help is calling %s->opts_help illegally", $class, __PACKAGE__)
		if $class ne __PACKAGE__;

	require Genesis::CI::Provider::Concourse;
	require Genesis::CI::Provider::GithubActions;
	require Genesis::CI::Provider::Manual;

	$config{type_default_msg} ||= '(optional, defaults to "manual")';
	$config{valid_types}      ||= [qw(concourse github-actions manual)];

	<<EOF;
CI PROVIDERS

Genesis can configure a CI/CD pipeline for your deployment repository.
Each provider type requires its own set of options.

  General CI Provider Options:

    --ci-provider <type> $config{type_default_msg}
        The type of CI provider to configure.  Valid types:
        concourse, github-actions, manual.

${\Genesis::CI::Provider::Concourse->opts_help(%config)
}${\Genesis::CI::Provider::GithubActions->opts_help(%config)
}${\Genesis::CI::Provider::Manual->opts_help(%config)
}
EOF
}

# }}}
# }}}
### Instance Methods {{{

# label - human-readable name for this provider {{{
sub label {
	$_[0]->{label} // 'CI Provider';
}

# }}}
# config - returns hash for .genesis/config ci.provider section (abstract) {{{
sub config {
	my ($self) = @_;
	bug("Abstract Method: %s class must define 'config'", ref($self));
}

# }}}
# check_prereqs - returns 1 if toolchain is present, 0 + error() if not {{{
sub check_prereqs {
	return 1;
}

# }}}
# validate_config - check stored config fields; returns list of error strings {{{
#
# Called by Provider->new after the subclass object is constructed.
# Subclasses override this to assert that all required fields are present and
# well-formed.  Returning an empty list means the config is valid.
# No network calls should be made here — this is a fast, local check only.
sub validate_config {
	return ();
}

# }}}
# interactive_wizard - prompt the user for provider config interactively (abstract) {{{
sub interactive_wizard {
	my ($self, $top) = @_;
	bug("Abstract Method: %s class must define 'interactive_wizard'", ref($self));
}

# }}}
# }}}

1;

=head1 NAME

Genesis::CI::Provider - CI provider factory and base class

=head1 DESCRIPTION

Genesis::CI::Provider is the factory and abstract base class for CI provider
configuration management.  It follows the same pattern as Genesis::Kit::Provider.

Concrete subclasses: Concourse, GithubActions, Manual.

=head1 SYNOPSIS

  # Parse CLI opts (two-pass: --ci-provider first, then provider-specific)
  my %ci_opts;
  Genesis::CI::Provider->parse_opts(\@ARGV, \%ci_opts);

  # Build provider object from CLI opts
  my $provider = Genesis::CI::Provider->init(%ci_opts);

  # Get config hash for .genesis/config ci.provider section
  my %cfg = $provider->config();

  # Reconstruct from stored config
  my $provider = Genesis::CI::Provider->new(type => 'concourse', target => 'prod');

=head1 SEE ALSO

Genesis::Kit::Provider, Genesis::CI::Compiler

=cut

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1
