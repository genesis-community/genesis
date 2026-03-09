# BOSH Cloud Config Overrides

This guide explains how to customize cloud configurations in Genesis environments using bosh-config overrides. These overrides allow you to modify or extend the cloud configuration elements (vm_types, vm_extensions, disk_types, networks) that kits define in their cloud-config hooks.

## When to Use Overrides

Use bosh-config overrides when you need to:
- Customize instance types or disk sizes for your specific requirements
- Apply consistent security settings across all resources
- Create additional configurations not provided by the kit
- Modify network allocations or properties
- Adapt kit configurations for your specific environment needs

## Basic Structure

All overrides are defined under the `bosh-configs.cloud` key in your environment file:

```yaml
# In your environment file (e.g., prod-us-east-1.yml)
bosh-configs:
  cloud:
    # Override configurations here
```

## Types of Overrides

### 1. Setting Defaults for All Resources

Use `{type}_defaults` to apply properties to all instances of a configuration type:

```yaml
bosh-configs:
  cloud:
    vm_type_defaults:
      cloud_properties:
        encrypted: true
        metadata_options:
          http_tokens: required

    disk_type_defaults:
      cloud_properties:
        encrypted: true
        type: gp3
```

This ensures all VM types get encrypted disks and all disk types use GP3 storage, regardless of what the kit defines.

### 2. Pattern-Based Overrides

Use `matching_{type}s` to apply overrides based on naming patterns or properties. Each rule contains multiple condition sets, where:
- **All conditions within a set must match** (AND logic)
- **Only one condition set needs to match** for the rule to apply (OR logic between sets)
- Properties are applied to all resources that match any condition set

```yaml
bosh-configs:
  cloud:
    matching_vm_types:
      - conditions:
          # Condition Set 1: All diego-related VMs
          - name: "/diego.*/"
            cloud_properties.instance_type: "/^[rt]/"  # r-series or t-series

          # Condition Set 2: Specific high-memory VMs
          - name: ["api", "scheduler"]
            cloud_properties.instance_type: "/large$/"

          # Condition Set 3: All database VMs
          - name: "/database/"

        properties:
          cloud_properties:
            ephemeral_disk:
              size: 65536
              type: gp3
```

In this example, the properties will be applied to VMs that match ANY of these condition sets:
1. Name starts with "diego" AND uses r-series or t-series instances
2. Name is "api" or "scheduler" AND instance type ends with "large"
3. Name contains "database"

Note: Currently there's a bug where only the first matching rule applies its properties. This should be fixed to apply all matching rules' properties.  In the meantime, you can use multiple rules to achieve the same effect (see below).

### Multiple Matching Rules

You can define multiple matching rules, and each matching rule that has a condition set match will apply its properties:

```yaml
bosh-configs:
  cloud:
    matching_vm_types:
      # Rule 1: Security settings for all production VMs
      - conditions:
        - cloud_properties.instance_type: "!~/^t/"  # Not t-series (burst)
        properties:
          cloud_properties:
            metadata_options:
              http_tokens: required

      # Rule 2: Disk encryption for sensitive workloads
      - conditions:
        - name: ["/database/","/api/","/auth/"]
        properties:
          cloud_properties:
            encrypted: true
```

### 3. Specific Resource Overrides

Use `{type}s` to override or create specific named configurations:

```yaml
bosh-configs:
  cloud:
    vm_types:
      api:  # Override existing kit-defined 'api' vm_type
        cloud_properties:
          instance_type: m6i.4xlarge

      custom-worker:  # Create entirely new vm_type - must include all required properties
        <based-on>: diego-cell  # OR base it on an existing type (see Advanced Features)
        cloud_properties:
          instance_type: c6i.xlarge
          ephemeral_disk:
            size: 32768
            type: gp3
```

**Important**: When creating entirely new configurations (not overriding existing ones), you must either:
- Provide ALL necessary properties for a complete configuration
- Use `<based-on>` to inherit from an existing configuration (see Advanced Features below)

## Resource Naming Conventions

Genesis automatically prefixes most resource names with your environment details:

- **vm_types**: `<env-name>.<env-type>.vm-<name>` (e.g., `prod.cf.vm-api`)
- **disk_types**: `<env-name>.<env-type>.disk-<name>` (e.g., `prod.cf.disk-database`)
- **networks**: `<env-name>.<env-type>.net-<name>` (e.g., `prod.cf.net-runtime`)
- **vm_extensions**: Use exact names without prefixing

This prefixing prevents naming conflicts between environments and kits.

## Advanced Features

### Inheriting from Other Configurations

Use `<based-on>` to inherit from another configuration and modify it:

