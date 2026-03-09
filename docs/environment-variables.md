# Genesis Environment Variables Reference

This document outlines the environment variables used by Genesis, categorized for easier reference. Each variable is presented in a tabular format detailing its purpose, default values, and how it's set and used within the system.

## 1. Core System & Configuration
Fundamental variables controlling Genesis operation and basic configuration.

| Variable | Description | Default/Values | Set By | Used By | Notes |
|----------|-------------|----------------|--------|---------|-------|
| `GENESIS_VERSION` | Current version of Genesis being used. Set internally during startup. | - | Genesis::Init() in bin/genesis | Genesis::Commands::Env (check prereqs)<br />Genesis::Kit (version compatibility checks)<br />Genesis::Config (version checks) | - |
| `GENESIS_LIB` | Path to Genesis library directory. Can be overridden to use alternate library location. | Defaults to `bin/lib` under Genesis installation directory | bin/genesis startup | Genesis::Kit::Provider (loading kit modules)<br />Genesis::Commands (loading command modules)<br />Genesis::Top (finding library components) | - |
| `GENESIS_CONFIG_NO_CHECK` | Configuration to skip checks in Genesis. If set, disables configuration validation checks. | - | Genesis::Commands::Env::deploy | Genesis::Kit (validation skipping)<br />Genesis::Commands::Env (deploy operations) | - |
| `GENESIS_CONFIG_AUTOMATIC_UPGRADE` | Automatic upgrade configuration for Genesis. Controls automatic configuration upgrades during tests. | - | Test scripts | Test scripts (e.g., t/compiled.t, t/manifest.t) | - |
| `GENESIS_MIN_VERSION` | Specifies the minimum Genesis version required for compatibility. | - | Dynamically set or retrieved by Genesis::Env | Genesis::Helpers (compatibility checks)<br />Genesis::Env (environment compatibility)<br />Genesis::Kit (semantic versioning validation) | - |
| `GENESIS_MIN_VERSION_FOR_KIT` | Specifies the minimum Genesis version required for a specific kit. | - | Dynamically set by Genesis::Env | Genesis::Helpers (kit compatibility checks)<br />Genesis::Env (kit compatibility) | - |
| `GENESIS_USING_EMBEDDED` | Indicates that Genesis is using an embedded mode. | `1` (when applicable) | Genesis::Commands | Genesis::Commands | - |
| `GENESIS_IS_HELPING_YOU` | Indicates whether Genesis is in a "helping" mode (e.g. providing extended information or assistance). | - | Genesis::Kit or user environment | Genesis::Commands (operation control)<br />Genesis::State (state management) | - |

## 2. Output, Logging & Display Control
Variables affecting how output, logs, and terminal displays are presented.

