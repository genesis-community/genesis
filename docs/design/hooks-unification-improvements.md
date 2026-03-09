# Genesis Hook Class Architecture Unification

**Status**: Draft  
**Date**: 2025-01-08  
**Author**: Analysis via Claude Code  

## Executive Summary

The Genesis Hook class hierarchy has evolved organically, leading to duplicated functionality and scattered responsibilities across derived classes. This document proposes a unification strategy to create a cleaner, more maintainable architecture while preserving backward compatibility for existing kit implementations.

## Current State Analysis

### Class Structure

The current Genesis Hook hierarchy consists of:

**Base Class**: `Genesis::Hook`
- Core functionality: environment access, feature detection, exodus data, BOSH interaction
- Universal methods: `env`, `deployed`, `features`, `want_feature`, `exodus_data`, `bosh`
- Location: `lib/Genesis/Hook.pm`

**Derived Classes**:
1. **Blueprint** (`lib/Genesis/Hook/Blueprint.pm`) - Manifest file selection and feature validation
2. **Check** (`lib/Genesis/Hook/Check.pm`) - Pre-deployment validation of configs and environment  
3. **CloudConfig** (`lib/Genesis/Hook/CloudConfig.pm`) - BOSH cloud configuration generation
4. **CpiConfig** (`lib/Genesis/Hook/CpiConfig.pm`) - Custom CPI configuration with secret entombment
5. **RuntimeConfig** (`lib/Genesis/Hook/RuntimeConfig.pm`) - BOSH runtime configuration with secret management
6. **PostDeploy** (`lib/Genesis/Hook/PostDeploy.pm`) - Post-deployment tasks and resource upload
7. **Addon** (`lib/Genesis/Hook/Addon.pm`) - Custom addon command execution

## Identified Problems

### 1. Secret Management Inconsistency

**Current State**:
- `RuntimeConfig` has comprehensive secret management:
  - `_get_secret(vault_path:key, default)` - vault secret with entombment
  - `credhub_base()` - credhub prefix for secrets
  - `store_secrets()` - batch upload secrets to credhub
  - `$self->{secrets}` - secret accumulation structure

- `CpiConfig` has parallel but separate implementation:
  - `cpi_entombment_path_for(key, value)` - custom entombment paths
  - `$self->{credhub_secrets}` - separate secret storage
  - `gather_properties()` - secret handling during property collection

- `PostDeploy` duplicates upload logic:
  - `_commit_config_credhub_secrets(secrets)` - manual credhub upload

**Problem**: Three separate implementations of the same secret entombment pattern.

### 2. BOSH Configuration Management Duplication  

**Current Patterns**:
- `RuntimeConfig`: Full lifecycle (build → compare → upload → store secrets)
- `CloudConfig`: Complex generation with network handling and config comparison
- `CpiConfig`: Property gathering and secret entombment
- `PostDeploy`: Manual config uploads with error handling

**BOSH Upload API Inconsistency**:
- `CloudConfig` and `CpiConfig` use: `bosh upload-config --type {cloud|cpi} --name <name> <file>`
- `RuntimeConfig` requires: `bosh upload-runtime-config --name <name> [--fix-releases] <file>`
- The runtime config command automatically handles release uploads, while others don't

**Problem**: Each class reimplements config validation, upload, comparison, and error handling, plus they require different BOSH command patterns.

### 3. Missing Abstractions

**Config Hook Commonalities**:
- Override processing from environment files
- Config validation and comparison  
- Upload to BOSH director
- Secret entombment and storage
- Error handling and user interaction

**Feature Processing Responsibility Split**:
- `Blueprint` hook: Feature validation, deprecation handling, manifest fragment selection
- `Features` hook: Virtual feature mapping (creating features based on absence/interaction of others)
- **Current Problem**: Mixed implementations across kits, unclear responsibility boundaries
- **User Experience Issue**: Inconsistent error messages and validation timing across different kits
- **Efficiency Problem**: Multiple hooks may re-validate the same feature set

