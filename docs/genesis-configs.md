# Genesis Configuration

This document describes how to configure Genesis using the `~/.genesis/config` file.

## Overview

Genesis reads configuration from `~/.genesis/config` to customize its behavior. This file uses YAML format and supports various settings that control how Genesis operates across different environments and deployments.

## Configuration File Location

The configuration file should be located at:
```
~/.genesis/config
```

## Configuration Options

### BOSH Target Configuration

| Option | Type | Default | Values | Environment Variable |
|--------|------|---------|--------|---------------------|
| `default_bosh_target` | enum | `ask` | `ask`, `self`, `parent` | `GENESIS_DEFAULT_BOSH_TARGET` |

**Description:** Controls the default BOSH director targeting behavior when multiple options are available.

**Values:**
- `ask`: Prompt the user to select a BOSH director
- `self`: Use the current environment as the BOSH director
- `parent`: Use the BOSH director that deployed the current environment

**Example:**
```yaml
default_bosh_target: ask
```

***Note:*** BOSH environments that use create-env will always use `self` regardless of this setting, because they have no parent. Likewise, non-BOSH director environments will always use `parent` because they aren't a BOSH director.

### Repository Configuration

| Option | Type | Default | Values | Environment Variable |
|--------|------|---------|--------|---------------------|
| `legacy_repo_suffix` | boolean | `false` | `true`, `false` | `GENESIS_LEGACY_REPO_SUFFIX` |
| `deployment_roots` | array | `[]` | string or hasharray | `GENESIS_DEPLOYMENT_ROOTS` |

#### `legacy_repo_suffix`
**Description:** Enable support for legacy repository naming conventions.

**Example:**
```yaml
legacy_repo_suffix: false
```

#### `deployment_roots`
**Description:** Configure deployment root directories for organizing Genesis repositories. This supports both simple string paths and labeled path mappings.

**Subtype:** `string||hasharray` (can be a string or a hash of label => path)  
**Environment Splitting:** Uses `:` to separate multiple entries specified in the environment variable.  
**Environment Conversion:** Supports both simple paths and `label=path` pairs separated by `;` in the environment variable.

**Example:**
```yaml
deployment_roots:
  - /home/user/deployments
  - production: /opt/genesis/prod
  - staging: /opt/genesis/staging
```

**Environment Variable Example:**
```bash
export GENESIS_DEPLOYMENT_ROOTS="/home/user/deployments;production=/opt/genesis/prod;staging=/opt/genesis/staging"
```

### Genesis Behavior

| Option | Type | Default | Values | Environment Variable |
|--------|------|---------|--------|---------------------|
| `embedded_genesis` | enum | `ignore` | `ignore`, `check`, `warn` | - |
| `automatic_config_upgrade` | enum | `no` | `no`, `yes`, `silent` | `GENESIS_CONFIG_AUTOMATIC_UPGRADE` |

#### `embedded_genesis`
**Description:** Control behavior when Genesis detects an embedded Genesis installation.

**Values:**
- `ignore`: Don't check for embedded Genesis
- `check`: Check for embedded Genesis but don't warn
- `warn`: Check and warn about embedded Genesis

**Example:**
```yaml
embedded_genesis: ignore
```

#### `automatic_config_upgrade`
**Description:** Control automatic upgrading of configuration files.

**Values:**
- `no`: Never automatically upgrade configuration
- `yes`: Upgrade configuration with user confirmation
- `silent`: Upgrade configuration without prompting

**Example:**
```yaml
automatic_config_upgrade: no
```

### Display Configuration

| Option | Type | Default | Values | Environment Variable |
|--------|------|---------|--------|---------------------|
| `output_style` | enum | `plain` | `plain`, `fun`, `pointer` | - |
| `show_duration` | boolean | `false` | `true`, `false` | `GENESIS_SHOW_DURATION` |

#### `output_style`
**Description:** Configure the visual style of Genesis output.

**Values:**
- `plain`: Simple text output without decorations
- `fun`: Enhanced output with emojis and visual elements
- `pointer`: Output with pointer-style indicators

**Example:**
```yaml
output_style: plain
```

#### `show_duration`
**Description:** Display command execution duration information.

**Example:**
```yaml
show_duration: true
```

### Deployment Behavior

| Option | Type | Default | Values | Environment Variable |
|--------|------|---------|--------|---------------------|
| `fix_on_deploy` | enum | `never` | `always`, `ask`, `never` | `GENESIS_FIX_ON_DEPLOY` |
| `confirm_release_overrides` | enum | - | `always`, `outdated`, `never` | `GENESIS_CONFIRM_RELEASE_OVERRIDES` |

