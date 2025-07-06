# Writing Kit Hooks

This guide provides detailed information on writing Genesis kit hooks, with a focus on the `new` hook which handles interactive environment creation.

## Hook Development Basics

### Script Setup

All hooks should start with proper error handling:

```bash
#!/bin/bash
set -eu  # Exit on error, undefined variables
```

### Environment Variables

Genesis provides these environment variables to all hooks:

```bash
# Core variables
GENESIS_ROOT          # Repository root directory
GENESIS_ENVIRONMENT   # Environment name
GENESIS_VAULT_PREFIX  # Vault path prefix (legacy)
GENESIS_SECRETS_PATH  # Vault path prefix (preferred)
GENESIS_KIT_NAME      # Kit name
GENESIS_KIT_VERSION   # Kit version

# Hook-specific variables vary by hook type
```

## Writing the `new` Hook

The `new` hook is executed when creating a new environment with `genesis new`. It interacts with users to gather configuration and generates the environment YAML file.

### Basic Structure

```bash
#!/bin/bash
set -eu

# Modern approach (Genesis 2.6.13+)
# No positional arguments needed

# Generate environment file
cat > "$GENESIS_ROOT/$GENESIS_ENVIRONMENT.yml" <<EOF
$(genesis_config_block)

kit:
  features: []

params:
  # Kit-specific parameters
EOF

# Offer to edit the file
offer_environment_editor
```

### Legacy Support

For kits supporting older Genesis versions:

```bash
#!/bin/bash
set -eu

# Legacy positional arguments
root=$1      # absolute path to deployments directory
name=$2      # name of the new environment
prefix=$3    # vault prefix for storing secrets

# Use environment variables if available
root=${GENESIS_ROOT:-$root}
name=${GENESIS_ENVIRONMENT:-$name}
prefix=${GENESIS_SECRETS_PATH:-${GENESIS_VAULT_PREFIX:-$prefix}}
```

## The `prompt_for` Helper

`prompt_for` is the primary helper for user interaction.

### Basic Usage

```bash
prompt_for VARNAME type "Question to ask" [OPTIONS]
```

### Prompt Types

#### boolean - Yes/No Questions

```bash
prompt_for use_ssl boolean \
  'Do you want to enable SSL/TLS?'

# Options:
# --default=[yn]  - Default answer if user presses enter
# --invert        - Swap true/false values

# Result: Sets variable to "true" or "false" (strings)
if [[ $use_ssl == "true" ]]; then
  echo "SSL enabled"
fi
```

#### line - Single Line Input

```bash
prompt_for domain line \
  'What is your base domain?' \
  --default 'example.com' \
  --validation dns

# Validation options:
# ip              - Valid IP address
# url             - Valid URL
# port            - Port number (1-65535)
# dns             - Valid DNS name
# 1-10            - Numeric range
# /^[a-z]+$/      - Regex pattern
# !/^test/        - Negated regex
```

#### block - Multi-line Input

```bash
prompt_for ssl_cert block \
  'Paste your SSL certificate (Ctrl-D when done):'

# No options supported
# User enters Ctrl-D to finish
```

#### select - Menu Selection

```bash
prompt_for iaas select \
  'Select your infrastructure:' \
  -o '[aws]      Amazon Web Services' \
  -o '[azure]    Microsoft Azure' \
  -o '[gcp]      Google Cloud Platform' \
  -o '[vsphere]  VMware vSphere'

# Options:
# --default VALUE   - Default selection
# --label TEXT      - Prompt label (default: "Select choice")
# -o/--option       - Menu option (required, multiple)
```

#### secret-line / secret-block - Secure Storage

```bash
# Store in Vault instead of environment file
prompt_for "$GENESIS_SECRETS_PATH/api:key" secret-line \
  'Enter your API key:' \
  --validation '/^[A-Za-z0-9]{32}$/'

prompt_for "$GENESIS_SECRETS_PATH/ssl:cert" secret-block \
  'Paste your SSL certificate:'

# Reference in environment file:
echo "api_key: (( vault \"$GENESIS_SECRETS_PATH/api:key\" ))"
```

