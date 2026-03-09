# Genesis Environment Inheritance System

## Overview

Genesis provides a powerful inheritance system through the `genesis.inherits` directive that allows environment files to inherit configuration from other environment files. This system enables code reuse, reduces duplication, and provides a flexible way to share common configuration across environments.

### Why use `genesis.inherits` when we already have local ops support in features?

While Genesis supports custom ops files through features (allowing files from your deployment repository to be included in the manifest assembly), `genesis.inherits` serves a different and complementary purpose:

**Scope Differences:**
- **Features/Ops files**: Processed in the full kit context during manifest assembly
- **`genesis.inherits`**: Processed at the environment file level before blueprint generation

**Timing Differences:**
Genesis processes configuration in this order:
1. **Environment processing**: Loads and merges environment files (including inherited files)
2. **Blueprint generation**: Kit determines which manifest fragments to include based on features
3. **Manifest assembly**: Kit processes features and includes ops files from deployment repo

**Practical Use Cases for `genesis.inherits`:**

1. **Modifying `kit.features`**: Since features are processed after environment loading, you need `genesis.inherits` to share feature configurations:
   ```yaml
   # common-features.yml
   kit:
     features:
       - shield-agent
       - vault-credhub-proxy

   # us-west-prod.yml
   genesis:
     inherits: [common-features]
   kit:
     features:
       - (( append ))
       - external-db
   ```

2. **Setting `bosh-configs`**: Cloud configs, runtime configs, and other BOSH configurations are processed at the environment level:
   ```yaml
   # common-bosh-configs.yml
   bosh-configs:
     cloud:
       vm_type:
         large:
           ram: 8192
           cpu: 4

   # production.yml
   genesis:
     inherits: [common-bosh-configs]
   ```

3. **Environment-level parameters**: Settings that need to be available before kit processing:
   ```yaml
   # foundation-params.yml
   params:
     availability_zones: [z1, z2, z3]
     network: foundation-net
   ```

**In summary**: Use `genesis.inherits` for environment-level configuration that affects how Genesis processes the environment, and use ops files in features for kit-level manifest customization.

## How It Works

### File Resolution Order

When Genesis processes a target environment (e.g., `us-west-1-prod`), it follows this order:

1. **Target Environment Hierarchy**: Genesis identifies the standard hierarchical files for the target environment (e.g., `us.yml`, `us-west.yml`, `us-west-1.yml`, `us-west-1-prod.yml`)
2. **Per-File Inheritance Processing**: For each hierarchical file that exists, Genesis:
   - Checks that file for `genesis.inherits`
   - Processes any inherited files (recursively if needed)
   - Inserts inherited files immediately before the hierarchical file in the merge order
3. **Final Merge Order**: Results in a sequence where inherited files appear right before the file that inherits them

**Example**: If `us.yml` inherits `[base-config]` and `us-west.yml` inherits `[regional-config]`, the final order becomes:
```
[base-config.yml, us.yml, regional-config.yml, us-west.yml, us-west-1.yml, us-west-1-prod.yml]
```

### Circular Dependency Handling

Genesis automatically prevents circular dependencies by tracking which files have already been processed in the current inheritance chain. When a circular reference is detected:

1. **Detection**: If a file tries to inherit another file that's already in the processing chain, Genesis skips the duplicate
2. **Behavior**: The file is silently skipped - no error is thrown
3. **Order**: Files appear in the order they were first encountered during traversal

**Example of circular dependency**:
```yaml
# file-a.yml
genesis:
  inherits: [file-b]

# file-b.yml
genesis:
  inherits: [file-c]

# file-c.yml
genesis:
  inherits: [file-a]  # Creates cycle: a → b → c → a
```

**Result**: Files are processed as `[file-b.yml, file-c.yml, file-a.yml]` - when `file-c` tries to inherit `file-a`, it's skipped since `file-a` is already in the chain.

## Usage

### Basic Inheritance

