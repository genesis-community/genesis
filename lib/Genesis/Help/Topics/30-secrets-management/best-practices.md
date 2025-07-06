# Secrets Management Best Practices

This guide provides security best practices for managing secrets in Genesis deployments. Following these practices helps maintain a strong security posture.

## General Principles

### 1. Never Commit Secrets

**Never** store secrets in version control:

```yaml
# BAD - Hardcoded secret
params:
  admin_password: "SuperSecret123!"  # NEVER DO THIS

# GOOD - Reference from Vault
params:
  admin_password: ((vault "secret/path:password"))
```

Use `.gitignore`:
```gitignore
# Ignore all potential secret files
*-secrets.yml
*.key
*.pem
*.crt
credentials.json
.env
```

### 2. Use Strong Secrets

Configure appropriate secret strength:

```yaml
# Weak - Too short
credentials:
  base:
    password: random 8  # BAD

# Strong - Sufficient length and complexity
credentials:
  base:
    password: random 32  # GOOD
    api_key: "random 40 fmt base64"  # BETTER
```

### 3. Rotate Regularly

Establish rotation schedules:

| Secret Type | Rotation Frequency | Notes |
|------------|-------------------|-------|
| Passwords | 90 days | More frequent for privileged accounts |
| API Keys | 180 days | Depends on provider requirements |
| SSH Keys | 365 days | Rotate immediately if compromised |
| Server Certificates | 30 days before expiry | Automate monitoring |
| CA Certificates | 1 year before expiry | Plan carefully |

### 4. Principle of Least Privilege

Grant minimal necessary access:

```hcl
# Vault policy - Developer
path "secret/dev/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/staging/*" {
  capabilities = ["read", "list"]  # Read-only
}

path "secret/prod/*" {
  capabilities = ["deny"]  # No access
}
```

## Vault Security

### Secure Vault Deployment

```yaml
# Production Vault configuration
params:
  # Use auto-unseal
  vault_seal_type: awskms
  vault_awskms_key_id: ((aws_kms_key_id))
  
  # Enable audit logging
  vault_audit_enabled: true
  
  # Use TLS
  vault_tls_cert: ((vault_tls_cert))
  vault_tls_key: ((vault_tls_key))
  
  # High availability
  vault_instances: 3
```

### Audit Logging

Always enable audit logs:

```bash
# Enable file audit backend
vault audit enable file \
  file_path=/vault/logs/audit.log \
  log_raw=false

# Enable syslog for SIEM integration
vault audit enable syslog \
  tag="vault" \
  facility="LOCAL7"
```

### Backup Procedures

Regular encrypted backups:

```bash
#!/bin/bash
# backup-vault.sh

DATE=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="vault-backup-${DATE}.tar.gz"

# Create backup
genesis do vault-prod -- backup

# Encrypt backup
gpg --encrypt \
  --recipient backup@example.com \
  "$BACKUP_FILE"

# Upload to secure storage
aws s3 cp "${BACKUP_FILE}.gpg" \
  s3://secure-backups/vault/

# Clean up
rm -f "$BACKUP_FILE" "${BACKUP_FILE}.gpg"
```

## Access Control

### Multi-Factor Authentication

Enable MFA for Vault access:

```bash
# Enable TOTP MFA
vault write sys/mfa/method/totp/my_totp \
  issuer=Genesis \
  period=30 \
  algorithm=SHA256 \
  digits=6

# Require MFA for production paths
vault write sys/policy/mfa/production_mfa \
  enforcement_config='[{
    "mfa_method_ids": ["method_id"],
    "auth_method_types": ["token"]
  }]'
```

### Time-Based Access

Use temporary credentials:

```bash
# Create time-limited token
safe auth token create \
  --policy=deployment \
  --ttl=1h \
  --max-ttl=2h \
  --display-name="CI deployment"
```

### Service Account Management

```yaml
# Separate accounts for each service
credentials:
  base:
    # Don't reuse accounts
    cf/nats_password: random 32
    cf/router_password: random 32
    cf/controller_password: random 32
    
    # Not this
    # shared_service_password: random 32  # BAD
```

## Secret Hygiene

### Regular Audits

```bash
#!/bin/bash
# audit-secrets.sh - Run monthly

echo "=== Secret Age Report ==="

# Check password age
for env in dev staging prod; do
  echo "Environment: $env"
  
  # List secrets with metadata
  safe export "secret/$env" | \
    jq -r 'to_entries[] | 
      select(.key | contains("password")) |
      "\(.key): \(.value.updated_at // "unknown")"'
done

echo "=== Expiring Certificates ==="
# Find certificates expiring soon
safe find secret | grep cert$ | while read -r cert; do
  if safe x509 expires "$cert" --within 30d; then
    echo "WARNING: $cert expires soon"
  fi
done
```

### Cleanup Unused Secrets

