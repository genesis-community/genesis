# Trace Logging

Genesis provides comprehensive trace logging capabilities for debugging complex issues. This guide covers how to enable, interpret, and use trace logs effectively.

## Enabling Trace Logging

### Command-Line Flag

The simplest way to enable tracing:

```bash
# Add --trace to any Genesis command
genesis manifest my-env --trace
genesis deploy my-env --trace
genesis check my-env --trace
```

### Environment Variable

Enable tracing for all commands:

```bash
# Set environment variable
export GENESIS_TRACE=1

# Now all commands include trace output
genesis manifest my-env
genesis deploy my-env

# Disable tracing
unset GENESIS_TRACE
```

### Debug Mode

For even more verbose output:

```bash
# Maximum verbosity
export GENESIS_DEBUG=1
export GENESIS_TRACE=1

genesis deploy my-env
```

## Understanding Trace Output

### Log Levels

Genesis uses different prefixes for log levels:

```
TRACE   - Detailed execution flow
DEBUG   - Debugging information
INFO    - General information
WARNING - Potential issues
ERROR   - Actual problems
```

### Trace Output Structure

```bash
# Example trace output
TRACE> Loading environment file: us.yml
TRACE> Loading environment file: us-east.yml
TRACE> Loading environment file: us-east-prod.yml
DEBUG> Merging 3 environment files with spruce
TRACE> Executing: spruce merge --skip-eval us.yml us-east.yml us-east-prod.yml
DEBUG> Environment merge completed
TRACE> Applying kit overlay: manifests/base.yml
TRACE> Applying feature overlay: manifests/features/ha.yml
```

## Common Trace Patterns

### Environment Loading

```bash
genesis manifest my-env --trace 2>&1 | grep "Loading"

# Output shows file loading order:
# TRACE> Loading environment file: us.yml
# TRACE> Loading environment file: us-east.yml
# TRACE> Loading environment file: us-east-1.yml
# TRACE> Loading kit manifest: manifests/base.yml
# TRACE> Loading kit manifest: manifests/features/ssl.yml
```

### Secret Resolution

```bash
genesis manifest my-env --trace 2>&1 | grep -E "(vault|secret)"

# Shows secret lookups:
# TRACE> Resolving secret: (( vault "secret/us/east/prod/admin:password" ))
# DEBUG> Executing: safe get secret/us/east/prod/admin:password
# TRACE> Secret resolved successfully
```

### Spruce Operations

```bash
genesis manifest my-env --trace 2>&1 | grep -E "(spruce|merge)"

# Shows merge operations:
# TRACE> Executing: spruce merge --skip-eval base.yml overrides.yml
# DEBUG> Spruce merge completed successfully
# TRACE> Executing: spruce eval manifest.yml
```

## Debugging Specific Issues

### Manifest Generation

**Trace manifest building process:**

```bash
# Save full trace
genesis manifest my-env --trace > manifest-trace.log 2>&1

# Analyze phases
echo "=== Phase Analysis ==="
grep -n "Phase:" manifest-trace.log

echo "=== File Loading ==="
grep -n "Loading" manifest-trace.log

echo "=== Merge Operations ==="
grep -n "merg" manifest-trace.log

echo "=== Errors ==="
grep -n -i "error" manifest-trace.log
```

### Feature Resolution

**Debug feature selection:**

```bash
genesis manifest my-env --trace 2>&1 | \
  grep -E "(feature|blueprint)" | \
  tee feature-trace.log

# Analyze feature application
grep "Applying feature" feature-trace.log
grep "blueprint hook" feature-trace.log
```

### Hook Execution

**Trace hook execution:**

```bash
# Enable hook tracing
GENESIS_TRACE=1 genesis new my-test-env 2>&1 | \
  grep -E "(hook|executing)"

# Shows:
# TRACE> Executing hook: new
# TRACE> Hook environment: GENESIS_ROOT=/path/to/repo
# TRACE> Hook environment: GENESIS_ENVIRONMENT=my-test-env
# DEBUG> Hook completed with exit code: 0
```

## Advanced Tracing

### Time-Based Analysis

```bash
# Add timestamps to trace
genesis manifest my-env --trace 2>&1 | \
  while IFS= read -r line; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S.%3N')] $line"
  done | tee timed-trace.log

# Find slow operations
awk '/TRACE.*Executing/ {
  cmd=$0; getline; 
  if (/completed/) print cmd " - " $0
}' timed-trace.log
```

### Filtered Tracing

```bash
# Trace only specific components
genesis manifest my-env --trace 2>&1 | \
  grep -E "(vault|secret|spruce)" > filtered-trace.log

# Trace errors and warnings only
genesis deploy my-env --trace 2>&1 | \
  grep -E "^(ERROR|WARNING)" > issues.log
```

### Structured Logging

```bash
#!/bin/bash
# structured-trace.sh

# Parse trace into JSON
genesis manifest my-env --trace 2>&1 | \
  perl -ne '
    if (/^(TRACE|DEBUG|INFO|WARNING|ERROR)>\s*(.*)/) {
      $level = $1;
      $msg = $2;
      $time = `date -u +%s`;
      chomp $time;
      print qq({"time":$time,"level":"$level","message":"$msg"}\n);
    }
  ' > trace.jsonl

# Query with jq
jq 'select(.level == "ERROR")' trace.jsonl
```

## Trace Log Analysis

### Common Patterns

**Identify bottlenecks:**

```bash
# Find long-running operations
genesis manifest my-env --trace --time 2>&1 | \
  grep -E "took [0-9]+\.[0-9]+s" | \
  sort -k2 -n -r | head -10
```

