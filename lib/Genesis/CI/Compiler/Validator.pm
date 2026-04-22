package Genesis::CI::Compiler::Validator;
use strict;
use warnings;

use Genesis;
use JSON::PP;

### Constructor {{{

# new - create a new validator instance {{{
sub new {
	my ($class, %opts) = @_;

	return bless({
		errors   => [],
		warnings => [],
		top      => $opts{top},
	}, $class);
}

# }}}
# }}}
### Public Methods {{{

# validate - validate parsed configuration {{{
sub validate {
	my ($self, $parsed) = @_;

	$self->{errors}   = [];
	$self->{warnings} = [];

	if ($parsed->{_source_format} eq 'legacy') {
		$self->_validate_legacy($parsed);
	} else {
		$self->_validate_multi_file($parsed);
	}

	return $self;
}

# }}}
# has_errors - check if validation found errors {{{
sub has_errors {
	my ($self) = @_;
	return scalar @{$self->{errors}} > 0;
}

# }}}
# errors - get list of error messages {{{
sub errors {
	my ($self) = @_;
	return $self->{errors};
}

# }}}
# has_warnings - check if validation found warnings {{{
sub has_warnings {
	my ($self) = @_;
	return scalar @{$self->{warnings}} > 0;
}

# }}}
# warnings - get list of warning messages {{{
sub warnings {
	my ($self) = @_;
	return $self->{warnings};
}

# }}}
# }}}
### Legacy Format Validation {{{

# _validate_legacy - validate legacy ci.yml-derived parsed config {{{
sub _validate_legacy {
	my ($self, $parsed) = @_;

	my $raw = $parsed->{_legacy_raw};
	unless ($raw && ref($raw->{pipeline}) eq 'HASH') {
		$self->_error("Missing or invalid top-level 'pipeline:' key");
		return;
	}

	my $p = $raw->{pipeline};

	# Validate required top-level keys
	$self->_validate_required_keys($p);

	# Validate vault
	$self->_validate_vault($p->{vault}) if $p->{vault};

	# Validate git
	$self->_validate_git($p->{git}) if $p->{git};

	# Validate boshes
	$self->_validate_boshes($p->{boshes}) if $p->{boshes};

	# Validate notifications
	$self->_validate_notifications($p);

	# Validate layouts
	$self->_validate_layouts($p);

	# Validate optional sections
	$self->_validate_locker($p->{locker}) if $p->{locker};
	$self->_validate_task($p->{task}) if exists $p->{task};
	$self->_validate_registry($p->{registry}) if exists $p->{registry};
	$self->_validate_groups($p->{groups}, $p->{boshes}) if exists $p->{groups};
	$self->_validate_auto_update($p->{'auto-update'}) if exists $p->{'auto-update'};
	$self->_validate_notifications_style($p->{notifications})
		if exists $p->{notifications};

	# Validate allowed keys
	for (keys %$p) {
		$self->_error("Unrecognized `pipeline.$_' key found")
			unless /^(name|public|tagged|errands|ocfp|vault|git|slack|email|boshes|task|layout|layouts|groups|debug|locker|unredacted|notifications|auto-update|registry|require-passed-caches)$/;
	}
}

# }}}
# _validate_required_keys - check required pipeline keys {{{
sub _validate_required_keys {
	my ($self, $p) = @_;
	for (qw(name vault git boshes)) {
		$self->_error("`pipeline.$_' is required") unless $p->{$_};
	}
}

# }}}
# _validate_vault - validate vault configuration {{{
sub _validate_vault {
	my ($self, $vault) = @_;

	if (ref($vault) ne 'HASH') {
		$self->_error("`pipeline.vault' must be a map");
		return;
	}

	$self->_error("`pipeline.vault.url' is required") unless $vault->{url};

	for (keys %$vault) {
		$self->_error("Unrecognized `pipeline.vault.$_' key found")
			unless /^(url|role|secret|verify|no-strongbox|namespace)$/;
	}
}

