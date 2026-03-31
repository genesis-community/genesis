package Genesis::CI::Concourse;
use v5.20;
use warnings;

use parent 'Genesis::CI', 'Genesis::CI::Compiler::PipelineProvider';

use Genesis;
use Genesis::Top;
use Genesis::CI::Legacy;
use Genesis::CI::Compiler::PipelineDescriptor;
use JSON::PP;

### Class Methods {{{

# new - constructor for compiler pipeline path {{{
sub new {
	my ($class, %opts) = @_;

	# Compiler construction path: receives AST and optionally top
	if ($opts{ast}) {
		return bless({
			ast => $opts{ast},
			top => $opts{top},
		}, $class);
	}

	# Direct construction without AST is not supported
	bug("Use Genesis::CI->new(type => 'concourse', ...) for trait construction, ".
		"or pass ast => \$ast for compiler construction");
}

# }}}
# init - initialize Concourse provider {{{
sub init {
	my ($class, %opts) = @_;

	my $self = bless({
		file      => $opts{file},
		top       => $opts{top},
		layout    => $opts{layout},
		_platform => $opts{platform} || '',
		config    => undef,
		ast       => undef,
		errors    => [],
	}, $class);

	return $self;
}

# }}}
# }}}
### Trait Interface Implementation {{{

# parse - parse and validate Concourse pipeline configuration {{{
sub parse {
	my ($self) = @_;

	my $platform = $self->{_platform} || '';

	# Legacy fallback: delegate to Legacy::parse when --platform legacy
	if ($platform eq 'legacy') {
		my ($pipeline, $layout) = Genesis::CI::Legacy::parse(
			$self->{file},
			$self->{top},
			$self->{layout}
		);
		$self->{config} = $pipeline;
		$self->{layout} = $layout;
		return $self;
	}

	# Native path: use the compiler pipeline
	require Genesis::CI::Compiler::Parser;
	require Genesis::CI::Compiler::Validator;
	require Genesis::CI::Compiler::ScriptDiscovery;
	require Genesis::CI::Compiler::ASTBuilder;

	my $parser = Genesis::CI::Compiler::Parser->new(
		file => $self->{file},
		top  => $self->{top},
	);
	my $parsed = $parser->parse();

	my $validator = Genesis::CI::Compiler::Validator->new(top => $self->{top});
	$validator->validate($parsed);

	if ($validator->has_errors) {
		bail("Pipeline configuration is invalid:\n  - %s",
			join("\n  - ", @{$validator->errors}));
	}

	my $script_discovery = Genesis::CI::Compiler::ScriptDiscovery->new(
		repo_path => '.',
	);
	my $scripts = $script_discovery->discover($parsed);

	my $ast_builder = Genesis::CI::Compiler::ASTBuilder->new(
		top => $self->{top},
	);
	my $ast = $ast_builder->build($parsed, $scripts);

	$self->{ast}    = $ast;
	$self->{config} = $parsed;
	$self->{layout} = $self->{layout};

	return $self;
}

# }}}
# generate - generate Concourse pipeline YAML {{{
sub generate {
	my ($self) = @_;

	bail("Must call parse() before generate()") unless $self->{config};

	# Legacy fallback
	if ($self->{_platform} && $self->{_platform} eq 'legacy') {
		return Genesis::CI::Legacy::generate_pipeline_concourse_yaml(
			$self->{config},
			$self->{top}
		);
	}

	# Native generation from AST
	bail("No AST available; call parse() first") unless $self->{ast};
	return $self->generate_from_ast($self->{ast});
}

# }}}
# deploy - deploy pipeline to Concourse via fly CLI {{{
sub deploy {
	my ($self, %opts) = @_;
	
	my $target = $opts{target} || $self->{layout};
	my $pipeline_name = $self->{config}{pipeline}{name};
	my $dry_run = $opts{'dry-run'};
	my $yes = $opts{yes};
	my $paused = $opts{paused};
	
	bail("Must call parse() before deploy()") unless $self->{config};
	
	my $yaml = $self->generate();
	
	if ($dry_run) {
		output({raw => 1}, $yaml);
		return;
	}
	
	# Pause pipeline before updating
	my ($out, $rc) = run(
		'fly -t $1 pause-pipeline -p $2',
		$target, $pipeline_name
	);
	bail("Could not pause pipeline '%s': %s", $pipeline_name, $out)
		unless $rc == 0 || $out =~ /pipeline '.*' not found/;
	
	# Write pipeline to temp file
	my $dir = workdir;
	mkfile_or_fail("${dir}/pipeline.yml", $yaml);
	
	# Upload pipeline
	my $yes_flag = $yes ? '-n' : '';
	run({
		interactive => 1,
		onfailure => "Could not upload pipeline $pipeline_name"
	},
		'fly -t $1 set-pipeline '.$yes_flag.' -p $2 -c $3/pipeline.yml',
		$target, $pipeline_name, $dir
	);
	
	# Unpause pipeline (unless --paused)
	unless ($paused) {
		run({
			interactive => 1,
			onfailure => "Could not unpause pipeline $pipeline_name"
		},
			'fly -t $1 unpause-pipeline -p $2',
			$target, $pipeline_name
		);
	}
	
	# Set visibility (public/private)
	my $action = $self->{config}{pipeline}{public} ? 'expose' : 'hide';
	run({
		interactive => 1,
		onfailure => "Could not $action pipeline $pipeline_name"
	},
		'fly -t $1 '.$action.'-pipeline -p $2',
		$target, $pipeline_name
	);
	
	return;
}

