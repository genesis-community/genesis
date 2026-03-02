package Genesis::CI::Compiler::AST;
use strict;
use warnings;

use Genesis;

### Constructor {{{

# new - create a new AST instance {{{
sub new {
	my ($class, %data) = @_;

	return bless({
		metadata        => $data{metadata}        || {},
		branches        => $data{branches}        || {},
		integrations    => $data{integrations}    || {},
		targets         => $data{targets}         || {},
		scripts         => $data{scripts}         || {},
		workflows       => $data{workflows}       || {},
		configuration   => $data{configuration}   || {},
		provider_config => $data{provider_config} || {},
	}, $class);
}

# }}}
# }}}
### Accessors {{{

sub metadata        { $_[0]->{metadata} }
sub branches        { $_[0]->{branches} }
sub integrations    { $_[0]->{integrations} }
sub targets         { $_[0]->{targets} }
sub scripts         { $_[0]->{scripts} }
sub workflows       { $_[0]->{workflows} }
sub configuration   { $_[0]->{configuration} }
sub provider_config { $_[0]->{provider_config} }

# }}}
### Query Methods {{{

# target_names - return sorted list of all target names {{{
sub target_names {
	my ($self) = @_;
	return sort keys %{$self->{targets}};
}

# }}}
# workflow_names - return sorted list of all workflow names {{{
sub workflow_names {
	my ($self) = @_;
	return sort keys %{$self->{workflows}};
}

# }}}
# targets_matching - return targets whose names match a glob pattern {{{
sub targets_matching {
	my ($self, $pattern) = @_;

	my $regex = $pattern;
	$regex =~ s/\*/.*/g;
	$regex =~ s/\?/./g;
	$regex = qr/^$regex$/;

	my @matching;
	for my $name (sort keys %{$self->{targets}}) {
		if ($name =~ $regex) {
			push @matching, $self->{targets}{$name};
		}
	}
	return @matching;
}

# }}}
# workflow_stage_order - topological sort of workflow stages {{{
sub workflow_stage_order {
	my ($self, $workflow_name) = @_;

	my $workflow = $self->{workflows}{$workflow_name}
		or bail("Unknown workflow '%s'", $workflow_name);

	my $graph = $workflow->{graph}
		or return (); # no graph means no stages

	return $self->_topological_sort($graph);
}

# }}}
# script_for_stage - get script metadata for a workflow stage {{{
sub script_for_stage {
	my ($self, $workflow_name, $stage_name) = @_;

	my $workflow = $self->{workflows}{$workflow_name}
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

	my $target = $self->{targets}{$target_name}
		or bail("Unknown target '%s'", $target_name);

	my $vault = $self->{integrations}{vault} || {};
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
	my $git = $self->{integrations}{source_control} || {};
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

Genesis::CI::Compiler::AST - Platform-agnostic pipeline representation

=head1 DESCRIPTION

Genesis::CI::Compiler::AST is the intermediate representation produced by
the Genesis CI compiler. It contains all the information needed for a
provider plugin to generate platform-specific CI/CD configuration.

The AST is a read-only data structure. Only the ASTBuilder creates it;
provider plugins only read from it via the accessor and query methods.

=head1 SYNOPSIS

  my $ast = Genesis::CI::Compiler::AST->new(
    metadata     => { name => 'my-pipeline', version => '2.0' },
    branches     => { live => 'main', target_prefix => 'target/' },
    integrations => { vault => {...}, source_control => {...} },
    targets      => { 'us-sandbox' => {...} },
    scripts      => { 'deploy/genesis-deploy' => {...} },
    workflows    => { sandbox => {...} },
    configuration => { timeouts => {...} },
  );

  # Query the AST
  my @targets = $ast->target_names();
  my @stages  = $ast->workflow_stage_order('sandbox');
  my $script  = $ast->script_for_stage('sandbox', 'deploy');
  my %env     = $ast->env_vars_for_target('us-sandbox');

=head1 SEE ALSO

Genesis::CI::Compiler::ASTBuilder, Genesis::CI::Compiler::PipelineProvider

=cut

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
