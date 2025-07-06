# Debugging Deployments

This guide provides systematic approaches to debugging Genesis deployment issues.

## Deployment Workflow

Understanding the deployment process helps identify where issues occur:

1. **Environment Resolution** - Finding and merging environment files
2. **Secret Retrieval** - Fetching credentials from Vault
3. **Manifest Generation** - Creating final BOSH manifest
4. **Validation** - Pre-deployment checks
5. **BOSH Deployment** - Actual deployment to infrastructure
6. **Post-Deploy** - Hooks and cleanup

## Pre-Deployment Debugging

### Environment Resolution Issues

**Debug environment file loading:**

```bash
# Trace environment resolution
genesis manifest my-env --trace 2>&1 | grep -E "(Loading|Merging)"

# Example output:
# Loading us.yml
# Loading us-east.yml
# Loading us-east-prod.yml
# Merging 3 environment files...
```

**Common problems:**

1. **Missing parent files:**
   ```bash
   # Check file existence
   genesis manifest my-env 2>&1 | grep "Could not find"
   
   # Fix: Create missing files
   touch us.yml us-east.yml
   ```

2. **Circular dependencies:**
   ```bash
   # Error: Circular dependency detected
   # Check for files that reference each other
   grep -l "genesis.env:" *.yml
   ```

### Feature Validation

**Debug feature issues:**

```bash
# List available features
genesis info my-env | grep -A20 "Available Features"

# Check enabled features
genesis manifest my-env | grep -A10 "kit.features"

# Validate feature combination
genesis check my-env --trace
```

**Common feature problems:**

```yaml
# Incompatible features
kit:
  features:
    - azure
    - aws  # Error: Can't use multiple IaaS

# Missing dependencies
kit:
  features:
    - ha  # Might require minimum instances
```

### Secret Debugging

**Trace secret retrieval:**

```bash
# List required secrets
genesis secrets-plan my-env

# Check missing secrets
genesis check-secrets my-env

# Debug secret paths
GENESIS_TRACE=1 genesis manifest my-env 2>&1 | grep -i vault
```

**Debug Vault connectivity:**

```bash
# Test Vault access
safe target
safe tree $(genesis secrets-path my-env)

# Manual secret check
safe get $(genesis secrets-path my-env)/admin:password
```

## Manifest Generation Debugging

### Trace Manifest Building

**Full trace of manifest generation:**

```bash
# Save trace output
genesis manifest my-env --trace > trace.log 2>&1

# Analyze phases
grep -n "Phase:" trace.log
```

**Step-by-step debugging:**

```bash
# 1. Base manifest only
genesis manifest my-env --partial base

# 2. With features
genesis manifest my-env --partial features

# 3. With secrets (no Vault lookup)
genesis manifest my-env --no-resolve

# 4. Final manifest
genesis manifest my-env
```

### Spruce Merge Issues

**Debug merge operations:**

```bash
# Extract spruce operations
genesis manifest my-env --trace 2>&1 | \
  grep -E "(spruce merge|Error.*spruce)"

# Test specific merge
spruce merge file1.yml file2.yml

# Debug grab operations
spruce merge --trace manifest.yml 2>&1 | grep grab
```

**Common spruce errors:**

1. **Undefined variables:**
   ```yaml
   # Error: (( grab params.missing )) - params.missing not found
   # Fix: Define in environment or use default
   value: (( grab params.missing || "default" ))
   ```

2. **Type mismatches:**
   ```yaml
   # Error: Cannot merge string into array
   # Check data types
   spruce diff base.yml override.yml
   ```

### Parameter Resolution

**Debug parameter lookup:**

```bash
# Show all parameters
genesis manifest my-env | spruce json | jq '.params'

# Trace parameter source
for file in $(genesis manifest my-env --trace 2>&1 | grep Loading | awk '{print $2}'); do
  echo "=== $file ==="
  grep "param_name:" "$file" || true
done
```

## Deployment Debugging

### Pre-Deployment Validation

**Run comprehensive checks:**

```bash
# Full validation
genesis check my-env

# Individual checks
genesis check-secrets my-env
genesis check-cloud-config my-env
genesis check-stemcells my-env
```

**Manual BOSH validation:**

```bash
# Get manifest
genesis manifest my-env > manifest.yml

# Validate with BOSH
bosh -d my-deployment deploy manifest.yml --dry-run

# Check interpolation
bosh int manifest.yml
```

### Deployment Execution

**Monitor deployment progress:**

```bash
# Deploy with verbose output
genesis deploy my-env --trace

# In another terminal, watch BOSH task
bosh tasks --recent
bosh task <id> --debug
```

**Debug deployment failures:**

