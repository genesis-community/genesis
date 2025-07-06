# Common Issues

This guide covers frequently encountered Genesis issues and their solutions.

## Installation Issues

### Genesis Command Not Found

**Symptom:**
```bash
$ genesis
-bash: genesis: command not found
```

**Solutions:**

1. **Add to PATH:**
   ```bash
   echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
   source ~/.bashrc
   ```

2. **Verify installation:**
   ```bash
   ls -la ~/bin/genesis
   # Should show executable file
   ```

3. **Reinstall Genesis:**
   ```bash
   curl -sL https://get.genesisproject.io/install | bash
   ```

### Permission Denied

**Symptom:**
```bash
$ genesis new my-env
Permission denied: cannot write to /path/to/repo
```

**Solution:**
```bash
# Fix permissions
sudo chown -R $(whoami):$(whoami) /path/to/repo

# Or use proper directory
cd ~/deployments/my-kit
genesis new my-env
```

## Deployment Issues

### Kit Not Found

**Symptom:**
```
Error: Kit 'my-kit/1.2.3' not found
```

**Solutions:**

1. **Check available versions:**
   ```bash
   genesis list-kits my-kit
   ```

2. **Update kit cache:**
   ```bash
   genesis fetch-kit my-kit
   ```

3. **Use local kit:**
   ```bash
   genesis new my-env --kit ./path/to/kit
   ```

### Environment File Not Found

**Symptom:**
```
Error: Could not find environment 'my-env'
```

**Solutions:**

1. **Check current directory:**
   ```bash
   pwd  # Should be in deployment repo root
   ls *.yml  # Should see environment files
   ```

2. **Verify environment exists:**
   ```bash
   genesis list
   find . -name "my-env.yml"
   ```

3. **Create environment:**
   ```bash
   genesis new my-env
   ```

### Merge Conflicts

**Symptom:**
```
Error: Merge conflict in parameters
```

**Solutions:**

1. **Debug merge order:**
   ```bash
   genesis manifest my-env --trace
   ```

2. **Check for duplicate keys:**
   ```bash
   # Look for duplicate parameters
   grep -n "param_name:" *.yml
   ```

3. **Use explicit null values:**
   ```yaml
   # In environment file
   params:
     unwanted_param: null  # Remove inherited value
   ```

## Vault/Secret Issues

### Cannot Connect to Vault

**Symptom:**
```
Error: Could not connect to Vault at https://127.0.0.1:8200
```

**Solutions:**

1. **Check Vault status:**
   ```bash
   safe target
   safe status
   ```

2. **Set Vault target:**
   ```bash
   safe target my-vault https://vault.example.com:8200
   ```

3. **Skip TLS verification (dev only):**
   ```bash
   safe target my-vault https://vault.example.com:8200 -k
   ```

### Missing Secrets

**Symptom:**
```
Error: Could not find secret at path/to/secret:key
```

**Solutions:**

1. **Check secret path:**
   ```bash
   safe tree path/to
   safe get path/to/secret
   ```

2. **Generate missing secrets:**
   ```bash
   genesis add-secrets my-env
   ```

3. **Check environment Vault path:**
   ```bash
   genesis secrets-path my-env
   ```

## BOSH Connection Issues

### Cannot Target BOSH Director

**Symptom:**
```
Error: Could not authenticate with BOSH director
```

**Solutions:**

1. **Check BOSH environment:**
   ```bash
   genesis bosh my-env
   bosh env
   ```

2. **Update BOSH credentials:**
   ```bash
   # Re-fetch from Vault
   genesis bosh my-env --reset
   ```

3. **Verify network connectivity:**
   ```bash
   curl -k https://<bosh-ip>:25555/info
   ```

### Deployment Not Found

**Symptom:**
```
Error: Deployment 'my-env-kit' not found
```

**Solutions:**

1. **Check deployment name:**
   ```bash
   bosh deployments
   genesis info my-env | grep "BOSH Deployment"
   ```

2. **Deploy first:**
   ```bash
   genesis deploy my-env
   ```

## State Corruption

### Invalid State File

**Symptom:**
```
Error: State file corrupted or invalid
```

**Solutions:**

1. **Backup and recreate:**
   ```bash
   # Backup current state
   cp .genesis/state.yml .genesis/state.yml.backup
   
   # Remove corrupted state
   rm .genesis/state.yml
   
   # Reinitialize
   genesis init --kit my-kit .
   ```

2. **Recover from BOSH:**
   ```bash
   # Get deployment manifest from BOSH
   bosh -d my-deployment manifest > recovered.yml
   ```

### Cache Corruption

**Symptom:**
```
Error: Invalid cached kit or corrupted download
```

**Solutions:**

