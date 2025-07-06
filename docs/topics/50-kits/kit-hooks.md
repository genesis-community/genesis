# Kit Hooks

Genesis hooks provide an extensible interface for customizing deployment behavior at various stages. They allow kit authors to inject custom code that executes during different phases of the deployment lifecycle.

## Overview

Genesis hooks are executable scripts (typically Bash) or Perl modules that extend Genesis functionality. Each hook serves a specific purpose in the deployment workflow and is invoked automatically by Genesis at the appropriate time.

## Hook Types

### Core Hooks (Bash Scripts)

Located in the `hooks/` directory of a kit:

#### new

Runs when creating a new environment with `genesis new`.

**Purpose**: Interactive environment setup, prompting for configuration values.

```bash
#!/bin/bash
# hooks/new
set -eu

# Prompt for required configuration
prompt_for base_domain \
  "What is your base domain?" \
  --validation "valid_domain"

# Feature selection
if features_enabled "ssl"; then
  prompt_for cert_path \
    "Path to SSL certificate?" \
    --default "/path/to/cert.pem"
fi
```

#### blueprint

Determines which manifest files to merge for the deployment.

**Purpose**: Build the ordered list of YAML files based on features.

```bash
#!/bin/bash
# hooks/blueprint
set -eu

# Always start with base
manifests=(manifests/base.yml)

# Add feature manifests
for want in $GENESIS_REQUESTED_FEATURES; do
  case $want in
    ha|monitoring|ssl)
      manifests+=(manifests/features/$want.yml)
      ;;
    aws|azure|gcp)
      manifests+=(manifests/iaas/$want.yml)
      ;;
  esac
done

# Output the list
printf "%s\n" "${manifests[@]}"
```

#### check

Validates the environment before deployment.

**Purpose**: Pre-deployment validation of configuration and requirements.

```bash
#!/bin/bash
# hooks/check
set -eu

# Validate cloud config
vm_type=$(lookup params.vm_type default)
if ! cloud_config_has vm_type "$vm_type"; then
  echo >&2 "VM type '$vm_type' not found in cloud config"
  exit 1
fi

# Check secrets
if want_feature "provided-cert" && ! safe exists "$VAULT_PREFIX/ssl/cert"; then
  echo >&2 "Feature 'provided-cert' requires certificate in Vault"
  exit 1
fi
```

#### secrets

Manages secrets beyond what's defined in kit.yml.

**Purpose**: Handle complex secret generation or rotation scenarios.

```bash
#!/bin/bash
# hooks/secrets
set -eu

case $GENESIS_SECRET_ACTION in
  add)
    # Generate additional secrets
    if want_feature "custom-ca"; then
      safe x509 ca "$VAULT_PREFIX/custom/ca" \
        --ttl 10y \
        --subject "/CN=Custom CA"
    fi
    ;;
    
  rotate)
    # Custom rotation logic
    ;;
esac
```

#### info

Displays deployment information after successful deployment.

**Purpose**: Show URLs, credentials, and next steps.

```bash
#!/bin/bash
# hooks/info
set -eu

echo "Deployment Information:"
echo
echo "URL: https://$(lookup params.base_domain)"
echo "Username: admin"
echo "Password: $(safe get "$VAULT_PREFIX/admin:password")"
echo
echo "To access the dashboard, run:"
echo "  genesis do $GENESIS_ENVIRONMENT dashboard"
```

#### addon

Provides operational commands via `genesis do`.

**Purpose**: Extend Genesis with kit-specific operations.

```bash
#!/bin/bash
# hooks/addon
set -eu

case $GENESIS_ADDON_SCRIPT in
  list)
    echo "Available addons:"
    echo "  login    - Log into the system"
    echo "  backup   - Run a backup"
    echo "  restore  - Restore from backup"
    ;;
    
  login)
    url="https://$(lookup params.base_domain)"
    password=$(safe get "$VAULT_PREFIX/admin:password")
    echo "Logging into $url..."
    # Login logic here
    ;;
    
  backup)
    echo "Starting backup..."
    $GENESIS_BOSH_COMMAND -d "$BOSH_DEPLOYMENT" run-errand backup
    ;;
    
  *)
    echo >&2 "Unknown addon: $GENESIS_ADDON_SCRIPT"
    exit 1
    ;;
esac
```

