# Blueprint Hook Feature Validation Tutorial

Genesis kits allow users to customize their deployments through "features" - simple flags that enable or disable functionality. As a kit author, you need to validate these features to ensure users don't specify invalid combinations, use deprecated features, or make configuration mistakes that would cause deployment failures.

This tutorial will walk you through implementing robust feature validation in your Genesis kit using the built-in validation framework.

## Why Feature Validation Matters

Without proper validation, users can:
- Specify features that don't exist, leading to confusing deployment failures
- Use deprecated features without knowing they should migrate
- Combine incompatible features that create conflicts
- Miss required parameters for complex features

Good validation provides clear, helpful error messages that guide users to fix their environment files before deployment time.

## Getting Started: Basic Feature Validation

The simplest validation just checks that requested features are valid. Let's start with a basic example:

```perl
# In your blueprint hook's perform method
sub perform {
    my ($self) = @_;

    # Validate features - this automatically stores raw features
    # and sets the final curated feature list
    $self->validate_features(
        valid_features => [qw/
            small-footprint
            external-db
            tls
            self-signed
        /]
    );

    # Now process the validated features...
    if ($self->want_feature('external-db')) {
        $self->add_files('operations/external-db.yml');
    }
		...

    return $self->done();
}
```

This basic validation will:
- Accept any of the listed features
- Reject unknown features with helpful error messages
- Allow custom operations files from the environment's `ops/` directory

**What happens without validation?**
```yaml
# environment.yml - user makes a typo
features:
  - small-footrpint  # typo in "small-footprint"
```

Without validation, this would silently be ignored, potentially causing the user to wonder why their small footprint configuration isn't working. With validation, they get a clear error: `Invalid feature requested: small-footrpint`.

## Understanding Feature Processing Flow

When you call `validate_features()`, here's what happens:

1. **Raw features stored**: The original feature list is automatically saved to `$self->{raw_features}`
2. **Feature validation**: Each feature is checked against your validation rules
3. **Curation**: Valid features are collected, deprecated features are processed
4. **Final list set**: `$self->set_features()` is called with the curated list, which can contain features that were replaced or modified during validation due to deprecation migrations.

This means after validation, when you call `$self->want_feature()` or `$self->features()`, you're working with the clean, validated feature set.

## Handling Deprecated Features

As your kit evolves, you'll need to deprecate old features. The validation framework makes this smooth for users by providing automatic migration and clear messaging.

### Basic Deprecation Examples

```perl
$self->validate_features(
    valid_features      => [qw/tls self-signed external-db/],
    deprecated_features => {
        # Simple replacement - old feature becomes new feature
        'legacy-tls' => 'tls',

        # Multiple replacement - one feature becomes several
        'haproxy-tls' => ['haproxy', 'tls'],

        # Feature now default - warn but don't add anything
        'enable-dns' => [],

        # Feature removed - error with explanation
        'old-experimental' => undef,
    }
);
```

### Advanced Deprecation with Custom Messages

```perl
deprecated_features => {
    # Replacement with explanation
    'minimum-vms' => {
        msg => '- use small-footprint for better resource optimization',
        replace => 'small-footprint'
    },

    # Feature automatically applied
    'azure-support' => {
        msg => '- automatically enabled when deploying to Azure',
        replace => []
    },

    # Invalid feature with helpful guidance
    'unsupported-db' => {
        msg => 'This database type is no longer supported. Use external-db with params.db_type instead'
        # No 'replace' key = invalid feature with custom error
    }
}
```

**User Experience:**
When a user specifies `legacy-tls`, they see:
```
The legacy-tls feature has been replaced with tls
```

When they specify `azure-support`:
```
The azure-support feature is now the default behaviour - automatically enabled when deploying to Azure
```

This helps users understand what's happening and how to update their configurations.

## Mutually Exclusive Features

Some features shouldn't be used together. The validation framework can enforce these constraints automatically.

### Why Mutual Exclusion Matters

Consider database features - a user shouldn't be able to specify both `local-postgres-db` and `external-mysql-db` because they conflict:

