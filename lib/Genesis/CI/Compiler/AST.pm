package Genesis::CI::Compiler::AST;
use strict;
use warnings;

use Genesis;

### Constructor {{{

# new - create a new AST instance {{{
sub new {
	my ($class, %data) = @_;

	return bless({
		# === Generic pipeline (the public interface for providers) ===
		# These are populated by PipelineDescriptor after the source
		# representation is built. Providers ONLY read these fields.
		pipeline => $data{pipeline} || {},  # {resource_types, resources, jobs, groups}
		metadata => $data{metadata} || {},  # {name, version, source, deployment_type, ...}
		scripts  => $data{scripts}  || {},  # script_id => {path, content, ...}

		# === Source representation (Genesis-specific, internal) ===
		# Used by PipelineDescriptor to build the generic pipeline.
		# Providers should NOT read these directly.
		_source => {
			branches        => $data{branches}        || {},
			integrations    => $data{integrations}    || {},
			targets         => $data{targets}         || {},
			workflows       => $data{workflows}       || {},
			configuration   => $data{configuration}   || {},
			provider_config => $data{provider_config} || {},
			triggers        => $data{triggers}        || {},
			resources       => $data{resources}       || {},
		},
	}, $class);
}

# }}}
# }}}
### Pipeline Accessors (for providers) {{{

# pipeline - the fully-resolved generic pipeline {{{
sub pipeline { $_[0]->{pipeline} }

# }}}
# metadata - pipeline metadata {{{
sub metadata { $_[0]->{metadata} }

# }}}
# scripts - script metadata with content {{{
sub scripts { $_[0]->{scripts} }

# }}}
# resource_types - shortcut to pipeline->{resource_types} {{{
sub resource_types { $_[0]->{pipeline}{resource_types} || [] }

# }}}
# pipeline_resources - shortcut to pipeline->{resources} {{{
sub pipeline_resources { $_[0]->{pipeline}{resources} || [] }

# }}}
# jobs - shortcut to pipeline->{jobs} {{{
sub jobs { $_[0]->{pipeline}{jobs} || [] }

# }}}
# groups - shortcut to pipeline->{groups} {{{
sub groups { $_[0]->{pipeline}{groups} || [] }

# }}}
# mermaid - pre-built Mermaid flowchart LR source {{{
sub mermaid { $_[0]->{pipeline}{mermaid} }

# }}}
# pipeline_md - pre-built Markdown document with fenced Mermaid block {{{
sub pipeline_md { $_[0]->{pipeline}{pipeline_md} }

# }}}
# description - pre-built human-readable description {{{
sub description { $_[0]->{pipeline}{description} }

# }}}
# set_pipeline - store the resolved generic pipeline {{{
sub set_pipeline {
	my ($self, $pipeline) = @_;
	$self->{pipeline} = $pipeline;
}

# }}}
# }}}
### Source Accessors (for PipelineDescriptor / internal use) {{{

sub branches        { $_[0]->{_source}{branches} }
sub integrations    { $_[0]->{_source}{integrations} }
sub targets         { $_[0]->{_source}{targets} }
sub workflows       { $_[0]->{_source}{workflows} }
sub configuration   { $_[0]->{_source}{configuration} }
sub provider_config { $_[0]->{_source}{provider_config} }
sub triggers        { $_[0]->{_source}{triggers} }
sub resources       { $_[0]->{_source}{resources} }

# }}}
### Source Query Methods (for PipelineDescriptor / internal use) {{{

# target_names - return sorted list of all target names {{{
sub target_names {
	my ($self) = @_;
	return sort keys %{$self->{_source}{targets}};
}

# }}}
# workflow_names - return sorted list of all workflow names {{{
sub workflow_names {
	my ($self) = @_;
	return sort keys %{$self->{_source}{workflows}};
}

# }}}
# resource_names - return sorted list of all generic resource names {{{
sub resource_names {
	my ($self) = @_;
	return sort keys %{$self->{_source}{resources}};
}

