# Kit Configuration in Environment Files

## Overview

The `kit` section in Genesis environment files defines how a kit is configured for a specific environment. This section specifies which kit to use, what features to enable, and any kit-specific overrides for secrets or other configurations.

## Basic Kit Configuration

### Kit Selection

```yaml
kit:
  name: bosh
  version: 4.0.0
  features:
    - shield-agent
    - vault-credhub-proxy
```

- **`name`**: The kit name (must match an available Genesis kit)
- **`version`**: Specific kit version to use (optional, defaults to latest)
- **`features`**: List of kit features to enable

### Feature Management

Features can be modified using spruce operators:

```yaml
# Adding features to defaults
kit:
  features:
    - (( append ))
    - external-db
    - custom-feature

# Replacing all features
kit:
  features:
    - (( replace ))
    - minimal-setup
    - basic-auth

# Removing specific features from array
kit:
  features:
    - (( delete "unwanted-feature" ))
    - remaining-feature
```

## Kit Overrides

The `overrides` section allows you to extend or modify kit-defined configurations:

### Secrets Overrides

You can add environment-specific secrets that supplement the kit's built-in secret definitions. For detailed syntax and options, refer to [docs/secrets.md](./secrets.md).

#### Adding Custom Credentials

```yaml
kit:
  name: my-app
  features: [basic]
  overrides:
    credentials:
      base:
        custom/api:
          token: random 64 fixed
        integration/auth:
          username: random 16 fmt base64 fixed
          password: random 32 fixed
```

#### Adding Custom Certificates

```yaml
kit:
  overrides:
    certificates:
      external-lb:  # Feature-specific certificates
        custom/tls:
          ca:
            valid_for: 1y
          server:
            valid_for: 90d
            names: "${params.external_domain},*.${params.external_domain}"
```

#### Adding User-Provided Secrets

```yaml
kit:
  overrides:
    provided:
      base:
        external/api:
          type: generic
          keys:
            endpoint:
              type: string
              prompt: "Enter the external API endpoint"
            token:
              type: string
              sensitive: true
              prompt: "Enter the API authentication token"
```

### Common Override Patterns

#### Bundling Features with Secrets

When adding complex functionality, you can bundle features with their required secrets:

```yaml
# In shared/monitoring.yml (for use with genesis.inherits)
kit:
  features:
    - (( append ))
    - prometheus-integration
  overrides:
    credentials:
      prometheus-integration:
        monitoring/prometheus:
          scrape_password: random 32 fixed
    certificates:
      prometheus-integration:
        monitoring/tls:
          ca:
            valid_for: 1y
          client:
            valid_for: 90d
            names: "prometheus-client"
```

#### Environment-Specific Secret Customization

```yaml
# Production environment with longer certificate validity
kit:
  overrides:
    certificates:
      base:
        ssl/web:
          server:
            valid_for: "${params.cert_validity_period}"  # Set in params
```

## Best Practices

### 1. Keep Overrides Minimal
Only override what's necessary for your specific environment. Let the kit handle standard configurations.

```yaml
# Good - only environment-specific additions
kit:
  overrides:
    credentials:
      base:
        custom/integration: random 32 fixed

# Avoid - redefining kit defaults
kit:
  overrides:
    credentials:
      base:
        admin/password: random 32 fixed  # Kit likely already defines this
```

### 2. Use Feature-Scoped Overrides
Organize overrides by feature to keep them maintainable:

```yaml
kit:
  overrides:
    credentials:
      monitoring-feature:       # Only generated when monitoring-feature is enabled
        monitoring/alerts: random 32 fixed
      base:                     # Always generated
        basic/admin: random 32 fixed
```

### 3. Document Custom Overrides
Add comments explaining why overrides are needed:

```yaml
kit:
  overrides:
    certificates:
      base:
        # Extended validity for production environment
        # to reduce rotation frequency
        ssl/server:
          server:
            valid_for: 2y
```

### 4. Use Parameters for Flexibility
Reference environment parameters in overrides for reusability:

```yaml
params:
  domain: example.com
  cert_validity: 1y

kit:
  overrides:
    certificates:
      base:
        web/tls:
          server:
            names: "api.${params.domain},*.${params.domain}"
            valid_for: "${params.cert_validity}"
```

## Integration with Inheritance

Kit configurations work seamlessly with `genesis.inherits`. See [genesis-inherit-documentation.md](./genesis-inherit-documentation.md) for examples of sharing kit configurations across environments.

## Reference

- For complete secrets syntax and options: [docs/secrets.md](./secrets.md)
- For kit authoring and development: [docs/AUTHORING-KITS.md](./AUTHORING-KITS.md)
- For environment inheritance patterns: [docs/genesis-inherit-documentation.md](./genesis-inherit-documentation.md)
