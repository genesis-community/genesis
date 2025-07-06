# Hook Reference

This document provides a complete reference for all Genesis hooks, their parameters, environment variables, and usage patterns.

## Hook Types

Genesis supports two types of hooks:

1. **Bash Scripts** - Traditional shell scripts in the `hooks/` directory
2. **Perl Modules** - Advanced hooks using Genesis::Hook modules

## Hook Execution Order

During a typical deployment, hooks execute in this order:

1. `new` - When creating a new environment
2. `blueprint` - To determine manifest files
3. `secrets` - To check/add/rotate secrets
4. `check` - Pre-deployment validation
5. `pre-deploy` - Just before deployment
6. `deploy` - (Internal - not a hook)
7. `post-deploy` - After deployment
8. `info` - Display deployment information

## Core Hooks

### new

**Purpose**: Interactive environment setup when running `genesis new`

**Type**: Bash script

**Environment Variables**:
```bash
GENESIS_ROOT              # Repository root directory
GENESIS_ENVIRONMENT       # Environment name
GENESIS_SECRETS_PATH      # Vault secrets path
GENESIS_VAULT_PREFIX      # Legacy: Vault prefix
GENESIS_KIT_NAME          # Kit name
GENESIS_KIT_VERSION       # Kit version
GENESIS_MIN_VERSION       # Minimum Genesis version
```

**Helper Functions**:
- `prompt_for` - Interactive prompting
- `genesis_config_block` - Generate Genesis config
- `offer_environment_editor` - Offer to edit file

**Example**:
```bash
#!/bin/bash
set -eu

prompt_for base_domain line \
  "What is your base domain?" \
  --default "example.com" \
  --validation dns

cat > "$GENESIS_ROOT/$GENESIS_ENVIRONMENT.yml" <<EOF
$(genesis_config_block)

kit:
  features: []

params:
  base_domain: $base_domain
EOF

offer_environment_editor
```

### blueprint

**Purpose**: Determine which manifest files to merge

**Type**: Bash script or Perl module

**Environment Variables**:
```bash
GENESIS_REQUESTED_FEATURES  # Space-separated feature list
GENESIS_KIT_NAME
GENESIS_KIT_VERSION
```

**Output**: List of manifest files, one per line

**Example (Bash)**:
```bash
#!/bin/bash
set -eu

echo "manifests/base.yml"

for feature in $GENESIS_REQUESTED_FEATURES; do
  case "$feature" in
    ha|monitoring|ssl)
      echo "manifests/features/$feature.yml"
      ;;
    *)
      echo >&2 "Error: Unknown feature '$feature'"
      exit 1
      ;;
  esac
done
```

**Example (Perl)**:
```perl
package Genesis::Hook::Blueprint::MyKit;
use parent qw(Genesis::Hook::Blueprint);

sub perform {
  my ($self) = @_;
  
  $self->add_files("base.yml");
  $self->add_files("features/ha.yml") if $self->want_feature('ha');
  
  return $self->done(1);
}
1;
```

### secrets

**Purpose**: Manage secrets beyond kit.yml definitions

**Type**: Bash script

**Environment Variables**:
```bash
GENESIS_SECRET_ACTION     # add, check, rotate
GENESIS_ENVIRONMENT
GENESIS_SECRETS_PATH
GENESIS_KIT_NAME
```

**Example**:
```bash
#!/bin/bash
set -eu

case "${GENESIS_SECRET_ACTION}" in
  add)
    # Generate additional secrets
    if want_feature "custom-ca"; then
      safe x509 issue "$GENESIS_SECRETS_PATH/custom-ca" \
        --signed-by "$GENESIS_SECRETS_PATH/ca" \
        --ttl 365d \
        --subject "/CN=Custom CA"
    fi
    ;;
    
  check)
    # Validate secrets exist
    if want_feature "provided-cert"; then
      safe exists "$GENESIS_SECRETS_PATH/ssl/cert" || \
        echo >&2 "Missing provided certificate"
    fi
    ;;
    
  rotate)
    # Rotate specific secrets
    safe regen "$GENESIS_SECRETS_PATH/api-key"
    ;;
esac
```

### check

**Purpose**: Pre-deployment validation

