# BOSH Overview

BOSH is a project that unifies release engineering, deployment, and lifecycle management of small and large-scale cloud software. Genesis builds on top of BOSH to provide a simpler, more opinionated deployment experience.

## What is BOSH?

BOSH is an open-source tool for release engineering, deployment, lifecycle management, and monitoring of distributed systems. Key features include:

- **Reproducible Deployments**: BOSH ensures that deployments are reproducible across different environments
- **Health Monitoring**: Automatic monitoring and resurrection of VMs
- **Rolling Updates**: Safe, zero-downtime updates with automatic rollback
- **Multi-Cloud Support**: Works with AWS, Azure, GCP, vSphere, OpenStack, and more

## How Genesis Uses BOSH

Genesis acts as a layer on top of BOSH, providing:

### 1. Simplified Manifest Generation

Instead of writing complex BOSH manifests directly, Genesis:
- Uses kits to encapsulate best practices
- Merges environment-specific configurations
- Generates final BOSH manifests automatically

```bash
# Genesis handles manifest generation
genesis manifest my-env

# Equivalent to complex BOSH manifest management
bosh -d my-deployment manifest
```

### 2. Streamlined Deployment Workflow

Genesis wraps BOSH commands with additional features:
- Pre-deployment validation
- Secret management integration
- Post-deployment hooks

```bash
# Genesis deployment
genesis deploy my-env

# Handles multiple BOSH operations:
# - Uploads releases
# - Validates cloud config
# - Manages secrets
# - Deploys manifest
# - Runs errands
```

### 3. Environment Management

Genesis provides a hierarchical environment structure that BOSH doesn't natively support:

```
environments/
├── us.yml          # Shared US configuration
├── us-east.yml     # Shared US-East configuration
├── us-east-1.yml   # Specific environment
└── us-east-2.yml   # Another specific environment
```

## BOSH Components

### BOSH Director

The BOSH Director is the core component that orchestrates deployments:
- Manages VMs lifecycle
- Stores deployment state
- Handles persistent disks
- Monitors system health

Genesis can deploy and manage BOSH directors using the BOSH Genesis kit:

```bash
genesis new my-bosh --kit bosh
genesis deploy my-bosh
```

### Cloud Config

Cloud configuration defines IaaS-specific settings:
- Networks and subnets
- VM types (sizes)
- Availability zones
- Disk types

Genesis validates that required cloud config elements exist:

```bash
# Check cloud config compatibility
genesis check my-env

# Update cloud config
bosh update-cloud-config cloud.yml
```

### Releases

BOSH releases contain the software to be deployed:
- Source code
- Configuration files
- Scripts
- Dependencies

Genesis kits specify which releases to use:

```yaml
# In kit.yml
releases:
  - name: concourse
    version: 7.8.3
  - name: postgres
    version: 43
```

### Stemcells

Stemcells are base OS images that BOSH uses to create VMs:
- Ubuntu-based by default
- IaaS-specific versions
- Security-hardened

Genesis kits define required stemcells:

```yaml
# In kit.yml
stemcells:
  - os: ubuntu-jammy
    version: latest
```

## BOSH vs Genesis Concepts

| BOSH Concept | Genesis Equivalent | Description |
|--------------|-------------------|-------------|
| Deployment | Environment | A running instance of software |
| Manifest | Generated from kit + environment | Deployment configuration |
| Cloud Config | Cloud Config (same) | IaaS settings |
| Runtime Config | Runtime Config (same) | Cross-deployment configuration |
| Release | Specified in kit | Software packages |
| Stemcell | Specified in kit | Base OS image |

## BOSH State Management

BOSH maintains state about deployments:
- Current VM instances
- Persistent disk attachments
- Network configurations
- Software versions

Genesis respects BOSH state while adding:
- Secret rotation tracking
- Feature flag management
- Deployment history

## Integration Points

### Direct BOSH Commands

You can always use BOSH commands directly:

```bash
# Get BOSH environment details
genesis bosh my-env

# Then use any BOSH command
bosh -d my-deployment vms
bosh -d my-deployment ssh
bosh -d my-deployment logs
```

### BOSH Targeting

Genesis automatically configures BOSH targeting:

```bash
# Genesis sets up BOSH environment
genesis do my-env -- bash
# Now $BOSH_ENVIRONMENT, $BOSH_CLIENT, etc. are set
```

### Deployment Names

Genesis uses consistent deployment naming:
- Environment name: `us-east-1-prod`
- BOSH deployment: `us-east-1-prod-concourse`
- Format: `[env-name]-[kit-name]`

## When to Use BOSH Directly

While Genesis handles most operations, use BOSH directly for:

1. **Debugging**: Examining VM state, logs, processes
2. **Advanced Operations**: Recreating VMs, manual resurrection
3. **Emergency Recovery**: Fixing broken deployments
4. **Custom Errands**: Running deployment-specific tasks

```bash
# Common BOSH operations
bosh -d my-deployment vms --vitals
bosh -d my-deployment recreate web/0
bosh -d my-deployment cloud-check
bosh -d my-deployment run-errand smoke-tests
```

## Best Practices

1. **Let Genesis Handle Manifests**: Don't modify generated manifests directly
2. **Use Genesis Deploy**: Prefer `genesis deploy` over `bosh deploy`
3. **Understand the Stack**: Know when to use Genesis vs BOSH commands
4. **Monitor BOSH Health**: Keep directors updated and healthy
5. **Backup BOSH State**: Regular director database backups

Understanding BOSH fundamentals helps you troubleshoot issues and perform advanced operations while leveraging Genesis for day-to-day deployment management.