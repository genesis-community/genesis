# Kit Testing

Testing Genesis kits ensures they work correctly across different scenarios and configurations. This guide covers testing strategies, tools, and best practices.

## Testing Overview

Kit testing involves:
- Unit testing individual hooks
- Integration testing with Genesis
- Manifest generation validation  
- Secret generation verification
- Deployment testing with BOSH

## Testing Tools

### Spec Testing with Ginkgo

Genesis kits use Ginkgo for automated testing:

```bash
# Install Ginkgo
go get -u github.com/onsi/ginkgo/ginkgo
go get -u github.com/onsi/gomega/...

# Run tests
cd spec
ginkgo -p
```

### Basic Spec Structure

```go
// spec/spec_test.go
package spec_test

import (
    . "github.com/genesis-community/testkit/testing"
    . "github.com/onsi/ginkgo"
    . "github.com/onsi/gomega"
)

var _ = Describe("My Kit", func() {
    kit := "my-software"
    
    Context("Base Manifest", func() {
        BeforeEach(func() {
            Setup(kit, "default")
        })
        
        It("uses the requested VM type", func() {
            manifest := Manifest(
                WithParam("vm_type", "large"),
            )
            Expect(manifest).To(HaveInstanceGroup("my-software", 
                WithVMType("large")))
        })
    })
})
```

## Hook Testing

### Testing the `new` Hook

Create a test wrapper for the `new` hook:

```bash
#!/bin/bash
# test/test-new-hook.sh

# Mock Genesis environment
export GENESIS_ROOT="/tmp/test-$$"
export GENESIS_ENVIRONMENT="test-env"
export GENESIS_SECRETS_PATH="test/env"
export GENESIS_MIN_VERSION="2.8.0"

mkdir -p "$GENESIS_ROOT"

# Mock prompt_for responses
cat > /tmp/responses <<EOF
example.com
y
3
aws
EOF

# Run hook with mocked input
../hooks/new < /tmp/responses

# Validate output
if [[ ! -f "$GENESIS_ROOT/test-env.yml" ]]; then
    echo "FAIL: Environment file not created"
    exit 1
fi

# Check content
if ! grep -q "base_domain: example.com" "$GENESIS_ROOT/test-env.yml"; then
    echo "FAIL: base_domain not set correctly"
    exit 1
fi

echo "PASS: new hook test"
```

### Testing the `blueprint` Hook

```bash
#!/bin/bash
# test/test-blueprint-hook.sh

# Test base blueprint
export GENESIS_REQUESTED_FEATURES=""
output=$(../hooks/blueprint)
expected="manifests/base.yml"

if [[ "$output" != "$expected" ]]; then
    echo "FAIL: Base blueprint incorrect"
    echo "Expected: $expected"
    echo "Got: $output"
    exit 1
fi

# Test with features
export GENESIS_REQUESTED_FEATURES="ha monitoring"
output=$(../hooks/blueprint)

if [[ "$output" != *"manifests/features/ha.yml"* ]]; then
    echo "FAIL: HA feature not included"
    exit 1
fi

echo "PASS: blueprint hook test"
```

### Testing the `check` Hook

```bash
#!/bin/bash
# test/test-check-hook.sh

# Mock BOSH cloud config check
cloud_config_has() {
    case "$1" in
        vm_type)
            [[ "$2" == "default" ]] && return 0
            ;;
    esac
    return 1
}
export -f cloud_config_has

# Test valid configuration
export GENESIS_CLOUD_CONFIG="{}"
../hooks/check && echo "PASS: Valid config accepted"

# Test invalid VM type
export vm_type="invalid"
if ../hooks/check 2>/dev/null; then
    echo "FAIL: Invalid VM type not caught"
    exit 1
fi

echo "PASS: check hook test"
```

## Manifest Testing

### Testing Manifest Generation

```bash
#!/bin/bash
# test/test-manifests.sh

kit_dir="$(cd ..; pwd)"

# Test base manifest
genesis compile-kit --dev --name test
genesis new test-base --kit test

# Validate structure
genesis manifest test-base > /tmp/manifest.yml
bosh int /tmp/manifest.yml --path /name | grep -q "test-base"
```

### Spec Tests for Manifests

```go
var _ = Describe("Manifest Generation", func() {
    Context("with HA feature", func() {
        BeforeEach(func() {
            Setup(kit, "ha")
        })
        
        It("creates 3 instances", func() {
            manifest := Manifest()
            ig := manifest.InstanceGroups.Lookup("my-software")
            Expect(ig.Instances).To(Equal(3))
        })
        
        It("enables clustering", func() {
            manifest := Manifest()
            props := manifest.InstanceGroups.Lookup("my-software").
                Jobs[0].Properties
            Expect(props).To(HaveKeyWithValue("cluster", 
                HaveKeyWithValue("enabled", true)))
        })
    })
})
```

## Secret Testing

### Testing Secret Generation

```go
var _ = Describe("Secrets", func() {
    It("generates required passwords", func() {
        manifest := Manifest()
        
        // Check password references
        Expect(manifest).To(HaveSecret("admin_password"))
        Expect(manifest).To(HaveSecret("database_password"))
    })
    
    It("generates certificates with correct SANs", func() {
        manifest := Manifest(
            WithParam("base_domain", "example.com"),
        )
        
        cert := GetCertificate("server")
        Expect(cert.SANs).To(ContainElement("*.example.com"))
    })
})
```

### Manual Secret Testing

