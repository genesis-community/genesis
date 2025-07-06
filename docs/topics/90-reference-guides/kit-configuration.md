# Kit Configuration Reference

This document provides a complete reference for the `kit.yml` configuration file used in Genesis kits.

## Overview

The `kit.yml` file defines kit metadata, dependencies, secrets, and configuration options. It serves as the primary configuration point for Genesis kits.

## File Structure

```yaml
# Basic kit information
name: my-kit
authors:
  - Your Name <you@example.com>
docs: https://github.com/genesis-community/my-kit
code: https://github.com/genesis-community/my-kit

# Version constraints
genesis_version_min: 2.8.0

# Dependencies
releases:
  - name: my-release
    version: 1.2.3
    url: https://bosh.io/d/github.com/org/release
    sha1: abc123...

stemcells:
  - os: ubuntu-jammy
    version: latest

# Features
features:
  - name: ha
    description: Enable high availability mode
  - name: ssl
    description: Enable SSL/TLS encryption

# Secrets and certificates
credentials:
  - name: admin_password
    description: Administrative user password

certificates:
  - name: server
    description: Server certificate for TLS
```

## Configuration Sections

### Basic Information

#### name
**Required**: Yes  
**Type**: String  
**Description**: The name of the kit. Must match the directory name for compiled kits.

```yaml
name: concourse
```

#### authors
**Required**: No  
**Type**: Array of strings  
**Description**: List of kit authors with optional email addresses.

```yaml
authors:
  - Jane Doe <jane@example.com>
  - John Smith
```

#### docs
**Required**: No  
**Type**: String (URL)  
**Description**: URL to kit documentation.

```yaml
docs: https://github.com/genesis-community/concourse-genesis-kit
```

#### code
**Required**: No  
**Type**: String (URL)  
**Description**: URL to kit source code repository.

```yaml
code: https://github.com/genesis-community/concourse-genesis-kit
```

#### description
**Required**: No  
**Type**: String  
**Description**: Brief description of the kit's purpose.

```yaml
description: |
  Deploys Concourse CI/CD platform with Genesis
```

### Version Constraints

#### genesis_version_min
**Required**: No  
**Type**: String (Semantic Version)  
**Description**: Minimum Genesis version required for this kit.

```yaml
genesis_version_min: 2.8.0
```

#### genesis_version_max
**Required**: No  
**Type**: String (Semantic Version)  
**Description**: Maximum Genesis version supported by this kit.

```yaml
genesis_version_max: 2.9.99
```

### Dependencies

#### releases
**Required**: No  
**Type**: Array of release specifications  
**Description**: BOSH releases required by the kit.

**Release Specification**:
```yaml
releases:
  - name: concourse        # Required: Release name
    version: 7.8.3         # Required: Version (can use patterns)
    url: https://...       # Optional: Download URL
    sha1: abc123...        # Optional: SHA1 checksum
    github: owner/repo     # Optional: GitHub repository
    
  # Version patterns
  - name: postgres
    version: "43"          # Exact version
    
  - name: bpm
    version: 1.1.+         # Any 1.1.x version
    
  - name: routing
    version: ">=0.200.0"   # Version 0.200.0 or higher
```

#### stemcells
**Required**: No  
**Type**: Array of stemcell specifications  
**Description**: Stemcells required by the kit.

```yaml
stemcells:
  - os: ubuntu-jammy       # Required: OS type
    version: latest        # Required: Version or "latest"
    
  - os: ubuntu-bionic
    version: 621.+         # Minimum version pattern
    
  # Multiple stemcells for different instance groups
  - alias: default
    os: ubuntu-jammy
    version: latest
    
  - alias: windows
    os: windows2019
    version: latest
```

### Features

#### features
**Required**: No  
**Type**: Array of feature definitions  
**Description**: Optional features that can be enabled.

```yaml
features:
  - name: ha
    description: |
      Enable high availability mode with 3 instances
    deprecated: false      # Optional: Mark as deprecated
    
  - name: monitoring
    description: Enable Prometheus exporters
    
  - name: shield-agent
    deprecated: true
    description: |
      DEPRECATED: Use Shield runtime config instead
```

### Secrets Configuration

