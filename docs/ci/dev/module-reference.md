# Module Reference

This document catalogs every Perl module in the Genesis CI system, its
purpose, its public API, and its relationships with other modules. Modules
are listed in dependency order: foundational modules first, then the
modules that depend on them.

## Genesis::CI

**File:** `lib/Genesis/CI.pm`

**Purpose:** Factory class and trait interface definition. Serves as the
central dispatch point for constructing CI providers and as the abstract
base class defining the trait interface that all providers must implement.

**Public API:**

`Genesis::CI->new(type => $type, %opts)` is the factory method. It
resolves `$type` to a provider class, loads the provider module with
`require`, and calls `$provider_class->init(%opts)`. Valid types are
`concourse` and `github-actions`. Returns a provider instance.

`Genesis::CI->compile(%opts)` is a convenience method that creates a
`Genesis::CI::Compiler` and runs `compile()`. Accepts the same options
as `Compiler->new()` and `Compiler->compile()`. Returns the compiler
result hashref.

**Trait Interface (abstract, must be overridden):**

`init(%opts)` — class method, constructs provider instance.
`parse()` — loads and validates configuration.
`generate()` — produces platform-specific output.
`deploy(%opts)` — uploads/writes output to the CI platform.
`platform_name()` — returns human-readable platform name string.
`file_extension()` — returns file extension string.
`graphviz()` — optional, generates DOT source.
`describe()` — optional, generates human-readable description.

**Internal:**

`_resolve_provider_class($type)` maps a type string to a hashref with
`class` and `file` keys. The class is the Perl package name and the file
is the path for `require`.

---

## Genesis::CI::Legacy

**File:** `lib/Genesis/CI/Legacy.pm`

**Purpose:** Original monolithic Concourse pipeline generator. Handles the
entire pipeline from YAML parsing through Concourse YAML generation using
string concatenation and embedded spruce operators.

**Public API:**

`Genesis::CI::Legacy::parse($config_file, $top, $layout)` — loads
`$config_file` via `spruce merge`, validates structure, parses layout DSL,
normalizes defaults. Returns `($pipeline_hashref, $layout_name)`.

`Genesis::CI::Legacy::generate_pipeline_concourse_yaml($pipeline, $top)` —
generates complete Concourse pipeline YAML from the parsed hashref. Returns
a YAML string.

`Genesis::CI::Legacy::generate_pipeline_graphviz_source($pipeline)` —
generates Graphviz DOT source from parsed pipeline. Returns a string.

`Genesis::CI::Legacy::generate_pipeline_human_description($pipeline)` —
prints human-readable pipeline description to stdout. No return value.

**Dependencies:** `Genesis`, `Genesis::Top`, `Genesis::UI`, `JSON::PP`.

---

## Genesis::CI::Compiler

**File:** `lib/Genesis/CI/Compiler.pm`

**Purpose:** Orchestrates the six-stage compilation pipeline. Constructs
each stage module, passes data between stages, and returns the final
result.

**Public API:**

`Genesis::CI::Compiler->new(ci_dir => $dir, file => $file, top => $top)` —
constructor. Provide `ci_dir` for multi-file format or `file` for legacy
format. `top` is a `Genesis::Top` object.

`$compiler->compile(provider => $type)` — runs all stages. `$type` is
`concourse` or `github-actions`. Returns:

```perl
{
    ast      => $ast_object,
    output   => { filename => $content, ... },
    provider => $provider_object,
    parsed   => $parsed_hashref,
}
```

**Class Methods:**

`Genesis::CI::Compiler->can_compile($ci_dir)` — returns true if `$ci_dir`
exists and contains `pipeline.yml`. Used for format detection.

**Internal:**

`_resolve_provider_class($type)` — identical to `Genesis::CI`'s version.

---

## Genesis::CI::Compiler::Parser

**File:** `lib/Genesis/CI/Compiler/Parser.pm`

**Purpose:** Loads CI configuration from either the multi-file directory or
a single legacy file and normalizes it into a common intermediate structure.

**Public API:**

`Genesis::CI::Compiler::Parser->new(ci_dir => $dir, file => $file, top => $top)` —
constructor.

`$parser->parse()` — detects format and delegates to `_parse_multi_file()`
or `_parse_legacy_file()`. Returns a hashref.

**Internal Methods:**

`_parse_multi_file($ci_dir)` — loads `pipeline.yml`, `targets.yml`,
`integrations.yml`, optionally `scripts/manifest.yml` and
`provider-config/*.yml`.

`_parse_legacy_file($file)` — loads single YAML file and normalizes it.
Calls `_normalize_legacy_boshes()`, `_normalize_legacy_integrations()`,
and `_normalize_legacy_layouts()`.

