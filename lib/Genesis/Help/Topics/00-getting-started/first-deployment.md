# Your First Genesis Deployment

This guide walks you through deploying your first environment with Genesis. We'll deploy a BOSH director, which is the foundation for all other deployments.

## Prerequisites

Before starting, ensure you have:
- [Genesis installed](installation.md) with all dependencies
- [Basic configuration](configuration.md) in place
- Access to a supported IaaS (AWS, Azure, GCP, vSphere, or OpenStack)
- IaaS credentials ready

## Step 1: Initialize a Repository

Create a new Genesis repository for BOSH deployments:

```bash
# Create and enter the repository
genesis init --kit bosh my-bosh-deployments
cd my-bosh-deployments
```

This creates:
- A Git repository for version control
- `.genesis/` directory for Genesis metadata
- Initial kit configuration

## Step 2: Select Your Infrastructure

Genesis needs to know what infrastructure you're using:

```bash
# List available features for the BOSH kit
genesis info bosh
```

Common infrastructure features:
- `aws` - Amazon Web Services
- `azure` - Microsoft Azure  
- `google` - Google Cloud Platform
- `vsphere` - VMware vSphere
- `openstack` - OpenStack

## Step 3: Create an Environment

Create your first environment file:

```bash
# Create a new environment (interactive wizard)
genesis new my-lab
```

The wizard will ask for:
1. **Infrastructure type** - Select your IaaS
2. **Environment name** - A descriptive name
3. **Vault prefix** - Where to store secrets
4. **Network configuration** - Subnet ranges
5. **IaaS-specific details** - Credentials, regions, etc.

## Step 4: Review Configuration

Examine the generated environment file:

```bash
# View the environment configuration
cat my-lab.yml
```

Example AWS configuration:
```yaml
---
kit:
  name: bosh
  version: 2.2.0
  features:
    - aws
    - proto

params:
  env:     my-lab
  bosh_vm_type: t3.small
  
  # AWS Configuration
  aws_region: us-east-1
  aws_default_sgs:
    - bosh

  # Networking
  subnet_addr: 10.128.0.0/24
  default_gateway: 10.128.0.1
  dns:
    - 8.8.8.8
    - 8.8.4.4
```

## Step 5: Configure Vault

Genesis uses Vault to store secrets. If you don't have Vault running:

```bash
# Start a development Vault (for testing only!)
safe init
safe verify
```

For production, use a properly configured Vault cluster.

## Step 6: Generate Cloud Config

For AWS, Azure, or GCP, generate the required cloud config:

```bash
# Generate IaaS configuration
genesis do my-lab -- cloud-config
```

This creates the necessary IaaS resources:
- Networks and subnets
- Security groups
- SSH keys
- Other IaaS-specific resources

## Step 7: Deploy

Now deploy your BOSH director:

```bash
# Verify everything looks correct
genesis check my-lab

# Deploy (this takes 15-30 minutes)
genesis deploy my-lab
```

Genesis will:
1. Generate required secrets in Vault
2. Create the BOSH manifest
3. Deploy the BOSH director
4. Configure local BOSH CLI access

## Step 8: Verify Deployment

Once deployed, verify your BOSH director:

```bash
# Target the new BOSH director
genesis do my-lab -- login

# Check BOSH status
bosh env

# View deployments (should be empty)
bosh deployments
```

## Common Issues

### Deployment Fails

If deployment fails:
```bash
# Check the deployment log
genesis deploy my-lab -l debug

# View BOSH task output
bosh task <task-id> --debug
```

### Network Issues

Ensure:
- Subnet ranges don't overlap
- Security groups allow required ports
- DNS servers are reachable

### Credential Problems

For IaaS credential issues:
```bash
# Re-run the new wizard
genesis new my-lab --force

# Or edit directly
vim my-lab.yml
```

## Next Steps

Congratulations! You've deployed your first Genesis environment. Now you can:

### Deploy Additional Software

```bash
# Initialize a Vault deployment repository
cd ..
genesis init --kit vault my-vault-deployments
cd my-vault-deployments

# Create Vault environment targeting your BOSH
genesis new my-vault
```

### Learn More

- [Environment Management](../10-environments/index.md) - Managing multiple environments
- [Secrets Management](../30-secrets-management/index.md) - Working with Vault
- [Using Kits](../50-kits/index.md) - Deploying other software

### Useful Commands

```bash
# List all Genesis environments
genesis list

# Show environment details
genesis describe my-lab

# Rotate credentials
genesis rotate-secrets my-lab

# SSH to BOSH director
genesis do my-lab -- ssh

# View generated manifest
genesis manifest my-lab
```

## Clean Up

To destroy the environment when done testing:

```bash
# Delete the deployment
genesis do my-lab -- destroy

# Remove environment file
rm my-lab.yml
git add -A
git commit -m "Removed lab environment"
```

## Production Considerations

For production deployments:

1. **Use proper Vault** - Not the dev server
2. **Configure backups** - Use Shield or BBR
3. **Enable monitoring** - Prometheus exporters
4. **Set up CI/CD** - Concourse pipelines
5. **Document everything** - Including credentials and procedures

See the [BOSH kit documentation](../50-kits/bosh.md) for production configuration details.