**Type**: Bash script

**Environment Variables**:
```bash
GENESIS_ENVIRONMENT
GENESIS_CLOUD_CONFIG      # Cloud config YAML
GENESIS_KIT_NAME
GENESIS_REQUESTED_FEATURES
```

**Helper Functions**:
- `cloud_config_has` - Check cloud config resources
- `lookup` - Get parameter values
- `want_feature` - Check if feature enabled

**Example**:
```bash
#!/bin/bash
set -eu

# Check VM types
vm_type=$(lookup params.vm_type default)
if ! cloud_config_has vm_type "$vm_type"; then
  echo >&2 "Error: VM type '$vm_type' not found in cloud config"
  exit 1
fi

# Check networks
network=$(lookup params.network default)
if ! cloud_config_has network "$network"; then
  echo >&2 "Error: Network '$network' not found"
  exit 1
fi

# Feature-specific checks
if want_feature "ha"; then
  instances=$(lookup params.instances 1)
  if [[ $instances -lt 3 ]]; then
    echo >&2 "Error: HA requires at least 3 instances"
    exit 1
  fi
fi
```

### pre-deploy

**Purpose**: Final actions before deployment

**Type**: Bash script

**Environment Variables**:
```bash
GENESIS_PREDEPLOY_DATAFILE   # File to store data
GENESIS_MANIFEST_FILE        # Full manifest path
GENESIS_DEPLOY_OPTIONS       # JSON deployment options
GENESIS_ENVIRONMENT
```

**Example**:
```bash
#!/bin/bash
set -eu

# Store current state
echo "timestamp: $(date -u +%s)" > "$GENESIS_PREDEPLOY_DATAFILE"
echo "version: $(get_deployed_version)" >> "$GENESIS_PREDEPLOY_DATAFILE"

# Validate major version upgrade
if is_major_upgrade; then
  if [[ "${GENESIS_CONFIRM:-}" != "yes" ]]; then
    describe "" \
      "WARNING: Major version upgrade detected!" \
      "This may require manual intervention."
    
    prompt_for confirm boolean \
      "Continue with deployment?"
    
    [[ "$confirm" == "true" ]] || exit 1
  fi
fi

# Run pre-deployment tasks
if deployment_exists; then
  bosh -d "$BOSH_DEPLOYMENT" run-errand pre-upgrade || true
fi
```

### post-deploy

**Purpose**: Actions after deployment completes

**Type**: Bash script or Perl module

**Environment Variables**:
```bash
GENESIS_DEPLOY_RC           # Deployment return code
GENESIS_PREDEPLOY_DATAFILE  # Pre-deploy data
GENESIS_ENVIRONMENT
GENESIS_CALL_BIN           # Genesis binary path
```

**Example (Bash)**:
```bash
#!/bin/bash
set -eu

if [[ "$GENESIS_DEPLOY_RC" != "0" ]]; then
  echo "Deployment failed - skipping post-deploy actions"
  exit 0
fi

# Run smoke tests
describe "Running smoke tests..."
bosh -d "$BOSH_DEPLOYMENT" run-errand smoke-tests

# Update DNS
if want_feature "external-dns"; then
  update_external_dns "$(lookup params.external_url)"
fi

# Display success
describe "" "Deployment successful!"
```

**Example (Perl)**:
```perl
package Genesis::Hook::PostDeploy::MyKit;
use parent qw(Genesis::Hook::PostDeploy);

sub perform {
  my ($self) = @_;
  
  return 0 unless $self->deploy_successful;
  
  $self->run_errand('smoke-tests');
  $self->upload_runtime_configs if $self->config('runtime');
  
  return $self->done(1);
}
1;
```

### info

**Purpose**: Display deployment information

**Type**: Bash script

**Environment Variables**:
```bash
GENESIS_ENVIRONMENT
GENESIS_SECRETS_PATH
BOSH_DEPLOYMENT          # BOSH deployment name
```

**Example**:
```bash
#!/bin/bash
set -eu

base_url="https://$(lookup params.base_domain)"
username="admin"
password="$(safe get $GENESIS_SECRETS_PATH/admin:password)"

describe "" \
  "Deployment Information" \
  "" \
  "  URL:      $base_url" \
  "  Username: $username" \
  "  Password: $password" \
  "" \
  "To access the dashboard:" \
  "  genesis do $GENESIS_ENVIRONMENT login"
```

