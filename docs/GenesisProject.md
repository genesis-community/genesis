# Genesis Project

Welcome to the Genesis Project! This document provides guidelines and instructions for developing the Genesis repository.

## Core Concepts

The Genesis project is a Perl package-based OOP-style software project designed to manage and deploy BOSH-based environments, specifically for the Cloud Foundry ecosystem. It provides a command-line interface (CLI) for managing various components of the environment, such as initializing deployment repositories, creating new environments, editing these environments, managing secrets, and deploying them to BOSH. It also includes a set of generic libraries for managing services used by the CLI, such as Vault, Credhub, BOSH, and Github, which are accessed through system calls to their respective CLIs. The project is designed to be modular and extensible, allowing for easy integration with other tools and services.

### Genesis Components
In order to deploy a BOSH-based environment, several components need to work together. These components include:

- The **repository (or repo for short)**, which is a collection of environments for a specific kit type. Each repo contains a set of environments, each of which is a separate deployment of the kit. The repo is managed by the `genesis` CLI and is used to create, edit, and deploy environments.

  The repo is represented by the `Genesis::Top` class, which manages the repo and access to the environments within it.  Genesis CLI commands that target repositories expect to be run from within the repo directory, or have a directory as its first argument.  Commands that operate on the repo are identified by containing the `repo` keyword in the the `scope` key (as a string, or in an arrayref) as part of the `define_command` method specified in `bin/genesis`.

- The **environment (or env for short)**, which is a specific deployment of a kit.  Each environment is represented by a directory containing the environment manifest, which describes the environment and its components.  The environment is managed by the `Genesis::Env` class, which provides methods for creating, editing, and deploying the environment.

  The environment is represented by the `Genesis::Env` class, which manages the environment and access to its components.  Genesis CLI commands that target environments expect to be run with an environment name (with or without the `.yml` suffix) from within its host repo dir, or a path to an environment file in a repo dir, as its first argument.  Commands that operate on the environment are identified by containing the `env` keyword in the the `scope` key (as a string, or in an arrayref) as part of the `define_command` method specified in `bin/genesis`.

- Hierarchical environment files, which are the way to make pushing changes from one environment to the others easier and safer.  Basically, when using hyphens in an environnment name, any file that contains shorter chains of components split by hyphens will be merged in order from shortest to longest.
  For example, if you have an environment called `foo-bar-baz`, and you have a file called `foo-bar.yml`, the contents of that file will be merged into the environment manifest before the contents of `foo-bar-baz.yml`.  This allows you to have a common set of components for all environments, and then override them in the specific environment files.  The merging is done using the `spruce` tool, which is a YAML processor that can merge multiple YAML files together.

  By keeping the general changes (and kit versions, features, etc) in the top-level environment file, and iaas or scale -specific changes in the files for the specific environments, you can easily push changes from one environment to the others without risking human-induced copying errors.  The `genesis repipe` command will create a pipeline to do this, with a correctly configured `ci.yml` file in your repo, but you can also manage this manually just by chosing to deploy more sensitive environments after validating the changes in the less sensitive environments first.

- The **kit**, which is a collection of components that make up the environment.  Each kit is available from a Kit Provider, with the most common being the Genesis Community Kit Provider, which is hosted on GitHub under the `genesis-community` organization.  It can be downloaded and installed into the local repository using the `genesis fetch-kit` command.  This provides a `compiled` kit, which is a pre-built version of the kit that is ready to be deployed.  The `genesis compile` command can be used to compile the kit into a local directory, which can then be used to create and deploy environments.  You can also
provide a `dev` kit, which is a development version of the kit that can be used to test changes before they are deployed, and can be created by using `genesis create-kit --dev` command inside the repo directory, or by using `genesis decompile-kit` command to decompile a compiled kit into the `dev` directory.

  A kit is a collection of manifest fragments, which are YAML files that describe different aspects of the environment, coupled with a set of hooks that are executed to build the environment's manifest based on the contents of the environment file.  An environment specifies which kit to use under the `kit` key, with `name` and `version` keys to specify the kit name and version, respectively.  In addition, the `kit` key supports a `iaas` keys to specify the IaaS provider to calibrate the kit for (defaults to whatever the environment's BOSH director is configured for), a `scale` key to specify the sizing of the environment (`dev` and `prod` are the only currently supported values), and a `features` key to specify a list of features to enable in the kit.

  The kit is represented by the `Genesis::Kit` class, which manages the kit and access to its components.  Genesis CLI commands that target kits expect to be run with a kit name (with or without the `.yml` suffix) from within its host repo dir, or a path to a kit file in a repo dir, as its first argument.  Commands that operate on the kit are identified by containing the `kit` keyword in the the `scope` key (as a string, or in an arrayref) as part of the `define_command` method specified in `bin/genesis`.