**Track execution flow:**

```bash
# Create execution graph
genesis manifest my-env --trace 2>&1 | \
  grep "TRACE>" | \
  awk '{$1=""; print NR ": " $0}' > execution-flow.txt
```

### Error Analysis

```bash
#!/bin/bash
# analyze-errors.sh

LOG_FILE="genesis-trace.log"
genesis deploy my-env --trace > $LOG_FILE 2>&1

echo "=== Error Summary ==="
grep -i "error" $LOG_FILE | wc -l
echo " errors found"

echo -e "\n=== Error Context ==="
grep -B5 -A5 -i "error" $LOG_FILE

echo -e "\n=== Failed Operations ==="
grep -E "(failed|exit code: [^0])" $LOG_FILE
```

## Performance Profiling

### Trace Timing

```bash
# Enable timing information
genesis manifest my-env --trace --time 2>&1 | \
  tee performance-trace.log

# Extract timing data
grep "took" performance-trace.log | \
  sed 's/.*took \([0-9.]*\)s.*/\1/' | \
  awk '{sum+=$1; count++} END {
    print "Total: " sum "s";
    print "Average: " sum/count "s";
  }'
```

### Operation Breakdown

```bash
# Categorize operations by time
genesis manifest my-env --trace --time 2>&1 | \
  grep -E "(Loading|Merging|Executing|Resolving).*took" | \
  awk -F'took ' '{
    split($1, op, ">");
    split($2, time, "s");
    category = op[2];
    gsub(/^[ \t]+|[ \t]+$/, "", category);
    split(category, cat, " ");
    times[cat[1]] += time[1];
    counts[cat[1]]++;
  }
  END {
    for (c in times) {
      printf "%-20s: %8.3fs (%d operations, avg: %.3fs)\n", 
        c, times[c], counts[c], times[c]/counts[c];
    }
  }' | sort -k2 -n -r
```

## Logging Best Practices

### 1. Targeted Tracing

Don't enable trace for everything:

```bash
# Good: Trace specific issue
genesis manifest problematic-env --trace > issue.log 2>&1

# Bad: Trace everything always
export GENESIS_TRACE=1  # In .bashrc
```

### 2. Log Rotation

Manage trace log files:

```bash
# Rotate logs script
#!/bin/bash
LOG_DIR="$HOME/.genesis/logs"
mkdir -p "$LOG_DIR"

# Run with logging
genesis deploy my-env --trace > \
  "$LOG_DIR/deploy-$(date +%Y%m%d-%H%M%S).log" 2>&1

# Clean old logs
find "$LOG_DIR" -name "*.log" -mtime +30 -delete
```

### 3. Structured Debugging

Create debugging workflows:

```bash
#!/bin/bash
# debug-deployment.sh

ENV=$1
ISSUE=$2
DEBUG_DIR="debug-$ENV-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$DEBUG_DIR"

echo "Collecting debug information for $ENV..."

# Manifest trace
genesis manifest $ENV --trace > \
  "$DEBUG_DIR/manifest-trace.log" 2>&1

# Check trace
genesis check $ENV --trace > \
  "$DEBUG_DIR/check-trace.log" 2>&1

# Environment info
genesis info $ENV > \
  "$DEBUG_DIR/info.txt" 2>&1

# Create summary
cat > "$DEBUG_DIR/summary.txt" <<EOF
Environment: $ENV
Issue: $ISSUE
Date: $(date)

Error Count: $(grep -i error $DEBUG_DIR/*.log | wc -l)
Warning Count: $(grep -i warning $DEBUG_DIR/*.log | wc -l)

First Error:
$(grep -i error $DEBUG_DIR/*.log | head -1)
EOF

echo "Debug information collected in $DEBUG_DIR/"
```

## Interpreting Common Traces

### Vault Connection Issues

```
TRACE> Resolving secret: (( vault "secret/path:key" ))
DEBUG> Executing: safe get secret/path:key
ERROR> Failed to retrieve secret: dial tcp 127.0.0.1:8200: connection refused
```

**Interpretation**: Vault is not accessible at the expected address.

### Merge Conflicts

```
TRACE> Executing: spruce merge base.yml overlay.yml
ERROR> merge conflict: key 'params.size' has conflicting values
DEBUG> base.yml defines params.size as integer
DEBUG> overlay.yml defines params.size as string
```

**Interpretation**: Type mismatch in parameter override.

### Missing Files

```
TRACE> Loading environment file: production.yml
TRACE> Looking for parent: prod.yml
ERROR> Could not find parent environment: prod.yml
TRACE> Searched in: ., .., ../..
```

**Interpretation**: Hierarchical environment file missing.

## Trace Output Reference

### Standard Trace Messages

| Pattern | Meaning |
|---------|---------|
| `Loading environment file:` | Reading YAML environment file |
| `Loading kit manifest:` | Reading kit-provided YAML |
| `Executing:` | Running external command |
| `Resolving secret:` | Looking up Vault secret |
| `Applying feature:` | Adding feature-specific configuration |
| `Merging files with spruce` | Combining YAML files |
| `Hook environment:` | Environment variables for hooks |
| `Validating manifest` | Pre-deployment checks |

### Debug Flags

| Flag | Purpose | Use Case |
|------|---------|----------|
| `--trace` | Enable trace logging | General debugging |
| `--debug` | Extra debug output | Deep troubleshooting |
| `--time` | Add timing information | Performance analysis |
| `--no-color` | Disable color output | Log processing |
| `--json` | JSON output (where supported) | Automation |

Trace logging is a powerful debugging tool. Use it judiciously to diagnose issues without overwhelming yourself with information.