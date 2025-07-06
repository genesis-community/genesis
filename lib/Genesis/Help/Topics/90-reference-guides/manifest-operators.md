# Manifest Operators Reference

This document provides a comprehensive reference for Spruce operators used in Genesis manifests. Spruce is the YAML merging tool that powers Genesis's hierarchical configuration system.

## Overview

Spruce operators are special directives enclosed in `(( ))` that perform operations during manifest generation. They enable dynamic values, references, conditionals, and complex data transformations.

## Basic Operators

### grab

Retrieves values from elsewhere in the document.

**Syntax**: `(( grab path.to.value ))`

**Example**:
```yaml
meta:
  domain: example.com

params:
  url: (( grab meta.domain ))
  # Result: url: example.com
```

**With defaults**:
```yaml
params:
  # Use default if not found
  port: (( grab meta.port || 8080 ))
  
  # Multiple fallbacks
  env: (( grab meta.environment || params.env || "development" ))
```

### concat

Concatenates strings or arrays.

**Syntax**: `(( concat arg1 arg2 ... ))`

**String concatenation**:
```yaml
meta:
  domain: example.com
  env: prod

params:
  # Result: "https://prod.example.com"
  url: (( concat "https://" meta.env "." meta.domain ))
  
  # With separator
  fqdn: (( join "." meta.env meta.domain ))
```

**Array concatenation**:
```yaml
base_features:
  - dns
  - ntp

params:
  features: (( concat base_features "[\"monitoring\"]" ))
  # Result: [dns, ntp, monitoring]
```

### vault

Retrieves secrets from Vault.

**Syntax**: `(( vault "path:key" ))`

**Examples**:
```yaml
params:
  # Simple secret
  password: (( vault "secret/prod/admin:password" ))
  
  # With path construction
  api_key: (( vault meta.vault "/api:key" ))
  
  # Using environment variable
  db_pass: (( vault $GENESIS_SECRETS_PATH "/database:password" ))
```

### static_ips

Generates static IPs from network definitions.

**Syntax**: `(( static_ips INTEGER ... ))`

**Example**:
```yaml
networks:
  - name: default
    static: [10.0.0.5 - 10.0.0.100]

instance_groups:
  - name: web
    instances: 3
    networks:
      - name: default
        static_ips: (( static_ips 0 1 2 ))
        # Result: [10.0.0.5, 10.0.0.6, 10.0.0.7]
```

## Reference Operators

### meta

References to the `meta` section (common pattern in Genesis).

```yaml
meta:
  az: [z1, z2, z3]
  network: default

instance_groups:
  - name: web
    azs: (( grab meta.az ))
    networks:
      - name: (( grab meta.network ))
```

### params

References to the `params` section (user parameters).

```yaml
params:
  base_domain: example.com
  instances: 3

instance_groups:
  - name: web
    instances: (( grab params.instances ))
    
properties:
  domain: (( grab params.base_domain ))
```

### self-reference

Reference current level using `.`:

```yaml
server:
  host: example.com
  port: 443
  url: (( concat "https://" .host ":" .port ))
  # Result: "https://example.com:443"
```

## Conditional Operators

### Ternary operator

Conditional selection based on boolean.

**Syntax**: `(( condition ? true_value : false_value ))`

**Examples**:
```yaml
meta:
  production: true

params:
  # Simple conditional
  instances: (( meta.production ? 3 : 1 ))
  
  # Nested conditionals
  vm_type: (( grab meta.scale || "small" == "large" ? "n1-highmem-8" : "n1-standard-2" ))
```

### Logical operators

Boolean operations for conditions.

```yaml
meta:
  ha_enabled: true
  instances: 3

params:
  # AND operator
  use_ha: (( meta.ha_enabled && meta.instances >= 3 ))
  
  # OR operator  
  enable_monitoring: (( grab meta.monitoring || meta.production ))
  
  # NOT operator
  skip_backups: (( !meta.production ))
```

## Array Operators

### join

Joins array elements into a string.

