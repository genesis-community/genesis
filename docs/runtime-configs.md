# Runtime Config Options in Genesis Environment Files

Genesis supports generating and managing BOSH runtime configs through kit hooks. This document describes how to specify runtime config options in your environment files.

## Overview

Runtime configs are BOSH configurations that apply to all deployments on a BOSH director. Genesis kits can provide runtime config hooks that generate these configurations based on your environment settings.

## Basic Usage

Runtime config options are specified under the `bosh-configs` top-level key in your environment file:

```yaml
bosh-configs:
  runtime:
    # Runtime config specifications go here
```

## Specification Formats

Genesis supports several formats for specifying runtime configs:

### 1. Boolean (Enable All)

Enable all available runtime configs with default options:

```yaml
bosh-configs:
  runtime: true
```

### 2. String (Single Config)

Request a single runtime config by name:

```yaml
bosh-configs:
  runtime: "dns"
```

### 3. Comma-Separated String (Multiple Configs)

Request multiple runtime builds by name in a comma-separated string:

```yaml
bosh-configs:
	runtime: "dns,toolbelt"
```

This will only generate the `dns` and `toolbelt` runtime configs.  Any other builds will not be generated.

### 4. Array (Multiple Configs)

Similar to the comma-separated string, you can use an array to request multiple runtime builds by name:

```yaml
bosh-configs:
  runtime:
    - dns
    - toolbelt
```

### 4. Hash (Configs with Options)

Specify runtime builds with custom options:

```yaml
bosh-configs:
  runtime:
    dns: 
      timeout: 30
      retries: 3
    security:
      enforce_tls: true
    monitoring: true  # no options - just enable the build
```

*Note:* The example above is not representative of actual runtime config options, but  is for illustration purposes only.  The actual options available depend on the specific runtime config being used.

### 5. Mixed Options

Combine different specification methods:

```yaml
bosh-configs:
  runtime:
    "*":  # All configs with shared options
      environment: production
    dns:
      timeout: 30
    security: false  # Exclude this config
```

In this example, all runtime configs are enabled with the `environment` option, while the `dns` config has an additional `timeout` option, and the `security` config is explicitly excluded.

When writing runtime config hooks, they should gracefully ignore options that are not applicable to the specific runtime config being generated. This allows for flexibility in specifying options without causing errors.

## Advanced Options

### Excluding Configs

Use `false` to explicitly exclude specific runtime configs:

```yaml
bosh-configs:
  runtime:
    "*": true        # Enable all configs
    legacy: false    # But exclude the legacy config
```

In this example, we explicitly enable all runtime configs but exclude the `legacy` config.  However, in this case, the `*` is redundant, because if you ***only*** specify explicit configs as false, then all other configs will be enabled by default.

### Wildcard Selection

Use `*` to apply options to all available runtime configs:

```yaml
bosh-configs:
  runtime:
    "*":
      environment: production
      region: us-west-2
```

### Comma-Separated Lists

Group multiple configs with shared options:

```yaml
bosh-configs:
  runtime:
    "dns,security,monitoring":
      environment: production
```

## Common Runtime Config Types

Different Genesis kits provide different runtime configs.  At the time of this writing, only the BOSH kit provides separate runtime config builds.  Other kits simply provide a boolean option to enable or disable all runtime configs during post-deployment.

It is further intended that the BOSH kit will be able to specify runtimes from other kits, allowing you to ensure that all deployments it deploys will have the same runtime configs applied.

## See Also

- [Genesis Environment Files](environment-files.md)
- [BOSH Runtime Configs](https://bosh.io/docs/runtime-config/)
- [Kit Development Guide](kit-development.md)
