# Processing Options in Addon Hooks

Genesis addon hooks support command-line option processing through the `parse_options` method provided by the `Genesis::Hook::Addon` base class. This allows your addon hooks to accept and validate command-line arguments in a standardized way.

## Overview

The `parse_options` method uses Perl's `Getopt::Long` module to parse command-line arguments passed to your addon hook. It provides automatic validation and error handling for unknown options.

## Basic Usage

### Method Signature

```perl
my %options = $self->parse_options(\@option_definitions, %default_values);
# or
my $options = $self->parse_options(\@option_definitions, %default_values);
```

### Parameters

- `\@option_definitions` - Array reference containing Getopt::Long option specifications
- `%default_values` - Hash of universal default values (optional)

### Return Values

- In list context: Returns a hash of parsed options
- In scalar context: Returns a hash reference of parsed options

**Note:** Universal defaults (values that don't depend on other arguments or environment configuration) should be specified in the `parse_options` call during `init`. Dynamic defaults should be applied later in `perform`.

## Option Definition Format

Option definitions follow the `Getopt::Long` specification format:

```perl
[
    'flag',           # Simple boolean flag
    'name=s',         # String option with required value
    'count=i',        # Integer option with required value
    'size=f',         # Float option with required value
    'file=s@',        # Array of strings
    'verbose+',       # Incremental counter
    'output=s{1,3}',  # 1-3 string values
]
```

### Common Option Types

| Format | Description | Example Usage |
|--------|-------------|---------------|
| `flag` | Boolean flag | `--flag` |
| `name=s` | Required string | `--name value` |
| `count=i` | Required integer | `--count 42` |
| `size=f` | Required float | `--size 3.14` |
| `name=s@` | Array of strings | `--name val1 --name val2` |
| `verbose+` | Incremental counter | `-v`, `-vv`, `-vvv` |
| `config=s%` | Hash of key=value pairs | `--config key1=val1 --config key2=val2` |

## Complete Example

Here's a comprehensive example based on the Stratos addon hook:

```perl
package Genesis::Hook::Addon::CF::Stratos;

use v5.20;
use warnings;
use parent qw(Genesis::Hook::Addon);

sub init {
    my $class = shift;
    my $obj = $class->SUPER::init(@_);
    $obj->check_minimum_genesis_version('3.1.0');

    # Parse options with universal defaults during initialization
    my %options = $obj->parse_options(
        [
            'json',             # Output in JSON format
            'urls-only',        # Only display URLs
            'force',            # Force redeployment
            'skip-cf-check',    # Skip CF CLI availability check
            'file=s',           # Path to Stratos zip file
            'version=s',        # Stratos version to deploy
            'buildpack=s',      # Buildpack to use
            'stack=s',          # Stack to use
            'memory=s',         # Memory allocation
            'disk=s',           # Disk allocation
            'timeout=i',        # Application startup timeout
        ],
        # Universal defaults (not dependent on other arguments/config)
        buildpack => 'binary_buildpack',
        stack     => 'cflinuxfs4',
        memory    => '1512M',
        disk      => '1024M',
        timeout   => 180,
    );

    $obj->{options} = \%options;
    return $obj;
}

sub perform {
    my ($self) = @_;
    my %options = %{ $self->{options} };

    # Dynamic defaults that depend on environment or other factors
    my $version = $options{version} 
               // $self->env->lookup('stratos.version', '4.9.2');

    # Use the parsed options
    if ($options{json}) {
        # Output in JSON format
    }
    
    if ($options{force}) {
        # Force operation
    }
    
    # Universal defaults are already applied from init
    info("Using buildpack: %s", $options{buildpack});
    info("Using stack: %s", $options{stack});
    info("Using memory: %s", $options{memory});
    
    # ... rest of implementation
}
```

## Error Handling

The `parse_options` method automatically handles common errors:

### Unknown Options

If unknown options are passed, the method will bail with an error message:

```
genesis env-name addon-name --unknown-option
# Error: Unknown option(s) passed to addon-name: --unknown-option
```

### Invalid Option Values

Invalid values for typed options (integers, floats) will cause Getopt::Long to fail:

```
genesis env-name addon-name --timeout abc
# Error parsing command line arguments
```

## Best Practices

### 1. Parse Options in `init` Method with Universal Defaults

Always parse options in the `init` method and specify universal defaults:

```perl
sub init {
    my $class = shift;
    my $obj = $class->SUPER::init(@_);
    
    my %options = $obj->parse_options(
        [
            'force',
            'version=s',
            'timeout=i',
            'memory=s',
        ],
        # Universal defaults (not dependent on arguments or environment)
        timeout => 180,
        memory  => '1G',
    );
    
    $obj->{options} = \%options;
    return $obj;
}
```

### 2. Apply Dynamic Defaults in `perform` Method

Apply defaults that depend on environment configuration or other arguments in `perform`:

```perl
sub perform {
    my ($self) = @_;
    my %options = %{ $self->{options} };
    
    # Dynamic defaults that depend on environment lookup
    my $version = $options{version}
               // $self->env->lookup('addon.version', '1.0.0');
    
    # Universal defaults are already applied from init
    # Use options directly...
    info("Using timeout: %d seconds", $options{timeout});
    info("Using memory: %s", $options{memory});
}
```

### 3. Document Options in `cmd_details`

Always document available options in your `cmd_details` method:

```perl
sub cmd_details {
    return 
        "Deploy and manage the Stratos UI application.\n\n" .
        "Deploy Options:\n" .
        "  --buildpack <name>  Buildpack to use (default: binary_buildpack)\n" .
        "  --disk <size>       Disk allocation (default: 1024M)\n" .
        "  --file <path>       Path to Stratos zip file\n" .
        "  --force             Force redeployment\n" .
        "  --memory <size>     Memory allocation (default: 1512M)\n" .
        "  --timeout <seconds> Application startup timeout (default: 180)\n" .
        "  --version <ver>     Stratos version to deploy\n\n" .
        "Display Options:\n" .
        "  --json              Output information in JSON format\n" .
        "  --urls-only         Only display URLs\n";
}
```

### 4. Distinguish Between Universal and Dynamic Defaults

**Universal defaults** should be specified in `parse_options` during `init`:
- Fixed values that never change
- Values not dependent on environment configuration
- Values not dependent on other command-line arguments

**Dynamic defaults** should be applied in `perform`:
- Values that depend on environment configuration
- Values that depend on other command-line arguments
- Values that require complex logic to determine

```perl
# Universal defaults in init
my %options = $obj->parse_options(
    ['timeout=i', 'retries=i'],
    timeout => 30,    # Always 30 unless overridden
    retries => 3,     # Always 3 unless overridden
);

# Dynamic defaults in perform
my $version = $options{version}                           # Command line
           // $self->env->lookup('addon.version')         # Environment config
           // $self->get_latest_version();                 # Complex logic
```

## Advanced Usage

### Working with Array Options

```perl
my %options = $self->parse_options([
    'exclude=s@',  # Can be specified multiple times
]);

# Usage: genesis env addon --exclude item1 --exclude item2
my @excluded = @{ $options{exclude} || [] };
```

### Working with Hash Options

```perl
my %options = $self->parse_options([
    'env=s%',  # Key=value pairs
]);

# Usage: genesis env addon --env KEY1=val1 --env KEY2=val2
my %environment = %{ $options{env} || {} };
```

### Incremental Options

```perl
my %options = $self->parse_options([
    'verbose+',  # Can be specified multiple times for increased verbosity
]);

# Usage: genesis env addon -v, -vv, -vvv
my $verbosity = $options{verbose} || 0;
```

## Integration with Environment Configuration

Combine command-line options with environment configuration:

```perl
sub perform {
    my ($self) = @_;
    my %options = %{ $self->{options} };
    my $env = $self->env;
    
    # Command line takes precedence over environment config
    my $version = $options{version} 
               // $env->lookup('stratos.version', '4.9.2');
    
    my $memory = $options{memory}
              // $env->lookup('stratos.memory', '1512M');
    
    # Use the resolved values...
}
```

This approach provides a flexible and user-friendly way to configure addon behavior through both environment files and command-line options.