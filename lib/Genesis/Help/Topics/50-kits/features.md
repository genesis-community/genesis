# Kit Features

Features are optional components in Genesis kits that allow you to customize deployments for different scenarios. This guide explains how features work and how to use them effectively.

## Understanding Features

### What Are Features?

Features are modular extensions to a kit's base configuration:
- Add or modify deployment components
- Enable integrations with external systems
- Adapt to different infrastructures
- Toggle functionality on/off

### How Features Work

When you enable a feature:
1. Genesis includes additional YAML files
2. New parameters may be required
3. Different secrets might be generated
4. Validation rules can change

## Feature Types

### Infrastructure Features

Adapt to different IaaS providers:

```yaml
kit:
  features:
    - aws          # Amazon Web Services
    - azure        # Microsoft Azure
    - gcp          # Google Cloud Platform
    - vsphere      # VMware vSphere
    - openstack    # OpenStack
```

Each provides:
- IaaS-specific resource types
- Network configurations
- Storage options
- Instance metadata

### Architectural Features

Change deployment topology:

```yaml
kit:
  features:
    # High Availability
    - ha           # Multi-instance, clustered
    - standalone   # Single instance
    
    # Scaling
    - minimum-vms  # Colocate jobs
    - distributed  # Separate job instances
```

### Storage Features

Different backend options:

```yaml
# Vault kit example
kit:
  features:
    - consul       # Consul storage backend
    - raft         # Integrated Raft storage
    - file         # File-based (dev only)
    
# CF kit example  
kit:
  features:
    - postgres     # PostgreSQL database
    - mysql        # MySQL database
    - external-db  # User-provided database
```

### Security Features

Enhanced security options:

```yaml
kit:
  features:
    # Authentication
    - ldap         # LDAP integration
    - github-oauth # GitHub OAuth
    - uaa          # UAA integration
    
    # Certificates
    - self-signed-cert  # Generate certificates
    - provided-cert     # User-provided certificates
    
    # Encryption
    - encryption-at-rest
    - mtls         # Mutual TLS
```

### Operational Features

Monitoring and maintenance:

```yaml
kit:
  features:
    # Monitoring
    - monitoring   # Prometheus exporters
    - logging      # Enhanced logging
    
    # Backup
    - shield       # Shield backup agent
    - native-backup # Built-in backup
    
    # Debugging
    - debug        # Debug logging
    - trace        # Trace-level output
```

## Feature Dependencies

### Mutually Exclusive Features

Some features cannot be used together:

```yaml
# Error - multiple databases
kit:
  features:
    - postgres  # Can't use both
    - mysql     # database types

# Error - conflicting architectures  
kit:
  features:
    - ha         # Can't be both HA
    - standalone # and standalone
```

### Required Combinations

Some features require others:

```yaml
# github-oauth requires UAA
kit:
  features:
    - uaa          # Required by
    - github-oauth # this feature
```

### Implicit Features

Features activated automatically:

```yaml
# If no storage backend specified
# Might implicitly activate +internal-storage
kit:
  features: []  # +internal-storage added
```

## Feature Parameters

### Feature-Specific Parameters

Features often introduce new parameters:

```yaml
# With 'aws' feature
params:
  aws_region: us-east-1
  aws_default_sgs: [bosh]
  
# With 'github-oauth' feature  
params:
  github_client_id: abc123
  github_client_secret: ((github_oauth_secret))
  github_orgs: [myorg]
```

### Conditional Parameters

Parameters that only apply with certain features:

```yaml
params:
  # Always required
  base_domain: example.com
  
  # Only with 'ha' feature
  cluster_members: 3
  
  # Only with 'postgres' feature
  postgres_version: "13"
```

## Feature Discovery

### List Available Features

```bash
# During environment creation
genesis new prod-env
> Select features to enable:
> [ ] aws - AWS infrastructure support
> [ ] monitoring - Prometheus metrics
> [ ] shield - Backup integration
> [x] ha - High availability mode

# From kit info
genesis info vault --features
```

### Feature Documentation

```bash
# Get feature details
genesis info vault --feature consul

# Shows:
# - Description
# - Required parameters
# - Dependencies
# - Conflicts
```

### In Kit Source

```bash
# Feature manifests
ls .genesis/kits/vault-1.5.0/manifests/features/
consul.yml
monitoring.yml
provided-cert.yml
```

## Common Feature Patterns

### Progressive Enhancement

Start simple, add features:

```yaml
# Initial deployment
kit:
  name: concourse
  version: 5.0.0
  features: []

# Add authentication
kit:
  features:
    - github-oauth

# Add monitoring
kit:
  features:
    - github-oauth
    - prometheus

# Add backups
kit:
  features:
    - github-oauth
    - prometheus
    - shield
```

