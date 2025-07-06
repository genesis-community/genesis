# Secret Rotation Procedures

Regular secret rotation is crucial for maintaining security. This guide covers how to safely rotate credentials in Genesis deployments.

## Overview

Secret rotation involves:
1. Generating new credentials
2. Updating Vault
3. Deploying with new secrets
4. Verifying services work
5. Cleaning up old credentials

## Using Genesis Rotate Command

### Basic Rotation

```bash
# Rotate specific secret
genesis rotate-secrets my-env admin_password

# Rotate multiple secrets
genesis rotate-secrets my-env admin_password nats_password

# Rotate all secrets (use with caution!)
genesis rotate-secrets my-env --all
```

### What Gets Rotated

The command rotates secrets marked as rotatable:
- Passwords (unless marked `fixed`)
- SSH keys (unless marked `fixed`)
- Certificates (regenerated with same parameters)
- Other generated credentials

Not rotated:
- Secrets marked with `fixed`
- User-provided secrets
- CA certificates (by default)

## Planning Rotation

### 1. Identify What to Rotate

```bash
# List all secrets
safe tree secret/us-east-1/prod/cf

# Check secret age
safe get secret/us-east-1/prod/cf/admin_password | \
  safe x509 show --json | jq .not_before

# Find old passwords
genesis info my-env --secrets
```

### 2. Assess Impact

Consider:
- **Service dependencies** - What uses this credential?
- **Downtime requirements** - Can services handle rotation?
- **External systems** - Any hardcoded references?
- **Backup systems** - Will backups still work?

### 3. Create Rotation Plan

```markdown
## Rotation Plan - Production CF

### Phase 1: Non-Critical (No Downtime)
- [ ] admin_password
- [ ] smoke_test_password
- [ ] autoscaler_password

### Phase 2: Internal Services (Brief Downtime)
- [ ] nats_password
- [ ] router_password
- [ ] bbs_password

### Phase 3: Critical (Maintenance Window)
- [ ] database_password
- [ ] blobstore_password
```

## Rotation Procedures by Type

### Password Rotation

#### Simple Password

```bash
# 1. Rotate the password
genesis rotate-secrets my-env admin_password

# 2. Deploy immediately
genesis deploy my-env

# 3. Test login with new password
cf login -a https://api.system.example.com
```

#### Database Password

Requires coordination:

```bash
# 1. Check current connections
bosh -d my-env-cf ssh database/0 \
  'sudo -u vcap psql -c "SELECT * FROM pg_stat_activity"'

# 2. Rotate password
genesis rotate-secrets my-env db/password

# 3. Deploy database first
genesis deploy my-env --skip-unchanged

# 4. Update applications
genesis deploy my-env

# 5. Verify connectivity
genesis do my-env -- run-errand smoke-tests
```

### SSH Key Rotation

```bash
# 1. Generate new key
genesis rotate-secrets my-env jumpbox/ssh

# 2. Deploy to update authorized_keys
genesis deploy my-env

# 3. Test new key
safe get secret/path/jumpbox/ssh:private > new_key
chmod 600 new_key
ssh -i new_key vcap@jumpbox

# 4. Remove old key from local systems
rm ~/.ssh/old_jumpbox_key
```

### Certificate Rotation

#### Server Certificate

```bash
# 1. Check expiration
safe x509 expires secret/us-east-1/prod/cf/haproxy/ssl

# 2. Rotate certificate
genesis rotate-secrets my-env haproxy/ssl

# 3. Deploy with new cert
genesis deploy my-env

# 4. Verify certificate
echo | openssl s_client -connect haproxy.example.com:443 2>/dev/null | \
  openssl x509 -noout -dates
```

#### CA Certificate Rotation

CA rotation is complex - requires careful planning:

```bash
# 1. Create new CA alongside old
safe x509 issue secret/path/new-ca \
  --ca \
  --valid-for 10y

# 2. Sign new certificates with new CA
genesis rotate-secrets my-env server/cert \
  --sign-with secret/path/new-ca

# 3. Deploy with both CAs trusted
# 4. Rotate all dependent certificates
# 5. Remove old CA
```

## Advanced Rotation Scenarios

### Zero-Downtime Password Rotation

For services supporting multiple credentials:

```yaml
# 1. Add new credential
credentials:
  base:
    db/password: random 32
    db/password_new: random 32

# 2. Deploy with both passwords
# 3. Switch to new password
# 4. Remove old password
```

### Rotating External Integrations

```bash
# 1. Create new credentials in external system
# AWS example:
aws iam create-access-key --user-name genesis-user

# 2. Update in Vault
safe set secret/us-east-1/prod/cf/aws \
  access_key=NEW_ACCESS_KEY \
  secret_key=NEW_SECRET_KEY

# 3. Deploy
genesis deploy my-env

# 4. Verify external access
genesis do my-env -- test-s3-access

# 5. Delete old credentials
aws iam delete-access-key \
  --user-name genesis-user \
  --access-key-id OLD_ACCESS_KEY
```

### Coordinated Multi-Environment Rotation

