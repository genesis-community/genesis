# Genesis Hooks

Genesis hooks provide an extensible interface for customizing deployment behavior and commands at various stages. They allow kit authors to inject custom code that executes during different phases of the deployment lifecycle.

## Table of Contents

- [Overview](#overview)
- [The Base Hook Interface](#the-base-hook-interface)
  - [Lifecycle](#lifecycle)
  - [Common Methods](#common-methods)
- [Specialized Hook Types](#specialized-hook-types)
  - [Addon Hooks](#addon-hooks)
  - [Blueprint Hooks](#blueprint-hooks)
  - [CloudConfig Hooks](#cloudconfig-hooks)
  - [CpiConfig Hooks](#cpiconfig-hooks)
  - [Features Hooks](#features-hooks)
  - [PostDeploy Hooks](#postdeploy-hooks)
- [Creating Custom Hooks](#creating-custom-hooks)
  - [Hook Module Structure](#hook-module-structure)
  - [Required Methods](#required-methods)
- [Best Practices](#best-practices)
- [Available Utilities](#available-utilities)

## Overview

Genesis hooks are Perl modules that extend the `Genesis::Hook` base class. Each hook type serves a specific purpose in the deployment workflow. Hooks are typically packaged with Genesis kits and are invoked by Genesis during deployment operations.

## The Base Hook Interface

All hooks inherit from the `Genesis::Hook` base class, which provides common functionality and utilities.

### Lifecycle

A typical hook lifecycle follows these steps:

1. **Initialization**: The hook is instantiated with required parameters.
2. **Execution**: The hook's `perform` method is called to execute its main logic.
3. **Completion**: The hook signals completion with the `done` method.
4. **Results**: The hook's output is retrieved with the `results` method.

### Common Methods

The base `Genesis::Hook` class provides these key methods:

```perl
# All hooks should init:
sub init {
  my $class = shift;
  my $obj = $class->SUPER::init(@_);
  $obj->check_minimum_genesis_version('3.1.0');
  return $obj;
}

# All hooks need a perform.
sub perform {
  # This is defined by specific hook implementations
  return $self->done($results); # results is optional and can be anything
}

# This is used for addon hooks only:
sub cmd_details {
  return "Description of hook, including its purpose and usage.";
}
1;
```

Additional utility methods provided:

- `env`: Returns the environment object
- `kit`: Returns the kit object
- `features`: Returns the list of enabled features
- `iaas`: Returns the infrastructure as a service provider
- `want_feature($feature)`: Checks if a feature is enabled
- `check_minimum_genesis_version($version)`: Ensures Genesis version compatibility

## Specialized Hook Types

Genesis provides several specialized hook types for different aspects of deployment:

### Addon Hooks

Addon hooks (`Genesis::Hook::Addon`) provide custom commands that extend Genesis with additional functionality within a kit.

Key methods:
- `parse_options($option_definition, %defaults)`: Parses command line options
- `help(%addons)`: Displays help information for available addons
- `vault`: Accesses the secrets store

Example usage (set the kit, addon name, and kit version):
```perl
#!/usr/bin/env perl
# vim: set ts=2 sw=2 sts=2 foldmethod=marker
package Genesis::Hook::Addon::<kit-name>::<addon-name> <kit-version>;

use strict;
use warnings;
use v5.20; # Genesis min perl version is 5.20
use lib $ENV{GENESIS_LIB} // "$ENV{HOME}/.genesis/lib";
use parent qw(Genesis::Hook::Addon);
use Genesis qw/bail info warning run/; # Import Genesis utility functions as needed
use Genesis::Term qw/terminal_width/; # If used...
use Genesis::UI qw/prompt_for_boolean/; # If used...

sub perform {
  my ($self) = @_;
  # Example options parsing
	my %options = $self->parse_options([
		'json', # Output in JSON format
	],
	);

  # Main logic goes here.
  return $self->done($results);
}

sub cmd_details {
  return "Performs a custom operation on the deployment";
}
1;
```

### Blueprint Hooks

Blueprint hooks (`Genesis::Hook::Blueprint`) manage the template structure of deployments.

Key methods:
- `validate_features(@features)`: Validates that requested features are compatible
- `add_files(@files)`: Adds files to the blueprint
- `remove_files(@files)`: Removes files from the blueprint

Example:
```perl
package Genesis::Hook::Blueprint::MyKit;
use parent qw(Genesis::Hook::Blueprint);

sub perform {
  my ($self) = @_;

  # Add base files
  $self->add_files("base.yml");

  # Add feature-specific files
  $self->add_files("high-availability.yml") if $self->want_feature('ha');

  $self->{complete} = 1;
  return 1;
}
1;
```

### CloudConfig Hooks

CloudConfig hooks (`Genesis::Hook::CloudConfig`) manage BOSH cloud configurations, including networks, subnets, availability zones, VM types, and disk types.

Key methods:
- `network_definition($target, %options)`: Creates a network definition
- `vm_type_definition($target, %maps)`: Creates a VM type definition
- `disk_type_definition($target, %maps)`: Creates a disk type definition
- `build_az_definitions(%options)`: Builds availability zone definitions

This is one of the most complex hook types, handling infrastructure-specific properties for different IaaS providers.

### CpiConfig Hooks

CpiConfig hooks (`Genesis::Hook::CpiConfig`) manage Cloud Provider Interface (CPI) configurations for BOSH directors.

Key methods:
- `build_cpi_config_for_iaas(%configs)`: Builds CPI configuration for a specific IaaS
- `gather_properties(@properties)`: Gathers CPI properties from environment settings
- `cpi_entombment_path_for($key, $value)`: Generates a path for storing secrets

### Features Hooks

Features hooks (`Genesis::Hook::Features`) manage feature flags that control deployment behavior.

Key methods:
- `add_feature($feature, $enabled)`: Adds a feature flag
- `has_feature($feature)`: Checks if a feature is enabled
- `delete_feature($feature)`: Removes a feature
- `build_features_list(%opts)`: Builds a list of enabled features

Example:
```perl
package Genesis::Hook::Features::MyKit;
use parent qw(Genesis::Hook::Features);

sub perform {
  my ($self) = @_;

  # Register available features
  $self->add_feature('ha', $self->want_feature('ha'));
  $self->add_feature('prometheus', $self->want_feature('prometheus'));

  # Automatically enable dependent features
  $self->add_feature('node-exporter', 1) if $self->has_feature('prometheus');

  return $self->done($self->build_features_list());
}
1;
```

### PostDeploy Hooks

PostDeploy hooks (`Genesis::Hook::PostDeploy`) handle tasks that should occur after a deployment completes successfully.

Key methods:
- `deploy_successful`: Checks if the deployment was successful
- `update_director_network_config`: Updates the BOSH director's network configuration
- `upload_director_cpi_config`: Uploads CPI configuration to the BOSH director
- `upload_stemcells(%opts)`: Uploads stemcells to the BOSH director
- `upload_runtime_configs(%opts)`: Uploads runtime configurations

Example:
```perl
package Genesis::Hook::PostDeploy::MyKit;
use parent qw(Genesis::Hook::PostDeploy);

sub perform {
  my ($self) = @_;

  return 0 unless $self->deploy_successful;

  # Perform post-deployment tasks
  $self->update_director_network_config();
  $self->upload_director_cpi_config();
  $self->upload_stemcells();

  return $self->done(1);
}
1;
```

## Creating Custom Hooks

To create a custom hook, you need to:

1. Create a new Perl module that inherits from `Genesis::Hook` or one of its specialized subclasses
2. Implement the `perform` method
3. Return the results using the `done` method

### Hook Module Structure

A typical hook module follows this structure:

```perl
package Genesis::Hook::Type::KitName;
use strict;
use warnings;

use parent qw(Genesis::Hook::Type);
use Genesis;  # Import Genesis utility functions

sub perform {
  my ($self) = @_;

  # Implement hook logic here

  # Set completion status and return results
  return $self->done($results);
}
1;
```

### Required Methods

At minimum, a hook must implement:

- `perform`: The main execution method that implements the hook's logic

## Best Practices

1. **Validate Input**: Always check that required arguments are provided
2. **Error Handling**: Use `bail` for fatal errors and `bug` for programming errors
3. **Return Values**: Always return hook results through the `done` method
4. **Version Compatibility**: Use `check_minimum_genesis_version` if your hook requires a specific Genesis version or later
5. **Documentation**: Document your hook's purpose and behavior using `cmd_details` method
6. **Logging**: Use Genesis logging functions (`info`, `debug`, `trace`, etc.) for appropriate visibility

## Available Utilities

Hooks have access to these useful utilities:

- **Environment Access**: `$self->env` provides access to the deployment environment
- **Kit Access**: `$self->kit` provides access to the Genesis kit
- **Feature Detection**: `$self->want_feature($feature)` checks for enabled features
- **Infrastructure Detection**: `$self->iaas` returns the current IaaS provider
- **BOSH Access**: `$self->bosh` provides a connection to the BOSH director
- **Vault Access**: `$self->vault` provides access to the secrets store
- **Temporary Files**: `$self->tempfile($name)` and `$self->tempdir($name)` create temporary files and directories
- **Boolean Constants**: `$self->TRUE`, `$self->FALSE`, `$self->NULL` for JSON boolean values
- **Spruce Merge**: `$self->spruce_merge(@args)` for YAML merging operations

