# Stemcells and Releases

BOSH uses stemcells and releases as the building blocks for deployments. This guide covers managing these components in Genesis deployments.

## Overview

### Stemcells
- Base operating system images
- IaaS-specific versions
- Security-hardened and minimal
- Regular updates for patches

### Releases
- Packaged software and configurations
- Jobs, packages, and templates
- Version-controlled artifacts
- Compiled or source format

## Working with Stemcells

### Understanding Stemcells

Stemcells follow a naming convention:
```
bosh-[iaas]-[hypervisor]-[os]-[version]

Examples:
bosh-aws-xen-hvm-ubuntu-jammy-go_agent
bosh-azure-hyperv-ubuntu-jammy-go_agent
bosh-vsphere-esxi-ubuntu-jammy-go_agent
```

### Managing Stemcells

```bash
# List uploaded stemcells
bosh stemcells

# Upload a stemcell
bosh upload-stemcell https://bosh.io/d/stemcells/bosh-aws-xen-hvm-ubuntu-jammy-go_agent

# Upload specific version
bosh upload-stemcell https://bosh.io/d/stemcells/bosh-aws-xen-hvm-ubuntu-jammy-go_agent?v=1.123

# Upload from file
bosh upload-stemcell ~/downloads/bosh-stemcell-1.123-aws-xen-hvm-ubuntu-jammy-go_agent.tgz

# Delete a stemcell
bosh delete-stemcell ubuntu-jammy/1.123

# Clean up unused stemcells
bosh clean-up --all
```

### Kit Stemcell Requirements

Genesis kits specify required stemcells:

```yaml
# In kit.yml
stemcells:
  - os: ubuntu-jammy
    version: latest
  - os: ubuntu-bionic
    version: 621.+  # Minimum version
```

Check current kit requirements:

```bash
# View kit metadata
genesis kit-info my-kit

# Example output:
# Stemcells:
#   - ubuntu-jammy (latest)
#   - ubuntu-bionic (621.+)
```

### Stemcell Updates

Keep stemcells current for security:

```bash
# Check for updates
bosh stemcells --recent

# Update procedure
# 1. Upload new stemcell
bosh upload-stemcell https://bosh.io/d/stemcells/bosh-aws-xen-hvm-ubuntu-jammy-go_agent

# 2. Update deployment (Genesis handles manifest update)
genesis deploy my-env

# 3. Clean up old stemcell
bosh clean-up
```

## Working with Releases

### Understanding Releases

BOSH releases contain:
- **Jobs**: Running processes and configurations
- **Packages**: Compiled software and dependencies
- **Source**: Original source code
- **Manifest**: Release metadata

### Managing Releases

```bash
# List uploaded releases
bosh releases

# Upload a release from URL
bosh upload-release https://bosh.io/d/github.com/cloudfoundry/cf-deployment

# Upload specific version
bosh upload-release https://bosh.io/d/github.com/cloudfoundry/cf-deployment?v=16.1.0

# Upload from file
bosh upload-release ~/releases/concourse-7.8.3.tgz

# Delete a release
bosh delete-release concourse/7.8.2

# Clean up unused releases
bosh clean-up --all
```

### Kit Release Management

Genesis kits manage releases automatically:

```yaml
# In kit.yml
releases:
  - name: concourse
    version: 7.8.3
    url: https://bosh.io/d/github.com/concourse/concourse-bosh-release?v=7.8.3
    sha1: abcd1234...
  
  - name: postgres
    version: "43"
    url: https://bosh.io/d/github.com/cloudfoundry/postgres-release?v=43
    sha1: efgh5678...

  - name: bpm
    version: 1.1.21
    url: https://bosh.io/d/github.com/cloudfoundry/bpm-release?v=1.1.21
    sha1: ijkl9012...
```

Genesis handles release uploads during deployment:

```bash
# Genesis automatically uploads required releases
genesis deploy my-env

# Manual release management
genesis do my-env -- upload-releases
```

### Compiled Releases

Use compiled releases for faster deployments:

```bash
# Export compiled release
bosh -d my-deployment export-release concourse/7.8.3 ubuntu-jammy/1.123

# Creates: concourse-7.8.3-ubuntu-jammy-1.123.tgz

# Upload compiled release
bosh upload-release concourse-7.8.3-ubuntu-jammy-1.123.tgz
```

Enable in Genesis:

```yaml
# In environment file
params:
  use_compiled_releases: true
  compiled_release_bucket: my-compiled-releases
```

## Release Development

### Creating Custom Releases

For Genesis kit development:

```bash
# Initialize release
bosh init-release

# Create job
bosh generate-job my-service

# Create package  
bosh generate-package my-app

# Build release
bosh create-release --force

# Upload dev release
bosh upload-release
```

### Local Release Testing

```yaml
# In kit development
releases:
  - name: my-release
    version: latest
    url: file:///home/user/my-release
```

## Advanced Management

### Release Dependencies

Handle transitive dependencies:

```yaml
# Some releases need others
releases:
  - name: routing  # Depends on bpm
    version: 0.213.0
  
  - name: bpm      # Required by routing
    version: 1.1.21
```

### Version Constraints

Specify version requirements:

```yaml
releases:
  - name: concourse
    version: 7.8.+    # Any 7.8.x version
  
  - name: postgres
    version: ">=42"   # Version 42 or higher
    
  - name: garden
    version: 1.19.16  # Exact version
```

### Multi-OS Support

Different stemcells for different jobs:

```yaml
stemcells:
  - alias: default
    os: ubuntu-jammy
    version: latest
    
  - alias: windows
    os: windows2019
    version: latest

instance_groups:
  - name: web
    stemcell: default
    
  - name: mssql
    stemcell: windows
```

## Best Practices

### 1. Regular Updates

Create an update schedule:

```bash
#!/bin/bash
# check-updates.sh

echo "=== Stemcell Updates ==="
bosh stemcells --recent

echo "=== Release Updates ==="
for release in $(bosh releases --json | jq -r '.Tables[0].Rows[].name'); do
  echo "Checking $release..."
  # Check for updates on bosh.io
done
```

### 2. Version Pinning

Pin versions in production:

```yaml
# production.yml
params:
  releases:
    concourse:
      version: 7.8.3  # Explicit version
    postgres:
      version: "43"   # Tested version
      
  stemcell_version: "1.123"  # Specific stemcell
```

### 3. Offline Environments

Prepare for air-gapped deployments:

```bash
# Download all artifacts
mkdir offline-artifacts

# Stemcells
wget https://bosh.io/d/stemcells/bosh-aws-xen-hvm-ubuntu-jammy-go_agent?v=1.123 \
  -O offline-artifacts/stemcell.tgz

# Releases
genesis download-kit-releases my-kit \
  --output-dir offline-artifacts/

# Upload from local files
cd offline-artifacts
bosh upload-stemcell stemcell.tgz
for release in *.tgz; do
  bosh upload-release "$release"
done
```

### 4. Cleanup Strategy

Maintain director health:

```bash
# Automated cleanup script
#!/bin/bash

# Keep last 3 versions of each stemcell
bosh clean-up --all

# Manual cleanup for specific items
bosh stemcells --json | jq -r '.Tables[0].Rows[] | 
  select(.version | tonumber < 120) | 
  "\(.os)/\(.version)"' | 
  xargs -I{} bosh delete-stemcell {} --force
```

### 5. Security Scanning

Verify stemcell security:

```bash
# Extract and scan stemcell
mkdir stemcell-check
cd stemcell-check
tar -xzf ../stemcell.tgz
tar -xzf image

# Run security scans
sudo lynis audit system
sudo chkrootkit
```

## Troubleshooting

### Upload Failures

```bash
# Error: Timed out uploading release
# Solution 1: Use compiled releases
bosh upload-release compiled-release.tgz

# Solution 2: Increase timeout
export BOSH_CLIENT_TIMEOUT=300
bosh upload-release large-release.tgz

# Solution 3: Upload from closer location
# Download first, then upload from jump box
```

### Version Conflicts

```bash
# Error: Release 'X' version 'Y' already exists
# Check current version
bosh releases | grep X

# Force upload if needed (dev only)
bosh upload-release --force

# Or delete and re-upload
bosh delete-release X/Y
bosh upload-release X-Y.tgz
```

### Compilation Issues

```bash
# Error: Failed to compile packages
# Solution: Check compilation VMs
bosh -d my-deployment task <task-id> --debug

# Common fixes:
# 1. Increase compilation VM size
# 2. Check internet access
# 3. Verify dependencies
```

## Integration with CI/CD

### Automated Updates

```yaml
# Concourse pipeline
resources:
- name: stemcell
  type: bosh-io-stemcell
  source:
    name: bosh-aws-xen-hvm-ubuntu-jammy-go_agent

- name: concourse-release
  type: bosh-io-release
  source:
    repository: concourse/concourse-bosh-release

jobs:
- name: update-genesis-deployment
  plan:
  - get: stemcell
    trigger: true
  - get: concourse-release
    trigger: true
  - task: update-manifest
    config:
      platform: linux
      image_resource:
        type: docker-image
        source:
          repository: genesiscommunity/genesis
      run:
        path: bash
        args:
        - -c
        - |
          genesis deploy my-env --yes
```

### Release Notes Tracking

Track what changes between versions:

```bash
# Check release notes
curl -s https://api.github.com/repos/concourse/concourse-bosh-release/releases/latest | \
  jq -r '.body'

# Document in deployment
cat >> deployment-notes.md <<EOF
## $(date +%Y-%m-%d) Update
- Stemcell: ubuntu-jammy/1.123 -> ubuntu-jammy/1.124
  - Security patches: CVE-2023-XXXXX
- Concourse: 7.8.2 -> 7.8.3
  - Bug fixes: [link to release notes]
EOF
```

Managing stemcells and releases effectively ensures your Genesis deployments stay secure, performant, and up-to-date.