In your environment file, add a `genesis.inherits` section:

```yaml
---
genesis:
  inherits:
    - common-config
    - database-settings

kit:
  name: my-app
  features:
    - shield-agent

params:
  network: default
```

### Inheritance Chain Example

**File: `common-config.yml`**
```yaml
---
genesis:
  inherits:
    - base-security

params:
  availability_zones: [z1, z2, z3]
  vm_type: small
```

**File: `base-security.yml`**
```yaml
---
params:
  trusted_certs: |
    -----BEGIN CERTIFICATE-----
    ...
    -----END CERTIFICATE-----
```

**File: `us-west-1-prod.yml`**
```yaml
---
genesis:
  inherits:
    - common-config

params:
  network: prod-network
  vm_type: large  # Override from common-config
```

**Resulting merge order:**
1. `base-security.yml` (inherited by common-config)
2. `common-config.yml` (inherited by us-west-1-prod)
3. `us-west-1-prod.yml` (the main file)

## Advanced Features

### Cached Files Support

Genesis supports cached files from previous environments via the `PREVIOUS_ENV` environment variable:

```bash
PREVIOUS_ENV=us-west-1-staging genesis manifest us-west-1-prod
```

When set, Genesis will look for inherited files in `.genesis/cached/$PREVIOUS_ENV/` first, falling back to the current directory.

### Integration with Kit Overrides

You can use `genesis.inherits` with kit overrides to bundle functionality and its required secrets together. This is particularly useful when wrapping ops features:

```yaml
---
# common/thingamabob.yml - Implements Thingamabob feature and its secrets
kit:
  features:
    - (( append ))
    - thingamabob
  overrides:
    credentials:
      base:
        thingamabob:
          password: random 32 fixed

# production.yml
genesis:
  inherits:
    - common/thingamabob
```

This pattern allows you to:
- Keep feature configuration and secrets together
- Share complex feature setups across environments
- Maintain consistency between feature requirements and their secrets

### File Path Resolution

- **Relative paths**: All inherited file paths are relative to the environment file's location
- **Directory organization**: You can organize inherited files in subdirectories within your deployment repository
- **Examples**:
  ```yaml
  genesis:
    inherits:
      - common-config              # Resolves to ./common-config.yml
      - ops/bosh-configs/prod      # Resolves to ./ops/bosh-configs/prod.yml
      - ../shared/foundation       # Resolves to ../shared/foundation.yml
  ```

⚠️ **Warning**: Paths outside the deployment repository (like `../shared/foundation`) must exist on every user's system that will deploy this environment. Consider using a containing git repository structure or keeping all inherited files within the deployment repository to ensure portability.

### File Extension Handling

- File extensions are optional - `.yml` is optional, but not recommended.
- Example: `inherits: ["common-config"]` resolves to `./common-config.yml`

### Error Handling

- **Missing files**: Will cause spruce to report missing file errors during processing
- **Invalid YAML**: Files with syntax errors will cause spruce processing to fail with detailed error messages
- **Spruce operators**: Continue to process in the order files are received - use `genesis <env> yamls` to see processing order if getting unexpected values

### Circular Dependency Protection

The system includes built-in protection against circular dependencies:
- Files already in the processing chain are skipped
- Prevents infinite recursion loops

## Error Handling

The system provides comprehensive error handling:

### Invalid Inherits Format
```yaml
genesis:
  inherits: not-a-list  # ERROR: must be an array
```

### YAML Syntax Errors
Files with invalid YAML syntax will cause processing to fail with detailed error messages.

### Missing Files
If an inherited file doesn't exist, Genesis will continue processing (the file is simply skipped).

## Best Practices

### 1. Organize Common Configuration
```
environments/
├── common/
│   ├── base-security.yml
│   ├── monitoring.yml
│   └── networking.yml
├── us-west.yml
├── us-west-1.yml
└── us-west-1-prod.yml
```