```yaml
bosh-configs:
  cloud:
    vm_types:
      large-api:
        <based-on>: api  # Inherit from 'api' vm_type
        cloud_properties:
          instance_type: m6i.4xlarge  # Override just the instance type

      custom-worker:  # Create new vm_type based on existing one
        <based-on>: diego-cell
        cloud_properties:
          instance_type: c6i.xlarge  # Different instance type
          ephemeral_disk:
            size: 65536  # Larger ephemeral disk
```

### Using Explicit Names

Use `<explicit-name>` to prevent environment prefixing:

```yaml
bosh-configs:
  cloud:
    disk_types:
      shared-storage:
        <explicit-name>: true  # Creates 'shared-storage' instead of 'env.type.disk-shared-storage'
        disk_size: 102400
        cloud_properties:
          type: gp3
          encrypted: true
```

Note: VM extensions automatically use explicit names and don't need this flag.

## Sharing Overrides Across Environments

Since bosh-config overrides are processed at the environment level (not the kit level), you cannot use kit features to share them. Instead, use Genesis's inheritance system to create reusable override files.

### Creating Shared Override Files

Create dedicated files containing your bosh-config overrides:

**File: `ops/bosh-configs/security-overrides.yml`**
```yaml
---
bosh-configs:
  cloud:
    vm_type_defaults:
      cloud_properties:
        metadata_options:
          http_tokens: required
          http_put_response_hop_limit: 1

    disk_type_defaults:
      cloud_properties:
        encrypted: true
```

**File: `ops/bosh-configs/production-sizing.yml`**
```yaml
---
bosh-configs:
  cloud:
    vm_types:
      api:
        cloud_properties:
          instance_type: m6i.2xlarge
      diego-cell:
        cloud_properties:
          instance_type: r6i.4xlarge

    matching_vm_types:
      - conditions:
          - name: "/database/"
        properties:
          cloud_properties:
            instance_type: m6i.xlarge
```

### Using Shared Override Files

Reference the shared files using `genesis.inherits` in your environment files:

**File: `us-west-1-prod.yml`**
```yaml
---
genesis:
  inherits:
    - ops/bosh-configs/security-overrides # .yml extension optional, but not recommended.
    - ops/bosh-configs/production-sizing

kit:
  name: cf
  version: 2.8.0
  features:
    - haproxy
    - shield-agent

params:
  availability_zones: [us-west-1a, us-west-1b, us-west-1c]
```

For a complete understanding of Genesis's inheritance system, see the [Genesis Environment Inheritance documentation](genesis-inherits.md), which covers:
- How inheritance chains work
- File resolution order
- Circular dependency handling
- Integration with cached files
- Best practices for organizing shared configuration

## Common Use Cases

### Upgrading Instance Types

Override kit defaults for production environments:

```yaml
# In prod.yml
bosh-configs:
  cloud:
    vm_types:
      api:
        cloud_properties:
          instance_type: m6i.2xlarge  # Upgrade from kit default
      diego-cell:
        cloud_properties:
          instance_type: r6i.4xlarge  # More memory for containers
```

### Applying Security Requirements

Set organization-wide security policies:

```yaml
bosh-configs:
  cloud:
    vm_type_defaults:
      cloud_properties:
        metadata_options:
          http_tokens: required
          http_put_response_hop_limit: 1

    disk_type_defaults:
      cloud_properties:
        encrypted: true
```

### Custom Load Balancers

Create application-specific load balancer configurations:

```yaml
bosh-configs:
  cloud:
    vm_extensions:
      api-lb:  # Creates 'api-lb' (no prefixing)
        cloud_properties:
          lb_target_groups: [api-app-tg, external-traffic-tg]

      worker-lb:  # Creates 'worker-lb' (no prefixing)
        cloud_properties:
          lb_target_groups: [worker-app-tg]
```

### Network Allocation Tuning

Adjust OCFP network allocations for your scale:

```yaml
bosh-configs:
  cloud:
    networks:
      ocf-runtime:
        allocation:
          total_size: 200  # More diego cells, spread across availability subnets
      ocf-core:
        allocation:
          vms_per_subnet: Customize per-subnet VM distribution
            ocfp-0: 30
            ocfp-1: 30
            ocfp-2: 20
```

### Custom Disk Types

Create specialized disk configurations:

```yaml
bosh-configs:
  cloud:
    disk_types:
      high-iops:  # New disk type with all required properties
        disk_size: 51200
        cloud_properties:
          type: io2
          iops: 10000
          encrypted: true

      backup-storage:  # New disk type based on existing one
        <based-on>: high-iops
        disk_size: 204800  # Override just the size
```

