# Bug Fixes

- Accessing a Vault over HTTP/2 now works. Previously our regex was strictly
  checking for HTTP/x.x connections. We've losened it to look for HTTP/x.x or
  HTTP/x.

- Genesis concourse pipelines now downloads the cloud configuration from the
  bosh director. Previously, pipelines would fail to deploy because the deploy
  didn't have a cloud-config to base spruce merges off of.

- Genesis now ensures that `GENESIS_CALLBACK_BIN` is a fully-qualified path.
