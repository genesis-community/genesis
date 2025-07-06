# Match Mode

Match mode provides a powerful way to quickly reference Genesis environments using glob-style patterns instead of typing full environment names. This is especially useful with long, hierarchical environment names.

## Overview

Instead of typing:
```bash
genesis deploy acme-aws-us-east-1-production
```

You can use:
```bash
genesis deploy @prod:cf
```

The `@` prefix activates match mode, allowing pattern matching against environment names.

## Enabling Match Mode

Match mode requires configuring deployment roots in your `~/.genesis/config`:

```yaml
---
deployment_roots:
  - ~/deployments              # Simple path
  - work: ~/work/deployments    # Labeled path
  - prod: /opt/genesis/prod     # Production deployments
```

Without deployment roots configured, match mode is not available.

## Match Mode Syntax

### Basic Pattern
```
@<pattern>:<type>
```

- `@` - Activates match mode
- `<pattern>` - Glob pattern to match environment names
- `:<type>` - Kit type (optional but recommended)

### Examples

```bash
# Match any production CF environment
genesis deploy @prod:cf

# Match us-east production
genesis deploy @*east*prod:cf

# Match anything in us-west-2
genesis deploy @*west-2*:bosh

# Match dev environments
genesis deploy @*dev:vault
```

## Pattern Matching

### Wildcards

- `*` - Matches any characters
- `?` - Matches single character

```bash
@prod           # Matches: prod, production, acme-prod
@*-prod         # Matches: us-east-1-prod, aws-prod
@us-*-1-*       # Matches: us-east-1-dev, us-west-1-prod
@us-????-1-prod # Matches: us-east-1-prod, us-west-1-prod
```

### Case Sensitivity

Matches are case-sensitive:
```bash
@prod  # Won't match: Prod, PROD
```

## Interactive Selection

When multiple environments match, Genesis presents a menu:

```bash
$ genesis deploy @*:cf

Multiple environment files found matching @*:cf:

  📁 Deployment Root 'work': ~/work/deployments
  1) cf/acme-aws-us-east-1-dev (default)
  2) cf/acme-aws-us-east-1-staging
  3) cf/acme-aws-us-east-1-prod
  4) cf/acme-aws-us-west-2-prod

  5) None of these - cancel

Select the desired environment file >
```

## Deployment Types

The `:<type>` suffix specifies which kit type to search:

```bash
@prod:cf        # Cloud Foundry deployments
@prod:bosh      # BOSH directors
@prod:vault     # Vault deployments
@prod:concourse # Concourse deployments
```

### Benefits of Specifying Type

1. **Faster** - Only searches relevant directories
2. **Accurate** - Avoids matching similarly named environments
3. **Clear** - Shows intent in commands

## Working with Multiple Roots

With multiple deployment roots:

```yaml
deployment_roots:
  - personal: ~/my-deployments
  - work: ~/work/deployments
  - client: ~/client/infrastructure
```

Matches search all roots:

```bash
$ genesis list @prod:*

personal:
  bosh/home-prod
  vault/personal-prod

work:
  cf/acme-aws-us-east-1-prod
  cf/acme-aws-us-west-2-prod

client:
  cf/bigco-azure-eastus-prod
  concourse/bigco-ci-prod
```

## Common Patterns

### By Environment Stage

```bash
# Development environments
genesis deploy @*dev*:cf
genesis check @*development*:vault

# Staging environments  
genesis manifest @*staging*:cf
genesis rotate-secrets @*stage*:bosh

# Production environments
genesis deploy @*prod*:cf
genesis describe @*production*:vault
```

### By Region

```bash
# US East environments
genesis deploy @*us-east*:cf
genesis list @*east-1*:*

# Europe environments
genesis check @*eu-*:bosh
genesis manifest @*europe*:vault

# All AWS environments
genesis list @*aws*:*
```

### By Organization

```bash
# ACME environments
genesis deploy @acme*:cf
genesis list @acme-*:*

# Department-specific
genesis deploy @*finance*:vault
genesis check @*engineering*:cf
```

## Advanced Usage

### Combining with Other Commands

Match mode works with most Genesis commands:

```bash
# Deployment operations
genesis deploy @prod:cf
genesis check @staging:vault
genesis manifest @dev:bosh

# Information commands
genesis describe @prod:cf
genesis list @*:vault
genesis info @dev:*

# Maintenance commands
genesis rotate-secrets @prod:vault
genesis do @staging:cf -- smoke-tests

# Pipeline operations
genesis repipe @*:cf
```

### Scripting with Match Mode

For scripts, use exact matches when possible:

```bash
#!/bin/bash
# Deploy all production CF environments

for env in $(genesis list @*prod:cf --json | jq -r '.[].name'); do
  echo "Deploying $env..."
  genesis deploy "$env"
done
```

### Unique Patterns

Design patterns that uniquely identify environments:

```bash
# Too broad
@prod         # Matches: prod, production, non-prod

# More specific
@*-prod       # Matches: us-east-1-prod (not non-prod)
@prod:cf      # Only CF production environments
```

## Best Practices

### 1. Use Type Suffixes

Always include the kit type for clarity:
```bash
# Good
genesis deploy @prod:cf

# Less clear
genesis deploy @prod
```

### 2. Test Patterns First

Use `list` to verify your pattern:
```bash
# Check what matches before deploying
genesis list @*west*:cf
genesis deploy @*west*:cf
```

### 3. Be Specific in Production

For production operations, use specific patterns:
```bash
# Good - very specific
genesis deploy @acme-aws-us-east-1-prod:cf

# Risky - might match unexpected environments
genesis deploy @prod:cf
```

### 4. Document Common Patterns

Keep a reference of useful patterns:
```markdown
## Common Match Patterns

- `@*dev*:cf` - All CF dev environments  
- `@*-prod:vault` - All production Vaults
- `@acme-*:*` - All ACME environments
- `@*us-east-1*:bosh` - US East 1 BOSH directors
```

## Troubleshooting

### No Matches Found

Check:
- Deployment roots are configured
- Pattern is correct
- Environment files exist
- Kit type is correct

### Too Many Matches

Make pattern more specific:
```bash
# Too broad
@*:cf

# Better
@*prod:cf
@*us-east*prod:cf
```

### Match Mode Not Working

Verify deployment roots:
```bash
# Check configuration
cat ~/.genesis/config

# Should include:
deployment_roots:
  - /path/to/deployments
```

### Wrong Environment Selected

- Double-check the selection number
- Use more specific patterns
- Consider using full environment name

## Examples

### Quick Deployment Check
```bash
# Check all production environments before deploying
genesis check @*prod:cf
genesis check @*prod:vault
genesis check @*prod:bosh
```

### Regional Operations
```bash
# Rotate secrets for all US East production
genesis rotate-secrets @*us-east*prod:cf
genesis rotate-secrets @*us-east*prod:vault
```

### Development Workflow
```bash
# Deploy to your personal dev environment
genesis deploy @john-dev:cf

# Check all team dev environments
genesis list @*-dev:cf
```

### Disaster Recovery
```bash
# Quick DR environment access
genesis do @*-dr:vault -- unseal
genesis deploy @*-dr:cf
```

Match mode significantly speeds up Genesis operations, especially in environments with many deployments and long naming conventions.