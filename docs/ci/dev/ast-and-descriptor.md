# AST and PipelineDescriptor

The AST is the central data structure of the compiler pipeline. It has a
deliberate two-layer design: a source representation that holds
Genesis-specific concepts, and a generic pipeline that holds fully-resolved
CI primitives. The PipelineDescriptor module is the bridge between these
two layers. Understanding this separation is critical for working on the
compiler.

## Why Two Layers

The two-layer design exists because Genesis domain concepts (BOSH directors,
Vault integrations, deployment environments, hierarchical YAML files,
cache propagation) do not map directly to CI platform primitives (resources,
jobs, triggers, steps). A BOSH director is not a "resource" in the CI
sense — it manifests as multiple resources (cloud-config watcher,
runtime-config watcher), task parameters (BOSH_ENVIRONMENT, BOSH_CLIENT),
and conditional logic (create-env vs director deployment).

If providers had to understand Genesis concepts, every provider would need
to implement the same domain logic. By resolving Genesis concepts into
generic CI primitives first, providers become thin serializers that only
need to know how to format `{resource_types, resources, jobs, groups}` for
their platform.

## AST Source Representation

The source representation is stored in `$ast->{_source}` and is populated
by the ASTBuilder. It contains Genesis-specific concepts that directly
mirror the parsed configuration.

```perl
$ast->{_source} = {
  branches        => { live => 'main', target_prefix => 'target/' },
  integrations    => {
    vault          => { url => '...', auth => {...}, options => {...} },
    source_control => { repository => '...', auth => {...}, ... },
    notifications  => [ { type => 'slack', ... }, ... ],
    locker         => { url => '...', ... },
  },
  targets         => {
    sandbox => { name => 'sandbox', type => 'bosh-director', connection => {...}, alias => '...' },
    proto   => { name => 'proto', type => 'bosh-create-env', tags => ['create-env'] },
  },
  workflows       => {
    default => {
      name  => 'default',
      type  => 'legacy-deployment',
      graph => {
        nodes => { sandbox => {...}, staging => {...}, prod => {...} },
        edges => [ { from => 'sandbox', to => 'staging' }, { from => 'staging', to => 'prod' } ],
      },
      _legacy => { ... },  # Legacy-specific data for the bridge
    },
  },
  configuration   => { public => 0, tagged => 0, task => {...}, ... },
  provider_config => { concourse => { _legacy_pipeline_raw => {...} } },
  triggers        => { ... },
  resources       => { ... },
};
```

Accessors for source data are defined as simple methods on the AST class:
`branches()`, `integrations()`, `targets()`, `workflows()`,
`configuration()`, `provider_config()`, `triggers()`, `resources()`.
Additionally, convenience query methods exist: `target_names()`,
`workflow_names()`, `resource_names()`, `trigger_names()`,
`resources_matching($pattern)`, `targets_matching($pattern)`,
`workflow_stage_order($wf_name)`, `script_for_stage($wf, $stage)`, and
`env_vars_for_target($target)`.

The source representation is meant to be read by PipelineDescriptor and
by internal compiler logic. Providers should not read it directly.

## AST Generic Pipeline

The generic pipeline is stored in `$ast->{pipeline}` and is populated by
PipelineDescriptor via `$ast->set_pipeline($pipeline)`. It contains
fully-resolved CI primitives.

```perl
$ast->{pipeline} = {
  resource_types => [
    { name => 'script', type => 'registry-image', source => { repository => '...' } },
    { name => 'slack-notification', type => 'registry-image', source => { ... } },
    ...
  ],
  resources => [
    { name => 'git', type => 'git', icon => 'github', source => { uri => '...', branch => '...' } },
    { name => 'slack', type => 'slack-notification', source => { url => '...' } },
    { name => 'sandbox-changes', type => 'git', source => { paths => [...] } },
    { name => 'sandbox-cloud-config', type => 'bosh-config', source => { ... } },
    ...
  ],
  jobs => [
    {
      name   => 'notify-staging-deployment-changes',
      public => true,
      serial => true,
      plan   => [ { in_parallel => [...] }, { task => '...' }, ... ],
    },
    {
      name   => 'sandbox-deployment',
      public => true,
      serial => true,
      plan   => [ { do => [...], on_failure => {...}, ensure => {...} } ],
    },
    ...
  ],
  groups => [
    { name => 'my-pipeline', jobs => ['sandbox-deployment', 'staging-deployment', ...] },
  ],
  graphviz    => 'digraph "..." { ... }',
  description => 'Pipeline: ...\n  sandbox ...',
};
```

Providers read this data through shortcut accessors: `resource_types()`,
`pipeline_resources()`, `jobs()`, `groups()`, `graphviz()`, `description()`.

## PipelineDescriptor in Detail

PipelineDescriptor is the largest module in the compiler at approximately
1300 lines. Every method in it serves a specific role in converting
Genesis domain concepts into generic CI primitives.

### Resource Generation

The descriptor generates several categories of resources:

**Base resources** are created once per pipeline. `_git_resource()` creates
the main git resource that tracks the deployment repository. It constructs
the Git URI from the source control integration, sets the branch, and
configures authentication (SSH key or username/password).
`_notification_resources()` creates slack and/or email resources from the
notification integrations.