- ** kit hooks**, which are scripts or modules that are executed at various points in an envronment's lifecycle.  These hooks are used to perform tasks involved in managing the environment based on the kit type.  The hooks are located in the `hooks/` directory of the kit, and although they can be written in any language, the most common are BASH and Genesis-flavoured Perl, as this provides some added functionality.

  Every kit has at least one hook, `blueprint`, which is responsible for gathering the list of kit features specified under `kit.features` in the environment file, validating them, and then making the appropriate decisions about which manifest fragments to include and in what order.  Other hooks include:
  - `check` - runs before the environment is deployed, or when the `genesis check` command is run.  This hook is used to validate the environment and its components, and can be used to perform any necessary checks before the deployment is started.
  - `cloud-config` - runs before the environment is deployed, and is used to generate the cloud config for the environment.  This hook is used to generate the cloud config based on the environment and its components, and can be used to perform any necessary checks before the deployment is started.  It specifically takes into account the IaaS provider and the environment size.  **WARNING**: Only environments that use the `ocfp` feature are supported, but support for `classic` environments is planned for the future.
  - `cloud-config-director` - a special cloud config that gets installed on the BOSH director itself after it is deployed, containing the basic compilation vms, azs, and networks.
  - `cpi-config` - runs before the environment is deployed, and is used to generate the CPI config for the environment.  This hook is used to generate the CPI config based on the environment and its components, and can be used to perform any necessary checks before the deployment is started.  This is very specific to the IaaS provider, and can be used for a BOSH director on one provider to deploy to a different provider type (ie AWS to Azure, or GCP).  **WARNING**: Only environments that use the `ocfp` feature are supported, but support for `classic` environments is planned for the future.
  - `features` - if the kit needs to do any special processing for the features specified in the environment file, such as specifying an `anti-feature` or a `glue-feature`, this hook is used to do that.
  - `pre-deploy` - runs before the environment is deployed, and is used to perform any necessary checks or process before the deployment is started.
  - `post-deploy` - runs after the environment is deployed, and is used to perform any necessary process after the deployment is started.  It is provided the result of the deployment, so it can also be used to check what went wrong if the deployment failed.
  - `addon*` - special hooks that add functionality to genesis that is specific to the kit, such as logging into the environment deployed, or performing specific maintenance tasks outside the scope of Genesis.  These are not run by default, but can be run using the `genesis <env> do <task>` command. It can be provided as a single hook with a case statement to determine which task to run (the BASH way) or a `addon-<task>~<shorthand>.pm` hook (the Perl way).

  All Perl hooks have a parent that is `Genesis::Hook` or a specialized derived class, and contain `init` and `perform` methods.  The `perform` method must return the result from `$self->done(<result>)`, to be considered completed.  The `addon` hooks have an extra method called `cmd_details` which returns a string that describes the command, used by `genesis <env> do list` to display the available commands.

## Directory Overview

Most of the code is located under the `lib/` directory, especially under `lib/Genesis/`, which contains the core components of the Genesis Project.  The `bin/` directory contains the main executable scripts for managing and deploying Genesis environments.  There are also directories for documentation (`docs/`), and ci configuration (`ci/`), though alternative support for github actions is planned in the future (under the `github/` directory), and a `t/` directory for tests (more on that below).

