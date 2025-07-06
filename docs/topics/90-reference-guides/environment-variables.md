# Environment Variables Reference

This document provides a comprehensive reference for all environment variables used by Genesis, organized by category for easier navigation.

## Core System & Configuration

These fundamental variables control Genesis operation and basic configuration.

### GENESIS_VERSION
- **Description**: Current version of Genesis being used. Set internally during startup.
- **Default**: Set automatically
- **Used By**: Version compatibility checks, prerequisite validation
- **Example**: `GENESIS_VERSION="2.8.0"`

### GENESIS_LIB
- **Description**: Path to Genesis library directory. Can be overridden to use alternate library location.
- **Default**: `bin/lib` under Genesis installation directory
- **Used By**: Loading kit modules, command modules, library components
- **Example**: `GENESIS_LIB="/opt/genesis/lib"`

### GENESIS_CONFIG_NO_CHECK
- **Description**: Skip configuration validation checks when set.
- **Used By**: Kit validation, deployment operations
- **Example**: `GENESIS_CONFIG_NO_CHECK=1`

### GENESIS_CONFIG_AUTOMATIC_UPGRADE
- **Description**: Controls automatic configuration upgrades during tests.
- **Values**: `no`, `yes`, `silent`
- **Used By**: Test scripts, configuration management
- **Example**: `GENESIS_CONFIG_AUTOMATIC_UPGRADE=yes`

### GENESIS_MIN_VERSION
- **Description**: Minimum Genesis version required for compatibility.
- **Used By**: Compatibility checks, environment validation
- **Example**: `GENESIS_MIN_VERSION="2.7.0"`

### GENESIS_MIN_VERSION_FOR_KIT
- **Description**: Minimum Genesis version required for a specific kit.
- **Used By**: Kit compatibility validation
- **Example**: `GENESIS_MIN_VERSION_FOR_KIT="2.8.0"`

### GENESIS_USING_EMBEDDED
- **Description**: Indicates Genesis is using embedded mode.
- **Default**: `1` when applicable
- **Used By**: Command execution, state management

### GENESIS_IS_HELPING_YOU
- **Description**: Enables extended help and assistance mode.
- **Used By**: Operation control, state management

## Output, Logging & Display Control

Variables affecting output formatting, logging, and terminal display.

### GENESIS_SHOW_TIMINGS
- **Description**: Show duration of key operations when set.
- **Used By**: Timing output, operation monitoring
- **Example**: `GENESIS_SHOW_TIMINGS=1`

### GENESIS_NO_UTF8
- **Description**: Disable UTF-8 output for limited character support environments.
- **Used By**: Character output control, display formatting
- **Example**: `GENESIS_NO_UTF8=1`

### GENESIS_QUIET
- **Description**: Reduce output verbosity, showing only errors and critical information.
- **Used By**: Output control across all commands
- **Example**: `GENESIS_QUIET=1`

### GENESIS_LOG_STYLE
- **Description**: Control output style formatting.
- **Values**: `plain`, `color`, `html`
- **Default**: `plain`
- **Example**: `GENESIS_LOG_STYLE=color`

### GENESIS_OUTPUT_COLUMNS
- **Description**: Control width of text output.
- **Default**: `80` columns
- **Used By**: Terminal output formatting
- **Example**: `GENESIS_OUTPUT_COLUMNS=120`

### GENESIS_NO_BOXES
- **Description**: Disable box-drawing characters in terminal output.
- **Used By**: Terminal formatting
- **Example**: `GENESIS_NO_BOXES=1`

### GENESIS_NOCOLOR
- **Description**: Disable colored output in terminal messages.
- **Used By**: Color formatting control
- **Example**: `GENESIS_NOCOLOR=1`

### GENESIS_STACK_TRACE
- **Description**: Enable stack trace logging for debugging.
- **Values**: `true` when enabled
- **Used By**: Error reporting, debugging
- **Example**: `GENESIS_STACK_TRACE=true`

### GENESIS_TRACE
- **Description**: Enable trace-level logging for detailed debugging.
- **Values**: `true` when enabled
- **Used By**: Detailed trace output, Vault operations
- **Example**: `GENESIS_TRACE=true`