| Variable | Description | Default/Values | Set By | Used By | Notes |
|----------|-------------|----------------|--------|---------|-------|
| `GENESIS_SHOW_TIMINGS` | Enables timing output for operations when set. Shows duration of key operations. | - | User/Environment | Genesis::Log (timing output)<br />Genesis::Commands::deploy (operation timing) | - |
| `GENESIS_NO_UTF8` | Disables UTF-8 output when set. Useful for environments with limited character support. | - | User/Environment | Genesis::Term (character output control)<br />Genesis::UI (display formatting) | - |
| `GENESIS_QUIET` | Reduces output verbosity when set. Only shows errors and critical information. | - | Command line options | Genesis::Log (output verbosity control)<br />Genesis::Commands (reduced output)<br />bin/genesis END block (log level control) | - |
| `GENESIS_LOG_STYLE` | Controls output style formatting. | Values: `plain`, `color`, `html`<br />Default: `plain` if unset | User config/Environment | Genesis::Log (output formatting)<br />Genesis::UI (display styling)<br />bin/genesis END block (log style control) | - |
| `GENESIS_OUTPUT_COLUMNS` | Controls the width of text output. | Default: 80 columns if unset | User environment / Terminal settings | /lib/Genesis/Term.pm (terminal output width)<br />Test files (simulating terminal widths) | - |
| `GENESIS_NO_BOXES` | Disables box-drawing characters in terminal output. | - | User environment | /lib/Genesis/Term.pm (terminal output formatting) | - |
| `GENESIS_NOCOLOR` | Disables colored output in terminal messages. | - | User environment | /lib/Genesis/Term.pm (color formatting control) | - |
| `GENESIS_STACK_TRACE` | Enables stack trace logging for debugging purposes. | `true` (when enabled) | User environment / Logging configuration | /lib/Genesis/Commands.pm<br />/lib/Genesis/Log.pm | - |
| `GENESIS_TRACE` | Enables trace-level logging for detailed debugging. | `true` (when enabled) | User environment / Logging configuration | /lib/Genesis/Commands.pm (trace logging setup)<br />/lib/Genesis/Helpers.pm (detailed trace output)<br />/lib/Service/Vault.pm (Vault trace logging)<br />Test files (validating trace logging) | - |
| `GENESIS_DEBUG` | Enables debug-level logging for Genesis operations. Provides detailed debugging information. | `true` (when enabled) | User environment or logging configuration | Genesis::Commands (debug logging setup)<br />Genesis::Log (log level control)<br />Test scripts (e.g., t/00-utils.t) | - |
| `GENESIS_SHOW_BOSH_CMD` | Enables the display of BOSH commands during execution. | `true` (when enabled) | User environment | /lib/Genesis/Helpers.pm | Example: `GENESIS_SHOW_BOSH_CMD="true"` |

## 3. Path & Directory Management
Variables for managing directory and file paths used by Genesis.

| Variable | Description | Default/Values | Set By | Used By | Notes |
|----------|-------------|----------------|--------|---------|-------|
| `GENESIS_CALLER_DIR` | Directory of the caller for Genesis operations. Represents the original directory where Genesis was invoked. | - | bin/genesis main() | Genesis::Env (path resolution)<br />bin/genesis (context maintenance) | This is duplicated by GENESIS_ORINATING_DIR, so we should probable only use this one|
| `GENESIS_DEPLOYMENT_ROOT` | Root directory of current deployment. Set when using @-notation for environments. | - | bin/genesis @-notation handling | Genesis::Top (repository location)<br />Genesis::Env (environment files)<br />Genesis::Commands::Pipeline (deployment paths) | - |
| `GENESIS_HOME` | Represents the home directory for Genesis. | Defaults to `$HOME` | User environment | Genesis::Commands::Core (environment setup)<br />Genesis::Pack (directory initialization) | - |
| `GENESIS_KIT_PATH` | Represents the file path to the current kit. | - | Genesis::Kit during initialization | Genesis::Env (resource location)<br />Test cases (path validation) | - |
| `GENESIS_PACK_PATH` | Represents the path for Genesis pack operations. | - | Test cases (`/t/helper.pm`) or `pack` command | `/t/helper.pm`<br />`/pack` (configures output path) | - |
| `GENESIS_ORIGINATING_DIR` | Represents the directory from which Genesis was invoked. | - | Genesis::Init | /lib/Genesis/Commands/Bosh.pm (sets working dir for BOSH)<br />/lib/Genesis/Commands/Info.pm (adjusts working dir)<br />/lib/Genesis/Env.pm (tracks dir for env ops) | Depricated; use GENESIS_CALLER_DIR |
| `GENESIS_ROOT` | Represents the root directory for Genesis operations. | - | User environment / Scripts | /lib/Genesis/Helpers.pm (configures root dir)<br />/lib/Genesis/Commands/Pipelines.pm (adjusts working dir for pipelines) | - |
| `GENESIS_ROOT_CA_PATH` | Represents the path to the root CA certificate. | - | Genesis::Env or User environment | /lib/Genesis/Helpers.pm (configures root CA path)<br />/lib/Genesis/Env/Secrets/Store/Vault.pm (retrieves path for Vault ops)<br />/lib/Genesis/Env.pm (tracks path for environment)<br />Test files (validates path handling) | - |
| `GENESIS_TOPDIR` | Represents the top-level directory for Genesis operations, primarily used in tests. | - | Test scripts (e.g., `/t/helper.pm`) | `/t/helper.pm`<br />`/t/21-hooks.t`<br />`/t/bin/vault` | Example: `GENESIS_TOPDIR="/path/to/genesis"` |
| `GENESIS_MANIFEST_FILE` | Represents the file path to the unredacted, unpruned manifest. | - | /lib/Genesis/Kit.pm | /lib/Genesis/Kit.pm (set to manifest path)<br />/lib/Genesis/Env.pm (stores unpruned manifest path) | - |
| `GENESIS_PREDEPLOY_DATAFILE` | Represents the file path containing data gathered during pre-deployment. | - | /lib/Genesis/Kit.pm | /lib/Genesis/Env.pm (stores pre-deployment data)<br />/lib/Genesis/Kit.pm (configures data file path) | - |

