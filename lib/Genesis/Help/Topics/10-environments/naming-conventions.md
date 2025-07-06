# Environment Naming Conventions

Genesis uses environment names to automatically build configuration hierarchies, determine BOSH deployments, and organize secrets in Vault. Understanding these conventions is crucial for effective Genesis usage.

## Naming Rules

### Valid Characters and Format

Environment filenames must follow these rules:

- **Extension**: Must end with `.yml`
- **Characters**: Only lowercase letters, numbers, underscores, and hyphens
- **Start**: Must begin with a letter
- **End**: Cannot end with a hyphen
- **Hyphens**: No consecutive hyphens (`--`)

### Valid Examples
```
env1.yml
us-east-1-prod.yml
acme_aws_us_east_1_prod.yml
my-really-long-hyphenated-name.yml
```

### Invalid Examples
```
-prod.yml          # Starts with hyphen
prod-.yml          # Ends with hyphen
prod--east.yml     # Consecutive hyphens
PROD.yml           # Uppercase letters
prod@east.yml      # Invalid character (@)
```

## Hierarchical Structure

Genesis uses hyphens to create a configuration hierarchy. Each hyphen-separated segment represents a level that can have its own configuration file.

### How It Works

For an environment named `acme-aws-us-east-1-prod.yml`, Genesis automatically looks for and merges these files in order:

1. `acme.yml` - Organization level
2. `acme-aws.yml` - Infrastructure level
3. `acme-aws-us.yml` - Country/region level
4. `acme-aws-us-east.yml` - Region level
5. `acme-aws-us-east-1.yml` - Availability zone level
6. `acme-aws-us-east-1-prod.yml` - Environment level

Each level inherits from the previous, with later values overriding earlier ones.

### Common Naming Patterns

#### Organization-First Pattern
```
<org>-<infrastructure>-<region>-<purpose>

Examples:
- acme-aws-us-east-1-prod
- acme-azure-westeurope-staging
- acme-vsphere-dc1-dev
```

#### Infrastructure-First Pattern
```
<infrastructure>-<region>-<org>-<purpose>

Examples:
- aws-us-east-1-acme-prod
- gcp-us-central1-startup-dev
```

#### Purpose-Last Pattern (Recommended)
```
<org>-<any-hierarchy>-<purpose>

Examples:
- acme-aws-prod
- startup-onprem-datacenter1-staging
- enterprise-cloud-region2-zone-a-dev
```

## Configuration Inheritance

### Example Hierarchy

Given these files:
```yaml
# acme.yml
params:
  company: ACME Corp
  dns:
    - 10.0.0.1
    - 10.0.0.2

# acme-aws.yml
params:
  cloud: aws
  region: us-east-1

# acme-aws-us-east-1.yml
params:
  availability_zone: us-east-1a
  
# acme-aws-us-east-1-prod.yml
params:
  env: production
  instances: 3
```

The final configuration for `acme-aws-us-east-1-prod` includes all settings:
```yaml
params:
  company: ACME Corp
  dns:
    - 10.0.0.1
    - 10.0.0.2
  cloud: aws
  region: us-east-1
  availability_zone: us-east-1a
  env: production
  instances: 3
```

### Override Behavior

Later files override earlier ones:
```yaml
# acme.yml
params:
  instances: 1
  
# acme-aws-us-east-1-prod.yml
params:
  instances: 3  # This wins
```

## BOSH Deployment Names

Genesis creates BOSH deployment names using the pattern:
```
<environment-name>-<kit-type>
```

Examples:
- Environment: `acme-aws-us-east-1-prod.yml`
- Kit: `cf-genesis-kit`
- BOSH deployment: `acme-aws-us-east-1-prod-cf`

## Vault Path Structure

### Secrets Path

Secrets are stored with the environment name split into segments:
```
/secret/<segments>/<kit-type>/

Example:
Environment: aws-us-east-1-prod.yml
Kit: cf
Path: /secret/aws/us/east/1/prod/cf/
```

### Exodus Path

Exodus data uses the full environment name:
```
/secret/exodus/<environment-name>/<kit-type>

Example:
Environment: aws-us-east-1-prod.yml
Kit: cf
Path: /secret/exodus/aws-us-east-1-prod/cf
```

## Custom Paths

### Overriding Secrets Path
```yaml
genesis:
  secrets_mount: custom-secrets  # default: "secret"
  secrets_slug: prod-aws         # default: split name
```

### Overriding Exodus Path
```yaml
genesis:
  exodus_mount: custom-exodus    # default: "<secrets_mount>/exodus"
  exodus_slug: cf-production     # default: full name
```

## Special Cases

### BOSH Directors

BOSH directors cannot deploy themselves, so use:
```yaml
genesis:
  env: aws-us-east-1-bosh
  bosh_env: aws-us-east-1-proto  # Different director
```

### Non-Hierarchical Inheritance

Use `genesis.inherits` for custom inheritance:
```yaml
genesis:
  inherits:
    - base-config
    - regional-overrides
    - security-policies
```

## Best Practices

1. **Be Consistent** - Use the same pattern across all environments
2. **Purpose Last** - Put environment purpose (dev/staging/prod) at the end
3. **Meaningful Segments** - Each segment should represent a logical grouping
4. **Document Your Schema** - Keep a README explaining your naming convention
5. **Avoid Over-Nesting** - 4-6 segments is usually sufficient

## Examples by Use Case

### Multi-Region AWS
```
acme-aws-us-east-1-prod.yml
acme-aws-us-west-2-prod.yml
acme-aws-eu-west-1-prod.yml
```

### Multi-Cloud
```
startup-aws-us-east-1-prod.yml
startup-gcp-us-central1-prod.yml
startup-azure-eastus-prod.yml
```

### Development Stages
```
app-cloud-region-dev.yml
app-cloud-region-staging.yml
app-cloud-region-prod.yml
```

### By Department
```
acme-finance-aws-prod.yml
acme-hr-aws-prod.yml
acme-engineering-aws-prod.yml
```

## Troubleshooting

### Environment Not Found

Check:
- File has `.yml` extension
- Using exact name (unless using match mode)
- In correct directory

### Inheritance Not Working

Verify:
- Parent files exist
- Names follow hyphen hierarchy
- No typos in filenames

### Vault Paths Too Long

Use `secrets_slug` to shorten:
```yaml
genesis:
  secrets_slug: prod-east  # Instead of very/long/path/segments
```