# Configuration Merging

Genesis uses a powerful hierarchical merging system to manage configuration across environments. This guide explains how configurations are merged, override rules, and best practices.

## How Merging Works

Genesis merges configuration files in a specific order, with later values overriding earlier ones. This allows you to define common settings once and override them where needed.

### Merge Order

For an environment named `acme-aws-us-east-1-prod.yml`, Genesis merges in this order:

1. Kit base manifest
2. Kit features (ops files)
3. `acme.yml`
4. `acme-aws.yml`
5. `acme-aws-us.yml`
6. `acme-aws-us-east.yml`
7. `acme-aws-us-east-1.yml`
8. `acme-aws-us-east-1-prod.yml`
9. Any files from `genesis.inherits`

### Basic Override Example

```yaml
# acme.yml
params:
  company: ACME Corp
  instances: 1
  enable_monitoring: true

# acme-aws.yml
params:
  cloud: aws
  instances: 2  # Overrides acme.yml

# acme-aws-us-east-1-prod.yml
params:
  env: production
  instances: 5  # Overrides both previous files
```

Final result:
```yaml
params:
  company: ACME Corp      # From acme.yml
  enable_monitoring: true # From acme.yml
  cloud: aws             # From acme-aws.yml
  env: production        # From acme-aws-us-east-1-prod.yml
  instances: 5           # From acme-aws-us-east-1-prod.yml (last wins)
```

## Merge Types

### Simple Values

Later values completely replace earlier ones:

```yaml
# parent.yml
params:
  port: 8080
  
# child.yml
params:
  port: 443  # Replaces 8080
```

### Arrays

Arrays are replaced, not merged:

```yaml
# parent.yml
params:
  availability_zones:
    - us-east-1a
    - us-east-1b

# child.yml
params:
  availability_zones:
    - us-east-1c  # Only us-east-1c remains
```

To append to arrays, you must include all values:

```yaml
# child.yml
params:
  availability_zones:
    - us-east-1a  # Include original values
    - us-east-1b
    - us-east-1c  # Add new value
```

### Maps (Hashes)

Maps are deep-merged:

```yaml
# parent.yml
params:
  database:
    host: localhost
    port: 5432
    pool: 10

# child.yml
params:
  database:
    host: prod-db.example.com  # Overrides
    ssl: true                  # Adds new key
    # port: 5432 (inherited)
    # pool: 10 (inherited)
```

Result:
```yaml
params:
  database:
    host: prod-db.example.com
    port: 5432
    pool: 10
    ssl: true
```

## Special Merge Keys

### The `(( merge ))` Operator

While Genesis doesn't use Spruce operators during environment file merging, understanding this pattern helps when working with ops files:

```yaml
# In ops files or kit manifests
meta:
  things: (( merge ))  # Indicates this should be merged
```

### Null Values

Use `null` to remove inherited values:

```yaml
# parent.yml
params:
  debug_mode: true
  log_level: debug

# production.yml
params:
  debug_mode: false
  log_level: null  # Removes this key entirely
```

## Complex Merging Examples

### Network Configuration

```yaml
# base.yml
params:
  networks:
    default:
      dns:
        - 8.8.8.8
        - 8.8.4.4
      mtu: 1500

# aws.yml
params:
  networks:
    default:
      dns:
        - 10.0.0.2    # Replaces public DNS
        - 10.0.0.3
      type: manual
      # mtu: 1500 (inherited)

# aws-us-east-1-prod.yml
params:
  networks:
    default:
      subnets:
        - range: 10.0.1.0/24
          gateway: 10.0.1.1
      # dns inherited from aws.yml
      # type inherited from aws.yml
      # mtu inherited from base.yml
```

### Feature Flags

```yaml
# base.yml
params:
  features:
    monitoring: enabled
    backups: enabled
    debug: disabled

# dev.yml
params:
  features:
    debug: enabled      # Override for dev
    test_mode: enabled  # Add new feature
    # monitoring: enabled (inherited)
    # backups: enabled (inherited)
```

## Using genesis.inherits

For non-hierarchical inheritance:

```yaml
# special-security.yml
params:
  security:
    require_https: true
    min_tls_version: "1.2"

# aws-us-east-1-prod.yml
genesis:
  inherits:
    - special-security  # Merged after hierarchical files
params:
  env: production
```

### Multiple Inherits

```yaml
genesis:
  inherits:
    - base-networking    # First
    - security-policies  # Second
    - performance-tuning # Third (wins conflicts)
```

## Best Practices

### 1. Design for Inheritance

Structure your configurations to minimize overrides:

```yaml
# Good: Use specific keys
params:
  cell_instances: 3
  router_instances: 2
  
# Bad: Generic names cause conflicts
params:
  instances: 3  # Which component?
```

### 2. Document Inheritance

Add comments explaining inheritance:

```yaml
# aws-us-east-1-prod.yml
params:
  # Inherits from: base.yml -> aws.yml -> aws-us-east-1.yml
  instances: 5  # Override: was 2 in aws.yml
```

### 3. Use Intermediate Files

Create logical groupings:

```yaml
# aws-networking.yml - Shared AWS network config
params:
  networks:
    default:
      type: manual
      dns: ["10.0.0.2"]

# aws-security.yml - Shared AWS security
params:
  security_groups:
    - default
    - bosh
```

### 4. Avoid Deep Nesting

Flatten when possible:

```yaml
# Good
params:
  database_host: prod-db.example.com
  database_port: 5432
  
# Harder to override
params:
  database:
    connection:
      host: prod-db.example.com
      port: 5432
```

## Debugging Merge Issues

### View Effective Configuration

```bash
# See what values an environment will use
genesis describe aws-us-east-1-prod

# View the final manifest
genesis manifest aws-us-east-1-prod
```

### Check Inheritance Chain

```bash
# List all files in merge order
genesis describe aws-us-east-1-prod --show-hierarchy
```

### Common Issues

#### Values Not Overriding

Check:
- Correct key names (typos prevent overrides)
- Proper YAML indentation
- File naming follows hierarchy

#### Unexpected Array Behavior

Remember arrays replace entirely:
```yaml
# Wrong: Expecting append
child:
  my_array:
    - new_value  # Old values lost!

# Right: Include all values
child:
  my_array:
    - old_value_1
    - old_value_2
    - new_value
```

#### Missing Inherited Values

Verify:
- Parent file exists
- No `null` assignments
- Correct merge order

## Advanced Patterns

### Environment-Specific Overrides

```yaml
# base.yml
params:
  log_level: (( grab params.environment_log_level || "info" ))

# dev.yml
params:
  environment_log_level: debug

# prod.yml
params:
  environment_log_level: error
```

### Conditional Features

```yaml
# base.yml
params:
  enable_feature_x: false

# staging.yml
params:
  enable_feature_x: true  # Test in staging first
```

### Shared Configurations

```yaml
# tls-config.yml
params:
  tls:
    certificate: |
      -----BEGIN CERTIFICATE-----
      ...
    protocols:
      - TLSv1.2
      - TLSv1.3

# Multiple environments inherit
genesis:
  inherits:
    - tls-config
```

## Summary

- Genesis merges hierarchically based on environment name
- Later files override earlier files
- Simple values replace, maps deep-merge, arrays replace entirely
- Use `genesis.inherits` for non-hierarchical inclusion
- Design configurations for inheritance from the start
- Test with `genesis describe` and `genesis manifest`