#### `fix_on_deploy`
**Description:** Control whether Genesis should attempt to fix issues during deployment.

**Values:**
- `always`: Automatically fix issues without prompting
- `ask`: Prompt before fixing issues
- `never`: Never attempt to fix issues automatically

**Example:**
```yaml
fix_on_deploy: ask
```

#### `confirm_release_overrides`
**Description:** Control when to confirm BOSH release overrides.

**Values:**
- `always`: Always confirm release overrides
- `outdated`: Only confirm when releases are outdated
- `never`: Never confirm release overrides

**Example:**
```yaml
confirm_release_overrides: outdated
```

### Cache and Storage

| Option | Type | Default | Values | Environment Variable |
|--------|------|---------|--------|---------------------|
| `spec_cache_dir` | string | `""` | any path | `GENESIS_SPEC_CACHE_DIR` |
| `bosh_logs_path` | string | `<DEPLOYMENT_ROOT>/bosh_logs` | any path template | `GENESIS_DEPLOYMENT_LOGS_PATH` |

#### `spec_cache_dir`
**Description:** Directory for caching specification files.

**Example:**
```yaml
spec_cache_dir: "/tmp/genesis-cache"
```

#### `bosh_logs_path`
**Description:** Path template for storing BOSH deployment logs. The `<DEPLOYMENT_ROOT>` placeholder will be replaced with the actual deployment root path.

**Example:**
```yaml
bosh_logs_path: "/var/log/genesis/bosh_logs"
```

### Warning Suppression

#### `suppress_warnings`
Configure which warnings to suppress. This is a hash with its own schema for specific warning types.

**Type:** hash

| Option | Type | Default | Environment Variable |
|--------|------|---------|---------------------|
| `oversized_secrets` | boolean | `false` | `GENESIS_SUPRESS_OVERSIZED_SECRETS_WARNING` |
| `bosh_target` | boolean | `false` | `GENESIS_SUPPRESS_BOSH_TARGET_WARNING` |

**Example:**
```yaml
suppress_warnings:
  oversized_secrets: false
  bosh_target: false
```

##### `oversized_secrets`
**Description:** Suppress warnings about secrets that are larger than expected.

##### `bosh_target`
**Description:** Suppress warnings about BOSH target selection.

### Logging Configuration

#### `logs`
Configure detailed logging behavior for Genesis operations. This is an array of hash objects, each defining a separate log destination with its own configuration.

**Type:** array of hash objects

```yaml
logs:
  - file: "/var/log/genesis/genesis.log"
    level: INFO
    show_stack: default
    truncate: false
    style: plain
    lifespan: forever
    timestamp: true
  - file: "/tmp/genesis-debug.log"
    level: DEBUG
    style: rfc-5424
    lifespan: current
```

Each log entry supports the following schema:

| Option | Type | Default | Values | Required |
|--------|------|---------|--------|----------|
| `file` | string | - | any path | ✓ |
| `level` | enum | `INFO` | `TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR`, `OUTPUT` | |
| `show_stack` | enum | `default` | `default`, `none`, `full`, `current`, `fatal` | |
| `style` | enum | `plain` | `plain`, `fun`, `pointer`, `rfc-5424` | |
| `timestamp` | boolean | `false` | `true`, `false` | |

##### `file`
Path to the log file where messages will be written.

##### `level`
Minimum log level to record. Messages at this level and above will be logged.

- `TRACE`: Most verbose, includes all internal operations
- `DEBUG`: Detailed debugging information
- `INFO`: General informational messages
- `WARN`: Warning messages
- `ERROR`: Error messages
- `OUTPUT`: Only capture command output

##### `show_stack`
Controls when and how stack traces are displayed in log messages.

- `default`: Show stack traces based on log level defaults
- `none`: Never show stack traces
- `full`: Always show full stack traces
- `current`: Show current execution context only
- `fatal`: Only show stack traces for fatal errors

##### `style`
Log message formatting style.

- `plain`: Simple text format
- `fun`: Enhanced format with colors and emojis
- `pointer`: Format with pointer-style indicators
- `rfc-5424`: Standard RFC-5424 syslog format

##### `timestamp`
Whether to include timestamps in log entries.

#### Future Logging Options - not yet implemented

These future options are currently placeholders and will be implemented in future releases.  They have no effect, but they will not cause errors if included in the configuration file.

| Option | Type | Default | Values |
|--------|------|---------|--------|
| `truncate` | boolean | `false` | `true`, `false` |
| `lifespan` | enum | `forever` | `forever`, `current`, `N days` |

