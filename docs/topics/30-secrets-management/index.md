# Secrets Management

Genesis provides comprehensive secrets management through integration with HashiCorp Vault and VMware CredHub. This section covers everything from basic secret generation to advanced rotation procedures.

## Topics in This Section

1. **[Overview](overview.md)** - Introduction to Genesis secrets management
2. **[Vault Integration](vault-integration.md)** - Working with HashiCorp Vault
3. **[Secret Types](secret-types.md)** - Passwords, certificates, SSH keys, and more
4. **[Kit Secrets](kit-secrets.md)** - Defining secrets in kit.yml files
5. **[Rotation Procedures](rotation-procedures.md)** - Rotating credentials safely
6. **[CredHub Support](credhub-support.md)** - Using CredHub as an alternative
7. **[Manual Management](manual-management.md)** - Direct secret manipulation
8. **[Best Practices](best-practices.md)** - Security recommendations

## Quick Overview

Genesis automatically manages secrets for your deployments:

- **Automatic Generation** - Credentials created on first deployment
- **Secure Storage** - Stored in Vault or CredHub
- **Easy Rotation** - Built-in rotation commands
- **Type Safety** - Specific generators for each secret type

### Common Secret Types

- **Passwords** - Random strings with configurable complexity
- **SSH Keys** - Public/private key pairs
- **X.509 Certificates** - TLS certificates with CA chains
- **RSA Keys** - For JWT signing and encryption
- **UUIDs** - Unique identifiers

## Basic Usage

### View Secrets

```bash
# List all secrets for an environment
safe tree secret/us-east-1/prod/cf

# View specific secret
safe get secret/us-east-1/prod/cf/admin_password
```

### Rotate Secrets

```bash
# Rotate specific secret
genesis rotate-secrets us-east-1-prod admin_password

# Rotate all secrets (careful!)
genesis rotate-secrets us-east-1-prod --all
```

### Manual Generation

```bash
# Generate a password
safe gen secret/us-east-1/prod/cf/custom_password

# Create SSH key
safe ssh secret/us-east-1/prod/cf/jumpbox_ssh

# Generate certificate
safe x509 issue secret/us-east-1/prod/cf/web_cert \
  --name example.com \
  --ca secret/us-east-1/prod/cf/ca
```

## Integration with Kits

Kits define required secrets in their `kit.yml`:

```yaml
credentials:
  base:
    admin_user:
      username: admin
      password: random 32

certificates:
  base:
    ca:
      valid_for: 10y
    server:
      valid_for: 1y
      names: 
        - "*.system.${params.base_domain}"
        - "*.apps.${params.base_domain}"
```

## Security Considerations

1. **Never commit secrets** to version control
2. **Use strong passwords** - Minimum 16 characters
3. **Rotate regularly** - Especially after personnel changes
4. **Limit access** - Use Vault policies
5. **Audit usage** - Enable Vault audit logs

## Getting Started

- New to secrets? Start with the [Overview](overview.md)
- Setting up Vault? See [Vault Integration](vault-integration.md)
- Need to rotate? Check [Rotation Procedures](rotation-procedures.md)
- Using CredHub? Read [CredHub Support](credhub-support.md)