The `lib/` directory is broken down into several subdirectory trees, each of which contains modules that are related to a specific aspect of the Genesis Project or supporting componernts.  The subdirectories are as follows:
- **`lib/Genesis/`**: Core modules for the Genesis Project:
  - **`Command.pm`**: Implements the command-line interface processing and command execution, as well as generating help text for the CLI.
  - **`Command/`**: Contains command classes for different functional groups (e.g., `Genesis::Command::Env`, `Genesis::Command::Kit`, etc.).  Each of these classes implements specific commands for the topic they are related to, and are linked via the `define_command` method in `Genesis::Command` as called by the `bin/genesis` script:
    - **`Bosh.pm`**: Implements the command-line interface for interacting with a BOSH director associated with the environment.
    - **`Env.pm`**: Implements the command-line interface for active environment management.
    - **`Info.pm`**: Implements the command-line interface for displaying information about the specified environment.
    - **`Kit.pm`**: Implements the command-line interface for lifecycle management of Genesis kits.
    - **`Repo.pm`**: Implements the command-line interface for repository management (a repo is a collection of envronments for a specific kit type).
    - **`Core.pm`**: Implements the command-line interface for Genesis-level commands, such as `ping`, or `upgrade`.
    - **`Utility.pm`**: Provides the utility call-back commands for BASH scripts found in kit hooks to call back into Genesis for additional functionality.  These will be deprecated in the future, as BASH scripts are being phased out in favour of Perl hook modules in the kits.
    - **`Pipelines.pm`**: Implements the command-line interface for managing pipelines in the environment.  This is primarily to support Concourse pipelines for deploying environments, but is intended to be deprecated in favour of using normal Genesis commands and a git branching strategy to manage the propagation of changes through the different environment stages.
    - **`Deprecated.pm`**: Implements the command-line interface for deprecated commands that are no longer supported, but are retained for backward compatibility and to give users the information they need to migrate to the new commands.
  - **`Top.pm`**: Handles repository management and top-level operations.
  - **`Env.pm`**: Manages environment creation, inspection and lifecycle management (ie deployments, secrets creation and rotation, termination, etc).
  - **`Env/`**: Contains modules for the different aspects that make up an environment, such as:
    - **`Manifest.pm`**: Represents the environment manifest, which is a YAML file that describes the environment and its components.  There are several types of manifests, which are identified under the `Manifest` directory:
      - **`Unevaluated.pm`**: Represents the unevaluated manifest, which is a YAML file that describes the environment and its components, but does the spruce merge without evaluation (ie --skip-eval).
      - **`UnevaluatedEnvironment.pm`**: Represents the unevaluated environment manifest without the kit-provided manifest components.  It merges in any hierarchical environment files, but doing the spruce merge witout evaluation (ie --skip-eval).
      - **`Partial.pm`**: Represents the manifest partially evaluated, leaving any spruce operators that cannot be evaluated in place.  Handy when trying to debug a manifest.
      - **`PartialEnvironment.pm`**: Represents the environment manifest partially evaluated without the kit-provided manifest components, leaving any spruce operators that cannot be evaluated in place.  Handy when looking up merged environment files without the kit-provided manifest components safely.
      - **`Unredacted.pm`**: Represents the unredacted manifest, which is a YAML file that describes the environment and its components, but does not redact any sensitive information (ie passwords, etc).  This is used to generate the manifest for the environment when it is deployed.
      - **`Redacted.pm`**: Represents the redacted manifest, which is a YAML file that describes the environment and its components, but redacts any sensitive information (ie passwords, etc).  This is used to generate a safe representation of the manifest for archival storage under the repo's `.genesis/manifests` directory.
      - **`Entombed.pm`**: Represents the entombed manifest, which is a YAML file that describes the environment and its components, but redirects all secrets to Credhub queries instead of storing them in the manifest in cleartext.  Only works with BOSH-deployed environments.  This is the default `deployment` manifest for non-create-env environments.
      - **`Vaultified.pm`**: Represents the vaultified manifest, which is a YAML file that describes the environment and its components, but rewrites all Credhub queries to spruce vault operators instead.  Primariy used for kits that have upstream base manifests that use Credhub queries, as this allows the upstream manifests to take advantage of secrets lifecycle management in Vault.
      - **`VaultifiedEntombed.pm`**: Represents the vaultified entombed manifest, which is a YAML file that describes the environment and its components, but it extracts the credhub queries from the manifest and replaces them with vault operators, but then entombs the secrets back into the manifest in a way that tracks if the contents have changed since last deploy without leaking the secrets.  This is the default `deployment` manifest for vaultified environments.
    - **`ManifestProvider.pm`**: Extracts the manifest generation logic from the `Genesis::Env` class, and provides a common interface for generating manifests for different types of environments.  This is used to generate the manifest for the environment when it is deployed.
    - **`Secrets/Parser.pm`**: Parses the secrets from the kit's `kit.yml` for the environment (`Secrets/Parser/FromKit.pm`) or the Credhub secrets from the partially rendered manifest (`Secrets/Parser/FromManifest.pm`).
    - **`Secrets/Plan.pm`**: Codifies the description of all the secrets in use by the environment, and provides a common interface for managing them, including generating, validating, and rotating them.  Genesis::Env objects manage a singleton instance of this class, via the method `secrets_plan`, which is used to manage the secrets for the environment.
    - **`Secrets/Store.pm`**: Provides a common interface for accessing the secrets, for both Vault-based (`Secrets/Store/Vault.pm`) and Credhub-based (`Secrets/Store/Credhub.pm`) secrets stores.  This is used to fetch and store the secrets being managed by the Secrets::Plan singleton.

  - **`Kit.pm`**: Provides functionality for managing deployment kits.
  - **`Kit/`**: Contains modules for managing kits, including:
    - **`Compiler.pm`**: Provides functionality for compiling kits so they can be pushed up to Kit Providers, or for use in the local repo.
    - **`Compiled.pm`**: Represents a compiled kit, which is a pre-built version of the kit that is ready to be deployed.  This is used to create and deploy environments.  This gets extracted to a temporary directory whenever a genesis command needs to access the kits contents, such as building manifests, getting the secrets plan, or running hooks.
    - **`Dev.pm`**: Represents a development kit, is an uncompiled kit that exists in the repo's `dev` directory.  This is used to test kit changes before they are compiled into a released kit.  This gets copied to a temporary directory whenever a genesis command needs to access the kits contents, similar to the compiled kit.
    - **`Provider.pm`**: Base class for implementing kit providers, which are used to manage the lifecycle of kits.  This module provides the base functionality and abstract methods to provide functionality for interrogating and fetching kits from the provider.
    - **`Provider/`**: Contains modules for different kit providers (`GenesisCommunity.pm` for the Genesis Community Kit Provider, `Github.pm` for a generic GitHub org).  These implement the concrete methods that `Provider.pm` defines in abstract.
  - **`Hook.pm`**: Base class for implementing hooks in Genesis.
  - **`Hook/`**: Contains modules for different hook types, such as `Genesis::Hook::Blueprint`, `Genesis::Hook::CloudConfig`, etc.  These implement specific funtionality that is used to simplify the implementation of Perl hooks of the given type.
  - **`Service/`**: Generic libraries for managing external services like Vault, Credhub, and BOSH.
  - **`UI.pm`**: Provides user interface utilities for CLI interactions prompts and progress indicators.
  - **`Base.pm`**: Base class for all Genesis component modules (`Env`, `Top` and `Kit`), specifically for providing a generic `_memoize` method for caching the results of expensive operations.
  - **`Config.pm`**: Provides configuration management for the Genesis project, including loading and saving configuration files.
  - **`State.pm`**: Provides state management for the Genesis project, such as the state of the terminal, testing and environment variables.
  - **`Term.pm`**: Provides terminal utilities for CLI interactions, such as colorizing output and wrapping text.
  - **`Log.pm`**: Provides logging utilities for the Genesis project, including logging to files and the console.
  - **`Helpers.pm`**: Provides utility functions to BASH scripts used in kit hooks.
  - **`Secret.pm`**: Abstract base class for defining secrets in Genesis.
  - **`Secret/`**: Contains modules for different secret types, such as `Genesis::Secret::Random`, `Genesis::Secret::X509`, etc.  These implement specific functionality for generating and validating secrets of the given type.
  - **`CI/Legacy.pm`**: Provides a set of functions generating Concourse pipelines to use a cached-based system to propagate changes through chained environment, using a seed `ci.yml` file.  This will hopefully be phased out in the future in favour of using the `genesis` CLI commands to manage pipelines and jobs, and git branching strategies to manage the propagation of changes through the different environment stages.