### Environment-Specific Features

Different features per environment:

```yaml
# development.yml
kit:
  features:
    - minimum-vms
    - self-signed-cert

# staging.yml  
kit:
  features:
    - ha
    - self-signed-cert
    - monitoring

# production.yml
kit:
  features:
    - ha
    - provided-cert
    - monitoring
    - shield
```

### Infrastructure Adaptation

```yaml
# AWS deployment
kit:
  features:
    - aws
    - ha
    - monitoring

# vSphere deployment
kit:
  features:
    - vsphere
    - ha
    - monitoring
    - nfs-volume-services
```

## Feature Implementation

### How Kits Define Features

In the kit's `manifests/features/` directory:

```yaml
# manifests/features/monitoring.yml
- type: replace
  path: /instance_groups/name=vault/jobs/-
  value:
    name: prometheus_exporter
    release: prometheus
    properties:
      prometheus:
        port: 9100
```

### Feature Activation

The `blueprint` hook determines active features:

```bash
#!/bin/bash
# hooks/blueprint

# Base manifest always included
manifest_files="manifests/base.yml"

# Add feature manifests
for feature in $GENESIS_REQUESTED_FEATURES; do
  manifest_files="$manifest_files manifests/features/$feature.yml"
done

echo "$manifest_files"
```

### Conditional Logic

Features can include logic:

```yaml
# Only add if using PostgreSQL
- type: replace
  path: /instance_groups/name=postgres?
  value:
    name: postgres
    instances: (( grab params.postgres_instances || 1 ))
```

## Advanced Feature Usage

### Custom Features

Add your own features via ops files:

```bash
# Create custom feature
mkdir -p ops
cat > ops/custom-logging.yml <<EOF
- type: replace
  path: /instance_groups/name=api/env?/LOG_LEVEL
  value: debug
EOF

# Use in environment
kit:
  features:
    - custom-logging
```

### Feature Validation

The `check` hook validates features:

```bash
#!/bin/bash
# hooks/check

# Ensure certificate provided
if has_feature "provided-cert"; then
  if ! safe exists "$GENESIS_SECRETS_BASE/ssl/cert"; then
    error "provided-cert feature requires certificate in Vault"
  fi
fi
```

### Feature-Based Secrets

Different features need different secrets:

```yaml
# kit.yml
credentials:
  base:
    admin_password: random 32
  
  consul:
    consul/gossip: random 16 fmt base64
  
  ldap:
    ldap/bind_password: random 32
```

## Best Practices

### 1. Start Simple

Begin with minimal features:
```yaml
# Start here
kit:
  features: []

# Add as needed
kit:
  features:
    - monitoring
```

### 2. Document Feature Choices

```yaml
# Production environment
# Features:
#   - aws: Deployed on AWS infrastructure
#   - ha: Need high availability for production
#   - monitoring: Required by ops team
#   - provided-cert: Using company CA
kit:
  features:
    - aws
    - ha
    - monitoring  
    - provided-cert
```

### 3. Test Feature Combinations

Before production:
```bash
# Test new feature
cp prod.yml test-feature.yml
# Add feature to test-feature.yml
genesis deploy test-feature

# Verify behavior
genesis do test-feature -- smoke-tests
```

### 4. Understand Implications

Some features fundamentally change behavior:
- Storage backends affect data persistence
- Authentication features affect access
- HA features affect update procedures

### 5. Keep Consistent

Use same features across similar environments:
```yaml
# All production environments
kit:
  features:
    - ha
    - monitoring
    - provided-cert
```

## Troubleshooting

### Feature Not Found

```bash
# Error: Feature 'custom' not found

# Check available features
genesis info mykit --features

# Check spelling
ls .genesis/kits/mykit-*/manifests/features/
```

### Missing Parameters

```bash
# Error: Missing param 'github_client_id'

# Feature added required parameter
params:
  github_client_id: "get-from-github"
  github_client_secret: ((github_secret))
```

### Feature Conflicts

```bash
# Error: Features 'consul' and 'raft' are mutually exclusive

# Choose one storage backend
kit:
  features:
    - raft  # Remove consul
```

### Unexpected Behavior

```bash
# Debug feature effects
genesis manifest my-env > with-feature.yml

# Remove feature and compare
# Edit environment file
genesis manifest my-env > without-feature.yml

diff without-feature.yml with-feature.yml
```

## Summary

Features provide powerful customization:
- Adapt to any infrastructure
- Enable optional functionality
- Maintain clean base configurations
- Share common patterns

Use them wisely to create flexible, maintainable deployments.