### GENESIS_DEBUG
- **Description**: Enable debug-level logging for Genesis operations.
- **Values**: `true` when enabled
- **Used By**: Debug logging, test scripts
- **Example**: `GENESIS_DEBUG=true`

### GENESIS_SHOW_BOSH_CMD
- **Description**: Display BOSH commands during execution.
- **Values**: `true` when enabled
- **Example**: `GENESIS_SHOW_BOSH_CMD=true`

## Path & Directory Management

Variables for managing directories and file paths.

### GENESIS_CALLER_DIR
- **Description**: Directory where Genesis was originally invoked.
- **Used By**: Path resolution, context maintenance
- **Note**: Preferred over deprecated GENESIS_ORIGINATING_DIR

### GENESIS_DEPLOYMENT_ROOT
- **Description**: Root directory of current deployment.
- **Set When**: Using @-notation for environments
- **Used By**: Repository location, environment files

### GENESIS_HOME
- **Description**: Home directory for Genesis.
- **Default**: `$HOME`
- **Used By**: Environment setup, directory initialization

### GENESIS_KIT_PATH
- **Description**: File path to the current kit.
- **Set By**: Kit initialization
- **Used By**: Resource location, path validation

### GENESIS_PACK_PATH
- **Description**: Path for Genesis pack operations.
- **Used By**: Pack command, test cases

### GENESIS_ORIGINATING_DIR (Deprecated)
- **Description**: Directory from which Genesis was invoked.
- **Status**: Deprecated - use GENESIS_CALLER_DIR instead

### GENESIS_ROOT
- **Description**: Root directory for Genesis operations.
- **Used By**: Root directory configuration, pipeline adjustments

### GENESIS_ROOT_CA_PATH
- **Description**: Path to root CA certificate.
- **Used By**: CA path configuration, Vault operations

### GENESIS_TOPDIR
- **Description**: Top-level directory for Genesis operations.
- **Used By**: Test scripts
- **Example**: `GENESIS_TOPDIR="/path/to/genesis"`

### GENESIS_MANIFEST_FILE
- **Description**: Path to unredacted, unpruned manifest.
- **Set By**: Kit during manifest generation

### GENESIS_PREDEPLOY_DATAFILE
- **Description**: File path for pre-deployment data.
- **Used By**: Pre-deployment data storage

## Command, Hook & Execution Control

Variables controlling command execution and hooks.

### GENESIS_CALLBACK_BIN
- **Description**: Path to Genesis binary for callbacks.
- **Used By**: Command execution, embedding

### GENESIS_CALL_BIN
- **Description**: Binary path for Genesis commands.
- **Used By**: Command embedding and execution

### GENESIS_CALL_ENV
- **Description**: Environment-specific command execution.
- **Note**: Preferred over deprecated GENESIS_CALL

### GENESIS_CALL_FULL
- **Description**: Full command call for Genesis.
- **Used By**: Command logging

### GENESIS_KIT_HOOK
- **Description**: Current hook being executed.
- **Used By**: Hook-specific operations

### GENESIS_COMMAND
- **Description**: Current command being executed.
- **Used By**: Command execution and logging

### GENESIS_COMMANDS
- **Description**: Mapping of command names to definitions.
- **Used By**: Command registration and validation

### GENESIS_ADDON_SCRIPT
- **Description**: Name of addon script to execute.
- **Used By**: Addon script execution

### GENESIS_NO_MODULE_HOOKS
- **Description**: Disable module hooks during operations.
- **Used By**: Hook loading control

### GENESIS_DEPLOY_DRYRUN
- **Description**: Indicates deployment is a dry-run.
- **Values**: `true` or `false`

### GENESIS_DEPLOY_OPTIONS
- **Description**: JSON representation of deployment options.
- **Set By**: Deployment initialization

### GENESIS_DEPLOY_RC
- **Description**: Return code of BOSH deploy call.
- **Values**: `0` for success, non-zero for failure

## Environment & Kit Management

Variables for environment configurations and kit management.

### GENESIS_ENVIRONMENT
- **Description**: Name of current environment.
- **Used By**: Environment-specific operations
- **Example**: `GENESIS_ENVIRONMENT="us-east-prod"`

