# Core Genesis Concepts

Understanding these fundamental concepts will help you use Genesis effectively.

## Kits

A **kit** is a pre-packaged template for deploying a specific type of software with BOSH. Kits encapsulate:

- **Manifest Templates** - YAML templates that generate BOSH manifests
- **Default Configuration** - Sensible defaults and best practices
- **Features** - Optional components you can enable/disable
- **Secrets Definitions** - What credentials and certificates to generate
- **Lifecycle Hooks** - Scripts that run during deployment phases

### Example Kits
- `bosh-genesis-kit` - Deploy BOSH directors
- `cf-genesis-kit` - Deploy Cloud Foundry
- `vault-genesis-kit` - Deploy Vault clusters
- `concourse-genesis-kit` - Deploy Concourse CI

## Repositories

A **repository** is a Git repository containing related Genesis deployments. Repositories provide:

- Version control for your infrastructure
- Shared configuration across environments
- Audit trail of changes
- Collaboration through pull requests

### Repository Structure
```
my-deployments/
├── .genesis/
│   ├── bin/          # Repository-specific scripts
│   ├── cache/        # Downloaded kit cache
│   └── kits/         # Local kit overrides
├── us-east-1.yml     # Region configuration
├── us-east-1-prod.yml # Environment file
└── us-east-1-dev.yml  # Environment file
```

## Environments

An **environment** represents a single deployment. Each environment:

- Has its own YAML configuration file
- Inherits from parent configurations
- Generates a unique BOSH manifest
- Maintains its own secrets in Vault

### Environment Files
```yaml
---
kit:
  name: bosh
  version: 2.2.0
  features:
    - aws
    - proto

params:
  env: us-east-1-prod
  aws_region: us-east-1
```

## Hierarchical Configuration

Genesis uses **hierarchical configuration** to avoid repetition:

1. **Global** - Repository-wide defaults
2. **Regional** - Infrastructure-specific settings
3. **Environmental** - Deployment-specific overrides

### Example Hierarchy
```
site.yml           # Global settings for all environments
└── us.yml         # US-specific settings
    └── us-east.yml    # us-east region settings
        └── us-east-1.yml      # Specific environment
            └── us-east-1-prod.yml # Most specific
```

### Configuration Merging
```yaml
# site.yml
params:
  vault: https://vault.example.com:8200

# us.yml  
params:
  domain: us.example.com

# us-east-1-prod.yml
params:
  env: prod
  # Inherits vault and domain from parents
```

## Features

**Features** are optional kit components you can enable:

```yaml
kit:
  features:
    - vsphere        # vSphere infrastructure
    - syslog         # Syslog forwarding
    - prometheus     # Metrics exporter
```

Features can:
- Add manifest snippets
- Require additional parameters
- Generate specific secrets
- Run validation checks

## Secrets Management

Genesis integrates with **Vault** (or CredHub) for secrets:

### Automatic Generation
- Passwords and credentials
- SSH keys
- X.509 certificates
- RSA key pairs

### Secret Paths
Secrets follow a predictable path structure:
```
secret/us-east-1/prod/bosh/
├── admin_password
├── ca
├── director_tls
└── db_password
```

### Secret Rotation
```bash
# Rotate specific secrets
genesis rotate-secrets my-env admin_password

# Rotate all secrets
genesis rotate-secrets my-env --all
```

## Lifecycle Hooks

**Hooks** are scripts that run at specific times:

- **new** - When creating a new environment
- **blueprint** - When generating the manifest
- **check** - Pre-deployment validation
- **pre-deploy** - Before deployment
- **post-deploy** - After deployment
- **addon** - Custom operator scripts

## Deployment Workflow

The typical Genesis workflow:

1. **Initialize** - Create a repository with a kit
2. **Configure** - Create environment files
3. **Generate Secrets** - Auto-generate credentials
4. **Deploy** - Push to BOSH
5. **Manage** - Update, rotate secrets, scale

### Example Workflow
```bash
# Initialize repository
genesis init --kit vault my-vault-deployments
cd my-vault-deployments

# Create environment
genesis new us-east-prod

# Edit configuration
vim us-east-prod.yml

# Check and deploy
genesis check us-east-prod
genesis deploy us-east-prod
```

## Manifest Generation

Genesis generates BOSH manifests by:

1. Loading the kit's base manifest
2. Applying features
3. Merging environment parameters
4. Injecting secrets from Vault
5. Running blueprint hooks

You can view the generated manifest:
```bash
genesis manifest my-env
```

## Best Practices

1. **Use Version Control** - Commit all environment files
2. **Hierarchical Config** - Share common settings
3. **Feature Flags** - Use features instead of manual overrides
4. **Secret Rotation** - Regularly rotate credentials
5. **Environment Naming** - Use consistent naming patterns

## Next Steps

Now that you understand the concepts:
- [Configure Genesis](configuration.md) for your needs
- Create your [First Deployment](first-deployment.md)
- Learn about [Environment Management](../10-environments/index.md)