#### pre-deploy

Runs before deployment begins.

**Purpose**: Final validation, data collection for post-deploy.

```bash
#!/bin/bash
# hooks/pre-deploy
set -eu

# Collect current state
echo "Current version: $(get_deployed_version)" > "$GENESIS_PREDEPLOY_DATAFILE"

# Final checks
if deploying_major_version_change; then
  echo "WARNING: Major version upgrade detected!"
  if [[ "$GENESIS_DEPLOY_CONFIRM" != "yes" ]]; then
    read -p "Continue? [y/N] " confirm
    [[ "$confirm" == "y" ]] || exit 1
  fi
fi
```

#### post-deploy

Runs after deployment (successful or failed).

**Purpose**: Cleanup, notifications, follow-up tasks.

```bash
#!/bin/bash
# hooks/post-deploy
set -eu

if [[ "$GENESIS_DEPLOY_RC" == "0" ]]; then
  echo "Deployment successful!"
  
  # Run smoke tests
  $GENESIS_BOSH_COMMAND -d "$BOSH_DEPLOYMENT" run-errand smoke-tests
  
  # Update DNS
  update_dns_records "$(lookup params.base_domain)"
else
  echo "Deployment failed - check logs"
  notify_ops_team "Deployment of $GENESIS_ENVIRONMENT failed"
fi
```

### Advanced Hooks (Perl Modules)

For complex kits, hooks can be written as Perl modules:

#### Addon Hook Module

```perl
package Genesis::Hook::Addon::MyKit::backup;
use parent qw(Genesis::Hook::Addon);

sub init {
  my $class = shift;
  my $obj = $class->SUPER::init(@_);
  $obj->check_minimum_genesis_version('3.1.0');
  return $obj;
}

sub perform {
  my ($self) = @_;
  
  # Parse options
  my %options = $self->parse_options(['force']);
  
  # Execute backup
  my $result = $self->env->bosh->run_errand('backup');
  
  return $self->done($result);
}

sub cmd_details {
  return "Performs a backup of the deployment";
}

1;
```

## Hook Environment Variables

Hooks have access to these environment variables:

### Always Available

- `GENESIS_ROOT` - Repository root directory
- `GENESIS_ENVIRONMENT` - Environment name
- `GENESIS_VAULT_PREFIX` - Vault path prefix
- `GENESIS_KIT_NAME` - Kit name
- `GENESIS_KIT_VERSION` - Kit version
- `GENESIS_REQUESTED_FEATURES` - Space-separated feature list

### Hook-Specific

#### new Hook
- `GENESIS_MIN_VERSION` - Minimum Genesis version required

#### blueprint Hook
- `GENESIS_REQUESTED_FEATURES` - Features to enable

#### addon Hook
- `GENESIS_ADDON_SCRIPT` - Addon being executed
- `GENESIS_ADDON_ARGS` - Arguments passed to addon

#### pre-deploy Hook
- `GENESIS_PREDEPLOY_DATAFILE` - File for storing pre-deploy data
- `GENESIS_MANIFEST_FILE` - Path to deployment manifest
- `GENESIS_DEPLOY_OPTIONS` - JSON deployment options

#### post-deploy Hook
- `GENESIS_DEPLOY_RC` - Deployment return code (0=success)
- `GENESIS_PREDEPLOY_DATAFILE` - Pre-deploy data file

## Helper Functions

Genesis provides Bash helper functions for hooks:

### Prompting Functions

```bash
# Basic prompt
prompt_for varname "Question?"

# With default
prompt_for_or_use_default varname "default" "Question?"

# With validation
prompt_for varname "Question?" \
  --validation "/^[a-z]+$/"

# Multiple choice
choose varname \
  "option1" "Description 1" \
  "option2" "Description 2"
```

