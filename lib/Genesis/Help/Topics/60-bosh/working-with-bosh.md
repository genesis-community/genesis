# Working with BOSH

This guide covers common BOSH operations in the context of Genesis deployments and when to use BOSH commands directly.

## Accessing BOSH Through Genesis

### Setting BOSH Environment

Genesis provides several ways to access the underlying BOSH director:

```bash
# Method 1: Get BOSH connection details
genesis bosh my-env

# Method 2: Open a shell with BOSH environment set
genesis do my-env -- bash
# $BOSH_ENVIRONMENT, $BOSH_CLIENT, etc. are now set

# Method 3: Run a specific BOSH command
genesis do my-env -- bosh vms
```

### Environment Variables

When Genesis sets up BOSH access, it configures:

- `BOSH_ENVIRONMENT` - Director URL
- `BOSH_CLIENT` - Authentication client
- `BOSH_CLIENT_SECRET` - Authentication secret
- `BOSH_CA_CERT` - CA certificate for TLS
- `BOSH_DEPLOYMENT` - Current deployment name

## Common BOSH Operations

### Viewing Deployment Information

```bash
# List all deployments
bosh deployments

# View VMs in a deployment
bosh -d my-deployment vms

# Detailed VM information with vitals
bosh -d my-deployment vms --vitals

# View current manifest
bosh -d my-deployment manifest

# View deployment properties
bosh -d my-deployment properties
```

### Managing VMs

```bash
# SSH into a VM
bosh -d my-deployment ssh web/0

# Restart a VM
bosh -d my-deployment restart web/0

# Recreate a VM (fresh instance)
bosh -d my-deployment recreate web/0

# Stop a VM
bosh -d my-deployment stop web/0

# Start a VM
bosh -d my-deployment start web/0

# Delete a VM (be careful!)
bosh -d my-deployment delete-vm <vm-cid>
```

### Logs and Debugging

```bash
# Download logs from all VMs
bosh -d my-deployment logs

# Download logs from specific VM
bosh -d my-deployment logs web/0

# Download logs for specific job
bosh -d my-deployment logs web/0 --job=nginx

# Follow logs (tail)
bosh -d my-deployment ssh web/0 -c "sudo tail -f /var/vcap/sys/log/**/*.log"

# View BOSH agent logs
bosh -d my-deployment ssh web/0 -c "sudo tail -f /var/vcap/bosh/log/current"
```

### Running Errands

```bash
# List available errands
bosh -d my-deployment errands

# Run an errand
bosh -d my-deployment run-errand smoke-tests

# Run errand with specific instance
bosh -d my-deployment run-errand backup --instance=database/0

# Download errand logs
bosh -d my-deployment run-errand diagnostics --download-logs
```

### Task Management

```bash
# List recent tasks
bosh tasks

# List all tasks
bosh tasks --all

# View task details
bosh task 123

# View task output
bosh task 123 --debug

# Cancel a running task
bosh cancel-task 123
```

## Advanced Operations

### Cloud Check

Fix deployment issues:

```bash
# Run cloud check (interactive)
bosh -d my-deployment cloud-check

# Auto-resolve problems
bosh -d my-deployment cloud-check --auto

# Report only
bosh -d my-deployment cloud-check --report
```

### Managing Releases

```bash
# List uploaded releases
bosh releases

# Upload a release
bosh upload-release https://bosh.io/d/github.com/cloudfoundry/cf-release

# Delete unused releases
bosh delete-release my-release/1.2.3

# Export a release
bosh -d my-deployment export-release my-release/1.2.3 ubuntu-jammy/1.123
```

### Managing Stemcells

```bash
# List uploaded stemcells
bosh stemcells

# Upload a stemcell
bosh upload-stemcell https://bosh.io/d/stemcells/bosh-aws-xen-hvm-ubuntu-jammy-go_agent

# Delete unused stemcells
bosh delete-stemcell ubuntu-jammy/1.123

# Clean up old stemcells
bosh clean-up --all
```

