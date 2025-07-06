# Environment Best Practices

This guide provides recommendations for organizing and managing Genesis environments effectively, based on real-world experience with large-scale deployments.

## Naming Conventions

### Choose a Consistent Pattern

Pick one pattern and use it everywhere:

```yaml
# Pattern 1: Organization-first (Recommended)
acme-aws-us-east-1-prod
acme-aws-us-west-2-staging
acme-vsphere-dc1-dev

# Pattern 2: Purpose-last (Also good)
aws-us-east-1-acme-prod
aws-us-west-2-acme-staging
vsphere-dc1-acme-dev
```

### Keep Names Meaningful

Each segment should convey information:

```yaml
# Good - Clear hierarchy
acme-aws-us-east-1-prod
#│    │   │    │    └─ Purpose/Stage
#│    │   │    └────── Availability Zone
#│    │   └─────────── Region
#│    └──────────────── Infrastructure
#└───────────────────── Organization

# Bad - Unclear segments
acme-aws-use1-p
env-1-prod
```

### Document Your Convention

Create a README explaining your naming:

```markdown
# Environment Naming Convention

All environments follow this pattern:
`<org>-<cloud>-<region>-<az>-<purpose>`

- org: Organization identifier (acme, globex)
- cloud: Infrastructure provider (aws, azure, gcp, vsphere)
- region: Geographic region (us-east-1, europe-west1)
- az: Availability zone or datacenter (optional)
- purpose: Environment purpose (prod, staging, dev, sandbox)
```

## Configuration Organization

### Use Hierarchy Effectively

Organize configurations from general to specific:

```yaml
# base.yml - Global settings
params:
  company: ACME Corp
  ntp_servers: [0.pool.ntp.org, 1.pool.ntp.org]

# aws.yml - AWS-wide settings  
params:
  stemcell_os: ubuntu-bionic
  stemcell_version: latest

# aws-us-east-1.yml - Region settings
params:
  region: us-east-1
  availability_zones: [a, b, c]

# aws-us-east-1-prod.yml - Environment specific
params:
  instances: 5
  enable_monitoring: true
```

### Avoid Duplication

Put shared settings at the appropriate level:

```yaml
# Bad - Duplicated in every environment
# aws-us-east-1-dev.yml
params:
  ntp_servers: [10.0.0.1, 10.0.0.2]
  dns_servers: [10.0.0.3, 10.0.0.4]

# aws-us-east-1-prod.yml  
params:
  ntp_servers: [10.0.0.1, 10.0.0.2]  # Duplicate!
  dns_servers: [10.0.0.3, 10.0.0.4]  # Duplicate!

# Good - Shared at region level
# aws-us-east-1.yml
params:
  ntp_servers: [10.0.0.1, 10.0.0.2]
  dns_servers: [10.0.0.3, 10.0.0.4]
```

### Feature Management

Use features consistently:

```yaml
# base.yml - Default features
kit:
  features:
    - base-monitoring
    - base-logging

# prod.yml - Production additions
kit:
  features:
    - base-monitoring
    - base-logging
    - haproxy         # Add load balancer
    - shield-agent    # Add backups
```

## Directory Structure

### Standard Layout

Maintain consistent directory structure:

```
deployments/
├── README.md              # Document your conventions
├── .gitignore            # Exclude caches and secrets
├── bin/                  # Shared scripts and reactions
│   ├── common-functions
│   ├── notify-slack
│   └── update-dns
├── bosh/                 # BOSH directors
│   ├── base.yml
│   ├── aws.yml
│   └── aws-us-east-1.yml
├── vault/                # Vault clusters
│   ├── base.yml
│   └── aws-us-east-1.yml
└── cf/                   # Cloud Foundry
    ├── base.yml
    ├── aws.yml
    ├── aws-us-east-1.yml
    └── aws-us-east-1-prod.yml
```

### Separate Concerns

Keep different deployment types in separate directories:

```bash
# Good - Clear separation
deployments/cf/
deployments/concourse/
deployments/vault/

# Bad - Mixed types
deployments/
├── cf-prod.yml
├── vault-prod.yml
└── concourse-prod.yml
```

## Version Control

### What to Commit

```gitignore
# Always commit
*.yml                    # Environment files
bin/                     # Scripts
ci/                      # Pipeline definitions
README.md                # Documentation

# Never commit
.genesis/cache/          # Downloaded kits
.genesis/manifests/      # Generated manifests
*-secrets.yml           # Any actual secrets
*.key                   # Private keys
*.pem                   # Certificates
```

### Branching Strategy

Use branches for environment promotion:

```bash
# Feature branch for changes
git checkout -b add-monitoring

# Make changes
vim base.yml

# Test in dev
genesis deploy aws-us-east-1-dev

# Merge to main
git checkout main
git merge add-monitoring

# Deploy through environments
genesis deploy aws-us-east-1-staging
genesis deploy aws-us-east-1-prod
```

