# Genesis Configuration File

Genesis uses a global configuration file located at `~/.genesis/config` to customize behavior and settings.

## Configuration File Format

The configuration file is written in YAML format. All configuration keys are optional and will use their default values if not specified.

## Configuration Options

### BOSH Settings

#### `default_bosh_target`
- **Type:** enum
- **Values:** `ask`, `self`, `parent`
- **Default:** `ask`
- **Environment Variable:** `GENESIS_DEFAULT_BOSH_TARGET`
- **Description:** Default BOSH target selection behavior when deploying environments.

#### `bosh_logs_path`
- **Type:** string
- **Default:** `<DEPLOYMENT_ROOT>/bosh_logs`
- **Environment Variable:** `GENESIS_DEPLOYMENT_LOGS_PATH`
- **Description:** Path for storing BOSH deployment logs. The `<DEPLOYMENT_ROOT>` placeholder will be replaced with the actual deployment root directory.

### Deployment Settings

#### `deployment_roots`
- **Type:** array of strings or label/path pairs
- **Default:** `[]` (empty array)
- **Environment Variable:** `GENESIS_DEPLOYMENT_ROOTS` (colon-separated list)
- **Description:** List of deployment root directories. Can be specified as:
  - Simple paths: `["/path/to/deployments", "/other/deployments"]`
  - Labeled paths: `[[label1, /path/to/deployments], [label2, /other/deployments]]`
  - In environment variable: paths separated by `:`, or `label=path` pairs separated by `;`

**Example:**
```yaml
deployment_roots:
  - /home/user/production-deployments
  - [dev, /home/user/dev-deployments]
  - [staging, /home/user/staging-deployments]
```

**Note:** Deployment root labels cannot start with `@` - this prefix is reserved for Genesis internal use.

#### `legacy_repo_suffix`
- **Type:** boolean
- **Default:** `false`
- **Environment Variable:** `GENESIS_LEGACY_REPO_SUFFIX`
- **Description:** Use legacy "-deployments" suffix when creating new repositories.

#### `kits_path`
- **Type:** string
- **Default:** Uses deployment repository's config settings
- **Description:** Path for storing kit files. Defaults to the kit path specified in the deployment repository's configuration.

#### `spec_cache_dir`
- **Type:** string
- **Default:** `""` (empty string)
- **Environment Variable:** `GENESIS_SPEC_CACHE_DIR`
- **Description:** Directory for caching kit specifications to improve performance.

### User Interface Settings

#### `output_style`
- **Type:** enum
- **Values:** `plain`, `fun`, `pointer`
- **Default:** `plain`
- **Description:** CLI output style for Genesis commands.

#### `show_duration`
- **Type:** boolean
- **Default:** `false`
- **Environment Variable:** `GENESIS_SHOW_DURATION`
- **Description:** Show command execution duration after operations complete.

#### `ui.colors.code`
- **Type:** string
- **Default:** `Yb` (Yellow text on dark blue background)
- **Environment Variable:** `GENESIS_UI_COLOR_CODE`
- **Description:** Color scheme for code blocks in the UI. Format: `[foreground][background][style]`
  - Foreground/Background colors: `K`/`k` (black), `R`/`r` (red), `G`/`g` (green), `Y`/`y` (yellow), `B`/`b` (blue), `M`/`m` (magenta), `C`/`c` (cyan), `W`/`w` (white)
  - Uppercase = bold, lowercase = normal
  - Optional style suffix: `i` (italic), `u` (underline)

#### `ui.colors.warning_alert`
- **Type:** string
- **Default:** `kYi` (Black on yellow header with yellow italicized text)
- **Environment Variable:** `GENESIS_UI_COLOR_WARNING`
- **Description:** Color scheme for warning messages in the UI.

**Example:**
```yaml
ui:
  colors:
    code: Yb           # Yellow on blue
    warning_alert: kYi # Black on yellow, italic
```

### Configuration Management

#### `embedded_genesis`
- **Type:** enum
- **Values:** `ignore`, `check`, `warn`
- **Default:** `ignore`
- **Description:** How to handle embedded genesis versions in deployment repositories.
  - `ignore`: Don't check for embedded genesis
  - `check`: Check and report embedded genesis versions
  - `warn`: Check and warn about embedded genesis versions

#### `automatic_config_upgrade`
- **Type:** enum
- **Values:** `no`, `yes`, `silent`
- **Default:** `no`
- **Environment Variable:** `GENESIS_CONFIG_AUTOMATIC_UPGRADE`
- **Description:** Automatically upgrade configuration files when Genesis detects an outdated format.
  - `no`: Don't upgrade automatically
  - `yes`: Upgrade and notify user
  - `silent`: Upgrade without notification

