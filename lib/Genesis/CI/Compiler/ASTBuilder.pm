package Genesis::CI::Compiler::ASTBuilder;
use strict;
use warnings;

use Genesis;
use Genesis::CI::Compiler::AST;
use JSON::PP;

### Constructor {{{

# new - create a new AST builder {{{
sub new {
	my ($class, %opts) = @_;

	return bless({
		top => $opts{top},
	}, $class);
}

# }}}
# }}}
### Public Methods {{{

# build - build AST from parsed config and discovered scripts {{{
sub build {
	my ($self, $parsed, $scripts) = @_;

	my %ast_data;

	if ($parsed->{_source_format} eq 'legacy') {
		%ast_data = $self->_build_from_legacy($parsed, $scripts);
	} else {
		%ast_data = $self->_build_from_multi_file($parsed, $scripts);
	}

	return Genesis::CI::Compiler::AST->new(%ast_data);
}

# }}}
# }}}
### Legacy Format Builder {{{

# _build_from_legacy - build AST from legacy ci.yml parsed config {{{
sub _build_from_legacy {
	my ($self, $parsed, $scripts) = @_;

	my $p = $parsed->{_legacy_raw}{pipeline};

	# Metadata
	my $metadata = {
		name            => $p->{name},
		version         => '1.0',
		source          => 'legacy',
		source_file     => $parsed->{_source_path},
		deployment_type => ($self->{top} ? $self->{top}->type : undef),
	};

	# Branches
	my $branches = {
		live          => $p->{git}{branch} || 'master',
		target_prefix => 'target/',
	};

	# Integrations (already normalized by parser)
	my $integrations = $parsed->{integrations};

	# Targets (already normalized by parser)
	my $targets_data = $parsed->{targets}{targets} || $parsed->{targets};

	# Build workflows from parsed layout data
	my $workflows = $self->_build_legacy_workflows($parsed, $p);

	# Configuration
	my $configuration = {
		public      => _yaml_bool($p->{public}, 0),
		tagged      => _yaml_bool($p->{tagged}, 0),
		unredacted  => _yaml_bool($p->{unredacted}, 0),
		ocfp        => _yaml_bool($p->{ocfp}, 0),
		debug       => $p->{debug} || 0,
		task        => {
			image      => ($p->{task}{image} || 'genesiscommunity/concourse'),
			version    => ($p->{task}{version} || 'latest'),
			privileged => ($p->{task}{privileged} || []),
		},
		registry     => $p->{registry},
		groups       => $p->{groups},
		errands      => $p->{errands},
		auto_update  => $p->{'auto-update'},
		notifications => {
			style => $p->{notifications} || 'inline',
		},
		'require-passed-caches' => $p->{'require-passed-caches'},
	};

	# Provider config - include legacy raw pipeline data for Concourse bridge
	my $provider_config = $parsed->{provider_config} || {};
	if ($parsed->{_legacy_raw}) {
		$provider_config->{concourse} = {
			_legacy_pipeline_raw => $parsed->{_legacy_raw}{pipeline},
		};
	}

	return (
		metadata        => $metadata,
		branches        => $branches,
		integrations    => $integrations,
		targets         => $targets_data,
		scripts         => $scripts || {},
		workflows       => $workflows,
		configuration   => $configuration,
		provider_config => $provider_config,
	);
}