## Proposed Architecture

### 1. New Intermediate Base Class

Create `Genesis::Hook::BoshConfig` as an intermediate base for all BOSH configuration hooks:

```perl
package Genesis::Hook::BoshConfig;
use parent qw(Genesis::Hook);

# Common configuration management methods:
sub compare_configs { }      # Compare existing vs generated config
sub upload_config { }        # Polymorphic upload (handles runtime vs others)
sub print_config { }         # Display config contents
sub validate_config { }      # Validate config structure
sub store_secrets { }        # Batch upload secrets to credhub

# Config-agnostic override processing
sub process_config_overrides { }

# BOSH upload strategy methods (polymorphic)
sub _upload_via_upload_config { }     # For cloud/cpi configs
sub _upload_via_runtime_config { }    # For runtime configs with --fix-releases
```

### 2. Enhanced Base Class Capabilities

**Promote to `Genesis::Hook`**:

```perl
# Secret management (generalized from RuntimeConfig)
sub _get_secret { }          # Vault secret with entombment
sub _get_exodus_secret { }   # Exodus secret with entombment (already added)
sub get_credhub_variable { } # Already exists

# Feature processing coordination (see Feature Processing Strategy below)
sub get_validated_features { }    # Get validated features from blueprint/features hooks
sub invalidate_feature_cache { }  # Clear cached features if hooks re-run

# Utility methods
sub titleize { }            # String formatting utility
```

### 3. Feature Processing Strategy

**Current State**: Mixed responsibility between Blueprint and Features hooks creates inconsistency and potential duplication.

**Proposed Resolution**:

#### Responsibility Clarification
- **Features Hook**: Virtual feature mapping and environment-specific feature resolution
- **Blueprint Hook**: Feature validation, deprecation handling, and manifest fragment selection  
- **Other Hooks**: Consume validated features without re-processing

#### Implementation Pattern
```perl
package Genesis::Hook;

sub get_validated_features {
    my $self = shift;
    
    # Cache validated features to avoid reprocessing
    return $self->{_validated_features} if $self->{_validated_features};
    
    # Features hook runs first (if exists) for virtual feature mapping
    if ($self->env->has_hook('features')) {
        my $mapped_features = $self->env->run_hook('features');
        $self->set_features(@$mapped_features);
    }
    
    # Blueprint hook validates and processes deprecations
    if ($self->env->has_hook('blueprint')) {
        # Blueprint gets access to both original and mapped features
        # for accurate user error reporting
        $self->{_validated_features} = $self->env->run_hook('blueprint')->validated_features;
    } else {
        $self->{_validated_features} = [$self->features];
    }
    
    return $self->{_validated_features};
}
```

#### Benefits
- **Single Source of Truth**: All hooks get consistent feature set
- **Efficient Processing**: Features validated once, consumed many times  
- **Better Error Messages**: Blueprint can reference original user input
- **Clear Responsibility**: Features maps, Blueprint validates, others consume

### 4. BOSH Upload Strategy

**Problem**: Runtime configs require different upload command than cloud/cpi configs.

**Solution**: Polymorphic upload with strategy pattern
```perl
package Genesis::Hook::BoshConfig;

sub upload_config {
    my ($self, $config_data, $config_name) = @_;
    
    # Determine upload strategy based on hook type
    if ($self->isa('Genesis::Hook::RuntimeConfig')) {
        return $self->_upload_via_runtime_config($config_data, $config_name);
    } else {
        return $self->_upload_via_upload_config($config_data, $config_name);
    }
}

sub _upload_via_runtime_config {
    my ($self, $config_data, $config_name) = @_;
    
    # Use bosh upload-runtime-config with --fix-releases
    my ($out, $rc, $err) = $self->bosh->upload_runtime_config(
        $config_data, $config_name, fix_releases => 1
    );
    return ($out, $rc, $err);
}

sub _upload_via_upload_config {
    my ($self, $config_data, $config_name) = @_;
    
    # Use generic bosh upload-config --type
    my $config_type = $self->_get_config_type(); # 'cloud' or 'cpi'
    my ($out, $rc, $err) = $self->bosh->upload_config(
        $config_data, $config_type, $config_name
    );
    return ($out, $rc, $err);
}
```