### Persistent Disks

```bash
# List persistent disks
bosh -d my-deployment disks

# Orphaned disks
bosh disks --orphaned

# Attach orphaned disk
bosh -d my-deployment attach-disk web/0 disk-123456
```

## BOSH and Genesis Integration

### Pre-deployment Checks

Before `genesis deploy`, you might need to:

```bash
# Verify cloud config exists
bosh cloud-config

# Check for required VM types
bosh cloud-config | grep vm_type

# Verify networks
bosh cloud-config | grep -A5 networks

# Check available stemcells
bosh stemcells
```

### During Deployment

Monitor deployment progress:

```bash
# Watch deployment task
genesis deploy my-env
# In another terminal:
bosh task <task-id> --debug

# Monitor VM creation
watch -n 2 'bosh -d my-deployment vms'
```

### Post-deployment Verification

```bash
# Check instance health
bosh -d my-deployment instances --ps

# Verify persistent disks
bosh -d my-deployment disks

# Run smoke tests
bosh -d my-deployment run-errand smoke-tests
```

## Troubleshooting with BOSH

### Common Issues

#### VM Not Starting

```bash
# Check VM vitals
bosh -d my-deployment vms --vitals

# SSH and check logs
bosh -d my-deployment ssh failing-vm
sudo tail -f /var/vcap/sys/log/**/*.log
sudo tail -f /var/vcap/monit/monit.log
```

#### Network Issues

```bash
# Verify VM can reach director
bosh -d my-deployment ssh web/0
curl -k https://$BOSH_ENVIRONMENT:25555/info

# Check network configuration
ip addr
ip route
cat /etc/resolv.conf
```

#### Disk Issues

```bash
# Check disk usage
bosh -d my-deployment ssh database/0
df -h
du -sh /var/vcap/store/*
```

### Recovery Operations

#### Recreate VM with Persistent Disk

```bash
# Stop VM
bosh -d my-deployment stop database/0

# Recreate (keeps persistent disk)
bosh -d my-deployment recreate database/0
```

#### Manual Resurrection

```bash
# Disable resurrection
bosh -d my-deployment update-resurrection off

# Fix issues...

# Re-enable resurrection
bosh -d my-deployment update-resurrection on
```

## Best Practices

### 1. Use Genesis When Possible

- Deploy with `genesis deploy` not `bosh deploy`
- Let Genesis manage manifest generation
- Use Genesis for secrets rotation

### 2. Know When to Use BOSH

- Debugging VM issues
- Emergency recovery
- Advanced operations (recreate, cloud-check)
- Log collection

### 3. Monitor Task Output

```bash
# Always check task output for errors
bosh task <id> --debug | grep -i error
```

### 4. Clean Up Regularly

```bash
# Remove unused releases and stemcells
bosh clean-up --all

# Remove orphaned disks
bosh disks --orphaned
bosh delete-disk <disk-cid>
```

### 5. Document Custom Operations

When you need to use BOSH directly, document:
- What you did
- Why Genesis couldn't handle it
- Any manual steps needed

## Integration Tips

### Shell Aliases

Add to your shell configuration:

```bash
# Quick BOSH access
alias gb='genesis bosh'

# Common operations
bosh-vms() {
  genesis do "$1" -- bosh vms --vitals
}

bosh-ssh() {
  genesis do "$1" -- bosh ssh "$2"
}
```

### Scripting

Automate common tasks:

```bash
#!/bin/bash
# check-deployment.sh
ENV=$1
genesis do "$ENV" -- bash -c '
  echo "=== VMs ==="
  bosh vms --vitals
  echo "=== Disks ==="
  bosh disks
  echo "=== Recent Tasks ==="
  bosh tasks --recent
'
```

Working effectively with BOSH through Genesis requires understanding both tools and knowing when to use each for maximum efficiency.