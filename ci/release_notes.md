# Bug Fixes

- Use the new `GENESIS_HONOR_ENV` environment variable to
  determine if we should or should not honor the contents of
  various other environment variables, like `BOSH_*` and
  `http*_proxy`.  We used to rely on `BUILD_PIPELINE_NAME` for
  this, but that doesn't seem to be set by Concourse any more.
