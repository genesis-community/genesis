# BOSH Integration

Genesis environments map directly to BOSH deployments. Understanding this relationship is crucial for debugging, manual BOSH operations, and advanced deployment scenarios.

## BOSH Director Selection

### Automatic Selection

By default, Genesis deploys to a BOSH director with the same name as the environment:

```yaml
# Environment: acme-aws-us-east-1-prod.yml
# Deploys to: acme-aws-us-east-1-prod BOSH director
```

### Manual Override

Override the target BOSH director:

```yaml
genesis:
  env: acme-aws-us-east-1-prod
  bosh_env: acme-aws-us-east-1-mgmt  # Use different director
```

Common override scenarios:
- BOSH directors (can't deploy to themselves)
- Shared management directors
- Cross-region deployments

## Deployment Names

### Naming Convention

BOSH deployment names follow the pattern:
```
<environment-name>-<kit-type>
```

Examples:
- Environment: `acme-aws-us-east-1-prod.yml`
- Kit: `cf-genesis-kit`
- BOSH deployment: `acme-aws-us-east-1-prod-cf`

### Viewing Deployments

```bash
# List all deployments on targeted director
bosh deployments

# Filter by Genesis pattern
bosh deployments | grep -- '-cf$'
```

## BOSH Configuration Management

### Cloud Config

Genesis manages BOSH cloud configs with prefixed names:

```yaml
# VM types become prefixed
vm_types:
- name: acme-aws-us-east-1-prod-small
  cloud_properties:
    instance_type: t3.small

# Disk types are prefixed
disk_types:
- name: acme-aws-us-east-1-prod-small
  disk_size: 10240

# Networks remain unprefixed
networks:
- name: default
  type: manual
  subnets: [...]
```

### Runtime Config

Runtime configs can be specified per environment:

```yaml
# In environment file
genesis:
  runtime_configs:
    - my-runtime-config
    - dns-runtime-config
```

### CPI Config

For multi-CPI directors:

```yaml
genesis:
  cpi_configs:
    - aws-cpi-config
```

## Environment Variables

### BOSH Connection

Genesis sets these for BOSH operations:

```bash
BOSH_ENVIRONMENT=10.0.0.6
BOSH_CA_CERT=/tmp/genesis-ca-cert.XXXX
BOSH_CLIENT=admin
BOSH_CLIENT_SECRET=<from-vault>
```

### Manual BOSH Access

```bash
# Get BOSH credentials
genesis do my-env -- login

# Now use BOSH directly
bosh deployments
bosh vms
```

## Deployment Lifecycle

### What Genesis Does

1. **Pre-deployment**:
   - Targets correct BOSH director
   - Uploads required releases
   - Updates cloud/runtime configs
   - Generates manifest

2. **Deployment**:
   - Runs `bosh deploy`
   - Monitors deployment progress
   - Handles errors

3. **Post-deployment**:
   - Runs post-deploy hooks
   - Updates exodus data
   - Cleans up temporary files

### Manual Deployment

For troubleshooting, deploy manually:

```bash
# Generate manifest
genesis manifest my-env > manifest.yml

# Target BOSH
genesis do my-env -- login

# Deploy manually
bosh -d my-env-cf deploy manifest.yml
```

## Advanced Integration

### Instance Management

```bash
# Through Genesis
genesis do my-env -- ssh router/0

# Direct BOSH commands
bosh -d acme-aws-us-east-1-prod-cf ssh router/0
bosh -d acme-aws-us-east-1-prod-cf restart router
```

### Logs and Debugging

```bash
# Get deployment logs
genesis do my-env -- logs

# Specific instance logs
bosh -d my-env-cf logs router/0

# Recent BOSH tasks
bosh tasks --recent
bosh task <id> --debug
```

### Errands

```bash
# Run smoke tests
genesis do my-env -- run-errand smoke-tests

# Direct BOSH errand
bosh -d my-env-cf run-errand smoke-tests
```

## BOSH Teams and UAA

### Multi-Tenancy

Configure BOSH teams in your environment:

```yaml
params:
  bosh_teams:
    - name: developers
      auth:
        type: uaa
        provider: github
      permissions:
        - deployment: my-env-cf
          operations: ["read", "ssh"]
```

### Authentication

```yaml
params:
  bosh_auth:
    type: uaa
    uaa_url: https://uaa.example.com
    client_id: genesis
    client_secret: ((uaa_client_secret))
```

## Cloud Config Details

### VM Type Mapping

Genesis maps kit VM types to cloud config:

```yaml
# Kit requests
instance_groups:
- name: web
  vm_type: small

# Genesis prefixes for uniqueness
# Uses: acme-aws-us-east-1-prod-small
```

### Network Selection

Networks are not prefixed:

```yaml
# Environment file
params:
  cf_network: cf-net
  
# Cloud config
networks:
- name: cf-net  # Used as-is
  subnets: [...]
```

### Availability Zones

```yaml
params:
  availability_zones:
    - z1
    - z2
    - z3
```

## Troubleshooting

### Deployment Not Found

Check:
- Correct BOSH director targeted
- Deployment name includes kit suffix
- Environment was actually deployed

### Cloud Config Issues

```bash
# View current cloud config
bosh cloud-config

# Check for prefixed types
bosh cloud-config | grep my-env

# Update cloud config
genesis do my-env -- cloud-config
```

### Version Mismatches

```bash
# Check BOSH version
bosh env

# Genesis expects BOSH v2 CLI
genesis -v
```

### Authentication Problems

```bash
# Re-authenticate
genesis do my-env -- login

# Check credentials in Vault
safe get secret/exodus/my-env-bosh/bosh
```

## Best Practices

### 1. Use Genesis Commands

Prefer Genesis commands over direct BOSH:
- Handles authentication
- Maintains consistency
- Includes Genesis features

### 2. Understand the Mapping

Know how Genesis names map to BOSH:
- Helps with debugging
- Enables manual intervention
- Useful for monitoring

### 3. Document Overrides

When overriding BOSH director:
```yaml
genesis:
  # Document why this override exists
  bosh_env: shared-mgmt  # Using shared director for cost savings
```

### 4. Monitor Both Layers

Monitor at both levels:
- Genesis operations (deployments, rotations)
- BOSH health (VMs, disks, compilations)

### 5. Backup Considerations

```bash
# Backup BOSH director state
genesis do my-bosh -- bbr backup

# Includes:
# - Deployment manifests
# - Cloud configs
# - BOSH database
```

## Integration Examples

### CI/CD Pipeline

```yaml
# Concourse task
- name: deploy-cf
  plan:
  - task: genesis-deploy
    config:
      run:
        path: genesis
        args: ["deploy", "my-env", "--yes"]
```

### Monitoring Integration

```bash
# Prometheus BOSH exporter config
jobs:
- name: bosh_exporter
  properties:
    bosh:
      url: ((exodus.my-env-bosh.bosh.url))
      ca_cert: ((exodus.my-env-bosh.bosh.ca_cert))
      username: ((exodus.my-env-bosh.bosh.admin_username))
      password: ((exodus.my-env-bosh.bosh.admin_password))
```

### Custom Scripts

```bash
#!/bin/bash
# Scale CF cells

ENV="acme-aws-us-east-1-prod"
DEPLOYMENT="${ENV}-cf"

# Login to BOSH
genesis do $ENV -- login

# Scale cells
bosh -d $DEPLOYMENT scale diego-cell=10
```

Understanding BOSH integration enables you to:
- Debug deployment issues
- Perform manual operations
- Integrate with existing tools
- Build custom automation