`_normalize_legacy_boshes($boshes)` — converts boshes map to targets
format with `type` and `connection` fields.

`_normalize_legacy_integrations($pipeline)` — extracts vault, git,
notifications, and locker into a unified integrations structure.

`_normalize_legacy_layouts($pipeline)` — extracts layout/layouts and
parses the DSL.

`_parse_layout_dsl($src, $boshes)` — tokenizes layout string, processes
`auto` directives and environment chains, returns structured workflow data.

`_load_yaml_file($path)` — loads a YAML file via `spruce merge`.

---

## Genesis::CI::Compiler::Validator

**File:** `lib/Genesis/CI/Compiler/Validator.pm`

**Purpose:** Validates parsed configuration for structural correctness,
required fields, allowed keys, and cross-reference integrity.

**Public API:**

`Genesis::CI::Compiler::Validator->new(top => $top)` — constructor.

`$validator->validate($parsed)` — dispatches to format-specific validation.
Returns `$self`.

`$validator->has_errors()` — returns true if errors were found.

`$validator->errors()` — returns arrayref of error message strings.

`$validator->has_warnings()` — returns true if warnings were found.

`$validator->warnings()` — returns arrayref of warning message strings.

**Internal Methods:**

`_validate_legacy($parsed)` — validates against legacy schema. Calls
`_validate_required_keys`, `_validate_vault`, `_validate_git`,
`_validate_boshes`, `_validate_notifications`, `_validate_layouts`,
`_validate_locker`, `_validate_task`, `_validate_registry`,
`_validate_groups`, `_validate_auto_update`,
`_validate_notifications_style`, and checks allowed top-level keys.

`_validate_multi_file($parsed)` — validates pipeline, targets, and
integrations sections, plus cross-references.

`_validate_dag($wf_name, $graph)` — depth-first cycle detection on
workflow graph.

`_validate_cross_references($parsed)` — checks that workflow trigger
patterns match targets and script references resolve.

---

## Genesis::CI::Compiler::ScriptDiscovery

**File:** `lib/Genesis/CI/Compiler/ScriptDiscovery.pm`

**Purpose:** Discovers script metadata from manifest files, inline
annotations, and filename conventions.

**Public API:**

`Genesis::CI::Compiler::ScriptDiscovery->new(repo_path => $path)` —
constructor.

`$discovery->discover($parsed_config)` — discovers scripts from all
sources. Returns hashref of `script_id => metadata_hashref`.

**Internal Methods:**

`_load_manifest($manifest)` — loads from `scripts/manifest.yml` data.

`_extract_inline_metadata($file)` — parses `@genesis-script` annotations.
Supported annotations: `@description`, `@version`, `@requires`, `@input`,
`@output`, `@env-required`, `@env-optional`, `@timeout`, `@privileged`.

`_infer_metadata($file, $rel_path)` — generates metadata from filename.

`_path_to_id($path)` — converts file path to script ID by stripping
prefix and extension.

`_validate_script($id, $script)` — ensures required fields have defaults.

---

## Genesis::CI::Compiler::AST

**File:** `lib/Genesis/CI/Compiler/AST.pm`

**Purpose:** Central data structure with two-layer design. Holds both the
Genesis-specific source representation and the fully-resolved generic
pipeline.

**Constructor:**

`Genesis::CI::Compiler::AST->new(%data)` — accepts all source and pipeline
fields. Source fields are stored in `$self->{_source}`.

**Generic Pipeline Accessors (for providers):**

`pipeline()` — returns the full pipeline hashref.
`metadata()` — returns metadata hashref.
`scripts()` — returns scripts hashref.
`resource_types()` — shortcut to `$self->{pipeline}{resource_types}`.
`pipeline_resources()` — shortcut to `$self->{pipeline}{resources}`.
`jobs()` — shortcut to `$self->{pipeline}{jobs}`.
`groups()` — shortcut to `$self->{pipeline}{groups}`.
`graphviz()` — returns pre-built DOT source string.
`description()` — returns pre-built description string.
`set_pipeline($pipeline)` — stores the resolved generic pipeline.

**Source Accessors (for PipelineDescriptor and internal use):**

`branches()`, `integrations()`, `targets()`, `workflows()`,
`configuration()`, `provider_config()`, `triggers()`, `resources()`.

**Query Methods:**

`target_names()` — sorted list of target names.
`workflow_names()` — sorted list of workflow names.
`resource_names()` — sorted list of resource names.
`trigger_names()` — sorted list of trigger names.
`resources_matching($pattern)` — resources matching a glob.
`targets_matching($pattern)` — targets matching a glob.
`workflow_stage_order($wf_name)` — topologically sorted stage names.
`script_for_stage($wf_name, $stage_name)` — script metadata for a stage.
`env_vars_for_target($target_name)` — complete env var map for a target.

