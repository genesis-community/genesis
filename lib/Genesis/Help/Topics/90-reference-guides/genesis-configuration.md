# Genesis Configuration

This guide provides comprehensive documentation for configuring Genesis using the `~/.genesis/config` file.

## Overview

Genesis uses a YAML configuration file to customize its behavior across environments and deployments. This configuration file provides a centralized way to manage Genesis settings without relying on environment variables.

## Configuration File Location

The configuration file is located at:
```
~/.genesis/config
```

Genesis automatically creates this directory and file on first use if they don't exist.

## Configuration Options

### BOSH Target Configuration

Control how Genesis selects BOSH directors when multiple options are available.

#### default_bosh_target

| Option | Type | Default | Values | Environment Variable |
|--------|------|---------|--------|---------------------|
| `default_bosh_target` | enum | `ask` | `ask`, `self`, `parent` | `GENESIS_DEFAULT_BOSH_TARGET` |

**Description**: Controls default BOSH director targeting behavior.

**Values**:
- `ask`: Prompt user to select a BOSH director (default)
- `self`: Use current environment as BOSH director
- `parent`: Use BOSH director that deployed current environment

**Example**:
```yaml
default_bosh_target: ask
```

**Notes**: 
- BOSH environments using create-env always use `self`
- Non-BOSH director environments always use `parent`
- This setting only applies when there's ambiguity

### Repository Configuration

Manage how Genesis handles deployment repositories.

#### legacy_repo_suffix

| Option | Type | Default | Values | Environment Variable |
|--------|------|---------|--------|---------------------|
| `legacy_repo_suffix` | boolean | `false` | `true`, `false` | `GENESIS_LEGACY_REPO_SUFFIX` |

**Description**: Enable support for legacy repository naming conventions (e.g., `concourse-deployments`).

**Example**:
```yaml
legacy_repo_suffix: false
```

#### deployment_roots

| Option | Type | Default | Values | Environment Variable |
|--------|------|---------|--------|---------------------|
| `deployment_roots` | array | `[]` | paths or labeled paths | `GENESIS_DEPLOYMENT_ROOTS` |

**Description**: Configure deployment root directories for organizing Genesis repositories.

**Format Options**:

1. **Simple paths**:
   ```yaml
   deployment_roots:
     - /home/user/deployments
     - /opt/genesis/deployments
   ```

2. **Labeled paths**:
   ```yaml
   deployment_roots:
     - production: /opt/genesis/prod
     - staging: /opt/genesis/staging
     - development: /tmp/genesis-dev
   ```

3. **Mixed format**:
   ```yaml
   deployment_roots:
     - /home/user/deployments
     - prod: /opt/genesis/prod
     - staging: /opt/genesis/staging
   ```

**Environment Variable Format**:
```bash
# Colon-separated paths
export GENESIS_DEPLOYMENT_ROOTS="/path1:/path2"

# With labels (semicolon for label=path)
export GENESIS_DEPLOYMENT_ROOTS="/path1;prod=/opt/prod;staging=/opt/staging"
```

**Usage**: Labels allow referencing deployment roots by name in commands.

### Genesis Behavior

Control core Genesis operational behavior.

#### embedded_genesis

| Option | Type | Default | Values |
|--------|------|---------|--------|
| `embedded_genesis` | enum | `ignore` | `ignore`, `check`, `warn` |

**Description**: Control behavior when detecting embedded Genesis installations.

**Values**:
- `ignore`: Don't check for embedded Genesis
- `check`: Check but don't warn users
- `warn`: Check and warn about embedded Genesis

**Example**:
```yaml
embedded_genesis: ignore
```

#### automatic_config_upgrade

| Option | Type | Default | Values | Environment Variable |
|--------|------|---------|--------|---------------------|
| `automatic_config_upgrade` | enum | `no` | `no`, `yes`, `silent` | `GENESIS_CONFIG_AUTOMATIC_UPGRADE` |

**Description**: Control automatic configuration file upgrades.

