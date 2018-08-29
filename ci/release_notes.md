# Bug Fixes

- Accessing a Vault over HTTP/2 now works. Previously our regex was strictly
  checking for HTTP/x.x connections. We've losened it to look for HTTP/x.x or
  HTTP/x.

- Genesis concourse pipelines now properly use the fetched cloud configuration
  resource in deployments. Previously, pipelines would fail to deploy because
  the cloud-config resource was not listed as an input.

- Genesis now ensures that `GENESIS_CALLBACK_BIN` is a fully-qualified path. If
  a relative path is given, it resolves the current working directory and
  prepends that to the relative path. 