```perl
$self->validate_features(
    valid_features              => [qw/
        local-postgres-db
        local-mysql-db
        external-postgres-db
        external-mysql-db
    /],
    mutually_exclusive_features => {
        'database-type' => [qw/
            local-postgres-db
            local-mysql-db
            external-postgres-db
            external-mysql-db
        /]
    }
);
```

**Without mutual exclusion:**
```yaml
# User accidentally specifies both
features:
  - local-postgres-db
  - external-postgres-db
```

This would create conflicting manifest operations, leading to deployment failures. With mutual exclusion, the user gets a clear error: `Cannot set multiple database-type features: local-postgres-db, external-postgres-db`.

### Grouping Related Features

You can have multiple mutual exclusion groups:

```perl
mutually_exclusive_features => {
    'database' => [qw/local-postgres-db local-mysql-db external-db/],
    'sizing'   => [qw/small-footprint medium-footprint large-footprint/],
    'tls'      => [qw/self-signed provided-certs no-tls/]
}
```

This prevents conflicts across different aspects of configuration while allowing valid combinations like `small-footprint` + `external-db` + `self-signed`.  Features can appear in multiple groups, allowing for complex configurations without conflicts.

## Custom Validation Logic

Sometimes you need validation that goes beyond simple feature lists. The framework supports custom validation through the `warnings` and `errors` parameters.

### Parameter-Dependent Validation

```perl
sub validate_classic_features {
    my ($self) = @_;

    # Custom validation before calling validate_features
    my (@warnings, @errors) = ();

    # Check required parameters
    if ($self->want_feature('external-db')) {
        push @errors, "Feature 'external-db' requires params.db_host to be defined"
            unless $self->env->lookup('params.db_host');

        push @errors, "Feature 'external-db' requires params.db_username to be defined"
            unless $self->env->lookup('params.db_username');
    }

    # Conditional warnings
    if ($self->want_feature('legacy-mode')) {
        push @warnings, "Feature 'legacy-mode' will be removed in the next major version";
    }

    # IaaS-specific validation
    if ($self->want_feature('azure-disk-type')) {
        push @errors, "Feature 'azure-disk-type' only valid on Azure IaaS"
            unless $self->iaas eq 'azure';
    }

    $self->validate_features(
        valid_features => \@valid_features,
        warnings       => \@warnings,
        errors         => \@errors
    );
}
```

This continues to build a comprehensive list of warnings and errors, using the `validate_features` reporting output, while allowing you to perform complex validation that considers:
- Environment parameters
- IaaS type
- Feature combinations
- External dependencies

## IaaS-Conditional Features

Many kits need different features for different infrastructure providers:

```perl
sub validate_classic_features {
    my ($self) = @_;

    # Base features available on all platforms
    my @valid_features = qw/
        small-footprint
        external-db
        tls
        self-signed
    /;

    # Add IaaS-specific features
    if ($self->iaas eq 'aws') {
        push @valid_features, qw/
            aws-iam-instance-profiles
            aws-elb-integration
            aws-s3-blobstore
        /;
    } elsif ($self->iaas eq 'azure') {
        push @valid_features, qw/
            azure-managed-disks
            azure-load-balancer
            azure-blob-storage
        /;
    } elsif ($self->iaas eq 'gcp') {
        push @valid_features, qw/
            gcp-service-accounts
            gcp-load-balancer
            gcp-cloud-storage
        /;
    }

    $self->validate_features(
        valid_features => \@valid_features
    );
}
```

This ensures users only see relevant features for their target infrastructure.

## Supporting Upstream Operations Files

Most kits don't need upstream operations file support - it's primarily useful for kits that incorporate external projects like cf-deployment. Here's when and how to use it.

### When You Need Upstream Support

You should only implement upstream support if:
- Your kit incorporates operations files from an external project
- Users need to specify these external operations as features
- The external operations files change frequently

The cf-genesis-kit is the primary example - it incorporates cf-deployment and allows users to specify cf-deployment operations as features like `cf-deployment/operations/use-postgres`.

### Configuring Upstream Support