## Advanced Prompting Patterns

### Conditional Questions

```bash
prompt_for use_ha boolean 'Enable High Availability?'

if [[ $use_ha == "true" ]]; then
  prompt_for instances line \
    'How many instances? (minimum 3 for HA)' \
    --default 3 \
    --validation '3-'
else
  instances=1
fi
```

### Dynamic Defaults

```bash
# Set default based on previous answer
if [[ $iaas == "aws" ]]; then
  default_vm="t3.small"
else
  default_vm="small"
fi

prompt_for vm_type line \
  'What VM type to use?' \
  --default "$default_vm"
```

### Feature Detection

```bash
features=()

prompt_for use_monitoring boolean \
  'Enable Prometheus monitoring?'
  
[[ $use_monitoring == "true" ]] && features+=("monitoring")

prompt_for use_backups boolean \
  'Enable automated backups?'
  
[[ $use_backups == "true" ]] && features+=("shield")
```

## Helper Functions

### Configuration Helpers

```bash
# Generate standard Genesis configuration block
genesis_config_block

# Output:
# genesis:
#   env:          "environment-name"
#   secrets_path: "secret/path"
#   min_version:  "2.8.0"
```

### Editor Helper

```bash
# Let user edit the generated file
offer_environment_editor

# Shows editor with kit manual on side (if supported)
# Prompts user before opening
```

### Custom Helpers

Create your own helper functions:

```bash
validate_ip() {
  local ip=$1
  if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    return 0
  fi
  return 1
}

select_vm_type() {
  local iaas=$1
  case $iaas in
    aws)   echo "t3.small" ;;
    azure) echo "Standard_B2s" ;;
    gcp)   echo "n1-standard-1" ;;
    *)     echo "small" ;;
  esac
}
```

## Complete Example

Here's a complete `new` hook for a hypothetical application:

```bash
#!/bin/bash
set -eu

# Initialize features array
features=()

# Basic configuration
describe "Setting up new deployment of My Application"
echo

prompt_for base_domain line \
  'What is your base domain?' \
  --validation dns \
  --default 'example.com'

# Infrastructure selection
prompt_for iaas select \
  'Which infrastructure are you using?' \
  -o '[aws]     Amazon Web Services' \
  -o '[azure]   Microsoft Azure' \
  -o '[vsphere] VMware vSphere'

features+=("$iaas")

# High availability
prompt_for use_ha boolean \
  'Do you want High Availability?'

instances=1
if [[ $use_ha == "true" ]]; then
  features+=("ha")
  prompt_for instances line \
    'How many instances? (minimum 3)' \
    --default 3 \
    --validation '3-'
fi

# SSL/TLS configuration
prompt_for ssl_mode select \
  'How do you want to handle SSL certificates?' \
  -o '[self-signed] Generate self-signed certificate' \
  -o '[provided]    I will provide a certificate' \
  -o '[lets-encrypt] Use Lets Encrypt'

case $ssl_mode in
  self-signed)
    features+=("self-signed-cert")
    ;;
  provided)
    features+=("provided-cert")
    prompt_for "$GENESIS_SECRETS_PATH/ssl:key" secret-block \
      'Paste your SSL private key:'
    prompt_for "$GENESIS_SECRETS_PATH/ssl:cert" secret-block \
      'Paste your SSL certificate:'
    ;;
  lets-encrypt)
    features+=("lets-encrypt")
    prompt_for le_email line \
      'Email for Lets Encrypt notifications:' \
      --validation email
    ;;
esac

# Optional features
prompt_for use_monitoring boolean \
  'Enable Prometheus monitoring?' \
  --default y

[[ $use_monitoring == "true" ]] && features+=("monitoring")

# Generate environment file
cat > "$GENESIS_ROOT/$GENESIS_ENVIRONMENT.yml" <<EOF
$(genesis_config_block)

kit:
  features:
$(for f in "${features[@]}"; do echo "    - $f"; done)

params:
  # Basic configuration
  base_domain: $base_domain
  
  # Sizing
  instances: $instances
  vm_type: $(select_vm_type $iaas)
EOF

# Add conditional parameters
if [[ $ssl_mode == "provided" ]]; then
  cat >> "$GENESIS_ROOT/$GENESIS_ENVIRONMENT.yml" <<EOF
  
  # SSL Configuration (certificates in Vault)
  ssl_key:  (( vault "$GENESIS_SECRETS_PATH/ssl:key" ))
  ssl_cert: (( vault "$GENESIS_SECRETS_PATH/ssl:cert" ))
EOF
elif [[ $ssl_mode == "lets-encrypt" ]]; then
  cat >> "$GENESIS_ROOT/$GENESIS_ENVIRONMENT.yml" <<EOF
  
  # Lets Encrypt Configuration
  lets_encrypt_email: $le_email
EOF
fi

# Offer to edit
describe ""
describe "Environment file generated!"
offer_environment_editor
```