#### `fix_on_deploy`
- **Type:** enum
- **Values:** `always`, `ask`, `never`
- **Default:** `never`
- **Environment Variable:** `GENESIS_FIX_ON_DEPLOY`
- **Description:** Automatically fix issues during deployment.
  - `always`: Automatically fix without asking
  - `ask`: Prompt user before fixing
  - `never`: Don't automatically fix issues

#### `confirm_release_overrides`
- **Type:** enum
- **Values:** `always`, `outdated`, `never`
- **Environment Variable:** `GENESIS_CONFIRM_RELEASE_OVERRIDES`
- **Description:** When to confirm BOSH release overrides.
  - `always`: Always confirm release overrides
  - `outdated`: Only confirm when releases are outdated
  - `never`: Never confirm release overrides

### Warning Suppression

#### `suppress_warnings.oversized_secrets`
- **Type:** boolean
- **Default:** `false`
- **Environment Variable:** `GENESIS_SUPRESS_OVERSIZED_SECRETS_WARNING`
- **Description:** Suppress warnings about oversized secrets in Vault/Credhub.

#### `suppress_warnings.bosh_target`
- **Type:** boolean
- **Default:** `false`
- **Environment Variable:** `GENESIS_SUPPRESS_BOSH_TARGET_WARNING`
- **Description:** Suppress warnings about BOSH target selection.

**Example:**
```yaml
suppress_warnings:
  oversized_secrets: true
  bosh_target: false
```

### Logging

#### `logs`
- **Type:** array of log configuration objects
- **Default:** `[]` (no file logging)
- **Description:** Configure file-based logging for Genesis operations.

Each log configuration object supports:

##### `file` (required)
- **Type:** string
- **Description:** File path for the log file.

##### `level`
- **Type:** enum
- **Values:** `TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR`, `OUTPUT`
- **Default:** `INFO`
- **Description:** Minimum log level to write to this file.

##### `show_stack`
- **Type:** enum
- **Values:** `default`, `none`, `full`, `current`, `fatal`
- **Default:** `default`
- **Description:** When to include stack traces in log entries.
  - `default`: Include stack on errors
  - `none`: Never include stack traces
  - `full`: Always include full stack traces
  - `current`: Include current context only
  - `fatal`: Only on fatal errors

##### `truncate`
- **Type:** boolean
- **Default:** `true`
- **Description:** Truncate the log file when Genesis starts.

##### `style`
- **Type:** enum
- **Values:** `plain`, `fun`, `pointer`, `rfc-5424`
- **Default:** `plain`
- **Description:** Log output format.
  - `plain`: Simple text format
  - `fun`: Colorful/emoji format
  - `pointer`: Pointer-style format
  - `rfc-5424`: RFC 5424 syslog format

##### `lifespan`
- **Type:** enum
- **Values:** `forever`, `current`
- **Default:** `current`
- **Description:** How long to keep log entries.
  - `forever`: Never remove log entries
  - `current`: Only keep entries from current session

##### `timestamp`
- **Type:** boolean
- **Default:** `false`
- **Description:** Include timestamps in log entries.

**Example:**
```yaml
logs:
  - file: ~/.genesis/logs/debug.log
    level: DEBUG
    truncate: true
    timestamp: true
    style: plain

  - file: ~/.genesis/logs/trace.log
    level: TRACE
    show_stack: full
    truncate: false
    lifespan: forever
```

## Complete Example Configuration

```yaml
# BOSH Settings
default_bosh_target: parent
bosh_logs_path: ~/genesis-logs

# Deployment Settings
deployment_roots:
  - [prod, /deployments/production]
  - [dev, /deployments/development]
  - /deployments/lab

kits_path: ~/.genesis/kits
spec_cache_dir: ~/.genesis/cache/specs

# UI Settings
output_style: fun
show_duration: true

ui:
  colors:
    code: Yb
    warning_alert: kYi

# Configuration Management
embedded_genesis: warn
automatic_config_upgrade: yes
fix_on_deploy: ask
confirm_release_overrides: outdated

# Warning Suppression
suppress_warnings:
  oversized_secrets: false
  bosh_target: true

# Logging
logs:
  - file: ~/.genesis/logs/genesis.log
    level: INFO
    truncate: true
    timestamp: true
    style: plain
    lifespan: current
```

## Environment Variable Overrides

Most configuration options can be overridden via environment variables. The environment variable name is listed under each option's description. When both a config file value and environment variable are set, the environment variable takes precedence.

## Path Expansion

Paths in the configuration file support:
- **Tilde expansion:** `~/path` expands to `$HOME/path`
- **User expansion:** `~username/path` expands to that user's home directory
- **Environment variables:** `$VAR` or `${VAR}` expand to the value of that environment variable
- **Relative paths:** Converted to absolute paths based on current directory

## Validation

Genesis validates the configuration file on startup. Invalid configuration values will cause Genesis to report an error and may prevent operation. Use `genesis ping` to validate your configuration without performing any operations.
