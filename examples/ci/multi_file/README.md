# Multi-File CI Configuration Example

This directory contains a complete example of the Genesis CI multi-file configuration format.

## Required vs Optional Files

### ✅ REQUIRED Files

```
.genesis/ci/
├── pipeline.yml          # ✅ REQUIRED - Main pipeline definition
├── targets.yml           # ✅ REQUIRED - Deployment targets (BOSH directors)
└── integrations.yml      # ✅ REQUIRED - Vault, Git, notifications
```

**Minimum viable configuration requires only these 3 files.**

### 📋 OPTIONAL Files

```
.genesis/ci/
├── scripts/                      # 📋 OPTIONAL - Custom scripts
│   └── manifest.yml              # 📋 OPTIONAL - Explicit script metadata
│                                 #              (scripts auto-discovered if not present)
└── provider-config/              # 📋 OPTIONAL - Provider-specific overrides
    ├── concourse.yml             # 📋 OPTIONAL - Concourse settings
    └── github-actions.yml        # 📋 OPTIONAL - GitHub Actions settings
```

### Complete Example Structure

```
.genesis/ci/                        # CI configuration directory
├── pipeline.yml                    # ✅ REQUIRED
├── targets.yml                     # ✅ REQUIRED
├── integrations.yml                # ✅ REQUIRED
├── scripts/                        # 📋 OPTIONAL
│   ├── manifest.yml                # 📋 OPTIONAL - Explicit script definitions
│   ├── deploy/ 
│   │   └── genesis-deploy.sh       # 📋 OPTIONAL - Deployment script
│   ├── test/ 
│   │   └── smoke-tests.sh          # 📋 OPTIONAL - Smoke test script
│   └── maintenance/ 
│       ├── check-kit-updates.sh    # 📋 OPTIONAL - Kit update checker
│       └── update-kit.sh           # 📋 OPTIONAL - Kit updater
└── provider-config/                # 📋 OPTIONAL
    ├── concourse.yml               # 📋 OPTIONAL - Concourse overrides
    └── github-actions.yml          # 📋 OPTIONAL - GitHub Actions overrides
```

## Required File Details

### 1. ✅ pipeline.yml - Main Pipeline Definition

**Required sections:**
- ✅ `metadata.name` - Pipeline name
- ✅ `branches.live` - Main branch to monitor
- ✅ `workflows` - At least one workflow

**Optional sections:**
- 📋 `metadata.version`, `metadata.description`
- 📋 `branches.target_prefix`
- 📋 `configuration.*` - All configuration is optional

**Minimal Example:**
```yaml
metadata:
  name: my-pipeline
branches:
  live: main
workflows:
  deploy:
    type: deployment
    stages:
      - name: sandbox
```

See [pipeline.yml](pipeline.yml) for full example with all optional features.

### 2. ✅ targets.yml - Deployment Targets

**Required:**
- ✅ `targets` - At least one deployment target

**For BOSH director targets, required:**
- ✅ `type: bosh-director`
- ✅ `connection.url`
- ✅ `connection.auth.client_id`
- ✅ `connection.auth.client_secret`
- ✅ `connection.ca_cert`

**Optional per-target:**
- 📋 `alias`, `tags`, `region`, `genesis_env`

**Minimal Example:**
```yaml
targets:
  sandbox:
    type: bosh-director
    connection:
      url: https://bosh.example.com:25555
      auth:
        client_id: admin
        client_secret: ((bosh-password))
      ca_cert: ((bosh-ca-cert))
```

See [targets.yml](targets.yml) for multi-region, multi-tier example.

### 3. ✅ integrations.yml - External Services

**Required:**
- ✅ `vault.url`
- ✅ `source_control` (provider or uri + repository)
- ✅ At least one notification (`slack` or `email`)

**Optional:**
- 📋 `vault.namespace`, `vault.auth`
- 📋 `source_control.auth`, `source_control.commit_author`
- 📋 `locker` configuration

**Minimal Example:**
```yaml
vault:
  url: https://vault.example.com

source_control:
  provider: github
  repository: myorg/deployments

notifications:
  - type: slack
    webhook: ((slack-webhook))
    channel: "#deployments"
```

See [integrations.yml](integrations.yml) for full example.

## Optional Features

### 📋 Script Discovery (3 Methods)

Scripts are discovered automatically using **three methods in priority order:**

#### Method 1: Explicit Manifest (Highest Priority)
[scripts/manifest.yml](scripts/manifest.yml) - Full control over script metadata

#### Method 2: Inline Annotations
Scripts with `@genesis-script` annotations:
```bash
#!/bin/bash
# @genesis-script
# @description: Execute Genesis deployment
# @requires: genesis>=3.1.0
# @timeout: 60m
```

#### Method 3: Convention-Based (Fallback)
Auto-discovery from filename:
- `scripts/deploy.sh` → ID: `deploy`
- `scripts/test/smoke.sh` → ID: `test/smoke`

### 📋 Provider-Specific Overrides

- [provider-config/concourse.yml](provider-config/concourse.yml) - Concourse-only settings
- [provider-config/github-actions.yml](provider-config/github-actions.yml) - GitHub Actions-only settings

## Quick Start - Minimal Configuration

Create these 3 files to get started:

**`.genesis/ci/pipeline.yml`:**
```yaml
metadata:
  name: my-pipeline
branches:
  live: main
workflows:
  deploy:
    type: deployment
    stages:
      - name: sandbox
```

