# Genesis::run() Function Documentation

The `Genesis::run()` function is a powerful utility for executing external commands with extensive configuration options. It provides a unified interface for command execution with support for environment variables, input/output redirection, error handling, and more.

## Basic Usage

```perl
use Genesis qw/run/;

# Simple command execution with embedded arguments
my ($output, $exit_code) = run('ls -la');

# Command with shell-style variable substitution
my ($output, $exit_code) = run('grep "$1" "$2"', $pattern, $file);

# Command with arguments array (old style - gets converted to shell format)
my ($output, $exit_code) = run('git', 'status', '--porcelain');
```

## Function Signature

```perl
($stdout, $exit_code, $stderr) = run(\%options, @command);
($stdout, $exit_code) = run(\%options, @command);
($stdout, $exit_code) = run(@command);
```

## Command Execution Modes

Genesis `run()` has several execution modes:

1. **Single string with embedded arguments**: `run('ls -la')`
2. **Shell-style with variable substitution**: `run('grep "$1" "$2"', $pattern, $file)`
3. **Array arguments (legacy)**: `run('git', 'status')` - gets converted to shell format

The recommended approach is the shell-style with variable substitution as it properly handles quoting and prevents shell injection.

## Options Hash Reference

The first argument can be a hash reference containing various options to control command execution:

### Environment Control

#### `env` - Environment Variables
```perl
run({env => {
    VAULT_ADDR => 'https://vault.example.com',
    SAFE_TARGET => 'my-vault',
    PATH => '/usr/local/bin:/usr/bin:/bin'
}}, 'safe get secret/path');
```

- **Type**: Hash reference
- **Purpose**: Set or override environment variables for the command
- **Behavior**: Creates local scope copy of %ENV and applies modifications. Use `undef` to unset variables
- **Special**: Undefined values will unset the environment variable

#### `shell` - Shell Selection
```perl
run({shell => '/bin/zsh'}, 'command');
```

- **Type**: String (path to shell)
- **Purpose**: Override the default shell (`/bin/bash`)
- **Default**: `/bin/bash`

#### `dir` - Working Directory
```perl
run({dir => '/path/to/workdir'}, 'make build');
```

- **Type**: String (directory path)
- **Purpose**: Change working directory for command execution
- **Behavior**: Uses `pushd/popd` internally to restore original directory

### Input/Output Control

#### `stdin` - Standard Input
```perl
run({stdin => "input data\nmore data\n"}, 'command');
```

- **Type**: String
- **Purpose**: Provide input data to the command's stdin
- **Behavior**: Data is written to command's stdin pipe

#### `stderr` - Standard Error Redirection
```perl
run({stderr => '/path/to/error.log'}, 'command');
run({stderr => '&1'}, 'command');     # Redirect to stdout (default)
run({stderr => '/dev/null'}, 'command'); # Discard errors
run({stderr => 0}, 'command');        # Capture separately
```

- **Type**: String, number, or special value
- **Purpose**: Control stderr handling
- **Default**: `'&1'` (redirected to stdout)
- **Special Values**:
  - File path: Redirects to file
  - `'&1'`: Redirects to stdout (default behavior)
  - `'/dev/null'`: Discards stderr
  - `0`: Captures stderr separately and returns as third value

### Execution Control

#### `interactive` - Interactive Mode
```perl
run({interactive => 1}, 'safe', 'set', 'secret/path', 'key');
```

- **Type**: Boolean
- **Purpose**: Enable interactive mode for commands requiring user input
- **Behavior**: Uses `system()` instead of pipe. Output is undefined in return values. Command interacts directly with terminal

#### `passfail` - Return Boolean Success
```perl
my $success = run({passfail => 1}, 'test', '-f', '/path/to/file');
```

- **Type**: Boolean
- **Purpose**: Return boolean success/failure instead of output
- **Returns**: 1 for success (exit code 0), 0 for failure

#### `onfailure` - Failure Handling
```perl
run({onfailure => 'Command failed with important context'}, @cmd);
```

- **Type**: String
- **Purpose**: Automatic error handling with custom message
- **Behavior**: Calls `bail()` with the message if command exits non-zero. Command output is included in error message

### Security & Logging

#### `redact_output` - Sensitive Data Protection
```perl
run({redact_output => 1}, 'safe', 'get', 'secret/password');
```

- **Type**: Boolean
- **Purpose**: Prevent output from being logged or displayed in debug traces
- **Behavior**: Shows only the byte count in debug output instead of actual content

#### `redact_env` - Environment Variable Redaction
```perl
run({redact_env => 1, env => {PASSWORD => 'secret'}}, 'command');
```

- **Type**: Boolean
- **Purpose**: Prevent environment variable values from being logged
- **Behavior**: Shows `<redacted>` instead of actual values in trace output

### Advanced Options

#### Argument Redaction
```perl
run('vault auth -method=userpass', {redact => 'secret_password'});
```

- **Type**: Hash reference with `redact` key
- **Purpose**: Redact specific arguments from trace output
- **Behavior**: Shows `<redacted:N bytes>` instead of actual value

## Return Values

### Standard Return (Two Values)
```perl
my ($output, $exit_code) = run(@command);
```

- `$output`: Combined stdout and stderr
- `$exit_code`: Command exit status (0 = success)

### Extended Return (Three Values)
```perl
my ($stdout, $exit_code, $stderr) = run(@command);
```