```bash
# Get failing task details
bosh task <id> --debug | less

# Common patterns to search
/error
/failed
/timeout
/not found
```

### Instance-Level Debugging

**Access problematic instances:**

```bash
# List instances with issues
bosh -d my-deployment instances --ps

# SSH to instance
bosh -d my-deployment ssh web/0

# Check logs
sudo tail -f /var/vcap/sys/log/**/*.log

# Check monit
sudo monit summary
```

## Post-Deployment Debugging

### Hook Failures

**Debug post-deploy hooks:**

```bash
# Run hook manually
cd /path/to/kit
GENESIS_ENVIRONMENT=my-env \
GENESIS_VAULT_PREFIX=$(genesis secrets-path my-env) \
GENESIS_TRACE=1 \
./hooks/post-deploy
```

### Smoke Test Failures

**Debug smoke tests:**

```bash
# Run errand manually
bosh -d my-deployment run-errand smoke-tests

# Get errand logs
bosh -d my-deployment run-errand smoke-tests --download-logs
tar xzf smoke-tests-logs.tgz
```

## Advanced Debugging Techniques

### Manifest Diffing

**Compare manifests:**

```bash
# Compare with last deployment
bosh -d my-deployment manifest > current.yml
genesis manifest my-env > new.yml
diff -u current.yml new.yml

# Semantic diff
spruce diff current.yml new.yml
```

### State Analysis

**Check Genesis state:**

```bash
# View cached information
cat .genesis/manifests/my-env.yml
cat .genesis/configs/my-env.yml

# Check deployment state
cat .genesis/deployments/my-env.yml
```

### Environment Variable Debugging

**Check Genesis environment:**

```bash
# Show all Genesis variables
env | grep GENESIS | sort

# Run with specific debug flags
GENESIS_TRACE=1 \
GENESIS_DEBUG=1 \
GENESIS_VAULT_VERIFY=0 \
genesis deploy my-env
```

## Recovery Procedures

### Partial Deployment Recovery

```bash
#!/bin/bash
# recover-deployment.sh

DEPLOYMENT=$1

# 1. Get current state from BOSH
echo "Fetching current deployment state..."
bosh -d $DEPLOYMENT manifest > current-state.yml

# 2. Compare with desired state
echo "Comparing states..."
genesis manifest ${DEPLOYMENT%-*} > desired-state.yml
spruce diff current-state.yml desired-state.yml > state-diff.txt

# 3. Identify stuck instances
echo "Checking instances..."
bosh -d $DEPLOYMENT instances --ps | grep -v running > stuck-instances.txt

# 4. Attempt recovery
if [[ -s stuck-instances.txt ]]; then
  echo "Found stuck instances:"
  cat stuck-instances.txt
  
  # Restart stuck instances
  while read instance; do
    inst=$(echo $instance | awk '{print $1}')
    echo "Restarting $inst..."
    bosh -d $DEPLOYMENT restart $inst
  done < stuck-instances.txt
fi
```

### Manual State Correction

```bash
# Force convergence
bosh -d my-deployment cloud-check --auto

# Recreate specific instances
bosh -d my-deployment recreate web/0

# Full recreation (last resort)
bosh -d my-deployment recreate
```

## Debugging Checklist

### Before Deployment

- [ ] Environment files exist and are valid YAML
- [ ] All parent files are present
- [ ] Features are compatible
- [ ] Required parameters are set
- [ ] Vault is accessible
- [ ] Secrets exist or can be generated
- [ ] Cloud config has required resources
- [ ] Stemcells are uploaded

### During Deployment

- [ ] Monitor BOSH task output
- [ ] Check for compilation failures
- [ ] Verify network connectivity
- [ ] Watch for timeout errors
- [ ] Check instance health

### After Deployment Failure

- [ ] Collect BOSH task logs
- [ ] Save current manifest
- [ ] Check instance states
- [ ] Review error messages
- [ ] Verify cloud resources
- [ ] Check persistent disks

## Common Patterns

### Timeout Issues

```bash
# Increase timeouts
export BOSH_CLIENT_TIMEOUT=300

# Deploy with reduced parallelism
genesis deploy my-env -- --max-in-flight=1
```

### Resource Constraints

```bash
# Check cloud usage
bosh cloud-config | grep -A5 compilation

# Reduce compilation workers
bosh update-cloud-config <(
  bosh cloud-config | 
  sed 's/workers: .*/workers: 2/'
)
```

### Network Problems

```bash
# Test from director
bosh -d my-deployment ssh web/0 -c "ping -c 3 8.8.8.8"

# Check DNS resolution
bosh -d my-deployment ssh web/0 -c "nslookup google.com"
```

Effective debugging combines systematic analysis with understanding of the deployment pipeline. Always collect evidence before attempting fixes.