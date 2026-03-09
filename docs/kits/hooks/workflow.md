# Genesis Kit Hook Deployment Workflow

This document describes the complete execution order and logic of Genesis kit hooks during deployment operations.

## Overview

Genesis kit hooks provide extension points throughout the deployment lifecycle. When you run `genesis deploy`, Genesis orchestrates a series of hooks in a specific order to validate, configure, deploy, and post-process your environment.

## Hook Execution Order

The following hooks are executed in this specific sequence during a deployment:

### 1. Features Hook (`hooks/features`)

- **When**: Called early during environment initialization when features are being resolved
- **Purpose**: Processes and validates kit features, can add derived features based on other features
- **Condition**: Only executed if the hook exists
- **Called by**: `$env->features()` method when determining the environment's feature set
- **Input**: List of explicitly declared features from the environment file
- **Output**: Modified feature list with any derived features added

### 2. Blueprint Hook (`hooks/blueprint`) - **REQUIRED**

- **When**: Called when determining which manifest files need to be merged
- **Purpose**: Returns the ordered list of YAML files to combine based on enabled features
- **Condition**: **Always required** - Genesis will fail without this hook
- **Called by**: `$kit->source_yaml_files()` via `$env->kit_files()`
- **Input**: Environment object with resolved features
- **Output**: Array of file paths to merge for the manifest
- **Note**: This is the only mandatory hook - all kits must provide it

### 3. Check Hook (`hooks/check`)

- **When**: During the pre-deployment validation phase
- **Purpose**: Validates environment configuration, parameters, and requirements
- **Condition**: Optional, only runs if the hook exists
- **Called during**: Environment viability check (`_check_environment_viability`)
- **Input**: Full environment configuration
- **Output**: Success/failure status
- **Use cases**: Verify required parameters, check for incompatible settings

### 4. CPI-config Hook (`hooks/cpi-config`)

- **When**: Before deployment if CPI configuration is needed
- **Purpose**: Generates Cloud Provider Interface configuration for BOSH director
- **Condition**: Only for environments with CPI enabled (typically BOSH directors)
- **Special**: Primarily used for BOSH director deployments
- **Input**: Environment's CPI settings
- **Output**: CPI configuration YAML

### 5. Cloud-config Hook (`hooks/cloud-config`)

- **When**: Before deployment to check/generate cloud configurations
- **Purpose**: Generates cloud configuration including networks, availability zones, VM types, and disk types
- **Condition**: Only if hook exists and environment is not using create-env
- **Variants**: 
  - `cloud-config` - for regular deployment cloud configs
  - `cloud-config-director` - for BOSH director's own cloud config (uploaded in post-deploy)
- **Input**: IaaS-specific parameters from environment
- **Output**: Cloud configuration YAML and network mappings

### 6. Pre-deploy Hook (`hooks/pre-deploy`)

- **When**: After manifest generation, immediately before BOSH deployment
- **Purpose**: Final preparation steps before deployment, can generate data for post-deploy
- **Condition**: Optional, only runs if the hook exists
- **Input**: Generated manifest path and vars file
- **Output**: Optional data to pass to post-deploy hook
- **Use cases**: Final validations, external system preparations

### 7. BOSH Deployment (not a hook)

At this point, Genesis executes the actual BOSH deployment command:
- `bosh deploy` for regular deployments
- `bosh create-env` for create-env deployments

### 8. Post-deploy Hook (`hooks/post-deploy`)

- **When**: After deployment completes (whether successful or failed)
- **Purpose**: Post-deployment tasks, cleanup, and configuration uploads
- **Condition**: Optional, only runs if the hook exists
- **Receives**: 
  - Deployment result code (success/failure)
  - Data from pre-deploy hook (if any)
  - Interactive flag (for user prompts)
- **Special tasks for BOSH directors**:
  - Uploads `cloud-config-director` if present
  - Uploads `runtime-config` if present
  - Uploads CPI config if needed
  - Updates stemcells and releases

### 9. Runtime-config Hook (`hooks/runtime-config`)

- **When**: Called from within the post-deploy hook for BOSH directors
- **Purpose**: Generates and uploads runtime configuration to the director
- **Condition**: Only for BOSH director deployments when the hook exists
- **Note**: Not called independently - always invoked as part of post-deploy
- **Input**: Director configuration parameters
- **Output**: Runtime configuration YAML

## Additional Hooks (Context-Dependent)

These hooks are not part of the standard deployment workflow but are triggered by specific commands:

### Addon Hooks (`hooks/addon-*`)
- **Triggered by**: `genesis do <env> -- <addon>`
- **Purpose**: Provide custom commands and operations
- **Examples**: `ssh`, `login`, `upload-stemcells`, custom scripts

### Info Hook (`hooks/info`)
- **Triggered by**: `genesis info <env>`
- **Purpose**: Display environment-specific information
- **Output**: Human-readable information about the deployment

### Secrets Hook (`hooks/secrets`)
- **Triggered by**: Secret management commands
- **Purpose**: Define secret generation and rotation specifications
- **Used by**: `genesis add-secrets`, `genesis rotate-secrets`, etc.

### New Hook (`hooks/new`)
- **Triggered by**: `genesis new <env>`
- **Purpose**: Customize new environment creation
- **Use cases**: Generate environment-specific configurations

## Important Notes

### Hook Requirements
1. **Blueprint is mandatory** - Genesis will fail without it
2. All other hooks are optional
3. Hooks must be executable files in the kit's `hooks/` directory
4. Hooks can be written in Bash or Perl

### Execution Context
1. **Features hook** runs very early to determine the final feature set
2. **Cloud/runtime configs** for directors are uploaded during post-deploy, not before
3. **Post-deploy always runs** even on deployment failure (for cleanup)
4. **Create-env deployments** skip certain hooks (cloud-config, runtime-config)

### Data Flow
1. Features determine which blueprint files are selected
2. Blueprint determines manifest structure
3. Check validates the configuration
4. Pre-deploy can pass data to post-deploy
5. Post-deploy receives deployment results

## Workflow Diagram

See [workflow.mermaid](workflow.mermaid) for a visual representation of the hook execution flow.

## Best Practices

1. **Keep hooks idempotent** - They may be run multiple times
2. **Handle failures gracefully** - Provide clear error messages
3. **Use pre-deploy/post-deploy data passing** - For cleanup on failure
4. **Validate early** - Use check hook to catch issues before deployment
5. **Document hook behavior** - Especially for addon hooks

## Examples

### Minimal Kit Structure
```
my-genesis-kit/
├── kit.yml
└── hooks/
    └── blueprint     # Required: determines manifest files
```

### Full-Featured Kit Structure
```
my-genesis-kit/
├── kit.yml
└── hooks/
    ├── blueprint     # Required: determines manifest files
    ├── features      # Optional: process features
    ├── check         # Optional: validate configuration
    ├── pre-deploy    # Optional: pre-deployment tasks
    ├── post-deploy   # Optional: post-deployment tasks
    ├── info          # Optional: display information
    ├── secrets       # Optional: secret specifications
    └── addon-*       # Optional: custom commands
```

### BOSH Director Kit Structure
```
bosh-genesis-kit/
├── kit.yml
└── hooks/
    ├── blueprint            # Required: determines manifest files
    ├── features             # Process BOSH-specific features
    ├── check                # Validate BOSH configuration
    ├── cloud-config         # Generate cloud config for deployments
    ├── cloud-config-director # Generate director's own cloud config
    ├── runtime-config       # Generate runtime config
    ├── cpi-config          # Generate CPI config
    ├── pre-deploy          # Pre-deployment preparations
    └── post-deploy         # Upload configs to director
```