**Per-environment resources** are created by `_env_resources()` for each
environment in each workflow. A changes resource watches the Git paths that
are unique to that environment. A cache resource (only for triggered
environments) watches the cache directory generated by the predecessor. Two
BOSH config resources (cloud-config and runtime-config) monitor the BOSH
director for config changes. These are skipped for create-env environments.

**Locker resources** are created by `_locker_resources()` when a locker
integration is configured. Each non-create-env environment gets a BOSH lock
resource (keyed on the director URL) and a deployment lock resource (keyed
on the environment-deployment name).

**Auto-update resources** are created by `_auto_update_resources()` when
`auto_update` is configured. These are `github-release` resources that
monitor kit releases and Genesis CLI releases.

### Job Generation

`_notify_job()` creates a notification job for each non-auto environment.
This job triggers on changes (and cache updates for triggered environments),
runs `ci-show-changes` to compute the deployment diff, and sends a
notification.

`_deploy_job()` creates the deployment job for each environment. This is
the most complex method in the module. It assembles the job plan from these
building blocks:

The resource gets section uses `in_parallel` to fetch the changes resource,
cache resource (for triggered environments), git resource (with passed
constraints), and BOSH config resources (for auto environments). The
trigger and passed settings depend on whether the environment is auto,
whether it has a predecessor, whether inline notifications are used, and
whether `require-passed-caches` is set.

The deploy task uses `_task_config()` to build a Concourse task definition
with the Genesis Docker image, all necessary environment variables (Vault,
BOSH, Git, Genesis configuration), and the `ci-pipeline-deploy` command.
The task has an `ensure` block that pushes the git output directory.

Errand tasks follow the deploy task for non-create-env environments.

The cache task uses `_cache_task_config()` to run `ci-generate-cache`.

After the cache task, the job pushes or gets cache resources for any
downstream environments (controlled by `will_trigger`).

Lock acquisition happens before the resource gets, and lock release
happens in an `ensure` block around the entire `do` sequence. This ensures
locks are released even on failure.

Notification steps (`on_failure` and `on_success`) wrap the `do` block.

`_auto_update_job()` creates the `update-genesis-assets` job with three
tasks: list existing kits, update the embedded Genesis binary, and fetch
the latest kit release. Each task uses embedded shell scripts.

### Environment Variable Assembly

`_task_config()` builds the complete environment variable map for
deployment tasks. This includes `GENESIS_HONOR_ENV`, `CI_NO_REDACT`,
`CURRENT_ENV`, `PREVIOUS_ENV`, `CACHE_DIR`, `OUT_DIR`, `WORKING_DIR`,
`GIT_BRANCH`, `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`,
`BOSH_NON_INTERACTIVE`, `VAULT_ADDR`, `VAULT_ROLE_ID`,
`VAULT_SECRET_ID`, `VAULT_SKIP_VERIFY`, `VAULT_NAMESPACE`,
`VAULT_NO_STRONGBOX`, git authentication variables, `GIT_GENESIS_ROOT`,
and `DEBUG`.

The `_unwrap_ref()` helper handles secret references. Values that were
stored as `{ secret_ref => 'some/path' }` by the ASTBuilder are unwrapped
back to `((some/path))` Concourse interpolation syntax. Plain scalar values
pass through unchanged.

### File Path Computation

Three helper functions compute Git paths for environment file watching:

`_env_file_patterns()` splits an environment name on hyphens and builds
the hierarchical list of YAML files. For `client-aws-us1-prod`, this
returns `['client.yml', 'client-aws.yml', 'client-aws-us1.yml',
'client-aws-us1-prod.yml']`.

`_unique_env_files()` computes files that exist in the downstream
environment but not in the upstream. These are the files that the changes
resource watches for triggered environments.

`_shared_env_files()` computes files that both environments share. These
are the files that the cache resource watches.

### Group Generation

Groups are generated based on the `notifications` style setting and
whether custom groups are configured. With custom groups, each group maps
to a list of environment aliases. With `grouped` notification style,
notify jobs are separated into a "notifications" group. The `auto_update`
job always gets its own "genesis-updates" group.

## Workflow Data Extraction

The `_extract_workflow_data()` helper is used throughout the descriptor
to get a consistent view of any workflow regardless of whether it came
from a legacy layout or a modern stage definition. It reads the graph
nodes and edges and builds maps of environments, auto flags, aliases,
genesis_envs, will_trigger, and triggers. For legacy workflows, it
overlays the `_legacy` data which may contain more accurate information
(since the legacy builder preserves the original auto patterns and alias
mappings).

## AST Query Methods

The AST provides several query methods that PipelineDescriptor and other
internal code use:

`env_vars_for_target($name)` builds a complete environment variable map
for a given target, including Vault credentials, BOSH connection info,
and Git authentication. This is used by the AST itself and could be used
by providers that need target-specific environment setup.

`workflow_stage_order($wf_name)` returns a topologically sorted list of
stage names for a workflow, which gives you deployment order.

`script_for_stage($wf_name, $stage_name)` looks up the script metadata
for a specific stage in a workflow by following the `script_id` reference.

`targets_matching($pattern)` and `resources_matching($pattern)` support
glob-style queries against target and resource names.