### Lookup Functions

```bash
# Get parameter value
value=$(lookup params.key default_value)

# Check if parameter exists
if param_exists params.key; then
  # Parameter is set
fi
```

### Feature Functions

```bash
# Check if feature is enabled
if want_feature "monitoring"; then
  # Add monitoring configuration
fi

# Check multiple features
if features_enabled "ha" "ssl"; then
  # Both features enabled
fi
```

### Cloud Config Functions

```bash
# Check if resource exists
if cloud_config_has vm_type "large"; then
  # VM type exists
fi

# Get cloud config value
network=$(cloud_config_get networks.0.name)
```

## Best Practices

### 1. Error Handling

Always use proper error handling:

```bash
#!/bin/bash
set -eu  # Exit on error, undefined variables

# Explicit error checking
if ! command_that_might_fail; then
  echo >&2 "ERROR: Command failed"
  exit 1
fi
```

### 2. User-Friendly Output

Use color and formatting:

```bash
# Use describe for formatted output
describe "Setting up #C{My Software} deployment"

# Success messages
success "Deployment configured successfully!"

# Warnings
warning "Using default configuration"

# Errors
error "Missing required parameter"
```

### 3. Idempotency

Make hooks idempotent when possible:

```bash
# Check before creating
if ! safe exists "$VAULT_PREFIX/generated"; then
  safe gen "$VAULT_PREFIX/generated" password
fi
```

### 4. Validation

Validate early and clearly:

```bash
# In check hook
errors=()

[[ -n "${base_domain:-}" ]] || errors+=("Missing base_domain")
[[ -n "${instances:-}" ]] || errors+=("Missing instances")

if [[ ${#errors[@]} -gt 0 ]]; then
  printf "Validation errors:\n" >&2
  printf "  - %s\n" "${errors[@]}" >&2
  exit 1
fi
```

### 5. Documentation

Document complex logic:

```bash
# Feature compatibility matrix:
# - 'ha' requires minimum 3 instances
# - 'ssl' conflicts with 'self-signed'
# - 'monitoring' adds Prometheus exporters
```

## Testing Hooks

Test hooks during development:

```bash
# Test blueprint hook
cd my-kit
export GENESIS_REQUESTED_FEATURES="ha monitoring"
./hooks/blueprint

# Test addon hook
export GENESIS_ADDON_SCRIPT="backup"
export GENESIS_ENVIRONMENT="test"
./hooks/addon

# Test with Genesis
genesis new test-env --kit ./
```

## Common Patterns

### Feature Detection

```bash
# Single feature
if want_feature "ssl"; then
  add_ssl_configuration
fi

# Multiple features (OR)
if want_feature "mysql" || want_feature "postgres"; then
  configure_database
fi

# Multiple features (AND)
if want_feature "ha" && want_feature "ssl"; then
  configure_ha_ssl
fi
```

### Dynamic Manifest Building

```bash
#!/bin/bash
# hooks/blueprint

manifests=(manifests/base.yml)

# IaaS-specific
case "$(iaas)" in
  aws)   manifests+=(manifests/iaas/aws.yml) ;;
  azure) manifests+=(manifests/iaas/azure.yml) ;;
  *)     manifests+=(manifests/iaas/generic.yml) ;;
esac

# Optional features
for feature in $GENESIS_REQUESTED_FEATURES; do
  [[ -f "manifests/features/$feature.yml" ]] && \
    manifests+=(manifests/features/$feature.yml)
done

printf "%s\n" "${manifests[@]}"
```

### Conditional Parameters

```bash
# In new hook
if want_feature "ha"; then
  prompt_for instances \
    "Number of instances (minimum 3 for HA)?" \
    --validation "/^[3-9][0-9]*$/"
else
  prompt_for instances \
    "Number of instances?" \
    --default 1
fi
```

Hooks are the key to creating flexible, user-friendly Genesis kits that encode operational knowledge while remaining adaptable to different deployment scenarios.