# }}}
# _build_legacy_workflows - build workflow definitions from legacy layouts {{{
sub _build_legacy_workflows {
	my ($self, $parsed, $p) = @_;

	my $wf_data = $parsed->{pipeline}{workflows} || {};
	my $boshes  = $p->{boshes} || {};

	my %workflows;
	for my $layout_name (keys %$wf_data) {
		my $layout = $wf_data->{$layout_name};
		next unless ref($layout) eq 'HASH';

		my @environments  = @{$layout->{environments} || []};
		my @auto_patterns = @{$layout->{auto_patterns} || []};
		my %will_trigger  = %{$layout->{will_trigger} || {}};

		# Build aliases and genesis_envs maps
		my %aliases      = map { $_ => ($boshes->{$_}{alias}       || $_) } @environments;
		my %genesis_envs = map { $_ => ($boshes->{$_}{genesis_env} || $_) } @environments;

		# Determine auto-trigger environments
		my %auto_envs;
		for my $pattern (@auto_patterns) {
			my $regex = $pattern;
			$regex =~ s/\*/.*/g;
			$regex = qr/^$regex$/;

			for my $env (@environments) {
				$auto_envs{$env} = 1 if $env =~ $regex;
			}
		}

		# Build trigger map (inverse of will_trigger)
		my %triggers;
		for my $a (keys %will_trigger) {
			for my $b (@{$will_trigger{$a}}) {
				$triggers{$b} = $a;
			}
		}

		# Build the workflow graph
		my %nodes;
		my @edges;

		for my $env (@environments) {
			my $alias = $aliases{$env};
			$nodes{$env} = {
				stage_name  => $env,
				target_name => $env,
				alias       => $alias,
				genesis_env => $genesis_envs{$env},
				auto        => $auto_envs{$env} ? 1 : 0,
				type        => 'deployment',
			};
		}

		for my $from (keys %will_trigger) {
			for my $to (@{$will_trigger{$from}}) {
				push @edges, { from => $from, to => $to };
			}
		}

		$workflows{$layout_name} = {
			name        => $layout_name,
			type        => 'legacy-deployment',
			triggers    => [],
			graph       => {
				nodes => \%nodes,
				edges => \@edges,
			},
			# Preserve legacy-specific data for the Concourse provider
			_legacy => {
				environments  => \@environments,
				auto_patterns => \@auto_patterns,
				auto_envs     => [keys %auto_envs],
				aliases       => \%aliases,
				genesis_envs  => \%genesis_envs,
				will_trigger  => \%will_trigger,
				triggers      => \%triggers,
			},
		};
	}

	return \%workflows;
}

# }}}
# }}}
### Multi-File Format Builder {{{

# _build_from_multi_file - build AST from new multi-file parsed config {{{
sub _build_from_multi_file {
	my ($self, $parsed, $scripts) = @_;

	my $pipeline = $parsed->{pipeline} || {};

	# Metadata
	my $metadata = $pipeline->{metadata} || {};

	# Branches
	my $branches = $pipeline->{branches} || {
		live          => 'main',
		target_prefix => 'target/',
	};

	# Integrations
	my $integrations = $parsed->{integrations} || {};

	# Targets (legacy accessor)
	my $targets_data = $parsed->{targets}{targets} || $parsed->{targets} || {};

	# Build workflows
	my $workflows = $self->_build_modern_workflows($pipeline->{workflows} || {}, $scripts);

	# Configuration
	my $configuration = $pipeline->{configuration} || {};

	# Provider config
	my $provider_config = $parsed->{provider_config} || {};

	# Generic pipeline extensions (from pipeline description)
	my $triggers  = $pipeline->{triggers}  || {};
	my $resources = $pipeline->{resources} || {};

	return (
		metadata        => $metadata,
		branches        => $branches,
		integrations    => $integrations,
		targets         => $targets_data,
		scripts         => $scripts || {},
		workflows       => $workflows,
		configuration   => $configuration,
		provider_config => $provider_config,
		triggers        => $triggers,
		resources       => $resources,
	);
}

