# Genesis Kits

Genesis Kits are pre-packaged deployment templates that encapsulate best practices for deploying software with BOSH. This section covers everything from using existing kits to creating your own.

## Topics in This Section

1. **[Overview](overview.md)** - Understanding Genesis kits
2. **[Using Kits](using-kits.md)** - Finding, selecting, and deploying with kits
3. **[Kit Features](features.md)** - Working with optional kit components
4. **[Available Kits](available-kits.md)** - Catalog of official Genesis kits
5. **[Authoring Kits](authoring-kits.md)** - Creating your own Genesis kits
6. **[Kit Structure](kit-structure.md)** - Anatomy of a kit
7. **[Kit Hooks](kit-hooks.md)** - Lifecycle hooks and scripts
8. **[Writing Hooks](writing-hooks.md)** - Hook development guide
9. **[Kit Testing](kit-testing.md)** - Testing and validation
10. **[Best Practices](best-practices.md)** - Kit development recommendations

## Quick Overview

Genesis Kits provide:

- **Pre-built Templates** - YAML manifests with sensible defaults
- **Feature Flags** - Optional components you can enable
- **Secret Management** - Automatic credential generation
- **Lifecycle Hooks** - Scripts for customization
- **Best Practices** - Years of deployment experience

### Common Kits

- **BOSH** - Deploy BOSH directors
- **Cloud Foundry** - Full CF deployments
- **Vault** - HashiCorp Vault clusters
- **Concourse** - CI/CD pipelines
- **Shield** - Backup solutions
- **Prometheus** - Monitoring stacks

## Using Kits

### Finding Kits

```bash
# List available kits
genesis kits

# Search for specific kit
genesis kits | grep vault

# Get kit information
genesis info vault
```

### Selecting Kit Version

```yaml
# In environment file
kit:
  name: vault
  version: 1.5.0  # Specific version
  # or
  version: latest # Always use latest
```

### Enabling Features

```yaml
kit:
  features:
    - postgres      # Use PostgreSQL
    - haproxy       # Enable load balancer
    - tls           # Enable TLS/SSL
```

## Creating Kits

### Basic Kit Structure

```
my-genesis-kit/
├── kit.yml           # Kit metadata
├── hooks/            # Lifecycle scripts
│   ├── new
│   ├── blueprint
│   └── check
├── manifests/        # YAML templates
│   └── base.yml
└── spec/            # Test specifications
```

### Development Workflow

```bash
# Create new kit
genesis create-kit my-software

# Work in dev mode
cd deployments/my-software
mkdir dev
# ... develop kit in dev/ ...

# Test your kit
genesis new test-env --kit dev

# Compile kit
genesis compile-kit --version 1.0.0
```

## Key Concepts

### Kit Metadata (kit.yml)

Defines kit properties:
- Name and version
- Author information
- Required secrets
- Available features
- Dependencies

### Features

Optional components:
- Infrastructure-specific (AWS, Azure, vSphere)
- Add-ons (monitoring, backups)
- Integrations (SSO, external databases)

### Hooks

Scripts that run at specific times:
- **new** - Environment creation
- **blueprint** - Manifest generation
- **check** - Pre-deployment validation
- **addon** - Operational tasks

## Getting Started

- New to kits? Start with [Overview](overview.md)
- Want to use a kit? See [Using Kits](using-kits.md)
- Ready to create? Read [Authoring Kits](authoring-kits.md)
- Need examples? Check [Available Kits](available-kits.md)