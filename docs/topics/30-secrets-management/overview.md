# Secrets Management Overview

Genesis integrates deeply with secret management systems to handle credentials, certificates, and other sensitive data required by your deployments. This overview explains the concepts and architecture.

## Why Secrets Management?

Modern infrastructure requires numerous credentials:
- Database passwords
- API keys
- SSH keys for access
- TLS certificates
- Service account credentials
- Encryption keys

Managing these manually is:
- **Error-prone** - Easy to expose or lose secrets
- **Time-consuming** - Generating and distributing takes effort
- **Risky** - Rotation requires coordination
- **Difficult to audit** - Who has access to what?

## How Genesis Handles Secrets

Genesis automates secret management through:

### 1. Automatic Generation

When you deploy an environment, Genesis:
- Detects required secrets from the kit
- Checks if they already exist in Vault
- Generates missing secrets automatically
- Stores them securely

### 2. Consistent Paths

Secrets follow predictable paths:
```
/secret/<environment>/<kit-type>/<secret-name>

Example:
/secret/us/east/1/prod/cf/admin_password
```

### 3. Manifest Integration

Genesis injects secrets during manifest generation:
```yaml
# In manifest template
admin_password: ((vault "secret/path:password"))

# Genesis replaces with actual value during deployment
admin_password: "GeneratedSecurePassword123!"
```

### 4. Rotation Support

Built-in commands for credential rotation:
```bash
genesis rotate-secrets my-env admin_password
```

## Supported Secret Stores

### HashiCorp Vault (Primary)

The preferred secret backend:
- **Encrypted storage** - All secrets encrypted at rest
- **Access control** - Fine-grained policies
- **Audit logging** - Track all access
- **High availability** - Clustered deployment
- **Secret engines** - Multiple backend types

### VMware CredHub

Alternative for Cloud Foundry environments:
- **BOSH integration** - Native BOSH support
- **Credential types** - Structured secret types
- **ACLs** - Access control lists
- **Interpolation** - Runtime secret injection

## Secret Lifecycle

### Generation Phase

1. **Kit Definition** - Kit specifies required secrets
2. **Deployment Check** - Genesis checks what's missing
3. **Automatic Generation** - Creates missing secrets
4. **Secure Storage** - Saves to Vault/CredHub

### Usage Phase

1. **Manifest Generation** - Genesis retrieves secrets
2. **Injection** - Replaces placeholders
3. **Deployment** - BOSH uses secrets
4. **Runtime** - Applications access as needed

### Rotation Phase

1. **Identify** - Determine what needs rotation
2. **Generate** - Create new credentials
3. **Update** - Store in secret backend
4. **Deploy** - Apply to infrastructure
5. **Verify** - Ensure services still work

## Secret Types

### Passwords
```yaml
credentials:
  base:
    db/password: random 32
```
- Random generation
- Configurable length
- Character set control

### SSH Keys
```yaml
credentials:
  base:
    jumpbox/ssh: ssh 2048
```
- RSA key pairs
- Configurable key size
- Public/private keys

### X.509 Certificates
```yaml
certificates:
  base:
    ca:
      valid_for: 10y
    server:
      valid_for: 1y
      names: ["*.example.com"]
```
- Certificate authorities
- Server/client certificates
- Automatic renewal warnings

### RSA Keys
```yaml
credentials:
  base:
    jwt/signing: rsa 4096
```
- JWT signing
- Encryption keys
- Configurable key size

## Security Architecture

### Vault Policies

Control access by path:
```hcl
# Dev team policy
path "secret/dev/*" {
  capabilities = ["create", "read", "update", "delete"]
}

# Prod read-only
path "secret/prod/*" {
  capabilities = ["read"]
}
```

### Network Security

- **TLS everywhere** - Encrypted communications
- **mTLS** - Mutual TLS for authentication
- **Network isolation** - Vault in secure subnet
- **Firewall rules** - Restrict access

### Operational Security

- **Regular rotation** - Scheduled credential updates
- **Audit logs** - Track all secret access
- **Backup procedures** - Encrypted secret backups
- **Break-glass access** - Emergency procedures

## Common Patterns

### Shared Secrets

Some secrets shared across environments:
```yaml
# Shared CA certificate
/secret/shared/ca-cert

# Environment-specific servers
/secret/dev/cf/server-cert    # Signed by shared CA
/secret/prod/cf/server-cert   # Signed by shared CA
```

### External Secrets

Integrating existing secrets:
```yaml
provided:
  base:
    external/api:
      keys:
        - api_key
        - api_secret
```

### Multi-Tenant Isolation

Separate secrets by tenant:
```
/secret/tenant-a/prod/cf/
/secret/tenant-b/prod/cf/
```

## Benefits

### For Operators

- **No manual generation** - Automated secret creation
- **Consistent storage** - Predictable locations
- **Easy rotation** - Simple commands
- **Audit trail** - Who accessed what

### For Security Teams

- **Encrypted storage** - Secrets never in plaintext
- **Access control** - Policy-based permissions
- **Compliance** - Audit logs for regulations
- **Rotation tracking** - Know secret ages

### For Developers

- **No hardcoded secrets** - Everything from Vault
- **Environment isolation** - Dev can't access prod
- **Self-service** - Generate dev secrets easily
- **Integration support** - SDKs for all languages

## Next Steps

- Learn about [Vault Integration](vault-integration.md)
- Understand [Secret Types](secret-types.md) in detail
- Master [Rotation Procedures](rotation-procedures.md)
- Review [Best Practices](best-practices.md)