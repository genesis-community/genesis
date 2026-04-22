package Genesis::CI::Compiler;
use strict;
use warnings;

use Genesis;
use Genesis::CI::Compiler::Parser;
use Genesis::CI::Compiler::Validator;
use Genesis::CI::Compiler::ScriptDiscovery;
use Genesis::CI::Compiler::ASTBuilder;
use Genesis::CI::Compiler::PipelineDescriptor;

# Register as the owner of the ci: section in .genesis/config.
# This runs at module load time so Top.pm's _validate_config() can
# delegate ci: section validation to us when we're loaded.
{
	require Genesis::Top;
	Genesis::Top->register_config_section('ci', __PACKAGE__);
}

### Constructor {{{

# new - create a new compiler instance {{{
sub new {
	my ($class, %opts) = @_;

	return bless({
		ci_dir  => $opts{ci_dir},
		file    => $opts{file},
		env_dir => $opts{env_dir},
		top     => $opts{top},
	}, $class);
}

# }}}
# }}}
### Public Methods {{{

# compile - run the full compilation pipeline {{{
sub compile {
	my ($self, %opts) = @_;

	my $provider_type = $opts{provider}
		or bail("Missing required 'provider' parameter for compile()");

	# Stage 1: Parse configuration
	info("Parsing pipeline configuration...");
	my $parser = Genesis::CI::Compiler::Parser->new(
		ci_dir => $self->{ci_dir},
		file   => $self->{file},
		top    => $self->{top},
	);
	my $parsed = $parser->parse();

	# Stage 2: Validate
	info("Validating configuration...");
	my $validator = Genesis::CI::Compiler::Validator->new(top => $self->{top});
	$validator->validate($parsed);

	if ($validator->has_warnings) {
		for my $warn (@{$validator->warnings}) {
			error("#Y{warning}: %s", $warn);
		}
	}

	if ($validator->has_errors) {
		error("#R{ERRORS encountered} in pipeline configuration:");
		error("  - #R{%s}", $_) for @{$validator->errors};
		bail("Pipeline configuration is invalid");
	}

	# Stage 3: Discover scripts
	info("Discovering scripts...");
	my $script_discovery = Genesis::CI::Compiler::ScriptDiscovery->new(
		repo_path => '.',
	);
	my $scripts = $script_discovery->discover($parsed);

	# Stage 4: Build AST (source representation)
	info("Building pipeline AST...");
	my $ast_builder = Genesis::CI::Compiler::ASTBuilder->new(
		top     => $self->{top},
		env_dir => $self->{env_dir},
	);
	my $ast = $ast_builder->build($parsed, $scripts);

	# Stage 5: Resolve generic pipeline from source representation
	info("Resolving pipeline...");
	my $descriptor = Genesis::CI::Compiler::PipelineDescriptor->new(
		ast => $ast,
		top => $self->{top},
	);
	$ast->set_pipeline($descriptor->describe());

	# Stage 6: Load and run provider
	# Stage 6 continued: generate platform-specific output
	info("Generating %s pipeline...", $provider_type);
	my $provider_info = $self->_resolve_provider_class($provider_type);
	eval { require $provider_info->{file} } ## no critic
		or bail("Failed to load CI provider '%s': %s", $provider_type, $@);

	# Extract provider options from parsed config (ci.provider: section)
	# and merge with any caller-supplied opts.  Normalize caller opts from their
	# CLI form (ci-* prefixed, hyphenated) to config/schema form (unprefixed, underscored)
	# so that provider_option() and provider_config() always see consistent keys.
	require Genesis::CI::Compiler::PipelineProvider;
	my $provider_opts = {
		%{ $parsed->{provider} || {} },
		%{ Genesis::CI::Compiler::PipelineProvider->normalize_provider_opts(
			$opts{provider_opts} || {}
		) },
	};

	my $provider = $provider_info->{class}->new(
		ast           => $ast,
		top           => $self->{top},
		provider_opts => $provider_opts,
	);
	my $raw_output = $provider->generate_from_ast($ast);

	# Wrap raw output into file map using provider's output_files manifest
	my $output;
	if (ref($raw_output) eq 'HASH') {
		$output = $raw_output;
	} else {
		my $files = $provider->output_files || {};
		my @filenames = keys %$files;
		my $filename = @filenames ? $filenames[0] : 'pipeline.yml';
		$output = { $filename => $raw_output };
	}

	# Stage 7: Apply provider-specific overrides (optional)
	$output = $self->_apply_provider_overrides($output, $provider_type);

	return {
		ast      => $ast,
		output   => $output,
		provider => $provider,
		parsed   => $parsed,
	};
}