# }}}
# _build_modern_workflows - build workflows with DAG from modern config {{{
sub _build_modern_workflows {
	my ($self, $workflow_defs, $scripts) = @_;

	my %workflows;
	for my $name (keys %$workflow_defs) {
		my $wf_def = $workflow_defs->{$name};

		# If this is a parsed legacy layout, just pass it through
		if (ref($wf_def) eq 'HASH' && $wf_def->{environments}) {
			$workflows{$name} = $wf_def;
			next;
		}

		# Build workflow with graph
		my $workflow = {
			name        => $name,
			description => $wf_def->{description} || '',
			type        => $wf_def->{type} || 'deployment',
			triggers    => $wf_def->{triggers} || [],
		};

		# Build graph from stages
		if ($wf_def->{stages} && ref($wf_def->{stages}) eq 'ARRAY') {
			$workflow->{graph} = $self->_build_workflow_graph($wf_def->{stages}, $scripts);
		} elsif ($wf_def->{graph}) {
			$workflow->{graph} = $wf_def->{graph};
		}

		# Analysis section (for distribution workflows)
		$workflow->{analysis} = $wf_def->{analysis} if $wf_def->{analysis};

		# Merge strategy
		$workflow->{merge_strategy} = $wf_def->{merge_strategy} if $wf_def->{merge_strategy};

		$workflows{$name} = $workflow;
	}

	return \%workflows;
}

# }}}
# _build_workflow_graph - construct DAG from a list of stages {{{
sub _build_workflow_graph {
	my ($self, $stages, $scripts) = @_;

	my %nodes;
	my @edges;

	# Build nodes from stages
	for my $stage (@$stages) {
		my $name = $stage->{name};
		my $node = {
			stage_name => $name,
		};

		if ($stage->{type} && $stage->{type} eq 'manual-approval') {
			$node->{type}      = 'manual-approval';
			$node->{approvers} = $stage->{approvers} || [];
			$node->{timeout}   = $stage->{timeout};
		} else {
			$node->{script_id}  = $stage->{script};
			$node->{inputs}     = $stage->{inputs}  || [];
			$node->{outputs}    = $stage->{outputs} || [];
			$node->{on_failure} = $stage->{on_failure};
		}

		$nodes{$name} = $node;
	}

	# Build edges: sequential by default (stage N -> stage N+1)
	for my $i (0 .. $#$stages - 1) {
		push @edges, {
			from => $stages->[$i]{name},
			to   => $stages->[$i + 1]{name},
		};
	}

	return {
		nodes => \%nodes,
		edges => \@edges,
	};
}

# }}}
# }}}
### Internal Helpers {{{

# _yaml_bool - handle yaml boolean values with defaults {{{
sub _yaml_bool {
	my ($bool, $default) = @_;
	return ($default || 0) unless defined $bool;
	return $bool ? 1 : 0;
}

# }}}
# _resolve_secret_refs - detect ((...)) syntax and wrap {{{
sub _resolve_secret_refs {
	my ($self, $value) = @_;
	return $value unless defined $value;

	if (!ref($value) && $value =~ /^\(\((.+)\)\)$/) {
		return { secret_ref => $1 };
	}

	if (ref($value) eq 'HASH') {
		my %result;
		for my $key (keys %$value) {
			$result{$key} = $self->_resolve_secret_refs($value->{$key});
		}
		return \%result;
	}

	if (ref($value) eq 'ARRAY') {
		return [map { $self->_resolve_secret_refs($_) } @$value];
	}

	return $value;
}

# }}}
# }}}

1;

=head1 NAME

Genesis::CI::Compiler::ASTBuilder - Builds AST from parsed configuration

=head1 DESCRIPTION

Genesis::CI::Compiler::ASTBuilder constructs a Genesis::CI::Compiler::AST
from parsed configuration and discovered script metadata. It handles both
legacy (single ci.yml) and modern (multi-file .genesis/ci/) formats,
normalizing them into the common AST representation.

=head1 SYNOPSIS

  my $builder = Genesis::CI::Compiler::ASTBuilder->new(top => $top_obj);
  my $ast = $builder->build($parsed_config, $scripts);

  # The resulting AST can be passed to any provider
  my $yaml = $provider->generate_from_ast($ast);

=head1 SEE ALSO

Genesis::CI::Compiler::AST, Genesis::CI::Compiler::Parser,
Genesis::CI::Compiler::ScriptDiscovery

=cut

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