# }}}
# _validate_git - validate git configuration {{{
sub _validate_git {
	my ($self, $git) = @_;

	if (ref($git) ne 'HASH') {
		$self->_error("`pipeline.git' must be a map");
		return;
	}

	# Authentication: private_key XOR username/password
	if ($git->{private_key}) {
		if ($git->{username} || $git->{password}) {
			$self->_error("'pipeline.git' cannot specify both 'private_key' and 'username/password'");
		} elsif (!$git->{uri}) {
			$self->_error("Must specify either 'uri', or 'owner' and 'repo' under 'pipeline.git'")
				unless ($git->{owner} && $git->{repo});
		}
	} elsif ($git->{username} || $git->{password}) {
		if (!$git->{uri}) {
			$self->_error("Must specify either 'uri', or 'owner' and 'repo' under 'pipeline.git'")
				unless ($git->{owner} && $git->{repo});
		}
	} else {
		$self->_error("'pipeline.git' must specify either 'private_key', or 'username' and 'password'");
	}

	# Commits subkey
	if (exists $git->{commits} && ref($git->{commits}) ne 'HASH') {
		$self->_error("'pipeline.git.commits' must be a map");
	} elsif (ref($git->{commits}) eq 'HASH') {
		for (keys %{$git->{commits}}) {
			$self->_error("Unrecognized `pipeline.git.commits.$_' key found")
				unless /^(user_name|user_email)$/;
		}
	}
}

# }}}
# _validate_boshes - validate BOSH directors {{{
sub _validate_boshes {
	my ($self, $boshes) = @_;

	if (ref($boshes) ne 'HASH') {
		$self->_error("`pipeline.boshes' must be a map");
		return;
	}

	for my $env (keys %$boshes) {
		# Try to detect create-env
		my $is_create_env = 0;
		if ($self->{top}) {
			my $E = eval { $self->{top}->load_env($env) };
			$is_create_env = ($E && $E->use_create_env);
		}

		if ($is_create_env) {
			for (keys %{$boshes->{$env}}) {
				$self->_error("Unrecognized `pipeline.boshes[$env].$_' key found")
					unless /^(alias)$/;
			}
		} else {
			for (qw(url ca_cert username password)) {
				$self->_error("`pipeline.boshes[$env].$_' is required")
					unless $boshes->{$env}{$_};
			}
			for (keys %{$boshes->{$env}}) {
				$self->_error("Unrecognized `pipeline.boshes[$env].$_' key found")
					unless /^(url|ca_cert|username|password|alias|genesis_env)$/;
			}
		}
	}
}

# }}}
# _validate_notifications - validate notification configuration {{{
sub _validate_notifications {
	my ($self, $p) = @_;

	my $has_notifications = 0;
	for (qw(slack email)) {
		$has_notifications++ if exists $p->{$_};
	}

	if ($has_notifications == 0) {
		$self->_error("No notification stanzas defined. Please define `pipeline.slack' or `pipeline.email'");
	}

	# Validate slack
	if ($p->{slack}) {
		if (ref($p->{slack}) ne 'HASH') {
			$self->_error("`pipeline.slack' must be a map");
		} else {
			for (qw(webhook channel)) {
				$self->_error("`pipeline.slack.$_' is required")
					unless $p->{slack}{$_};
			}
			for (keys %{$p->{slack}}) {
				$self->_error("Unrecognized `pipeline.slack.$_' key found")
					unless /^(webhook|channel|username|icon)$/;
			}
		}
	}

	# Validate email
	if ($p->{email}) {
		if (ref($p->{email}) ne 'HASH') {
			$self->_error("`pipeline.email' must be a map");
		} else {
			for (qw(to from smtp)) {
				$self->_error("`pipeline.email.$_' is required")
					unless $p->{email}{$_};
			}
			if (exists $p->{email}{to}) {
				if (ref($p->{email}{to}) ne 'ARRAY') {
					$self->_error("`pipeline.email.to' must be a list of addresses");
				} elsif (@{$p->{email}{to}} == 0) {
					$self->_error("`pipeline.email.to' must contain at least one address");
				}
			}
			for (keys %{$p->{email}}) {
				$self->_error("Unrecognized `pipeline.email.$_' key found")
					unless /^(to|from|smtp)$/;
			}
			if (ref($p->{email}{smtp}) eq 'HASH') {
				for (qw(host username password)) {
					$self->_error("`pipeline.email.smtp.$_' is required")
						unless $p->{email}{smtp}{$_};
				}
				for (keys %{$p->{email}{smtp}}) {
					$self->_error("Unrecognized `pipeline.email.smtp.$_' key found")
						unless /^(host|port|username|password)$/;
				}
			}
		}
	}
}

# }}}
# _validate_layouts - validate layout/layouts {{{
sub _validate_layouts {
	my ($self, $p) = @_;

	if (exists $p->{layout} && exists $p->{layouts}) {
		$self->_error("Both `pipeline.layout' and `pipeline.layouts' specified; pick one");
		return;
	}

	my $layouts = $p->{layouts};
	if (exists $p->{layout}) {
		$layouts = { default => $p->{layout} };
	}

	unless ($layouts) {
		$self->_error("Missing `pipeline.layout' or `pipeline.layouts'");
		return;
	}

	if (ref($layouts) ne 'HASH') {
		$self->_error("`pipeline.layouts' must be a map");
		return;
	}

	for my $name (keys %$layouts) {
		if (ref($layouts->{$name})) {
			$self->_error("`pipeline.layouts.$name' must be a string");
		}
	}
}

