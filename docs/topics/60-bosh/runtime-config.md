# Runtime Config Management

Runtime configurations in BOSH apply settings across all deployments on a director. This guide covers managing runtime configs with Genesis.

## Overview

Runtime configs provide:
- **Cross-cutting concerns**: DNS, syslog, monitoring agents
- **Security policies**: OS hardening, compliance tools
- **Operational tools**: Debugging utilities, backup agents
- **Network policies**: MTU settings, custom routes

## Runtime Config Structure

### Basic Structure

```yaml
releases:
- name: os-conf
  version: 22.1.0

addons:
- name: os-configuration
  jobs:
  - name: sysctl
    release: os-conf
    properties:
      sysctl:
        kernel.panic: 10
        net.ipv4.tcp_syncookies: 1
  include:
    deployments: [all]

- name: dns
  jobs:
  - name: bosh-dns
    release: bosh-dns
    properties:
      cache:
        enabled: true
      api:
        server:
          tls: ((/dns_api_server_tls))
```

## Common Runtime Configs

### DNS Configuration

Modern BOSH DNS setup:

```yaml
releases:
- name: bosh-dns
  version: 1.36.0

addons:
- name: bosh-dns
  jobs:
  - name: bosh-dns
    release: bosh-dns
    properties:
      cache:
        enabled: true
        max_entries: 10000
      health:
        enabled: true
        server:
          tls: ((/dns_healthcheck_server_tls))
      api:
        server:
          tls: ((/dns_api_server_tls))
  include:
    deployments: [all]
```

### Syslog Forwarding

Centralized logging:

```yaml
releases:
- name: syslog
  version: 11.7.0

addons:
- name: syslog-forwarder
  jobs:
  - name: syslog_forwarder
    release: syslog
    properties:
      syslog:
        address: syslog.example.com
        port: 514
        transport: tcp
        tls:
          enabled: true
          ca_cert: |
            -----BEGIN CERTIFICATE-----
            ...
            -----END CERTIFICATE-----
  include:
    deployments: [all]
  exclude:
    deployments: [bosh]  # Don't forward BOSH's own logs
```

### Monitoring Agents

Prometheus node exporter:

```yaml
releases:
- name: node-exporter
  version: 4.2.0

addons:
- name: node-exporter
  jobs:
  - name: node_exporter
    release: node-exporter
    properties:
      node_exporter:
        collectors:
          - cpu
          - diskstats
          - filesystem
          - loadavg
          - meminfo
          - netstat
          - time
          - vmstat
  include:
    deployments: [all]
```

### OS Hardening

Security baseline:

```yaml
releases:
- name: os-conf
  version: 22.1.0

addons:
- name: os-hardening
  jobs:
  - name: sysctl
    release: os-conf
    properties:
      sysctl:
        # Kernel hardening
        kernel.randomize_va_space: 2
        kernel.exec-shield: 1
        
        # Network hardening
        net.ipv4.conf.all.accept_source_route: 0
        net.ipv4.conf.all.accept_redirects: 0
        net.ipv4.conf.all.send_redirects: 0
        net.ipv4.conf.all.log_martians: 1
        net.ipv4.tcp_syncookies: 1
        
        # Disable IPv6 if not used
        net.ipv6.conf.all.disable_ipv6: 1
        
  - name: login_banner
    release: os-conf
    properties:
      login_banner:
        text: |
          UNAUTHORIZED ACCESS TO THIS DEVICE IS PROHIBITED
          All activities performed on this device are logged.
  include:
    deployments: [all]
```

## Managing Runtime Configs

### Viewing Runtime Configs

```bash
# View current runtime config
bosh runtime-config

# List all runtime configs
bosh configs --type=runtime

# View specific named config
bosh config --type=runtime --name=dns
```

### Updating Runtime Configs

```bash
# Update default runtime config
bosh update-runtime-config runtime.yml

# Update named runtime config
bosh update-config --type=runtime --name=dns dns-runtime.yml

# Update with variables
bosh update-runtime-config runtime.yml \
  -v syslog_address=10.0.0.100
```

### Multiple Runtime Configs

Layer configs for different purposes:

```bash
# Base OS configuration
bosh update-config --type=runtime --name=os-baseline \
  os-baseline.yml

# Monitoring agents
bosh update-config --type=runtime --name=monitoring \
  monitoring.yml

# Security tools
bosh update-config --type=runtime --name=security \
  security.yml
```

## Genesis Integration

### Kit-Provided Runtime Configs

Some kits include runtime configs:

```yaml
# In kit.yml
runtime_configs:
  - name: dns
    file: runtime-configs/dns.yml
  - name: syslog
    file: runtime-configs/syslog.yml
```

Apply them:

```bash
# Apply kit runtime configs
genesis do my-env -- apply-runtime-configs
```

### Environment-Specific Configs

Override for specific environments:

```yaml
# production.yml
params:
  runtime_config_overrides:
    syslog_address: prod-syslog.example.com
    monitoring_enabled: true
```

## Advanced Usage

### Conditional Inclusion

Target specific deployments:

```yaml
addons:
- name: debug-tools
  jobs:
  - name: toolbelt
    release: toolbelt
  include:
    deployments: 
      - /.*-dev$/    # Dev deployments only
      - /.*-staging$/ # Staging deployments
  exclude:
    deployments:
      - /.*-prod$/   # Not in production

- name: production-monitoring
  jobs:
  - name: enhanced-monitoring
    release: monitoring
  include:
    deployments:
      - /.*-prod$/   # Production only
```

### Instance Group Targeting

Apply to specific instance groups:

```yaml
addons:
- name: database-tools
  jobs:
  - name: db-backup-agent
    release: backup-tools
  include:
    instance_groups:
      - database
      - mysql
      - postgres

- name: web-monitoring
  jobs:
  - name: nginx-exporter
    release: prometheus-exporters
  include:
    instance_groups:
      - web
      - api
      - router
```

### Job Placement

Control where jobs run:

```yaml
addons:
- name: colocated-dns
  placement:
    include:
      - colocated: true  # Only on VMs with other jobs
  jobs:
  - name: bosh-dns
    release: bosh-dns

- name: dedicated-monitoring
  placement:
    exclude:
      - colocated: true  # Only on dedicated VMs
  jobs:
  - name: telegraf
    release: telegraf
```

## Best Practices

### 1. Layered Configuration

Organize configs by concern:

```bash
# Structure
runtime-configs/
├── 01-os-baseline.yml      # OS settings
├── 02-dns.yml              # DNS configuration
├── 03-monitoring.yml       # Monitoring agents
├── 04-security.yml         # Security tools
└── 05-logging.yml          # Log forwarding
```

### 2. Version Control

Track all runtime configs:

```bash
# Before updating
bosh runtime-config > backup/runtime-$(date +%Y%m%d).yml

# After updating
git add runtime-configs/
git commit -m "Enable TLS for syslog forwarding"
```

### 3. Test in Non-Production

```bash
# Test in dev first
bosh -e dev-bosh update-runtime-config new-runtime.yml

# Verify with deployment
bosh -d test-deployment recreate

# Then apply to production
bosh -e prod-bosh update-runtime-config new-runtime.yml
```

### 4. Document Dependencies

```yaml
# monitoring.yml
# Dependencies:
# - Prometheus server at prometheus.example.com:9090
# - Grafana dashboards: https://grafana.example.com
# - Alert manager: https://alerts.example.com

releases:
- name: node-exporter
  version: 4.2.0
  # Download: bosh upload-release https://bosh.io/d/github.com/cloudfoundry-community/node-exporter-boshrelease
```

### 5. Monitor Impact

Check runtime config effects:

```bash
# Check addon resource usage
bosh -d my-deployment ssh web/0
ps aux | grep node_exporter
df -h  # Check disk usage

# Verify functionality
curl localhost:9100/metrics  # Node exporter
```

## Common Patterns

### Multi-Site Configuration

Different configs per site:

```yaml
# us-east runtime config
addons:
- name: dns
  jobs:
  - name: bosh-dns
    properties:
      handlers:
      - domain: east.example.com
        forward: 10.1.0.2

# us-west runtime config  
addons:
- name: dns
  jobs:
  - name: bosh-dns
    properties:
      handlers:
      - domain: west.example.com
        forward: 10.2.0.2
```

### Progressive Rollout

Test new configs gradually:

```yaml
# Phase 1: Dev only
include:
  deployments: [/.*-dev$/]

# Phase 2: Dev + Staging
include:
  deployments: [/.*-(dev|staging)$/]

# Phase 3: All environments
include:
  deployments: [all]
```

## Troubleshooting

### Addon Not Applied

```bash
# Check if addon matches
bosh -d my-deployment manifest | grep -A20 addons

# Verify inclusion rules
# Does deployment name match?
# Is instance group included?
```

### Conflicts with Deployment

```bash
# Error: Job 'syslog_forwarder' already exists
# Solution: Check deployment manifest
bosh -d my-deployment manifest | grep syslog_forwarder

# Remove from deployment or runtime config
```

### Performance Impact

```bash
# Too many addons slowing deployments
# Solution: Consolidate addons
addons:
- name: monitoring-suite  # Combine multiple agents
  jobs:
  - name: node_exporter
  - name: process_exporter
  - name: postgres_exporter
```

## Migration Strategies

### From Deployment to Runtime

Move common jobs to runtime config:

```bash
# 1. Identify common jobs across deployments
for d in $(bosh deployments --json | jq -r '.Tables[0].Rows[].name'); do
  echo "=== $d ==="
  bosh -d $d manifest | grep -A5 "jobs:" | grep "name:"
done

# 2. Create runtime config
# 3. Remove from deployment manifests
# 4. Apply runtime config
# 5. Update deployments
```

### Updating Releases

Safely update runtime releases:

```bash
# 1. Upload new release
bosh upload-release new-release.tgz

# 2. Update runtime config with new version
bosh update-runtime-config updated-runtime.yml

# 3. Recreate deployments to pick up changes
# Option 1: All at once
for d in $(bosh deployments --json | jq -r '.Tables[0].Rows[].name'); do
  bosh -d $d recreate
done

# Option 2: Canary approach
bosh -d canary-deployment recreate
# Verify...
bosh -d production-deployment recreate
```

Runtime configs provide powerful cross-cutting functionality for all Genesis deployments while maintaining separation of concerns.