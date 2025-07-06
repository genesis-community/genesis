# Runtime Configs Reference

This document provides a comprehensive reference for specifying and managing BOSH runtime configurations in Genesis environment files.

## Overview

Runtime configs are BOSH configurations that apply to all deployments on a BOSH director. Genesis kits can provide runtime config hooks that generate these configurations based on your environment settings, allowing you to standardize operational concerns across all deployments.

## Configuration Location

Runtime config options are specified under the `bosh-configs` top-level key in your environment file:

```yaml
# my-env.yml
bosh-configs:
  runtime:
    # Runtime config specifications
```

## Specification Formats

Genesis supports multiple formats for specifying runtime configs, from simple boolean flags to complex configurations with options.

### 1. Boolean Format

Enable all available runtime configs with default options:

```yaml
bosh-configs:
  runtime: true
```

This enables all runtime configs defined by the kit with their default settings.

### 2. String Format (Single Config)

Request a specific runtime config by name:

```yaml
bosh-configs:
  runtime: "dns"
```

Only the specified runtime config will be generated.

### 3. Comma-Separated String (Multiple Configs)

Request multiple runtime configs in a single string:

```yaml
bosh-configs:
  runtime: "dns,toolbelt,monitoring"
```

Each named config will be generated with default options.

### 4. Array Format

List multiple runtime configs using YAML array syntax:

```yaml
bosh-configs:
  runtime:
    - dns
    - toolbelt
    - monitoring
    - security
```

### 5. Hash Format (Configs with Options)

Specify runtime configs with custom options:

```yaml
bosh-configs:
  runtime:
    dns: 
      timeout: 30
      retries: 3
      cache_size: 1000
    security:
      enforce_tls: true
      audit_logging: enabled
    monitoring: true  # Use defaults
    toolbelt:
      packages:
        - htop
        - tmux
        - vim
```

### 6. Mixed Configurations

Combine different specification methods for flexibility:

```yaml
bosh-configs:
  runtime:
    # Apply shared options to all configs
    "*":
      environment: production
      region: us-east-1
    
    # Config-specific options
    dns:
      timeout: 30
      upstream_dns:
        - 8.8.8.8
        - 8.8.4.4
    
    # Exclude specific config
    legacy: false
    
    # Enable with defaults
    monitoring: true
```

## Advanced Configuration

### Wildcard Selection

Use `*` to apply options to all available runtime configs:

```yaml
bosh-configs:
  runtime:
    "*":
      environment: production
      datacenter: us-east-1
      contact: ops-team@example.com
```

### Excluding Configs

Explicitly exclude specific runtime configs:

```yaml
bosh-configs:
  runtime:
    "*": true        # Enable all configs
    legacy: false    # Except legacy
    experimental: false  # And experimental
```

When only exclusions are specified, all other configs are enabled by default:

```yaml
bosh-configs:
  runtime:
    # All configs enabled except these
    legacy: false
    deprecated: false
```

### Grouped Configuration

Apply shared options to multiple configs:

```yaml
bosh-configs:
  runtime:
    # Group configs with comma-separated names
    "dns,security,monitoring":
      environment: production
      log_level: info
    
    # Additional config-specific options
    dns:
      cache_size: 2000
    security:
      strict_mode: true
```

## Common Runtime Config Types

### DNS Configuration

Modern BOSH DNS setup:

```yaml
bosh-configs:
  runtime:
    dns:
      # DNS-specific options
      cache:
        enabled: true
        max_entries: 10000
      health_check:
        enabled: true
        interval: 30
      handlers:
        - domain: consul.local
          forward: 10.0.0.10
```

### Monitoring Configuration

Prometheus node exporter and monitoring agents:

```yaml
bosh-configs:
  runtime:
    monitoring:
      node_exporter:
        enabled: true
        port: 9100
        collectors:
          - cpu
          - memory
          - disk
          - network
      telegraf:
        enabled: true
        outputs:
          - influxdb: "http://metrics.example.com:8086"
```

### Security Configuration

OS hardening and security tools:

```yaml
bosh-configs:
  runtime:
    security:
      sysctl:
        kernel_hardening: true
        network_hardening: true
      login_banner:
        enabled: true
        text: |
          AUTHORIZED ACCESS ONLY
          All activity is monitored
      fail2ban:
        enabled: true
        max_retries: 3
```

### Toolbelt Configuration

Development and debugging tools:

```yaml
bosh-configs:
  runtime:
    toolbelt:
      packages:
        - vim
        - tmux
        - htop
        - tcpdump
        - strace
      custom_scripts:
        enabled: true
        path: /var/vcap/toolbelt/scripts
```

### Logging Configuration

Centralized logging setup:

```yaml
bosh-configs:
  runtime:
    logging:
      syslog:
        enabled: true
        address: syslog.example.com
        port: 514
        protocol: tcp
        tls:
          enabled: true
          verify: true
      format: rfc5424
      include_audit_logs: true
```

## Kit Integration

### Kit-Defined Runtime Configs

Kits define available runtime configs in their metadata:

```yaml
# kit.yml
runtime_configs:
  - name: dns
    description: "BOSH DNS configuration"
    default: true
  - name: monitoring
    description: "Prometheus monitoring agents"
    default: false
  - name: security
    description: "OS hardening and security policies"
    default: true
```

### Runtime Config Hooks

Kits implement runtime config generation through hooks:

```bash
# hooks/runtime-config
#!/bin/bash
set -eu

config_type=$1
shift

case "$config_type" in
  dns)
    generate_dns_runtime_config "$@"
    ;;
  monitoring)
    generate_monitoring_runtime_config "$@"
    ;;
  security)
    generate_security_runtime_config "$@"
    ;;
  *)
    echo >&2 "Unknown runtime config: $config_type"
    exit 1
    ;;
esac
```