### addon

**Purpose**: Provide additional commands via `genesis do`

**Type**: Bash script or Perl module

**Environment Variables**:
```bash
GENESIS_ADDON_SCRIPT     # Addon being executed
GENESIS_ADDON_ARGS       # Arguments array
GENESIS_ENVIRONMENT
GENESIS_SECRETS_PATH
```

**Example (Bash)**:
```bash
#!/bin/bash
set -eu

case "$GENESIS_ADDON_SCRIPT" in
  list)
    echo "Available addons:"
    echo "  login    - Log into the system"
    echo "  backup   - Perform backup"
    echo "  restore  - Restore from backup"
    ;;
    
  login)
    url="https://$(lookup params.base_domain)"
    password="$(safe get $GENESIS_SECRETS_PATH/admin:password)"
    
    echo "Logging into $url..."
    open "$url" || xdg-open "$url"
    echo "Password: $password"
    ;;
    
  backup)
    bosh -d "$BOSH_DEPLOYMENT" run-errand backup
    ;;
    
  restore)
    backup_file="${1:?Usage: genesis do $GENESIS_ENVIRONMENT restore <backup-file>}"
    bosh -d "$BOSH_DEPLOYMENT" run-errand restore -v "backup_file=$backup_file"
    ;;
    
  *)
    echo >&2 "Error: Unknown addon '$GENESIS_ADDON_SCRIPT'"
    exit 1
    ;;
esac
```

**Example (Perl)**:
```perl
package Genesis::Hook::Addon::MyKit::backup;
use parent qw(Genesis::Hook::Addon);

sub init {
  my $class = shift;
  my $obj = $class->SUPER::init(@_);
  $obj->parse_options(['full', 'incremental']);
  return $obj;
}

sub perform {
  my ($self) = @_;
  
  my $type = $self->has_option('incremental') ? 'incremental' : 'full';
  my $result = $self->bosh->run_errand("backup-$type");
  
  return $self->done($result);
}

sub cmd_details {
  return "Perform system backup (--full or --incremental)";
}
1;
```

## Helper Functions Reference

### Prompting Functions

```bash
# Basic prompt
prompt_for varname "Question?"

# With default
prompt_for varname line "Question?" --default "value"

# With validation
prompt_for varname line "Question?" \
  --validation ip \
  --validation port \
  --validation dns \
  --validation url \
  --validation email \
  --validation "/^[A-Z]+$/"

# Boolean prompt
prompt_for confirm boolean "Continue?" --default y

# Selection menu
prompt_for choice select "Choose:" \
  -o "[option1] First Option" \
  -o "[option2] Second Option"

# Multi-line input
prompt_for content block "Enter content (Ctrl-D to finish):"

# Secret prompts
prompt_for "$GENESIS_SECRETS_PATH/password" secret-line \
  "Enter password:"

prompt_for "$GENESIS_SECRETS_PATH/cert" secret-block \
  "Paste certificate:"
```

### Lookup Functions

```bash
# Get parameter value with default
value=$(lookup params.key default_value)

# Check if parameter exists
if param_exists params.key; then
  echo "Parameter is set"
fi

# Get deployment name
deployment=$(lookup genesis.bosh_deployment)
```

### Feature Functions

```bash
# Check single feature
if want_feature "monitoring"; then
  echo "Monitoring enabled"
fi

# Check multiple features
if features_enabled "ha" "ssl"; then
  echo "Both HA and SSL enabled"
fi

# Get feature list
for feature in $GENESIS_REQUESTED_FEATURES; do
  echo "Feature: $feature"
done
```

### Cloud Config Functions

```bash
# Check VM type exists
if cloud_config_has vm_type "large"; then
  echo "Large VM type available"
fi

# Check network
if cloud_config_has network "default"; then
  echo "Default network exists"
fi

# Check disk type
if cloud_config_has disk_type "ssd"; then
  echo "SSD disk type available"
fi

# Get cloud config value
value=$(cloud_config_get networks.0.name)
```