# }}}
# _validate_locker - validate locker configuration {{{
sub _validate_locker {
	my ($self, $locker) = @_;

	if (ref($locker) ne 'HASH') {
		$self->_error("`pipeline.locker' must be a map");
		return;
	}
	for (qw(url username password)) {
		$self->_error("`pipeline.locker.$_' is required")
			unless $locker->{$_};
	}
	for (keys %$locker) {
		$self->_error("Unrecognized `pipeline.locker.$_' key found")
			unless /^(url|username|password|ca_cert|skip_ssl_validation)$/;
	}
}

# }}}
# _validate_task - validate task configuration {{{
sub _validate_task {
	my ($self, $task) = @_;

	if (ref($task) ne 'HASH') {
		$self->_error("`pipeline.task' must be a map");
		return;
	}
	for (keys %$task) {
		$self->_error("Unrecognized `pipeline.task.$_' key found")
			unless /^(image|version|privileged)$/;
	}
	if (exists($task->{privileged}) && ref($task->{privileged}) ne 'ARRAY') {
		$self->_error("`pipeline.task.privileged` must be an array");
	}
}

# }}}
# _validate_registry - validate registry configuration {{{
sub _validate_registry {
	my ($self, $registry) = @_;

	if (ref($registry) ne 'HASH') {
		$self->_error("`pipeline.registry' must be a map");
		return;
	}
	for (keys %$registry) {
		$self->_error("Unrecognized `pipeline.registry.$_' key found")
			unless /^(uri|username|password)$/;
	}
}

# }}}
# _validate_groups - validate groups configuration {{{
sub _validate_groups {
	my ($self, $groups, $boshes) = @_;

	if (ref($groups) ne 'HASH') {
		$self->_error("`pipeline.groups' must be a map");
		return;
	}

	my @valid_names = keys %{$boshes || {}};
	push @valid_names, map { $boshes->{$_}{alias} } keys %{$boshes || {}};
	@valid_names = grep { defined $_ && $_ ne '' } @valid_names;

	for my $group (keys %$groups) {
		if (ref($groups->{$group}) ne 'ARRAY') {
			$self->_error("`pipeline.groups.$group' must be an array");
			next;
		}
		for my $job (@{$groups->{$group}}) {
			unless (grep { $_ eq $job } @valid_names) {
				$self->_error("`pipeline.groups.$job' is invalid, must be a bosh env name or alias");
			}
		}
	}
}

# }}}
# _validate_auto_update - validate auto-update configuration {{{
sub _validate_auto_update {
	my ($self, $au) = @_;

	if (ref($au) ne 'HASH') {
		$self->_error("`pipeline.auto-update' must be a map");
		return;
	}

	$self->_error("Missing required `pipeline.auto-update.file` key")
		unless $au->{file};

	for (keys %$au) {
		$self->_error("Unrecognized `pipeline.auto-update.$_' key found")
			unless /^(file|kit|org|(github_|kit_|)auth_token|api_url|label|period)$/;
	}
}

# }}}
# _validate_notifications_style - validate notifications style value {{{
sub _validate_notifications_style {
	my ($self, $val) = @_;

	if (ref($val) || $val !~ /^(inline|parallel|grouped)$/) {
		$self->_error("pipeline.notifications must be one of parallel, grouped or inline");
	}
}

# }}}
# }}}
### Multi-File Format Validation {{{

# _validate_multi_file - validate new .genesis/ci/ format {{{
sub _validate_multi_file {
	my ($self, $parsed) = @_;

	# Validate pipeline section
	$self->_validate_pipeline_section($parsed->{pipeline});

	# Validate targets section
	$self->_validate_targets_section($parsed->{targets});

	# Validate integrations section
	$self->_validate_integrations_section($parsed->{integrations});

	# Validate provider options section (ci.provider: or provider-config/concourse.yml)
	$self->_validate_provider_section($parsed->{provider})
		if $parsed->{provider};

	# Cross-reference validation
	$self->_validate_cross_references($parsed);
}