##### `truncate`
Whether to truncate (clear) the log file when Genesis starts up.
*(Currently defaults to `true` in effect, as this is not implemented yet)*

##### `lifespan`
How long to retain log entries.

- `forever`: Keep log entries indefinitely
- `current`: Only keep entries for the current Genesis session (ie truncate is effectively `true`)
- `N days`: Keep log entries for the specified number of days (e.g., `7 days`)

## Example Configuration

Here's a complete example configuration file demonstrating all available options:

```yaml
# ~/.genesis/config

# BOSH targeting
default_bosh_target: ask

# Repository management
legacy_repo_suffix: false
deployment_roots:
  - /home/genesis/deployments
  - production: /opt/genesis/prod
  - staging: /opt/genesis/staging
  - development: /tmp/genesis-dev

# Display preferences
output_style: fun
show_duration: true

# Deployment behavior
fix_on_deploy: ask
confirm_release_overrides: outdated

# Cache and storage
spec_cache_dir: "/tmp/genesis-cache"
bosh_logs_path: "/var/log/genesis/<DEPLOYMENT_ROOT>/bosh_logs"

# Warning suppression
suppress_warnings:
  oversized_secrets: false
  bosh_target: true

# Genesis behavior
embedded_genesis: warn
automatic_config_upgrade: yes

# Comprehensive logging setup
logs:
  # Main application log
  - file: "/var/log/genesis/genesis.log"
    level: INFO
    timestamp: true
    style: plain
    lifespan: forever
    show_stack: default
    truncate: false
    
  # Debug log for troubleshooting
  - file: "/tmp/genesis-debug.log"
    level: DEBUG
    style: rfc-5424
    lifespan: current
    truncate: true
    timestamp: true
    show_stack: full
    
  # Error-only log
  - file: "/var/log/genesis/errors.log"
    level: ERROR
    style: plain
    lifespan: forever
    timestamp: true
    show_stack: fatal
```

## Environment Variable Overrides

Many configuration options can be overridden using environment variables. When an environment variable is set, it takes precedence over the configuration file setting. The following environment variables are supported:

- `GENESIS_DEFAULT_BOSH_TARGET`
- `GENESIS_LEGACY_REPO_SUFFIX`
- `GENESIS_SHOW_DURATION`
- `GENESIS_CONFIG_AUTOMATIC_UPGRADE`
- `GENESIS_FIX_ON_DEPLOY`
- `GENESIS_CONFIRM_RELEASE_OVERRIDES`
- `GENESIS_SPEC_CACHE_DIR`
- `GENESIS_DEPLOYMENT_LOGS_PATH`
- `GENESIS_DEPLOYMENT_ROOTS`
- `GENESIS_SUPRESS_OVERSIZED_SECRETS_WARNING`
- `GENESIS_SUPPRESS_BOSH_TARGET_WARNING`

## Configuration Validation

Genesis validates the configuration file on startup using a comprehensive schema. If there are validation errors, Genesis will report them and may refuse to run until the configuration is corrected. The validation ensures:

- All enum values are from the allowed set
- Boolean values are properly formatted
- Required fields are present
- Array and hash structures match expected schemas
- Environment variable conversions are properly formatted

## Advanced Configuration

### Deployment Roots with Labels

The `deployment_roots` configuration supports both simple paths and labeled mappings. This is particularly useful when working with multiple environments:

```yaml
deployment_roots:
  - /home/user/simple-path
  - prod: /opt/production/deployments
  - staging: /opt/staging/deployments  
  - dev: /tmp/dev-deployments
```

Labels allow you to reference deployment roots by name in Genesis commands, making it easier to switch between different deployment contexts.

### Complex Logging Scenarios

You can configure multiple log destinations for different purposes:

```yaml
logs:
  # Audit trail - everything at INFO level
  - file: "/var/log/genesis/audit.log"
    level: INFO
    style: rfc-5424
    timestamp: true
    lifespan: forever
    
  # Development debugging
  - file: "/tmp/genesis-trace.log"
    level: TRACE
    style: plain
    show_stack: full
    lifespan: current
    truncate: true
    
  # Error monitoring
  - file: "/var/log/genesis/errors.log"
    level: ERROR
    style: plain
    timestamp: true
    show_stack: fatal
```

## Upgrading Configuration

When `automatic_config_upgrade` is enabled, Genesis may automatically update your configuration file to support new features or fix deprecated settings. The upgrade behavior depends on the setting:

- `no`: Configuration is never automatically modified
- `yes`: Genesis will prompt before making changes
- `silent`: Changes are applied automatically without prompting

It's recommended to keep backups of your configuration file when enabling automatic upgrades.
