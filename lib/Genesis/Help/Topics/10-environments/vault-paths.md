# Vault Path Structure

Genesis automatically organizes secrets in Vault using a predictable path structure based on environment names. Understanding these paths is essential for debugging, manual secret management, and integration with other tools.

## Default Path Structure

### Secrets Path

Genesis stores deployment secrets using a hierarchical path that mirrors your environment naming:

```
/secret/<environment-segments>/<kit-type>/

Example:
Environment: acme-aws-us-east-1-prod.yml
Kit: cf
Vault path: /secret/acme/aws/us/east/1/prod/cf/
```

The environment name is split on hyphens, with each segment becoming a directory level in Vault.

### Exodus Path

Exodus data (deployment outputs shared with other deployments) uses a different structure:

```
/secret/exodus/<environment-name>/<kit-type>

Example:
Environment: acme-aws-us-east-1-prod.yml
Kit: bosh
Vault path: /secret/exodus/acme-aws-us-east-1-prod/bosh
```

Exodus paths keep the environment name intact rather than splitting it.

## Path Components

### Mount Points

- **Secrets Mount**: `/secret` (default)
- **Exodus Mount**: `/secret/exodus` (default)

### Environment Segments

Environment name split on hyphens:
- `acme-aws-us-east-1-prod` → `acme/aws/us/east/1/prod`
- `company-vsphere-dc1-dev` → `company/vsphere/dc1/dev`

### Kit Type

The deployment type (kit name without `-genesis-kit`):
- `cf-genesis-kit` → `cf`
- `bosh-genesis-kit` → `bosh`
- `vault-genesis-kit` → `vault`

## Secret Organization

### Common Secret Patterns

Within each deployment's Vault path:

```
/secret/acme/aws/us/east/1/prod/cf/
├── admin_password           # User credentials
├── app_domain_cert         # X.509 certificates
│   ├── cert
│   ├── key
│   └── ca
├── bbs_encryption_key      # Encryption keys
├── db/                     # Database credentials
│   ├── password
│   └── username
└── jwt_signing_key         # JWT keys
    ├── private
    └── public
```

### Secret Types

Genesis automatically generates various secret types:

#### Passwords
```
/secret/.../admin_password
/secret/.../db/password
/secret/.../nats_password
```

#### SSH Keys
```
/secret/.../jumpbox_ssh
├── private
└── public
```

#### X.509 Certificates
```
/secret/.../router_ssl
├── cert
├── key
├── ca
└── combined  # Sometimes includes cert+key
```

#### RSA Keys
```
/secret/.../jwt_signing_key
├── private
└── public
```

## Exodus Data

### What Is Exodus?

Exodus data provides deployment information to other deployments:

```yaml
# BOSH director exodus
/secret/exodus/acme-aws-us-east-1-bosh/bosh
├── url              # https://10.0.0.6:25555
├── ca_cert          # BOSH director CA
├── admin_username   # admin
└── admin_password   # generated password
```

### Using Exodus Data

Other deployments reference exodus data:

```yaml
# In CF deployment
params:
  bosh: acme-aws-us-east-1-bosh  # References exodus data
```

Genesis automatically retrieves:
- BOSH URL
- CA certificate  
- Admin credentials

## Custom Paths

### Overriding Secrets Paths

In your environment file:

```yaml
genesis:
  # Change the mount point
  secrets_mount: secret/genesis  # Default: secret
  
  # Change the path structure
  secrets_slug: production/cf     # Default: split by hyphens
```

Results in: `/secret/genesis/production/cf/`

### Overriding Exodus Paths

```yaml
genesis:
  # Custom exodus mount
  exodus_mount: secret/shared    # Default: <secrets_mount>/exodus
  
  # Custom exodus slug
  exodus_slug: cf-production     # Default: full environment name
```

Results in: `/secret/shared/cf-production/cf`

### When to Customize

Consider custom paths when:
- Organization Vault policies restrict paths
- Migrating from another system
- Integrating with existing Vault structure
- Path segments exceed Vault limits

## Vault Operations

### Viewing Secrets

```bash
# List all secrets for an environment
safe tree secret/acme/aws/us/east/1/prod/cf

# View specific secret
safe get secret/acme/aws/us/east/1/prod/cf/admin_password

# Export all secrets
safe export secret/acme/aws/us/east/1/prod/cf
```

### Manual Secret Management

```bash
# Set a specific secret
safe set secret/acme/aws/us/east/1/prod/cf/custom_key value=mysecret

# Generate a new password
safe gen secret/acme/aws/us/east/1/prod/cf/new_password

# Create SSH key
safe ssh secret/acme/aws/us/east/1/prod/cf/ssh_key
```

### Copying Secrets

```bash
# Copy between environments
safe cp \
  secret/acme/aws/us/east/1/dev/cf \
  secret/acme/aws/us/east/1/staging/cf
```

## Path Discovery

### Finding Paths

```bash
# Show environment's Vault paths
genesis describe acme-aws-us-east-1-prod

# In deployment output
Secrets Path: secret/acme/aws/us/east/1/prod/cf
Exodus Path: secret/exodus/acme-aws-us-east-1-prod/cf
```

### Debugging Path Issues

Check for:
1. Correct environment name
2. Proper hyphen placement
3. Kit type identification
4. Mount point permissions

## Best Practices

### 1. Use Default Paths

Stick to defaults unless necessary:
- Predictable for team members
- Easier troubleshooting
- Better tool integration

### 2. Document Custom Paths

If using custom paths:
```yaml
# Document WHY in environment file
genesis:
  secrets_mount: restricted/project-x  # Required by security policy XYZ
```

### 3. Consistent Naming

Keep environment names consistent:
- Easier path prediction
- Simpler secret management
- Clearer organization

### 4. Access Control

Set Vault policies by path:
```hcl
# Dev team access to dev environments
path "secret/acme/*/dev/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Read-only prod access
path "secret/acme/*/prod/*" {
  capabilities = ["read", "list"]
}
```

### 5. Backup Considerations

When backing up:
```bash
# Backup entire environment
safe export secret/acme/aws/us/east/1/prod/cf > cf-prod-backup.json

# Include exodus data
safe export secret/exodus/acme-aws-us-east-1-prod/cf > cf-prod-exodus.json
```

## Common Issues

### Secrets Not Found

Check:
- Environment name spelling
- Hyphen placement
- Kit type detection
- Vault authentication

### Path Too Long

Vault has segment limits. Solutions:
1. Shorten environment names
2. Use `secrets_slug` override
3. Reduce hierarchy depth

### Permission Denied

Verify:
- Vault token permissions
- Policy allows path access
- Mount point exists

### Exodus Data Missing

Ensure:
- Source deployment succeeded
- Exodus path is correct
- No custom path overrides conflict

## Integration Examples

### CI/CD Integration

```yaml
# Concourse pipeline
- name: get-cf-secrets
  plan:
  - task: export-secrets
    config:
      run:
        path: safe
        args:
        - export
        - secret/acme/aws/us/east/1/prod/cf
```

### Terraform Integration

```hcl
# Read Genesis secrets in Terraform
data "vault_generic_secret" "cf_admin" {
  path = "secret/acme/aws/us/east/1/prod/cf/admin_password"
}
```

### Monitoring Integration

```bash
# Script to check certificate expiration
for cert in $(safe find secret | grep cert$); do
  expiry=$(safe get $cert | openssl x509 -noout -dates)
  echo "$cert: $expiry"
done
```

Understanding Vault paths helps you:
- Debug secret issues
- Integrate with other tools
- Implement access controls
- Manage secrets manually when needed