# }}}
# _validate_provider_section - validate ci.provider: options against provider schema {{{
#
# Called when a 'provider' key is present in the parsed config (inline in
# .genesis/config or as provider-config/concourse.yml).  Loads the named
# provider class and validates subkeys against its provider_options_schema().
sub _validate_provider_section {
	my ($self, $provider) = @_;

	unless (ref($provider) eq 'HASH') {
		$self->_error("'provider' section must be a hash");
		return;
	}

	my $type = $provider->{type};
	unless ($type) {
		$self->_error("'provider.type' is required");
		return;
	}

	# Load provider class to get its schema
	require Genesis::CI::Compiler::PipelineProvider;
	my %known = map { $_ => 1 } Genesis::CI::Compiler::PipelineProvider->known_providers();
	unless ($known{$type}) {
		$self->_error(sprintf(
			"'provider.type' is '%s', which is not a known CI provider.  Valid types: %s",
			$type, join(', ', sort keys %known)
		));
		return;
	}

	# Dynamically load provider to get its schema
	my $provider_info;
	eval {
		require Genesis::CI::Compiler;
		$provider_info = Genesis::CI::Compiler->_resolve_provider_class($type);
		require $provider_info->{file};  ## no critic
	};
	if ($@) {
		$self->_warn("Could not load provider '$type' for schema validation: $@");
		return;
	}

	my $schema = $provider_info->{class}->provider_options_schema();

	# Check required keys
	for my $key (sort keys %$schema) {
		my $spec = $schema->{$key};
		next unless $spec->{required};
		$self->_error(sprintf("'provider.%s' is required for provider type '%s'", $key, $type))
			unless defined $provider->{$key};
	}

	# Check unknown keys
	for my $key (sort keys %$provider) {
		unless (exists $schema->{$key}) {
			$self->_error(sprintf(
				"'provider.%s' is not a recognized option for provider type '%s'.  Valid options: %s",
				$key, $type, join(', ', sort keys %$schema)
			));
		}
	}
}

# }}}
# _validate_pipeline_section - validate pipeline.yml structure {{{
sub _validate_pipeline_section {
	my ($self, $pipeline) = @_;

	unless ($pipeline && ref($pipeline) eq 'HASH') {
		$self->_error("Invalid or empty pipeline.yml");
		return;
	}

	# Empty pipeline section means env-file-topology mode (no pipeline.yml).
	# Topology is derived from genesis.pipeline.* in env files; nothing to validate here.
	return unless %$pipeline;

	# Metadata
	if ($pipeline->{metadata}) {
		$self->_error("'metadata.name' is required")
			unless $pipeline->{metadata}{name};
	}

	# Branches
	if ($pipeline->{branches}) {
		$self->_error("'branches.live' is required")
			unless $pipeline->{branches}{live};
	}

	# Workflows
	if ($pipeline->{workflows}) {
		for my $wf_name (keys %{$pipeline->{workflows}}) {
			$self->_validate_workflow($wf_name, $pipeline->{workflows}{$wf_name});
		}
	} else {
		$self->_error("'workflows' section is required in pipeline.yml");
	}
}

# }}}
# _validate_workflow - validate a single workflow definition {{{
sub _validate_workflow {
	my ($self, $name, $workflow) = @_;

	unless (ref($workflow) eq 'HASH') {
		$self->_error("Workflow '$name' must be a map");
		return;
	}

	# Triggers
	if ($workflow->{triggers} && ref($workflow->{triggers}) eq 'ARRAY') {
		for my $trigger (@{$workflow->{triggers}}) {
			$self->_error("Workflow '$name' trigger missing 'type'")
				unless $trigger->{type};
		}
	}

	# Stages (for deployment workflows)
	if ($workflow->{stages} && ref($workflow->{stages}) eq 'ARRAY') {
		for my $stage (@{$workflow->{stages}}) {
			$self->_error("Workflow '$name' stage missing 'name'")
				unless $stage->{name};
		}
	}

	# Graph (for workflows with explicit DAG)
	if ($workflow->{graph}) {
		$self->_validate_dag($name, $workflow->{graph});
	}
}

# }}}
# _validate_dag - verify workflow graph is acyclic {{{
sub _validate_dag {
	my ($self, $workflow_name, $graph) = @_;

	return unless $graph->{nodes} && $graph->{edges};

	my %visited;
	my %temp_mark;

	my $visit;
	$visit = sub {
		my ($node) = @_;
		return 1 if $visited{$node};
		if ($temp_mark{$node}) {
			$self->_error("Cycle detected in workflow '$workflow_name' graph at node '$node'");
			return 0;
		}

		$temp_mark{$node} = 1;
		for my $edge (@{$graph->{edges}}) {
			if ($edge->{from} eq $node) {
				return 0 unless $visit->($edge->{to});
			}
		}
		delete $temp_mark{$node};
		$visited{$node} = 1;
		return 1;
	};

	for my $node (keys %{$graph->{nodes}}) {
		$visit->($node) unless $visited{$node};
	}
}