## 4. Command, Hook & Execution Control
Variables related to command execution, hooks, and operational flow.

| Variable | Description | Default/Values | Set By | Used By | Notes |
|----------|-------------|----------------|--------|---------|-------|
| `GENESIS_CALLBACK_BIN` | Callback binary for Genesis operations. Path to the Genesis binary for callbacks. | - | bin/genesis or user environment | Genesis::Commands (callback execution)<br />Genesis::Helpers (command execution)<br />Test scripts | Used for embedding, executing commands, and testing. |
| `GENESIS_CALL_BIN` | Represents the binary path for Genesis commands. Used for embedding and executing commands. | - | Genesis::Env or user environment | Genesis::Env (command embedding)<br />bin/genesis (command execution)<br />Test scripts | - |
| `GENESIS_CALL_ENV` | Preferred over `GENESIS_CALL`. Used for constructing environment-specific command execution. | - | Genesis::Env | Genesis::Env (environment-specific commands)<br />Genesis::Hook::PostDeploy (command construction) | - |
| `GENESIS_CALL_FULL` | Represents the full command call for Genesis. | - | Genesis::Commands during command execution | Genesis::Commands (logging incorrect command usage) | - |
| `GENESIS_KIT_HOOK` | Represents the current hook being executed for a kit. | - | Genesis::Kit during hook execution | Genesis::Helpers (hook-specific operations)<br />Genesis::Hook (hook management)<br />Genesis::Env (environment-specific hooks) | - |
| `GENESIS_COMMAND` | Represents the current command being executed. | - | Genesis::Commands | Genesis::Commands (command execution)<br />Genesis::Env (logging and command prefix construction) | - |
| `GENESIS_COMMANDS` | Represents a mapping of command names to their definitions. Used for command registration and validation. | - | Genesis::Commands | Genesis::Commands (command registration and validation) | - |
| `GENESIS_ADDON_SCRIPT` | Refers to the name of an addon script to execute during deployment. Used to specify and execute custom addon scripts. | - | Genesis::Kit or user environment | Genesis::Helpers (addon script execution)<br />Test scripts | - |
| `GENESIS_NO_MODULE_HOOKS` | Disables module hooks during operations. | - | User environment | /lib/Genesis/Helpers.pm (skips module hooks for addons)<br />/lib/Genesis/Kit.pm (prevents loading module hooks) | - |
| `GENESIS_DEPLOY_DRYRUN` | Indicates whether the deployment is a dry-run. | `true` or `false` | Genesis::Env based on deployment options | Genesis::Env (deployment control) | - |
| `GENESIS_DEPLOY_OPTIONS` | Stores a JSON representation of deployment options. | - | Genesis::Env during deployment initialization | Genesis::Env (deployment configuration) | - |
| `GENESIS_DEPLOY_RC` | Represents the return code of the BOSH deploy call. `0` indicates success, non-zero indicates failure. | - | Genesis::Kit or Genesis::Env during deployment | Genesis::Kit (return code handling)<br />Genesis::Env (deployment result processing) | - |

## 5. Environment & Kit Management
Variables for managing environment-specific configurations, kits, cloud settings, and data services like CredHub/Exodus.