### 2. Use Descriptive Names
```yaml
genesis:
  inherits:
    - common/base-security
    - common/monitoring
    - regional-settings
```

### 3. Layer Configuration Logically
- **Base layer**: Security, compliance, organizational standards
- **Regional layer**: Region-specific networking, availability zones
- **Environment layer**: Environment-specific overrides

### 4. Document Inheritance Chains
Include comments in your environment files:
```yaml
---
# Inherits base security and monitoring from common configs
genesis:
  inherits:
    - common/base-security    # Org security standards
    - common/monitoring       # Standard monitoring setup
```

## Troubleshooting

### Debug Inheritance Chain
To see which files are being processed:
```bash
genesis manifest --dry-run <env> 2>&1 | grep "Processing"
```

### Validate YAML Syntax
```bash
spruce merge --skip-eval environment-file.yml
```

### Check File Resolution
Ensure inherited files exist in the expected locations:
```bash
ls -la ./common-config.yml
ls -la .genesis/cached/$PREVIOUS_ENV/common-config.yml
```

## Examples

### Simple Shared Configuration
**File: `common-db.yml`**
```yaml
---
params:
  database_host: db.example.com
  database_port: 5432
  database_name: myapp
```

**File: `prod.yml`**
```yaml
---
genesis:
  inherits:
    - common-db

params:
  database_pool_size: 20
  database_ssl: true
```

### Multi-Layer Inheritance
**File: `foundation.yml`**
```yaml
---
params:
  bosh_director: bosh.foundation.com
  vault_url: https://vault.foundation.com
```

**File: `prod-foundation.yml`**
```yaml
---
genesis:
  inherits:
    - foundation

params:
  high_availability: true
  backup_schedule: "0 2 * * *"
```

**File: `us-west-1-prod.yml`**
```yaml
---
genesis:
  inherits:
    - prod-foundation

params:
  region: us-west-1
  availability_zones: [us-west-1a, us-west-1b, us-west-1c]
```

This creates the inheritance chain: `foundation.yml` → `prod-foundation.yml` → `us-west-1-prod.yml`

## Technical Implementation Details

### Core Components

The inheritance system is implemented through two main methods in `Genesis::Env`:

1. **`actual_environment_files()`** - The entry point that builds the complete list of files
2. **`_genesis_inherits()`** - The recursive method that processes inheritance chains

### Processing Flow

```
Environment File (e.g., us-west-1-prod.yml)
    ↓
actual_environment_files()
    ↓
For each hierarchical file that exists:
    ↓
_genesis_inherits(file, @accumulated_files)
    ↓
Parse file with spruce → Extract genesis.inherits → Process each inherited file recursively
    ↓
Return: [inherited_files..., original_file]
```

### Spruce Integration

Genesis uses spruce to parse environment files:
```bash
spruce merge --skip-eval --go-patch --multi-doc | spruce json
```

This ensures:
- Multi-document YAML support
- Go-patch operator handling
- Proper JSON conversion for parsing

### Memoization

The `actual_environment_files()` method uses memoization to cache results, improving performance for repeated calls.

### File Processing

Each inherited file is processed through the same `_genesis_inherits()` method, ensuring consistent behavior across the inheritance chain.

### Circular Dependency Prevention

The system prevents infinite recursion through a simple but effective mechanism:

```perl
# In _genesis_inherits method
next if grep {$_ eq $inherited_file} @files;
```

**How it works**:
1. The `@files` parameter contains all files processed so far in the current chain
2. Before processing an inherited file, Genesis checks if it's already in `@files`
3. If found, the file is skipped (`next`) and processing continues with the next inherited file
4. This prevents the same file from being processed multiple times in a single inheritance chain

**Parameter passing**: The method passes the accumulated file list through recursive calls:
```perl
push(@new_files, $self->_genesis_inherits($inherited_file,$file,@files,@new_files),$inherited_file);
```

The `@files` array grows with each recursive call, maintaining the complete history of processed files.