# }}}
# platform_name - return platform name {{{
sub platform_name {
	return "Concourse";
}

# }}}
# file_extension - return file extension {{{
sub file_extension {
	return ".yml";
}

# }}}
# }}}
### Compiler Pipeline Interface {{{

# generate_from_ast - generate Concourse pipeline from AST {{{
sub generate_from_ast {
	my ($self, $ast) = @_;

	my $source = $ast->metadata->{source} || '';

	# For legacy-sourced ASTs with raw pipeline data, bridge to Legacy
	if ($source eq 'legacy'
		&& $ast->provider_config->{concourse}
		&& $ast->provider_config->{concourse}{_legacy_pipeline_raw}
		&& $self->{top}) {
		return $self->_generate_from_legacy_ast($ast);
	}

	# For all other ASTs, generate natively
	return $self->_generate_native($ast);
}

# }}}
# output_files - describe generated files {{{
sub output_files {
	return { 'pipeline.yml' => 'Concourse pipeline definition' };
}

# }}}
# }}}
### Legacy AST Bridge {{{

# _generate_from_legacy_ast - bridge AST back to Legacy generator {{{
sub _generate_from_legacy_ast {
	my ($self, $ast) = @_;

	my $raw_p = $ast->provider_config->{concourse}{_legacy_pipeline_raw};

	# Get the first (typically only) workflow's legacy data
	my @wf_names = $ast->workflow_names;
	my $wf = $ast->workflows->{$wf_names[0]};
	my $leg = $wf->{_legacy} || {};

	# Reconstruct the fully-parsed $P hashref that Legacy expects
	my $P = {
		pipeline => { %$raw_p },
		file     => $ast->metadata->{source_file} || 'ci.yml',
		envs     => $leg->{environments} || [],
		auto     => $leg->{auto_envs}    || [],
		aliases      => { %{$leg->{aliases}      || {}} },
		genesis_envs => { %{$leg->{genesis_envs} || {}} },
		will_trigger => { %{$leg->{will_trigger} || {}} },
		triggers     => ref($leg->{triggers}) eq 'HASH'
			? { %{$leg->{triggers}} } : {},
	};

	# Apply defaults (same as Legacy::parse)
	$P->{pipeline}{tagged}     = _yaml_bool($P->{pipeline}{tagged}, 0);
	$P->{pipeline}{public}     = _yaml_bool($P->{pipeline}{public}, 0);
	$P->{pipeline}{unredacted} = _yaml_bool($P->{pipeline}{unredacted}, 0);
	$P->{pipeline}{ocfp}       = _yaml_bool($P->{pipeline}{ocfp}, 0);
	if ($P->{pipeline}{vault}) {
		$P->{pipeline}{vault}{verify} = _yaml_bool($P->{pipeline}{vault}{verify}, 1);
	}
	$P->{pipeline}{task}{image}      ||= 'genesiscommunity/concourse';
	$P->{pipeline}{task}{version}    ||= 'latest';
	$P->{pipeline}{task}{privileged} ||= [];

	return Genesis::CI::Legacy::generate_pipeline_concourse_yaml($P, $self->{top});
}

# }}}
# }}}
### Native Concourse Generator {{{

# _generate_native - serialize the generic pipeline from AST to Concourse YAML {{{
sub _generate_native {
	my ($self, $ast) = @_;

	$self->_ensure_pipeline_resolved();

	# Serialize the generic pipeline to Concourse YAML
	my $pipeline = {
		groups         => $ast->groups,
		resources      => $ast->pipeline_resources,
		resource_types => $ast->resource_types,
		jobs           => $ast->jobs,
	};

	return "---\n" . $self->dump_yaml($pipeline) . "\n";
}

# }}}
# }}}
### Additional Concourse-Specific Methods {{{

