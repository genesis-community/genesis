# Secret Problems

This guide helps diagnose and resolve issues with Vault integration and secret management in Genesis.

## Common Secret Issues

### Cannot Connect to Vault

**Symptoms:**
```
Error: Could not connect to Vault at https://127.0.0.1:8200
Error: x509: certificate signed by unknown authority
Error: 403 permission denied
```

**Diagnostics:**

```bash
# Check Vault target
safe target

# Test connectivity
safe status

# Verify authentication
safe auth status

# Check network
curl -k https://your-vault:8200/v1/sys/health
```

**Solutions:**

1. **Set correct target:**
   ```bash
   safe target my-vault https://vault.example.com:8200
   ```

2. **Skip TLS verification (dev only):**
   ```bash
   safe target my-vault https://vault.example.com:8200 --skip-verify
   # Or
   export VAULT_SKIP_VERIFY=1
   ```

3. **Add CA certificate:**
   ```bash
   export VAULT_CACERT=/path/to/ca.crt
   safe target my-vault https://vault.example.com:8200
   ```

### Authentication Failures

**Symptoms:**
```
Error: Vault token has expired
Error: permission denied
Error: 403 Forbidden
```

**Diagnostics:**

```bash
# Check current token
safe vault token lookup

# Verify token capabilities
safe vault token capabilities secret/path

# Test authentication
safe auth status
```

**Solutions:**

1. **Re-authenticate:**
   ```bash
   safe auth
   # Or with specific method
   safe auth ldap
   safe auth github
   safe auth token
   ```

2. **Token renewal:**
   ```bash
   safe vault token renew
   ```

3. **Check policies:**
   ```bash
   # List policies
   safe vault policy list
   
   # Read policy
   safe vault policy read my-policy
   ```

### Missing Secrets

**Symptoms:**
```
Error: secret/path/to/secret:key not found
Error: Could not retrieve secret from Vault
```

**Diagnostics:**

```bash
# Check if secret exists
safe exists secret/path/to/secret

# List secrets in path
safe tree secret/path/to

# Check exact path
safe get secret/path/to/secret

# Verify secrets for environment
genesis secrets-plan my-env
```

**Solutions:**

1. **Generate missing secrets:**
   ```bash
   genesis add-secrets my-env
   ```

2. **Create manually:**
   ```bash
   # Password
   safe gen secret/path password
   
   # SSH key
   safe ssh secret/path/ssh
   
   # Certificate
   safe x509 issue secret/path/cert \
     --name example.com \
     --ttl 365d
   ```

3. **Check path correctness:**
   ```bash
   # Get actual secrets path
   genesis secrets-path my-env
   
   # Should match references in manifest
   genesis manifest my-env --no-resolve | grep vault
   ```

## Secret Path Issues

### Incorrect Paths

**Diagnostics:**

```bash
# Show expected secrets path
genesis secrets-path my-env

# Compare with actual usage
genesis manifest my-env --no-resolve | \
  grep -o '(( *vault *"[^"]*"' | \
  sed 's/.*"\([^"]*\)".*/\1/' | \
  sort -u

# Check path hierarchy
safe tree $(genesis secrets-path my-env)
```

**Common path problems:**

```yaml
# Wrong: Hardcoded path
admin_password: (( vault "secret/prod/admin:password" ))

# Right: Use relative path
admin_password: (( vault meta.vault "/admin:password" ))

# Or with Genesis 2.8+
admin_password: (( vault $GENESIS_SECRETS_PATH "/admin:password" ))
```

### Path Migration

When moving environments:

```bash
#!/bin/bash
# migrate-secrets.sh

OLD_PATH="secret/old/path"
NEW_PATH="secret/new/path"

# Export secrets
safe export $OLD_PATH > secrets-backup.json

# Import to new location
safe import < secrets-backup.json
safe move $OLD_PATH $NEW_PATH

# Update environment
sed -i "s|$OLD_PATH|$NEW_PATH|g" my-env.yml
```

## Secret Generation Issues

### Failed Auto-Generation

**Symptoms:**
```
Error: Failed to generate secret: x509 certificate generation failed
Error: Could not generate SSH key
```

**Diagnostics:**

```bash
# Check kit secret definitions
grep -A20 "credentials:" kit.yml

# Test generation manually
safe x509 issue test-cert --ttl 90d
safe ssh test-ssh
safe gen test-password
```

**Solutions:**

1. **Generate manually:**
   ```bash
   # For certificates
   safe x509 issue secret/path/cert \
     --ca secret/path/ca \
     --ttl 365d \
     --subject "/C=US/O=Company/CN=example.com" \
     --san "*.example.com" \
     --san "10.0.0.5"
   ```

2. **Custom generation:**
   ```bash
   # Complex password
   safe set secret/path password=value < <(pwgen -s 32 1)
   
   # Multiple values
   safe set secret/path \
     username=admin \
     password=secret \
     api_key=abcd1234
   ```

### Certificate Problems

**Common certificate issues:**

