# Vault Integration

Genesis uses HashiCorp Vault as its primary secret storage backend. This guide covers setup, configuration, and operational procedures for Vault with Genesis.

## Vault Setup

### Quick Start (Development)

For testing, use the Genesis built-in Vault:

```bash
# Start a dev Vault instance
safe init

# Target and authenticate
safe target dev http://127.0.0.1:8201
safe auth

# Verify connection
safe status
```

### Production Deployment

Deploy a production Vault cluster using Genesis:

```bash
# Initialize Vault deployment repository
genesis init --kit vault my-vault-deployments
cd my-vault-deployments

# Create production environment
genesis new prod-vault

# Deploy
genesis deploy prod-vault
```

## Connecting Genesis to Vault

### Environment Variables

Genesis uses these variables to connect to Vault:

```bash
# Vault server address
export VAULT_ADDR=https://vault.example.com:8200

# Skip TLS verification (dev only!)
export VAULT_SKIP_VERIFY=1

# Authentication token (not recommended)
export VAULT_TOKEN=s.abcdef123456

# Namespace (Vault Enterprise)
export VAULT_NAMESPACE=genesis
```

### Safe CLI Configuration

The `safe` CLI manages Vault targets:

```bash
# Add a Vault target
safe target add prod https://vault.example.com:8200

# List targets
safe targets

# Switch targets
safe target prod

# Authenticate
safe auth
```

### Authentication Methods

#### Token Authentication

```bash
# Interactive login
safe auth

# Using existing token
safe auth token
```

#### GitHub Authentication

```bash
# Configure GitHub auth in Vault
safe auth-configure github \
  --organization=myorg \
  --team=ops-team

# Login with GitHub
safe auth github
```

#### LDAP Authentication

```bash
# Configure LDAP
safe auth-configure ldap \
  --url=ldap://ldap.example.com \
  --binddn="cn=vault,ou=service,dc=example,dc=com" \
  --userdn="ou=users,dc=example,dc=com"

# Login with LDAP
safe auth ldap
```

## Secret Paths

### Standard Genesis Paths

Genesis organizes secrets hierarchically:

```
/secret/<environment-path>/<kit-type>/
├── admin_password
├── ca_cert
├── db/
│   ├── username
│   └── password
└── ssl/
    ├── cert
    ├── key
    └── ca
```

### Exodus Data

Shared deployment information:

```
/secret/exodus/<environment>/<kit-type>/
├── url
├── username
├── password
└── ca_cert
```

### Custom Paths

Override default paths in environment files:

```yaml
genesis:
  secrets_mount: secret/custom
  secrets_slug: prod/cf
  exodus_mount: secret/shared
  exodus_slug: cf-prod
```

## Vault Policies

### Basic Policy Structure

```hcl
# Read-only access to production
path "secret/prod/*" {
  capabilities = ["read", "list"]
}

# Full access to development
path "secret/dev/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Deny access to specific paths
path "secret/prod/*/admin_password" {
  capabilities = ["deny"]
}
```

### Genesis-Specific Policies

#### Operator Policy

```hcl
# Full access to all Genesis secrets
path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Access to Vault tools
path "sys/tools/*" {
  capabilities = ["read"]
}

# Mount management
path "sys/mounts/*" {
  capabilities = ["read", "list"]
}
```

#### Developer Policy

```hcl
# Read dev/staging, no prod access
path "secret/dev/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/staging/*" {
  capabilities = ["read", "list"]
}

path "secret/prod/*" {
  capabilities = ["deny"]
}
```

#### CI/CD Policy

```hcl
# Read-only for deployments
path "secret/+/+/+/*" {
  capabilities = ["read"]
}

# Write exodus data
path "secret/exodus/*" {
  capabilities = ["create", "read", "update"]
}
```

### Applying Policies

```bash
# Create policy
safe policy write operator-policy policy.hcl

# Assign to user
safe auth token create \
  --policy=operator-policy \
  --display-name="John Doe"

# Assign to GitHub team
safe write auth/github/map/teams/ops-team \
  value=operator-policy
```

## Secret Operations

### Viewing Secrets