| Variable | Description | Default/Values | Set By | Used By | Notes |
|----------|-------------|----------------|--------|---------|-------|
| `GENESIS_ENVIRONMENT` | Represents the name of the current environment. | - | Genesis::Env or user environment | Genesis::Helpers (environment-specific operations)<br />Genesis::Commands::Utility (environment loading)<br />Genesis::Top (environment management) | - |
| `GENESIS_ENV_IAAS` | Represents the IaaS (Infrastructure as a Service) type for the environment. | - | Genesis::Env based on the environment's configuration | Genesis::Env (IaaS-specific operations) | - |
| `GENESIS_PREFIX_TYPE` | Controls how environment prefixes are handled. | - | bin/genesis | /lib/Genesis/Commands.pm (configures prefix type for commands)<br />/lib/Genesis/Env.pm (handles prefix type for env ops)<br />/bin/genesis (sets and validates prefix types) | - |
| `GENESIS_PREFIX_SEARCH` | Represents the search pattern for environment prefixes. | - | bin/genesis | /lib/Genesis/Commands/Info.pm (handles prefix search patterns)<br />/lib/Genesis/Env.pm (configures and retrieves search patterns)<br />/bin/genesis (sets search pattern) | - |
| `GENESIS_ENV_KIT_OVERRIDE_FILES` | Represents override files for the environment's kit. | - | Genesis::Env during environment initialization | Genesis::Env (kit override handling) | - |
| `GENESIS_ENV_REF` | Represents a reference to the environment. | - | Genesis::Env during environment setup | Genesis::Env (environment reference management) | - |
| `GENESIS_ENV_SCALE` | Represents the scale of the environment. | - | Genesis::Env based on the environment's configuration | Genesis::Env (scale-specific operations) | - |
| `GENESIS_ENV_VAULT_DESCRIPTOR` | Represents the Vault descriptor for the environment. | - | Genesis::Env or user environment | Genesis::Env (Vault descriptor handling)<br />Genesis::Helpers (Vault operations) | - |
| `GENESIS_ENVIRONMENT_NAME` | Represents the name of the environment, used in logging. | - | User environment or scripts | Hooks and scripts (logging and environment identification) | - |
| `GENESIS_ENVIRONMENT_PARAMS` | Represents the parameters for the environment in JSON format. | - | Genesis::Env during environment initialization | Genesis::Env (parameter management)<br />Test cases (parameter validation) | - |
| `GENESIS_EXECUTABLE_ENVS` | Represents a configuration for executable environments. | - | Genesis::Commands based on `$Genesis::RC` configuration | Genesis::Commands (environment execution control) | - |
| `GENESIS_HONOR_ENV` | Indicates whether to honor the current environment settings. | - | User environment or CI pipelines | Service::BOSH (BOSH operations)<br />Genesis::CI::Legacy (pipeline configuration)<br />Test cases (pipeline validation) | - |
| `GENESIS_LEGACY` | Used to allow environment name mismatches and conditional checks. | - | User environment / Test scripts | /lib/Genesis/Env.pm (conditional checks for mismatches)<br />/t/pipeline.t (allows mismatches in testing) | - |
| `GENESIS_REQUESTED_FEATURES` | Represents a list of features requested for the current operation. | - | /lib/Genesis/Kit.pm | /lib/Genesis/Helpers.pm (processes features)<br />/lib/Genesis/Kit.pm (sets features for a kit)<br />/lib/Genesis/Env.pm (tracks and manages features)<br />Test files (simulating feature requests) | - |
| `GENESIS_RUNTIME_CONFIG` | Represents the runtime configuration file used during operations. | - | User environment / Deployment options | /lib/Genesis/Helpers.pm (validates and processes file) | - |
| `GENESIS_TYPE` | Represents the type of the Genesis environment. | - | User environment | /lib/Genesis/Helpers.pm<br />/lib/Genesis/Env.pm<br />Test files | Example: `GENESIS_TYPE="bosh"` |
| `GENESIS_UNEVALED_PARAMS` | Prevents parameter evaluation, typically to avoid Vault dependencies. | `1` (when enabled) | User environment | /lib/Genesis/Env/ManifestProvider.pm<br />/lib/Genesis/Commands/Kit.pm<br />/lib/Genesis/Env.pm | Example: `GENESIS_UNEVALED_PARAMS="1"` |
| `GENESIS_KIT_ID` | Represents the ID of the current kit. | - | Genesis::Kit during initialization | Genesis::Helpers (kit identification)<br />Genesis::Kit (kit management) | - |
| `GENESIS_KIT_NAME` | Represents the name of the current kit. | - | Genesis::Kit during initialization | Genesis::Helpers (kit-specific operations)<br />Genesis::Env (environment-specific operations)<br />Genesis::CI::Legacy (CI pipeline configuration) | - |
| `GENESIS_KIT_VERSION` | Represents the version of the current kit. | - | Genesis::Kit during initialization | Genesis::Helpers (version-specific operations)<br />Genesis::Env (environment-specific operations)<br />Test cases (version validation) | - |
| `GENESIS_PREFIX` | Represents the prefix used for environment-specific operations. | - | bin/genesis | /lib/Genesis/Env.pm (configures env prefixes)<br />/bin/genesis (prefix-related ops) | - |
| `GENESIS_CLOUD_CONFIG` | Represents the cloud configuration data. Used for parsing and validating cloud configuration. | - | Genesis::Helpers | Genesis::Helpers (cloud config parsing and validation) | - |
| `GENESIS_CLOUD_CONFIG_SUBTYPE` | Specifies the subtype of the cloud configuration. Used to determine appropriate cloud-config hooks. | - | Genesis::Kit or user environment | Genesis::Hook::CloudConfig (subtype handling)<br />Genesis::Kit (hook determination) | - |
| `GENESIS_OCFP_CONFIG_MOUNT` | Represents the Vault path under which all `ocfp_config` data is stored. | - | Genesis::Env | /lib/Genesis/Hook/CloudConfig/Director.pm (retrieves config data from Vault)<br />/lib/Genesis/Env.pm (provides path) | - |
| `GENESIS_CREDHUB_EXODUS_SOURCE` | Represents the source for CredHub Exodus data. Used for setting CredHub environment parameters. | - | Genesis::Env or user environment | Genesis::Env (CredHub parameter setup)<br />Genesis::Helpers (environment configuration) | - |
| `GENESIS_CREDHUB_EXODUS_SOURCE_OVERRIDE` | Overrides the default CredHub Exodus source. Used for custom CredHub configurations. | - | Genesis::Env or user environment | Genesis::Env (CredHub source override)<br />Genesis::Helpers (custom configuration handling) | - |
| `GENESIS_CREDHUB_ROOT` | Represents the root path for CredHub operations. Used for constructing CredHub paths. | - | Genesis::Env or user environment | Genesis::Env (path construction)<br />Genesis::Helpers (CredHub operations) | - |
| `GENESIS_EXODUS` | Related to Exodus data handling. Used for retrieving and managing Exodus data paths. | - | Genesis::Env or user environment | Genesis::Helpers (Exodus data operations)<br />Genesis::Env (data path management) | - |
| `GENESIS_EXODUS_BASE` | Represents the full Vault path of the Exodus data for the environment. | - | Genesis::Env during environment initialization | Genesis::Env (Vault path construction)<br />Test cases (path validation) | - |
| `GENESIS_EXODUS_MOUNT` | Represents the Vault path under which all Exodus data is stored. | - | Genesis::Env during environment initialization | Genesis::Helpers (Vault path operations)<br />Genesis::Env (data storage management) | - |
| `GENESIS_EXODUS_MOUNT_OVERRIDE` | Overrides the default Exodus mount point. | - | User environment or Genesis::Env | Genesis::Helpers (custom mount handling)<br />Test cases (override validation) | - |
| `GENESIS_CHECK_YAML_ON_DEPLOY` | Enables YAML validation during deployment. Ensures YAML files are valid before deployment. | - | User environment or deployment options | Genesis::Env (YAML validation control) | - |
| `GENESIS_CONFIRM_RELEASE_OVERRIDES` | Controls confirmation behavior for release overrides. Specifies how release overrides are handled. | - | User environment | Genesis::Top (release override confirmation) | - |
| `GENESIS__LOOKUP_MERGED_MANIFEST` | Enables or checks for merged manifest lookup functionality. Controls whether merged manifests are retrieved. | - | User environment | Genesis::Commands::Info (manifest lookup control) | - |