- `$stdout`: Standard output only
- `$exit_code`: Command exit status
- `$stderr`: Standard error only

### Boolean Return (`passfail => 1`)
```perl
my $success = run({passfail => 1}, @command);
```

- `$success`: 1 if command succeeded (exit code 0), 0 otherwise

## Common Patterns

### Vault Operations
```perl
# Query vault with target override
my ($output, $rc) = run({
    env => {SAFE_TARGET => $vault->ref},
    redact_output => 1
}, 'safe', 'get', 'secret/path');

# Vault policy creation with stdin
my ($out, $rc) = run({
    stdin => $policy_content,
    env => {VAULT_ADDR => $vault_url}
}, 'vault', 'policy', 'write', 'policy-name', '-');
```

### Error Handling
```perl
# Ignore stderr
my ($output, $rc) = run({stderr => '/dev/null'}, @command);

# Capture stderr separately
my ($stdout, $rc, $stderr) = run({stderr => 0}, @command);
bail("Command failed: $stderr") if $rc;

# Custom failure message
run({
    onfailure => "Failed to initialize repository"
}, 'git', 'init');
```

### Interactive Commands
```perl
# Interactive secret entry
run({
    interactive => 1,
    redact_output => 1
}, 'safe', 'set', 'secret/path', 'key');
```

### JSON Processing
```perl
# Get JSON output
my ($json_out, $rc) = run({
    stderr => '/dev/null'
}, 'safe', 'targets', '--json');

my $data = read_json_from($json_out) if $rc == 0;
```

### File Operations
```perl
# Execute command in specific directory
run({dir => '/build/dir'}, 'make install');

# Command with stderr captured separately
my ($stdout, $rc, $stderr) = run({stderr => 0}, 'compile', 'source.c');
if ($rc) {
    error("Compilation failed: $stderr");
}
```

## Error Conditions

### Command Not Found
- Returns non-zero exit code
- stderr contains "command not found" message

### Permission Denied
- Returns non-zero exit code (typically 126)
- stderr contains permission error details

### Command Failure
- Returns command's actual exit code
- stdout/stderr contain command output

## Best Practices

### 1. Always Check Return Codes
```perl
my ($output, $rc) = run(@command);
bail("Command failed: $output") if $rc != 0;
```

### 2. Use Appropriate Redaction
```perl
# Redact sensitive output
run({redact_output => 1}, 'safe', 'get', 'secret/credentials');

# Redact environment variables in trace output
run({redact_env => 1, env => {TOKEN => $secret}}, 'api-call');
```

### 3. Handle Environment Properly
```perl
# Preserve important environment while overriding specific values
my %env = %ENV;
$env{VAULT_ADDR} = $new_vault_url;
run({env => \%env}, @vault_command);
```

### 4. Use Specific Error Messages
```perl
run({
    onfailure => "Failed to deploy $env_name environment"
}, 'bosh', 'deploy', $manifest);
```

### 5. Combine with Genesis Utilities
```perl
# Use with read_json_from for structured data
my ($json, $rc) = run({stderr => 0}, 'bosh', 'deployments', '--json');
my $deployments = read_json_from($json) if $rc == 0;

# Use with lines() for line-by-line processing
my ($output, $rc) = run('ps', 'aux');
my @processes = lines($output) if $rc == 0;
```

## Integration with Other Genesis Functions

### With `read_json_from()`
```perl
my $data = read_json_from(run('api-call', '--json'));
```

### With `lines()`
```perl
my @files = lines(run('find', '/path', '-type', 'f'));
```

### With Error Handling
```perl
eval {
    run({onfailure => "Critical operation failed"}, @critical_command);
};
if ($@) {
    error("Recovery needed: $@");
    # Perform recovery operations
}
```

## Implementation Details

### Command Processing
The `run` function processes commands in several ways:

1. **Single string mode**: If only one argument is provided and it doesn't contain variable substitution patterns (`${@}` or `$[0-9]`), it's executed directly
2. **Array mode**: If multiple arguments are provided, the first argument gets `' "${@}"'` appended to support shell-style argument passing
3. **Variable substitution**: Arguments are processed through environment variable substitution using the pattern `$VAR` or `${VAR}`

### Shell Execution
- Default shell: `/bin/bash`
- Commands are executed via: `($shell, "-c", $prog, @cmd_args)`
- The shell receives the basename of the shell as `$0`

### Environment Handling
- Creates a local copy of `%ENV` for the duration of the command
- Environment variables with `undef` values are deleted from the environment
- DEBUG environment variable is explicitly cleared to prevent interference

### Output Handling
- By default, stderr is redirected to stdout (`2>$stderr_file`)
- Output is captured via pipe unless in interactive mode
- Binary data is detected and not included in debug output
- Command duration is tracked and optionally displayed

### Error Handling
- Exit codes are extracted via `$? >> 8`
- Failed commands can automatically call `bail()` with `onfailure` option
- Commands that return sensitive data can be redacted from logs

## Performance Notes

- Command execution is synchronous
- Large output buffers are handled efficiently
- Environment variable inheritance is optimized
- File descriptor management is automatic

## Security Considerations

- Always validate command arguments from user input
- Use `redact_cmd` and `redact_output` for sensitive operations
- Environment variables can leak sensitive data in process lists
- Temporary files for stdin/stdout may persist on failure

## Examples Repository

See `t/` directory for comprehensive test examples demonstrating various `run()` usage patterns and edge cases.