# }}}
# trigger_names - return sorted list of all trigger names {{{
sub trigger_names {
	my ($self) = @_;
	return sort keys %{$self->{_source}{triggers}};
}

# }}}
# resources_matching - return resources whose names match a glob pattern {{{
sub resources_matching {
	my ($self, $pattern) = @_;

	my $regex = join('', map {
		$_ eq '*' ? '.*' : $_ eq '?' ? '.' : quotemeta($_)
	} split(/([*?])/, $pattern, -1));
	$regex = qr/^$regex$/;

	my @matching;
	for my $name (sort keys %{$self->{_source}{resources}}) {
		push @matching, $self->{_source}{resources}{$name} if $name =~ $regex;
	}
	return @matching;
}

# }}}
# targets_matching - return targets whose names match a glob pattern {{{
sub targets_matching {
	my ($self, $pattern) = @_;

	my $regex = join('', map {
		$_ eq '*' ? '.*' : $_ eq '?' ? '.' : quotemeta($_)
	} split(/([*?])/, $pattern, -1));
	$regex = qr/^$regex$/;

	my @matching;
	for my $name (sort keys %{$self->{_source}{targets}}) {
		if ($name =~ $regex) {
			push @matching, $self->{_source}{targets}{$name};
		}
	}
	return @matching;
}

# }}}
# workflow_stage_order - topological sort of workflow stages {{{
sub workflow_stage_order {
	my ($self, $workflow_name) = @_;

	my $workflow = $self->{_source}{workflows}{$workflow_name}
		or bail("Unknown workflow '%s'", $workflow_name);

	my $graph = $workflow->{graph}
		or return (); # no graph means no stages

	return $self->_topological_sort($graph);
}

# }}}
# script_for_stage - get script metadata for a workflow stage {{{
sub script_for_stage {
	my ($self, $workflow_name, $stage_name) = @_;

	my $workflow = $self->{_source}{workflows}{$workflow_name}
		or return undef;

	my $graph = $workflow->{graph}
		or return undef;

	my $stage = $graph->{nodes}{$stage_name}
		or return undef;

	my $script_id = $stage->{script_id}
		or return undef; # non-script stages (e.g. manual-approval)

	return $self->{scripts}{$script_id};
}

# }}}
# env_vars_for_target - build environment variable map for a target {{{
sub env_vars_for_target {
	my ($self, $target_name) = @_;

	my $target = $self->{_source}{targets}{$target_name}
		or bail("Unknown target '%s'", $target_name);

	my $vault = $self->{_source}{integrations}{vault} || {};
	my $conn  = $target->{connection} || {};
	my $auth  = $conn->{auth} || {};

	my %env;
	$env{CURRENT_ENV} = $target_name;

	# Vault
	$env{VAULT_ADDR} = $vault->{url} if $vault->{url};
	if ($vault->{auth}) {
		$env{VAULT_ROLE_ID}   = _resolve_ref($vault->{auth}{role_id});
		$env{VAULT_SECRET_ID} = _resolve_ref($vault->{auth}{secret_id});
	}
	$env{VAULT_SKIP_VERIFY} = 'true'
		if $vault->{options} && !$vault->{options}{tls_verify};
	$env{VAULT_NAMESPACE} = $vault->{namespace}
		if $vault->{namespace};

	# BOSH
	if ($conn->{url}) {
		$env{BOSH_ENVIRONMENT}   = $conn->{url};
		$env{BOSH_CLIENT}        = $auth->{client_id} if $auth->{client_id};
		$env{BOSH_CLIENT_SECRET} = _resolve_ref($auth->{client_secret});
		$env{BOSH_CA_CERT}       = _resolve_ref($conn->{ca_cert});
	}

	# Git
	my $git = $self->{_source}{integrations}{source_control} || {};
	if ($git->{auth}) {
		if ($git->{auth}{type} eq 'ssh-key') {
			$env{GIT_PRIVATE_KEY} = _resolve_ref($git->{auth}{private_key});
		} elsif ($git->{auth}{type} eq 'username-password') {
			$env{GIT_USERNAME} = _resolve_ref($git->{auth}{username});
			$env{GIT_PASSWORD} = _resolve_ref($git->{auth}{password});
		}
	}
	if ($git->{commit_author}) {
		$env{GIT_AUTHOR_NAME}  = $git->{commit_author}{name}  || 'Concourse Bot';
		$env{GIT_AUTHOR_EMAIL} = $git->{commit_author}{email} || 'concourse@pipeline';
	}

	return %env;
}

