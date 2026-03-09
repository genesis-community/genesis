# Genesis::run Function Reference

## Overview

`Genesis::run` is the primary function for executing external commands in Genesis hooks. It provides controlled command execution with comprehensive error handling, output capture, and debugging support.

## Basic Syntax

```perl
# Simple execution
my $output = run('command', 'arg1', 'arg2');

# With options
my ($output, $rc, $stderr) = run({options}, 'command', 'args...');
```

## Options

The function accepts an optional hash reference as the first parameter with the following options:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `onfailure` | String | - | Error message to display and bail if command fails |
| `stderr` | String/Int | '&1' | How to handle stderr: `0` (capture), `/dev/null` (discard), or file path |
| `interactive` | Boolean | 0 | Run command interactively (for user-facing commands) |
| `env` | Hash | {} | Environment variables to set/override |
| `redact_env` | Boolean | 0 | Hide environment values in debug logs |
| `redact_output` | Boolean | 0 | Redact command output in debug logs |
| `dir` | String | - | Directory to run command in |
| `passfail` | Boolean | 0 | Return boolean success instead of output |
| `shell` | String | '/bin/bash' | Shell to use for command execution |

## Return Values

The function has context-sensitive return values:

### Scalar Context
- Returns stdout if successful
- Returns stderr if command failed and stderr exists
- Returns stdout otherwise

### List Context
- Returns `($stdout, $exit_code, $stderr)`
- For interactive mode: `(undef, $exit_code)`

### Special Cases
- With `passfail` option: Returns boolean (true if exit code is 0)

## Common Hook Patterns

### 1. Run Command with Error Handling

```perl
run({onfailure => "Failed to deploy BOSH"}, 
    'bosh', '-n', '-d', $self->env->name, 'deploy', $manifest_file);
```

### 2. Parse Command Output

When parsing JSON or YAML output, always use `stderr => 0` to prevent stderr from contaminating the output:

```perl
my $json = run({stderr => 0}, 'vault', 'read', '-format=json', $path);
my $data = read_json_from($json);
```

### 3. Check Command Success

```perl
if (run({passfail => 1}, 'safe', 'exists', $path)) {
    # Path exists in vault
}
```

### 4. Interactive Commands

```perl
run({interactive => 1}, 'safe', 'set', $path);
```

### 5. Capture All Outputs

```perl
my ($out, $rc, $err) = run({stderr => 0}, 'command');
if ($rc != 0) {
    error "Command failed: $err";
}
```

### 6. Set Environment Variables

```perl
my $result = run({
    env => {
        VAULT_ADDR => 'https://vault.example.com',
        VAULT_TOKEN => $token
    },
    redact_env => 1
}, 'vault', 'read', 'secret/path');
```

### 7. Run in Specific Directory

```perl
run({
    dir => '/path/to/project'
}, 'make', 'test');
```

## Handling Sensitive Data

### Redacting Arguments

Arguments can include redaction directives for sensitive data:

```perl
run('command', '--password', {redact => $secret_password});
```

### Redacting Environment

```perl
run({
    env => { SECRET_TOKEN => $token },
    redact_env => 1,
    redact_output => 1
}, 'command-using-secrets');
```

## Best Practices

1. **Always use `stderr => 0` when parsing command output** to avoid stderr contaminating the parsed data.

2. **Use `onfailure` for critical operations** that should stop hook execution on failure.

3. **Capture all return values** when you need detailed error information:
   ```perl
   my ($out, $rc, $err) = run({...}, 'command');
   if ($rc != 0) {
       # Handle error with access to stderr
   }
   ```

4. **Use `passfail` for existence checks** or when you only care about success/failure:
   ```perl
   return run({passfail => 1}, 'which', $command);
   ```

5. **Prefer `interactive` for user-facing commands** like editors or password prompts:
   ```perl
   run({interactive => 1}, 'vi', $filename);
   ```

6. **Redact sensitive information** in logs using `redact_env` and `redact_output` options.

## Error Handling

When `onfailure` is set, the function will automatically call `bail` with the provided message if the command fails. This is the preferred method for critical operations:

```perl
run({onfailure => "Could not connect to BOSH"}, 
    'bosh', 'env');
```

Without `onfailure`, you must handle errors manually:

```perl
my ($out, $rc, $err) = run('command');
if ($rc != 0) {
    bail "Command failed with exit code $rc: $err";
}
```

## Notes

- The function automatically logs commands in debug mode
- Environment changes are temporary and scoped to the command execution
- Shell variable expansion is supported in the command string
- Binary output is detected and handled appropriately
- The function integrates with Genesis's trace/debug logging system