---

## Genesis::CI::Compiler::ASTBuilder

**File:** `lib/Genesis/CI/Compiler/ASTBuilder.pm`

**Purpose:** Constructs AST objects from parsed configuration and
discovered scripts.

**Public API:**

`Genesis::CI::Compiler::ASTBuilder->new(top => $top)` — constructor.

`$builder->build($parsed, $scripts)` — dispatches to format-specific
builder. Returns `Genesis::CI::Compiler::AST` object.

**Internal Methods:**

`_build_from_legacy($parsed, $scripts)` — builds from legacy format.
Computes metadata, branches, integrations, targets, workflows (via
`_build_legacy_workflows`), configuration, and provider_config.

`_build_legacy_workflows($parsed, $pipeline)` — builds workflow graphs
from parsed layout data. Computes aliases, genesis_envs, auto_envs (via
glob pattern matching), triggers (inverse of will_trigger), and DAG
nodes/edges. Preserves `_legacy` data on each workflow.

`_build_from_multi_file($parsed, $scripts)` — builds from multi-file
format. Passes most data through, builds workflows via
`_build_modern_workflows`.

`_build_modern_workflows($defs, $scripts)` — builds graphs from stage
lists via `_build_workflow_graph`.

`_build_workflow_graph($stages, $scripts)` — creates sequential DAG
from a list of stage definitions.

---

## Genesis::CI::Compiler::PipelineDescriptor

**File:** `lib/Genesis/CI/Compiler/PipelineDescriptor.pm`

**Purpose:** Converts the AST source representation into a fully-resolved
generic pipeline. This is the boundary between Genesis domain logic and
generic CI generation. At approximately 1300 lines, it is the largest
module in the compiler.

**Public API:**

`Genesis::CI::Compiler::PipelineDescriptor->new(ast => $ast, top => $top)` —
constructor.

`$descriptor->describe()` — builds the full generic pipeline. Returns a
hashref with `resource_types`, `resources`, `jobs`, `groups`, `graphviz`,
and `description` keys. Also stores the result in the AST via
`set_pipeline()`.

`$descriptor->graphviz()` — generates DOT source from workflow graphs.

`$descriptor->description()` — generates human-readable text.

**Internal Methods (resource generation):**

`_resource_types($ast)` — base resource types (script, email,
slack-notification, bosh-config, locker).

`_git_resource($ast)` — main git resource.

`_notification_resources($ast)` — slack and email resources.

`_env_resources($ast, $env, $alias, $trigger_from, $is_create_env, $wf_data)` —
per-environment resources (changes, cache, cloud-config, runtime-config).

`_locker_resources($ast, $env, $alias, $deploy_type, $is_create_env)` —
BOSH lock and deployment lock resources.

`_auto_update_resources($ast)` — kit-release and genesis-release resources.

**Internal Methods (job generation):**

`_notify_job(...)` — notification job for non-auto environments.

`_deploy_job(...)` — deployment job with full plan assembly.

`_auto_update_job($ast)` — update-genesis-assets job.

**Internal Methods (task configuration):**

`_task_config(...)` — deploy/show-changes task config with all env vars.

`_cache_task_config(...)` — cache generation task config.

`_errand_config(...)` — errand execution task config.

`_notification_step($ast, $message)` — slack/email notification plan step.

**Internal Methods (helpers):**

`_extract_workflow_data($ast, $workflow)` — unified extraction from any
workflow type.

`_git_uri($source_control)` — builds git URI.

`_unwrap_ref($value)` — unwraps `{secret_ref => '...'}` to `((...))`.

`_is_create_env($ast, $env)` — checks target type.

`_env_file_patterns($env_name)` — hierarchical YAML file list.

`_unique_env_files($env, $trigger_from)` — files unique to downstream env.

`_shared_env_files($env, $trigger_from)` — files shared between envs.

`_topological_sort($graph)` — standard topological sort.

---

## Genesis::CI::Compiler::PipelineProvider

**File:** `lib/Genesis/CI/Compiler/PipelineProvider.pm`

**Purpose:** Abstract base class for CI platform providers. Defines the
compiler interface and provides shared helper methods.

**Abstract Methods (must override):**

`platform_name()` — return platform name string.
`generate_from_ast($ast)` — generate platform-specific output.
`output_files()` — describe generated files.

**Helper Methods:**

