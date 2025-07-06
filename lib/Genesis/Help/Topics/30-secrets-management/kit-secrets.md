# Kit Secrets Definition

This guide explains how to define secrets in Genesis kit.yml files. Kit authors use these definitions to specify what secrets their deployments need.

## Overview

Kits define secrets in three main sections of `kit.yml`:

1. **credentials** - Passwords, keys, and other generated secrets
2. **certificates** - X.509 certificates and CAs
3. **provided** - User-supplied secrets

## Credentials Section

### Basic Structure

```yaml
credentials:
  <feature>:
    <path>: <definition>
```

### Simple Credentials

```yaml
credentials:
  base:
    # Simple password
    admin_password: random 32
    
    # Password with options
    db/password: "random 64 fmt base64"
    
    # SSH key
    jumpbox/ssh: ssh 2048
    
    # RSA key
    jwt/signing_key: rsa 4096
    
    # UUID
    consul/gossip: uuid
```

### Complex Credentials

For secrets with multiple components:

```yaml
credentials:
  base:
    # Multiple keys under one path
    nats:
      username: nats
      password: random 32
    
    # Nested structure
    db/admin:
      username: admin
      password: "random 40 allowed-chars A-Za-z0-9"
```

### Credential Parameters

#### Random Passwords

```yaml
"random <length> [options]"

Options:
- fmt base64|bcrypt  # Encoding format
- allowed-chars <set>  # Character set
- fixed  # Prevent rotation
- at <key>  # Store at specific key

Examples:
- "random 16"  # 16-char password
- "random 32 fmt base64"  # Base64 encoded
- "random 8 allowed-chars 0-9"  # Numeric only
- "random 40 fixed"  # Non-rotating
```

#### SSH Keys

```yaml
"ssh <bits> [fixed]"

Examples:
- "ssh 2048"  # 2048-bit RSA key
- "ssh 4096 fixed"  # Non-rotating 4096-bit key
```

#### RSA Keys

```yaml
"rsa <bits> [fixed]"

Examples:
- "rsa 2048"  # 2048-bit RSA key
- "rsa 4096 fixed"  # Non-rotating 4096-bit key
```

#### DH Parameters

```yaml
"dhparam <bits> [fixed]"

Examples:
- "dhparam 2048"  # 2048-bit DH params
- "dhparam 4096 fixed"  # Non-rotating 4096-bit
```

#### UUIDs

```yaml
"uuid [version] [namespace <ns> name <name>]"

Examples:
- "uuid"  # Random v4 UUID
- "uuid v4"  # Explicit v4
- "uuid v5 namespace dns name example.com"  # Deterministic
```

## Certificates Section

### Basic Structure

```yaml
certificates:
  <feature>:
    <path>:
      <cert_name>:
        <properties>
```

### Certificate Properties

```yaml
certificates:
  base:
    certs:
      ca:
        is_ca: true
        valid_for: 10y
      
      server:
        valid_for: 1y
        names:
          - "*.system.cf.example.com"
          - "*.apps.cf.example.com"
          - "10.0.0.5"
        signed_by: certs/ca
```

### Certificate Parameters

- **is_ca**: Boolean, marks as CA certificate
- **valid_for**: Duration (e.g., `1y`, `90d`, `8760h`)
- **names**: List of DNS names and IPs
- **signed_by**: Path to signing CA (optional)

### Using Parameters

Reference environment parameters:

```yaml
certificates:
  base:
    haproxy/ssl:
      server:
        valid_for: "${params.cert_validity}"
        names: "${params.haproxy_domains}"
```

### Certificate Hierarchies

```yaml
certificates:
  base:
    # Root CA
    root/ca:
      is_ca: true
      valid_for: 20y
    
    # Intermediate CA
    intermediate/ca:
      is_ca: true
      valid_for: 10y
      signed_by: root/ca
    
    # Server certs
    internal/server:
      valid_for: 1y
      signed_by: intermediate/ca
      names: ["internal.example.com"]
```

## Provided Section

### Basic Structure

```yaml
provided:
  <feature>:
    <path>:
      type: generic
      keys:
        <key_name>:
          <properties>
```

### Provided Secret Properties

```yaml
provided:
  base:
    external/oauth:
      type: generic
      keys:
        client_id:
          type: string
          prompt: "Enter OAuth Client ID"
        
        client_secret:
          type: string
          sensitive: true
          prompt: "Enter OAuth Client Secret"
        
        private_key:
          type: string
          multiline: true
          prompt: "Paste private key (Ctrl-D when done)"
```