**Values**:
- `no`: Never automatically upgrade
- `yes`: Upgrade with user confirmation
- `silent`: Upgrade without prompting

**Example**:
```yaml
automatic_config_upgrade: no
```

### Display Configuration

Customize Genesis output and display.

#### output_style

| Option | Type | Default | Values |
|--------|------|---------|--------|
| `output_style` | enum | `plain` | `plain`, `fun`, `pointer` |

**Description**: Configure visual style of Genesis output.

**Values**:
- `plain`: Simple text output
- `fun`: Enhanced output with emojis and colors
- `pointer`: Output with pointer indicators

**Example**:
```yaml
output_style: fun
```

#### show_duration

| Option | Type | Default | Values | Environment Variable |
|--------|------|---------|--------|---------------------|
| `show_duration` | boolean | `false` | `true`, `false` | `GENESIS_SHOW_DURATION` |

**Description**: Display execution time for operations.

**Example**:
```yaml
show_duration: true
```

### Deployment Behavior

Control deployment-specific operations.

#### fix_on_deploy

| Option | Type | Default | Values | Environment Variable |
|--------|------|---------|--------|---------------------|
| `fix_on_deploy` | enum | `never` | `always`, `ask`, `never` | `GENESIS_FIX_ON_DEPLOY` |

**Description**: Automatically fix issues during deployment.

**Values**:
- `always`: Automatically fix without prompting
- `ask`: Prompt before fixing issues
- `never`: Never attempt automatic fixes

**Example**:
```yaml
fix_on_deploy: ask
```

#### confirm_release_overrides

| Option | Type | Default | Values | Environment Variable |
|--------|------|---------|--------|---------------------|
| `confirm_release_overrides` | enum | - | `always`, `outdated`, `never` | `GENESIS_CONFIRM_RELEASE_OVERRIDES` |

**Description**: When to confirm BOSH release overrides.

**Values**:
- `always`: Always confirm overrides
- `outdated`: Only confirm outdated releases
- `never`: Never confirm overrides

**Example**:
```yaml
confirm_release_overrides: outdated
```

### Cache and Storage

Configure caching and storage locations.

#### spec_cache_dir

| Option | Type | Default | Values | Environment Variable |
|--------|------|---------|--------|---------------------|
| `spec_cache_dir` | string | `""` | any path | `GENESIS_SPEC_CACHE_DIR` |

**Description**: Directory for caching specification files.

**Example**:
```yaml
spec_cache_dir: "/var/cache/genesis/specs"
```

#### bosh_logs_path

| Option | Type | Default | Values | Environment Variable |
|--------|------|---------|--------|---------------------|
| `bosh_logs_path` | string | `<DEPLOYMENT_ROOT>/bosh_logs` | path template | `GENESIS_DEPLOYMENT_LOGS_PATH` |

**Description**: Path template for BOSH deployment logs.

**Placeholders**:
- `<DEPLOYMENT_ROOT>`: Replaced with actual deployment root

**Example**:
```yaml
bosh_logs_path: "/var/log/genesis/<DEPLOYMENT_ROOT>/bosh_logs"
```

### Warning Suppression

Control which warnings Genesis displays.

#### suppress_warnings

| Option | Type | Default |
|--------|------|---------|
| `suppress_warnings` | hash | see below |

**Sub-options**:

| Warning | Type | Default | Environment Variable |
|---------|------|---------|---------------------|
| `oversized_secrets` | boolean | `false` | `GENESIS_SUPRESS_OVERSIZED_SECRETS_WARNING` |
| `bosh_target` | boolean | `false` | `GENESIS_SUPPRESS_BOSH_TARGET_WARNING` |

**Description**: Selectively suppress specific warnings.

**Example**:
```yaml
suppress_warnings:
  oversized_secrets: true
  bosh_target: false
```

### Logging Configuration

Configure detailed logging for Genesis operations.

#### logs

| Option | Type | Default |
|--------|------|---------|
| `logs` | array | `[]` |

**Description**: Array of log configurations, each defining a separate log destination.

