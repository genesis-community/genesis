# BOSH User Authentication Policy Implementation Discussion

## Overview

This document summarizes a discussion about implementing OCFP (Open Cloud Foundry Platform) policy-based authentication for BOSH objects in the Genesis project, addressing the need for dynamic credential selection based on environment-specific policies.

## BOSH Authentication Policy Implementation

### Problem Statement
The Genesis project needed to implement OCFP policy-based authentication where BOSH objects could use either:
1. **Admin credentials** from exodus data (existing behavior)
2. **User credentials** from environment variables (`BOSH_USER` and `BOSH_PASSWORD`)

The decision should be based on OCFP configuration data at `secret/config/<ocfp-env>/<ocfp-type>/policies`.

### Current Architecture Issues
- BOSH Director and CreateEnvProxy constructors don't associate with Genesis::Env objects
- No access to OCFP configuration data for policy decisions
- Multiple call sites including kit hooks, Genesis commands, and environment deployment logic

### Recommended Solution: Environment Context Parameter

#### 1. Constructor Modification
```perl
sub new {
    my ($class, $alias, %opts) = @_;
    # ...existing code...
    my $director = {
        # ...existing fields...
        env => $opts{env} # Store Genesis::Env reference
    };
    return bless($director, $class);
}
```

#### 2. Authentication Policy Logic
```perl
sub _determine_auth_policy {
    my ($self) = @_;
    return 'admin' unless $self->{env}; # Default fallback
    
    # Check OCFP configuration
    my $env = $self->{env};
    my $ocfp_config_path = $env->lookup('meta.ocfp.vault.config', '');
    return 'admin' unless $ocfp_config_path;
    
    # Determine policy from vault
    my $env_name = $env->name;
    my $ocfp_type = $self->_determine_ocfp_type($env_name);
    my $policy_path = "secret/config/${env_name}/${ocfp_type}/policies";
    
    my $policies = eval { 
        my $vault = $self->{exodus_vault} || Service::Vault->current;
        $vault->get($policy_path) if $vault;
    };
    
    return $policies && $policies->{bosh_auth} eq 'user' ? 'user' : 'admin';
}
```

#### 3. Environment Variables Override
```perl
sub environment_variables {
    my ($self) = @_;
    my %envs = (
        BOSH_ALIAS       => $self->{alias},
        BOSH_ENVIRONMENT => $self->url,
        BOSH_CA_CERT     => $self->{ca_cert},
    );
    
    my $auth_policy = $self->_determine_auth_policy();
    
    if ($auth_policy eq 'user' && $ENV{BOSH_USER} && $ENV{BOSH_PASSWORD}) {
        $envs{BOSH_CLIENT} = $ENV{BOSH_USER};
        $envs{BOSH_CLIENT_SECRET} = $ENV{BOSH_PASSWORD};
    } else {
        $envs{BOSH_CLIENT} = $self->{client};
        $envs{BOSH_CLIENT_SECRET} = $self->{secret};
    }
    
    return %envs;
}
```

### Bash Helper Script Challenges

#### Problem with Helper Scripts
The `bosh()` bash function in `Genesis::Helpers` creates BOSH objects without access to Genesis::Env objects:

```perl
perl_script="$(cat <<'      EOF'
      my $bosh=(
        Service::BOSH::Director->from_exodus($ENV{BOSH_ALIAS}) ||
        Service::BOSH::Director->from_alias($ENV{BOSH_ALIAS})
      );
      # No environment context available here
      EOF
      )"
```

#### Recommended Solution: Environment Variable Pass-Through
```perl
# In Genesis::Env hook execution
sub run_hook {
    my ($self, $hook_name, @args) = @_;
    
    # Determine BOSH authentication policy
    my $auth_policy = $self->_determine_bosh_auth_policy();
    
    # Set environment variable to signal bash helpers
    local $ENV{GENESIS_USE_BOSH_USER_CREDS} = ($auth_policy eq 'user') ? '1' : '0';
    
    # Execute the hook
    return $self->SUPER::run_hook($hook_name, @args);
}
```

#### Updated Bash Helper
```perl
perl_script="$(cat <<'      EOF'
      my $bosh = Service::BOSH::Director->from_exodus($ENV{BOSH_ALIAS}) ||
                 Service::BOSH::Director->from_alias($ENV{BOSH_ALIAS});
      
      my %vars = $bosh->environment_variables;
      
      # Override with user credentials if policy dictates
      if ($ENV{GENESIS_USE_BOSH_USER_CREDS} eq '1' && $ENV{BOSH_USER} && $ENV{BOSH_PASSWORD}) {
        $vars{BOSH_CLIENT} = $ENV{BOSH_USER};
        $vars{BOSH_CLIENT_SECRET} = $ENV{BOSH_PASSWORD};
      }
      
      # Export variables for bash
      for my $key (keys %vars) {
        my $val = $vars{$key} // '';
        $val =~ s/'/'"'"'/g;  # Escape quotes
        print "export $key='$val'\n";
      }
      EOF
      )"
```

