# Troubleshooting

This section provides guidance for diagnosing and resolving common issues with Genesis deployments.

## Topics in this Section

### [Common Issues](common-issues.md)
Frequently encountered problems and their solutions.

### [Debugging Deployments](debugging-deployments.md)
Techniques for troubleshooting deployment failures.

### [Trace Logging](trace-logging.md)
Using Genesis trace logs for detailed debugging.

### [Manifest Debugging](manifest-debugging.md)
Troubleshooting manifest generation and merge issues.

### [Secret Problems](secret-problems.md)
Resolving issues with Vault and secret management.

### [Kit Development Issues](kit-development-issues.md)
Common problems when developing Genesis kits.

### [Error Messages](error-messages.md)
Understanding and resolving Genesis error messages.

## Quick Diagnostics

### Basic Health Check

```bash
# Check Genesis version
genesis version

# Verify environment
genesis list

# Check deployment status
genesis info my-env

# Validate environment
genesis check my-env
```

### Getting Help

- Check error messages carefully - they often contain the solution
- Use `--trace` flag for detailed debugging output
- Review logs in `~/.genesis/logs/`
- Search GitHub issues: https://github.com/genesis-community/genesis/issues

## Emergency Procedures

- [Deployment Recovery](debugging-deployments.md#recovery-procedures)
- [Secret Recovery](secret-problems.md#recovery)
- [State Corruption](common-issues.md#state-corruption)