# Manual Secret Management

While Genesis automates most secret operations, sometimes you need direct control. This guide covers manual secret management techniques for special cases and troubleshooting.

## Direct Vault Access

### Using Safe CLI

The `safe` command provides direct Vault access:

```bash
# Target Vault
safe target prod https://vault.example.com:8200
safe auth

# Basic operations
safe set secret/path key=value
safe get secret/path
safe delete secret/path
safe move secret/old/path secret/new/path
safe copy secret/source secret/dest
```

### Complex Secret Operations

```bash
# Set multiple keys
safe set secret/us-east-1/prod/cf/database \
  username=dbadmin \
  password=complex-password \
  host=db.example.com \
  port=5432

# Set from file
safe set secret/path/cert value=@/path/to/cert.pem

# Set JSON data
safe set secret/path/config value='{"key": "value", "foo": "bar"}'

# Interactive mode
safe set secret/path/password
# Prompts for value (hidden)
```

## Viewing and Exporting Secrets

### Individual Secrets

```bash
# View specific key
safe get secret/us-east-1/prod/cf/admin_password

# Get just the value
safe get secret/us-east-1/prod/cf/admin_password:value

# Format output
safe get secret/path --format json
safe get secret/path --format yaml
```

### Bulk Operations

```bash
# List all secrets
safe tree secret/us-east-1/prod/cf

# Export entire tree
safe export secret/us-east-1/prod/cf > cf-secrets.json

# Export with paths
safe export --all secret/us-east-1/prod > all-secrets.json

# Find secrets by pattern
safe find secret/us-east-1 | grep password
```

## Manual Generation

### Passwords

```bash
# Generate password in Vault
safe gen secret/path/password

# With specific length
safe gen secret/path/password length=40

# Custom parameters
safe gen secret/path/password \
  length=32 \
  policy=printable

# Generate locally and set
PASSWORD=$(openssl rand -base64 32)
safe set secret/path value="$PASSWORD"
```

### SSH Keys

```bash
# Generate SSH key
safe ssh secret/path/ssh-key

# With specific size
safe ssh secret/path/ssh-key size=4096

# Extract public key
safe get secret/path/ssh-key:public > id_rsa.pub

# Generate locally
ssh-keygen -t rsa -b 4096 -f temp_key -N ""
safe set secret/path/ssh \
  private=@temp_key \
  public=@temp_key.pub
rm temp_key temp_key.pub
```

### Certificates

```bash
# Create CA
safe x509 ca secret/path/ca \
  --common-name "Genesis CA" \
  --valid-for 10y

# Issue certificate
safe x509 issue secret/path/server \
  --ca secret/path/ca \
  --common-name server.example.com \
  --alternative-names "*.example.com,10.0.0.5" \
  --valid-for 1y

# Self-signed certificate
safe x509 self-signed secret/path/self \
  --common-name test.example.com \
  --valid-for 90d
```

### RSA Keys

```bash
# Generate RSA key pair
openssl genrsa -out private.pem 4096
openssl rsa -in private.pem -pubout -out public.pem

# Store in Vault
safe set secret/path/rsa \
  private=@private.pem \
  public=@public.pem

# Clean up
rm private.pem public.pem
```

## Fixing Secret Issues

### Wrong Format

```bash
# Certificate stored incorrectly
safe get secret/path/cert

# Fix by reformatting
CERT=$(safe get secret/path/cert:value)
safe set secret/path/cert \
  cert="$CERT" \
  key=@private.key \
  ca=@ca.crt
```

### Missing Components

```bash
# SSH key missing public component
PRIVATE=$(safe get secret/path/ssh:private)

# Generate public from private
echo "$PRIVATE" > temp.key
chmod 600 temp.key
ssh-keygen -y -f temp.key > temp.pub

# Update secret
safe set secret/path/ssh \
  private="$PRIVATE" \
  public=@temp.pub

rm temp.key temp.pub
```

### Corrupted Secrets

```bash
# Backup current state
safe export secret/path > backup.json

# Check for issues
safe get secret/path | jq .

# Restore from backup if needed
safe import < backup.json
```

## Path Management

### Moving Secrets

```bash
# Move single secret
safe move secret/old/path secret/new/path

# Move entire tree
safe export secret/old/tree > temp.json
safe import --at secret/new/tree < temp.json
safe delete secret/old/tree --recursive
```

### Copying Between Environments

```bash
# Copy from dev to staging
safe export secret/dev/cf > dev-secrets.json

# Modify paths
sed 's|secret/dev|secret/staging|g' dev-secrets.json > staging-secrets.json

# Import to staging
safe import < staging-secrets.json
```