```bash
#!/bin/bash
# Rotate shared database password across environments

ENVIRONMENTS="dev staging prod"
SECRET="db/password"

# 1. Generate new password
NEW_PASS=$(safe gen password)

# 2. Update all environments
for env in $ENVIRONMENTS; do
  safe set secret/$env/cf/$SECRET value="$NEW_PASS"
done

# 3. Deploy in order
for env in $ENVIRONMENTS; do
  genesis deploy $env
  genesis do $env -- run-errand smoke-tests
done
```

## Monitoring and Verification

### Pre-Rotation Checks

```bash
# Check service health
bosh -d my-env-cf vms --vitals

# Verify current credentials work
genesis do my-env -- run-errand smoke-tests

# Backup current secrets
safe export secret/us-east-1/prod/cf > backup-before-rotation.json
```

### Post-Rotation Verification

```bash
# 1. Check deployment health
bosh -d my-env-cf vms --vitals

# 2. Run smoke tests
genesis do my-env -- run-errand smoke-tests

# 3. Check application logs
bosh -d my-env-cf logs api/0 --follow

# 4. Verify external integrations
curl -H "Authorization: Bearer $(safe get secret/path:token)" \
  https://api.example.com/health
```

## Rollback Procedures

### Immediate Rollback

If rotation causes issues:

```bash
# 1. Restore from backup
safe import < backup-before-rotation.json

# 2. Redeploy with old secrets
genesis deploy my-env

# 3. Verify services restored
genesis do my-env -- run-errand smoke-tests
```

### Partial Rollback

For specific secrets:

```bash
# Get old value from backup
OLD_VALUE=$(jq -r '.admin_password' backup-before-rotation.json)

# Restore specific secret
safe set secret/us-east-1/prod/cf/admin_password value="$OLD_VALUE"

# Redeploy
genesis deploy my-env
```

## Automation

### Scheduled Rotation Script

```bash
#!/bin/bash
# rotate-passwords.sh - Run monthly via cron

set -e

REPO="/home/genesis/cf-deployments"
ENVIRONMENTS="dev staging prod"
PASSWORDS="admin_password smoke_test_password autoscaler_password"

cd $REPO

for env in $ENVIRONMENTS; do
  echo "Rotating passwords for $env"
  
  # Rotate passwords
  genesis rotate-secrets $env $PASSWORDS
  
  # Deploy
  genesis deploy $env --yes
  
  # Test
  if ! genesis do $env -- run-errand smoke-tests; then
    echo "ERROR: Smoke tests failed for $env"
    exit 1
  fi
  
  echo "Successfully rotated $env"
done
```

### Certificate Expiration Monitoring

```bash
#!/bin/bash
# check-certs.sh - Run daily

THRESHOLD_DAYS=30

# Find expiring certificates
for env in $(genesis list); do
  certs=$(safe find secret/$env | grep cert$)
  
  for cert in $certs; do
    expires=$(safe x509 expires $cert --json | jq -r .not_after)
    expires_epoch=$(date -d "$expires" +%s)
    now_epoch=$(date +%s)
    days_left=$(( ($expires_epoch - $now_epoch) / 86400 ))
    
    if [ $days_left -lt $THRESHOLD_DAYS ]; then
      echo "WARNING: $cert expires in $days_left days"
      # Send alert
    fi
  done
done
```

## Best Practices

### 1. Regular Rotation Schedule

- **Passwords**: Every 90 days
- **SSH Keys**: Every 180 days
- **Server Certificates**: 30 days before expiry
- **CA Certificates**: 1 year before expiry

### 2. Test in Lower Environments

```bash
# Test rotation procedure
genesis rotate-secrets dev admin_password
genesis deploy dev

# If successful, proceed to staging and prod
```

### 3. Document External Dependencies

```yaml
# In environment file comments
# admin_password used by:
# - CF CLI admin scripts
# - Monitoring system (update manually)
# - Backup scripts (auto-updated)
```

### 4. Use Maintenance Windows

For critical rotations:
1. Schedule maintenance window
2. Notify users
3. Perform rotation
4. Verify thoroughly
5. Document completion

### 5. Maintain Audit Trail

```bash
# Before rotation
safe get secret/path | jq > audit/secret-before-$(date +%Y%m%d).json

# After rotation
genesis rotate-secrets my-env secret-name | tee audit/rotation-$(date +%Y%m%d).log
```

## Troubleshooting

### Service Won't Start

```bash
# Check logs for auth errors
bosh -d my-env-cf logs failing-job/0

# Verify secret was rotated
safe get secret/path/to/password

# Ensure deployment completed
bosh -d my-env-cf task <task-id>
```

### External Integration Broken

```bash
# Verify new credential format
safe get secret/path/api_key

# Test credential manually
curl -H "Authorization: $(safe get secret/path:key)" \
  https://api.example.com

# Check for hardcoded values
grep -r "old-password" /var/vcap/jobs/
```

### Rollback Failed

```bash
# Force redeploy with manifest
genesis manifest my-env > manifest.yml
bosh -d my-env-cf deploy manifest.yml \
  --vars-store=/dev/null \
  --recreate

# Manual secret injection if needed
bosh -d my-env-cf ssh job/0
# Update config files manually
```

Regular, well-planned rotation keeps your Genesis deployments secure while minimizing operational risk.