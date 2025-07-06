# Available Genesis Kits

This catalog lists official Genesis kits maintained by the Genesis Community, along with their primary use cases and key features.

## Infrastructure Kits

### BOSH Director Kit

**Repository**: [bosh-genesis-kit](https://github.com/genesis-community/bosh-genesis-kit)

Deploy BOSH directors for managing your infrastructure.

**Key Features**:
- `aws`, `azure`, `gcp`, `vsphere`, `openstack` - IaaS support
- `proto` - Proto-BOSH for bootstrapping
- `bosh-init` - Legacy create-env support
- `bbr` - BOSH Backup & Restore
- `vault-credhub-proxy` - CredHub integration

**Common Usage**:
```yaml
kit:
  name: bosh
  features:
    - aws
    - proto
    - vault-credhub-proxy
```

### Vault Kit

**Repository**: [vault-genesis-kit](https://github.com/genesis-community/vault-genesis-kit)

Deploy HashiCorp Vault for secrets management.

**Key Features**:
- `consul`, `raft`, `file` - Storage backends
- `auto-unseal` - Cloud KMS unsealing
- `ha` - High availability mode
- `monitoring` - Prometheus metrics

**Common Usage**:
```yaml
kit:
  name: vault
  features:
    - raft
    - auto-unseal
    - monitoring
```

## Platform Kits

### Cloud Foundry Kit

**Repository**: [cf-genesis-kit](https://github.com/genesis-community/cf-genesis-kit)

Deploy full Cloud Foundry platforms.

**Key Features**:
- `haproxy`, `routing-api` - Routing options
- `postgres`, `mysql` - Database backends
- `azure-blobstore`, `s3-blobstore` - Blob storage
- `container-routing`, `loggregator-forwarder-agent`
- `small-footprint`, `minimum-vms` - Sizing options

**Common Usage**:
```yaml
kit:
  name: cf
  features:
    - haproxy
    - postgres
    - s3-blobstore
    - routing-api
```

### Kubernetes Kit

**Repository**: [k8s-genesis-kit](https://github.com/genesis-community/k8s-genesis-kit)

Deploy Kubernetes clusters with BOSH.

**Key Features**:
- `flannel`, `calico` - Network providers
- `dashboard` - Kubernetes dashboard
- `monitoring` - Cluster monitoring
- `ingress` - Ingress controller

**Common Usage**:
```yaml
kit:
  name: k8s
  features:
    - flannel
    - dashboard
    - monitoring
```

## CI/CD Kits

### Concourse Kit

**Repository**: [concourse-genesis-kit](https://github.com/genesis-community/concourse-genesis-kit)

Deploy Concourse CI/CD systems.

**Key Features**:
- `github-oauth`, `cf-auth` - Authentication
- `prometheus` - Metrics exporter
- `vault` - Vault integration
- `workers` - External workers
- `no-tls`, `provided-cert` - Certificate options

**Common Usage**:
```yaml
kit:
  name: concourse
  features:
    - github-oauth
    - prometheus
    - vault
```

### Jenkins Kit

**Repository**: [jenkins-genesis-kit](https://github.com/genesis-community/jenkins-genesis-kit)

Deploy Jenkins automation servers.

**Key Features**:
- `github-oauth` - GitHub authentication
- `ldap` - LDAP integration
- `slaves` - Distributed builds
- `backup` - Automated backups

## Database Kits

### PostgreSQL Kit

**Repository**: [postgres-genesis-kit](https://github.com/genesis-community/postgres-genesis-kit)

Deploy standalone PostgreSQL databases.

**Key Features**:
- `ha` - High availability
- `monitoring` - Database metrics
- `backups` - Automated backups
- `tls` - Encrypted connections

**Common Usage**:
```yaml
kit:
  name: postgres
  features:
    - ha
    - monitoring
    - backups
```

### Redis Kit

**Repository**: [redis-genesis-kit](https://github.com/genesis-community/redis-genesis-kit)

Deploy Redis key-value stores.

**Key Features**:
- `cluster` - Redis cluster mode
- `sentinel` - High availability
- `persistent` - Disk persistence
- `shield` - Backup integration

## Monitoring Kits

### Prometheus Kit

**Repository**: [prometheus-genesis-kit](https://github.com/genesis-community/prometheus-genesis-kit)

Deploy Prometheus monitoring stacks.

**Key Features**:
- `grafana` - Visualization
- `alertmanager` - Alert routing
- `node-exporter` - System metrics
- `postgres-exporter`, `mysql-exporter` - Database monitoring

**Common Usage**:
```yaml
kit:
  name: prometheus
  features:
    - grafana
    - alertmanager
    - node-exporter
```

### Blacksmith Kit

**Repository**: [blacksmith-genesis-kit](https://github.com/genesis-community/blacksmith-genesis-kit)

Deploy on-demand service brokers.

**Key Features**:
- `redis-forge` - Redis services
- `postgres-forge` - PostgreSQL services
- `rabbitmq-forge` - RabbitMQ services
- `cf-integration` - Cloud Foundry broker

## Backup & Recovery Kits

### Shield Kit

**Repository**: [shield-genesis-kit](https://github.com/genesis-community/shield-genesis-kit)

Deploy Shield backup/restore solutions.

**Key Features**:
- `postgres`, `mysql` - Database backends
- `minio` - Object storage
- `monitoring` - Backup metrics
- `oauth` - External authentication

**Common Usage**:
```yaml
kit:
  name: shield
  features:
    - postgres
    - monitoring
    - oauth
```

### Minio Kit

**Repository**: [minio-genesis-kit](https://github.com/genesis-community/minio-genesis-kit)

Deploy Minio S3-compatible object storage.

**Key Features**:
- `distributed` - Multi-node setup
- `tls` - Encrypted connections
- `monitoring` - Storage metrics

## Utility Kits

### Jumpbox Kit

**Repository**: [jumpbox-genesis-kit](https://github.com/genesis-community/jumpbox-genesis-kit)

Deploy secure bastion hosts.

**Key Features**:
- `openvpn` - VPN server
- `shield` - Backup agent
- `all-tools` - Extra utilities
- `golang`, `ruby` - Development tools

**Common Usage**:
```yaml
kit:
  name: jumpbox
  features:
    - openvpn
    - all-tools
```

### Docker Registry Kit

**Repository**: [docker-registry-genesis-kit](https://github.com/genesis-community/docker-registry-genesis-kit)

Deploy private Docker registries.

**Key Features**:
- `s3-storage`, `swift-storage` - Backend storage
- `auth` - Authentication
- `proxy` - Pull-through cache
- `monitoring` - Registry metrics

## Using Official Kits

### Installation

All official kits are automatically available:

```bash
# List all kits
genesis kits

# Initialize with kit
genesis init --kit <kit-name> <repo-name>
```

### Version Selection

Check available versions:

```bash
# Show kit versions
genesis info <kit-name> --versions

# Use specific version
kit:
  version: 2.3.0  # Recommended for production
```

### Getting Help

For each kit:

```bash
# View documentation
genesis info <kit-name>

# See available features
genesis info <kit-name> --features

# Check parameters
genesis info <kit-name> --params
```

## Community Kits

Beyond official kits, community members create kits for:
- Custom applications
- Proprietary software
- Specialized configurations

Find community kits:
- Search GitHub for `*-genesis-kit`
- Check Genesis community forums
- Ask in Genesis Slack

## Creating Your Own Kit

If you need a kit that doesn't exist:

1. **Check existing kits** - Maybe adapt one
2. **Use generic kit** - For simple cases
3. **Create new kit** - See [Authoring Kits](authoring-kits.md)

## Kit Selection Guide

### For New Users

Start with these well-documented kits:
1. **BOSH** - Essential infrastructure
2. **Vault** - Secrets management
3. **Concourse** - CI/CD pipelines
4. **Jumpbox** - Secure access

### For Cloud Foundry

Complete CF deployment stack:
1. **BOSH** - Infrastructure layer
2. **Vault** - Secrets backend
3. **Postgres** - CF database
4. **CF** - Cloud Foundry itself
5. **Shield** - Backup solution

### For Kubernetes

Kubernetes on BOSH:
1. **BOSH** - Infrastructure
2. **Vault** - Secrets
3. **K8s** - Kubernetes cluster
4. **Prometheus** - Monitoring

## Support

For kit issues:
- Check kit repository issues
- Ask in Genesis Slack
- Consult kit documentation
- Review kit release notes

Official kits are actively maintained and tested across common deployment scenarios.