### 5. Migration Strategy

**Phase 1: Create BoshConfig Base**
1. Extract common patterns from RuntimeConfig, CloudConfig, CpiConfig
2. Create `Genesis::Hook::BoshConfig` with unified methods
3. Maintain backward compatibility through delegation

**Phase 2: Enhance Base Hook**  
1. Move secret management to `Genesis::Hook`
2. Add optional feature validation capabilities
3. Provide utility methods for all hook types

**Phase 3: Update Derived Classes**
1. Migrate configuration hooks to use `BoshConfig` base
2. Remove duplicated code
3. Add polymorphic method calls where appropriate

## Backward Compatibility Strategy

### Existing Kit Hook Compatibility

**Identification of Impact**:
- Kits using `RuntimeConfig`: Direct method calls remain unchanged
- Kits using `CloudConfig`: Network-specific methods unchanged
- Kits using `CpiConfig`: Property gathering unchanged
- Custom hooks: May gain new capabilities automatically

**Compatibility Preservation**:

#### 1. Method Aliasing
```perl
package Genesis::Hook::RuntimeConfig;

# Existing method names preserved via aliasing
sub _get_secret { shift->SUPER::_get_secret(@_) }  # Delegates to base
sub credhub_base { shift->SUPER::credhub_base(@_) }
```

#### 2. Upload Strategy Compatibility
```perl
package Genesis::Hook::BoshConfig;

# Existing methods preserved with enhanced implementation
sub upload_runtime_config {
    my $self = shift;
    # Uses new strategy pattern but maintains same signature
    return $self->upload_config(@_);  # Automatically uses runtime-config command
}

sub upload_cloud_config {  
    my $self = shift;
    # Uses upload-config --type cloud strategy
    return $self->upload_config(@_);
}
```

#### 3. Legacy Method Support
```perl
package Genesis::Hook::RuntimeConfig;

# Existing kits may call this directly
sub build_dns_runtime {
    my $self = shift;
    # Existing logic preserved
    # Can now also use enhanced base class methods
}
```

### Kit Upgrade Paths

**Level 1: No Changes Required**
- Existing hook methods continue to work
- Kits automatically gain enhanced capabilities
- Secret management becomes more robust

**Level 2: Light Refactoring** 
- Replace direct credhub calls with `store_secrets()`
- Use unified `_get_secret()` instead of custom implementations
- Adopt standardized config upload patterns

**Level 3: Full Modernization**
- Implement polymorphic config methods
- Use enhanced feature validation
- Leverage new secret management capabilities

### Detection and Upgrade Tools

**Compatibility Scanner**:
```perl
# Tool to scan kits for upgrade opportunities
sub analyze_kit_hooks {
    my $kit_path = shift;
    
    # Detect patterns:
    # - Direct credhub interaction (can use store_secrets)
    # - Duplicated config upload logic (can use upload_config)  
    # - Custom secret entombment (can use _get_secret)
    # - Manual feature validation (can use validate_features)
}
```

**Migration Helpers**:
```perl
package Genesis::Hook::BoshConfig;

# Transition method for old-style config uploads
sub legacy_upload_config {
    my ($self, $old_style_args) = @_;
    
    # Convert old argument format to new unified format
    return $self->upload_config($converted_args);
}
```

## Implementation Plan

### Phase 1: Foundation (Low Risk)
1. **Create `Genesis::Hook::BoshConfig`**
   - Extract common patterns without breaking existing code
   - Implement polymorphic upload strategy for BOSH API differences
   - Add delegation methods to maintain compatibility
   - Focus on RuntimeConfig/CpiConfig commonalities

