# Environment File Structure

Understanding how to organize your Genesis environment files is crucial for maintainable deployments. This guide covers directory layouts, file organization patterns, and best practices.

## Basic Structure

### Single Kit Repository
```
my-cf-deployments/
├── .genesis/
│   ├── config         # Repository configuration
│   ├── cache/         # Downloaded kits
│   └── kits/          # Local kit overrides
├── .gitignore
├── README.md
├── base.yml           # Global defaults (optional)
├── aws.yml            # AWS-specific settings
├── aws-us.yml         # US region settings
├── aws-us-east-1.yml  # Specific region settings
├── aws-us-east-1-dev.yml      # Development environment
├── aws-us-east-1-staging.yml  # Staging environment
└── aws-us-east-1-prod.yml     # Production environment
```

### Environment File Contents

A typical environment file contains:

```yaml
---
# Kit configuration
kit:
  name: cf
  version: 2.3.0
  features:
    - haproxy
    - postgres
    - routing-api

# Environment parameters
params:
  # Environment identification
  env: aws-us-east-1-prod
  
  # Infrastructure settings
  availability_zones:
    - us-east-1a
    - us-east-1b
    - us-east-1c
  
  # CF-specific configuration
  base_domain: cf.example.com
  skip_ssl_validation: false
  
  # Resource sizing
  cell_instances: 3
  router_instances: 2
```

## Multi-Kit Organization

### Deployment Root Structure

For organizations with multiple kits:

```
deployments/                    # Deployment root
├── .genesis/
│   └── config                 # Root configuration
├── bosh/                      # BOSH directors
│   ├── .genesis/config
│   ├── aws.yml
│   ├── aws-us-east-1.yml
│   └── aws-us-west-2.yml
├── vault/                     # Vault deployments
│   ├── .genesis/config
│   ├── aws.yml
│   └── aws-us-east-1.yml
├── cf/                        # Cloud Foundry
│   ├── .genesis/config
│   ├── base.yml
│   ├── aws.yml
│   ├── aws-us-east-1-dev.yml
│   ├── aws-us-east-1-staging.yml
│   └── aws-us-east-1-prod.yml
└── concourse/                 # Concourse CI
    ├── .genesis/config
    ├── aws.yml
    └── aws-us-east-1.yml
```

### Benefits of This Structure

1. **Clear Separation** - Each kit has its own directory
2. **Shared Settings** - Common configs at deployment root
3. **Easy Navigation** - Predictable locations
4. **Git Flexibility** - Can be one repo or many

## Operations Files

### Using Ops Files

Operations files modify the base manifest during compilation:

```
cf-deployments/
├── aws-us-east-1-prod.yml
└── ops/
    ├── enable-debug.yml       # Debugging features
    ├── scale-cells.yml        # Custom scaling
    └── custom-certificates.yml # Additional certs
```

Reference in environment file:
```yaml
kit:
  features:
    - enable-debug      # Looks for ops/enable-debug.yml
    - scale-cells
```

### Ops File Example

```yaml
# ops/scale-cells.yml
- type: replace
  path: /instance_groups/name=diego-cell/instances
  value: 10

- type: replace
  path: /instance_groups/name=diego-cell/vm_type
  value: large
```

## Hierarchical Files

### Inheritance Chain Example

```
deployments/cf/
├── base.yml                   # Level 1: Global defaults
├── aws.yml                    # Level 2: AWS-wide settings
├── aws-us.yml                 # Level 3: US regions
├── aws-us-east-1.yml          # Level 4: Specific region
└── aws-us-east-1-prod.yml     # Level 5: Final environment
```

### What Goes Where

#### Global Level (`base.yml`)
```yaml
params:
  # Company-wide settings
  company_name: ACME Corp
  
  # Default DNS servers
  dns:
    - 8.8.8.8
    - 8.8.4.4
  
  # Security policies
  password_policy:
    min_length: 14
    require_special: true
```

#### Infrastructure Level (`aws.yml`)
```yaml
params:
  # AWS-specific settings
  cloud_provider: aws
  
  # AWS instance types
  default_vm_type: t3.small
  
  # Availability zones format
  availability_zone_pattern: "{region}{az}"
```

