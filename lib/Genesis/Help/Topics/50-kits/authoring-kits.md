# Authoring Genesis Kits

This guide covers creating your own Genesis kits to package deployment knowledge for reuse across teams and environments.

## Getting Started

### When to Create a Kit

Create a kit when:
- Deploying software not covered by existing kits
- Standardizing deployment patterns across teams
- Packaging proprietary software deployments
- Sharing deployment expertise

### Kit Philosophy

Remember these principles:

1. **Kit Authors are Trusted** - You have full control
2. **User Parameters under `params`** - Keep configuration organized
3. **Secrets in Vault** - Never hardcode credentials
4. **Multiple Ways to Deploy** - Support variations via features

### Development Setup

```bash
# Create kit skeleton
genesis create-kit my-software

# Directory structure created:
my-software-genesis-kit/
├── kit.yml           # Kit metadata
├── manifests/        # BOSH manifests
│   └── base.yml
└── hooks/           # Lifecycle scripts
    └── blueprint

cd my-software-genesis-kit
```

## Kit Structure

### kit.yml - Metadata

Define your kit's identity and behavior:

```yaml
name:    my-software
version: 0.1.0
author:  Your Name <your.email@example.com>
docs:    https://github.com/yourorg/my-software-genesis-kit
code:    https://github.com/yourorg/my-software-genesis-kit

description: |
  Deploys My Software, a revolutionary application that
  solves all your problems.

# Define required credentials
credentials:
  base:
    admin:
      password: random 32
    database:
      password: random 64 fmt base64

# Define certificates
certificates:
  base:
    server:
      ca:
        valid_for: 10y
      web:
        valid_for: 1y
        names: 
          - "*.${params.base_domain}"
```

### Base Manifest

Start with `manifests/base.yml`:

```yaml
---
name: (( grab params.env ))

releases:
- name: my-software
  version: "1.2.3"
  url: https://github.com/org/releases/download/v1.2.3/release.tgz
  sha1: abc123...

stemcells:
- alias: default
  os: ubuntu-jammy
  version: latest

update:
  canaries: 1
  max_in_flight: 1
  canary_watch_time: 30000-120000
  update_watch_time: 30000-120000

instance_groups:
- name: my-software
  instances: (( grab params.instances || 1 ))
  vm_type: (( grab params.vm_type || "default" ))
  stemcell: default
  networks:
  - name: (( grab params.network || "default" ))
  jobs:
  - name: my-software
    release: my-software
    properties:
      admin_password: (( vault "secret/" params.vault "/admin:password" ))
      database_password: (( vault "secret/" params.vault "/database:password" ))
```

## Features

### Adding Features

Create feature manifests in `manifests/features/`:

```yaml
# manifests/features/ha.yml
---
# High Availability Feature
- type: replace
  path: /instance_groups/name=my-software/instances
  value: 3

- type: replace
  path: /instance_groups/name=my-software/jobs/name=my-software/properties/cluster?
  value:
    enabled: true
    members: 3
```

```yaml
# manifests/features/monitoring.yml
---
# Prometheus Monitoring
- type: replace
  path: /instance_groups/name=my-software/jobs/-
  value:
    name: prometheus_exporter
    release: prometheus
    properties:
      prometheus:
        port: 9100
```

### Feature-Specific Secrets

```yaml
# kit.yml
credentials:
  base:
    admin:
      password: random 32
  
  ldap:  # Only with LDAP feature
    ldap/bind:
      password: random 32
  
  ssl:   # Only with SSL feature
    ssl/server: cert
```

## Lifecycle Hooks

### blueprint Hook

Controls manifest generation:

```bash
#!/bin/bash
# hooks/blueprint
set -eu

# Base manifest is always first
declare -a manifests
manifests+=( "manifests/base.yml" )

# Process requested features
for want in ${GENESIS_REQUESTED_FEATURES}; do
  case "$want" in
    ha|monitoring|ssl)
      manifests+=( "manifests/features/$want.yml" )
      ;;
    *)
      echo >&2 "Unrecognized feature: $want"
      exit 1
      ;;
  esac
done

# Output manifest list
printf "%s\n" "${manifests[@]}"
```

