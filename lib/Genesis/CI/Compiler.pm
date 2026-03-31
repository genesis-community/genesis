package Genesis::CI::Compiler;
use strict;
use warnings;

use Genesis;
use Genesis::CI::Compiler::Parser;
use Genesis::CI::Compiler::Validator;
use Genesis::CI::Compiler::ScriptDiscovery;
use Genesis::CI::Compiler::ASTBuilder;
use Genesis::CI::Compiler::PipelineDescriptor;

### Constructor {{{

# new - create a new compiler instance {{{
sub new {
	my ($class, %opts) = @_;

	return bless({
		ci_dir => $opts{ci_dir},
		file   => $opts{file},
		top    => $opts{top},
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
		top => $self->{top},
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

	my $provider = $provider_info->{class}->new(ast => $ast, top => $self->{top});
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

# can_compile - detect if new config format exists at a path {{{
sub can_compile {
	my ($class, $ci_dir) = @_;
	$ci_dir ||= '.genesis/ci';

	return (-d $ci_dir && -f "$ci_dir/pipeline.yml");
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
		print $fh $content;
		close $fh;

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