# }}}
# _validate_targets_section - validate targets.yml structure {{{
sub _validate_targets_section {
	my ($self, $targets_data) = @_;

	unless ($targets_data && ref($targets_data) eq 'HASH') {
		$self->_error("Invalid or empty targets.yml");
		return;
	}

	my $targets = $targets_data->{targets} || $targets_data;

	for my $name (keys %$targets) {
		my $target = $targets->{$name};
		unless (ref($target) eq 'HASH') {
			$self->_error("Target '$name' must be a map");
			next;
		}

		if ($target->{type} && $target->{type} eq 'bosh-director') {
			unless ($target->{connection}) {
				$self->_error("Target '$name' is missing 'connection' section");
			} elsif (!$target->{connection}{url}) {
				$self->_error("Target '$name' is missing 'connection.url'");
			}
		}
	}
}

# }}}
# _validate_integrations_section - validate integrations.yml structure {{{
sub _validate_integrations_section {
	my ($self, $integrations) = @_;

	unless ($integrations && ref($integrations) eq 'HASH') {
		$self->_error("Invalid or empty integrations.yml");
		return;
	}

	# Vault is required
	unless ($integrations->{vault}) {
		$self->_error("'vault' section is required in integrations.yml");
	} elsif (!$integrations->{vault}{url}) {
		$self->_error("'vault.url' is required in integrations.yml");
	}

	# Source control is required
	unless ($integrations->{source_control}) {
		$self->_error("'source_control' section is required in integrations.yml");
	}
}

# }}}
# _validate_cross_references - cross-reference validation {{{
sub _validate_cross_references {
	my ($self, $parsed) = @_;

	my $targets = $parsed->{targets}{targets} || $parsed->{targets} || {};
	my $workflows = $parsed->{pipeline}{workflows} || {};
	my $scripts = $parsed->{scripts}{scripts} || $parsed->{scripts} || {};

	# Validate workflow trigger patterns match at least one target
	for my $wf_name (keys %$workflows) {
		my $wf = $workflows->{$wf_name};
		next unless ref($wf) eq 'HASH' && $wf->{triggers};

		for my $trigger (@{$wf->{triggers}}) {
			next unless $trigger->{pattern};

			my $pattern = $trigger->{pattern};
			my $regex = join('', map {
				$_ eq '*' ? '.*' : $_ eq '?' ? '.' : quotemeta($_)
			} split(/([*?])/, $pattern, -1));
			$regex = qr/^$regex$/;

			my $matched = 0;
			for my $target_name (keys %$targets) {
				if ($target_name =~ $regex) {
					$matched = 1;
					last;
				}
			}

			$self->_warn("Workflow '$wf_name' trigger pattern '$pattern' matches no targets")
				unless $matched;
		}
	}

	# Validate script references in workflow stages
	for my $wf_name (keys %$workflows) {
		my $wf = $workflows->{$wf_name};
		next unless ref($wf) eq 'HASH';

		my $stages = $wf->{stages} || [];
		if (ref($stages) eq 'ARRAY') {
			for my $stage (@$stages) {
				next unless $stage->{script};
				unless ($scripts->{$stage->{script}}) {
					$self->_warn("Workflow '$wf_name' references undefined script '$stage->{script}'");
				}
			}
		}
	}
}

# }}}
# }}}
### Internal Helpers {{{

# _error - record a validation error {{{
sub _error {
	my ($self, $msg) = @_;
	push @{$self->{errors}}, $msg;
}

# }}}
# _warn - record a validation warning {{{
sub _warn {
	my ($self, $msg) = @_;
	push @{$self->{warnings}}, $msg;
}

# }}}
# }}}

1;

=head1 NAME

Genesis::CI::Compiler::Validator - CI configuration validator

=head1 DESCRIPTION

Genesis::CI::Compiler::Validator validates parsed CI configuration for
both legacy single-file and new multi-file formats. It checks required
fields, allowed keys, cross-references, and semantic constraints like
DAG acyclicity.

=head1 SYNOPSIS

  my $validator = Genesis::CI::Compiler::Validator->new(top => $top_obj);
  $validator->validate($parsed_config);

  if ($validator->has_errors) {
    for my $err (@{$validator->errors}) {
      error("  - %s", $err);
    }
    bail("Configuration validation failed");
  }

=head1 SEE ALSO

Genesis::CI::Compiler::Parser, Genesis::CI::Compiler::ASTBuilder

=cut

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