2. **Enhance Base Hook Class**  
   - Move `_get_exodus_secret` (already done)
   - Add generalized `_get_secret` capability
   - Implement `get_validated_features` caching mechanism
   - Move utility methods like `titleize`

3. **Feature Processing Coordination**
   - Clarify Features vs Blueprint hook responsibilities
   - Implement feature validation caching to avoid duplication
   - Ensure backward compatibility with existing kit patterns

### Phase 2: Unification (Medium Risk)  
1. **Update RuntimeConfig to inherit from BoshConfig**
   - Preserve all existing public methods
   - Use base class implementations internally
   - Maintain secret management compatibility

2. **Update CpiConfig to inherit from BoshConfig**
   - Unify secret entombment with RuntimeConfig patterns
   - Preserve property gathering API
   - Use common config upload logic

### Phase 3: Optimization (Higher Risk)
1. **Update CloudConfig to inherit from BoshConfig**  
   - Complex due to network-specific logic
   - May require specialized BoshConfig methods
   - Preserve all network calculation capabilities

2. **Kit Migration Support**
   - Provide migration tools and documentation
   - Create compatibility testing framework
   - Support both old and new patterns during transition

## Benefits

### For Genesis Core
- **Reduced Code Duplication**: ~30% reduction in config management code
- **Enhanced Consistency**: Unified patterns across all config types  
- **Better Testing**: Common code paths easier to test comprehensively
- **Simplified Maintenance**: Changes propagate automatically

### For Kit Developers  
- **More Capabilities**: All hook types gain secret management
- **Better Patterns**: Standardized approaches to common tasks
- **Enhanced Documentation**: Clear inheritance hierarchy  
- **Future-Proofing**: New capabilities automatically available

### For Operations Teams
- **Consistent Behavior**: Uniform error handling and user interaction
- **Better Debugging**: Common code paths easier to troubleshoot  
- **Enhanced Security**: Robust secret management across all config types

## Risks and Mitigations

### Compatibility Risk
**Risk**: Existing kits break due to method signature changes  
**Mitigation**: Maintain all existing method signatures, delegate to new implementations

### Complexity Risk  
**Risk**: New architecture too complex for existing workflows
**Mitigation**: Gradual migration with extensive compatibility testing

### Performance Risk
**Risk**: Additional inheritance layers impact performance
**Mitigation**: Profile before/after, optimize hot paths if needed

### BOSH API Inconsistency Risk
**Risk**: Runtime config upload differences cause compatibility issues
**Mitigation**: Implement robust polymorphic upload strategy with extensive testing

### Feature Processing Complexity Risk  
**Risk**: Feature validation coordination between Blueprint/Features hooks introduces bugs
**Mitigation**: Implement with comprehensive caching and fallback mechanisms, maintain existing kit compatibility

## Success Metrics

- Zero breaking changes to existing kit hooks during Phase 1-2
- >90% reduction in duplicated secret management code
- All config hook types support secret entombment
- Migration tools successfully upgrade reference kits
- No performance degradation in hook execution times

## Next Steps

1. **Stakeholder Review**: Get feedback on proposed architecture changes
2. **Prototype Development**: Build `Genesis::Hook::BoshConfig` prototype  
3. **Compatibility Testing**: Test with existing Genesis Community kits
4. **Implementation Planning**: Detailed task breakdown and timeline
5. **Documentation Updates**: Update kit development guides

## Related Documents

- `lib/Genesis/Hook.pm` - Current base class implementation
- `lib/Genesis/Hook/RuntimeConfig.pm` - Reference implementation for secret management  
- `lib/Genesis/Hook/CloudConfig.pm` - Complex config generation patterns
- Kit development documentation (to be updated)

---

*This document serves as the foundation for future discussions and implementation planning of the Genesis Hook architecture improvements.*