### Output Functions

```bash
# Formatted output
describe "Setting up deployment"
describe "" "Line 1" "Line 2" "Line 3"

# Colored output
echo "$(green "Success"): Operation completed"
echo "$(yellow "Warning"): Check configuration"
echo "$(red "Error"): Operation failed"

# Stylized output
header "Deployment Configuration"
bullet "First item"
bullet "Second item"
```

## Environment Variables Reference

### Always Available

| Variable | Description |
|----------|-------------|
| `GENESIS_ROOT` | Repository root directory |
| `GENESIS_ENVIRONMENT` | Environment name |
| `GENESIS_KIT_NAME` | Kit name |
| `GENESIS_KIT_VERSION` | Kit version |
| `GENESIS_SECRETS_PATH` | Vault secrets base path |
| `GENESIS_VAULT_PREFIX` | Legacy Vault prefix |

### Hook-Specific

| Hook | Variables |
|------|-----------|
| `new` | `GENESIS_MIN_VERSION` |
| `blueprint` | `GENESIS_REQUESTED_FEATURES` |
| `secrets` | `GENESIS_SECRET_ACTION` |
| `check` | `GENESIS_CLOUD_CONFIG` |
| `pre-deploy` | `GENESIS_PREDEPLOY_DATAFILE`, `GENESIS_MANIFEST_FILE`, `GENESIS_DEPLOY_OPTIONS` |
| `post-deploy` | `GENESIS_DEPLOY_RC`, `GENESIS_PREDEPLOY_DATAFILE` |
| `addon` | `GENESIS_ADDON_SCRIPT`, `GENESIS_ADDON_ARGS` |

### BOSH Variables

When in BOSH context:

| Variable | Description |
|----------|-------------|
| `BOSH_ENVIRONMENT` | BOSH director URL |
| `BOSH_CLIENT` | BOSH authentication client |
| `BOSH_CLIENT_SECRET` | BOSH authentication secret |
| `BOSH_CA_CERT` | BOSH CA certificate |
| `BOSH_DEPLOYMENT` | Deployment name |

## Best Practices

### 1. Error Handling

Always use proper error handling:

```bash
#!/bin/bash
set -eu  # Exit on error, undefined variables

# Explicit error checking
if ! command_that_might_fail; then
  echo >&2 "Error: Command failed"
  exit 1
fi
```

### 2. Idempotency

Make hooks idempotent:

```bash
# Check before creating
if ! safe exists "$GENESIS_SECRETS_PATH/generated"; then
  safe gen "$GENESIS_SECRETS_PATH/generated" password
fi

# Check before running errands
if ! errand_has_run "configure-database"; then
  bosh -d "$BOSH_DEPLOYMENT" run-errand configure-database
fi
```

### 3. User Communication

Provide clear feedback:

```bash
describe "Validating deployment configuration..."

# Detailed progress
describe "✓ Cloud config validated"
describe "✓ Secrets present"
describe "✓ Network connectivity confirmed"

# Errors with context
if [[ $error ]]; then
  describe "" \
    "$(red "ERROR"): Deployment validation failed" \
    "" \
    "  Missing VM type: $vm_type" \
    "  Please update your cloud config" \
    "" \
    "Run: bosh update-cloud-config"
fi
```

### 4. Feature Validation

Validate feature combinations:

```bash
# Check incompatible features
if want_feature "standalone" && want_feature "ha"; then
  echo >&2 "Error: Cannot use both 'standalone' and 'ha' features"
  exit 1
fi

# Check required parameters for features
if want_feature "ssl"; then
  if ! param_exists params.certificate; then
    echo >&2 "Error: SSL feature requires params.certificate"
    exit 1
  fi
fi
```

### 5. Documentation

Document complex logic:

```bash
# This check ensures that HA deployments have sufficient
# instances across multiple AZs for proper redundancy
if want_feature "ha"; then
  # Minimum 3 instances for quorum
  # Should be odd number to prevent split-brain
  # Distributed across AZs for fault tolerance
fi
```

Hooks provide the extensibility that makes Genesis kits powerful and flexible. Understanding their capabilities enables creating sophisticated deployment automation.