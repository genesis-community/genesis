# Cloud Config Management

Cloud configuration in BOSH defines IaaS-specific settings that are shared across deployments. This guide covers managing cloud configs for Genesis deployments.

## Overview

Cloud config separates IaaS settings from deployment manifests:
- **Networks**: Subnets, gateways, DNS servers
- **VM Types**: Instance sizes (t2.micro, Standard_DS1_v2, etc.)
- **Disk Types**: Persistent disk configurations
- **Availability Zones**: IaaS-specific zones/regions
- **Compilation**: Workers for package compilation

## Cloud Config Structure

### Basic Structure

```yaml
azs:
- name: z1
  cloud_properties:
    availability_zone: us-east-1a

- name: z2
  cloud_properties:
    availability_zone: us-east-1b

networks:
- name: default
  type: manual
  subnets:
  - range: 10.0.0.0/24
    gateway: 10.0.0.1
    az: z1
    static: [10.0.0.5-10.0.0.50]
    dns: [8.8.8.8, 8.8.4.4]
    cloud_properties:
      subnet: subnet-0123456789abcdef0

vm_types:
- name: small
  cloud_properties:
    instance_type: t3.small
    ephemeral_disk:
      size: 10240
      type: gp3

- name: large
  cloud_properties:
    instance_type: t3.large
    ephemeral_disk:
      size: 32768
      type: gp3

disk_types:
- name: small
  disk_size: 10240
  cloud_properties:
    type: gp3

- name: large
  disk_size: 51200
  cloud_properties:
    type: gp3

compilation:
  workers: 5
  reuse_compilation_vms: true
  az: z1
  vm_type: large
  network: default
```

## Managing Cloud Configs

### Viewing Current Config

```bash
# View current cloud config
bosh cloud-config

# Save to file
bosh cloud-config > cloud-config.yml
```

### Updating Cloud Config

```bash
# Update cloud config
bosh update-cloud-config cloud-config.yml

# Update with variables
bosh update-cloud-config cloud-config.yml \
  -v vpc_id=vpc-12345 \
  -v subnet_id=subnet-67890
```

### Multiple Cloud Configs

BOSH 2.0+ supports multiple named configs:

```bash
# Upload named configs
bosh update-config --type=cloud --name=base base-cloud.yml
bosh update-config --type=cloud --name=aws aws-cloud.yml

# List configs
bosh configs
```

## IaaS-Specific Examples

### AWS Cloud Config

```yaml
azs:
- name: us-east-1a
  cloud_properties:
    availability_zone: us-east-1a

networks:
- name: default
  type: manual
  subnets:
  - range: 10.0.0.0/24
    gateway: 10.0.0.1
    az: us-east-1a
    reserved: [10.0.0.1-10.0.0.5]
    static: [10.0.0.6-10.0.0.50]
    dns: [10.0.0.2]
    cloud_properties:
      subnet: subnet-0123456789abcdef0
      security_groups: [sg-0123456789abcdef0]

vm_types:
- name: small
  cloud_properties:
    instance_type: t3.small
    ephemeral_disk:
      size: 10240
      type: gp3
    security_groups: [bosh-vms]
    iam_instance_profile: bosh-vm-role

disk_types:
- name: default
  disk_size: 10240
  cloud_properties:
    type: gp3
    encrypted: true
    kms_key_id: alias/bosh-disks

vm_extensions:
- name: elb
  cloud_properties:
    elbs: [my-elb]
```

### Azure Cloud Config

```yaml
azs:
- name: z1
  cloud_properties:
    availability_zone: "1"

networks:
- name: default
  type: manual
  subnets:
  - range: 10.0.0.0/24
    gateway: 10.0.0.1
    az: z1
    dns: [168.63.129.16]
    cloud_properties:
      virtual_network_name: bosh-vnet
      subnet_name: bosh-subnet
      resource_group_name: bosh-rg

vm_types:
- name: small
  cloud_properties:
    instance_type: Standard_B2s
    root_disk:
      size: 30720
    ephemeral_disk:
      use_root_disk: false
      size: 10240

disk_types:
- name: default
  disk_size: 10240
  cloud_properties:
    storage_account_type: Standard_LRS
    caching: ReadWrite
```

### vSphere Cloud Config

```yaml
azs:
- name: z1
  cloud_properties:
    datacenters:
    - name: dc1
      clusters:
      - cluster1:
          resource_pool: bosh-rp

networks:
- name: default
  type: manual
  subnets:
  - range: 10.0.0.0/24
    gateway: 10.0.0.1
    az: z1
    dns: [10.0.0.2]
    cloud_properties:
      name: VM Network

vm_types:
- name: small
  cloud_properties:
    cpu: 2
    ram: 2048
    disk: 10240

disk_types:
- name: default
  disk_size: 10240
  cloud_properties:
    type: thin
```

## Genesis Integration

### Validation

Genesis validates cloud config before deployment:

