# Genesis Match Mode

Genesis match mode lets you reference environments and deployment repositories by pattern instead of typing full filenames. Using `@` notation, you can target any environment across your deployment roots with just a few characters, making operations faster and less error-prone.

## Quick Start

```bash
# Deploy the management BOSH environment
genesis @mgmt deploy

# Check the status of the OCF Cloud Foundry deployment
genesis @ocf:cf check

# List all environments across all deployment types
genesis "@:*" environments
```

> **Note:** Quote patterns containing `*` or `?` to prevent shell glob expansion. See [Troubleshooting](#troubleshooting) for details.

> Requires deployment roots configuration — see [Prerequisites](#prerequisites) below.

## Prerequisites

Match mode requires one or more deployment roots to be configured. A deployment root is a directory containing your Genesis deployment repositories (e.g., `bosh/`, `vault/`, `cf/`).

Configure deployment roots in `~/.genesis/config`:

```yaml
deployment_roots:
  - /home/user/deployments
  - production: /opt/genesis/prod
  - staging: /opt/genesis/staging
```

Or via environment variable:

```bash
export GENESIS_DEPLOYMENT_ROOTS="/home/user/deployments;production=/opt/genesis/prod"
```

Entries can be simple paths or `label: path` mappings. Labels make disambiguation menus clearer when multiple roots contain matching results.

See [genesis-configs.md](genesis-configs.md) for full configuration details.

## Syntax

Match mode is activated by placing an `@` expression **before** the subcommand.

```bash
genesis @<pattern> <subcommand> [options]
```

There are three forms:

| Form | What It Matches | Search Scope |
|------|----------------|--------------|
| `@<env>` | Environment file | Only `bosh/` and `bosh-deployments/` directories |
| `@<env>:<type>` | Environment file in deployment type | Directories matching `<type>` |
| `@:<type>` | Deployment repository | Directories matching `<type>` |

Examples:

- `@mgmt` — find an environment file named `*mgmt*` in BOSH directories

- `@ocf:cf` — find an environment file named `*ocf*` in CF directories

- `@:vault` — find the `vault` deployment repository

## Pattern Matching Rules

Patterns use glob-style matching with implicit wildcards and optional anchoring.

### Implicit Wildcards

By default, your pattern is wrapped with `*` on both sides. The pattern `mgmt` becomes `*mgmt*`, matching any filename containing "mgmt".

### Anchoring

Use `^` and `$` to anchor patterns to the beginning or end of the name:

| Pattern | Expands To | Matches |
|---------|-----------|---------|
| `mgmt` | `*mgmt*` | Anything containing "mgmt" |
| `^mgmt` | `mgmt*` | Names starting with "mgmt" |
| `mgmt$` | `*mgmt` | Names ending with "mgmt" |
| `^mgmt$` | `mgmt` | Exact match "mgmt" only |

### Glob Wildcards

Standard glob characters are supported within patterns:

- `*` — matches any sequence of characters

- `?` — matches exactly one character

### Step-by-Step Transformation

Genesis transforms your pattern in five steps:

1. Start with user input: `mgmt`

2. Wrap with wildcards: `*mgmt*`

3. Apply anchoring (if present): `^mgmt` becomes `mgmt*` (leading `*` removed)

4. Append `.yml` for environment searches: `*mgmt*.yml`

5. Glob against deployment directories

The type pattern (after `:`) follows the same transformation rules when matching directory names.

## Search Algorithm

### Search Root Order

Genesis searches deployment roots in this order:

1. **`@current`** — the directory where the Genesis command was invoked

2. **`@parent`** — the parent of the current directory

3. **Configured roots** — deployment roots from `~/.genesis/config` or `GENESIS_DEPLOYMENT_ROOTS`, in the order specified

### Environment Search (`@env` and `@env:type`)

When searching for environment files:

1. For each root, find subdirectories containing `.genesis/config` (valid Genesis repositories)

2. If no type is specified, restrict to `bosh/` and `bosh-deployments/` directories only

3. If a type is specified, restrict to directories matching the type pattern

4. Glob for `.yml` files matching the environment pattern in those directories

5. Validate each file: it must contain a `genesis:` block with an `env:` key matching the filename, and must have no top-level `name:` key

### Repository Search (`@:type`)

When searching for deployment repositories:

1. For each root, find subdirectories containing `.genesis/config`

2. Match directory names against the type pattern

3. Return matching repository paths

### Result Ordering

Results are ordered across both search types:

1. Current directory matches first

2. Parent directory matches second

3. Configured roots in their specified order

4. Within each root, BOSH directories (`bosh/` or `bosh-deployments/`) sort first

5. Remaining results sort alphabetically

### Exact Type Match Shortcut

Genesis applies a shortcut when a simple type pattern (no wildcards or anchors) yields multiple results. If one result matches the type name literally — for example, `cf/` matching type `cf` — Genesis selects it without prompting.

## Disambiguation

### Single Match

When only one file or repository matches, Genesis selects it automatically.

### Multiple Matches (Interactive)

When Genesis finds multiple matches in an interactive terminal, Genesis presents a numbered selection menu:

```
Multiple environment files found matching @ocf:*:

  📁 Deployment Root 'genesis-deployments': ~/ops
  1) cf/ocf (default)
  2) vault/ocf
  3) concourse/ocf

  4) None of these - cancel

Select the desired environment file >
```

The first result is the default. Results are grouped by deployment root with labeled headers.

### Multiple Matches (Non-Interactive / CI)

In non-interactive contexts (piped commands, CI pipelines), Genesis exits with an error listing all matches:

```
Ambiguous environment name: @ocf:* matches multiple files:
  - ~/ops/cf/ocf
  - ~/ops/vault/ocf
  - ~/ops/concourse/ocf

Please refine your match criteria.
```

Refine your pattern or use anchoring to produce a unique match.

## BOSH Target Behavior

Match mode sets the default BOSH target based on the form used:

| Form | Default BOSH Target | Rationale |
|------|-------------------|-----------|
| `@<env>` (no type) | `self` | Searches only BOSH directories, so the target is the director itself |
| `@<env>:<type>` (with type) | `parent` | Non-BOSH deployments are managed by a parent BOSH director |

This default is applied only when `GENESIS_DEFAULT_BOSH_TARGET` is not already set. If you have configured `default_bosh_target` in `~/.genesis/config` or set the environment variable, that takes precedence.

Genesis updates the in-memory configuration so that subsequent operations within the same invocation use the correct target.

## Special Case: `genesis environments`

When you use `@` with the `environments` subcommand (also accepted as `envs`), the pattern acts as a **filter** rather than a resolver. Instead of selecting a single environment, it lists all matching environments across all roots:

```bash
# List all CF environments
genesis @:cf environments

# List all environments with "prod" in the name
genesis @prod environments

# List all environments across all deployment types
genesis "@:*" environments
```

The environment and type patterns are converted to regular expressions for filtering (glob `*` becomes `.*`, `?` becomes `.?`), and anchoring with `^` and `$` is preserved in the regex form.

## OCFP Usage Patterns

Given a typical OCFP deployment structure:

```
~/ops/
├── bosh/
│   ├── mgmt.yml
│   └── ocf.yml
├── vault/
│   ├── mgmt.yml
│   └── ocf.yml
├── cf/
│   └── ocf.yml
├── concourse/
│   └── ocf.yml
├── shield/
│   └── ocf.yml
└── blacksmith/
    └── ocf.yml
```

Common patterns:

| Pattern | Resolves To | Description |
|---------|------------|-------------|
| `@mgmt` | `bosh/mgmt.yml` | Management BOSH director |
| `@ocf` | `bosh/ocf.yml` | OCF BOSH director |
| `@mgmt:vault` | `vault/mgmt.yml` | Management Vault deployment |
| `@ocf:cf` | `cf/ocf.yml` | OCF Cloud Foundry deployment |
| `@ocf:shield` | `shield/ocf.yml` | OCF SHIELD deployment |
| `@:cf` | `cf/` (repo) | Cloud Foundry deployment repository |
| `@:vault` | `vault/` (repo) | Vault deployment repository |
| `@ocf:*` | Interactive selection | All OCF environments across all types (quote as `"@ocf:*"`) |

## Argument Position and Interaction with Other Methods

The `@` expression must be the **first argument**, before the subcommand. You cannot combine it with other environment-specification methods.

| Method | Syntax | Notes |
|--------|--------|-------|
| Match mode | `genesis @mgmt deploy` | First argument, pattern-based |
| `-C` flag | `genesis -C /path/to/dir deploy env.yml` | Changes working directory |
| Direct file | `genesis deploy my-env.yml` | Explicit filename after subcommand |
| Implicit | `genesis deploy my-env` | Current directory, `.yml` appended |

These methods are mutually exclusive. Using `@` sets `GENESIS_PREFIX_TYPE` to `search` and resolves the environment before the subcommand is parsed.

## Environment Variables

| Variable | Purpose | Set By |
|----------|---------|--------|
| `GENESIS_DEPLOYMENT_ROOTS` | Configure deployment roots (semicolon-separated, supports `label=path`) | User |
| `GENESIS_DEFAULT_BOSH_TARGET` | Override default BOSH target (`ask`, `self`, `parent`) | User |
| `GENESIS_DEPLOYMENT_ROOT` | Set by match mode to the resolved deployment root path | Genesis (internal) |
| `GENESIS_PREFIX_TYPE` | Set to `search` when match mode is active | Genesis (internal) |
| `GENESIS_PREFIX_SEARCH` | Stores the original `@` pattern for use by subcommands | Genesis (internal) |
| `GENESIS_ORIGINATING_DIR` | The directory where the Genesis command was invoked; serves as the `@current` search root so match mode can find deployments relative to the invoking directory | Genesis (internal) |

## Best Practices

1. **Configure labeled deployment roots** for clear disambiguation menus. Labels like `production` and `staging` make it obvious which root you are selecting from.

2. **Use type qualifiers for non-BOSH deployments.** Without a type qualifier, match mode only searches BOSH directories. Use `@env:type` to target other deployment types.

3. **Use anchoring for precision** when environment names overlap. If you have both `mgmt` and `mgmt-dr`, use `@^mgmt$` for an exact match.

4. **Use `genesis @:* environments` for discovery.** This lists all environments across all deployment types and roots, helping you understand what is available.

5. **Understand BOSH target implications.** `@env` defaults to `self` (targeting the director), while `@env:type` defaults to `parent` (managed by a director). Set `default_bosh_target` in your config if you prefer different behavior.

6. **Prefer exact type names over wildcards.** Using `@ocf:cf` is faster and less ambiguous than `@ocf:c*`. Wildcards are best for exploration, not routine operations.

## Troubleshooting

### Unexpected Results with Wildcards

If a pattern containing `*` or `?` produces unexpected results, your shell may be expanding the glob before Genesis sees it. Always quote wildcard patterns: `genesis "@ocf:*" environments`.

### "No environment files found matching..."

- **No deployment roots configured.** Ensure `deployment_roots` is set in `~/.genesis/config` or `GENESIS_DEPLOYMENT_ROOTS` is exported.

- **Pattern too restrictive.** Broaden your pattern. Use `@:* environments` to see all available environments.

- **Not a Genesis repository.** Target directories must contain `.genesis/config` to be recognized. Verify with `ls <dir>/.genesis/config`.

- **File validation failed.** Environment files must contain a `genesis:` block with `env:` matching the filename, and must have no top-level `name:` key.

### "No deployment repositories found matching..."

- **Directory name mismatch.** Verify the deployment directory name matches your type pattern. Use `@:* environments` to list all repositories.

- **Missing `.genesis/config`.** The target directory must be an initialized Genesis repository.

### Unexpected BOSH-Only Results

When using `@env` without a type qualifier, Genesis intentionally restricts the search to `bosh/` and `bosh-deployments/` directories. This is by design: the unqualified form assumes you are targeting a BOSH director. Add a type qualifier (e.g., `@env:cf`) to search other deployment types.

### Wrong BOSH Director Targeted

Match mode sets the BOSH target to `self` for `@env` and `parent` for `@env:type`. If this is not what you want, either:

- Set `default_bosh_target` in `~/.genesis/config`

- Export `GENESIS_DEFAULT_BOSH_TARGET` before running the command

## See Also

These references cover the configuration and naming conventions that match mode depends on.

- [environment-naming.md](environment-naming.md) — environment naming conventions and deployment root structure

- [genesis-configs.md](genesis-configs.md) — full `~/.genesis/config` reference including `deployment_roots`

- [environment-variables.md](environment-variables.md) — complete list of Genesis environment variables