# }}}
# }}}
### Internal Methods {{{

# _topological_sort - standard topological sort on a workflow graph {{{
sub _topological_sort {
	my ($self, $graph) = @_;

	my @sorted;
	my %visited;
	my %temp_mark;

	my $visit;
	$visit = sub {
		my ($node) = @_;
		return if $visited{$node};
		bail("Cycle detected in workflow graph at node '%s'", $node)
			if $temp_mark{$node};

		$temp_mark{$node} = 1;

		for my $edge (@{$graph->{edges} || []}) {
			if ($edge->{from} eq $node) {
				$visit->($edge->{to});
			}
		}

		delete $temp_mark{$node};
		$visited{$node} = 1;
		unshift @sorted, $node;
	};

	for my $node (sort keys %{$graph->{nodes} || {}}) {
		$visit->($node) unless $visited{$node};
	}

	return @sorted;
}

# }}}
# _resolve_ref - unwrap a secret_ref wrapper or return scalar {{{
sub _resolve_ref {
	my ($value) = @_;
	return undef unless defined $value;
	if (ref($value) eq 'HASH' && exists $value->{secret_ref}) {
		return "(($value->{secret_ref}))";
	}
	return $value;
}

# }}}
# }}}

1;

=head1 NAME

Genesis::CI::Compiler::AST - Generic pipeline representation

=head1 DESCRIPTION

Genesis::CI::Compiler::AST is the fully-resolved pipeline representation
produced by the Genesis CI compiler. It contains ALL data needed by a
provider to generate platform-specific CI/CD configuration, including
resource types, resources, jobs, groups, and embedded script content.

The AST has two layers:

=over 4

=item B<Generic pipeline> (public, for providers)

The C<pipeline> field holds the fully-resolved generic pipeline with
resource_types, resources, jobs, and groups. Providers ONLY read this.

=item B<Source representation> (internal, for PipelineDescriptor)

The C<_source> fields hold Genesis-specific concepts (targets, integrations,
workflows, configuration). These are used by PipelineDescriptor to build
the generic pipeline and should not be accessed by providers directly.

=back

=head1 SYNOPSIS

  # The compiler builds the AST in two phases:
  # Phase 1: ASTBuilder creates source representation
  my $ast = Genesis::CI::Compiler::ASTBuilder->new(top => $top)->build($parsed, $scripts);

  # Phase 2: PipelineDescriptor resolves into generic pipeline
  my $descriptor = Genesis::CI::Compiler::PipelineDescriptor->new(ast => $ast);
  $ast->set_pipeline($descriptor->describe());

  # Providers serialize the generic pipeline
  my $yaml = $provider->serialize($ast);

  # Pipeline accessors (for providers)
  my $resource_types = $ast->resource_types;
  my $resources      = $ast->pipeline_resources;
  my $jobs           = $ast->jobs;
  my $groups         = $ast->groups;
  my $dot            = $ast->mermaid;
  my $text           = $ast->description;

=head1 SEE ALSO

Genesis::CI::Compiler::ASTBuilder, Genesis::CI::Compiler::PipelineDescriptor,
Genesis::CI::Compiler::PipelineProvider

=cut

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
