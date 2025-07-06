# Reactions

Reactions allow you to run custom scripts before and after deployments on a per-environment basis. This enables environment-specific automation like maintenance notifications, integration updates, or custom validations.

## Overview

Reactions are scripts that execute at specific points in the deployment lifecycle:
- **Pre-deploy**: Before the deployment starts
- **Post-deploy**: After the deployment completes (or fails)

## Configuration

Add reactions to your environment file under the `genesis.reactions` key:

```yaml
genesis:
  reactions:
    pre-deploy:
      - script: put-up-maintenance-page
      - script: update-jira
        args: ['PROD-123', 'Deploying CF']
    post-deploy:
      - addon: run-smoke-tests
      - script: remove-maintenance-page
      - script: notify-slack
        args: ['#deployments', 'CF Production deployed']
```

## Script Location

Scripts must be placed in the `bin/` directory at the repository root:

```
cf-deployments/
├── bin/
│   ├── put-up-maintenance-page
│   ├── remove-maintenance-page
│   ├── update-jira
│   └── notify-slack
├── base.yml
└── aws-us-east-1-prod.yml
```

Scripts are automatically included in pipeline caches and made available during deployment.

## Script Arguments

### Static Arguments

Pass fixed arguments to scripts:

```yaml
reactions:
  pre-deploy:
    - script: notify-team
      args: ['production', 'cf', 'starting']
```

### Environment Variables

Use environment variables in arguments:

```yaml
reactions:
  post-deploy:
    - script: update-dashboard
      args: ['$GENESIS_ENVIRONMENT', '$DEPLOYMENT_STATUS']
```

## Available Environment Variables

Scripts have access to these environment variables:

### Always Available

- `GENESIS_ENVIRONMENT` - Current environment name
- `GENESIS_KIT_NAME` - Kit being deployed
- `GENESIS_KIT_VERSION` - Kit version
- `GENESIS_VAULT_PREFIX` - Vault path prefix
- `GENESIS_MANIFEST_FILE` - Path to the full manifest
- `GENESIS_BOSHVARS_FILE` - Path to BOSH variables file
- `GENESIS_DEPLOY_OPTIONS` - JSON of deployment options
- `GENESIS_DEPLOY_DRYRUN` - `true` if dry-run, `false` otherwise

### Pre-deploy Only

- `GENESIS_PREDEPLOY_DATAFILE` - Data from pre-deploy hook

### Post-deploy Only

- `GENESIS_DEPLOY_RC` - Deployment return code (0=success, 1=failure)

## Script Examples

### Maintenance Page Script

```bash
#!/bin/bash
# bin/put-up-maintenance-page

set -e

ENVIRONMENT="${GENESIS_ENVIRONMENT}"
MAINTENANCE_BUCKET="s3://maintenance-pages"

# Generate maintenance page
cat > /tmp/maintenance.html <<EOF
<!DOCTYPE html>
<html>
<head><title>Maintenance</title></head>
<body>
  <h1>System Maintenance</h1>
  <p>We're updating ${ENVIRONMENT}. Back soon!</p>
</body>
</html>
EOF

# Upload to CDN
aws s3 cp /tmp/maintenance.html "$MAINTENANCE_BUCKET/${ENVIRONMENT}.html"

# Update load balancer
aws elb configure-health-check \
  --load-balancer-name "${ENVIRONMENT}-lb" \
  --health-check Target=HTTP:80/maintenance.html

echo "Maintenance page activated for ${ENVIRONMENT}"
```

### Jira Integration

```bash
#!/bin/bash
# bin/update-jira

set -e

TICKET_ID="$1"
COMMENT="$2"
JIRA_URL="https://jira.example.com"

# Add deployment comment
curl -X POST \
  -H "Authorization: Bearer $JIRA_API_TOKEN" \
  -H "Content-Type: application/json" \
  "$JIRA_URL/rest/api/2/issue/$TICKET_ID/comment" \
  -d "{\"body\": \"Deployment: $COMMENT\"}"

# Transition ticket if successful
if [ "$GENESIS_DEPLOY_RC" = "0" ]; then
  curl -X POST \
    -H "Authorization: Bearer $JIRA_API_TOKEN" \
    "$JIRA_URL/rest/api/2/issue/$TICKET_ID/transitions" \
    -d '{"transition": {"id": "31"}}'  # Deploy Complete
fi
```

### Slack Notification