### GENESIS_ENV_IAAS
- **Description**: Infrastructure as a Service type.
- **Values**: `aws`, `azure`, `gcp`, `vsphere`, etc.
- **Example**: `GENESIS_ENV_IAAS="aws"`

### GENESIS_PREFIX_TYPE
- **Description**: How environment prefixes are handled.
- **Used By**: Prefix configuration

### GENESIS_PREFIX_SEARCH
- **Description**: Search pattern for environment prefixes.
- **Used By**: Prefix search operations

### GENESIS_ENV_KIT_OVERRIDE_FILES
- **Description**: Override files for environment's kit.
- **Used By**: Kit override handling

### GENESIS_ENV_REF
- **Description**: Reference to the environment.
- **Used By**: Environment reference management

### GENESIS_ENV_SCALE
- **Description**: Scale of the environment.
- **Used By**: Scale-specific operations

### GENESIS_ENV_VAULT_DESCRIPTOR
- **Description**: Vault descriptor for environment.
- **Used By**: Vault operations

### GENESIS_ENVIRONMENT_NAME
- **Description**: Environment name for logging.
- **Used By**: Hooks and scripts

### GENESIS_ENVIRONMENT_PARAMS
- **Description**: Environment parameters in JSON format.
- **Used By**: Parameter management

### GENESIS_EXECUTABLE_ENVS
- **Description**: Configuration for executable environments.
- **Used By**: Environment execution control

### GENESIS_HONOR_ENV
- **Description**: Honor current environment settings.
- **Used By**: BOSH operations, CI pipelines

### GENESIS_LEGACY
- **Description**: Allow environment name mismatches.
- **Used By**: Conditional checks, testing

### GENESIS_REQUESTED_FEATURES
- **Description**: List of requested features.
- **Used By**: Feature processing and management

### GENESIS_RUNTIME_CONFIG
- **Description**: Runtime configuration file path.
- **Used By**: Runtime config validation

### GENESIS_TYPE
- **Description**: Type of Genesis environment.
- **Example**: `GENESIS_TYPE="bosh"`

### GENESIS_UNEVALED_PARAMS
- **Description**: Prevent parameter evaluation.
- **Values**: `1` when enabled
- **Example**: `GENESIS_UNEVALED_PARAMS=1`

### GENESIS_KIT_ID
- **Description**: ID of current kit.
- **Used By**: Kit identification

### GENESIS_KIT_NAME
- **Description**: Name of current kit.
- **Used By**: Kit-specific operations
- **Example**: `GENESIS_KIT_NAME="concourse"`

### GENESIS_KIT_VERSION
- **Description**: Version of current kit.
- **Used By**: Version-specific operations
- **Example**: `GENESIS_KIT_VERSION="4.0.0"`

### GENESIS_PREFIX
- **Description**: Prefix for environment operations.
- **Used By**: Environment prefixes

### GENESIS_CLOUD_CONFIG
- **Description**: Cloud configuration data.
- **Used By**: Cloud config parsing

### GENESIS_CLOUD_CONFIG_SUBTYPE
- **Description**: Subtype of cloud configuration.
- **Used By**: Cloud-config hook determination

### GENESIS_OCFP_CONFIG_MOUNT
- **Description**: Vault path for ocfp_config data.
- **Used By**: Config data retrieval

### GENESIS_CREDHUB_EXODUS_SOURCE
- **Description**: Source for CredHub Exodus data.
- **Used By**: CredHub parameter setup

### GENESIS_CREDHUB_EXODUS_SOURCE_OVERRIDE
- **Description**: Override default CredHub Exodus source.
- **Used By**: Custom CredHub configurations

### GENESIS_CREDHUB_ROOT
- **Description**: Root path for CredHub operations.
- **Used By**: CredHub path construction

### GENESIS_EXODUS
- **Description**: Exodus data handling.
- **Used By**: Exodus data operations

### GENESIS_EXODUS_BASE
- **Description**: Full Vault path of Exodus data.
- **Used By**: Vault path construction

### GENESIS_EXODUS_MOUNT
- **Description**: Vault path for Exodus data storage.
- **Used By**: Data storage management

### GENESIS_EXODUS_MOUNT_OVERRIDE
- **Description**: Override default Exodus mount point.
- **Used By**: Custom mount handling

