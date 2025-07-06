# Manifest Debugging

This guide helps troubleshoot issues with Genesis manifest generation, merging, and validation.

## Understanding Manifest Generation

### The Manifest Pipeline

Genesis builds manifests through several stages:

1. **Environment Resolution** - Load environment files hierarchically
2. **Kit Integration** - Apply base manifest and features
3. **Parameter Injection** - Add environment-specific parameters
4. **Secret Resolution** - Replace Vault references
5. **Final Evaluation** - Process Spruce operators

## Common Manifest Issues

### Merge Conflicts

**Symptom:**
```
Error: merge conflict detected
```

**Debug approach:**

```bash
# Identify conflict source
genesis manifest my-env --trace 2>&1 | grep -B10 "conflict"

# Test individual merges
spruce merge base.yml overlay.yml

# Show differences
spruce diff base.yml overlay.yml
```

**Common solutions:**

```yaml
# Problem: Array merge conflict
# base.yml
instances:
  - name: web
  - name: api

# overlay.yml  
instances:  # This replaces instead of merging
  - name: worker

# Solution: Use explicit array indices or replace operator
instances:
  - (( replace ))
  - name: worker

# Or use index notation
instances.2:
  name: worker
```

### Missing Parameters

**Symptom:**
```
Error: (( grab params.missing_value )) could not be resolved
```

**Debug approach:**

```bash
# List all grab operations
genesis manifest my-env --no-resolve | \
  grep -o "(( grab [^)]*" | sort -u

# Check parameter definitions
genesis manifest my-env | \
  spruce json | jq '.params' | \
  grep -i "missing_value"
```

**Solutions:**

```yaml
# Add default values
value: (( grab params.optional || "default" ))

# Or define in environment
params:
  missing_value: "now defined"
```

### Type Mismatches

**Symptom:**
```
Error: cannot merge string with array
```

**Debug approach:**

```bash
# Find type conflicts
genesis manifest my-env --trace 2>&1 | \
  grep -E "(cannot merge|type mismatch)"

# Check data types
spruce json base.yml | jq '.path.to.value'
spruce json overlay.yml | jq '.path.to.value'
```

**Solutions:**

```yaml
# Ensure consistent types
# Bad:
base.yml:    ports: "8080"
overlay.yml: ports: [8080, 8443]

# Good:
base.yml:    ports: ["8080"]
overlay.yml: ports: ["8080", "8443"]
```

## Advanced Debugging Techniques

### Partial Manifest Generation

Build manifests step-by-step:

```bash
# 1. Base manifest only
cat > debug-base.yml <<EOF
---
meta:
  kit: my-kit
  env: my-env
EOF

spruce merge \
  dev/manifests/base.yml \
  debug-base.yml > step1.yml

# 2. Add features
spruce merge \
  step1.yml \
  dev/manifests/features/ha.yml > step2.yml

# 3. Add environment
spruce merge \
  step2.yml \
  my-env.yml > step3.yml

# Compare with full generation
genesis manifest my-env > full.yml
diff step3.yml full.yml
```

### Operator Debugging

Debug Spruce operators:

```bash
# Extract operators
genesis manifest my-env --no-resolve | \
  grep -E "\(\(" | \
  sed 's/.*\(\((.*)\)\).*/\1/' | \
  sort | uniq -c | sort -nr

# Test operators individually
cat > test-operator.yml <<EOF
test:
  value: (( grab params.test || "default" ))
  concat: (( concat "hello-" meta.env ))
  vault: (( vault "path:key" ))
EOF

spruce merge test-operator.yml
```

### Trace Variable Resolution

```bash
#!/bin/bash
# trace-variables.sh

ENV=$1
VAR=$2

echo "Tracing variable: $VAR"

# Find definition
echo "=== Definitions ==="
grep -r "$VAR:" . --include="*.yml" | grep -v ".genesis"

# Find references  
echo "=== References ==="
genesis manifest $ENV --no-resolve | grep -n "$VAR"

# Trace resolution
echo "=== Resolution Trace ==="
genesis manifest $ENV --trace 2>&1 | grep -A5 -B5 "$VAR"
```

## Manifest Validation

### Pre-flight Checks

```bash
# Validate YAML syntax
for file in *.yml; do
  echo "Checking $file..."
  yaml-lint "$file" || yamllint "$file"
done

# Check manifest structure
genesis manifest my-env | \
  bosh int - --path /name >/dev/null && echo "Name: OK"

genesis manifest my-env | \
  bosh int - --path /instance_groups >/dev/null && echo "Instance Groups: OK"
```

### BOSH Validation

```bash
# Full BOSH validation
genesis manifest my-env > manifest.yml
bosh int manifest.yml

# Check specific paths
bosh int manifest.yml --path /instance_groups/0/name
bosh int manifest.yml --path /releases
bosh int manifest.yml --path /stemcells
```

### Schema Validation

```yaml
# Create validation schema
# schema.yml
type: map
mapping:
  name:
    type: str
    required: true
  instance_groups:
    type: seq
    sequence:
      - type: map
        mapping:
          name: 
            type: str
            required: true
          instances:
            type: int
            range:
              min: 1
```

