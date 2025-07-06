# Kit Structure

This guide details the anatomy of a Genesis kit, explaining each component and how they work together.

## Directory Layout

A complete Genesis kit has this structure:

```
my-genesis-kit/
├── kit.yml                 # Kit metadata and configuration
├── hooks/                  # Lifecycle scripts
│   ├── addon              # Operational tasks
│   ├── blueprint          # Manifest generation
│   ├── check              # Pre-deployment validation
│   ├── features           # Feature detection
│   ├── info               # Information display
│   ├── new                # Environment creation
│   ├── post-deploy        # Post-deployment actions
│   ├── pre-deploy         # Pre-deployment actions
│   └── secrets            # Secret management
├── manifests/             # BOSH manifest templates
│   ├── base.yml           # Base manifest
│   └── features/          # Feature-specific manifests
│       ├── aws.yml
│       ├── monitoring.yml
│       └── ha.yml
├── ops/                   # Additional ops files (optional)
├── spec/                  # Test specifications
├── ci/                    # CI/CD pipeline definitions
└── README.md              # Documentation

```

## Core Components

### kit.yml

The kit metadata file defines identity and behavior:

```yaml
# Identity
name:    my-software
version: 1.2.0
author:  Genesis Community <community@genesisproject.io>
docs:    https://github.com/genesis-community/my-software-genesis-kit
code:    https://github.com/genesis-community/my-software-genesis-kit

# Description
description: |
  This kit deploys My Software, providing scalable
  services for your infrastructure.

# Genesis version requirement
genesis_version_min: 2.8.0

# Dependencies
depends_on:
  - vault

# Provided features
provides:
  - my-software-api

# Subkits (deprecated - use features)
# subkits: []

# Certificates
certificates:
  base:
    server/ca:
      ca:
        valid_for: 10y
        names: ["My Software CA"]
    server/cert:
      server:
        valid_for: 1y
        names: ["server.${params.base_domain}"]
        signed_by: server/ca

# Credentials  
credentials:
  base:
    admin:
      password: random 32
    system/db:
      username: dbadmin
      password: random 40 fmt base64

# User-provided secrets
provided:
  base:
    external/api:
      keys:
        - client_id
        - client_secret
```

### Manifest Files

#### Base Manifest (manifests/base.yml)

The foundation all deployments build upon:

```yaml
---
# Basic structure
name: (( grab params.env ))

# Releases
releases:
- name: my-software
  version: 3.4.5
  url: https://github.com/.../my-software-3.4.5.tgz
  sha1: abc123def456...

# Stemcells
stemcells:
- alias: default
  os: ubuntu-jammy
  version: latest

# Update settings
update:
  canaries: 1
  max_in_flight: 1
  canary_watch_time: 1000-60000
  update_watch_time: 1000-60000
  serial: false

# Instance groups
instance_groups:
- name: api
  instances: (( grab params.api_instances || 1 ))
  vm_type: (( grab params.api_vm_type || "default" ))
  stemcell: default
  networks:
  - name: (( grab params.network || "default" ))
  jobs:
  - name: api
    release: my-software
    properties:
      api:
        port: 8080
        admin_password: (( vault "secret/" params.vault "/admin:password" ))

# Required parameters
params:
  env: (( param "What environment is this?" ))
  network: (( param "What network should VMs be placed on?" ))
```

#### Feature Manifests (manifests/features/)

Modifications applied when features are enabled:

```yaml
# manifests/features/ha.yml
---
# Enable high availability
- type: replace
  path: /instance_groups/name=api/instances
  value: 3

- type: replace
  path: /instance_groups/name=api/jobs/name=api/properties/api/cluster?
  value:
    enabled: true
    quorum: 2
    
# Add load balancer
- type: replace
  path: /instance_groups/-
  value:
    name: haproxy
    instances: 2
    vm_type: (( grab params.haproxy_vm_type || "small" ))
    stemcell: default
    networks:
    - name: (( grab params.network ))
    jobs:
    - name: haproxy
      release: haproxy
      properties:
        ha_proxy:
          backend_port: 8080
          backend_servers: (( grab instance_groups.api.networks[0].static_ips ))
```

### Hook Scripts

#### blueprint Hook

Determines which manifests to merge:

```bash
#!/bin/bash
set -eu

# Start with base
manifests=( manifests/base.yml )

# Add features
for want in $GENESIS_REQUESTED_FEATURES; do
  case "$want" in
    # Infrastructure features
    aws|azure|gcp|vsphere|openstack)
      manifests+=( manifests/iaas/$want.yml )
      ;;
      
    # Standard features
    ha|monitoring|shield)
      manifests+=( manifests/features/$want.yml )
      ;;
      
    # Implicit features
    +internal-db)
      manifests+=( manifests/addons/internal-db.yml )
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

#### new Hook

Interactive environment creation:

```bash
#!/bin/bash
set -eu

# Load Genesis helpers
source $GENESIS_ROOT/.genesis/lib/genesis.sh

# Basic information
describe "Setting up new My Software deployment"
echo

# Required parameters
prompt_for base_domain \
  "What is your base domain (e.g., example.com)?" \
  --validation dns_domain

# Optional parameters with defaults
prompt_for_or_use_default api_instances "1" \
  "How many API instances do you want?"

# Feature selection
if features_enabled ha; then
  prompt_for_or_use_default api_instances "3" \
    "How many API instances? (minimum 3 for HA)"
fi

# Infrastructure selection
infrastructure_menu() {
  describe "Select your infrastructure:"
  choose "aws"       "Amazon Web Services" \
         "azure"     "Microsoft Azure" \
         "gcp"       "Google Cloud Platform" \
         "vsphere"   "VMware vSphere" \
         "openstack" "OpenStack"
}