**`.genesis/ci/targets.yml`:**
```yaml
targets:
  sandbox:
    type: bosh-director
    connection:
      url: https://bosh.example.com:25555
      auth:
        client_id: admin
        client_secret: ((bosh-password))
      ca_cert: ((bosh-ca-cert))
```

**`.genesis/ci/integrations.yml`:**
```yaml
vault:
  url: https://vault.example.com
source_control:
  provider: github
  repository: myorg/deployments
notifications:
  - type: slack
    webhook: ((slack-webhook))
    channel: "#ci"
```

Then compile:
```bash
genesis ci compile --provider concourse --ci-dir .genesis/ci
```

## Usage

### Compile to Concourse Pipeline

```bash
cd /path/to/deployment-repo

# Compile using the compiler
genesis ci compile --provider concourse --ci-dir .genesis/ci
```

### Compile to GitHub Actions Workflow

```bash
genesis ci compile --provider github-actions --ci-dir .genesis/ci
```

### Generate Pipeline from Legacy Format

If you have an existing `ci.yml`, you can migrate:

```bash
# The compiler handles both formats automatically
genesis ci compile --provider concourse --file ci.yml
```

## Secret References

Secrets use the `((...))` syntax and are resolved at runtime:

- `((vault/path/to/secret))` - Vault secret path
- `((bosh/env/ca-cert))` - BOSH director CA certificate
- `((git/deploy-key))` - Git SSH deploy key
- `((slack/webhook-url))` - Slack webhook URL

## Workflow Triggers

### Git Commit Triggers
```yaml
triggers:
  - type: git-commit
    branch: main
    pattern: "*-sandbox"  # Auto-deploy sandbox environments
```

### Schedule Triggers
```yaml
triggers:
  - type: schedule
    cron: "0 2 * * 1"  # Weekly on Monday at 2am
```

### Deployment Completion Triggers
```yaml
triggers:
  - type: deployment-complete
    pattern: "*"  # All environments
```

## Environment Progression

The example demonstrates a typical progression:

```
sandbox (auto) → preprod (manual) → prod (manual)
```

- **Sandbox**: Auto-deploys on every commit
- **Pre-Prod**: Requires manual trigger, runs after sandbox
- **Production**: Requires manual trigger, runs after preprod

## Multi-Region Deployment

The example includes parallel deployment across regions:

- **US-West**: us-west-sandbox, us-west-preprod, us-west-prod
- **US-East**: us-east-sandbox, us-east-prod

Each region can progress independently.

## Testing Integration

Smoke tests run automatically after successful deployments:

1. Login to Cloud Foundry API
2. Verify org/space listing
3. Check buildpacks availability
4. Validate service marketplace

## Maintenance Workflows

Scheduled kit updates:

1. **Check for Updates**: Query Genesis Community for new kit versions
2. **Update Kit**: Download and apply updates
3. **Run Tests**: Validate updated kit with unit tests

## Migration from Legacy Format

The compiler automatically normalizes legacy `ci.yml` to this structure:

| Legacy `ci.yml` | Multi-File Format |
|-----------------|-------------------|
| `pipeline.name` | `metadata.name` in `pipeline.yml` |
| `pipeline.vault` | `vault` section in `integrations.yml` |
| `pipeline.git` | `source_control` in `integrations.yml` |
| `pipeline.boshes` | `targets` in `targets.yml` |
| `pipeline.slack` | `notifications` in `integrations.yml` |
| `pipeline.layout` | `workflows.deploy.stages` in `pipeline.yml` |

## Configuration Checklist

### ✅ Required (Minimum Viable Pipeline)
- [ ] `pipeline.yml` with `metadata.name`, `branches.live`, `workflows`
- [ ] `targets.yml` with at least one BOSH director
- [ ] `integrations.yml` with `vault`, `source_control`, `notifications`
- [ ] Secrets in Vault for all `((...))` references

### 📋 Recommended (Production-Ready)
- [ ] Multiple environments (sandbox, preprod, prod)
- [ ] Email notifications in addition to Slack
- [ ] Auto-triggering for sandbox, manual for production
- [ ] Locker integration for deployment coordination
- [ ] Script metadata (manifest or inline annotations)

### 🎯 Advanced (Enterprise)
- [ ] Multiple workflows (deploy, test, maintenance)
- [ ] Multi-region deployment targets
- [ ] Provider-specific configuration overrides
- [ ] Scheduled maintenance workflows
- [ ] Custom scripts with full metadata

## Troubleshooting

### "Missing required 'vault' section"
→ Add `vault:` with `url` in `integrations.yml`

### "Pipeline must have at least one workflow"
→ Add workflow under `workflows:` in `pipeline.yml`

### "Target 'X' is missing 'connection.url'"
→ BOSH targets need `connection.url`, `connection.auth`, `connection.ca_cert`

### "No notification stanzas defined"
→ Add Slack or Email notification in `integrations.yml`

### Script not found
→ Scripts auto-discover from `scripts/` directory
→ Use `@genesis-script` annotations or `scripts/manifest.yml`

## See Also

- [CI Compiler Documentation](../../lib/Genesis/CI/Compiler/README.md)
- [Genesis CI System Architecture](../../lib/Genesis/CI/README.md)
- [Genesis Documentation](https://genesis-community.github.io/docs/)