```bash
#!/bin/bash
# test/test-secrets.sh

# Create test Vault
safe target test --memory
safe auth

# Test secret generation
export VAULT_PREFIX="secret/test"
genesis add-secrets test-env

# Verify secrets created
safe exists secret/test/admin:password || exit 1
safe exists secret/test/ssl/ca:certificate || exit 1

echo "PASS: Secrets generated correctly"
```

## Integration Testing

### Full Deployment Test

```bash
#!/bin/bash
# test/integration-test.sh

# Setup
genesis init --kit ../my-kit test-deployments
cd test-deployments

# Create test environment
genesis new integration-test <<EOF
example.com
n
1
vsphere
EOF

# Check and deploy
genesis check integration-test
genesis deploy integration-test --dry-run

# Verify deployment
genesis manifest integration-test | \
    bosh int - --path /instance_groups/0/instances | \
    grep -q "1" || exit 1

echo "PASS: Integration test"
```

### CI/CD Pipeline Tests

```yaml
# ci/test.yml
---
platform: linux
image_resource:
  type: docker-image
  source:
    repository: genesiscommunity/testing

inputs:
- name: kit

run:
  path: bash
  args:
  - -c
  - |
    cd kit
    export GENESIS_TESTING=1
    
    # Run spec tests
    cd spec && ginkgo -p
    
    # Run hook tests
    cd ../test
    for test in test-*.sh; do
      echo "Running $test..."
      ./$test || exit 1
    done
```

## Testing Best Practices

### 1. Test Matrix

Create a test matrix for feature combinations:

```markdown
| Base | HA | SSL | Monitoring | Expected Result |
|------|----|-----|------------|-----------------|
| ✓    | ✗  | ✗   | ✗          | 1 instance      |
| ✓    | ✓  | ✗   | ✗          | 3 instances     |
| ✓    | ✓  | ✓   | ✗          | 3 + SSL enabled |
| ✓    | ✓  | ✓   | ✓          | Full features   |
```

### 2. Mock External Dependencies

```bash
# Mock BOSH commands
bosh() {
    case "$1" in
        cloud-config)
            cat test/fixtures/cloud-config.yml
            ;;
        *)
            command bosh "$@"
            ;;
    esac
}
export -f bosh
```

### 3. Test Error Conditions

```go
It("fails with invalid VM type", func() {
    _, err := ManifestWithError(
        WithParam("vm_type", "nonexistent"),
    )
    Expect(err).To(HaveOccurred())
    Expect(err.Error()).To(ContainSubstring("VM type"))
})
```

### 4. Use Fixtures

```
test/fixtures/
├── cloud-config.yml
├── valid-cert.pem
├── valid-key.pem
└── sample-manifest.yml
```

### 5. Parameterized Tests

```go
var _ = Describe("IaaS Support", func() {
    testIaaS := func(iaas string, expectedStemcell string) {
        Context("on "+iaas, func() {
            BeforeEach(func() {
                Setup(kit, iaas)
            })
            
            It("uses correct stemcell", func() {
                manifest := Manifest()
                Expect(manifest.Stemcells[0].OS).To(Equal(expectedStemcell))
            })
        })
    }
    
    testIaaS("aws", "ubuntu-jammy")
    testIaaS("azure", "ubuntu-jammy")
    testIaaS("vsphere", "ubuntu-jammy")
})
```

## Debugging Tests

### Enable Debug Output

```bash
# For hook tests
export DEBUG=1
export GENESIS_DEBUG=1

# For spec tests
ginkgo -v --trace
```

### Inspect Generated Files

```bash
# Keep temporary files
export GENESIS_TESTING_DO_NOT_CLEAN_UP=1

# Check generated manifests
ls -la /tmp/genesis-test-*
```

### Common Issues

#### Missing Dependencies

```bash
# Check for required commands
for cmd in spruce safe vault bosh; do
    command -v $cmd || echo "Missing: $cmd"
done
```

#### Path Issues

```bash
# Ensure proper paths
export PATH="$PATH:$HOME/bin:/usr/local/bin"
export GENESIS_LIB="${GENESIS_LIB:-/usr/local/lib/genesis}"
```

## Continuous Testing

### Pre-commit Hooks

```bash
#!/bin/bash
# .git/hooks/pre-commit

# Run fast tests before commit
cd spec && ginkgo --failFast || exit 1
cd ../test && ./test-blueprint-hook.sh || exit 1

echo "All tests passed!"
```

### Automated Testing

```yaml
# .github/workflows/test.yml
name: Test Kit
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v2
    
    - name: Setup Go
      uses: actions/setup-go@v2
      with:
        go-version: 1.17
        
    - name: Install Dependencies
      run: |
        go get -u github.com/onsi/ginkgo/ginkgo
        go get -u github.com/onsi/gomega/...
        
    - name: Run Tests
      run: |
        cd spec && ginkgo -p --race --randomizeAllSpecs
```

## Performance Testing

### Manifest Generation Speed

```bash
#!/bin/bash
# test/benchmark.sh

time_genesis() {
    local features=$1
    local start=$(date +%s.%N)
    
    genesis manifest test-env > /dev/null
    
    local end=$(date +%s.%N)
    echo "$features: $(echo "$end - $start" | bc)s"
}

# Test different feature combinations
time_genesis ""
time_genesis "ha"
time_genesis "ha monitoring ssl"
```

### Memory Usage

```bash
# Monitor memory during tests
/usr/bin/time -v genesis manifest large-env 2>&1 | \
    grep "Maximum resident set size"
```

Testing thoroughly ensures your kit works reliably across all supported configurations and provides a good user experience.