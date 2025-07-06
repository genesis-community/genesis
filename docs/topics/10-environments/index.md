# Environment Management

This section covers everything you need to know about Genesis environments - from naming conventions to configuration management.

## Topics in This Section

1. **[Naming Conventions](naming-conventions.md)** - Environment naming rules and patterns
2. **[File Structure](file-structure.md)** - Organizing environment files
3. **[Configuration Merging](configuration-merging.md)** - How hierarchical inheritance works
4. **[Match Mode](match-mode.md)** - Quick environment selection
5. **[Vault Paths](vault-paths.md)** - Secret storage conventions
6. **[BOSH Integration](bosh-integration.md)** - How environments map to BOSH
7. **[Reactions](reactions.md)** - Pre and post-deploy scripts
8. **[Best Practices](best-practices.md)** - Recommendations and patterns

## Quick Overview

Genesis environments are the heart of your infrastructure-as-code. Each environment represents a single deployment with its own:

- YAML configuration file
- Hierarchical inheritance from parent configs
- Secrets stored in Vault
- BOSH deployment manifest

### Key Concepts

**Environment File**: A YAML file (e.g., `us-east-1-prod.yml`) that defines a deployment's configuration.

**Hierarchical Merging**: Configurations inherit from parent files based on naming patterns:
```
us.yml                  # US-wide settings
└── us-east.yml         # US East settings
    └── us-east-1.yml   # Specific region
        └── us-east-1-prod.yml  # Production environment
```

**Match Mode**: Quick selection using patterns:
```bash
genesis deploy @prod:cf  # Deploy any CF prod environment
```

## Common Patterns

### Standard Naming Convention
```
<org>-<infrastructure>-<region>-<purpose>.yml
```

Examples:
- `acme-aws-us-east-1-prod.yml`
- `globex-azure-westeurope-staging.yml`
- `startup-gcp-us-central1-dev.yml`

### Directory Organization
```
deployments/
├── bosh/
│   ├── acme.yml              # Company-wide BOSH settings
│   ├── acme-aws.yml          # AWS-specific BOSH settings
│   └── acme-aws-us-east-1.yml # Region-specific BOSH
├── vault/
│   └── acme-aws-us-east-1.yml # Vault deployment
└── cf/
    ├── acme.yml              # Company-wide CF settings
    ├── acme-prod.yml         # Production CF settings
    └── acme-aws-us-east-1-prod.yml # Full CF deployment
```

## Getting Started

1. **Learn the naming rules** in [Naming Conventions](naming-conventions.md)
2. **Understand inheritance** with [Configuration Merging](configuration-merging.md)
3. **Organize your files** using [File Structure](file-structure.md)
4. **Speed up workflows** with [Match Mode](match-mode.md)

## Common Tasks

### Create a New Environment
```bash
genesis new us-east-1-prod
```

### View Environment Hierarchy
```bash
genesis describe us-east-1-prod
```

### Check What Will Be Deployed
```bash
genesis manifest us-east-1-prod
```

### Deploy an Environment
```bash
genesis deploy us-east-1-prod
```

## Tips

- Use consistent naming across all deployments
- Leverage hierarchy to avoid repetition
- Document your naming conventions
- Test changes in lower environments first
- Use match mode for faster operations