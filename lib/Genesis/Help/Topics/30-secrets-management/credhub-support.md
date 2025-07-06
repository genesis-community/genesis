# CredHub Support

Genesis supports VMware CredHub as an alternative to HashiCorp Vault for secrets management. CredHub is particularly popular in Cloud Foundry environments due to its tight BOSH integration.

## Overview

CredHub provides:
- **Native BOSH integration** - Direct support in BOSH Director
- **Typed credentials** - Structured secret types
- **Automatic generation** - BOSH can generate missing credentials
- **ACL support** - Fine-grained access control
- **Certificate rotation** - Built-in certificate management

## Enabling CredHub

### BOSH Director Configuration

Deploy BOSH with CredHub enabled:

```yaml
# In BOSH environment file
kit:
  features:
    - aws
    - credhub

params:
  credhub_enabled: true
```

### Environment Configuration

Configure Genesis to use CredHub:

```yaml
# In deployment environment file
genesis:
  secrets_provider: credhub
  credhub_env: my-bosh-director
```

## CredHub vs Vault

### Feature Comparison

| Feature | Vault | CredHub |
|---------|-------|---------|
| Secret Types | Generic KV | Typed (password, cert, etc.) |
| BOSH Integration | Via Genesis | Native |
| Access Control | Policies | ACLs |
| UI | Yes | Limited |
| Multi-DC | Yes | Per-BOSH |
| Audit Logs | Comprehensive | Basic |

### When to Use CredHub

Choose CredHub when:
- Deploying primarily Cloud Foundry
- Using BOSH heavily
- Want native BOSH integration
- Prefer typed credentials

Choose Vault when:
- Need enterprise features
- Multiple secret backends
- Complex access policies
- Non-BOSH workloads

## Secret Management

### Viewing Secrets

```bash
# Target CredHub
credhub api https://credhub.example.com:8844

# Login
credhub login --client-name genesis --client-secret <secret>

# List secrets
credhub find -n '/genesis/us-east-1-prod'

# Get specific secret
credhub get -n '/genesis/us-east-1-prod/cf/admin_password'
```

### Manual Secret Operations

```bash
# Set a password
credhub set -n '/genesis/us-east-1-prod/cf/api_key' \
  -t password \
  -w 'super-secret-key'

# Generate a password
credhub generate -n '/genesis/us-east-1-prod/cf/new_password' \
  -t password \
  -l 32

# Create certificate
credhub generate -n '/genesis/us-east-1-prod/cf/web_cert' \
  -t certificate \
  -c 'web.example.com' \
  -a 'web.example.com,*.apps.example.com' \
  --duration 365 \
  --ca '/genesis/us-east-1-prod/cf/ca'
```

## Path Structure

### Genesis Paths in CredHub

CredHub paths follow this pattern:
```
/<director-name>/<deployment-name>/<secret-name>

Example:
/my-bosh/us-east-1-prod-cf/admin_password
```

### Custom Path Configuration

```yaml
genesis:
  credhub_prefix: /genesis/custom
  env: us-east-1-prod
```

Results in paths like:
```
/genesis/custom/us-east-1-prod/admin_password
```

## Certificate Management

### Certificate Generation

CredHub excels at certificate management:

```bash
# Generate CA
credhub generate -n '/genesis/prod/ca' \
  -t certificate \
  --is-ca \
  --common-name 'Genesis CA'

# Generate server certificate
credhub generate -n '/genesis/prod/server-cert' \
  -t certificate \
  --ca '/genesis/prod/ca' \
  --common-name 'server.example.com' \
  --alternative-names 'server.example.com,*.example.com'
```

### Certificate Rotation

```bash
# Regenerate certificate
credhub regenerate -n '/genesis/prod/server-cert'

# Bulk regenerate
credhub bulk-regenerate --signed-by '/genesis/prod/ca'
```

## Access Control

### CredHub ACLs

Define who can access secrets:

```bash
# Grant read access
credhub set-permission \
  -n '/genesis/prod/*' \
  -a 'uaa-client:app1' \
  -p read

# Grant write access
credhub set-permission \
  -n '/genesis/dev/*' \
  -a 'uaa-user:developer' \
  -p read,write
```

### UAA Integration

CredHub uses UAA for authentication:

```yaml
# In CF deployment
params:
  credhub_uaa_clients:
    - name: genesis
      secret: ((credhub_genesis_client_secret))
      scopes:
        - credhub.read
        - credhub.write
```

## Integration with Genesis

### Automatic Secret Generation

Genesis kits work seamlessly with CredHub:

```yaml
# Kit defines requirements
credentials:
  base:
    admin_password: random 32

# CredHub generates automatically during deploy
```

### Manual Provided Secrets

For user-provided secrets:

```bash
# Set before deployment
credhub set -n '/my-bosh/prod-cf/external_api_key' \
  -t value \
  -v 'provided-by-user'
```