## 6. BOSH Integration
All BOSH-related variables for interacting with BOSH directors and deployments.

| Variable | Description | Default/Values | Set By | Used By | Notes |
|----------|-------------|----------------|--------|---------|-------|
| `GENESIS_BOSH_COMMAND` | Path to the BOSH command binary used by Genesis. Used to override default BOSH command. | - | Test scripts or user environment | Service::BOSH (command execution)<br />Test scripts | - |
| `GENESIS_BOSH_ENVIRONMENT` | URI of the BOSH environment to target. Specifies the BOSH environment for operations. | - | Command-line options or user environment | Genesis::Commands (environment setup)<br />Genesis::Env (environment validation and usage) | - |
| `GENESIS_DEFAULT_BOSH_TARGET` | Default BOSH target when not explicitly specified. | Values: `parent`, `self` | Genesis::Commands::Env bosh operations | Genesis::BOSH (target resolution)<br />Genesis::Commands::deploy (BOSH operations) | - |
| `GENESIS_BOSH_VERIFIED` | Tracks whether a BOSH alias has been verified. Ensures the correct BOSH alias is being used. | - | Genesis::Helpers during alias verification | Genesis::Helpers (alias verification logic)<br />Service::BOSH::Director (validation checks) | - |
| `GENESIS_BOSHVARS_FILE` | Path to a file containing BOSH variables. Provides additional variables for BOSH operations. | - | Genesis::Kit or user environment | Genesis::Kit (variable file handling)<br />Genesis::Env (variable file usage) | - |
| `GENESIS_USE_CREATE_ENV` | Indicates whether to use the `create-env` command for BOSH deployments. | `true` (when applicable) | User environment / Scripts | /lib/Genesis/Helpers.pm<br />/lib/Genesis/Hook.pm<br />/lib/Genesis/Env.pm<br />Test files | Example: `GENESIS_USE_CREATE_ENV="true"` |

