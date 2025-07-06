# Error Messages

This reference guide explains common Genesis error messages and how to resolve them.

## Environment Errors

### "Could not find environment 'X'"

**Full Error:**
```
Error: Could not find environment 'my-env' in /path/to/deployments
```

**Cause:** Genesis cannot find the environment YAML file.

**Resolution:**
```bash
# Check current directory
pwd  # Must be in deployment repository root

# List available environments
genesis list

# Create if missing
genesis new my-env
```

### "No deployment type specified"

**Full Error:**
```
Error: No deployment type specified in 'my-env.yml'
```

**Cause:** Environment file missing kit information.

**Resolution:**
```yaml
# Add to environment file
kit:
  name: concourse  # or your kit name
  version: 4.0.0   # optional
```

### "Circular dependency detected"

**Full Error:**
```
Error: Circular dependency detected in environment hierarchy
```

**Cause:** Environment files reference each other in a loop.

**Resolution:**
```bash
# Check environment references
grep "genesis.env:" *.yml

# Fix circular reference
# Remove or correct the circular dependency
```

## Kit Errors

### "Kit 'X' not found"

**Full Error:**
```
Error: Kit 'my-kit/1.0.0' not found in any known location
```

**Cause:** Kit not available locally or in upstream.

**Resolution:**
```bash
# List available kits
genesis list-kits my-kit

# Fetch from upstream
genesis fetch-kit my-kit

# Use local kit
genesis init --kit ./path/to/kit
```

### "Kit version mismatch"

**Full Error:**
```
Error: Environment requires kit version 2.0.0 but 1.0.0 is installed
```

**Cause:** Environment specifies different kit version than available.

**Resolution:**
```bash
# Update kit
genesis fetch-kit my-kit@2.0.0

# Or update environment
# Remove version requirement from kit: section
```

### "Invalid kit structure"

**Full Error:**
```
Error: Invalid kit structure: missing required directory 'manifests'
```

**Cause:** Kit missing required files/directories.

**Resolution:**
```bash
# Check kit structure
ls -la dev/
# Must have: kit.yml, manifests/, hooks/

# Create missing directories
mkdir -p dev/manifests dev/hooks
```

## Manifest Errors

### "Merge conflict detected"

**Full Error:**
```
Error: Merge conflict detected at $.instance_groups[0].name
```

**Cause:** YAML merge conflict between files.

**Resolution:**
```bash
# Debug merge
genesis manifest my-env --trace

# Test individual merges
spruce merge base.yml overlay.yml

# Use explicit operators
# (( replace )) to replace
# (( append )) to append
```

### "Could not resolve (( grab ... ))"

**Full Error:**
```
Error: Could not resolve (( grab params.missing_param ))
```

**Cause:** Referenced parameter not defined.

**Resolution:**
```yaml
# Define in environment
params:
  missing_param: "value"

# Or provide default
value: (( grab params.missing_param || "default" ))
```

### "Type mismatch in merge"

**Full Error:**
```
Error: Cannot merge string with array at $.networks[0]
```

**Cause:** Trying to merge incompatible types.

**Resolution:**
```yaml
# Ensure consistent types
# Bad:
base:    networks: "default"
overlay: networks: ["default", "other"]

# Good:
base:    networks: ["default"]
overlay: networks: ["default", "other"]
```

## Vault/Secret Errors

### "Could not connect to Vault"

**Full Error:**
```
Error: Could not connect to Vault at https://127.0.0.1:8200: connection refused
```

**Cause:** Vault not accessible.

**Resolution:**
```bash
# Check Vault target
safe target

# Set correct target
safe target my-vault https://vault.example.com:8200

# Verify connectivity
safe status
```

### "Secret not found"

**Full Error:**
```
Error: Could not retrieve secret 'secret/my/env/password:key' from Vault
```

**Cause:** Secret doesn't exist in Vault.

**Resolution:**
```bash
# Check if secret exists
safe exists secret/my/env/password

# Generate missing secrets
genesis add-secrets my-env

# Or create manually
safe set secret/my/env/password key=value
```

### "Permission denied"

**Full Error:**
```
Error: 403 permission denied accessing 'secret/my/env'
```

**Cause:** Vault token lacks required permissions.

**Resolution:**
```bash
# Check token permissions
safe vault token lookup

# Re-authenticate
safe auth

# Check policies
safe vault policy read my-policy
```

## BOSH Errors

### "Could not authenticate with BOSH"

**Full Error:**
```
Error: Could not authenticate with BOSH director: 401 Unauthorized
```

**Cause:** Invalid or expired BOSH credentials.