```bash
#!/bin/bash
# bin/notify-slack

CHANNEL="$1"
MESSAGE="$2"
WEBHOOK_URL="$SLACK_WEBHOOK_URL"

STATUS="success"
COLOR="good"

if [ "$GENESIS_DEPLOY_RC" = "1" ]; then
  STATUS="failed"
  COLOR="danger"
fi

curl -X POST "$WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d @- <<EOF
{
  "channel": "$CHANNEL",
  "attachments": [{
    "color": "$COLOR",
    "title": "Genesis Deployment",
    "text": "$MESSAGE",
    "fields": [
      {"title": "Environment", "value": "$GENESIS_ENVIRONMENT", "short": true},
      {"title": "Status", "value": "$STATUS", "short": true}
    ]
  }]
}
EOF
```

## Using Kit Addons

Instead of scripts, you can run kit addons:

```yaml
reactions:
  post-deploy:
    - addon: run-smoke-tests
    - addon: update-dns
```

This runs the addon as if you had executed:
```bash
genesis do <env> -- run-smoke-tests
genesis do <env> -- update-dns
```

## Advanced Patterns

### Conditional Execution

```bash
#!/bin/bash
# Only run in production

if [[ "$GENESIS_ENVIRONMENT" == *-prod ]]; then
  echo "Running production-only task..."
  # Production logic here
fi
```

### Using Manifest Data

```bash
#!/bin/bash
# Extract data from manifest

# Get instance count
INSTANCES=$(spruce json "$GENESIS_MANIFEST_FILE" | \
  jq '.instance_groups[] | select(.name=="web") | .instances')

# Alert if scaling up significantly
if [ "$INSTANCES" -gt 10 ]; then
  send-alert "Scaling to $INSTANCES instances!"
fi
```

### Error Handling

```bash
#!/bin/bash
# Handle deployment failures

if [ "$GENESIS_DEPLOY_RC" != "0" ]; then
  # Rollback actions
  restore-database-snapshot
  clear-cache
  
  # Alert on-call
  pagerduty-alert "Deployment failed for $GENESIS_ENVIRONMENT"
  
  exit 1
fi
```

## Best Practices

### 1. Make Scripts Idempotent

Scripts should handle being run multiple times:

```bash
# Good - checks before acting
if ! maintenance-page-exists; then
  create-maintenance-page
fi

# Bad - assumes state
rm /var/www/index.html  # Fails if already removed
```

### 2. Handle Failures Gracefully

```bash
#!/bin/bash
set -e  # Exit on error

# Cleanup function
cleanup() {
  echo "Cleaning up..."
  remove-temp-files
}
trap cleanup EXIT

# Main logic
do-deployment-task || {
  echo "Task failed, but continuing deployment"
  exit 0  # Don't fail the deployment
}
```

### 3. Log Appropriately

```bash
#!/bin/bash
LOG_FILE="/var/log/genesis-reactions.log"

log() {
  echo "[$(date)] $GENESIS_ENVIRONMENT: $1" | tee -a "$LOG_FILE"
}

log "Starting pre-deploy reaction"
# ... script logic ...
log "Pre-deploy reaction complete"
```

### 4. Use Version Control

Always commit reaction scripts:

```bash
git add bin/
git commit -m "Add deployment reaction scripts"
```

### 5. Test Scripts Locally

```bash
# Test with mock environment
export GENESIS_ENVIRONMENT="test-env"
export GENESIS_DEPLOY_RC="0"
./bin/notify-slack "#test" "Test message"
```

## Common Use Cases

### Database Migrations

```yaml
reactions:
  pre-deploy:
    - script: backup-database
    - script: run-migrations
```

### Cache Management

```yaml
reactions:
  post-deploy:
    - script: clear-cdn-cache
    - script: warm-application-cache
```

### External Service Updates

```yaml
reactions:
  post-deploy:
    - script: update-load-balancer
    - script: register-service-discovery
    - script: update-monitoring
```

### Compliance and Auditing

```yaml
reactions:
  pre-deploy:
    - script: log-deployment-start
      args: ['audit-system']
  post-deploy:
    - script: log-deployment-complete
      args: ['audit-system', '$GENESIS_DEPLOY_RC']
```

## Troubleshooting

### Script Not Found

Ensure:
- Script is in `bin/` directory
- Script has execute permissions: `chmod +x bin/script-name`
- Script name matches exactly (case-sensitive)

### Environment Variables Not Set

Check:
- Using correct variable names
- Variables are exported in script
- Not overwriting Genesis variables

### Script Failures

- Check script logs
- Run script manually to test
- Verify all dependencies available
- Check script exit codes

### Pipeline Issues

For CI/CD pipelines:
- Ensure bin/ directory is included
- Scripts are committed to Git
- Pipeline has necessary credentials

Reactions provide powerful automation capabilities while maintaining environment-specific flexibility.