### Alternative Approach: Dynamic Environment Loading

#### Loading Environment Object from Context
An alternative to passing environment context through constructors is to dynamically load the environment object when needed, using the `GENESIS_ROOT` and `GENESIS_ENVIRONMENT` environment variables that are always available during Genesis operations.

```perl
# _load_environment_context - Load Genesis::Env object from environment variables {{{
sub _load_environment_context {
	my ($self) = @_;
	
	# Check if we already have environment context
	return $self->{env} if $self->{env};
	
	# Load from environment variables if available
	return unless $ENV{GENESIS_ROOT} && $ENV{GENESIS_ENVIRONMENT};
	
	eval {
		require Genesis::Top;
		require Genesis::Env;
		
		my $top = Genesis::Top->new($ENV{GENESIS_ROOT});
		$self->{env} = $top->load_env($ENV{GENESIS_ENVIRONMENT});
	};
	
	# Return environment object or undef if loading failed
	return $self->{env};
}

# }}}
```

#### Updated Authentication Policy Logic
```perl
sub _determine_auth_policy {
	my ($self) = @_;
	
	# Try to load environment context if not already available
	my $env = $self->{env} || $self->_load_environment_context();
	return 'admin' unless $env; # Default fallback
	
	# Check OCFP configuration
	my $ocfp_config_path = $env->lookup('meta.ocfp.vault.config', '');
	return 'admin' unless $ocfp_config_path;
	
	# Determine policy from vault
	my $env_name = $env->name;
	my $ocfp_type = $self->_determine_ocfp_type($env_name);
	my $policy_path = "secret/config/${env_name}/${ocfp_type}/policies";
	
	my $policies = eval { 
		my $vault = $self->{exodus_vault} || Service::Vault->current;
		$vault->get($policy_path) if $vault;
	};
	
	return $policies && $policies->{bosh_auth} eq 'user' ? 'user' : 'admin';
}
```

#### Benefits of Dynamic Loading Approach
1. **No Constructor Changes**: Existing BOSH object creation code requires no modifications
2. **Automatic Context**: Environment context is loaded automatically when needed
3. **Graceful Degradation**: Falls back to admin credentials if environment context cannot be loaded
4. **Works with Helper Scripts**: Bash helpers can use this approach without requiring environment variable pass-through
5. **Minimal Performance Impact**: Environment loading is lazy and cached

#### Updated Bash Helper with Dynamic Loading
```perl
perl_script="$(cat <<'      EOF'
      use Service::BOSH::Director;
      use Genesis::Top;
      use Genesis::Env;
      
      my $bosh = Service::BOSH::Director->from_exodus($ENV{BOSH_ALIAS}) ||
                 Service::BOSH::Director->from_alias($ENV{BOSH_ALIAS});
      
      # Load environment context if available
      if ($ENV{GENESIS_ROOT} && $ENV{GENESIS_ENVIRONMENT} && !$bosh->{env}) {
        eval {
          my $top = Genesis::Top->new($ENV{GENESIS_ROOT});
          $bosh->{env} = $top->load_env($ENV{GENESIS_ENVIRONMENT});
        };
      }
      
      my %vars = $bosh->environment_variables;
      
      # Export variables for bash
      for my $key (keys %vars) {
        my $val = $vars{$key} // '';
        $val =~ s/'/'"'"'/g;  # Escape quotes
        print "export $key='$val'\n";
      }
      EOF
      )"
```

### Implementation Benefits
1. **Backward Compatibility**: Existing code continues working unchanged
2. **Optional Enhancement**: Only environments with context get policy-based auth
3. **Clean Separation**: Policy logic contained within BOSH service classes
4. **Fallback Safety**: Always defaults to admin credentials if policy lookup fails
5. **Minimal Changes**: Only requires adding `env => $self` to constructor calls

## Key Recommendations

### For BOSH Authentication Implementation
1. **Implement environment context parameter** in BOSH constructors
2. **Use environment variable pass-through** for bash helper compatibility
3. **Maintain backward compatibility** throughout implementation
4. **Implement comprehensive policy lookup** with proper error handling

## Future Considerations

### Implementation Phases
1. **Phase 1**: Add environment context support to constructors
2. **Phase 2**: Update Genesis::Env methods to pass context
3. **Phase 3**: Update kit hooks creating BOSH objects directly
4. **Phase 4**: Add comprehensive OCFP policy checking logic

### Testing Requirements
- Unit tests for policy determination logic
- Integration tests for environment variable handling
- Backward compatibility tests for existing functionality
- End-to-end tests for OCFP environments

### Documentation Updates
- Update Genesis configuration documentation as features evolve
- Maintain coding standards documentation
- Create migration guides for kit authors
- Document troubleshooting procedures for authentication issues

This discussion demonstrates Genesis project's commitment to maintainable, well-documented, and properly tested code while implementing complex authentication policy requirements.
