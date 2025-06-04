# BOSH User Credentials Feature

## Overview

Genesis now supports using personal BOSH user credentials from environment variables, replacing the need to rely exclusively on shared admin credentials stored in Vault. This feature improves security, provides better audit trails, and aligns with modern authentication best practices.

## Key Features

- **User-specific authentication**: Each operator uses their own BOSH credentials
- **Environment variable support**: Standard `BOSH_USER`/`BOSH_PASSWORD` variables
- **Backward compatibility**: Existing workflows continue to work unchanged
- **Automatic UAA provisioning**: User credentials can be automatically created in UAA
- **Dual credential format**: Both user and client credentials are supported

## Quick Start

### Setting User Credentials

Set your personal BOSH credentials using env vars:
```bash
export BOSH_USER="alice"
export BOSH_PASSWORD="my-secure-password"
```

NOTE: Genesis will continue to provide these items:
```bash
export BOSH_ENVIRONMENT="https://10.0.0.5:25555"
export BOSH_CA_CERT="/path/to/ca-cert.pem"  # or the certificate content
export BOSH_ALIAS="prod-bosh"
```

### Using Genesis with User Credentials

Once your credentials are set, use Genesis normally:

```bash
# Deploy an environment
genesis deploy my-env

# Run BOSH commands
genesis bosh my-env vms
genesis bosh my-env ssh

# Check which credentials are being used
genesis bosh my-env env
```

## How It Works

### Credential Priority

Genesis checks for BOSH credentials in the following order:

1. **User credentials** (`BOSH_USER`/`BOSH_PASSWORD`) - *NEW*
2. **Client credentials** (`BOSH_CLIENT`/`BOSH_CLIENT_SECRET`) - Set by Genesis 
3. **Local BOSH config** (~/.bosh/config aliases) - If use the bosh login Genesis will use this.
4. **Vault admin credentials** (exodus data) - What Genesis currently uses by default.

### Automatic Credential Synchronization

When user credentials are detected, Genesis automatically sets both formats:

- `BOSH_USER` / `BOSH_PASSWORD` - User format
- `BOSH_CLIENT` / `BOSH_CLIENT_SECRET` - Client format (same values)

This ensures compatibility with all BOSH CLI operations and existing automation.

## UAA Integration

### Automatic UAA Admin Credential Storage

For BOSH directors deployed with `create-env`, Genesis now automatically stores UAA admin credentials in Vault via the kit.

- **Username**: `admin`
- **Password**: Same as the BOSH admin password

This enables post-deploy hooks and automation to authenticate to UAA without hardcoding credentials.

### User Credential Provisioning

Kit authors can implement automatic user credential provisioning using post-deploy hooks. See the [example post-deploy hook](example-post-deploy-user-credentials) for a complete implementation.

## Configuration Examples

### Individual Developer

```bash
# ~/.bashrc or ~/.bash_profile
export BOSH_USER="john.doe"
export BOSH_PASSWORD="$(vault read -field=password secret/personal/bosh)"
```

### CI/CD Pipeline

```yaml
# .gitlab-ci.yml
deploy:
  script:
    - export BOSH_USER="ci-user"
    - export BOSH_PASSWORD="$CI_BOSH_PASSWORD"  # from CI secrets
    - genesis @mgmt:prod deploy --yes
```

### Environment-Specific Credentials

```bash
#!/bin/bash
# deploy.sh

case "$ENVIRONMENT" in
  production)
    export BOSH_USER="prod-deployer"
    export BOSH_PASSWORD="$PROD_BOSH_PASSWORD"
    ;;
  staging)
    export BOSH_USER="staging-deployer"
    export BOSH_PASSWORD="$STAGING_BOSH_PASSWORD"
    ;;
  *)
    export BOSH_USER="dev-user"
    export BOSH_PASSWORD="$DEV_BOSH_PASSWORD"
    ;;
esac

genesis deploy "${ENVIRONMENT}-env"
```

## Creating User Credentials in UAA

### Manual Creation

```bash
# Target the BOSH director's UAA
uaac target https://10.0.0.5:8443 --ca-cert ~/ops/bosh/ops/root_ca_certificate

# Login as UAA admin (password from Vault)
ADMIN_PASS=$(safe get secret/exodus/my-bosh/bosh:uaa_admin_password)
uaac token owner get login -s "$ADMIN_PASS" <<< "admin
$ADMIN_PASS"

# Create user
uaac user add alice \
  --emails alice@example.com \
  --password "secure-password"

# Grant BOSH admin permissions
uaac member add bosh.admin alice

# Create client with same credentials (for compatibility)
uaac client add alice \
  --authorized_grant_types client_credentials \
  --authorities bosh.admin \
  --secret "secure-password"
```

## Troubleshooting

### Debugging Credential Detection

Enable debug mode to see how Genesis detects credentials:

```bash
export GENESIS_DEBUG=1
genesis bosh my-env env
```