```bash
# Find potentially unused secrets
genesis list --json | jq -r '.[].name' > active-envs.txt

safe find secret | while read -r secret; do
  # Extract environment from path
  env=$(echo "$secret" | cut -d/ -f2-3)
  
  if ! grep -q "$env" active-envs.txt; then
    echo "Potentially unused: $secret"
  fi
done
```

### Document Secret Usage

```yaml
# In environment files, document external usage
genesis:
  secrets_notes: |
    admin_password: Used by monitoring system (Datadog)
    api_key: Shared with partner integration
    db_password: Also configured in backup scripts
```

## Secure Development

### Development Environments

Use separate Vault instances:

```bash
# Development Vault (unsealed, insecure)
safe init dev --memory

# Never use dev mode for real secrets
safe set secret/dev/test password=test123
```

### Secret Scanning

Pre-commit hooks to catch secrets:

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/Yelp/detect-secrets
    rev: v1.4.0
    hooks:
      - id: detect-secrets
        args: ['--baseline', '.secrets.baseline']
```

### Environment Isolation

```bash
# Separate Vault paths by environment
/secret/dev/...      # Development
/secret/staging/...  # Staging  
/secret/prod/...     # Production

# Different access policies
/secret/sandbox/...  # Wide open for experiments
```

## Incident Response

### Compromised Secrets

If a secret is compromised:

1. **Rotate immediately**
   ```bash
   genesis rotate-secrets prod compromised_password
   genesis deploy prod
   ```

2. **Audit access**
   ```bash
   grep "compromised_password" /var/log/vault-audit.log
   ```

3. **Update dependencies**
   ```bash
   # Find all uses
   genesis manifest prod | grep compromised_password
   ```

4. **Document incident**
   ```yaml
   # In environment file
   genesis:
     security_incidents:
       - date: 2024-01-15
         secret: admin_password
         action: rotated
         reason: potential exposure in logs
   ```

### Emergency Access

Break-glass procedures:

```bash
# Sealed Vault emergency access
export VAULT_UNSEAL_KEY_1="..."
export VAULT_UNSEAL_KEY_2="..."
export VAULT_UNSEAL_KEY_3="..."

vault operator unseal $VAULT_UNSEAL_KEY_1
vault operator unseal $VAULT_UNSEAL_KEY_2
vault operator unseal $VAULT_UNSEAL_KEY_3

# Use root token only in emergency
vault login $VAULT_ROOT_TOKEN
```

## Monitoring and Alerting

### Certificate Expiration

```bash
#!/bin/bash
# monitor-certs.sh - Run daily via cron

ALERT_DAYS=30
SLACK_WEBHOOK="https://hooks.slack.com/..."

check_cert_expiry() {
  local cert_path=$1
  local days_left=$(safe x509 expires "$cert_path" --json | \
    jq -r '.days_until_expiration')
  
  if [ "$days_left" -lt "$ALERT_DAYS" ]; then
    curl -X POST "$SLACK_WEBHOOK" \
      -H "Content-Type: application/json" \
      -d "{\"text\": \"Certificate $cert_path expires in $days_left days\"}"
  fi
}

# Check all certificates
safe find secret | grep cert$ | while read -r cert; do
  check_cert_expiry "$cert"
done
```

### Failed Authentication

Monitor Vault audit logs:

```bash
# Count failed authentications
grep "error" /var/log/vault-audit.log | \
  grep "permission denied" | \
  jq -r '.auth.display_name' | \
  sort | uniq -c | sort -rn
```

## Compliance

### Regulatory Requirements

Common compliance needs:

```yaml
# PCI-DSS Compliance
credentials:
  base:
    # Requirement 8.2.4 - Change passwords every 90 days
    payment_api_key: "random 40 rotate_days=90"
    
    # Requirement 8.2.3 - Strong passwords
    admin_password: "random 32 complexity=high"

# HIPAA Compliance
certificates:
  base:
    # Encryption in transit
    api/tls:
      valid_for: 1y
      min_tls_version: "1.2"
```

### Audit Trail

Maintain compliance records:

```bash
# Generate compliance report
cat > compliance-report.sh <<'EOF'
#!/bin/bash

echo "=== Secret Rotation Compliance Report ==="
echo "Generated: $(date)"
echo

# Check rotation compliance
for secret in $(safe find secret/prod | grep password); do
  last_rotated=$(safe get "$secret:updated_at" 2>/dev/null || echo "unknown")
  echo "$secret: Last rotated $last_rotated"
done
EOF
```

## Security Checklist

Before deploying to production:

- [ ] All secrets in Vault (no hardcoded values)
- [ ] Appropriate secret strength (32+ chars for passwords)
- [ ] Rotation schedule defined
- [ ] Access policies configured
- [ ] Audit logging enabled
- [ ] Backup procedures tested
- [ ] Emergency access documented
- [ ] Monitoring alerts configured
- [ ] Compliance requirements met
- [ ] Team trained on procedures

Following these best practices ensures your Genesis deployments remain secure while maintaining operational efficiency.