- **`lib/IPv4.pm`**: Provides IPv4 address manipulation and validation functions for Address, Span and Range objects.
- **`lib/UUID/Tiny.pm`**: Provides UUID generation and validation functions (imbedded from https://metacpan.org/pod/UUID::Tiny)

Furthermore, the Genesis project provides a suite of tests to ensure the functionality of the components.  These tests are organized into different categories, each starting with a numeric prefix to indicate the order in which they should run.  They are found in the `t/` directory and are executed using the `prove` command.  The categories are as follows:
- **`t/00-`**: Tests for any utility functions or modules that are not specific to any particular component.
- **`t/01-`**: Tests for the non-Genesis `lib/` directory etries, which should be independent of each other (ie order of testing should not matter).
- **`t/02-`**: ** reserved for future use **.
- **`t/03-`**: ** reserved for future use **.
- **`t/04-`**: Tests for the compiling kits, which are the encapulated 'best practices' for deploying a specific component.
- **`t/05-`**: Tests for the `lib/Service/` components, which are the generic libraries for managing services used by the CLI.
- **`t/1x-`**: Tests for repository management components, such as Genesis::Top.
- **`t/2x-`**: Tests for kit management components, such as Genesis::Kit (compiled and dev), and Genesis::KitProvider::* and Genesis::Kit hooks calls.
- **`t/3x-`**: Tests for environment management components, such as Genesis::Env and its major methods.
- **`t/4x-`**: Tests for hook support, as provided by Genesis::Hook and its derived classes.
- **`t/5x-`**: Tests for the Genesis binary CLI and the Genesis::Command class and its derived classes.

- Tests without a numeric prefix are considered 'system tests', and run as calls against the `genesis` binary, or under Test::Expect.  These are mostly legacy in origin, but still provide useful test coverage, albeit very slowly (especially `t/secrets.t`).

## Coding Standards

- Before performing any code changes, ensure that any code you're checking has been indexed correctly and is not out of date.  Assume any pending copilot code changes are completed, with any changes not kept are dropped. This is to ensure that the code you're working on is up to date and that any changes you make are based on the latest version of the code.

- When performing a code review, perform static analysis to confirm that any methods called are defined for the object being called on, and that the arguments passed to the method are of the correct type and format.

- Uses tab characters for indentation, with a tab size of 2 spaces.

- **Pragma Usage**:
  - **For files under `lib/`**: Uses `v5.20`, and `warnings` (no `strict` pragma, as is implied by `use v5.20`).
  - **Signature Feature**: Files outside `lib/Genesis/` are allowed and encouraged to use `use feature 'signatures'` and `no warnings 'experimental::signatures'`

- All modules should have a vim config commentline at the bottom of the file, stating:
```
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
```

- Only uses core Perl modules, and the libraries under `lib/` - NO external CPAN dependencies. Tests are the exception to this rule, as they are not part of the core functionality of the project.

- All methods should have a descriptive fold comment at the start of the method, such as:
```perl
# method_name - brief description of what the method does {{{
sub method_name {
	...
}

# }}}
```
  The closing `# }}}` comment should be on its own line, after a blank line after the end of the method, but no blank line before the next method's fold comment.  This is to allow the method to be folded in editors that support folding, such as vim, and to provide a consistent look and feel for the code.

- In the case of a single command that is conditionally executed, prefer
```
call(
  args,
  ...
) if|unless $condition;
```
over
```
if ($condition) {
  call(
    args,
    ...
  );
}
```

- When using `Genesis::Env` lookup* methods, prefer to use // to provide the default value instead of the second argument to the method.  This is because // is a short-circuit operator, whereas the second argument to the method is always evaluated, even if the first argument is defined. This is important for performance reasons, as the second argument may be a complex expression that takes a long time to evaluate.  The exception to this is when you want to use the list context of the method, in which case you should use the second argument to the method. Even then, you can analyze the result and use //= to set the value if not defined.

- The `info`, `warning`, `error`, `notice`, `bail` and `bug` methods take the same arguments as `printf`, and are used to log messages to the console. The `info` method is used for informational messages, the `warning` method is used for warning messages, the `error` method is used for error messages, the `notice` method is used for notice messages, the `bail` method is used to bail out of a command with an error message, and the `bug` method is used to log bug reports. These are provided by `Genesis` and are never method calls on an object.

- When including any non-OOP Genesis package, such as `Genesis`, `Genesis::Term`, `Genesis::UI`, etc., an explicit list of methods to import should be used instead of importing all exported methods into the namespace, such as:
```
use Genesis::Term qw/wrap colorize bullet/;
```

- When using any non-ASCII characters in output, such as `✓`, `✗`, `✔`, `✘`, etc., the `Genesis::Term` module should be used to provide a consistent output across different terminal types. The "#\@{x}" syntax is interpreted by the `colorize` method to replace with a UTF-8 glyph for the given ascii character (ie '*' => "\x{2022}" (a bullet), or '[ ]' => "\x{25FB}" (a white square), etc.). This is used to provide a consistent output across different terminal types, and to provide a consistent look and feel for the Genesis project. `colorize` is used by all the other methods in `Genesis::Term`, and the `Genesis::Log` methods, such as `info`, `warning`, `error`, `notice`, `bail` and `bug`, so it is not needed to be called explicitly when using these methods.

## Hooks

- Perl-based hooks for kits are placed in a package `Genesis::Hook::HookType::KitType[::HookSubtype]`, where `HookType` is the type of hook (e.g., `Blueprint`, `CloudConfig`, etc.) and `KitType` is the type of kit (e.g., `BOSH`, `CF`, `Prometheus`, etc.). The `HookSubType` is optional, most often used for the specific task of an `Addon` hook.

- Perl-based hooks should not use a shebang line, but be structured as such:
  - package line, as described above
	- use pragma for `v5.20` and `warnings` : `strict` and `520` pragmas should be removed.
	- a blank line followed by the dev support line (see below) and the `use parent` statement. Any existing `use lib` line can be removed.
	- a blank line followed by the `use` statements for any Genesis modules (modules found under ./lib/ in the genesis project).
	- a blank line followed by the `use` statements for any core Perl modules (such as `File::Basename`, `File::Path`, etc.), arranged alphabetically. Non-core Perl modules should not be used, as the Genesis project is designed to be self-contained and not rely on external CPAN modules.
	- a blank line followed by the init method.
	- a blank line followed by the `perform` method, which is the main method that is called when the hook is executed.
	- perform methods should always return the result of `$self->done(<arg>)`, where `<arg>` is dependent on the Hook subtype parent.
	- any further methods that are called by the `perform` method should be defined after it, with a blank line before each method definition.
  - a blank line, followed by a `1;` and then the vim config commentline at the bottom of the file.

- Perl-based hooks always contain a dev-support line as such:
```
# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}
```
before the `use parent` statement, to ensure Language Server Protocol (LSP) support in your IDE. This is not needed for the actual hook execution, as the `GENESIS_LIB` environment variable is set by the `genesis` binary to point to the `lib/` directory of the repo.
