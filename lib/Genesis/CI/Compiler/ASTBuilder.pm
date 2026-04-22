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
		top     => $opts{top},
		env_dir => $opts{env_dir},
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

		my @environments = @{$layout->{environments} || []};
		my %will_trigger = %{$layout->{will_trigger} || {}};

		# Build aliases and genesis_envs maps
		my %aliases      = map { $_ => ($boshes->{$_}{alias}       || $_) } @environments;
		my %genesis_envs = map { $_ => ($boshes->{$_}{genesis_env} || $_) } @environments;

		# Auto-trigger environments — already expanded by Genesis::CI::Layout
		my %auto_envs = map { $_ => 1 } @{$layout->{_auto_envs} || []};

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

		# Enrich nodes with require_pr/manual from env files when available
		my $env_dir = $self->{env_dir}
			|| ($self->{top} ? $self->{top}->path() : undef);
		if ($env_dir) {
			my ($ef_nodes) = $self->_build_from_env_files($env_dir);
			for my $env (keys %nodes) {
				my $ef = $ef_nodes->{$env} or next;
				$nodes{$env}{require_pr} = $ef->{require_pr};
				$nodes{$env}{manual}     = $ef->{manual};
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
				environments => \@environments,
				auto_envs    => [keys %auto_envs],
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

	# Build workflows: from pipeline.yml definitions when present; otherwise
	# derive topology from genesis.pipeline.* keys in env files (Phase A).
	my $workflow_defs = $pipeline->{workflows} || {};
	my $workflows;
	if (%$workflow_defs) {
		$workflows = $self->_build_modern_workflows($workflow_defs, $scripts);
	} else {
		my $env_dir = $parsed->{env_dir}
			|| $self->{env_dir}
			|| ($self->{top} ? $self->{top}->path : '.');
		my ($nodes, $edges) = $self->_build_from_env_files($env_dir);
		$workflows = {
			default => {
				name     => 'default',
				type     => 'deployment',
				triggers => [],
				graph    => { nodes => $nodes, edges => $edges },
			},
		};
	}

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
### Env-File Topology Builder {{{

# _build_from_env_files - build workflow graph nodes+edges from genesis.pipeline.* {{{
#
# Scans *.yml files in $dir.  For each file that contains a
#
#   genesis:
#     pipeline:
#       prior_env:  <upstream-env>
#       require_pr: true|false
#       manual:     true|false
#
# block, a graph node is created (keyed by the file stem) and, when
# prior_env names another env that is also present, a directed edge
# is added: prior_env -> this_env.
#
# Returns: (\%nodes, \@edges)
sub _build_from_env_files {
	my ($self, $dir) = @_;

	opendir(my $dh, $dir) or return ({}, []);
	my @files = sort grep { /\.ya?ml$/i && -f "$dir/$_" } readdir($dh);
	closedir $dh;

	# Pass 1: collect genesis.pipeline data and note which files exist
	my (%pipeline_data, %file_exists);
	for my $file (@files) {
		(my $env = $file) =~ s/\.ya?ml$//i;
		$file_exists{$env} = 1;
		my $data = _read_genesis_pipeline_keys("$dir/$file");
		$pipeline_data{$env} = $data if %$data;
	}

	# Identify envs referenced as prior_env — these are pipeline entrypoints
	# that may have no genesis.pipeline block themselves (Phase C design).
	my %referenced_upstream;
	for my $env (keys %pipeline_data) {
		my $upstream = $pipeline_data{$env}{prior_env} or next;
		$referenced_upstream{$upstream} = 1;
	}

	# Pass 2: build nodes for envs that either have pipeline data OR are
	# referenced as upstream by another env AND have a file in the directory.
	my %nodes;
	my %prior_env_map;
	my %envs_to_include = (
		%pipeline_data,
		map { $_ => {} } grep { $file_exists{$_} } keys %referenced_upstream,
	);

	for my $env (sort keys %envs_to_include) {
		my $data = $pipeline_data{$env} || {};
		$nodes{$env} = {
			stage_name  => $env,
			target_name => $env,
			alias       => $env,
			genesis_env => $env,
			auto        => 0,
			type        => 'deployment',
			require_pr  => _truthy($data->{require_pr}),
			manual      => _truthy($data->{manual}),
		};
		$prior_env_map{$env} = $data->{prior_env} if $data->{prior_env};
	}

	my @edges;
	for my $env (sort keys %prior_env_map) {
		my $upstream = $prior_env_map{$env};
		push @edges, { from => $upstream, to => $env }
			if exists $nodes{$upstream};
	}

	return (\%nodes, \@edges);
}

# }}}
# }}}
### Internal Helpers {{{

# _read_genesis_pipeline_keys - extract genesis.pipeline.* from a YAML file {{{
#
# Reads a YAML file line-by-line looking for the nested structure:
#   genesis:
#     pipeline:
#       key: value
#
# Returns a hashref of the pipeline sub-keys (may be empty).
# No external YAML parser needed — only flat scalar values are extracted.
sub _read_genesis_pipeline_keys {
	my ($file) = @_;

	open(my $fh, '<', $file) or return {};
	my @lines = <$fh>;
	close $fh;

	my %result;
	my ($in_genesis, $in_pipeline) = (0, 0);

	for my $line (@lines) {
		chomp $line;
		next if $line =~ /^\s*#/ || $line =~ /^\s*---/;

		# Top-level key resets context
		if ($line =~ /^([a-zA-Z_][a-zA-Z0-9_]*):\s*(.*)$/) {
			my $key = $1;
			$in_genesis  = $key eq 'genesis' ? 1 : 0;
			$in_pipeline = 0;
			next;
		}

		# 'pipeline:' under genesis (2-space indent)
		if ($in_genesis && $line =~ /^  pipeline:\s*$/) {
			$in_pipeline = 1;
			next;
		}

		# Another 2-space key under genesis resets pipeline context
		if ($in_genesis && $line =~ /^  [a-zA-Z]/) {
			$in_pipeline = 0;
			next;
		}

		# 4-space keys under genesis.pipeline
		if ($in_pipeline && $line =~ /^    ([a-zA-Z_][a-zA-Z0-9_]*):\s*(.*)$/) {
			my ($k, $v) = ($1, $2);
			$v =~ s/\s*#.*$//;   # strip inline comment
			$v =~ s/^\s+|\s+$//g; # trim
			$result{$k} = $v;
		}
	}

	return \%result;
}

# }}}
# _truthy - convert YAML-ish string values to 0/1 {{{
sub _truthy {
	my ($v) = @_;
	return 0 unless defined $v && $v ne '';
	return 0 if $v =~ /^(false|no|0)$/i;
	return 1;
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
