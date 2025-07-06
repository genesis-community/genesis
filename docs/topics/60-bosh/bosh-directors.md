# BOSH Directors

The BOSH Director is the core component that orchestrates deployments. This guide covers deploying and managing BOSH directors using Genesis.

## Overview

A BOSH Director:
- Manages the lifecycle of VMs and software
- Stores deployment state and configuration
- Monitors health and resurrects failed VMs
- Handles persistent disks and snapshots
- Manages releases, stemcells, and deployments

## Deploying a BOSH Director with Genesis

Genesis provides a BOSH kit for deploying directors:

### Initial Setup

```bash
# Create a new BOSH deployment repository
genesis init my-bosh --kit bosh
cd my-bosh

# Create a new BOSH environment
genesis new my-bosh
```

### Configuration Options

The BOSH kit will prompt for:

1. **Static IP Address**: The director's IP
2. **IaaS Selection**: AWS, Azure, GCP, vSphere, etc.
3. **Network Configuration**: Subnet, gateway, DNS
4. **IaaS Credentials**: Cloud provider access

### Example Environment File

```yaml
---
genesis:
  env:          my-bosh
  secrets_path: my/bosh

kit:
  features:
    - aws
    - proto-bosh
    - bosh-init

params:
  # Static IP for director
  static_ip: 10.0.0.6

  # AWS Configuration
  aws_region: us-east-1
  aws_default_sgs:
    - sg-0123456789abcdef0  # BOSH security group

  # Network Configuration  
  subnet_id: subnet-0123456789abcdef0
  external_domain: bosh.example.com
  
  # Director Name
  director_name: my-bosh
```

### Deployment

```bash
# Deploy the BOSH director
genesis deploy my-bosh

# This will:
# 1. Create the director VM
# 2. Install BOSH software
# 3. Configure the database
# 4. Start BOSH services
```

## Proto-BOSH vs Regular BOSH

### Proto-BOSH

The first BOSH director in an environment (bootstrapping):
- Deployed using `bosh create-env`
- Manages its own lifecycle
- Requires the `proto-bosh` feature

```yaml
kit:
  features:
    - proto-bosh
    - aws
```

### Regular BOSH

Subsequent directors managed by another BOSH:
- Deployed using standard `bosh deploy`
- Managed by a parent director
- More resilient and easier to update

```yaml
kit:
  features:
    - aws
    # No proto-bosh feature
```

## Managing Multiple Directors

### Director Hierarchy

Common patterns:

```
proto-bosh (global)
├── regional-bosh-us-east
├── regional-bosh-us-west
└── regional-bosh-eu-west
    ├── env-bosh-dev
    ├── env-bosh-staging
    └── env-bosh-prod
```

### Configuration Management

Use hierarchical configuration:

```yaml
# global.yml
params:
  trusted_certs: |
    -----BEGIN CERTIFICATE-----
    # Corporate CA cert
    -----END CERTIFICATE-----

# us-east.yml  
params:
  aws_region: us-east-1
  ntp_servers:
    - 0.amazon.pool.ntp.org
    - 1.amazon.pool.ntp.org

# us-east-prod.yml
params:
  static_ip: 10.0.0.6
  director_name: us-east-prod-bosh
```

## Director Features

### Core Features

Available in all deployments:
- **Health Monitor**: VM monitoring and resurrection
- **Database**: PostgreSQL for state storage
- **NATS**: Message bus for agent communication
- **Blobstore**: Release and package storage

### Optional Features

Enable via kit features:

#### UAA Authentication

```yaml
kit:
  features:
    - uaa
params:
  uaa_admin_client_secret: ((uaa-admin-secret))
```

#### CredHub Integration

```yaml
kit:
  features:
    - credhub
params:
  credhub_encryption_password: ((credhub-encryption))
```

#### Compiled Releases

```yaml
kit:
  features:
    - compiled-releases
params:
  compiled_releases_bucket: my-compiled-releases
```

#### BBR (BOSH Backup and Restore)

```yaml
kit:
  features:
    - bbr
```

## Director Operations

### Accessing the Director

```bash
# Get connection info
genesis bosh my-bosh

# Target the director
export BOSH_ENVIRONMENT=10.0.0.6
export BOSH_CLIENT=admin
export BOSH_CLIENT_SECRET=$(safe get secret/my/bosh/director:password)
export BOSH_CA_CERT=$(safe get secret/my/bosh/director:ca)

# Verify connection
bosh env
```

