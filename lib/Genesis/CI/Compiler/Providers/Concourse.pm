package Genesis::CI::Concourse;
use v5.20;
use warnings;

use parent 'Genesis::CI', 'Genesis::CI::Compiler::PipelineProvider';

use Genesis;
use Genesis::Top;
use Genesis::CI::Legacy;
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
		file   => $opts{file},
		top    => $opts{top},
		layout => $opts{layout},
		config => undef,
		errors => [],
	}, $class);
	
	return $self;
}

# }}}
# }}}
### Trait Interface Implementation {{{

# parse - parse and validate Concourse pipeline configuration {{{
sub parse {
	my ($self) = @_;
	
	# Delegate to Legacy implementation for now
	# This validates and normalizes the config
	my ($pipeline, $layout) = Genesis::CI::Legacy::parse(
		$self->{file},
		$self->{top},
		$self->{layout}
	);
	
	$self->{config} = $pipeline;
	$self->{layout} = $layout;
	
	return $self;
}

# }}}
# generate - generate Concourse pipeline YAML {{{
sub generate {
	my ($self) = @_;
	
	bail("Must call parse() before generate()") unless $self->{config};
	
	# Delegate to Legacy implementation
	# TODO: Refactor Legacy logic into this class over time
	my $yaml = Genesis::CI::Legacy::generate_pipeline_concourse_yaml(
		$self->{config},
		$self->{top}
	);
	
	return $yaml;
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

# _generate_native - generate Concourse pipeline YAML directly from AST {{{
sub _generate_native {
	my ($self, $ast) = @_;

	my $config      = $ast->configuration || {};
	my $deploy_type = $ast->metadata->{deployment_type} || 'deployment';
	my $name        = $ast->metadata->{name} || 'genesis-pipeline';

	my @resources;
	my @resource_types = @{$self->_native_resource_types($ast)};
	my @jobs;
	my @groups;

	# Base resources
	push @resources, $self->_native_git_resource($ast);
	push @resources, @{$self->_native_notification_resources($ast)};

	# Process each workflow
	for my $wf_name (sort $ast->workflow_names) {
		my $workflow = $ast->workflows->{$wf_name};
		my $wf_data  = $self->_extract_workflow_data($ast, $workflow);

		my @wf_job_names;
		for my $env (sort @{$wf_data->{environments}}) {
			my $alias         = $wf_data->{aliases}{$env} || $env;
			my $is_auto       = $wf_data->{auto}{$env};
			my $trigger_from  = $wf_data->{triggers}{$env};
			my $is_create_env = $self->_is_create_env($ast, $env);

			push @resources, @{$self->_native_env_resources(
				$ast, $env, $alias, $trigger_from, $is_create_env, $wf_data
			)};

			unless ($is_auto) {
				my $nj = $self->_native_notify_job(
					$ast, $env, $alias, $deploy_type, $trigger_from,
					$is_create_env, $wf_data
				);
				push @jobs, $nj;
				push @wf_job_names, $nj->{name};
			}

			my $dj = $self->_native_deploy_job(
				$ast, $env, $alias, $deploy_type, $is_auto,
				$trigger_from, $is_create_env, $wf_data
			);
			push @jobs, $dj;
			push @wf_job_names, $dj->{name};
		}

		push @groups, {
			name => ($wf_name eq 'default') ? $name : $wf_name,
			jobs => [sort @wf_job_names],
		};
	}

	# Assemble and serialize
	my $pipeline = {
		groups         => \@groups,
		resources      => \@resources,
		resource_types => \@resource_types,
		jobs           => \@jobs,
	};

	return "---\n" . $self->dump_yaml($pipeline) . "\n";
}

# }}}
# _extract_workflow_data - extract unified data from any workflow type {{{
sub _extract_workflow_data {
	my ($self, $ast, $workflow) = @_;

	my $graph = $workflow->{graph} || {};
	my $nodes = $graph->{nodes} || {};
	my $edges = $graph->{edges} || [];

	my (%will_trigger, %triggers, %auto, %aliases, %genesis_envs);

	for my $edge (@$edges) {
		push @{$will_trigger{$edge->{from}}}, $edge->{to};
		$triggers{$edge->{to}} = $edge->{from};
	}
	for my $n (keys %$nodes) {
		my $nd = $nodes->{$n};
		$auto{$n}         = 1 if $nd->{auto};
		$aliases{$n}      = $nd->{alias}       || $n;
		$genesis_envs{$n} = $nd->{genesis_env} || $n;
	}

	# Prefer _legacy data if available (more complete)
	if ($workflow->{_legacy}) {
		my $leg = $workflow->{_legacy};
		%auto         = map { $_ => 1 } @{$leg->{auto_envs} || []};
		%aliases      = %{$leg->{aliases}      || \%aliases};
		%genesis_envs = %{$leg->{genesis_envs} || \%genesis_envs};
		%will_trigger = %{$leg->{will_trigger} || \%will_trigger};
		%triggers     = ref($leg->{triggers}) eq 'HASH'
			? %{$leg->{triggers}} : %triggers;
	}

	return {
		environments => [sort keys %$nodes],
		auto         => \%auto,
		aliases      => \%aliases,
		genesis_envs => \%genesis_envs,
		will_trigger => \%will_trigger,
		triggers     => \%triggers,
	};
}

# }}}
# _native_git_resource - build main git resource {{{
sub _native_git_resource {
	my ($self, $ast) = @_;

	my $sc     = $ast->integrations->{source_control} || {};
	my $uri    = $self->git_uri($sc);
	my $branch = $sc->{default_branch} || $ast->branches->{live} || 'main';

	my $source = { uri => $uri, branch => $branch };

	if ($sc->{auth}) {
		if (($sc->{auth}{type} || '') eq 'ssh-key') {
			$source->{private_key} = $self->_unwrap_ref($sc->{auth}{private_key});
		} else {
			$source->{username} = $self->_unwrap_ref($sc->{auth}{username});
			$source->{password} = $self->_unwrap_ref($sc->{auth}{password});
		}
	}
	$source->{version_depth} = $sc->{version_depth} if $sc->{version_depth};

	return { name => 'git', type => 'git', icon => 'github', source => $source };
}

# }}}
# _native_notification_resources - build slack/email resources {{{
sub _native_notification_resources {
	my ($self, $ast) = @_;

	my @resources;
	my $notifications = $ast->integrations->{notifications} || [];

	for my $notif (@$notifications) {
		if ($notif->{type} eq 'slack') {
			push @resources, {
				name   => 'slack',
				type   => 'slack-notification',
				icon   => 'slack',
				source => { url => $self->_unwrap_ref($notif->{webhook}) },
			};
		} elsif ($notif->{type} eq 'email') {
			push @resources, {
				name   => 'email',
				type   => 'email',
				icon   => 'email-send-outline',
				source => {
					to   => $notif->{recipients},
					from => $notif->{from},
					smtp => $notif->{smtp},
				},
			};
		}
	}
	return \@resources;
}

# }}}
# _native_resource_types - build resource type definitions {{{
sub _native_resource_types {
	my ($self, $ast) = @_;

	my $registry = ($ast->configuration || {})->{registry} || {};
	my $prefix   = $registry->{uri} ? "$registry->{uri}/" : '';

	my %rs;
	if ($registry->{username}) {
		$rs{username} = $registry->{username};
		$rs{password} = $self->_unwrap_ref($registry->{password});
	}

	return [map {{
		name   => $_->[0],
		type   => 'registry-image',
		source => { %rs, repository => "$prefix$_->[1]" },
	}} (
		['script',             'cfcommunity/script-resource'],
		['email',              'pcfseceng/email-resource'],
		['slack-notification', 'cfcommunity/slack-notification-resource'],
		['bosh-config',        'cfcommunity/bosh-config-resource'],
		['locker',             'cfcommunity/locker-resource'],
	)];
}

# }}}
# _native_env_resources - build per-environment resources {{{
sub _native_env_resources {
	my ($self, $ast, $env, $alias, $trigger_from, $is_create_env, $wf_data) = @_;

	my @resources;
	my $sc   = $ast->integrations->{source_control} || {};
	my $uri  = $self->git_uri($sc);
	my $br   = $sc->{default_branch} || $ast->branches->{live} || 'main';
	my $root = $sc->{root} || '.';
	my $pr   = ($root eq '.') ? '' : "$root/";

	# Shared git source
	my %gs = (uri => $uri, branch => $br);
	if ($sc->{auth}) {
		if (($sc->{auth}{type} || '') eq 'ssh-key') {
			$gs{private_key} = $self->_unwrap_ref($sc->{auth}{private_key});
		} else {
			$gs{username} = $self->_unwrap_ref($sc->{auth}{username});
			$gs{password} = $self->_unwrap_ref($sc->{auth}{password});
		}
	}

	# Changes resource
	my @paths;
	if ($trigger_from) {
		@paths = map { "$pr$_" } $self->_unique_env_files($env, $trigger_from);
	} else {
		@paths = (
			(map { "$pr$_" } $self->_env_file_patterns($env)),
			"${pr}ops/*", "${pr}kit-overrides.yml",
		);
	}
	push @resources, {
		name => "$alias-changes", type => 'git', icon => 'github',
		source => { %gs, paths => \@paths },
	};

	# Cache resource (triggered envs only)
	if ($trigger_from) {
		my @cpaths = map { "$pr.genesis/cached/$trigger_from/$_" }
			$self->_shared_env_files($env, $trigger_from);
		push @cpaths, "$pr.genesis/cached/$trigger_from/ops/*";
		push @cpaths, "$pr.genesis/cached/$trigger_from/kit-overrides.yml";
		push @resources, {
			name => "$alias-cache", type => 'git', icon => 'github',
			source => { %gs, paths => \@cpaths },
		};
	}

	# BOSH config resources (non-create-env)
	unless ($is_create_env) {
		my $target = $ast->targets->{$env} || {};
		my $conn   = $target->{connection} || {};
		my $auth   = $conn->{auth} || {};
		my $tagged = ($ast->configuration || {})->{tagged};
		my %to = $tagged ? (tags => [$env]) : ();

		my %bs = (
			target        => $conn->{url},
			client        => $auth->{client_id},
			client_secret => $self->_unwrap_ref($auth->{client_secret}),
			ca_cert       => $self->_unwrap_ref($conn->{ca_cert}),
		);
		push @resources, {
			name => "$alias-cloud-config", type => 'bosh-config',
			icon => 'script-text', %to,
			source => { %bs, config => 'cloud', all => JSON::PP::true },
		};
		push @resources, {
			name => "$alias-runtime-config", type => 'bosh-config',
			icon => 'script-text', %to,
			source => { %bs, config => 'runtime', all => JSON::PP::true },
		};
	}

	return \@resources;
}

# }}}
# _native_notify_job - notification job for non-auto environments {{{
sub _native_notify_job {
	my ($self, $ast, $env, $alias, $deploy_type, $trigger_from,
		$is_create_env, $wf_data) = @_;

	my $config = $ast->configuration || {};
	my $tagged = $config->{tagged};
	my %to     = $tagged ? (tags => [$env]) : ();
	my $passed = $trigger_from ? $wf_data->{aliases}{$trigger_from} : '';
	my $passed_job = $passed ? "$passed-$deploy_type" : '';

	my @gets = ({ get => "$alias-changes", trigger => JSON::PP::true });
	push @gets, { get => "$alias-cache", trigger => JSON::PP::true }
		if $trigger_from;
	push @gets, { get => 'git', passed => [$passed_job], trigger => JSON::PP::false }
		if $passed_job && !$config->{'require-passed-caches'};

	unless ($is_create_env) {
		push @gets, { get => "$alias-cloud-config",   %to, trigger => JSON::PP::true };
		push @gets, { get => "$alias-runtime-config", %to, trigger => JSON::PP::true };
	}

	my $task_cfg = $self->_native_task_config($ast, $env, $alias, $trigger_from, $wf_data,
		{ command => 'ci-show-changes' });

	my $pipeline_name = $ast->metadata->{name} || 'genesis-pipeline';
	my $notif = $self->_build_notification_step($ast,
		"$pipeline_name: Changes staged for $env-$deploy_type");

	my @plan = (
		{ in_parallel => \@gets },
		{ task => 'show-pending-changes', %to, config => $task_cfg },
	);
	push @plan, $notif if $notif;

	return {
		name   => "notify-$alias-$deploy_type-changes",
		public => JSON::PP::true,
		serial => JSON::PP::true,
		plan   => \@plan,
	};
}

# }}}
# _native_deploy_job - deployment job for an environment {{{
sub _native_deploy_job {
	my ($self, $ast, $env, $alias, $deploy_type, $is_auto,
		$trigger_from, $is_create_env, $wf_data) = @_;

	my $config     = $ast->configuration || {};
	my $sc         = $ast->integrations->{source_control} || {};
	my $root       = $sc->{root} || '.';
	my $tagged     = $config->{tagged};
	my %to         = $tagged ? (tags => [$env]) : ();
	my $name       = $ast->metadata->{name} || 'genesis-pipeline';
	my $trigger    = $is_auto ? JSON::PP::true : JSON::PP::false;
	my $passed     = $trigger_from ? $wf_data->{aliases}{$trigger_from} : '';
	my $passed_job = $passed ? "$passed-$deploy_type" : '';
	my $pass_cache = $config->{'require-passed-caches'};
	my $inline     = ($config->{notifications}{style} || 'inline') eq 'inline';

	# Genesis binary source
	my $srcdir = $pass_cache
		? ($trigger_from ? "$alias-cache" : "$alias-changes")
		: 'git';
	my $bindir = $srcdir;
	$bindir .= "/$root" if $root ne '.';

	# Resource gets
	my @gets;
	if (!$is_create_env && $is_auto) {
		push @gets, { get => "$alias-cloud-config",   %to, trigger => JSON::PP::true };
		push @gets, { get => "$alias-runtime-config", %to, trigger => JSON::PP::true };
	}
	if ($is_auto || !$inline) {
		push @gets, { get => "$alias-changes", trigger => $trigger };
	} else {
		push @gets, { get => "$alias-changes", trigger => JSON::PP::false,
			passed => ["notify-$alias-$deploy_type-changes"] };
	}
	if ($trigger_from) {
		my %cg = (get => "$alias-cache", trigger => ($is_auto ? JSON::PP::true : JSON::PP::false));
		$cg{passed} = [$passed_job] if $pass_cache && $passed_job;
		push @gets, \%cg;
	}
	if ($trigger_from && !$pass_cache) {
		my $gp = ($is_auto || !$inline) ? $passed_job : "notify-$alias-$deploy_type-changes";
		push @gets, { get => 'git', passed => [$gp], trigger => JSON::PP::false } if $gp;
	}

	# Deploy task
	my $deploy_task = {
		task => 'bosh-deploy', %to,
		config => $self->_native_task_config($ast, $env, $alias, $trigger_from, $wf_data,
			{ command => 'ci-pipeline-deploy', genesis_bindir => $bindir, genesis_srcdir => $srcdir }),
		ensure => { put => 'git', params => { repository => 'out/git' } },
	};
	my @priv = @{$config->{task}{privileged} || []};
	$deploy_task->{privileged} = JSON::PP::true if grep { $_ eq $alias } @priv;

	# Cache task
	my $cache_task = {
		task => 'generate-cache', %to,
		config => $self->_native_cache_task_config($ast, $env, $alias, $trigger_from, $wf_data,
			{ genesis_bindir => $bindir, genesis_srcdir => $srcdir }),
	};

	# Build do block
	my @do = (
		{ in_parallel => \@gets },
		$deploy_task,
	);

	# Errands (non-create-env only)
	unless ($is_create_env) {
		for my $errand (@{$config->{errands} || []}) {
			push @do, {
				task => "$errand-errand", %to,
				config => $self->_native_errand_config($ast, $env, $errand, $bindir, $srcdir),
			};
		}
	}

	push @do, $cache_task;
	push @do, { put => 'git', params => { repository => 'cache-out/git' } };

	# Trigger downstream cache resources
	for my $push_env (@{$wf_data->{will_trigger}{$env} || []}) {
		my $pa = $wf_data->{aliases}{$push_env} || $push_env;
		if ($pass_cache) {
			push @do, { put => "$pa-cache", params => { repository => 'cache-out/git' } };
		} else {
			push @do, { get => "$pa-cache", %to };
		}
	}

	# Notifications
	my $fail = $self->_build_notification_step($ast, "$name: Deployment to $env-$deploy_type failed");
	my $succ = $self->_build_notification_step($ast, "$name: Successfully deployed $env-$deploy_type");

	my $plan_step = {};
	$plan_step->{on_failure} = $fail if $fail;
	$plan_step->{on_success} = $succ if $succ;
	$plan_step->{do} = \@do;

	return {
		name   => "$alias-$deploy_type",
		public => JSON::PP::true,
		serial => JSON::PP::true,
		plan   => [$plan_step],
	};
}

# }}}
# _native_task_config - common task configuration block {{{
sub _native_task_config {
	my ($self, $ast, $env, $alias, $trigger_from, $wf_data, $opts) = @_;

	my $config  = $ast->configuration || {};
	my $sc      = $ast->integrations->{source_control} || {};
	my $vault   = $ast->integrations->{vault} || {};
	my $root    = $sc->{root} || '.';
	my $cmd     = $opts->{command} || 'ci-pipeline-deploy';
	my $bindir  = $opts->{genesis_bindir} || 'git';
	my $srcdir  = $opts->{genesis_srcdir} || 'git';
	my $passed  = $trigger_from || '';

	my $task_cfg = $config->{task} || {};
	my $reg      = $config->{registry} || {};
	my $pfx      = $reg->{uri} ? "$reg->{uri}/" : '';

	my $img_src = {
		repository => "$pfx" . ($task_cfg->{image} || 'genesiscommunity/concourse'),
		tag        => $task_cfg->{version} || 'latest',
	};
	if ($reg->{username}) {
		$img_src->{username} = $reg->{username};
		$img_src->{password} = $self->_unwrap_ref($reg->{password});
	}

	my %params = (
		GENESIS_HONOR_ENV    => 1,
		CI_NO_REDACT         => $config->{unredacted} || 0,
		CURRENT_ENV          => $env,
		PREVIOUS_ENV         => $passed || '~',
		CACHE_DIR            => "$alias-cache",
		OUT_DIR              => 'out/git',
		WORKING_DIR          => "$alias-changes",
		GIT_BRANCH           => $sc->{default_branch} || $ast->branches->{live} || 'main',
		GIT_AUTHOR_NAME      => ($sc->{commit_author} ? $sc->{commit_author}{name}  : undef) || 'Concourse Bot',
		GIT_AUTHOR_EMAIL     => ($sc->{commit_author} ? $sc->{commit_author}{email} : undef) || 'concourse@pipeline',
		BOSH_NON_INTERACTIVE => 'true',
		VAULT_ADDR           => $vault->{url} || '',
	);

	if ($vault->{auth}) {
		$params{VAULT_ROLE_ID}   = $self->_unwrap_ref($vault->{auth}{role_id});
		$params{VAULT_SECRET_ID} = $self->_unwrap_ref($vault->{auth}{secret_id});
	}
	if ($vault->{options}) {
		$params{VAULT_SKIP_VERIFY}   = $vault->{options}{tls_verify} ? 'false' : 'true';
		$params{VAULT_NO_STRONGBOX}  = '"true"' if $vault->{options}{no_strongbox};
	}
	$params{VAULT_NAMESPACE} = $vault->{namespace} if $vault->{namespace};

	if ($sc->{auth}) {
		if (($sc->{auth}{type} || '') eq 'ssh-key') {
			$params{GIT_PRIVATE_KEY} = $self->_unwrap_ref($sc->{auth}{private_key});
		} else {
			$params{GIT_USERNAME} = $self->_unwrap_ref($sc->{auth}{username});
			$params{GIT_PASSWORD} = $self->_unwrap_ref($sc->{auth}{password});
		}
	}
	$params{GIT_GENESIS_ROOT} = $root if $root ne '.';
	$params{DEBUG}            = $config->{debug} if $config->{debug};

	my @inputs = ({ name => "$alias-changes" });
	push @inputs, { name => "$alias-cache" } if $passed;
	push @inputs, { name => 'git' } unless $config->{'require-passed-caches'};

	return {
		platform       => 'linux',
		image_resource => { type => 'registry-image', source => $img_src },
		params         => \%params,
		run            => { path => "$bindir/.genesis/bin/genesis", args => [$cmd] },
		inputs         => \@inputs,
		outputs        => [{ name => 'out' }],
	};
}

# }}}
# _native_cache_task_config - cache generation task config {{{
sub _native_cache_task_config {
	my ($self, $ast, $env, $alias, $trigger_from, $wf_data, $opts) = @_;

	my $config = $ast->configuration || {};
	my $sc     = $ast->integrations->{source_control} || {};
	my $root   = $sc->{root} || '.';
	my $bindir = $opts->{genesis_bindir} || 'git';
	my $srcdir = $opts->{genesis_srcdir} || 'git';

	my $task_cfg = $config->{task} || {};
	my $reg      = $config->{registry} || {};
	my $pfx      = $reg->{uri} ? "$reg->{uri}/" : '';

	my $img_src = {
		repository => "$pfx" . ($task_cfg->{image} || 'genesiscommunity/concourse'),
		tag        => $task_cfg->{version} || 'latest',
	};
	if ($reg->{username}) {
		$img_src->{username} = $reg->{username};
		$img_src->{password} = $self->_unwrap_ref($reg->{password});
	}

	my %params = (
		GENESIS_HONOR_ENV => 1,
		CI_NO_REDACT      => $config->{unredacted} || 0,
		CURRENT_ENV       => $env,
		WORKING_DIR       => 'out/git',
		OUT_DIR           => 'cache-out/git',
		GIT_BRANCH        => $sc->{default_branch} || $ast->branches->{live} || 'main',
		GIT_AUTHOR_NAME   => ($sc->{commit_author} ? $sc->{commit_author}{name}  : undef) || 'Concourse Bot',
		GIT_AUTHOR_EMAIL  => ($sc->{commit_author} ? $sc->{commit_author}{email} : undef) || 'concourse@pipeline',
	);

	if ($trigger_from) {
		$params{PREVIOUS_ENV} = $trigger_from;
		$params{CACHE_DIR}    = 'out/git';
	}

	if ($sc->{auth}) {
		if (($sc->{auth}{type} || '') eq 'ssh-key') {
			$params{GIT_PRIVATE_KEY} = $self->_unwrap_ref($sc->{auth}{private_key});
		} else {
			$params{GIT_USERNAME} = $self->_unwrap_ref($sc->{auth}{username});
			$params{GIT_PASSWORD} = $self->_unwrap_ref($sc->{auth}{password});
		}
	}
	$params{GIT_GENESIS_ROOT} = $root if $root ne '.';
	$params{DEBUG} = $config->{debug} if $config->{debug};

	return {
		platform       => 'linux',
		image_resource => { type => 'registry-image', source => $img_src },
		params         => \%params,
		run            => { path => "$bindir/.genesis/bin/genesis", args => ['ci-generate-cache'] },
		inputs         => [{ name => 'out' }, { name => $srcdir }],
		outputs        => [{ name => 'cache-out' }],
	};
}

# }}}
# _native_errand_config - errand task config {{{
sub _native_errand_config {
	my ($self, $ast, $env, $errand_name, $bindir, $srcdir) = @_;

	my $config = $ast->configuration || {};
	my $vault  = $ast->integrations->{vault} || {};
	my $sc     = $ast->integrations->{source_control} || {};
	my $root   = $sc->{root} || '.';

	my $task_cfg = $config->{task} || {};
	my $reg      = $config->{registry} || {};
	my $pfx      = $reg->{uri} ? "$reg->{uri}/" : '';

	my $img_src = {
		repository => "$pfx" . ($task_cfg->{image} || 'genesiscommunity/concourse'),
		tag        => $task_cfg->{version} || 'latest',
	};
	if ($reg->{username}) {
		$img_src->{username} = $reg->{username};
		$img_src->{password} = $self->_unwrap_ref($reg->{password});
	}

	my %params = (
		GENESIS_HONOR_ENV => 1,
		CI_NO_REDACT      => $config->{unredacted} || 0,
		CURRENT_ENV       => $env,
		ERRAND_NAME       => $errand_name,
		VAULT_ADDR        => $vault->{url} || '',
	);
	if ($vault->{auth}) {
		$params{VAULT_ROLE_ID}   = $self->_unwrap_ref($vault->{auth}{role_id});
		$params{VAULT_SECRET_ID} = $self->_unwrap_ref($vault->{auth}{secret_id});
	}
	if ($vault->{options}) {
		$params{VAULT_SKIP_VERIFY}  = $vault->{options}{tls_verify} ? 'false' : 'true';
		$params{VAULT_NO_STRONGBOX} = '"true"' if $vault->{options}{no_strongbox};
	}
	$params{VAULT_NAMESPACE} = $vault->{namespace} if $vault->{namespace};
	$params{DEBUG} = $config->{debug} if $config->{debug};

	my $subdir = ($root eq '.') ? '' : "/$root";

	return {
		platform       => 'linux',
		image_resource => { type => 'registry-image', source => $img_src },
		params         => \%params,
		run            => {
			path => "../../$bindir/.genesis/bin/genesis",
			dir  => "out/git$subdir",
			args => ['ci-pipeline-run-errand'],
		},
		inputs => [{ name => 'out' }, { name => $srcdir }],
	};
}

# }}}
# _build_notification_step - build notification plan step {{{
sub _build_notification_step {
	my ($self, $ast, $message) = @_;

	my $notifications = $ast->integrations->{notifications};
	return undef unless $notifications && ref($notifications) eq 'ARRAY' && @$notifications;

	my @steps;
	for my $notif (@$notifications) {
		if ($notif->{type} eq 'slack') {
			push @steps, {
				put    => 'slack',
				params => {
					channel  => $notif->{channel},
					username => $notif->{username} || 'runwaybot',
					icon_url => $notif->{icon},
					text     => $message,
				},
			};
		}
	}

	return @steps ? { in_parallel => \@steps } : undef;
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
# _unwrap_ref - unwrap secret_ref hash or return scalar {{{
sub _unwrap_ref {
	my ($self, $value) = @_;
	return undef unless defined $value;
	if (ref($value) eq 'HASH' && exists $value->{secret_ref}) {
		return "(($value->{secret_ref}))";
	}
	return $value;
}

# }}}
# _is_create_env - check if target is a create-env deployment {{{
sub _is_create_env {
	my ($self, $ast, $env) = @_;
	my $target = $ast->targets->{$env} || {};
	return 1 if ($target->{type} || '') eq 'bosh-create-env';
	return 1 if grep { $_ eq 'create-env' } @{$target->{tags} || []};
	return 0;
}

# }}}
# _env_file_patterns - compute potential environment files {{{
sub _env_file_patterns {
	my ($self, $env_name) = @_;
	my @parts = split /-/, $env_name;
	my @patterns;
	my $prefix = '';
	for my $part (@parts) {
		$prefix .= ($prefix ? '-' : '') . $part;
		push @patterns, "$prefix.yml";
	}
	return @patterns;
}

# }}}
# _unique_env_files - files unique to env (not shared with predecessor) {{{
sub _unique_env_files {
	my ($self, $env, $trigger_from) = @_;
	my @ep = split /-/, $env;
	my @tp = split /-/, $trigger_from;

	my $common = 0;
	for my $i (0 .. $#tp) {
		last if $i > $#ep || $tp[$i] ne $ep[$i];
		$common++;
	}

	my @unique;
	my $prefix = '';
	for my $i (0 .. $#ep) {
		$prefix .= ($prefix ? '-' : '') . $ep[$i];
		push @unique, "$prefix.yml" if $i >= $common;
	}
	return @unique;
}

# }}}
# _shared_env_files - files shared between env and its predecessor {{{
sub _shared_env_files {
	my ($self, $env, $trigger_from) = @_;
	my @ep = split /-/, $env;
	my @tp = split /-/, $trigger_from;

	my @shared;
	my $prefix = '';
	for my $i (0 .. $#tp) {
		last if $i > $#ep || $tp[$i] ne $ep[$i];
		$prefix .= ($prefix ? '-' : '') . $tp[$i];
		push @shared, "$prefix.yml";
	}
	return @shared;
}

# }}}
# }}}
### Additional Concourse-Specific Methods {{{

# graphviz - generate graphviz dot source {{{
sub graphviz {
	my ($self) = @_;
	
	bail("Must call parse() before graphviz()") unless $self->{config};
	
	return Genesis::CI::Legacy::generate_pipeline_graphviz_source(
		$self->{config}
	);
}

# }}}
# describe - generate human-readable description {{{
sub describe {
	my ($self) = @_;
	
	bail("Must call parse() before describe()") unless $self->{config};
	
	Genesis::CI::Legacy::generate_pipeline_human_description(
		$self->{config}
	);
	
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

=head2 graphviz()

Generate Graphviz DOT source for pipeline visualization.

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