Look for messages like:
```
DEBUG: Validating user credentials...
DEBUG: User credentials are valid and ready for use
INFO: Using user credentials from environment variables: BOSH_USER=alice
```

### Common Issues

#### Issue: "Missing required environment variables"

**Solution**: Ensure all required variables are set:
```bash
echo "BOSH_USER=$BOSH_USER"
echo "BOSH_PASSWORD=${BOSH_PASSWORD:+[SET]}"  # Don't echo the actual password
```

#### Issue: "401 Unauthorized"

**Possible Causes**:
1. User doesn't exist in UAA
2. Incorrect password
3. User lacks required permissions

**Solution**: Verify credentials work with BOSH CLI directly:
```bash
bosh -e "$BOSH_ENVIRONMENT" --client="$BOSH_USER" --client-secret="$BOSH_PASSWORD" env
```

#### Issue: "User exists but operations fail"

**Solution**: Check user permissions in UAA:
```bash
uaac user get "$BOSH_USER"
uaac member add bosh.admin "$BOSH_USER"  # Grant admin access
```

### Validation Commands

```bash
# Check which credentials Genesis will use
genesis @mgmt:envname info | grep -i bosh

# Test BOSH connection
genesis @mgmt:envname bosh env

# Verify credential type being used
GENESIS_DEBUG=1 genesis deploy my-env --dry-run 2>&1 | grep -i "credential"
```

## Security Best Practices

### Credential Storage

**DO:**
- Store passwords in secure vaults (HashiCorp Vault, OpenBao, BitWarden, etc...)
- Use environment-specific credentials
- Rotate credentials regularly
- Use strong, unique passwords

**DON'T:**
- Hardcode passwords in scripts
- Share credentials between users
- Use the same password across environments
- Store passwords in version control

### Example Secure Setup

```bash
# Store password securely
safe set secret/personal/bosh password=<enter-password>

# Use in scripts
export BOSH_USER="alice"
export BOSH_PASSWORD="$(safe get secret/personal/bosh:password)"
```

### Audit Trail Benefits

With user credentials, BOSH logs show individual actions:

```
Task 1234 | 10:30:45 | Updating deployment: Started by alice
Task 1235 | 11:15:22 | Deleting VM: Started by bob
```

Instead of generic admin entries:

```
Task 1234 | 10:30:45 | Updating deployment: Started by admin
Task 1235 | 11:15:22 | Deleting VM: Started by admin
```

## Implementation Details

### New Methods

The following methods were added to `Service::BOSH::Director`:

- `validate_user_credentials()` - Validates environment variables
- `detect_user_credentials()` - Creates director with user credentials
- `supports_user_credentials()` - Checks if director uses user credentials
- `get_credential_type()` - Returns 'user' or 'client'
- `synchronize_credentials()` - Ensures dual format compatibility

### Modified Methods

- `from_environment()` - Now prioritizes user credentials
- `environment_variables()` - Sets both credential formats
- `Genesis::Env::bosh()` - Checks user credentials first
- `Genesis::Env::get_target_bosh()` - Prioritizes user credentials

## Backward Compatibility

All existing Genesis functionality remains unchanged:

- Environments without user credentials continue to use Vault admin credentials
- Existing CI/CD pipelines work without modification
- BOSH config aliases still function
- Client credentials (`BOSH_CLIENT`/`BOSH_CLIENT_SECRET`) are still supported

## Migration Guide

### For Operators

1. **Create your UAA user account** (see [Creating User Credentials](#creating-user-credentials-in-uaa))

2. **Test the credentials**:
   ```bash
   export BOSH_USER="your-username"
   export BOSH_PASSWORD="your-password"
   genesis @mgmt:bosh bosh env
   ```

3. **Update your shell profile** to set credentials automatically

4. **Update team documentation** to reflect the new authentication method

### For Kit Authors

1. **Add post-deploy hook** (optional) to automatically provision user credentials

2. **Update kit documentation** to mention user credential support

3. **Test compatibility** with both user and client credentials

## FAQ

**Q: Do I have to use user credentials?**
A: No, this is an optional feature. Existing admin credentials continue to work.

**Q: Can I use both user and client credentials?**
A: Yes, but user credentials take priority when both are set.

**Q: Will this break my existing automation?**
A: No, all existing workflows remain functional. This is purely additive.

**Q: How do I know which credentials Genesis is using?**
A: Run `genesis bosh <env> env` - it shows the authenticated user.

**Q: Can I use different credentials for different environments?**
A: Yes, credentials are read from environment variables, so you can change them as needed.

**Q: What happens if my user credentials are invalid?**
A: Genesis falls back to the next authentication method (client credentials, then Vault admin).

## Related Documentation

- [Example Post-Deploy Hook](example-post-deploy-user-credentials)
- [Genesis Environment Variables](environment-variables.md)
- [BOSH Authentication](https://bosh.io/docs/cli-v2/#auth)
- [UAA User Management](https://docs.cloudfoundry.org/uaa/uaa-user-management.html)