## Environment-Specific Overrides

### Development Environment

Minimal runtime configs for development:

```yaml
# dev.yml
bosh-configs:
  runtime:
    dns: true  # Only DNS
    # All others disabled by default
```

### Production Environment

Full runtime configs with strict settings:

```yaml
# prod.yml
bosh-configs:
  runtime:
    "*":
      environment: production
      alert_email: ops@example.com
    dns:
      cache_size: 50000
      strict_mode: true
    security:
      enforce_tls: true
      audit_all: true
      compliance_mode: pci
    monitoring:
      retention: 90d
      high_frequency: true
    logging:
      archive: true
      compress: true
```

## Best Practices

### 1. Hierarchical Configuration

Use environment hierarchy for runtime configs:

```yaml
# base.yml - Shared configs
bosh-configs:
  runtime:
    dns: true
    monitoring: true

# prod.yml - Production additions
bosh-configs:
  runtime:
    security:
      strict_mode: true
    logging:
      archive: true
```

### 2. Document Options

Include comments explaining options:

```yaml
bosh-configs:
  runtime:
    dns:
      # Increased cache for high-traffic environment
      cache_size: 50000
      
      # Custom upstream for internal domains
      handlers:
        - domain: internal.company.com
          forward: 10.0.0.100
```

### 3. Validate Compatibility

Ensure runtime configs are compatible:

```yaml
bosh-configs:
  runtime:
    # These work together
    monitoring: true
    logging: true
    
    # But not with this (example)
    legacy_monitoring: false
```

### 4. Use Defaults Wisely

Leverage kit defaults when appropriate:

```yaml
bosh-configs:
  runtime:
    # Use all kit defaults
    "*": true
    
    # Except customize DNS
    dns:
      cache_size: 20000
```

## Troubleshooting

### Runtime Config Not Applied

Check if config is generated:

```bash
# List runtime configs
genesis do my-env -- list-runtime-configs

# View generated config
genesis do my-env -- runtime-config dns
```

### Option Not Recognized

Runtime config hooks should gracefully handle unknown options:

```yaml
bosh-configs:
  runtime:
    dns:
      unknown_option: value  # Should be ignored, not error
```

### Conflicts Between Configs

Some runtime configs may conflict:

```yaml
bosh-configs:
  runtime:
    # Error: Both provide syslog forwarding
    logging: true
    legacy_syslog: true
```

## Migration Examples

### From Manual Runtime Configs

Migrating from manually managed runtime configs:

```bash
# Export current runtime config
bosh runtime-config > current-runtime.yml

# Analyze and map to Genesis options
# Add to environment file:
bosh-configs:
  runtime:
    dns:
      # Options matching current-runtime.yml
```

### Upgrading Runtime Configs

When upgrading kits with new runtime configs:

```yaml
# Before upgrade - explicit list
bosh-configs:
  runtime:
    - dns
    - monitoring

# After upgrade - use new configs
bosh-configs:
  runtime:
    - dns
    - monitoring
    - security  # New in kit v2.0
```

## Complete Example

Comprehensive runtime config setup:

```yaml
# production.yml
genesis:
  env: production

bosh-configs:
  runtime:
    # Global options for all configs
    "*":
      environment: production
      region: us-east-1
      owner: platform-team
    
    # DNS with production settings
    dns:
      cache:
        enabled: true
        size: 100000
        ttl: 300
      recursors:
        - 8.8.8.8
        - 8.8.4.4
      handlers:
        - domain: consul.service.consul
          forward: 127.0.0.1:8600
        - domain: internal.company.com
          forward: 10.0.0.53
    
    # Comprehensive monitoring
    monitoring:
      node_exporter:
        enabled: true
        port: 9100
      prometheus:
        scrape_interval: 15s
        external_labels:
          environment: production
          region: us-east-1
      telegraf:
        enabled: true
        interval: 10s
        outputs:
          - influxdb: "https://metrics.company.com:8086"
    
    # Strict security settings
    security:
      os_hardening:
        kernel: true
        network: true
        filesystem: true
      compliance:
        mode: pci-dss
        audit_level: detailed
      tls:
        min_version: "1.2"
        cipher_suites: modern
    
    # Centralized logging
    logging:
      syslog:
        address: syslog-aggregator.company.com
        port: 6514
        protocol: tcp
        tls:
          enabled: true
          verify: true
      format: json
      buffer_size: 65536
      include:
        - system
        - audit
        - application
    
    # Exclude development tools
    toolbelt: false
```

## Future Enhancements

### Cross-Kit Runtime Configs

Future versions may support specifying runtime configs from other kits:

```yaml
bosh-configs:
  runtime:
    # From BOSH kit
    dns: true
    
    # From Shield kit
    "shield/backup-agent":
      schedule: "0 2 * * *"
    
    # From Prometheus kit  
    "prometheus/exporters":
      - node
      - process
      - postgres
```

### Runtime Config Dependencies

Automatic dependency resolution:

```yaml
bosh-configs:
  runtime:
    monitoring: true  # Automatically enables dns if required
```

### Conditional Runtime Configs

Environment-aware configurations:

```yaml
bosh-configs:
  runtime:
    monitoring:
      enabled: (( grab meta.monitoring_enabled || false ))
      endpoint: (( concat "https://prometheus." params.base_domain ":9090" ))
```

Runtime configurations provide powerful cross-cutting functionality for all deployments while maintaining flexibility through Genesis's configuration system.