```perl
sub init {
    my $class = shift;
    my $obj = $class->SUPER::init(@_);
    $obj->check_minimum_genesis_version('3.1.0');

    # Only configure if you actually need upstream support
    $obj->{upstream_dir} = '.';  # Where upstream files are located
    $obj->{upstream_pattern_match} = qr/^cf-deployment\/operations\/(.*)$/;

    return $obj;
}
```

With this configuration:
- Feature `cf-deployment/operations/use-postgres` looks for file `./cf-deployment/operations/use-postgres.yml`
- If the file exists, the feature is valid
- If not, it's rejected with a helpful error

**Without upstream support** (the default for most kits):
```perl
# This is all you need - no upstream configuration
sub init {
    my $class = shift;
    my $obj = $class->SUPER::init(@_);
    $obj->check_minimum_genesis_version('3.1.0');
    return $obj;
}
```

## Custom Operations Files

The validation framework automatically supports custom operations files from the environment's `ops/` directory. This gives users flexibility without requiring validation changes.

### How It Works

When a feature isn't found in your valid features list or deprecated features, the validator checks:

1. **Upstream pattern** (if configured) - `cf-deployment/operations/custom-op`
2. **Environment ops files** - `ops/custom-feature.yml`

If either exists, the feature is considered valid.

### User Experience

```yaml
# User's environment file
features:
  - standard-feature      # From your valid_features list
  - my-custom-tweak       # Will look for ops/my-custom-tweak.yml
```

This lets users add custom functionality without requiring kit updates, while still getting validation for standard features.

## Complete Real-World Example

Here's a comprehensive example showing multiple validation concepts:

```perl
package Genesis::Hook::Blueprint::MyApp v2.0.0;

use v5.20;
use warnings;

BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}
use parent qw(Genesis::Hook::Blueprint);

use Genesis qw/info warning error bail/;

sub init {
    my $class = shift;
    my $obj = $class->SUPER::init(@_);
    $obj->check_minimum_genesis_version('3.1.0');

    # This kit doesn't need upstream support - most don't
    # $obj->{upstream_dir} and $obj->{upstream_pattern_match} left undefined

    return $obj;
}

sub perform {
    my ($self) = @_;

    # Route to appropriate validation based on deployment type
    if ($self->want_feature('enterprise')) {
        $self->validate_enterprise_features();
        return $self->process_enterprise_features();
    } else {
        $self->validate_standard_features();
        return $self->process_standard_features();
    }
}

sub validate_standard_features {
    my ($self) = @_;

    # Pre-validation custom checks
    my (@warnings, @errors) = ();

    # Parameter-dependent validation
    if ($self->want_feature('external-auth')) {
        my $auth_url = $self->env->lookup('params.auth_url');
        push @errors, "Feature 'external-auth' requires params.auth_url"
            unless $auth_url;

        push @warnings, "External auth URL should use HTTPS"
            if $auth_url && $auth_url !~ /^https:/;
    }

    # Build feature list with IaaS-specific additions
    my @valid_features = qw/
        small-footprint
        medium-footprint
        large-footprint
        external-db
        local-postgres-db
        local-mysql-db
        tls
        self-signed
        external-auth
        monitoring
    /;

    # Add cloud-specific features
    push @valid_features, 'aws-iam' if $self->iaas eq 'aws';
    push @valid_features, 'azure-managed-identity' if $self->iaas eq 'azure';
    push @valid_features, 'gcp-service-account' if $self->iaas eq 'gcp';

    $self->validate_features(
        valid_features              => \@valid_features,
        deprecated_features         => {
            # Simple migrations
            'legacy-db'      => 'external-db',
            'minimum-vms'    => 'small-footprint',

            # Multiple feature replacement
            'secure-setup'   => ['tls', 'external-auth'],

            # Features now enabled by default
            'basic-monitoring' => {
                msg => '- monitoring is now enabled by default',
                replace => []
            },

            # Removed features with guidance
            'experimental-feature' => {
                msg => 'This feature was experimental and has been removed. Use standard configuration instead.'
                # No replace = invalid feature
            },

            # Cloud-specific deprecation
            'legacy-aws-auth' => {
                msg => '- use aws-iam feature for better security',
                replace => 'aws-iam'
            }
        },
        mutually_exclusive_features => {
            'sizing'    => [qw/small-footprint medium-footprint large-footprint/],
            'database'  => [qw/external-db local-postgres-db local-mysql-db/],
            'tls-mode'  => [qw/tls self-signed/]
        },
        warnings                    => \@warnings,
        errors                      => \@errors
    );
}

sub validate_enterprise_features {
    my ($self) = @_;

    # Enterprise has different features and constraints
    $self->validate_features(
        valid_features              => [qw/
            enterprise
            high-availability
            disaster-recovery
            external-db
            ldap-auth
            saml-auth
            monitoring
            audit-logging
        /],
        deprecated_features         => {
            'basic-auth' => {
                msg => '- enterprise deployments require external authentication',
                replace => 'ldap-auth'
            }
        },
        mutually_exclusive_features => {
            'auth-type' => [qw/ldap-auth saml-auth/]
        }
    );
}

# Processing methods would follow...
sub process_standard_features {
    my ($self) = @_;

    # Add base files
    $self->add_files('base.yml');

    # Process sizing
    if ($self->want_feature('small-footprint')) {
        $self->add_files('operations/small-footprint.yml');
    } elsif ($self->want_feature('large-footprint')) {
        $self->add_files('operations/large-footprint.yml');
    }
    # medium-footprint is default, no extra files needed

    # Database configuration
    if ($self->want_feature('external-db')) {
        $self->add_files('operations/external-db.yml');
        $self->add_files('operations/external-db-tls.yml') if $self->want_feature('tls');
    } elsif ($self->want_feature('local-mysql-db')) {
        $self->add_files('operations/local-mysql.yml');
    }
    # local-postgres-db is default

    return $self->done();
}

1;
```