### new Hook

Interactive environment setup:

```bash
#!/bin/bash
# hooks/new
set -eu

# Prompt for basic configuration
prompt_for "base_domain" \
  "What is your base domain?" \
  --validation "/^[a-z0-9.-]+$/"

# Feature selection
feature_wanted "ha" \
  "Do you want High Availability mode?"

if feature_wanted "ha"; then
  prompt_for "instances" \
    "How many instances?" \
    --default 3 \
    --validation "/^[3-9]$/"
else
  prompt_for "instances" \
    "How many instances?" \
    --default 1
fi

# Infrastructure features
describe "What infrastructure are you deploying to?"
features+=( \
  "$(prompt_for_choice \
    "Infrastructure?" \
    "aws" \
    "azure" \
    "gcp" \
    "vsphere" \
    "openstack" \
  )" \
)

# Save configuration
genesis_config_set params.base_domain "$base_domain"
genesis_config_set params.instances "$instances"
```

### check Hook

Pre-deployment validation:

```bash
#!/bin/bash
# hooks/check
set -eu

# Validate cloud config
if ! bosh_cloud_config_has vm_type $(genesis_config_get params.vm_type); then
  describe >&2 \
    "VM type '#R{$(genesis_config_get params.vm_type)}' not found in cloud config"
  exit 1
fi

# Check for required secrets
if want_feature "provided-cert"; then
  if ! safe exists "$GENESIS_SECRETS_BASE/ssl/server"; then
    describe >&2 \
      "Feature 'provided-cert' requires certificate at $GENESIS_SECRETS_BASE/ssl/server"
    exit 1
  fi
fi

describe "Environment looks good!"
```

### info Hook

Display deployment information:

```bash
#!/bin/bash
# hooks/info
set -eu

# Get deployment info
FQDN="$(genesis_config_get params.base_domain)"
PASS="$(safe get "$GENESIS_SECRETS_BASE/admin:password")"

describe "#G{My Software Information}"
echo
describe "  URL: #C{https://app.$FQDN}"
describe "  Username: #C{admin}"
describe "  Password: #C{$PASS}"
echo
describe "To visit the web UI, run:"
echo
describe "  #G{genesis do $GENESIS_ENVIRONMENT visit-ui}"
```

### addon Hook

Operational tasks:

```bash
#!/bin/bash
# hooks/addon
set -eu

case "$GENESIS_ADDON_SCRIPT" in
  visit-ui)
    URL="https://app.$(genesis_config_get params.base_domain)"
    describe "Opening $URL in your browser..."
    open "$URL" || xdg-open "$URL" || echo "Please visit: $URL"
    ;;
    
  backup)
    describe "Running backup..."
    genesis bosh run-errand backup
    ;;
    
  list)
    describe "Available addons:"
    describe "  #G{visit-ui}  - Open the web interface"
    describe "  #G{backup}    - Run a backup"
    ;;
    
  *)
    describe >&2 "Unknown addon: $GENESIS_ADDON_SCRIPT"
    exit 1
    ;;
esac
```

## Development Workflow

### Local Development

Use the `dev/` directory for rapid iteration:

```bash
# In your deployment repo
mkdir dev
cp -r /path/to/my-software-genesis-kit/* dev/

# Use dev kit
cat > test.yml <<EOF
kit:
  name: dev
  features: [ha, monitoring]
params:
  env: test
  base_domain: test.example.com
EOF

# Test deployment
genesis deploy test
```

### Testing Your Kit

Create test environments:

```bash
# Minimal test
genesis new test-minimal
genesis manifest test-minimal

# Feature combinations
genesis new test-ha --feature ha
genesis manifest test-ha

genesis new test-full --feature ha --feature monitoring
genesis manifest test-full
```

### Debugging

```bash
# Enable debug output
export GENESIS_DEBUG=1

# Test individual hooks
cd dev
./hooks/new      # Test new hook
./hooks/blueprint # Test blueprint
./hooks/check    # Test validation
```

## Advanced Techniques

### Implicit Features

Handle feature dependencies:

```bash
#!/bin/bash
# hooks/features

# If no DB selected, use internal
if ! want_feature "external-db" && \
   ! want_feature "postgres" && \
   ! want_feature "mysql"; then
  echo "+internal-db"
fi

# HA requires shared storage
if want_feature "ha" && ! want_feature "nfs"; then
  echo "+local-storage-warning"
fi
```

### Parameter Validation

```yaml
# In base.yml - parameter requirements
params:
  base_domain: (( param "What is your base domain?" ))
  instances:   (( param "How many instances?" ))
  
  # Optional with defaults
  vm_type:     (( grab params.vm_type     || "default" ))
  network:     (( grab params.network     || "default" ))
  disk_type:   (( grab params.disk_type   || "default" ))
```

### Complex Secrets

```yaml
# kit.yml - different secret types
credentials:
  base:
    # SSH key for system access
    system/ssh: ssh 2048 fixed
    
    # Admin with specific format
    admin:
      password: random 32 fmt bcrypt
    
    # Multiple related secrets
    database:
      username: "dbuser"
      password: random 40
      admin_password: random 40
```

### Cross-Feature Compatibility

```yaml
# manifests/features/monitoring.yml
---
# Add monitoring to base
- type: replace
  path: /instance_groups/name=my-software/jobs/-
  value:
    name: prometheus_exporter
    release: prometheus

# Also add to HA instances if present
- type: replace
  path: /instance_groups/name=my-software-secondary?/jobs/-
  value:
    name: prometheus_exporter
    release: prometheus
```

## Best Practices

### 1. Clear Documentation

Document everything:
- Kit README with examples
- Feature descriptions
- Parameter explanations
- Common configurations

### 2. Sensible Defaults

```yaml
# Good defaults in base.yml
instance_groups:
- name: my-software
  instances: (( grab params.instances || 1 ))
  vm_type: (( grab params.vm_type || "default" ))
  persistent_disk_type: (( grab params.disk_type || "10GB" ))
```

### 3. Helpful Error Messages

```bash
# In hooks/check
if [[ -z "${base_domain:-}" ]]; then
  describe >&2 \
    "#R{Missing required parameter 'base_domain'}" \
    "" \
    "Please add to your environment file:" \
    "  #C{params:}" \
    "  #C{  base_domain: example.com}"
  exit 1
fi
```

### 4. Feature Organization

Group related changes:
```
manifests/features/
├── aws.yml          # IaaS-specific
├── azure.yml
├── ha.yml           # Architecture
├── standalone.yml
├── monitoring.yml   # Operations
└── shield.yml
```

### 5. Version Management

```yaml
# kit.yml
name: my-software
version: 1.0.0  # Semantic versioning

# Track BOSH release versions
releases:
  my-software: 2.3.4
  prometheus: 25.0.0
```

## Publishing Your Kit

### Prepare for Release

1. **Test thoroughly** across scenarios
2. **Document** in README.md
3. **Version** appropriately
4. **Include examples**

### Compile and Release

```bash
# Compile kit
genesis compile-kit \
  --version 1.0.0 \
  --name my-software

# Creates: my-software-1.0.0.tar.gz

# Upload to GitHub releases
# Tag repository with v1.0.0
```

### Sharing with Community

1. Open source on GitHub
2. Follow naming convention: `*-genesis-kit`
3. Submit to Genesis community registry
4. Announce in Genesis Slack

## Troubleshooting

### Manifest Generation Issues

```bash
# Debug blueprint hook
cd dev
GENESIS_REQUESTED_FEATURES="ha monitoring" ./hooks/blueprint

# Check generated manifest
genesis manifest test -P | spruce diff base.yml -
```

### Secret Generation Problems

```bash
# Check what secrets are needed
genesis check-secrets test

# Manually generate if needed
safe gen "$VAULT_PREFIX/test/admin" password
```

### Hook Failures

```bash
# Run hooks manually
cd dev
export GENESIS_ENVIRONMENT=test
export GENESIS_SECRETS_BASE=secret/test/my-software
./hooks/info
```

## Next Steps

- Study existing kits for patterns
- Start with simple kits
- Iterate based on user feedback
- Contribute improvements back

Creating kits shares your operational knowledge and makes deployments consistent and reliable across your organization.