```bash
# Check if cloud config has required resources
genesis check my-env

# Example output:
# Checking cloud config...
# ✓ VM type 'small' exists
# ✓ VM type 'large' exists
# ✓ Network 'default' exists
# ✓ Disk type 'default' exists
```

### Kit Requirements

Kits specify cloud config requirements:

```yaml
# In kit.yml
cloud_config_requirements:
  vm_types:
    - name: small
      minimum_instance_size:
        cpu: 2
        ram: 2048
    - name: large
      minimum_instance_size:
        cpu: 4
        ram: 8192
  
  networks:
    - name: default
      type: manual
  
  disk_types:
    - name: default
      minimum_size: 10240
```

### Environment Overrides

Override cloud config names in environments:

```yaml
# my-env.yml
params:
  # Use different VM types
  vm_type: custom-small
  
  # Use different network
  network: production
  
  # Use different disk type
  persistent_disk_type: fast-ssd
```

## Advanced Features

### VM Extensions

Add cloud properties to specific instance groups:

```yaml
vm_extensions:
- name: load-balancer
  cloud_properties:
    elbs: [web-elb]
    
- name: public-ip
  cloud_properties:
    associate_public_ip_address: true
```

Use in deployment:

```yaml
instance_groups:
- name: web
  vm_type: small
  vm_extensions: [load-balancer, public-ip]
```

### Custom Cloud Properties

Pass IaaS-specific settings:

```yaml
vm_types:
- name: gpu
  cloud_properties:
    instance_type: p3.2xlarge
    placement_group: gpu-cluster
    dedicated_host_id: h-0123456789abcdef0
```

### Compilation Workers

Optimize compilation:

```yaml
compilation:
  workers: 10
  reuse_compilation_vms: true
  az: z1
  vm_type: xlarge  # Fast compilation
  network: compilation  # Dedicated network
  env:
    bosh:
      password: $6$salt$encrypted  # For SSH access
```

## Multi-Cloud Configurations

### Separate Configs by IaaS

```bash
# AWS environments
bosh update-config --type=cloud --name=aws \
  aws-cloud-config.yml

# Azure environments  
bosh update-config --type=cloud --name=azure \
  azure-cloud-config.yml

# vSphere environments
bosh update-config --type=cloud --name=vsphere \
  vsphere-cloud-config.yml
```

### Environment Selection

```yaml
# aws-prod.yml
cloud_config:
  - aws
  - production-overrides

# azure-dev.yml  
cloud_config:
  - azure
  - development-overrides
```

## Best Practices

### 1. Standardize Naming

Use consistent names across environments:

```yaml
vm_types:
- name: small    # 2 CPU, 4GB RAM
- name: medium   # 4 CPU, 8GB RAM  
- name: large    # 8 CPU, 16GB RAM
- name: xlarge   # 16 CPU, 32GB RAM
```

### 2. Document Sizing

Include comments for clarity:

```yaml
vm_types:
- name: web
  # Web servers: 2 CPU, 4GB RAM, 10GB disk
  cloud_properties:
    instance_type: t3.medium
```

### 3. Network Segmentation

Separate networks by purpose:

```yaml
networks:
- name: management  # BOSH directors
- name: data        # Databases
- name: web         # Web-facing
- name: compilation # Compilation only
```

### 4. Reserve IPs

Prevent conflicts:

```yaml
subnets:
- range: 10.0.0.0/24
  reserved:
    - 10.0.0.1-10.0.0.10   # Network devices
    - 10.0.0.100-10.0.0.110 # Future use
  static:
    - 10.0.0.11-10.0.0.99   # Static assignments
```

### 5. Version Control

Track cloud config changes:

```bash
# Before updating
bosh cloud-config > cloud-config-backup-$(date +%Y%m%d).yml

# Commit to git
git add cloud-config.yml
git commit -m "Add new GPU VM types"
```

## Troubleshooting

### Missing Resources

```bash
# Error: Can't find VM type 'large'
# Solution: Check cloud config
bosh cloud-config | grep -A5 "vm_types"

# Add missing type
bosh update-cloud-config updated-cloud.yml
```

### Network Issues

```bash
# Error: No IP available in network 'default'
# Check subnet allocation
bosh cloud-config | grep -A20 "networks"

# Expand static range if needed
```

### Compilation Failures

```bash
# Increase compilation workers
compilation:
  workers: 10  # Increase from 5
  
# Use bigger VMs
  vm_type: xlarge  # Instead of large
```

## Migration Strategies

### Updating Existing Deployments

```bash
# 1. Update cloud config
bosh update-cloud-config new-cloud-config.yml

# 2. Recreate deployments to pick up changes
genesis deploy my-env --recreate

# Or selectively update
bosh -d my-deployment recreate
```

### Renaming Resources

Handle with aliases:

```yaml
vm_types:
- name: small
  cloud_properties:
    instance_type: t3.small
    
- name: default  # Alias for backward compatibility
  cloud_properties:
    instance_type: t3.small
```

Effective cloud config management ensures your Genesis deployments have the proper IaaS resources while maintaining consistency across environments.