# Kit Development Issues

This guide helps troubleshoot common problems encountered when developing Genesis kits.

## Development Environment Setup

### Kit Development Structure

```bash
my-kit/
├── kit.yml           # Kit metadata
├── manifests/        # BOSH manifests
│   ├── base.yml      # Base manifest
│   └── features/     # Feature-specific manifests
├── hooks/            # Lifecycle hooks
│   ├── blueprint     # Required: manifest selection
│   ├── new           # Environment creation
│   ├── check         # Pre-deployment validation
│   └── info          # Post-deployment information
└── spec/             # Test specifications
```

### Common Setup Issues

**Missing kit.yml:**
```bash
Error: Could not find kit.yml in current directory
```

**Solution:**
```bash
# Create minimal kit.yml
cat > kit.yml <<EOF
name: my-kit
version: 0.1.0
authors:
  - Your Name <you@example.com>
EOF
```

**Invalid directory structure:**
```bash
Error: No manifests directory found
```

**Solution:**
```bash
# Create required directories
mkdir -p manifests/features hooks
touch manifests/base.yml
chmod +x hooks/*
```

## Hook Development Issues

### Hook Not Executing

**Symptoms:**
```
Hook 'new' not found or not executable
```

**Diagnostics:**
```bash
# Check file existence and permissions
ls -la hooks/
file hooks/new
bash -n hooks/new  # Syntax check
```

**Solutions:**
```bash
# Fix permissions
chmod +x hooks/*

# Add shebang
echo '#!/bin/bash' | cat - hooks/new > temp && mv temp hooks/new

# Test directly
cd /path/to/kit
GENESIS_ENVIRONMENT=test ./hooks/new
```

### Hook Environment Variables

**Missing variables:**
```bash
# Debug hook environment
cat > hooks/debug <<'EOF'
#!/bin/bash
echo "=== Genesis Environment Variables ==="
env | grep GENESIS | sort
echo "=== Other Relevant Variables ==="
echo "PATH: $PATH"
echo "PWD: $PWD"
EOF
chmod +x hooks/debug
```

**Common required variables:**
```bash
#!/bin/bash
# In hook scripts

# Always available
echo "Kit: $GENESIS_KIT_NAME v$GENESIS_KIT_VERSION"
echo "Environment: $GENESIS_ENVIRONMENT"
echo "Root: $GENESIS_ROOT"

# Hook-specific
echo "Vault prefix: ${GENESIS_SECRETS_PATH:-$GENESIS_VAULT_PREFIX}"
echo "Features: $GENESIS_REQUESTED_FEATURES"
```

### Blueprint Hook Issues

**No manifests returned:**
```bash
Error: Blueprint hook returned no manifest files
```

**Debug blueprint:**
```bash
#!/bin/bash
# hooks/blueprint
set -eu

# Debug mode
if [[ "${GENESIS_TRACE:-}" == "1" ]]; then
  set -x
fi

# Always include base
echo "manifests/base.yml"

# Add features
for feature in $GENESIS_REQUESTED_FEATURES; do
  case "$feature" in
    ha|ssl|monitoring)
      if [[ -f "manifests/features/$feature.yml" ]]; then
        echo "manifests/features/$feature.yml"
      else
        echo >&2 "Warning: Feature $feature requested but manifests/features/$feature.yml not found"
      fi
      ;;
    *)
      echo >&2 "Error: Unknown feature: $feature"
      exit 1
      ;;
  esac
done
```

### Check Hook Validation

**Hook failing silently:**
```bash
# Add debugging to check hook
#!/bin/bash
# hooks/check
set -eu

# Enable tracing
[[ "${GENESIS_TRACE:-}" == "1" ]] && set -x

# Verbose error reporting
error() {
  echo >&2 "CHECK FAILED: $*"
  exit 1
}

# Check cloud config
echo "Checking cloud config..."
if ! cloud_config_has vm_type "small"; then
  error "Cloud config missing required vm_type 'small'"
fi

echo "All checks passed!"
```

## Manifest Issues

### YAML Syntax Errors

**Invalid YAML:**
```bash
Error: yaml: line 10: found character that cannot start any token
```

**Debugging:**
```bash
# Validate all YAML files
for file in manifests/**/*.yml; do
  echo "Checking $file..."
  yaml-lint "$file" || yamllint "$file"
done

# Common issues:
# - Tabs instead of spaces
# - Incorrect indentation
# - Missing quotes around values with colons
```

### Spruce Errors

**Merge failures:**
```bash
Error: spruce merge failed: conflicting key types
```

**Debug approach:**
```bash
# Test manifest merging
cd /path/to/kit

# Base only
spruce merge manifests/base.yml

# With features
spruce merge manifests/base.yml manifests/features/ha.yml

# With environment
cat > test-env.yml <<EOF
params:
  env: test
EOF
spruce merge manifests/base.yml test-env.yml
```

### Missing Parameters

**Undefined parameters:**
```bash
Error: (( grab params.missing )) could not be resolved
```

**Solution:**
```yaml
# In manifests/base.yml
params:
  # Provide defaults
  missing: (( grab params.missing || "default-value" ))
  
  # Or make required with clear error
  required: (( grab params.required || "REQUIRED: Set params.required in environment file" ))
```

## Feature Development

### Feature Not Loading

**Feature manifest not applied:**
```bash
# Debug feature loading
GENESIS_REQUESTED_FEATURES="myfeature" ./hooks/blueprint
```

**Common issues:**
1. Feature file missing
2. Blueprint hook not handling feature
3. Feature name mismatch

**Solution:**
```bash
# Ensure feature file exists
touch manifests/features/myfeature.yml

# Update blueprint hook
case "$feature" in
  myfeature)
    echo "manifests/features/myfeature.yml"
    ;;
esac
```