### Interpolation

CredHub interpolates at runtime:

```yaml
# In manifest
properties:
  admin_password: ((admin_password))
  
# CredHub provides value during deployment
```

## Migration

### From Vault to CredHub

```bash
#!/bin/bash
# Migrate secrets from Vault to CredHub

VAULT_PATH="secret/us-east-1/prod/cf"
CREDHUB_PATH="/genesis/us-east-1-prod/cf"

# Export from Vault
safe export $VAULT_PATH > secrets.json

# Import to CredHub
for secret in $(jq -r 'keys[]' secrets.json); do
  value=$(jq -r ".$secret" secrets.json)
  
  # Detect type and import
  if [[ $secret == *"password"* ]]; then
    credhub set -n "$CREDHUB_PATH/$secret" -t password -w "$value"
  elif [[ $secret == *"cert"* ]]; then
    credhub set -n "$CREDHUB_PATH/$secret" -t certificate -c "$value"
  else
    credhub set -n "$CREDHUB_PATH/$secret" -t value -v "$value"
  fi
done
```

### From CredHub to Vault

```bash
#!/bin/bash
# Migrate from CredHub to Vault

# Export from CredHub
credhub find -n '/genesis/prod' -j | \
  jq -r '.credentials[].name' | \
  while read -r name; do
    credhub get -n "$name" -j > "/tmp/$(basename $name).json"
  done

# Import to Vault
# ... conversion logic ...
```

## Operations

### Backup and Restore

```bash
# Backup CredHub database
bosh -d credhub-deployment \
  run-errand bbr-backup

# Restore
bosh -d credhub-deployment \
  run-errand bbr-restore \
  --backup-artifact /path/to/backup
```

### Monitoring

Monitor CredHub health:

```yaml
# Prometheus metrics
- job_name: credhub
  static_configs:
    - targets: ['credhub.example.com:9000']
  metrics_path: /metrics
```

Key metrics:
- `credhub_credential_count`
- `credhub_operation_duration`
- `credhub_api_requests_total`

### Performance Tuning

```yaml
# In CredHub deployment
params:
  credhub_encryption_keys: 2  # Multiple keys
  credhub_db_connections: 20  # Connection pool
  credhub_threads: 100        # Request threads
```

## Best Practices

### 1. Use Typed Credentials

```bash
# Good - typed password
credhub generate -n /path -t password

# Less ideal - generic value
credhub set -n /path -t value -v "password"
```

### 2. Leverage Certificate Features

```bash
# Use CA signing
credhub generate -n /ca -t certificate --is-ca
credhub generate -n /server -t certificate --ca /ca

# Set expiry alerts
credhub set-permission -n /certs/* \
  -a 'monitoring-system' -p read
```

### 3. Implement ACLs

```bash
# Principle of least privilege
credhub set-permission \
  -n '/prod/*' \
  -a 'prod-team' \
  -p read,write

credhub set-permission \
  -n '/prod/*' \
  -a 'dev-team' \
  -p read
```

### 4. Regular Rotation

```bash
# Rotate passwords
credhub regenerate -n /path/to/password

# Bulk rotate certificates
credhub bulk-regenerate --signed-by /my-ca
```

### 5. Monitor Certificate Expiry

```bash
# Check certificate expiration
credhub get -n /path/to/cert -j | \
  jq -r '.value.certificate' | \
  openssl x509 -noout -enddate
```

## Troubleshooting

### Connection Issues

```bash
# Check CredHub API
curl -k https://credhub.example.com:8844/info

# Verify UAA connectivity  
curl -k https://uaa.example.com:8443/info

# Check client permissions
credhub login --client-name my-client
```

### Permission Denied

```bash
# List permissions
credhub get-permission -n /path

# Check UAA token
credhub --version  # Shows current auth

# Re-authenticate
credhub logout
credhub login
```

### Secret Not Found

```bash
# Search for secret
credhub find -n prod

# Check exact path
credhub get -n /full/path/to/secret

# Verify BOSH interpolation
bosh interpolate manifest.yml \
  --vars-store=credhub
```

## CredHub CLI Reference

Common commands:

```bash
# Authentication
credhub login
credhub logout

# Secret operations
credhub get -n <path>
credhub set -n <path> -t <type> -v <value>
credhub delete -n <path>
credhub generate -n <path> -t <type>
credhub regenerate -n <path>

# Bulk operations
credhub find -n <path-prefix>
credhub bulk-regenerate --signed-by <ca-path>

# Permissions
credhub set-permission -n <path> -a <actor> -p <operations>
credhub get-permission -n <path>
credhub delete-permission -n <path> -a <actor>
```

CredHub provides a robust, BOSH-native alternative to Vault for organizations heavily invested in the Cloud Foundry ecosystem.