# }}}
# }}}
### Class Methods {{{

# can_compile - detect if multi-file config with pipeline.yml exists {{{
sub can_compile {
	my ($class, $ci_dir) = @_;
	$ci_dir ||= '.genesis/ci';

	return (-d $ci_dir && -f "$ci_dir/pipeline.yml");
}

# }}}
# can_compile_from_env_files - detect if .genesis/ci/ exists for env-file topology {{{
#
# Returns true when the .genesis/ci/ directory is present and contains the
# required support files (targets.yml + integrations.yml), even if there is
# no pipeline.yml (topology coming from genesis.pipeline.* in env files).
sub can_compile_from_env_files {
	my ($class, $ci_dir) = @_;
	$ci_dir ||= '.genesis/ci';

	return (
		-d  $ci_dir &&
		-f  "$ci_dir/targets.yml" &&
		-f  "$ci_dir/integrations.yml" &&
		!-f "$ci_dir/pipeline.yml"
	);
}

# }}}
# can_compile_from_genesis_config - detect if ci: section exists in .genesis/config {{{
#
# Returns true when $top has a Genesis::Config with a ci: key, meaning
# CI configuration is embedded inline in .genesis/config rather than in
# separate files under .genesis/ci/.
sub can_compile_from_genesis_config {
	my ($class, $top) = @_;
	return 0 unless $top && $top->can('config');
	return 0 unless eval { $top->config->has('ci') };
	return 1;
}

# }}}
# validate_config_section - validate the ci: section delegated by Top.pm {{{
#
# Called by Top::_validate_config() when this module is loaded and a ci: key
# exists in .genesis/config.  Performs structural validation; detailed
# cross-reference checks happen later in Compiler::Validator during compile().
sub validate_config_section {
	my ($class, $data, $top) = @_;

	return unless defined $data;
	bail("'ci' configuration in .genesis/config must be a hash")
		unless ref($data) eq 'HASH';

	# ci.targets must be a non-empty hash
	my $targets = $data->{targets};
	bail("'ci.targets' is required and must define at least one target")
		unless defined($targets) && ref($targets) eq 'HASH' && scalar(keys %$targets) > 0;

	# ci.integrations.source_control is required and must be a hash
	my $integrations = $data->{integrations};
	if (defined $integrations) {
		bail("'ci.integrations' must be a hash") unless ref($integrations) eq 'HASH';
		my $sc = $integrations->{source_control};
		bail("'ci.integrations.source_control' is required")
			unless defined $sc;
		bail("'ci.integrations.source_control' must be a hash")
			unless ref($sc) eq 'HASH';
	} else {
		bail("'ci.integrations.source_control' is required");
	}

	# Validate ci.provider section against the provider's own schema
	if (my $provider_data = $data->{provider}) {
		bail("'ci.provider' must be a hash")
			unless ref($provider_data) eq 'HASH';

		my $type = $provider_data->{type};
		bail("'ci.provider.type' is required") unless $type;

		# Load provider class to get its schema
		my $provider_info = eval { $class->_resolve_provider_class($type) };
		if ($@) {
			bail("'ci.provider.type' is '%s', which is not a known CI provider type.  ".
				"Valid types: %s", $type,
				join(', ', Genesis::CI::Compiler::PipelineProvider->known_providers()));
		}

		eval { require $provider_info->{file} };  ## no critic
		if ($@) {
			bail("Failed to load CI provider '%s' for config validation: %s", $type, $@);
		}

		my $schema   = $provider_info->{class}->provider_options_schema();
		my $defaults = $provider_info->{class}->provider_options_defaults();

		# Check required keys
		for my $key (sort keys %$schema) {
			my $spec = $schema->{$key};
			next unless $spec->{required};
			bail("'ci.provider.%s' is required for provider type '%s'", $key, $type)
				unless defined $provider_data->{$key};
		}

		# Check unknown keys
		for my $key (sort keys %$provider_data) {
			next if exists $schema->{$key};
			bail("'ci.provider.%s' is not a recognized option for provider type '%s'.  ".
				"Valid options: %s",
				$key, $type, join(', ', sort keys %$schema));
		}
	}
}