#### Region Level (`aws-us-east-1.yml`)
```yaml
params:
  # Region configuration
  region: us-east-1
  
  # Regional endpoints
  s3_endpoint: https://s3.us-east-1.amazonaws.com
  
  # Network ranges
  management_network: 10.0.0.0/16
```

#### Environment Level (`aws-us-east-1-prod.yml`)
```yaml
params:
  # Environment specifics
  env: production
  
  # Scaling parameters
  instances: 5
  
  # Environment-specific domains
  system_domain: prod.cf.example.com
  apps_domain: apps.example.com
```

## Alternative Patterns

### By Purpose First
```
deployments/
├── production/
│   ├── cf/
│   ├── bosh/
│   └── vault/
├── staging/
│   ├── cf/
│   ├── bosh/
│   └── vault/
└── development/
    ├── cf/
    ├── bosh/
    └── vault/
```

### By Region First
```
deployments/
├── us-east-1/
│   ├── cf/
│   ├── bosh/
│   └── vault/
├── us-west-2/
│   ├── cf/
│   ├── bosh/
│   └── vault/
└── eu-west-1/
    ├── cf/
    ├── bosh/
    └── vault/
```

## Supporting Files

### README Files

Include documentation:
```markdown
# Cloud Foundry Deployments

This repository contains Genesis CF deployments.

## Environments

- `aws-us-east-1-dev` - Development environment
- `aws-us-east-1-staging` - Staging (pre-production)
- `aws-us-east-1-prod` - Production

## Deployment

```bash
genesis deploy aws-us-east-1-prod
```
```

### .gitignore

Standard Genesis gitignore:
```
# Genesis
.genesis/cache/
.genesis/config
.genesis/manifests/
.genesis/releases/
.genesis/kits/

# Editor files
.*.sw?
*~

# OS files
.DS_Store
Thumbs.db

# Temporary files
*.tmp
```

### CI/CD Files

Pipeline configuration:
```
cf-deployments/
├── ci/
│   ├── pipeline.yml
│   ├── scripts/
│   │   ├── test.sh
│   │   └── deploy.sh
│   └── settings.yml
└── .concourse/
    └── secrets.yml
```

## Best Practices

### 1. Consistent Naming
- Use the same pattern everywhere
- Document your conventions
- Stick to lowercase and hyphens

### 2. Logical Grouping
- Group by kit type, not by environment
- Keep related environments together
- Use hierarchy to reduce duplication

### 3. Version Control
```bash
# Track everything except caches
git add -A
git commit -m "Added production environment"

# Don't track
# - .genesis/cache/
# - .genesis/manifests/
# - Any secrets
```

### 4. Documentation
- README in each kit directory
- Comment complex configurations
- Document non-obvious choices

### 5. Secrets Management
- Never commit secrets
- Use Vault references
- Document secret requirements

## Common Patterns

### Development Workflow
```
cf/
├── dev.yml            # Shared dev settings
├── john-dev.yml       # Personal dev environment
├── mary-dev.yml       # Personal dev environment
└── ci-dev.yml         # CI test environment
```

### Multi-Datacenter
```
cf/
├── dc1.yml            # Datacenter 1 base
├── dc1-prod.yml       # DC1 production
├── dc1-dr.yml         # DC1 disaster recovery
├── dc2.yml            # Datacenter 2 base
├── dc2-prod.yml       # DC2 production
└── dc2-dr.yml         # DC2 disaster recovery
```

### Blue-Green Deployments
```
cf/
├── prod.yml           # Shared production settings
├── prod-blue.yml      # Blue environment
└── prod-green.yml     # Green environment
```

## Troubleshooting

### File Not Found
- Check exact filename and extension
- Verify you're in the right directory
- Ensure .yml extension is present

### Inheritance Issues
- Verify parent files exist
- Check for typos in names
- Review hyphen placement

### Merge Conflicts
- Use explicit keys in child files
- Override entire structures when needed
- Test with `genesis manifest` to verify