### Feature Conflicts

**Incompatible features:**
```bash
Error: Features 'azure' and 'aws' are mutually exclusive
```

**Implement validation:**
```bash
#!/bin/bash
# hooks/blueprint

# Check for conflicts
features=($GENESIS_REQUESTED_FEATURES)

if [[ " ${features[@]} " =~ " aws " ]] && [[ " ${features[@]} " =~ " azure " ]]; then
  echo >&2 "Error: Cannot use both 'aws' and 'azure' features"
  exit 1
fi
```

## Testing Issues

### Local Testing

**Test kit without compilation:**
```bash
# Use dev directory
mkdir -p ~/deployments/test-kit
cd ~/deployments/test-kit
genesis init --kit /path/to/kit/dev

# Create test environment
genesis new test-env
```

**Mock Genesis environment:**
```bash
#!/bin/bash
# test-kit.sh

export GENESIS_KIT_NAME="my-kit"
export GENESIS_KIT_VERSION="0.1.0"
export GENESIS_ENVIRONMENT="test"
export GENESIS_ROOT="/tmp/test-deployments"
export GENESIS_SECRETS_PATH="test/env"
export GENESIS_REQUESTED_FEATURES="ha ssl"
export GENESIS_TRACE=1

mkdir -p "$GENESIS_ROOT"

# Test hooks
echo "=== Testing blueprint hook ==="
./hooks/blueprint

echo "=== Testing new hook ==="
./hooks/new
```

### Spec Test Failures

**Ginkgo test issues:**
```bash
# Run tests with verbose output
cd spec
ginkgo -v --trace

# Run specific test
ginkgo --focus "should deploy with HA"
```

**Common test problems:**

```go
// spec/spec_test.go
var _ = Describe("My Kit", func() {
  BeforeEach(func() {
    // Ensure clean state
    Setup(kit, "default")
  })

  It("should have required properties", func() {
    manifest := Manifest()
    
    // Debug manifest
    fmt.Printf("Manifest: %+v\n", manifest)
    
    // Assertions with clear errors
    Expect(manifest).NotTo(BeNil(), 
      "Manifest should not be nil")
    Expect(manifest.InstanceGroups).To(HaveLen(1), 
      "Should have exactly one instance group")
  })
})
```

## Compilation Issues

### Kit Compilation Failures

**Compilation errors:**
```bash
Error: Failed to compile kit: manifest validation failed
```

**Debug compilation:**
```bash
# Compile with verbose output
genesis compile-kit --name my-kit --version 0.1.0 --verbose

# Dev compilation (no tarball)
genesis compile-kit --dev

# Force recompilation
rm -rf .genesis/kits/my-kit*
genesis compile-kit
```

### Packaging Problems

**Missing files in compiled kit:**
```bash
# Check kit contents
tar -tzf my-kit-0.1.0.tar.gz | grep -E "(hooks|manifests)"

# Ensure files are tracked
git add -A
genesis compile-kit --version 0.1.0
```

## Runtime Issues

### Memory/Performance

**Slow manifest generation:**
```bash
# Profile manifest generation
time genesis manifest test-env

# Optimize spruce operations
# Bad: Multiple grabs
a: (( grab params.a ))
b: (( grab params.b ))
c: (( grab params.c ))

# Better: Single grab
_params: (( grab params ))
a: (( grab _params.a ))
b: (( grab _params.b ))
c: (( grab _params.c ))
```

### Large Manifests

**Memory exhaustion:**
```bash
# Split large arrays
# Instead of inline:
instances:
  - { name: web-1, ... }
  - { name: web-2, ... }
  # ... 100 more

# Use references:
instance_definitions:
  web: { ... }
instances:
  - (( grab instance_definitions.web ))
  - (( grab instance_definitions.web ))
```

## Debugging Tools

### Kit Validation Script

```bash
#!/bin/bash
# validate-kit.sh

echo "=== Validating Kit Structure ==="

# Check required files
required_files="kit.yml manifests/base.yml hooks/blueprint"
for file in $required_files; do
  if [[ -f "$file" ]]; then
    echo "✓ $file exists"
  else
    echo "✗ $file missing"
    exit 1
  fi
done

# Check hook permissions
for hook in hooks/*; do
  if [[ -x "$hook" ]]; then
    echo "✓ $hook is executable"
  else
    echo "✗ $hook not executable"
  fi
done

# Validate YAML
for yaml in manifests/**/*.yml; do
  if yamllint "$yaml" >/dev/null 2>&1; then
    echo "✓ $yaml valid"
  else
    echo "✗ $yaml invalid"
    yamllint "$yaml"
  fi
done

echo "=== Testing Blueprint ==="
GENESIS_REQUESTED_FEATURES="" ./hooks/blueprint
```

### Development Workflow

```bash
#!/bin/bash
# dev-workflow.sh

# 1. Make changes
vi manifests/base.yml

# 2. Validate
./validate-kit.sh

# 3. Test locally
cd ~/deployments/test
genesis manifest test-env

# 4. Run tests
cd spec && ginkgo

# 5. Compile
genesis compile-kit --dev

# 6. Full test
genesis deploy test-env --dry-run
```

## Best Practices

1. **Always test locally** before committing
2. **Use trace mode** for debugging: `GENESIS_TRACE=1`
3. **Validate YAML** syntax regularly
4. **Test each feature** independently
5. **Document complex logic** in comments
6. **Handle errors gracefully** in hooks
7. **Provide helpful error messages**

Kit development requires attention to detail and systematic testing. Use these debugging techniques to identify and resolve issues quickly.