infrastructure=$(infrastructure_menu)
features+=( "$infrastructure" )

# Save configuration
param_entry params.base_domain "$base_domain"
param_entry params.api_instances "$api_instances"
```

#### check Hook

Validate before deployment:

```bash
#!/bin/bash
set -eu

# Check BOSH
describe "Validating BOSH environment..."

# Verify cloud config
for type in vm network disk; do
  value=$(lookup params.${type}_type "default")
  if ! bosh_cloud_config_has ${type}_type "$value"; then
    fail "Cloud config missing ${type} type '$value'"
  fi
done

# Verify secrets
describe "Checking Vault secrets..."

if want_feature provided-cert; then
  for secret in ssl/server:certificate ssl/server:key; then
    if ! safe exists "$GENESIS_SECRETS_BASE/$secret"; then
      fail "Missing required secret: $secret"
    fi
  done
fi

describe "#G{All checks passed!}"
```

#### info Hook

Display deployment information:

```bash
#!/bin/bash
set -eu

base_domain=$(lookup params.base_domain)
url="https://api.$base_domain"
username="admin"
password=$(safe get "$GENESIS_SECRETS_BASE/admin:password")

describe "#Yi{My Software Deployment Information}"
echo
describe "  API URL:   #C{$url}"
describe "  Username:  #C{$username}" 
describe "  Password:  #C{$password}"
echo
describe "Need to do something? Try these addons:"
echo
genesis do "$GENESIS_ENVIRONMENT" list
```

#### addon Hook

Operational tasks:

```bash
#!/bin/bash
set -eu

list() {
  describe "Available addons:"
  describe "  #G{login}       Login to API"
  describe "  #G{setup}       Initial setup"
  describe "  #G{backup}      Run backup"
  describe "  #G{restore}     Restore from backup"
}

case $GENESIS_ADDON_SCRIPT in
  list) list ;;
  
  login)
    api_url="https://api.$(lookup params.base_domain)"
    password=$(safe get "$GENESIS_SECRETS_BASE/admin:password")
    
    describe "Logging into $api_url..."
    curl -X POST "$api_url/login" \
      -d "username=admin&password=$password" \
      -c cookie.txt
    ;;
    
  backup)
    describe "Running backup errand..."
    genesis bosh run-errand backup
    ;;
    
  *)
    echo >&2 "Unrecognized addon: $GENESIS_ADDON_SCRIPT"
    list >&2
    exit 1
    ;;
esac
```

### Supporting Files

#### spec/ - Test Specifications

Ginkgo tests for validating kit behavior:

```go
// spec/spec_test.go
var _ = Describe("My Software Kit", func() {
    BeforeEach(func() {
        kit = "my-software"
        version = "latest"
    })
    
    Context("Base Manifest", func() {
        BeforeEach(func() {
            features = []string{}
        })
        
        It("should deploy with defaults", func() {
            manifest := GetManifest()
            Expect(manifest.Name).To(Equal("my-env-my-software"))
            
            ig := manifest.InstanceGroups.Lookup("api")
            Expect(ig.Instances).To(Equal(1))
        })
    })
    
    Context("HA Feature", func() {
        BeforeEach(func() {
            features = []string{"ha"}
        })
        
        It("should scale instances", func() {
            manifest := GetManifest()
            
            ig := manifest.InstanceGroups.Lookup("api")
            Expect(ig.Instances).To(Equal(3))
        })
    })
})
```

#### ci/ - Pipeline Configuration

Concourse pipeline for testing:

```yaml
# ci/pipeline.yml
resources:
- name: git
  type: git
  source:
    uri: ((github.uri))
    branch: develop

- name: version
  type: semver
  source:
    driver: git
    uri: ((github.uri))
    branch: version
    file: version

jobs:
- name: test
  plan:
  - get: git
    trigger: true
  - task: test-kit
    file: git/ci/tasks/test.yml

- name: release
  plan:
  - aggregate:
    - get: git
      passed: [test]
    - get: version
      params: {bump: final}
  - task: release
    file: git/ci/tasks/release.yml
  - put: version
    params: {file: version/version}
```

## File Interactions

### Manifest Assembly Flow

1. **Genesis** calls `blueprint` hook
2. **Blueprint** returns ordered manifest list
3. **Genesis** merges manifests with Spruce
4. **Parameters** from environment file applied
5. **Secrets** retrieved from Vault
6. **Final manifest** sent to BOSH

### Secret Generation Flow

1. **Kit.yml** defines required secrets
2. **Genesis** checks Vault for existence
3. **Missing secrets** generated automatically
4. **Manifests** reference via `(( vault ))` operator

### Hook Execution Order

1. **features** - Determine active features
2. **new** - Create new environment (once)
3. **blueprint** - Generate manifest list
4. **secrets** - Manage secrets
5. **check** - Validate configuration
6. **pre-deploy** - Pre-deployment tasks
7. *[Genesis deploys to BOSH]*
8. **post-deploy** - Post-deployment tasks
9. **info** - Display information
10. **addon** - Run operational tasks

## Best Practices

### Manifest Organization

- Keep `base.yml` minimal and focused
- One feature per file in `features/`
- Use ops file format for modifications
- Document parameter requirements

### Hook Guidelines

- Always `set -eu` for safety
- Use Genesis helper functions
- Provide helpful error messages
- Make scripts idempotent

### Testing Structure

- Test base configuration
- Test each feature independently
- Test feature combinations
- Validate error conditions

### Documentation

Always include:
- README.md with examples
- Parameter documentation
- Feature descriptions
- Upgrade notes

Understanding kit structure helps you create maintainable, reusable deployment templates that encode your operational knowledge.