1. **Clear cache:**
   ```bash
   rm -rf ~/.genesis/cache/*
   genesis fetch-kit my-kit
   ```

2. **Force redownload:**
   ```bash
   genesis compile-kit --force
   ```

## Network Issues

### Proxy Configuration

**Symptom:**
```
Error: Could not download kit - connection timeout
```

**Solutions:**

1. **Set proxy variables:**
   ```bash
   export http_proxy=http://proxy.example.com:8080
   export https_proxy=http://proxy.example.com:8080
   export no_proxy=localhost,127.0.0.1,.example.com
   ```

2. **Git proxy configuration:**
   ```bash
   git config --global http.proxy http://proxy.example.com:8080
   ```

### SSL Certificate Issues

**Symptom:**
```
Error: x509: certificate signed by unknown authority
```

**Solutions:**

1. **Add CA certificate:**
   ```bash
   export SSL_CERT_FILE=/path/to/ca-bundle.crt
   export CURL_CA_BUNDLE=/path/to/ca-bundle.crt
   ```

2. **Skip verification (dev only):**
   ```bash
   export GENESIS_SKIP_VAULT_VERIFY=1
   export BOSH_SKIP_SSL_VALIDATION=true
   ```

## Performance Issues

### Slow Manifest Generation

**Symptom:**
Manifest generation takes several minutes

**Solutions:**

1. **Enable caching:**
   ```bash
   export GENESIS_MANIFEST_CACHE=1
   ```

2. **Reduce spruce operations:**
   - Minimize grab operations
   - Use static references where possible
   - Avoid complex array operations

3. **Profile generation:**
   ```bash
   genesis manifest my-env --trace --time
   ```

### Memory Issues

**Symptom:**
```
Error: Cannot allocate memory
```

**Solutions:**

1. **Increase limits:**
   ```bash
   ulimit -m unlimited
   ulimit -v unlimited
   ```

2. **Use streaming for large files:**
   ```bash
   # Split large arrays
   # Use references instead of inline data
   ```

## Development Issues

### Hook Failures

**Symptom:**
```
Error: Hook 'new' exited with status 1
```

**Solutions:**

1. **Debug hook:**
   ```bash
   cd dev/
   GENESIS_TRACE=1 ./hooks/new
   ```

2. **Check hook permissions:**
   ```bash
   chmod +x hooks/*
   ```

3. **Validate bash syntax:**
   ```bash
   bash -n hooks/new
   ```

### Kit Compilation Errors

**Symptom:**
```
Error: Failed to compile kit
```

**Solutions:**

1. **Check kit.yml syntax:**
   ```bash
   yamllint kit.yml
   spruce merge kit.yml > /dev/null
   ```

2. **Validate directory structure:**
   ```bash
   # Required directories
   ls -d hooks/ manifests/
   ```

3. **Test compilation:**
   ```bash
   genesis compile-kit --dev
   ```

## Recovery Procedures

### Emergency Deployment Recovery

```bash
#!/bin/bash
# emergency-recovery.sh

ENV=$1
KIT=$2

echo "Attempting recovery of $ENV"

# 1. Backup current state
mkdir -p backups/$(date +%Y%m%d)
cp -r . backups/$(date +%Y%m%d)/

# 2. Get manifest from BOSH
bosh -d "$ENV-$KIT" manifest > recovered-manifest.yml

# 3. Extract parameters
spruce json recovered-manifest.yml | \
  jq '.params' > recovered-params.json

# 4. Recreate environment file
cat > "$ENV.yml" <<EOF
---
genesis:
  env: $ENV

kit:
  name: $KIT
  features: []

params:
$(spruce merge recovered-params.json | spruce json | jq -r 'to_entries | .[] | "  \(.key): \(.value)"')
EOF

echo "Recovery complete. Please review $ENV.yml"
```

### State Reset

```bash
# Complete state reset
rm -rf .genesis/
genesis init --kit my-kit .

# Reimport environments
for env in *.yml; do
  [[ -f "$env" ]] || continue
  echo "Importing $env..."
  # Environments are already in place
done
```

## Prevention Tips

1. **Regular Backups:**
   ```bash
   # Backup script
   tar czf genesis-backup-$(date +%Y%m%d).tar.gz \
     *.yml .genesis/ dev/
   ```

2. **Version Control:**
   ```bash
   git add -A
   git commit -m "Before deployment"
   git push
   ```

3. **Test Environments:**
   - Always test in dev first
   - Use `--dry-run` for validation
   - Keep staging identical to production

4. **Monitoring:**
   ```bash
   # Health check script
   genesis list | while read env; do
     genesis check "$env" || echo "ISSUE: $env"
   done
   ```

When encountering issues not covered here, use `--trace` flag and check Genesis GitHub issues for similar problems.