**Syntax**: `(( join SEPARATOR ARRAY ))`

```yaml
meta:
  domains:
    - api
    - www
    - admin

params:
  # Result: "api,www,admin"
  domain_list: (( join "," meta.domains ))
  
  # Result: "api.example.com www.example.com admin.example.com"
  fqdns: (( join " " meta.domains ".example.com" ))
```

### elem

Extracts element from array by index.

**Syntax**: `(( elem INDEX ARRAY ))`

```yaml
meta:
  azs: [us-east-1a, us-east-1b, us-east-1c]

params:
  # Result: "us-east-1b"
  primary_az: (( elem 1 meta.azs ))
```

### append

Appends to arrays (used with merge).

```yaml
# base.yml
features:
  - dns
  - ntp

# overlay.yml
features:
  - (( append ))
  - monitoring
  - logging
# Result: [dns, ntp, monitoring, logging]
```

### replace

Replaces entire structure.

```yaml
# base.yml
databases:
  - name: postgres
    port: 5432

# overlay.yml
databases: (( replace ))
  - name: mysql
    port: 3306
# Result: only mysql, postgres removed
```

### inline

Merges array elements inline.

```yaml
# base.yml
jobs:
  - name: web
    templates: [nginx]

# overlay.yml
jobs:
  - (( inline ))
  - name: web
    templates:
      - (( append ))
      - php-fpm
# Result: web job with [nginx, php-fpm]
```

## Map/Object Operators

### keys

Extracts keys from a map.

**Syntax**: `(( keys MAP ))`

```yaml
services:
  web:
    port: 80
  api:
    port: 8080
  db:
    port: 5432

service_names: (( keys services ))
# Result: [web, api, db]
```

### values  

Extracts values from a map.

**Syntax**: `(( values MAP ))`

```yaml
services:
  web: 80
  api: 8080
  db: 5432

ports: (( values services ))
# Result: [80, 8080, 5432]
```

## String Operators

### base64

Base64 encodes a string.

**Syntax**: `(( base64 STRING ))`

```yaml
params:
  encoded_password: (( base64 "my-secret-password" ))
  # Result: "bXktc2VjcmV0LXBhc3N3b3Jk"
```

### sha1/sha256

Generates hash of string.

```yaml
params:
  password_hash: (( sha256 "password" ))
  file_checksum: (( sha1 meta.file_contents ))
```

### regexp

Regular expression matching and replacement.

**Syntax**: `(( regexp PATTERN REPLACEMENT STRING ))`

```yaml
meta:
  version: "v1.2.3"

params:
  # Remove 'v' prefix
  clean_version: (( regexp "^v" "" meta.version ))
  # Result: "1.2.3"
  
  # Extract major version
  major: (( regexp "^v?([0-9]+)\\..*" "$1" meta.version ))
  # Result: "1"
```

## Special Operators

### inject

Injects sub-documents.

**Syntax**: `(( inject FILE ))`

```yaml
# main.yml
base_config: (( inject "configs/base.yml" ))

overrides:
  <<: (( inject "configs/overrides.yml" ))
```

### file

Reads file contents as string.

**Syntax**: `(( file PATH ))`

```yaml
params:
  certificate: (( file "certs/server.crt" ))
  config_data: (( file "/etc/app/config.json" ))
```

### env

Accesses environment variables.

**Syntax**: `(( env "VARIABLE" ))`

```yaml
params:
  home_dir: (( env "HOME" ))
  deployment: (( env "GENESIS_ENVIRONMENT" ))
  
  # With default
  log_level: (( env "LOG_LEVEL" || "info" ))
```

### null

Represents null/nil value.

```yaml
params:
  # Remove inherited value
  unwanted_param: (( null ))
  
  # Conditional null
  optional: (( meta.enabled ? meta.value : null ))
```

## Advanced Patterns

### Pipeline Operations

Chain multiple operations:

```yaml
meta:
  raw_domains:
    - "  api.example.com  "
    - "  www.example.com  "

params:
  # Trim whitespace and join
  domains: (( join "," ( map regexp "^\\s+|\\s+$" "" meta.raw_domains ) ))
```

### Complex Conditionals

Multi-condition logic:

```yaml
meta:
  env: production
  region: us-east
  ha_enabled: true

params:
  instances: ((
    meta.env == "production" && meta.ha_enabled ? 5 :
    meta.env == "production" ? 3 :
    meta.env == "staging" ? 2 :
    1
  ))
```

### Dynamic Key Names

Generate keys dynamically:

```yaml
meta:
  env: prod
  region: us-east-1

params:
  (( concat meta.env "-config" )):
    region: (( grab meta.region ))
  # Result: prod-config: { region: us-east-1 }
```

### Nested Grabs

Navigate complex structures:

```yaml
meta:
  environments:
    prod:
      us-east:
        instances: 5
      us-west:
        instances: 3

params:
  count: (( grab meta.environments.prod.us-east.instances ))
```

## Error Handling

### Default Values

Always provide defaults for optional values:

```yaml
params:
  # Single default
  port: (( grab meta.port || 8080 ))
  
  # Chain of defaults
  environment: (( grab meta.env || params.env || "development" ))
  
  # Complex default
  config: (( grab meta.config || { "timeout": 30, "retries": 3 } ))
```

### Type Safety

Ensure correct types in operations:

```yaml
# BAD: May cause type errors
total: (( grab meta.count + 1 ))

# GOOD: Ensure numeric default
total: (( ( grab meta.count || 0 ) + 1 ))
```

### Existence Checks

Check before using:

```yaml
# Only add if exists
features: ((
  has meta.optional_feature ?
  concat base_features "[\"" meta.optional_feature "\"]" :
  base_features
))
```

## Best Practices

### 1. Use Descriptive Paths

```yaml
# BAD
value: (( grab m.d ))

# GOOD  
value: (( grab meta.deployment.domain ))
```

### 2. Provide Meaningful Defaults

```yaml
# BAD
port: (( grab params.port || 0 ))

# GOOD
port: (( grab params.port || 8080 ))  # Default HTTP port
```

### 3. Group Related Operations

```yaml
meta:
  # Group related calculations
  sizing:
    base_instances: 3
    ha_multiplier: (( grab params.ha_enabled ? 3 : 1 ))
    total_instances: (( meta.sizing.base_instances * meta.sizing.ha_multiplier ))
```

### 4. Document Complex Operations

```yaml
params:
  # Calculate required IPs: instances + 2 (for load balancers)
  # Must account for multiple AZs in HA mode
  required_ips: ((
    ( grab params.instances || 1 ) +
    2 +
    ( grab params.ha_enabled ? length(meta.azs) : 0 )
  ))
```

### 5. Avoid Deep Nesting

```yaml
# BAD: Hard to read and maintain
value: (( grab meta.config.services.web.endpoints.primary.port || grab meta.defaults.services.web.port || 80 ))

# GOOD: Use intermediate values
meta:
  web_config: (( grab meta.config.services.web || {} ))
  web_endpoint: (( grab meta.web_config.endpoints.primary || {} ))
  
params:
  web_port: (( grab meta.web_endpoint.port || 80 ))
```

## Common Pitfalls

### 1. Circular References

```yaml
# BAD: Causes infinite loop
a: (( grab b ))
b: (( grab a ))
```

### 2. Type Mismatches

```yaml
# BAD: Concatenating different types
result: (( concat meta.string meta.number ))

# GOOD: Convert to string first
result: (( concat meta.string ( string meta.number ) ))
```

### 3. Missing Defaults

```yaml
# BAD: Fails if meta.value not present
calculation: (( grab meta.value * 2 ))

# GOOD: Provide default
calculation: (( ( grab meta.value || 1 ) * 2 ))
```

Understanding Spruce operators is essential for creating flexible and maintainable Genesis deployments. These operators provide the power to create sophisticated configuration templates while maintaining clarity and reusability.