`ast()` — returns stored AST.
`top()` — returns stored `Genesis::Top`.
`dump_yaml($data)` — serializes Perl data to YAML string.
`git_uri($source_control)` — builds git URI.
`secret_ref($ref)` — formats secret reference (default: `(($ref))`).
`topological_sort($graph)` — topological sort on workflow graph.
`matches_pattern($name, $pattern)` — glob pattern matching.

---

## Genesis::CI::Concourse

**File:** `lib/Genesis/CI/Compiler/Providers/Concourse.pm`

**Purpose:** Concourse CI provider. Implements both the trait interface
and the compiler interface. Handles the legacy bridge for backward
compatibility.

**Inherits:** `Genesis::CI`, `Genesis::CI::Compiler::PipelineProvider`

**Compiler Interface:**

`generate_from_ast($ast)` — checks for legacy marker and delegates to
either `_generate_from_legacy_ast()` or `_generate_native()`.

`output_files()` — returns `{ 'pipeline.yml' => '...' }`.

**Trait Interface:**

`init(%opts)` — constructs instance with file, top, layout, platform.

`parse()` — routes to Legacy::parse (for platform=legacy) or runs
compiler pipeline stages.

`generate()` — routes to Legacy generation or `generate_from_ast()`.

`deploy(%opts)` — uploads pipeline via fly CLI. Supports dry-run, yes,
paused options. Handles pause/set-pipeline/unpause/expose cycle.

**Concourse-Specific:**

`graphviz()` — DOT source via Legacy or AST.

`describe()` — human description via Legacy or AST.

**Internal:**

`_generate_from_legacy_ast($ast)` — reconstructs `$P` hashref from AST
legacy data and delegates to `Legacy::generate_pipeline_concourse_yaml`.

`_generate_native($ast)` — serializes generic pipeline to YAML.

`_ensure_pipeline_resolved()` — runs PipelineDescriptor if needed.

---

## Genesis::CI::GithubActions

**File:** `lib/Genesis/CI/Compiler/Providers/GithubActions.pm`

**Purpose:** GitHub Actions provider. Generates workflow YAML for GitHub's
CI platform.

**Inherits:** `Genesis::CI`, `Genesis::CI::Compiler::PipelineProvider`

**Dependencies:** `YAML::PP` (external dependency, unlike Concourse which
uses the built-in serializer).

**Compiler Interface:**

`generate_from_ast($ast)` — reads source representation directly (not
the generic pipeline) and builds GitHub Actions workflow structure with
`on` triggers, `jobs` with `steps`, and `needs` dependencies.

`output_files()` — returns `{ "$name.yml" => '...' }`.

**Trait Interface:**

`init(%opts)`, `parse()`, `generate()`, `deploy(%opts)` — self-contained
implementations that do not use Legacy.

**Internal:**

`_normalize_git_config()` — sets defaults and parses owner/repo from URI.

`_normalize_vault_config()` — placeholder for vault config normalization.

`_determine_environments()` — extracts sorted environment names from
boshes config.

`_generate_triggers()` — builds workflow `on` section.

`_generate_jobs()` — builds job definitions with `_generate_steps_for_env`.

---

## Genesis::Commands::Pipelines

**File:** `lib/Genesis/Commands/Pipelines.pm`

**Purpose:** Command handler for all pipeline-related CLI commands. Routes
between legacy and compiler code paths based on the `--platform` flag.

**Public Subroutines:**

`embed()` — embeds Genesis binary into deployment repository.

`repipe()` — generates and deploys pipeline. Routes to legacy or compiler.

`graph()` — generates Graphviz DOT output.

`describe()` — generates human-readable description.

`ci_pipeline_deploy()` — internal command for pipeline deployment tasks.

`ci_show_changes()` — internal command for showing pending changes.

`ci_generate_cache()` — internal command for cache generation.

`ci_pipeline_run_errand()` — internal command for running errands.

**Internal:**

`_repipe_compiled($top, $layout)` — runs compiler pipeline and deploys
result. Handles --output-dir, --dry-run, and platform-specific deployment.

`_graph_compiled($top, $layout)` — runs compiler and outputs DOT.

`_describe_compiled($top, $layout)` — runs compiler and outputs description.

`_compile_pipeline($top, $platform)` — shared compilation logic. Detects
`.genesis/ci/` directory, creates compiler, runs `compile()`, handles
`--debug-dir`.

`_dump_debug_artifacts($debug_dir, $result, $platform)` — writes numbered
intermediate files for debugging.

`_vault_auth()` — authenticates to Vault using AppRole.

`_commit_changes(...)` — commits pipeline artifacts back to git.

`_get_git_env($dir)` — sets up git credentials in a temp directory.

`_propagate_previous_passed_files()` — copies cache from predecessor env.