**Log Entry Schema**:

| Option | Type | Default | Values | Required |
|--------|------|---------|--------|----------|
| `file` | string | - | any path | ✓ |
| `level` | enum | `INFO` | `TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR`, `OUTPUT` | |
| `show_stack` | enum | `default` | `default`, `none`, `full`, `current`, `fatal` | |
| `style` | enum | `plain` | `plain`, `fun`, `pointer`, `rfc-5424` | |
| `timestamp` | boolean | `false` | `true`, `false` | |
| `truncate` | boolean | `false` | `true`, `false` | *future* |
| `lifespan` | enum | `forever` | `forever`, `current`, `N days` | *future* |

**Log Levels**:
- `TRACE`: Most verbose, all operations
- `DEBUG`: Detailed debugging
- `INFO`: General information
- `WARN`: Warning messages
- `ERROR`: Error messages only
- `OUTPUT`: Command output only

**Stack Trace Options**:
- `default`: Based on log level
- `none`: Never show traces
- `full`: Always show full traces
- `current`: Current context only
- `fatal`: Fatal errors only

**Style Options**:
- `plain`: Simple text
- `fun`: Enhanced with colors
- `pointer`: Pointer indicators
- `rfc-5424`: Standard syslog format

**Example**:
```yaml
logs:
  # Main application log
  - file: "/var/log/genesis/genesis.log"
    level: INFO
    timestamp: true
    style: plain
    
  # Debug log
  - file: "/tmp/genesis-debug.log"
    level: DEBUG
    style: rfc-5424
    show_stack: full
    
  # Error log
  - file: "/var/log/genesis/errors.log"
    level: ERROR
    timestamp: true
    show_stack: fatal
```

## Complete Example Configuration

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
spec_cache_dir: "/var/cache/genesis/specs"
bosh_logs_path: "/var/log/genesis/bosh_logs"

# Warning suppression
suppress_warnings:
  oversized_secrets: false
  bosh_target: true

# Genesis behavior
embedded_genesis: warn
automatic_config_upgrade: yes

# Logging configuration
logs:
  # Main log
  - file: "/var/log/genesis/genesis.log"
    level: INFO
    timestamp: true
    style: plain
    
  # Debug log
  - file: "/tmp/genesis-debug.log"
    level: DEBUG
    style: rfc-5424
    timestamp: true
    show_stack: full
    
  # Error log
  - file: "/var/log/genesis/errors.log"
    level: ERROR
    timestamp: true
    show_stack: fatal
```

## Environment Variable Overrides

Most configuration options can be overridden using environment variables. When set, environment variables take precedence over configuration file settings.

### Override Examples

```bash
# Override BOSH target behavior
export GENESIS_DEFAULT_BOSH_TARGET=self

# Override deployment roots
export GENESIS_DEPLOYMENT_ROOTS="/alt/path;prod=/alt/prod"

# Override display settings
export GENESIS_SHOW_DURATION=true