### GENESIS_CHECK_YAML_ON_DEPLOY
- **Description**: Enable YAML validation during deployment.
- **Used By**: YAML validation control

### GENESIS_CONFIRM_RELEASE_OVERRIDES
- **Description**: Control release override confirmation.
- **Used By**: Release override handling

### GENESIS__LOOKUP_MERGED_MANIFEST
- **Description**: Enable merged manifest lookup.
- **Used By**: Manifest lookup control

## BOSH Integration

Variables for BOSH director interaction.

### GENESIS_BOSH_COMMAND
- **Description**: Path to BOSH command binary.
- **Used By**: BOSH command execution
- **Example**: `GENESIS_BOSH_COMMAND="/usr/local/bin/bosh"`

### GENESIS_BOSH_ENVIRONMENT
- **Description**: URI of BOSH environment.
- **Used By**: Environment setup and validation
- **Example**: `GENESIS_BOSH_ENVIRONMENT="https://10.0.0.6:25555"`

### GENESIS_DEFAULT_BOSH_TARGET
- **Description**: Default BOSH target selection.
- **Values**: `parent`, `self`, `ask`
- **Default**: `ask`

### GENESIS_BOSH_VERIFIED
- **Description**: Track BOSH alias verification.
- **Used By**: Alias verification logic

### GENESIS_BOSHVARS_FILE
- **Description**: Path to BOSH variables file.
- **Used By**: Variable file handling

### GENESIS_USE_CREATE_ENV
- **Description**: Use create-env for deployments.
- **Values**: `true` when applicable
- **Example**: `GENESIS_USE_CREATE_ENV=true`

## Vault & Secrets Management

Variables for Vault and secret handling.

### GENESIS_TARGET_VAULT
- **Description**: Target Vault URL.
- **Used By**: Vault operations
- **Example**: `GENESIS_TARGET_VAULT="https://vault.example.com"`

### GENESIS_SECRETS_MOUNT
- **Description**: Vault mount path for secrets.
- **Default**: `/` within Vault
- **Example**: `GENESIS_SECRETS_MOUNT="/secret"`

### GENESIS_NO_VAULT
- **Description**: Disable Vault integration.
- **Used By**: Vault usage configuration

### GENESIS_SECRETS_BASE
- **Description**: Base Vault path for secrets.
- **Example**: `GENESIS_SECRETS_BASE="/secret/genesis"`

### GENESIS_SECRETS_MOUNT_OVERRIDE
- **Description**: Override default secrets mount.
- **Values**: `true` when enabled

### GENESIS_SECRETS_SLUG
- **Description**: Vault path component for environment.
- **Example**: `GENESIS_SECRETS_SLUG="us-east-prod"`

### GENESIS_SECRETS_SLUG_OVERRIDE
- **Description**: Override default secrets slug.
- **Values**: `true` when enabled

### GENESIS_VAULT_ENV_SLUG
- **Description**: Vault slug for environment.
- **Example**: `GENESIS_VAULT_ENV_SLUG="base/extended"`

### GENESIS_VERIFY_VAULT
- **Description**: Vault connection verification status.
- **Values**: `1` when verified

### GENESIS_SECRET_ACTION
- **Description**: Action to perform on secrets.
- **Values**: `add`, `rotate`, `check`
- **Example**: `GENESIS_SECRET_ACTION="rotate"`

### GENESIS_RENEW_SUBJECT
- **Description**: Update certificate subject during renewal.
- **Used By**: Certificate renewal operations

### GENESIS_HIDE_PROBLEMATIC_SECRETS
- **Description**: Hide problematic secrets from output.
- **Used By**: Secret visibility control

### GENESIS_SECRETS_DATAFILE
- **Description**: File path for storing secrets.
- **Example**: `GENESIS_SECRETS_DATAFILE="/tmp/secrets.yml"`

### GENESIS_SKIP_SECRET_DEFINITION_VALIDATION
- **Description**: Skip secret definition validation.
- **Values**: `true` when enabled

### GENESIS_SECRETS_PATH (Deprecated)
- **Description**: Path for secrets.
- **Status**: Deprecated in v2.7.0
- **Note**: Use GENESIS_SECRETS_BASE instead