## 7. Vault & Secrets Management
Variables for Vault interaction and general secret management.

| Variable | Description | Default/Values | Set By | Used By | Notes |
|----------|-------------|----------------|--------|---------|-------|
| `GENESIS_TARGET_VAULT` | Target Vault for operations. Represents the target Vault URL. | - | User environment / bin/genesis | /lib/Genesis/Helpers.pm<br />/lib/Service/Vault/Remote.pm<br />/lib/Service/Vault.pm<br />/lib/Genesis/Top.pm<br />/lib/Genesis/Env.pm<br />/bin/genesis | Example: `GENESIS_TARGET_VAULT="https://vault.example.com"` |
| `GENESIS_SECRETS_MOUNT` | Represents the Vault mount path for secrets. | Default: `/` (within Vault) or as configured | Genesis::Env / User environment | /lib/Genesis/Helpers.pm<br />/lib/Service/Vault.pm<br />/lib/Genesis/Env.pm<br />Test files | Example: `GENESIS_SECRETS_MOUNT="/vault/mount"` |
| `GENESIS_NO_VAULT` | Disables Vault integration. | - | Environment settings | /lib/Genesis/Commands.pm (configures Vault usage)<br />/lib/Genesis/Top.pm (skips Vault ops) | - |
| `GENESIS_SECRETS_BASE` | Represents the base Vault path for secrets. | - | User environment | /lib/Genesis/Helpers.pm<br />/lib/Genesis/Env.pm<br />Test files | Example: `GENESIS_SECRETS_BASE="/vault/secrets/base"` |
| `GENESIS_SECRETS_MOUNT_OVERRIDE` | Allows overriding the default secrets mount. | `true` (when enabled) | User environment | /lib/Genesis/Helpers.pm<br />Test files | Example: `GENESIS_SECRETS_MOUNT_OVERRIDE="true"` |
| `GENESIS_SECRETS_SLUG` | Represents the component of the Vault path under the mount for the environment. | - | User environment | /lib/Genesis/Helpers.pm<br />/lib/Genesis/Env.pm<br />Test files | Example: `GENESIS_SECRETS_SLUG="env-slug"` |
| `GENESIS_SECRETS_SLUG_OVERRIDE` | Allows overriding the default secrets slug. | `true` (when enabled) | User environment | /lib/Genesis/Helpers.pm<br />/lib/Genesis/Env.pm<br />Test files | Example: `GENESIS_SECRETS_SLUG_OVERRIDE="true"` |
| `GENESIS_VAULT_ENV_SLUG` | Represents the Vault slug for the environment. | - | User environment | /lib/Genesis/Env.pm<br />Test files | Example: `GENESIS_VAULT_ENV_SLUG="base/extended"` |
| `GENESIS_VERIFY_VAULT` | Indicates whether the Vault connection has been verified. | `1` (when verified) | Genesis::Env | /lib/Genesis/Env.pm<br />Test files | Example: `GENESIS_VERIFY_VAULT="1"` |
| `GENESIS_SECRET_ACTION` | Defines the action to be performed on secrets (e.g., add, rotate, check). | - | /lib/Genesis/Kit.pm | Various hooks and tests | Example: `GENESIS_SECRET_ACTION="add"` |
| `GENESIS_RENEW_SUBJECT` | Determines whether to update the subject of a certificate during renewal. | - | User environment | /lib/Genesis/Secret/X509.pm (checks and updates subject) | - |
| `GENESIS_HIDE_PROBLEMATIC_SECRETS` | Controls whether problematic secrets are hidden from output. | - | User environment | Genesis::Secret (secret-related message visibility) | - |
| `GENESIS_SECRETS_DATAFILE` | Refers to the file path for storing secrets. | - | /lib/Genesis/Kit.pm | /lib/Genesis/Kit.pm | Example: `GENESIS_SECRETS_DATAFILE="/path/to/secrets/file"` |
| `GENESIS_SKIP_SECRET_DEFINITION_VALIDATION` | Skips validation of secret definitions. | `true` (when enabled) | User environment | /lib/Genesis/Secret.pm | Example: `GENESIS_SKIP_SECRET_DEFINITION_VALIDATION="true"` |