### Common Management Tasks

#### Update Cloud Config

```bash
# After deploying director
bosh update-cloud-config cloud-config.yml

# Verify
bosh cloud-config
```

#### Upload Stemcells

```bash
# Upload Ubuntu stemcell
bosh upload-stemcell \
  https://bosh.io/d/stemcells/bosh-aws-xen-hvm-ubuntu-jammy-go_agent

# List stemcells
bosh stemcells
```

#### Manage Releases

```bash
# Upload releases
bosh upload-release \
  https://bosh.io/d/github.com/cloudfoundry/cf-deployment

# View releases
bosh releases
```

### Director Maintenance

#### Updating the Director

```bash
# Update BOSH deployment
genesis deploy my-bosh

# This safely:
# 1. Updates director software
# 2. Migrates database if needed
# 3. Restarts services
```

#### Backing Up the Director

```bash
# Using BBR
genesis do my-bosh -- backup

# Manual backup
genesis do my-bosh -- bash
bosh create-env backup.yml \
  --vars-store backup-creds.yml
```

#### Monitoring Director Health

```bash
# Check director status
bosh env

# View director tasks
bosh tasks --recent

# Check VM vitals
genesis do my-bosh -- bosh vms --vitals
```

## Advanced Configuration

### Custom Properties

```yaml
params:
  # Database settings
  postgres_max_connections: 100
  
  # Director settings
  director_worker_count: 8
  director_enable_snapshots: true
  
  # Health monitor
  hm_email_recipients:
    - ops-team@example.com
  hm_email_from: bosh@example.com
  
  # Blobstore
  blobstore_type: s3
  blobstore_bucket: my-bosh-blobstore
```

### Network Configuration

```yaml
params:
  # Multiple networks
  networks:
    - name: bosh
      type: manual
      subnets:
        - range: 10.0.0.0/24
          gateway: 10.0.0.1
          static: [10.0.0.6]
          dns: [10.0.0.2]
          cloud_properties:
            subnet: subnet-0123456
```

### Security Hardening

```yaml
params:
  # Remove default users
  remove_dev_users: true
  
  # Enable audit logging
  director_enable_audit: true
  
  # Restrict API access
  director_api_accept_from:
    - 10.0.0.0/16
    - 192.168.0.0/16
```

## Troubleshooting Directors

### Common Issues

#### Director Unreachable

```bash
# Check VM status (if using proto-bosh)
cd my-bosh-deployments
bosh create-env manifests/bosh.yml \
  --state state.json \
  --vars-store creds.yml

# Check network connectivity
ping 10.0.0.6
nc -zv 10.0.0.6 25555
```

#### Database Issues

```bash
# SSH to director
genesis do my-bosh -- bosh ssh

# Check PostgreSQL
sudo -u vcap psql -U postgres
\l  # List databases
\q  # Quit

# Check logs
sudo tail -f /var/vcap/sys/log/postgres/*.log
```

#### Certificate Issues

```bash
# Regenerate certificates
safe x509 renew secret/my/bosh/director

# Redeploy
genesis deploy my-bosh
```

### Recovery Procedures

#### Restore from Backup

```bash
# Using BBR
genesis do my-bosh -- restore --artifact-path=./backup

# Manual restore
bosh create-env restore.yml \
  --state state.json \
  --vars-store creds.yml
```

#### Rebuild Director

```bash
# Last resort - rebuild
# 1. Backup deployment manifests
# 2. Note all deployments
# 3. Redeploy director
genesis deploy my-bosh --recreate

# 4. Restore cloud configs
# 5. Re-upload stemcells/releases
# 6. Redeploy all deployments
```

## Best Practices

1. **Regular Backups**: Schedule automated BBR backups
2. **Monitor Health**: Set up alerts for director issues
3. **Update Regularly**: Keep director software current
4. **Separate Directors**: Use different directors for prod/non-prod
5. **Document Configuration**: Maintain clear documentation
6. **Test Recovery**: Regularly test backup/restore procedures

Managing BOSH directors effectively is crucial for maintaining healthy Genesis deployments across your infrastructure.