### Commit Messages

Be descriptive:

```bash
# Good
git commit -m "Enable Shield backups for production CF"
git commit -m "Scale web instances from 3 to 5 in us-east-1"

# Bad
git commit -m "Update config"
git commit -m "Changes"
```

## Security Practices

### Never Store Secrets

Always use Vault references:

```yaml
# Bad - Hardcoded secret
params:
  admin_password: "SuperSecret123!"

# Good - Vault reference
params:
  admin_password: ((vault "secret/path:password"))
```

### Protect Sensitive Configurations

Some configurations reveal infrastructure:

```yaml
# Consider making these Vault references
params:
  aws_access_key: ((vault "secret/aws:access_key"))
  aws_secret_key: ((vault "secret/aws:secret_key"))
  internal_domain: ((vault "secret/networking:internal_domain"))
```

### Audit Access

Regular review access patterns:

```bash
# Check who can deploy to production
safe auth list

# Review Vault policies
safe policy list
```

## Operational Practices

### Environment Promotion

Follow a consistent promotion path:

```
Development → Staging → Production

sandbox → dev → qa → staging → prod
```

### Testing Changes

Always test in lower environments:

```bash
# 1. Deploy to dev
genesis deploy aws-us-east-1-dev

# 2. Run smoke tests
genesis do aws-us-east-1-dev -- smoke-tests

# 3. Promote to staging
genesis deploy aws-us-east-1-staging

# 4. Full integration tests
run-integration-tests staging

# 5. Deploy to production
genesis deploy aws-us-east-1-prod
```

### Documentation

Document everything:

```markdown
## Environment Overview

### Production
- **Environment**: aws-us-east-1-prod
- **Purpose**: Production customer-facing services
- **Maintenance Window**: Sunday 2-4 AM EST
- **Contacts**: ops-team@example.com

### Staging  
- **Environment**: aws-us-east-1-staging
- **Purpose**: Pre-production testing
- **Refresh Schedule**: Weekly from production
- **Contacts**: dev-team@example.com
```

## Troubleshooting Practices

### Manifest Validation

Always check before deploying:

```bash
# Check manifest generation
genesis manifest aws-us-east-1-prod

# Validate changes
genesis manifest aws-us-east-1-prod > new.yml
genesis manifest aws-us-east-1-prod --cached > old.yml
diff old.yml new.yml
```

### Debugging Inheritance

Understand your configuration chain:

```bash
# See full inheritance
genesis describe aws-us-east-1-prod

# Check specific values
genesis lookup aws-us-east-1-prod params.instances
```

### Rollback Procedures

Document rollback steps:

```markdown
## Rollback Procedure

1. Revert Git commit:
   ```bash
   git revert HEAD
   git push
   ```

2. Redeploy previous version:
   ```bash
   genesis deploy aws-us-east-1-prod
   ```

3. Verify services:
   ```bash
   genesis do aws-us-east-1-prod -- smoke-tests
   ```
```

## Performance Tips

### Use Match Mode

Enable for faster operations:

```bash
# Setup in ~/.genesis/config
deployment_roots:
  - ~/deployments

# Use patterns
genesis deploy @prod:cf
genesis list @*:vault
```

### Cache Manifests

For repeated operations:

```bash
# Cache manifest for debugging
genesis manifest my-env --cache

# Use cached version
genesis manifest my-env --cached
```

### Parallel Operations

When safe, run in parallel:

```bash
# Deploy multiple dev environments
genesis deploy aws-us-east-1-dev &
genesis deploy aws-us-west-2-dev &
wait
```

## Common Pitfalls to Avoid

### 1. Inconsistent Naming

Stick to your pattern:
```bash
# Bad - Mixed patterns
aws-us-east-1-prod
aws-west-2-prod      # Missing 'us'
production-aws-east  # Different order
```

### 2. Over-Nesting

Don't create too many levels:
```bash
# Too deep
acme-aws-us-east-1-az-a-vpc-123-subnet-456-prod

# Better
acme-aws-us-east-1a-prod
```

### 3. Environment Sprawl

Regular cleanup:
```bash
# Find unused environments
genesis list | grep -E '(old|test|tmp)'

# Archive old environments
mkdir archived
git mv *-old.yml archived/
```

### 4. Forgetting Vault Paths

Document special paths:
```yaml
# In environment file
# Note: This environment uses custom Vault paths
# Secrets: /secret/special/acme/prod/cf
# Exodus: /secret/exodus/acme-prod/cf
genesis:
  secrets_slug: special/acme/prod
  exodus_slug: acme-prod
```

By following these best practices, you'll maintain clean, understandable, and manageable Genesis deployments that scale with your organization.