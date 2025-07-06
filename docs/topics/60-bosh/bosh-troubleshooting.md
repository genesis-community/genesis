# BOSH Troubleshooting

This guide helps diagnose and resolve common BOSH-related issues in Genesis deployments.

## Common Issues

### Deployment Failures

#### Symptom: Deployment Times Out

```bash
Task 1234 | Error: Timed out sending 'apply' to instance 'web/abc-123'
```

**Diagnosis:**
```bash
# Check task details
bosh task 1234 --debug

# Check instance status
bosh -d my-deployment instances --ps

# SSH to problematic instance
bosh -d my-deployment ssh web/abc-123
```

**Common Causes:**
1. VM not starting properly
2. Network connectivity issues
3. BOSH agent not responding
4. Insufficient resources

**Solutions:**
```bash
# Recreate the instance
bosh -d my-deployment recreate web/abc-123

# Check cloud infrastructure
bosh -d my-deployment cloud-check

# Increase timeout (if appropriate)
bosh -d my-deployment deploy --max-in-flight=1
```

#### Symptom: Package Compilation Failures

```bash
Task 1234 | Error: Package compilation failed
```

**Diagnosis:**
```bash
# View compilation logs
bosh task 1234 --debug | grep -A50 "compilation failed"

# Check compilation VMs
bosh -d my-deployment vms --details
```

**Solutions:**
```bash
# Use compiled releases
genesis set my-env compiled_releases true

# Increase compilation resources
# In cloud-config.yml:
compilation:
  workers: 5
  vm_type: large  # Bigger VMs
  network: default
```

### VM Issues

#### Symptom: VMs Not Starting

```bash
# Instance stuck in "starting" state
web/0 (abc-123) starting
```

**Diagnosis:**
```bash
# Check VM vitals
bosh -d my-deployment vms --vitals

# View agent logs
bosh -d my-deployment ssh web/0
sudo tail -f /var/vcap/bosh/log/current

# Check monit status
sudo monit summary
```

**Common Issues:**
1. **Disk full:**
   ```bash
   df -h
   # Clear logs if needed
   sudo find /var/vcap/sys/log -name "*.log" -mtime +7 -delete
   ```

2. **Memory exhausted:**
   ```bash
   free -m
   ps aux --sort=-%mem | head
   ```

3. **Process failing to start:**
   ```bash
   sudo tail -f /var/vcap/sys/log/*/current
   sudo monit restart all
   ```

#### Symptom: VM Unresponsive

**Quick Checks:**
```bash
# From director
bosh -d my-deployment ssh web/0 -c "echo 'VM responsive'"

# Check from director VM
ssh vcap@<instance-ip>

# Network connectivity
bosh -d my-deployment ssh other-vm
ping <problematic-vm-ip>
```

**Recovery:**
```bash
# Restart VM
bosh -d my-deployment restart web/0

# Hard recreate
bosh -d my-deployment recreate web/0 --force
```

### Network Issues

#### Symptom: Cannot Reach Other VMs

**Diagnosis:**
```bash
# Check network configuration
bosh -d my-deployment ssh web/0
ip addr show
ip route show
cat /etc/resolv.conf

# Test connectivity
ping <other-vm-ip>
nslookup other-vm.deployment.bosh
```

**Common Fixes:**
1. **DNS Issues:**
   ```bash
   # Check BOSH DNS
   sudo monit summary | grep bosh-dns
   dig @169.254.0.2 google.com
   
   # Restart BOSH DNS
   sudo monit restart bosh-dns
   ```

2. **Firewall/Security Groups:**
   ```bash
   # Verify security groups (AWS)
   aws ec2 describe-security-groups --group-ids sg-xxxxx
   
   # Test specific ports
   nc -zv other-vm 8080
   ```

### Persistent Disk Issues

#### Symptom: Disk Full or Missing

**Check Disk Status:**
```bash
# List disks
bosh -d my-deployment disks

# On VM
df -h
lsblk
mount | grep persistent
```

**Solutions:**

1. **Expand Disk:**
   ```yaml
   # Update manifest
   instance_groups:
   - name: database
     persistent_disk_type: large  # Bigger disk type
   ```
   ```bash
   # Apply change
   genesis deploy my-env
   ```

2. **Migrate Data:**
   ```bash
   # Stop jobs
   bosh -d my-deployment stop database/0
   
   # Attach new disk
   bosh -d my-deployment attach-disk database/0 disk-xxxxx
   
   # Start and migrate
   bosh -d my-deployment start database/0
   ```

### Certificate Issues

#### Symptom: TLS/Certificate Errors

**Diagnosis:**
```bash
# Check certificate expiry
bosh -d my-deployment ssh web/0
openssl x509 -in /var/vcap/jobs/web/config/cert.pem -noout -dates

# Verify certificate chain
openssl verify -CAfile ca.pem cert.pem
```

**Solutions:**
```bash
# Regenerate certificates via Genesis
genesis rotate-certs my-env

# Or manually via Vault
safe x509 renew secret/my/env/ssl/server --ttl 90d

# Redeploy
genesis deploy my-env
```

## Director Issues

### Director Unreachable

**Quick Diagnostics:**
```bash
# Test connectivity
curl -k https://<director-ip>:25555/info

# Check from jump box
nc -zv <director-ip> 25555

# Verify environment variables
echo $BOSH_ENVIRONMENT
echo $BOSH_CLIENT
```