## Best Practices

### 1. User Experience

- Provide clear, concise questions
- Use sensible defaults
- Group related questions
- Show progress/context

### 2. Validation

- Validate input early
- Provide helpful error messages
- Use appropriate validation types
- Consider edge cases

### 3. Documentation

```bash
# Document complex logic
# This determines the number of instances based on:
# - HA requirement (minimum 3)
# - IaaS limitations (AWS max 5 in placement group)
# - Cost considerations
```

### 4. Error Handling

```bash
# Check for required tools
if ! command -v jq &>/dev/null; then
  echo >&2 "ERROR: jq is required but not installed"
  exit 1
fi

# Validate critical inputs
if [[ -z "${base_domain:-}" ]]; then
  echo >&2 "ERROR: base_domain cannot be empty"
  exit 1
fi
```

### 5. Idempotency

Make hooks re-runnable:

```bash
# Check if already configured
if [[ -f "$GENESIS_ROOT/$GENESIS_ENVIRONMENT.yml" ]]; then
  prompt_for overwrite boolean \
    "Environment already exists. Overwrite?" \
    --default n
    
  [[ $overwrite == "false" ]] && exit 0
fi
```

## Testing Your Hook

### Manual Testing

```bash
cd my-kit

# Set test environment
export GENESIS_ROOT="/tmp/test"
export GENESIS_ENVIRONMENT="test-env"
export GENESIS_SECRETS_PATH="test/env"

# Run hook
./hooks/new

# Check output
cat /tmp/test/test-env.yml
```

### Automated Testing

Create test scripts:

```bash
#!/bin/bash
# test-new-hook.sh

# Mock prompt_for
prompt_for() {
  local var=$1
  local type=$2
  case "$var" in
    base_domain) eval "$var='test.example.com'" ;;
    use_ha) eval "$var='true'" ;;
    instances) eval "$var='3'" ;;
  esac
}

# Source and run hook
source hooks/new

# Validate output
grep -q "base_domain: test.example.com" "$GENESIS_ROOT/$GENESIS_ENVIRONMENT.yml"
```

## Common Patterns

### IaaS-Specific Configuration

```bash
case $iaas in
  aws)
    prompt_for aws_region line \
      'AWS Region?' \
      --default 'us-east-1'
    ;;
  azure)
    prompt_for azure_region line \
      'Azure Region?' \
      --default 'eastus'
    ;;
  vsphere)
    prompt_for vcenter_ip line \
      'vCenter IP address?' \
      --validation ip
    ;;
esac
```

### Database Selection

```bash
prompt_for database select \
  'Which database backend?' \
  -o '[postgres] PostgreSQL' \
  -o '[mysql]    MySQL' \
  -o '[none]     No database'

if [[ $database != "none" ]]; then
  features+=("$database")
  
  prompt_for db_persistent boolean \
    'Use persistent disk for database?'
    
  if [[ $db_persistent == "true" ]]; then
    prompt_for db_disk_size line \
      'Database disk size?' \
      --default '10GB'
  fi
fi
```

Writing effective hooks makes your kit user-friendly and reduces deployment errors by guiding users through configuration with appropriate validations and helpful defaults.