## 8. CI/CD Pipeline Variables
Pipeline-related configuration for Continuous Integration and Continuous Deployment.

| Variable | Description | Default/Values | Set By | Used By | Notes |
|----------|-------------|----------------|--------|---------|-------|
| `GENESIS_PIPELINE_DEPLOY_BRANCH` | Git branch for pipeline deployments. Used by CI pipeline operations. | - | Genesis::Commands::Pipeline::repipe | Genesis::CI (pipeline configuration)<br />Genesis::Commands::Pipeline (deployment) | - |
| `GENESIS_CI` | Indicates if Genesis is running in a CI environment. Used to adjust behavior for CI/CD pipelines. | - | CI/CD environment | Genesis::CI::Legacy (pipeline generation) | - |
| `GENESIS_CI_BASE` | Base path for CI-related secrets and configurations in Vault. Used to organize CI-specific data. | - | Genesis::Env (based on genesis.ci_base lookup) | Genesis::Env (Vault path construction)<br />Genesis::CI::Legacy (pipeline configuration) | - |
| `GENESIS_CI_DIR` | Directory containing CI-related scripts and configurations. Used to locate CI-specific resources. | - | ci/repipe script | ci/repipe (script execution) | - |
| `GENESIS_CI_MOUNT` | Mount point for CI-related secrets and configurations in Vault. Used to access CI-specific data. | Default: `/` | Genesis::Env | Genesis::Env (Vault path construction) | - |
| `GENESIS_CI_MOUNT_OVERRIDE` | Overrides the default CI mount point in Vault. Allows customization of the CI Vault path. | - | Genesis::Env (based on environment configuration) | Genesis::Env (Vault path construction) | - |