```bash
# Expired certificate
safe x509 show secret/path/cert | grep "Not After"

# Wrong CA
safe x509 verify secret/path/cert --ca secret/path/ca

# Missing SANs
safe x509 show secret/path/cert | grep -A5 "Subject Alternative Name"
```

**Certificate renewal:**

```bash
# Renew existing certificate
safe x509 renew secret/path/cert --ttl 365d

# Reissue with new parameters
safe x509 reissue secret/path/cert \
  --san "new.example.com" \
  --ttl 365d
```

## Secret Rotation

### Manual Rotation

```bash
#!/bin/bash
# rotate-secrets.sh

ENV=$1
SECRET_PATH=$(genesis secrets-path $ENV)

# Rotate passwords
for path in admin db api; do
  echo "Rotating $path password..."
  safe gen "$SECRET_PATH/$path" password
done

# Rotate SSH keys
safe ssh "$SECRET_PATH/ssh" --no-clobber

# Rotate certificates (keep same CA)
safe x509 renew "$SECRET_PATH/cert" --ttl 365d
```

### Automated Rotation

Using Genesis rotation features:

```bash
# Rotate all secrets
genesis rotate-secrets my-env

# Rotate specific secrets
genesis rotate-secrets my-env --only passwords
genesis rotate-secrets my-env --only certificates

# Dry run
genesis rotate-secrets my-env --dry-run
```

## CredHub Integration

### Switching from Vault to CredHub

```yaml
# Environment configuration
genesis:
  secrets_provider: credhub
  credhub_env: my-bosh-director

# Update references
properties:
  password: (( credhub "admin-password" ))
```

### CredHub Debugging

```bash
# Check CredHub connection
credhub api

# List secrets
credhub find -n "/"

# Get specific secret
credhub get -n "/bosh/deployment/secret"
```

## Recovery Procedures

### Vault Sealed

```bash
# Check seal status
safe vault status

# Unseal with keys
safe vault operator unseal
# Enter unseal key when prompted

# Or with multiple keys
for i in 1 2 3; do
  echo "Unseal key $i:"
  safe vault operator unseal
done
```

### Lost Secrets

**Recovery from backups:**

```bash
# From Vault backup
safe import < vault-backup-20231201.json

# From Genesis deployment
bosh -d my-deployment manifest > manifest.yml
# Extract secrets from manifest
```

**Regenerate from deployment:**

```bash
#!/bin/bash
# extract-deployed-secrets.sh

DEPLOYMENT=$1
OUTPUT_PATH=$2

# Get manifest from BOSH
bosh -d $DEPLOYMENT manifest > deployed-manifest.yml

# Extract credentials
spruce json deployed-manifest.yml | \
  jq -r '.properties | to_entries[] | 
    select(.value | type == "string") | 
    "\(.key)=\(.value)"' > extracted-secrets.txt

# Store in Vault
while IFS='=' read -r key value; do
  safe set "$OUTPUT_PATH/$key" value="$value"
done < extracted-secrets.txt
```

## Best Practices

### 1. Regular Backups

```bash
#!/bin/bash
# backup-secrets.sh

BACKUP_DIR="/secure/backups"
DATE=$(date +%Y%m%d-%H%M%S)

# Export all secrets
safe export secret > "$BACKUP_DIR/vault-$DATE.json"

# Encrypt backup
gpg --encrypt --recipient backup@example.com \
  "$BACKUP_DIR/vault-$DATE.json"

# Remove unencrypted
rm "$BACKUP_DIR/vault-$DATE.json"
```

### 2. Access Policies

```hcl
# genesis-policy.hcl
path "secret/data/genesis/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/metadata/genesis/*" {
  capabilities = ["list", "read"]
}
```

Apply policy:
```bash
safe vault policy write genesis genesis-policy.hcl
```

### 3. Secret Hygiene

```bash
# Check for weak passwords
for secret in $(safe find secret --type password); do
  length=$(safe get $secret | wc -c)
  if [ $length -lt 20 ]; then
    echo "Weak password: $secret (length: $length)"
  fi
done

# Find expired certificates
for cert in $(safe find secret --type x509); do
  if ! safe x509 validate $cert --ttl 30d; then
    echo "Certificate expiring soon: $cert"
  fi
done
```

## Troubleshooting Checklist

### Connection Issues
- [ ] Vault target configured correctly
- [ ] Network connectivity to Vault
- [ ] TLS certificates valid
- [ ] Authentication current

### Secret Issues  
- [ ] Secrets exist at expected paths
- [ ] Correct secret path in environment
- [ ] Proper permissions on paths
- [ ] Secrets have required keys

### Generation Issues
- [ ] Kit defines secret correctly
- [ ] CA certificates available
- [ ] Sufficient entropy for generation
- [ ] No naming conflicts

### Rotation Issues
- [ ] Backup before rotation
- [ ] All instances updated
- [ ] Services restarted
- [ ] Old secrets archived

Effective secret management requires understanding both Vault operations and Genesis integration patterns. Always backup before making changes.