# Override fix behavior
export GENESIS_FIX_ON_DEPLOY=always
```

### Available Environment Variables

- `GENESIS_DEFAULT_BOSH_TARGET`
- `GENESIS_LEGACY_REPO_SUFFIX`
- `GENESIS_DEPLOYMENT_ROOTS`
- `GENESIS_SHOW_DURATION`
- `GENESIS_CONFIG_AUTOMATIC_UPGRADE`
- `GENESIS_FIX_ON_DEPLOY`
- `GENESIS_CONFIRM_RELEASE_OVERRIDES`
- `GENESIS_SPEC_CACHE_DIR`
- `GENESIS_DEPLOYMENT_LOGS_PATH`
- `GENESIS_SUPRESS_OVERSIZED_SECRETS_WARNING`
- `GENESIS_SUPPRESS_BOSH_TARGET_WARNING`

## Configuration Validation

Genesis validates configuration on startup. Invalid configurations result in:
- Clear error messages
- Suggested corrections
- Refusal to run until fixed

### Common Validation Errors

1. **Invalid enum values**:
   ```yaml
   # ERROR: 'maybe' is not valid
   fix_on_deploy: maybe
   # Valid: always, ask, never
   ```

2. **Type mismatches**:
   ```yaml
   # ERROR: boolean expected
   show_duration: "yes"
   # Valid: true or false
   ```

3. **Invalid paths**:
   ```yaml
   # ERROR: must be array
   deployment_roots: "/single/path"
   # Valid: array format
   deployment_roots:
     - /single/path
   ```

## Advanced Usage

### Multiple Log Destinations

Configure comprehensive logging:

```yaml
logs:
  # Audit trail - everything
  - file: "/var/log/genesis/audit.log"
    level: INFO
    style: rfc-5424
    timestamp: true
    
  # Development debugging
  - file: "/tmp/genesis-trace.log"
    level: TRACE
    style: plain
    show_stack: full
    
  # Error monitoring
  - file: "/var/log/genesis/errors.log"
    level: ERROR
    style: plain
    timestamp: true
    show_stack: fatal
    
  # Operations log
  - file: "/var/log/genesis/ops.log"
    level: OUTPUT
    timestamp: true
```

### Environment-Specific Configuration

Use deployment roots with labels:

```yaml
deployment_roots:
  - local: ~/genesis/local
  - dev: /mnt/nfs/genesis/dev
  - staging: /mnt/nfs/genesis/staging
  - prod: /secure/genesis/prod
```

Then reference by label:
```bash
genesis @prod list
genesis @staging deploy my-env
```

### CI/CD Configuration

Optimize for automation:

```yaml
# Minimal output for CI
output_style: plain
show_duration: false

# No confirmations
fix_on_deploy: always
confirm_release_overrides: never
automatic_config_upgrade: silent

# Suppress warnings
suppress_warnings:
  oversized_secrets: true
  bosh_target: true

# Log everything
logs:
  - file: "/var/log/ci/genesis.log"
    level: DEBUG
    timestamp: true
    style: plain
```

## Migration Guide

### From Environment Variables

To migrate from environment variables to configuration file:

1. **Identify current variables**:
   ```bash
   env | grep GENESIS_
   ```

2. **Create configuration**:
   ```yaml
   # Map variables to config options
   default_bosh_target: parent  # from GENESIS_DEFAULT_BOSH_TARGET
   show_duration: true          # from GENESIS_SHOW_DURATION
   ```

3. **Test configuration**:
   ```bash
   # Unset variables
   unset GENESIS_DEFAULT_BOSH_TARGET
   # Test with config file
   genesis list
   ```

### Upgrading Configuration

When Genesis detects outdated configuration:

1. **Backup current config**:
   ```bash
   cp ~/.genesis/config ~/.genesis/config.backup
   ```

2. **Enable automatic upgrade**:
   ```yaml
   automatic_config_upgrade: yes
   ```

3. **Run Genesis command**:
   ```bash
   genesis version  # Triggers upgrade check
   ```

## Best Practices

1. **Version Control**: Keep configuration in version control for team consistency
2. **Comments**: Document configuration choices
3. **Environment Variables**: Use for temporary overrides only
4. **Logging**: Configure appropriate log levels for your needs
5. **Validation**: Test configuration changes before deploying
6. **Backups**: Keep backups before major changes

## Troubleshooting

### Configuration Not Loading

```bash
# Check file location
ls -la ~/.genesis/config

# Validate YAML syntax
yamllint ~/.genesis/config

# Test with trace logging
GENESIS_TRACE=1 genesis version
```

### Override Not Working

```bash
# Check environment variable
echo $GENESIS_DEFAULT_BOSH_TARGET

# Verify precedence (env vars override config)
unset GENESIS_DEFAULT_BOSH_TARGET
genesis version  # Now uses config value
```

### Permission Issues

```bash
# Fix permissions
chmod 600 ~/.genesis/config
chmod 700 ~/.genesis

# Check ownership
chown $(whoami) ~/.genesis/config
```