**Resolution:**
```bash
# Refresh BOSH credentials
genesis bosh my-env --reset

# Verify connection
bosh env
```

### "Deployment not found"

**Full Error:**
```
Error: Deployment 'my-env-concourse' not found on BOSH director
```

**Cause:** Deployment doesn't exist yet or wrong name.

**Resolution:**
```bash
# Check existing deployments
bosh deployments

# Deploy first
genesis deploy my-env

# Verify deployment name
genesis info my-env | grep "BOSH Deployment"
```

### "Cloud config missing required elements"

**Full Error:**
```
Error: Cloud config missing required vm_type 'small'
```

**Cause:** BOSH cloud config incomplete.

**Resolution:**
```bash
# Check cloud config
bosh cloud-config | grep vm_type

# Update cloud config
bosh update-cloud-config cloud.yml
```

## Hook Errors

### "Hook 'X' failed with exit code Y"

**Full Error:**
```
Error: Hook 'check' failed with exit code 1
```

**Cause:** Kit hook script failed.

**Resolution:**
```bash
# Debug hook
cd /path/to/kit
GENESIS_TRACE=1 ./hooks/check

# Check hook permissions
chmod +x hooks/check

# Review hook output for specific errors
```

### "Hook not found or not executable"

**Full Error:**
```
Error: Hook 'new' not found or not executable
```

**Cause:** Missing hook or wrong permissions.

**Resolution:**
```bash
# Check hook exists
ls -la hooks/new

# Fix permissions
chmod +x hooks/new

# Verify shebang
head -1 hooks/new  # Should be #!/bin/bash
```

## Validation Errors

### "Invalid YAML syntax"

**Full Error:**
```
Error: Invalid YAML in 'my-env.yml': found character that cannot start any token
```

**Cause:** YAML syntax error.

**Resolution:**
```bash
# Validate YAML
yamllint my-env.yml

# Common issues:
# - Tabs instead of spaces
# - Missing quotes around values with ':'
# - Incorrect indentation
```

### "Missing required parameter"

**Full Error:**
```
Error: Missing required parameter 'base_domain'
```

**Cause:** Required parameter not provided.

**Resolution:**
```yaml
# Add to environment file
params:
  base_domain: example.com
```

## State Errors

### "State file corrupted"

**Full Error:**
```
Error: State file corrupted or unreadable
```

**Cause:** Genesis state file damaged.

**Resolution:**
```bash
# Backup corrupted state
mv .genesis/state.yml .genesis/state.yml.backup

# Reinitialize
genesis init --kit my-kit .
```

### "Cache corrupted"

**Full Error:**
```
Error: Cached manifest corrupted for environment 'my-env'
```

**Cause:** Cached files corrupted.

**Resolution:**
```bash
# Clear cache
rm -rf .genesis/manifests/my-env.yml
rm -rf .genesis/cache/*

# Regenerate
genesis manifest my-env
```

## Network Errors

### "Connection timeout"

**Full Error:**
```
Error: Connection timeout downloading kit from upstream
```

**Cause:** Network connectivity issues.

**Resolution:**
```bash
# Check proxy settings
export http_proxy=http://proxy:8080
export https_proxy=http://proxy:8080

# Increase timeout
export GENESIS_DOWNLOAD_TIMEOUT=300
```

### "Certificate verification failed"

**Full Error:**
```
Error: x509: certificate signed by unknown authority
```

**Cause:** TLS certificate not trusted.

**Resolution:**
```bash
# Add CA certificate
export SSL_CERT_FILE=/path/to/ca-bundle.crt

# Or skip verification (dev only)
export GENESIS_SKIP_VERIFY=1
```

## Recovery Commands

### General Debugging

```bash
# Enable maximum debugging
export GENESIS_DEBUG=1
export GENESIS_TRACE=1
genesis deploy my-env

# Check Genesis version
genesis version

# Validate environment
genesis check my-env
```

### Quick Fixes

```bash
# Clear all caches
rm -rf ~/.genesis/cache/*
rm -rf .genesis/manifests/*

# Reset BOSH connection
genesis bosh my-env --reset

# Regenerate secrets
genesis rotate-secrets my-env

# Force manifest regeneration
rm .genesis/manifests/my-env.yml
genesis manifest my-env
```

### Getting Help

When reporting errors:

1. **Exact error message**
2. **Genesis version**: `genesis version`
3. **Command that failed**: `genesis deploy my-env`
4. **Trace output**: Run with `--trace`
5. **Environment details**: OS, network setup

Understanding error messages helps quickly identify and resolve issues. Most errors provide clear guidance on the problem and solution.