### Cleaning Up

```bash
# Delete single secret
safe delete secret/path/to/delete

# Delete with confirmation
safe delete secret/important/path --prompt

# Recursive delete
safe delete secret/entire/tree --recursive

# Dry run
safe delete secret/path --recursive --dry-run
```

## Advanced Techniques

### Templating Secrets

```bash
#!/bin/bash
# Generate environment-specific secrets

ENVS="dev staging prod"
TEMPLATE='{
  "admin_password": "$(safe gen password)",
  "api_key": "$(uuidgen)",
  "deployed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}'

for env in $ENVS; do
  eval "echo '$TEMPLATE'" | \
    jq . | \
    safe import --at "secret/$env/cf/metadata"
done
```

### Bulk Updates

```bash
#!/bin/bash
# Update all passwords in an environment

BASE_PATH="secret/us-east-1/prod/cf"

# Find all passwords
safe find "$BASE_PATH" | grep password$ | while read -r path; do
  echo "Rotating: $path"
  safe gen "$path" length=32
done
```

### Secret Validation

```bash
#!/bin/bash
# Validate secret structure

validate_secret() {
  local path=$1
  local required_keys=$2
  
  for key in $required_keys; do
    if ! safe exists "$path:$key"; then
      echo "ERROR: Missing $key in $path"
      return 1
    fi
  done
  
  echo "OK: $path has all required keys"
  return 0
}

# Check database secret
validate_secret "secret/prod/cf/db" "username password host port"

# Check certificate
validate_secret "secret/prod/cf/cert" "cert key ca"
```

## Integration Scripts

### Pre-deployment Validation

```bash
#!/bin/bash
# check-secrets.sh - Run before deployment

ENV=$1
BASE="secret/$ENV/cf"

echo "Checking secrets for $ENV..."

# Required secrets
REQUIRED=(
  "admin_password"
  "db/password"
  "nats/password"
  "router/ca"
)

MISSING=()
for secret in "${REQUIRED[@]}"; do
  if ! safe exists "$BASE/$secret"; then
    MISSING+=("$secret")
  fi
done

if [ ${#MISSING[@]} -ne 0 ]; then
  echo "ERROR: Missing secrets:"
  printf ' - %s\n' "${MISSING[@]}"
  exit 1
fi

echo "All required secrets present"
```

### External Service Integration

```bash
#!/bin/bash
# Sync external API keys

# Fetch from external service
API_KEY=$(aws secretsmanager get-secret-value \
  --secret-id prod/api-key \
  --query SecretString \
  --output text)

# Store in Vault
safe set secret/us-east-1/prod/cf/external/aws \
  api_key="$API_KEY" \
  updated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

## Debugging

### Trace Secret Usage

```bash
# Find where a secret is used
SECRET_NAME="admin_password"
ENV="us-east-1-prod"

# Check manifest
genesis manifest $ENV | grep -n "$SECRET_NAME"

# Check generated manifest
bosh -d $ENV-cf manifest | grep -n "$SECRET_NAME"

# Check runtime config
bosh runtime-config | grep -n "$SECRET_NAME"
```

### Audit Access

```bash
# Enable audit logging
vault audit enable file file_path=/var/log/vault-audit.log

# Check who accessed a secret
grep "secret/us-east-1/prod" /var/log/vault-audit.log | \
  jq -r '[.time, .auth.display_name, .request.path] | @csv'
```

## Best Practices

### 1. Document Manual Changes

```bash
# Add metadata when manually setting
safe set secret/path/manual-secret \
  value="special-value" \
  created_by="$USER" \
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  reason="Required for legacy system X"
```

### 2. Use Atomic Operations

```bash
# Update multiple related secrets together
cat <<EOF | safe import --at secret/path
{
  "username": "newuser",
  "password": "newpass",
  "updated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
```

### 3. Maintain Backups

```bash
# Before manual changes
safe export secret/path > "backup-$(date +%Y%m%d-%H%M%S).json"

# Verify backup
jq . backup-*.json
```

### 4. Test Changes

```bash
# Test in lower environment first
safe copy secret/prod/setting secret/dev/setting-test
# Test deployment with dev environment
# If successful, apply to prod
```

### 5. Clean Up Temporary Files

```bash
# Use trap for cleanup
cleanup() {
  rm -f /tmp/temp-key-*
}
trap cleanup EXIT

# Work with temporary files
TEMP_KEY=$(mktemp /tmp/temp-key-XXXXXX)
# ... use temp file ...
# Cleanup happens automatically
```

Manual secret management gives you full control when Genesis automation isn't sufficient, but use it judiciously to maintain security and consistency.