### GENESIS_VAULT_PREFIX (Deprecated)
- **Description**: Vault prefix.
- **Status**: Deprecated in v2.7.0
- **Note**: Use GENESIS_SECRETS_BASE instead

## CI/CD Pipeline Variables

Variables for continuous integration and deployment.

### GENESIS_PIPELINE_DEPLOY_BRANCH
- **Description**: Git branch for pipeline deployments.
- **Used By**: CI pipeline operations

### GENESIS_CI
- **Description**: Indicates CI environment.
- **Used By**: Pipeline behavior adjustment

### GENESIS_CI_BASE
- **Description**: Base path for CI secrets in Vault.
- **Used By**: CI-specific data organization

### GENESIS_CI_DIR
- **Description**: Directory containing CI scripts.
- **Used By**: CI resource location

### GENESIS_CI_MOUNT
- **Description**: Mount point for CI secrets.
- **Default**: `/`

### GENESIS_CI_MOUNT_OVERRIDE
- **Description**: Override default CI mount point.
- **Used By**: Custom CI Vault paths

## Testing & Development

Variables for testing and development.

### GENESIS_DEV_MODE
- **Description**: Enable development mode features.
- **Used By**: Development-specific code paths

### GENESIS_UNDER_TEST
- **Description**: Running under test harness.
- **Used By**: Test behavior modifications

### GENESIS_TESTING
- **Description**: Running in testing mode.
- **Values**: `yes` when applicable
- **Example**: `GENESIS_TESTING=yes`

### GENESIS_IGNORE_EVAL
- **Description**: Prevent evaluation catching exits.
- **Used By**: Test evaluation control

### GENESIS_INDEX
- **Description**: Index-related test configuration.
- **Used By**: Test index validation

### GENESIS_EXPECT_TRACE
- **Description**: Enable trace logging in tests.
- **Used By**: Test trace control

### GENESIS_TEST_VAULT_VERSION
- **Description**: Version of test Vault.
- **Example**: `GENESIS_TEST_VAULT_VERSION="1.0.2"`

### GENESIS_TESTING_BOSH_CPI
- **Description**: Custom BOSH CPI for testing.
- **Example**: `GENESIS_TESTING_BOSH_CPI="warden"`

### GENESIS_TESTING_CHECK_SECRETS_PRESENCE_ONLY
- **Description**: Only check secret presence in tests.
- **Values**: `true` when enabled

### GENESIS_TESTING_DEV_VERSION_DETECTION
- **Description**: Control dev version detection.
- **Values**: `false` to disable

## Miscellaneous

Other variables and settings.

### GENESIS_NETWORK_TIMEOUT
- **Description**: Network operation timeout.
- **Default**: `10` seconds
- **Used By**: Network timeout configuration

### GENESIS_CALL (Deprecated)
- **Description**: Command execution.
- **Status**: Deprecated - use GENESIS_CALL_ENV

## Usage Examples

### Enable Full Debugging
```bash
export GENESIS_DEBUG=true
export GENESIS_TRACE=true
export GENESIS_STACK_TRACE=true
export GENESIS_SHOW_BOSH_CMD=true
genesis deploy my-env
```

### CI/CD Pipeline Setup
```bash
export GENESIS_CI=true
export GENESIS_CI_BASE="/secret/ci"
export GENESIS_PIPELINE_DEPLOY_BRANCH="main"
export GENESIS_QUIET=1
```

### Development Environment
```bash
export GENESIS_DEV_MODE=1
export GENESIS_TESTING=yes
export GENESIS_SHOW_TIMINGS=1
export GENESIS_LOG_STYLE=color
```

### Vault Configuration
```bash
export GENESIS_TARGET_VAULT="https://vault.example.com:8200"
export GENESIS_SECRETS_MOUNT="/secret"
export GENESIS_SECRETS_BASE="/secret/genesis/prod"
```

## Best Practices

1. **Use Configuration File**: For persistent settings, use `~/.genesis/config` instead of environment variables
2. **Debugging**: Enable trace and debug only when needed to avoid verbose output
3. **CI/CD**: Set appropriate variables in pipeline configurations
4. **Security**: Avoid exposing sensitive values in environment variables
5. **Documentation**: Document custom environment variable usage in your deployment repos