## Pattern Matching Reference

When using `matching_{type}s`, you can match on any property using these patterns:

### Regex Patterns
- `/pattern/` - Basic regex
- `/pattern/i` - Case insensitive
- `!~/pattern/` - Negated regex

### Array Matching
Provide arrays for OR logic within a condition:
```yaml
matching_vm_types:
  - conditions:
      - name: ["api", "scheduler", "cc-worker"]  # Matches any of these names
      - cloud_properties.instance_type: ["m6i.large", "m6i.xlarge"]  # Any of these types
```

### Complex Matching Examples
```yaml
matching_vm_types:
  - conditions:
      # Condition Set 1: Production diego cells
      - name: "/^diego/"
        cloud_properties.instance_type: "!~/^t/"  # Not t-series

      # Condition Set 2: All API-related VMs in any environment
      - name: "/api/"

      # Condition Set 3: Specific high-priority VMs
      - name: ["scheduler", "router"]
        cloud_properties.instance_type: "/large$|xlarge$/"

    properties:
      cloud_properties:
        monitoring: enhanced
        backup_required: true
```

## Validation and Troubleshooting

Genesis validates your override configurations and will report errors for:
- Invalid section names
- Malformed matching rules
- Circular dependencies in `<based-on>` chains

Common issues:
- **Meta-keys in wrong places**: Don't use `<based-on>` in defaults sections
- **Invalid regex**: Test your patterns before deploying
- **Missing properties**: Ensure matching rules have both `conditions` and `properties`
- **Incomplete new configurations**: New resources need all required properties or must use `<based-on>`
- **Logic errors**: Remember AND within condition sets, OR between condition sets

## Best Practices

1. **Start with defaults** - Use `{type}_defaults` for organization-wide policies
2. **Use matching for patterns** - Apply systematic changes with `matching_{type}s`
3. **Minimize specific overrides** - Only override individual resources when necessary
4. **Use `<based-on>` for new resources** - Inherit from existing configurations instead of defining from scratch
5. **Share common overrides** - Use `genesis.inherits` to create reusable override files
6. **Organize by purpose** - Group related overrides (security, sizing, networking) into dedicated files
7. **Test incrementally** - Verify cloud config generation after each change
8. **Document custom resources** - Especially when using `<explicit-name>`
9. **Consider kit updates** - Your overrides persist through kit upgrades
10. **Understand naming** - Remember that most resources get environment prefixes
11. **Test matching logic** - Verify condition sets match intended resources

---

## Technical Implementation Reference

This section provides technical details for developers and advanced users.

### Processing Order

Overrides are applied in this specific order:
1. Kit-defined defaults from cloud-config.pm hook
2. Environment `{type}_defaults` sections
3. Environment `matching_{type}s` rules (in order)
4. Environment `{type}s` named configurations

### Implementation Files

- Configuration processing: `lib/Genesis/Hook/CloudConfig.pm:1250` (`_process_config_overrides`)
- Pattern matching evaluation: `lib/Genesis/Hook/CloudConfig.pm:1317` (`_evaluate_matching_rule`)
- Schema validation: `lib/Genesis/Hook/CloudConfig.pm:798` (`_validate_override_schema`)
- Extended config building: `lib/Genesis/Hook/CloudConfig.pm:915` (`_add_extended_cloud_config`)

### Valid Root Configuration Keys

```
vm_type_defaults, vm_types, matching_vm_types
vm_extension_defaults, vm_extensions, matching_vm_extensions
disk_type_defaults, disk_types, matching_disk_types
network_defaults, networks, matching_networks
```

### Resource Naming Implementation

- **vm_types, disk_types, networks**: Use `name_for($prefix, $target)` method which creates `<basename>.$prefix-$target`
- **vm_extensions**: Use explicit names without prefixing (see `vm_extension_definition` in CloudConfig.pm:762)
- **Explicit name override**: `<explicit-name>` meta-key bypasses prefixing for vm_types, disk_types, and networks

### Matching Logic Implementation

Pattern matching uses OR logic between condition sets and AND logic within each set. Current implementation in `_evaluate_matching_rule` (CloudConfig.pm:1317) has a bug where only the first matching rule applies - this should apply all matching rules.

### Network-Specific Properties

Networks support additional subnet-level configuration:

```yaml
bosh-configs:
  cloud:
    network_defaults:
      subnets:
        dns: [8.8.8.8, 1.1.1.1]

    networks:
      network-name:
        subnet_defaults:
          cloud_properties:
            security_groups: [default-sg]
        subnets:
          subnet-name:
            dns: [192.168.1.1]
            cloud_properties:
              subnet: subnet-12345
```