# graph_md - generate pipeline.md with Mermaid flowchart {{{
sub graph_md {
	my ($self) = @_;

	bail("Must call parse() before graph_md()") unless $self->{config};

	# Legacy fallback: no Mermaid support; return minimal document
	if ($self->{_platform} && $self->{_platform} eq 'legacy') {
		my $name = ($self->{config}{pipeline} || {})->{name} || 'pipeline';
		return "# Pipeline: $name\n\n*(Legacy provider — graph not available)*\n";
	}

	# Native Mermaid from AST
	bail("No AST available; call parse() first") unless $self->{ast};
	$self->_ensure_pipeline_resolved();
	return $self->{ast}->pipeline_md();
}

# }}}
# describe - generate human-readable description {{{
sub describe {
	my ($self) = @_;

	bail("Must call parse() before describe()") unless $self->{config};

	# Legacy fallback
	if ($self->{_platform} && $self->{_platform} eq 'legacy') {
		Genesis::CI::Legacy::generate_pipeline_human_description(
			$self->{config}
		);
		return;
	}

	# Native description from AST
	bail("No AST available; call parse() first") unless $self->{ast};
	$self->_ensure_pipeline_resolved();
	output({raw => 1}, $self->{ast}->description());
	return;
}

# }}}
# }}}
### Accessors {{{

# config - get parsed configuration {{{
sub config {
	return $_[0]->{config};
}

# }}}
# top - get Genesis::Top object {{{
sub top {
	return $_[0]->{top};
}

# }}}
# layout - get layout name {{{
sub layout {
	return $_[0]->{layout};
}

# }}}
# }}}
### Internal Helpers {{{

# _ensure_pipeline_resolved - resolve pipeline via PipelineDescriptor if needed {{{
sub _ensure_pipeline_resolved {
	my ($self) = @_;
	my $ast = $self->{ast} or return;
	unless ($ast->pipeline && %{$ast->pipeline}) {
		my $descriptor = Genesis::CI::Compiler::PipelineDescriptor->new(
			ast => $ast,
			top => $self->{top},
		);
		$ast->set_pipeline($descriptor->describe());
	}
}

# }}}
# _yaml_bool - handle yaml boolean values with defaults {{{
sub _yaml_bool {
	my ($bool, $default) = @_;
	return ($default || 0) unless defined $bool;
	return $bool ? 1 : 0;
}

# }}}
# }}}

1;

=head1 NAME

Genesis::CI::Concourse - Concourse CI provider implementation

=head1 DESCRIPTION

Genesis::CI::Concourse implements the Genesis::CI trait interface for
Concourse CI. It handles parsing ci.yml configuration, generating Concourse
pipeline YAML, and deploying pipelines via the fly CLI.

This implementation currently delegates to Genesis::CI::Legacy for the heavy
lifting, but provides a clean interface for future refactoring.

=head1 SYNOPSIS

  # Via trait interface (legacy path)
  use Genesis::CI;
  my $ci = Genesis::CI->new(
    type   => 'concourse',
    file   => 'ci.yml',
    top    => $top_obj,
    layout => 'default'
  );
  $ci->parse();
  my $yaml = $ci->generate();
  $ci->deploy(target => 'prod', yes => 1);

  # Via compiler pipeline (new path)
  my $result = Genesis::CI->compile(
    ci_dir   => '.genesis/ci',
    provider => 'concourse',
    top      => $top_obj,
  );

=head1 COMPILER PIPELINE METHODS

=head2 generate_from_ast($ast)

Generate Concourse pipeline YAML from a Genesis::CI::Compiler::AST.
For legacy-sourced ASTs, bridges to Legacy::generate_pipeline_concourse_yaml().
For modern ASTs, generates Concourse YAML natively.

=head2 output_files()

Returns hash describing generated files.

=head1 TRAIT INTERFACE METHODS

=head2 init(%opts)

Initialize Concourse provider instance.

=head2 parse()

Parse and validate ci.yml configuration for Concourse.

=head2 generate()

Generate Concourse pipeline YAML.

=head2 deploy(%opts)

Deploy pipeline to Concourse via fly CLI.

Options: target, dry-run, yes, paused

=head2 platform_name()

Returns "Concourse".

=head2 file_extension()

Returns ".yml".

=head1 CONCOURSE-SPECIFIC METHODS

=head2 graph_md()

Generate pipeline.md content containing a Mermaid flowchart LR diagram.

=head2 describe()

Print human-readable pipeline description to stdout.

=head1 ACCESSORS

=head2 config()

Returns parsed pipeline configuration.

=head2 top()

Returns Genesis::Top object.

=head2 layout()

Returns layout name.

=head1 SEE ALSO

Genesis::CI, Genesis::CI::GithubActions, Genesis::CI::Legacy

=cut

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