```bash
# Validate against schema
genesis manifest my-env | \
  python -c "import yaml, sys; yaml.safe_load(sys.stdin)" && \
  echo "Valid YAML structure"
```

## Debugging Merge Order

### Trace File Loading

```bash
# Show merge order
genesis manifest my-env --trace 2>&1 | \
  grep "Loading" | nl

# Visualize hierarchy
genesis manifest my-env --trace 2>&1 | \
  grep "Loading environment" | \
  sed 's/.*Loading environment file: //' | \
  awk '{print NR-1 ":" $0}' | \
  sed 's/^/  /' | sed 's/^  0://'
```

### Test Merge Order Impact

```bash
#!/bin/bash
# test-merge-order.sh

# Test different merge orders
echo "=== Original Order ==="
spruce merge a.yml b.yml c.yml | spruce json

echo "=== Reversed Order ==="
spruce merge c.yml b.yml a.yml | spruce json

echo "=== Differences ==="
diff <(spruce merge a.yml b.yml c.yml | spruce json) \
     <(spruce merge c.yml b.yml a.yml | spruce json)
```

## Secret Debugging

### Mock Secrets for Testing

```bash
# Test without Vault
genesis manifest my-env --no-resolve > manifest-no-secrets.yml

# Create mock secrets
cat > mock-secrets.yml <<EOF
params:
  admin_password: "mock-password"
  ssl_cert: |
    -----BEGIN CERTIFICATE-----
    MOCK CERTIFICATE
    -----END CERTIFICATE-----
EOF

# Merge with mocks
spruce merge manifest-no-secrets.yml mock-secrets.yml
```

### Trace Secret Resolution

```bash
# Find all Vault references
genesis manifest my-env --no-resolve | \
  grep -o '(( *vault *"[^"]*" *))' | \
  sed 's/.* "\([^"]*\)".*/\1/' | \
  sort -u > vault-paths.txt

# Check each path
while read -r path; do
  echo -n "Checking $path: "
  safe exists "$path" && echo "EXISTS" || echo "MISSING"
done < vault-paths.txt
```

## Common Patterns and Solutions

### Array Manipulation

```yaml
# Appending to arrays
base_array:
  - item1
  - item2

# Append
extended_array: (( concat base_array "[\"item3\"]" ))

# Prepend  
extended_array: (( concat "[\"item0\"]" base_array ))

# Replace specific index
base_array.1: "modified_item2"
```

### Conditional Inclusion

```yaml
# Include based on feature
instance_groups:
  - name: web
    instances: 2
  - (( grab meta.ha_enabled ? ha_instances : null ))

ha_instances:
  name: web-ha
  instances: 3

meta:
  ha_enabled: (( grab params.enable_ha || false ))
```

### Deep Merging

```yaml
# Control merge behavior
properties:
  # Deep merge (default)
  database:
    host: localhost
    port: 5432
  
  # Replace entire structure
  redis: (( replace ))
    host: redis.example.com
    port: 6379
```

## Troubleshooting Workflow

### 1. Isolate the Problem

```bash
# Generate partial manifests
genesis manifest my-env --partial base > base-only.yml
genesis manifest my-env --partial features > with-features.yml
genesis manifest my-env --no-resolve > without-secrets.yml
genesis manifest my-env > complete.yml

# Compare stages
diff base-only.yml with-features.yml
diff with-features.yml without-secrets.yml
diff without-secrets.yml complete.yml
```

### 2. Binary Search

```bash
#!/bin/bash
# Find problematic file

files=(base.yml feature1.yml feature2.yml env.yml)
working=()

for file in "${files[@]}"; do
  if spruce merge "${working[@]}" "$file" >/dev/null 2>&1; then
    working+=("$file")
    echo "✓ $file merges successfully"
  else
    echo "✗ $file causes merge failure"
    spruce merge "${working[@]}" "$file"
    break
  fi
done
```

### 3. Manual Resolution

```bash
# Step through resolution
cat > manual-test.yml <<EOF
test1: (( grab params.value || "default" ))
test2: (( vault "secret/path:key" || "vault-default" ))
test3: (( concat "prefix-" params.name "-suffix" ))
EOF

# Test each operator
echo 'params: {value: "test", name: "myapp"}' | \
  spruce merge - manual-test.yml
```

## Prevention Strategies

### 1. Validate Early

Add pre-commit hooks:

```bash
#!/bin/bash
# .git/hooks/pre-commit

# Check YAML syntax
for file in $(git diff --cached --name-only | grep "\.yml$"); do
  yaml-lint "$file" || exit 1
done

# Test manifest generation
genesis manifest "*" --no-resolve >/dev/null || exit 1
```

### 2. Use Explicit Operations

```yaml
# Be explicit about intentions
array_items:
  - (( append ))  # Clearly append
  - new_item

replaced_value: (( replace ))  # Clearly replace
  completely: new

merged_map:  # Default deep merge
  existing_key: modified_value
  new_key: new_value
```

### 3. Document Complex Merges

```yaml
# Document merge behavior
instance_groups:
  # This will be modified by HA feature to add instances
  # DO NOT use (( replace )) here
  - name: web
    instances: (( grab params.web_instances || 1 ))
```

Effective manifest debugging requires understanding both the Genesis merging process and Spruce operators. Use systematic approaches to isolate and resolve issues.