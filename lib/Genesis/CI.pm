package Genesis::CI;
use strict;
use warnings;

use Genesis;

### Factory Methods {{{

# new - factory constructor that dispatches to the appropriate provider {{{
sub new {
	my ($class, %opts) = @_;

	bug("%s->new is calling %s->new illegally", $class, __PACKAGE__)
		if ($class ne __PACKAGE__);

	my $type = $opts{type}
		or bail("Missing required 'type' parameter for Genesis::CI->new()");

	my $provider_info = _resolve_provider_class($type);
	eval { require $provider_info->{file} } ## no critic
		or bail("Failed to load CI provider '%s': %s", $type, $@);

	return $provider_info->{class}->init(%opts);
}

# }}}
# compile - use the compiler pipeline to generate platform-specific output {{{
sub compile {
	my ($class, %opts) = @_;

	bug("%s->compile is calling %s->compile illegally", $class, __PACKAGE__)
		if ($class ne __PACKAGE__);

	require Genesis::CI::Compiler;
	return Genesis::CI::Compiler->new(%opts)->compile(%opts);
}

# }}}
# _resolve_provider_class - map type name to package name and file {{{
sub _resolve_provider_class {
	my ($type) = @_;

	my %providers = (
		'concourse'      => {
			class => 'Genesis::CI::Concourse',
			file  => 'Genesis/CI/Compiler/Providers/Concourse.pm',
		},
		'github-actions' => {
			class => 'Genesis::CI::GithubActions',
			file  => 'Genesis/CI/Compiler/Providers/GithubActions.pm',
		},
	);

	return $providers{$type}
		|| bail("Unknown CI provider type '%s'. Valid types: %s",
			$type, join(', ', sort keys %providers));
}

# }}}
# }}}
### Trait Interface (Abstract Methods) {{{
#
# All providers MUST implement these methods.
# Calling them on the base class is a programming error.

# init - initialize provider instance {{{
sub init {
	my ($class, %opts) = @_;
	bug("Genesis::CI subclass '%s' must implement init()", $class);
}

# }}}
# parse - parse and validate configuration {{{
sub parse {
	my ($self) = @_;
	bug("Genesis::CI subclass '%s' must implement parse()", ref($self));
}

# }}}
# generate - generate platform-specific pipeline/workflow {{{
sub generate {
	my ($self) = @_;
	bug("Genesis::CI subclass '%s' must implement generate()", ref($self));
}

# }}}
# deploy - deploy/upload to CI platform {{{
sub deploy {
	my ($self, %opts) = @_;
	bug("Genesis::CI subclass '%s' must implement deploy()", ref($self));
}

# }}}
# platform_name - return human-readable platform name {{{
sub platform_name {
	my ($self) = @_;
	bug("Genesis::CI subclass '%s' must implement platform_name()", ref($self));
}

# }}}
# file_extension - return file extension for generated config {{{
sub file_extension {
	my ($self) = @_;
	bug("Genesis::CI subclass '%s' must implement file_extension()", ref($self));
}

# }}}
# }}}
### Optional Trait Methods (Default Implementations) {{{

# graphviz - generate graphviz visualization (optional) {{{
sub graphviz {
	my ($self) = @_;
	bail("Provider '%s' does not support graphviz visualization",
		$self->platform_name);
}

# }}}
# describe - generate human-readable description (optional) {{{
sub describe {
	my ($self) = @_;
	bail("Provider '%s' does not support human-readable description",
		$self->platform_name);
}

# }}}
# }}}

1;

=head1 NAME

Genesis::CI - Factory and trait interface for CI providers

=head1 DESCRIPTION

Genesis::CI is the factory class and trait interface for the Genesis CI
pipeline generation system. It dispatches to platform-specific provider
implementations based on the C<type> parameter.

=head1 SYNOPSIS

  use Genesis::CI;

  # Create a provider via the factory
  my $ci = Genesis::CI->new(
    type   => 'concourse',      # or 'github-actions'
    file   => 'ci.yml',
    top    => $top_obj,
    layout => 'default',
  );

  # Use the trait interface
  $ci->parse();
  my $yaml = $ci->generate();
  $ci->deploy(target => 'prod', yes => 1);

  # Or use the compiler pipeline
  my $output = Genesis::CI->compile(
    ci_dir   => '.genesis/ci',
    provider => 'concourse',
    top      => $top_obj,
  );

=head1 FACTORY METHODS

=head2 new(%opts)

Factory constructor. Required: C<type>. Returns an instance of the
appropriate provider subclass.

=head2 compile(%opts)

Uses the compiler pipeline (Parser, Validator, ASTBuilder, Provider)
to generate platform-specific output from configuration files.

=head1 TRAIT INTERFACE

All providers must implement: C<init>, C<parse>, C<generate>, C<deploy>,
C<platform_name>, C<file_extension>.

Optional: C<graphviz>, C<describe>.

=head1 SEE ALSO

Genesis::CI::Concourse, Genesis::CI::GithubActions, Genesis::CI::Legacy,
Genesis::CI::Compiler

=cut

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