## 9. Testing & Development
Variables used specifically during testing and development phases.

| Variable | Description | Default/Values | Set By | Used By | Notes |
|----------|-------------|----------------|--------|---------|-------|
| `GENESIS_DEV_MODE` | Enables development mode features. | - | User environment | Various development-specific code paths | - |
| `GENESIS_UNDER_TEST` | Indicates Genesis is running under test harness. | - | Test harness/scripts | Various modules to alter behavior for testing | - |
| `GENESIS_TESTING` | Indicates that Genesis is running in a testing mode. | `yes` (when applicable) | Test scripts / helper.pm | Multiple modules (Commands, State, Term, Kit, BOSH, Env)<br />/t/helper.pm, /t/pipeline.t | Example: `GENESIS_TESTING="yes"` |
| `GENESIS_IGNORE_EVAL` | Prevents evaluation from catching exits in test cases. | - | Test scripts or user environment | Test cases (evaluation control) | - |
| `GENESIS_INDEX` | Represents an index-related configuration for Genesis, typically for testing. | - | Test scripts or user environment | Test cases (index configuration validation) | - |
| `GENESIS_EXPECT_TRACE` | Used for enabling trace logging in test cases. | - | Test scripts or user environment | Test cases (trace logging control) | - |
| `GENESIS_TEST_VAULT_VERSION` | Specifies the version of the test Vault. | - | /t/bin/vault (test utility) | /t/bin/vault | Example: `GENESIS_TEST_VAULT_VERSION="1.0.2"` |
| `GENESIS_TESTING_BOSH_CPI` | Specifies a custom BOSH CPI for testing purposes. | - | Test scripts | /lib/Genesis/Commands.pm<br />/lib/Genesis/Helpers.pm | Example: `GENESIS_TESTING_BOSH_CPI="warden"` |
| `GENESIS_TESTING_CHECK_SECRETS_PRESENCE_ONLY` | Controls whether only the presence of secrets is checked during testing. | `true` (when enabled) | Test scripts | /lib/Genesis/Env.pm | Example: `GENESIS_TESTING_CHECK_SECRETS_PRESENCE_ONLY="true"` |
| `GENESIS_TESTING_DEV_VERSION_DETECTION` | Enables or disables development version detection during testing. | `false` (to disable) | Test scripts | /lib/Genesis/Env.pm<br />/lib/Genesis/Kit.pm | Example: `GENESIS_TESTING_DEV_VERSION_DETECTION="false"` |

## 10. Miscellaneous & Deprecated
Variables that are deprecated or don't fit neatly into other categories.

| Variable | Description | Default/Values | Set By | Used By | Notes |
|----------|-------------|----------------|--------|---------|-------|
| `GENESIS_CALL` | Deprecated in favor of `GENESIS_CALL_ENV`. Used for command execution with fallback. | - | Genesis::Env | Genesis::Env (command execution)<br />Genesis::Hook::PostDeploy (command fallback) | Deprecated. |
| `GENESIS_SECRETS_PATH` | Represents the path for secrets. | - | User environment | /lib/Genesis/Env.pm<br />/docs/writing-a-hooks-new.md<br />Test files | Deprecated in v2.7.0. Example: `GENESIS_SECRETS_PATH="/path/to/secrets"` |
| `GENESIS_VAULT_PREFIX` | Represents the Vault prefix. | - | User environment | /lib/Genesis/Kit.pm<br />/lib/Genesis/Env.pm<br />Test files | Deprecated in v2.7.0. Example: `GENESIS_VAULT_PREFIX="base/extended/thing"` |
| `GENESIS_NETWORK_TIMEOUT` | Sets a timeout value for network operations. | Default: 10 seconds | User environment / Default | /lib/Service/BOSH/Director.pm (configures network timeout) | - |


