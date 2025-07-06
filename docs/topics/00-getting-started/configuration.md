# Basic Genesis Configuration

This guide covers essential Genesis configuration for new users. For a complete configuration reference, see the [Configuration Reference Guide](../90-reference-guides/configuration.md).

## Configuration File

Genesis stores its configuration in `~/.genesis/config` (YAML format).

```bash
# Create the configuration directory
mkdir -p ~/.genesis

# Create a basic configuration file
vim ~/.genesis/config
```

## Essential Settings

### BOSH Target Behavior

When deploying, Genesis needs to know which BOSH director to use. Configure the default behavior:

```yaml
---
# How to select BOSH directors when multiple options exist
default_bosh_target: ask  # ask, parent, or self
```

Options:
- **ask** - Prompt to select a director (recommended for beginners)
- **parent** - Use the director that deployed this environment
- **self** - Use this environment as the director (for BOSH directors)

### Deployment Roots

Organize your Genesis repositories in standard locations:

```yaml
deployment_roots:
  - ~/deployments        # Personal deployments
  - work: ~/work/deploy  # Work deployments (with label)
```

This helps Genesis:
- Find repositories with `genesis switch`
- Organize the `genesis list` output
- Provide better command completion

## Common Configurations

### For Development Environments

```yaml
---
default_bosh_target: ask

deployment_roots:
  - ~/dev/genesis

# Suppress warnings about embedded Genesis
embedded_genesis: ignore

# Automatically upgrade configs without prompting
automatic_config_upgrade: yes
```

### For Production Environments

```yaml
---
default_bosh_target: parent

deployment_roots:
  - prod: /opt/genesis/production
  - staging: /opt/genesis/staging

# Check for embedded Genesis issues
embedded_genesis: warn

# Never auto-upgrade configs
automatic_config_upgrade: no
```

### For CI/CD Systems

```yaml
---
default_bosh_target: parent

# Silent config upgrades for automation
automatic_config_upgrade: silent

# Use environment variables for dynamic config
# Set GENESIS_BOSH_ENVIRONMENT, GENESIS_VAULT_PREFIX, etc.
```

## Environment Variables

Genesis configuration can also be set via environment variables:

```bash
# Override config file settings
export GENESIS_DEFAULT_BOSH_TARGET=parent
export GENESIS_LEGACY_REPO_SUFFIX=false

# Set deployment roots
export GENESIS_DEPLOYMENT_ROOTS="$HOME/deployments;work=$HOME/work/deploy"

# Configure default behaviors
export GENESIS_CONFIG_AUTOMATIC_UPGRADE=yes
```

### Precedence

Environment variables take precedence over config file settings.

## Vault Configuration

While Vault settings are typically per-environment, you can set defaults:

```bash
# Default Vault server
export GENESIS_VAULT_SERVER=https://vault.example.com:8200

# Skip TLS verification (development only!)
export VAULT_SKIP_VERIFY=1
```

## Shell Completion

Enable command completion for better usability:

### Bash
```bash
echo 'source <(genesis completion bash)' >> ~/.bashrc
```

### Zsh
```bash
echo 'source <(genesis completion zsh)' >> ~/.zshrc
```

## Verifying Configuration

Check your configuration:

```bash
# Show effective configuration
genesis config

# Test BOSH connectivity
genesis ping

# List known deployments
genesis list
```

## Common Issues

### Permission Denied

If Genesis can't write to `~/.genesis/config`:
```bash
# Fix permissions
chmod 755 ~/.genesis
chmod 644 ~/.genesis/config
```

### Config Not Loading

Genesis looks for config in this order:
1. `$GENESIS_CONFIG_FILE` (if set)
2. `~/.genesis/config`
3. Built-in defaults

### Environment Variable Syntax

For arrays in environment variables, use `:` as separator:
```bash
# Multiple deployment roots
export GENESIS_DEPLOYMENT_ROOTS="/opt/genesis:$HOME/deployments"

# With labels, use = and ;
export GENESIS_DEPLOYMENT_ROOTS="prod=/opt/prod;dev=/opt/dev"
```

## Advanced Configuration

For more configuration options including:
- Pipeline automation settings
- Advanced BOSH configurations
- Custom hook behaviors
- Experimental features

See the [Complete Configuration Reference](../90-reference-guides/configuration.md).

## Next Steps

With Genesis configured:
- Create your [First Deployment](first-deployment.md)
- Learn about [Environment Management](../10-environments/index.md)
- Explore [Kit Selection](../50-kits/using-kits.md)