#### credentials
**Required**: No  
**Type**: Array of credential definitions  
**Description**: Password and random secret definitions.

```yaml
credentials:
  # Basic password
  - name: admin_password
    description: Administrator password
    
  # With constraints
  - name: api_key
    description: API authentication key
    length: 32
    fixed: true           # Don't rotate
    
  # With character set
  - name: db_password
    description: Database password
    length: 20
    allowed_chars: "a-zA-Z0-9"
```

#### certificates
**Required**: No  
**Type**: Array of certificate definitions  
**Description**: X.509 certificate definitions.

```yaml
certificates:
  # Basic certificate
  - name: server
    description: Server TLS certificate
    
  # With components
  - name: ca
    description: Certificate Authority
    self_signed: true
    
  - name: server
    description: Server certificate
    signed_by: ca
    common_name: "*.example.com"
    alternative_names:
      - "*.example.com"
      - "10.0.0.5"
      - "localhost"
    
  # With custom validity
  - name: client
    description: Client certificate
    ttl: 90d              # 90 days
    signed_by: ca
    
  # With specific usage
  - name: etcd-peer
    description: etcd peer certificate
    key_usage:
      - digital_signature
      - key_encipherment
    extended_key_usage:
      - server_auth
      - client_auth
```

#### provided
**Required**: No  
**Type**: Array of provided secret definitions  
**Description**: Secrets that users must provide.

```yaml
provided:
  - name: ssl_cert
    description: |
      SSL certificate for external access.
      Must include full certificate chain.
    example: |
      -----BEGIN CERTIFICATE-----
      MIIDXTCCAkWgAwIBAgIJAKl...
      -----END CERTIFICATE-----
    
  - name: slack_webhook
    description: Slack webhook URL for notifications
    example: https://hooks.slack.com/services/XXX/YYY/ZZZ
```

### Parameters

#### params
**Required**: No  
**Type**: Hash  
**Description**: Default parameter values.

```yaml
params:
  # Simple defaults
  instances: 1
  vm_type: default
  
  # Complex defaults
  networks:
    - name: default
      static_ips: []
```

### Subkits (Deprecated)

The `subkits` section is deprecated in favor of `features`:

```yaml
# Old format (deprecated)
subkits:
  - name: ha
    description: High availability

# New format
features:
  - name: ha
    description: High availability
```

## Advanced Configuration

### Conditional Features

Features can have dependencies and conflicts:

```yaml
features:
  - name: ha
    description: High availability (requires 3+ instances)
    
  - name: single-node
    description: Single node deployment
    conflicts: [ha]       # Cannot use with HA
    
  - name: ssl
    description: Enable SSL/TLS
    
  - name: mtls
    description: Mutual TLS authentication
    requires: [ssl]       # Requires SSL feature
```

### Complex Secrets

Advanced secret configurations:

```yaml
credentials:
  # User-provided with validation
  - name: admin_password
    description: Admin password
    min_length: 12
    require_special: true
    require_numeric: true
    
  # Generated with specific format
  - name: session_key
    description: Session encryption key
    format: base64
    length: 32

certificates:
  # CA with specific DN
  - name: ca
    description: Root CA
    self_signed: true
    ttl: 10y
    subject:
      C: US
      ST: California
      L: San Francisco
      O: Example Corp
      OU: IT Department
      CN: Example Root CA
    
  # Server with IP SANs
  - name: server
    description: Server certificate
    signed_by: ca
    common_name: server.example.com
    ip_sans:
      - 10.0.0.5
      - 10.0.0.6
    dns_sans:
      - server.example.com
      - api.example.com
```

### Release Versions

Complex version specifications:

```yaml
releases:
  # Latest from GitHub
  - name: concourse
    github: concourse/concourse-bosh-release
    version: latest
    
  # Specific version with fallback
  - name: postgres
    version: "43"
    url: https://bosh.io/d/github.com/cloudfoundry/postgres-release?v=43
    sha1: abc123
    fallback:
      version: "42"
      url: https://bosh.io/d/github.com/cloudfoundry/postgres-release?v=42
      sha1: def456
    
  # Version range
  - name: routing
    version: ">=0.200.0 <1.0.0"
```

### Environment Types

Kits can define environment types:

```yaml
environment_types:
  - name: development
    features:
      - single-node
    params:
      instances: 1
      
  - name: production
    features:
      - ha
      - ssl
      - monitoring
    params:
      instances: 3
```

### Deployment Parameters

Control deployment behavior:

```yaml
deployment:
  # Canary settings
  canaries: 1
  max_in_flight: 10
  canary_watch_time: 30000-600000
  update_watch_time: 30000-600000
  
  # Serial deployment
  serial: false
  
  # AZ configuration
  availability_zones:
    - z1
    - z2
    - z3
```

## Validation Schema

Genesis validates kit.yml against this schema:

```yaml
type: map
mapping:
  name:
    type: str
    required: true
  authors:
    type: seq
    sequence:
      - type: str
  genesis_version_min:
    type: str
    pattern: /^\d+\.\d+\.\d+$/
  releases:
    type: seq
    sequence:
      - type: map
        mapping:
          name: {type: str, required: true}
          version: {type: str, required: true}
          url: {type: str}
          sha1: {type: str}
  # ... etc
```

## Complete Example

Comprehensive kit.yml example:

```yaml
name: concourse
authors:
  - Genesis Community
  - Concourse Team <concourse@example.com>
docs: https://concourse-ci.org
code: https://github.com/genesis-community/concourse-genesis-kit
description: |
  Deploy Concourse CI/CD platform using Genesis
  
  Supports standalone and clustered deployments
  with optional GitHub authentication.

genesis_version_min: 2.8.0

releases:
  - name: concourse
    version: 7.8.3
    url: https://bosh.io/d/github.com/concourse/concourse-bosh-release?v=7.8.3
    sha1: abc123def456
    
  - name: postgres
    version: "43"
    url: https://bosh.io/d/github.com/cloudfoundry/postgres-release?v=43
    sha1: 789ghi012jkl
    
  - name: bpm
    version: 1.1.+
    
  - name: routing
    version: latest

stemcells:
  - alias: default
    os: ubuntu-jammy
    version: latest

features:
  - name: workers
    description: |
      Deploy external workers for job processing
      
  - name: github-oauth
    description: |
      Enable GitHub OAuth for authentication
      
  - name: prometheus
    description: |
      Export Prometheus metrics
      
  - name: vault
    description: |
      Use Vault for credential management
    deprecated: true

params:
  # Instance configuration
  instances: 1
  vm_type: default
  network: concourse
  disk_type: default
  
  # Concourse configuration
  external_url: https://concourse.example.com
  worker_count: 3

credentials:
  - name: local_user_password
    description: Password for local admin user
    
  - name: postgresql_password
    description: PostgreSQL database password
    length: 32
    
  - name: token_signing_key
    description: Key for signing auth tokens
    format: rsa
    bits: 4096

certificates:
  - name: ca
    description: Concourse CA certificate
    self_signed: true
    ttl: 10y
    
  - name: tls
    description: Concourse web TLS certificate
    signed_by: ca
    ttl: 1y
    common_name: concourse.example.com
    alternative_names:
      - "*.concourse.example.com"
      - "127.0.0.1"
      
  - name: worker
    description: Worker certificate
    signed_by: ca
    ttl: 90d
    common_name: worker.concourse.internal

provided:
  - name: github_oauth_client_id
    description: |
      GitHub OAuth application client ID
      Create at: https://github.com/settings/applications/new
    example: "0123456789abcdef0123"
    
  - name: github_oauth_client_secret  
    description: |
      GitHub OAuth application client secret
    example: "0123456789abcdef0123456789abcdef01234567"

deployment:
  canaries: 1
  max_in_flight: 4
  canary_watch_time: 30000-600000
  update_watch_time: 30000-600000
  serial: false
```

## Best Practices

1. **Version Constraints**: Always specify minimum Genesis version
2. **Descriptions**: Provide clear descriptions for all features and secrets
3. **Examples**: Include examples for provided secrets
4. **Deprecation**: Mark deprecated features clearly
5. **Documentation**: Link to comprehensive documentation
6. **Validation**: Test kit.yml with `genesis compile-kit`

The kit.yml file is the heart of a Genesis kit, defining its capabilities, requirements, and configuration options.