## Testing Your Validation

Good validation requires thorough testing. Test these scenarios:

### Valid Configurations
```yaml
# Test basic valid features
features: [small-footprint, tls, external-db]

# Test IaaS-specific features
features: [aws-iam, external-db]  # on AWS

# Test custom ops files
features: [standard-feature, my-custom-ops]  # with ops/my-custom-ops.yml
```

### Invalid Configurations
```yaml
# Test typos
features: [small-footrpint]  # Should error clearly

# Test mutual exclusion
features: [small-footprint, large-footprint]  # Should error

# Test parameter dependencies
features: [external-auth]  # Without params.auth_url should error
```

### Deprecated Features
```yaml
# Test deprecation warnings
features: [legacy-db]  # Should warn and migrate to external-db

# Test removed features
features: [experimental-feature]  # Should error with helpful message
```

## Advanced Topics

### Version-Specific Validation

```perl
# Check kit version for feature availability
my $kit_version = $self->kit->metadata->{version};
push @valid_features, 'new-feature' if new_enough($kit_version, '2.1.0');
```

### Environment-Type Specific Features

```perl
# Different features for different environment types
my @valid_features = qw/base-feature/;
if ($self->env->type eq 'production') {
    push @valid_features, qw/high-availability disaster-recovery/;
} elsif ($self->env->type eq 'development') {
    push @valid_features, qw/debug-mode fast-startup/;
}
```

### Complex Parameter Validation

```perl
# Validate parameter combinations
if ($self->want_feature('cluster-mode')) {
    my $nodes = $self->env->lookup('params.cluster_nodes', 0);
    push @errors, "Feature 'cluster-mode' requires params.cluster_nodes >= 3"
        if $nodes < 3;

    push @warnings, "Cluster mode with only 3 nodes provides minimal fault tolerance"
        if $nodes == 3;
}
```

## Summary

Feature validation is crucial for providing a good user experience with your Genesis kit. The validation framework handles the common cases automatically while giving you flexibility for complex scenarios.

Key takeaways:
- Start with basic `valid_features` validation
- Add deprecation handling as your kit evolves
- Use mutual exclusion to prevent conflicting features
- Implement custom validation for complex parameter relationships
- Only add upstream support if you really need it
- Test thoroughly with both valid and invalid configurations

Good validation catches problems early and guides users toward correct configurations, making your kit more reliable and user-friendly.