```bash
# List secrets for environment
safe tree secret/us-east-1/prod/cf

# View specific secret
safe get secret/us-east-1/prod/cf/admin_password

# Export all secrets
safe export secret/us-east-1/prod/cf > cf-secrets.json
```

### Manual Secret Management

```bash
# Set a secret
safe set secret/us-east-1/prod/cf/api_key value=abc123

# Generate password
safe gen secret/us-east-1/prod/cf/new_password

# Create SSH key
safe ssh secret/us-east-1/prod/cf/bastion_ssh

# Issue certificate
safe x509 issue secret/us-east-1/prod/cf/web_cert \
  --ca secret/us-east-1/prod/cf/ca \
  --name web.example.com \
  --ttl 365d
```

### Copying Secrets

```bash
# Copy between environments
safe cp \
  secret/us-east-1/dev/cf \
  secret/us-east-1/staging/cf

# Copy specific secret
safe cp \
  secret/us-east-1/prod/cf/ca \
  secret/us-west-2/prod/cf/ca
```

## High Availability

### Multi-Node Vault

Deploy Vault in HA mode:

```yaml
# In Vault environment file
params:
  vault_num_instances: 3
  
  consul_servers:
    - 10.0.1.10
    - 10.0.1.11
    - 10.0.1.12
```

### Backup and Recovery

```bash
# Backup Vault data
genesis do vault-prod -- backup

# Create snapshot (Vault Enterprise)
vault operator raft snapshot save backup.snap

# Restore from backup
genesis do vault-prod -- restore backup.tar.gz
```

## Monitoring and Maintenance

### Health Checks

```bash
# Check Vault status
safe status

# Detailed status
vault status -format=json

# Check seal status
safe sealed?
```

### Audit Logging

Enable audit logging:

```bash
# File audit backend
vault audit enable file \
  file_path=/var/log/vault/audit.log

# Syslog audit backend  
vault audit enable syslog \
  tag="vault" \
  facility="LOCAL7"
```

### Performance Tuning

```bash
# Enable metrics
vault write sys/config/telemetry \
  prometheus_retention_time="30s" \
  disable_hostname=true

# Monitor key metrics
- vault.core.handle_request
- vault.token.lookup
- vault.barrier.get
- vault.barrier.put
```

## Troubleshooting

### Connection Issues

```bash
# Test connectivity
safe target check

# Verify environment
env | grep VAULT

# Check TLS
openssl s_client -connect vault.example.com:8200
```

### Authentication Problems

```bash
# Check token validity
safe token

# Renew token
safe renew

# Re-authenticate
safe auth
```

### Permission Denied

```bash
# Check policies
safe vault policy read my-policy

# List token policies
vault token lookup

# Test specific path
safe exists secret/path/to/test
```

## Best Practices

### 1. Use Policies

Always use policies instead of root tokens:
- Create specific policies for each role
- Follow principle of least privilege
- Regularly audit policy assignments

### 2. Enable Auditing

```bash
vault audit enable file \
  file_path=/vault/logs/audit.log \
  log_raw=true
```

### 3. Regular Backups

```bash
# Automated backup script
#!/bin/bash
genesis do vault-prod -- backup
aws s3 cp vault-backup.tar.gz s3://backups/vault/
```

### 4. Monitor Unseal Keys

- Distribute unseal keys securely
- Never store together
- Regular key rotation
- Use auto-unseal when possible

### 5. TLS Everywhere

- Valid certificates on Vault
- Verify certificates in production
- Use mTLS for added security

## Integration Examples

### CI/CD Pipeline

```yaml
# Concourse pipeline
resources:
- name: secrets
  type: vault
  source:
    url: ((vault_addr))
    path: secret/us-east-1/prod
    client_token: ((vault_token))
```

### Application Integration

```python
# Python example
import hvac

client = hvac.Client(
    url='https://vault.example.com:8200',
    token=os.environ['VAULT_TOKEN']
)

secret = client.read('secret/data/app/database')
db_password = secret['data']['data']['password']
```

### Kubernetes Integration

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-creds
  annotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/agent-inject-secret-db: "secret/app/db"
    vault.hashicorp.com/role: "app"
```

Proper Vault integration ensures your Genesis deployments remain secure while maintaining operational efficiency.