### Key Properties

- **type**: Always `string` currently
- **sensitive**: Hide input (boolean)
- **multiline**: Accept multiple lines (boolean)
- **prompt**: Message shown to user
- **fixed**: Prevent regeneration (boolean)

## Feature-Based Organization

### Conditional Secrets

Secrets can be organized by feature:

```yaml
credentials:
  # Always generated
  base:
    admin_password: random 32
  
  # Only with postgres feature
  postgres:
    db/password: random 32
    db/username: cfdb
  
  # Only with mysql feature
  mysql:
    db/password: random 40
    db/root_password: random 40

certificates:
  # Only with haproxy feature
  haproxy:
    haproxy/ssl:
      ca:
        is_ca: true
        valid_for: 10y
      server:
        valid_for: 1y
        names: ["*.${params.system_domain}"]
```

### Feature Activation

In environment file:

```yaml
kit:
  features:
    - postgres  # Activates postgres secrets
    - haproxy   # Activates haproxy certificates
```

## Advanced Patterns

### Shared CAs

```yaml
certificates:
  base:
    # Shared CA for all features
    shared/ca:
      ca:
        is_ca: true
        valid_for: 10y
  
  routing:
    # Uses shared CA
    router/ssl:
      server:
        signed_by: shared/ca
        valid_for: 1y
        names: ["*.router.${params.base_domain}"]
  
  uaa:
    # Also uses shared CA
    uaa/ssl:
      server:
        signed_by: shared/ca
        valid_for: 1y
        names: ["uaa.${params.system_domain}"]
```

### Computed Secrets

Some kits compute secrets from others:

```yaml
credentials:
  base:
    # Base components
    db/username: cfdb
    db/password: random 32
    
    # Computed in manifest
    # db/uri: postgres://cfdb:password@host:5432/cf
```

### Secret Groups

Organize related secrets:

```yaml
credentials:
  shield:
    # Agent credentials
    agent/shield:
      username: shield-agent
      password: random 32
    
    # Backup target credentials  
    backups/s3:
      access_key: "provided"
      secret_key: "provided"
    
    # Encryption key
    backups/cipher:
      key: "random 32 fmt base64"
```

## Validation

### Required Fields

Genesis validates secret definitions:

```yaml
# This will fail - certificates need names
certificates:
  base:
    bad/cert:
      server:
        valid_for: 1y
        # Missing: names
```

### Type Checking

```yaml
# This will fail - invalid secret type
credentials:
  base:
    bad/secret: "invalid-type 32"
```

## Best Practices

### 1. Use Clear Paths

```yaml
# Good - clear purpose
credentials:
  base:
    nats/server_password: random 32
    nats/client_password: random 32

# Bad - ambiguous
credentials:
  base:
    password1: random 32
    password2: random 32
```

### 2. Group Related Secrets

```yaml
credentials:
  base:
    # Group by component
    diego/ssh:
      private_key: "rsa 2048"
    diego/bbs/encryption:
      key: "random 32 fmt base64"
    diego/rep/password: random 32
```

### 3. Document Provided Secrets

```yaml
provided:
  newrelic:
    monitoring/newrelic:
      keys:
        license_key:
          prompt: |
            Enter New Relic License Key
            (Get from: https://rpm.newrelic.com/accounts/xxx)
```

### 4. Use Parameters

```yaml
# In kit.yml
certificates:
  base:
    web/ssl:
      server:
        valid_for: "${params.cert_validity_period}"
        names: "${params.web_domains}"

# Allows environment customization
params:
  cert_validity_period: 90d
  web_domains:
    - example.com
    - www.example.com
```

### 5. Consider Rotation

```yaml
credentials:
  base:
    # Rotatable
    app/password: random 32
    
    # Fixed - external dependency
    legacy/api_key: "random 40 fixed"
```

## Testing Secret Definitions

### Manual Testing

```bash
# Deploy to test environment
genesis new test-secrets
genesis deploy test-secrets

# Check generated secrets
safe tree secret/test/secrets
```

### Validation Commands

```bash
# Validate kit
genesis kit validate

# Check specific feature
genesis new test --features haproxy
genesis check test
```

Understanding kit secret definitions helps you create secure, maintainable Genesis kits with proper credential management.