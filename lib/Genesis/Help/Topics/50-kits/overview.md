# Genesis Kits Overview

Genesis Kits are the heart of the Genesis deployment system. They encapsulate years of operational experience into reusable, parameterized templates that make deploying complex software simple and repeatable.

## What Is a Kit?

A Genesis Kit is a packaged collection of:

- **Manifest Templates** - YAML files defining BOSH deployments
- **Configuration Defaults** - Sensible default values
- **Feature Definitions** - Optional components and variations
- **Secret Specifications** - What credentials to generate
- **Lifecycle Hooks** - Scripts for customization and validation
- **Documentation** - Usage instructions and examples

Think of a kit as a blueprint for deploying a specific type of software, complete with all the knowledge needed to do it right.

## Why Use Kits?

### Without Kits

Deploying software with BOSH traditionally requires:
- Writing hundreds of lines of YAML
- Understanding every configuration option
- Managing credentials manually
- Keeping up with best practices
- Avoiding common pitfalls

### With Kits

Genesis Kits provide:
- **Pre-built configurations** - Start with working defaults
- **Curated options** - Only expose what matters
- **Automatic secrets** - Credentials generated for you
- **Built-in validation** - Catch errors before deployment
- **Community knowledge** - Best practices built in

## How Kits Work

### 1. Kit Selection

Choose a kit for what you want to deploy:

```yaml
kit:
  name: vault      # Deploy HashiCorp Vault
  version: 1.5.0   # Specific kit version
```

### 2. Feature Activation

Enable optional components:

```yaml
kit:
  features:
    - consul         # Use Consul backend
    - monitoring     # Enable Prometheus metrics
    - auto-unseal    # AWS KMS auto-unseal
```

### 3. Parameter Configuration

Provide environment-specific values:

```yaml
params:
  env: production
  vault_disk_size: 50_GB
  availability_zones:
    - us-east-1a
    - us-east-1b
    - us-east-1c
```

### 4. Manifest Generation

Genesis combines:
- Kit base manifests
- Feature modifications
- Your parameters
- Generated secrets

Into a complete BOSH manifest.

## Kit Components

### Base Manifest

The foundation all deployments start from:

```yaml
# manifests/base.yml
name: (( grab params.env ))
instance_groups:
- name: vault
  instances: 3
  vm_type: (( grab params.vm_type ))
  jobs:
  - name: vault
    release: vault
    properties:
      # Sensible defaults here
```

### Features

Optional modifications:

```yaml
# manifests/features/consul.yml
instance_groups:
- name: vault
  jobs:
  - name: vault
    properties:
      vault:
        backend:
          type: consul
          consul:
            address: (( grab params.consul_address ))
```

### Hooks

Lifecycle automation:

```bash
#!/bin/bash
# hooks/new
prompt_for "vault_disk_size" \
  "How much disk space for Vault data?" \
  --default "10G"
```

### Secrets Definition

```yaml
# kit.yml
credentials:
  base:
    vault/seal:
      seal_key: random 32 fmt base64
```

## Kit Lifecycle

### Development Time

1. **Author creates kit** - Encodes deployment knowledge
2. **Testing and refinement** - Validates across scenarios
3. **Release** - Published for community use

### Deployment Time

1. **Operator selects kit** - Chooses software to deploy
2. **Configuration** - Provides environment details
3. **Generation** - Genesis creates full manifest
4. **Deployment** - BOSH deploys the software

### Operational Time

1. **Updates** - New kit versions bring improvements
2. **Modifications** - Features can be added/removed
3. **Maintenance** - Hooks provide operational tasks

## Types of Kits

### Infrastructure Kits

Deploy foundational services:
- **BOSH** - BOSH directors
- **Vault** - Secret management
- **Concourse** - CI/CD systems

### Platform Kits

Deploy application platforms:
- **Cloud Foundry** - PaaS platform
- **Kubernetes** - Container orchestration
- **Nomad** - Workload scheduling

### Service Kits

Deploy supporting services:
- **PostgreSQL** - Databases
- **RabbitMQ** - Message queues
- **Elasticsearch** - Search and analytics

### Monitoring Kits

Deploy observability stacks:
- **Prometheus** - Metrics collection
- **Grafana** - Visualization
- **ELK Stack** - Log aggregation

## Kit Philosophy

### 1. Convention Over Configuration

Kits make reasonable assumptions:
- Standard network names
- Common VM types
- Typical sizing

While allowing overrides when needed.

### 2. Progressive Disclosure

Start simple:
```yaml
kit:
  name: vault
```

Add complexity as needed:
```yaml
kit:
  name: vault
  features: [consul, monitoring, auto-unseal]
params:
  vault_instances: 5
  vault_vm_type: large
```

### 3. Operational Experience

Kits encode real-world lessons:
- Recommended instance counts
- Proven update strategies
- Common troubleshooting steps

## Kit Benefits

### For Operators

- **Faster deployments** - Minutes instead of days
- **Fewer mistakes** - Validation catches errors
- **Consistent environments** - Same kit = same setup
- **Easy updates** - Kit versions bring improvements

### For Organizations

- **Standardization** - Consistent across teams
- **Knowledge sharing** - Best practices in code
- **Reduced training** - Simpler operations
- **Compliance** - Security built in

### For the Community

- **Shared improvements** - Everyone benefits
- **Collective knowledge** - Lessons learned together
- **Reduced duplication** - Solve problems once

## Getting Started with Kits

### Using Existing Kits

1. Browse available kits:
   ```bash
   genesis kits
   ```

2. Initialize with a kit:
   ```bash
   genesis init --kit vault
   ```

3. Deploy:
   ```bash
   genesis new prod-vault
   genesis deploy prod-vault
   ```

### Creating New Kits

1. Start from template:
   ```bash
   genesis create-kit my-software
   ```

2. Define your manifest structure
3. Add features and hooks
4. Test thoroughly
5. Share with community

## Next Steps

- Learn to [Use Kits](using-kits.md)
- Explore [Available Kits](available-kits.md)
- Understand [Kit Features](features.md)
- Start [Authoring Kits](authoring-kits.md)