**Common Fixes:**

1. **Network Path:**
   ```bash
   # Trace route
   traceroute <director-ip>
   
   # Check security groups/firewalls
   ```

2. **Director Services:**
   ```bash
   # SSH to director (if proto-bosh)
   # Check services
   sudo monit summary
   sudo tail -f /var/vcap/sys/log/director/current
   ```

### Database Issues

**Symptoms:**
- Slow deployments
- "Database is locked" errors
- Connection timeouts

**Diagnosis:**
```bash
# On director VM
sudo -u vcap psql -U postgres
\l  # List databases
\c bosh  # Connect to bosh db
SELECT count(*) FROM deployments;
SELECT count(*) FROM tasks;
```

**Maintenance:**
```bash
# Clean old tasks
bosh clean-up --all

# Vacuum database
sudo -u vcap psql -U postgres -d bosh -c "VACUUM ANALYZE;"

# Restart director
sudo monit restart director
```

## Advanced Troubleshooting

### Enable Debug Logging

```bash
# For specific deployment
bosh -d my-deployment deploy manifest.yml --debug

# For specific instance
bosh -d my-deployment ssh web/0
sudo su -
echo "debug" > /var/vcap/bosh/etc/level
```

### Cloud Check

Automated problem resolution:

```bash
# Interactive mode
bosh -d my-deployment cloud-check

# Automatic resolution
bosh -d my-deployment cloud-check --auto

# Report only
bosh -d my-deployment cloud-check --report
```

Common resolutions:
- Recreate unresponsive VMs
- Reattach persistent disks
- Delete missing VMs from state

### Manual State Cleanup

**Warning: Advanced operation**

```bash
# Export current state
bosh -d my-deployment manifest > current-manifest.yml

# Remove instance from state
bosh -d my-deployment delete-vm <cid>

# Recreate
bosh -d my-deployment deploy current-manifest.yml
```

### Task Analysis

```bash
# List recent failed tasks
bosh tasks --recent --failed

# Analyze specific task
bosh task <id> --debug > task-debug.log

# Common error patterns
grep -E "(error|failed|timeout)" task-debug.log
```

## Performance Issues

### Slow Deployments

**Diagnosis:**
```bash
# Check task timing
bosh task <id> --event

# Monitor director load
bosh -d director ssh
top
iostat -x 1
```

**Optimizations:**

1. **Parallel Operations:**
   ```yaml
   # In manifest
   update:
     max_in_flight: 10  # Increase parallelism
   ```

2. **Compiled Releases:**
   ```bash
   # Use pre-compiled releases
   bosh upload-release compiled-release.tgz
   ```

3. **Local Blobstore:**
   ```yaml
   # For directors with many deployments
   blobstore:
     provider: local
     path: /var/vcap/store/blobstore
   ```

## Recovery Procedures

### Emergency VM Recovery

```bash
#!/bin/bash
# emergency-recover.sh

DEPLOYMENT=$1
INSTANCE=$2

echo "Attempting recovery of $INSTANCE in $DEPLOYMENT"

# Stop instance
bosh -d $DEPLOYMENT stop $INSTANCE

# Cloud check
bosh -d $DEPLOYMENT cloud-check --auto

# Recreate
bosh -d $DEPLOYMENT recreate $INSTANCE

# Verify
bosh -d $DEPLOYMENT instances --ps
```

### State File Recovery

When deployment state is corrupted:

```bash
# Backup current state
cp ~/.bosh/state.json state.json.backup

# Recreate from manifest
bosh create-env manifest.yml \
  --state=state.json \
  --vars-store=creds.yml \
  --recreate

# For managed deployments
bosh -d my-deployment deploy manifest.yml --recreate
```

## Monitoring and Prevention

### Health Checks

Regular health monitoring:

```bash
#!/bin/bash
# bosh-health-check.sh

echo "=== Director Health ==="
bosh env

echo "=== Deployments ==="
bosh deployments

echo "=== Problem Instances ==="
for d in $(bosh deployments --json | jq -r '.Tables[0].Rows[].name'); do
  echo "Checking $d..."
  bosh -d $d instances --ps | grep -v running || true
done

echo "=== Recent Failed Tasks ==="
bosh tasks --recent=10 --failed
```

### Preventive Maintenance

```bash
# Weekly maintenance script
#!/bin/bash

# Clean up old releases
bosh clean-up --all

# Check disk usage
bosh -d director ssh -c "df -h"

# Verify backups
genesis do my-bosh -- bbr deployment backup

# Update stemcells
bosh stemcells --recent
```

## Getting Help

### Collecting Diagnostics

When reporting issues:

```bash
# Collect bundle
bosh -d my-deployment logs --all

# Director info
bosh env --json > director-info.json

# Task details
bosh task <id> --debug > task-output.log

# Manifest (sanitized)
bosh -d my-deployment manifest | \
  sed 's/password: .*/password: REDACTED/g' > manifest.yml
```

### Debug Information

Include in bug reports:
- Genesis version: `genesis version`
- BOSH version: `bosh env`
- Kit version: `genesis kit-info`
- Error messages and task IDs
- Steps to reproduce

Effective troubleshooting combines understanding BOSH internals with systematic diagnosis and proper tooling.