# }}}
# }}}
### Internal Methods {{{

# _apply_provider_overrides - deep-merge ci-overrides-<provider>.yml via spruce {{{
sub _apply_provider_overrides {
	my ($self, $output, $provider_type) = @_;

	# Locate the ci directory
	my $ci_dir = $self->{ci_dir};
	unless ($ci_dir) {
		my $f = $self->{file} || '';
		($ci_dir = $f) =~ s{/[^/]+$}{} or $ci_dir = '.';
	}

	my $override_file = "$ci_dir/ci-overrides-${provider_type}.yml";
	return $output unless -f $override_file;

	info("Applying ci-overrides-%s.yml...", $provider_type);

	my $dir = workdir;
	my %merged;

	for my $filename (sort keys %$output) {
		my $content = $output->{$filename};

		# Only spruce-merge YAML files; pass others through unchanged
		unless ($filename =~ /\.ya?ml$/i) {
			$merged{$filename} = $content;
			next;
		}

		my $base_path = "$dir/override-base-${filename}";
		open(my $fh, '>', $base_path)
			or bail("Cannot write temporary override base %s: %s", $base_path, $!);
		print $fh $content
			or bail("Cannot write to temporary override base %s: %s", $base_path, $!);
		close $fh
			or bail("Cannot flush temporary override base %s: %s", $base_path, $!);

		my ($merged_yaml, $rc) = run(
			'spruce', 'merge', $base_path, $override_file
		);
		bail("Failed to apply ci-overrides-%s.yml: spruce merge returned non-zero",
			$provider_type)
			unless $rc == 0;

		$merged{$filename} = $merged_yaml;
	}

	return \%merged;
}

# }}}
# _resolve_provider_class - map type name to provider package and file {{{
sub _resolve_provider_class {
	my ($self, $type) = @_;

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

1;

=head1 NAME

Genesis::CI::Compiler - CI pipeline compilation orchestrator

=head1 DESCRIPTION

Genesis::CI::Compiler orchestrates the full compilation pipeline:

  1. Parser    - Load configuration files (legacy or multi-file)
  2. Validator - Validate structure, cross-references, semantics
  3. ScriptDiscovery - Find and parse script metadata
  4. ASTBuilder - Construct platform-agnostic AST
  5. PipelineDescriptor - Resolve generic pipeline from source AST
  6. Provider  - Generate platform-specific output from AST
  7. Overrides - Deep-merge ci-overrides-<provider>.yml if present

=head1 SYNOPSIS

  # Compile from new multi-file format
  my $result = Genesis::CI::Compiler->new(
    ci_dir => '.genesis/ci',
    top    => $top_obj,
  )->compile(provider => 'concourse');

  # Compile from legacy ci.yml
  my $result = Genesis::CI::Compiler->new(
    file => 'ci.yml',
    top  => $top_obj,
  )->compile(provider => 'concourse');

  # Check if new format is available
  if (Genesis::CI::Compiler->can_compile('.genesis/ci')) {
    # Use compiler pipeline
  }

=head1 SEE ALSO

Genesis::CI, Genesis::CI::Compiler::Parser, Genesis::CI::Compiler::AST

=cut

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
