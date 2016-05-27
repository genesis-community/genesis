# New Features

- **VAULT_PREFIX**
  `genesis` now creates a VAULT_PREFIX based on your site/env/deployment
  name, and sticks that in the `name.yml` file, for easier use pulling creds from `spruce`
  templates.
- **Environment Hooks**
  `genesis` can now execute arbitrary scripts when creating a new environment.
  This is useful for auto-populating a `Vault` with sensitive data that should
  be both unique per environment, and required for all environments.
- **Dependency Checks**
  `genesis` now looks in `${DEPLOYMENT_ROOT}/.genesis_deps` for a list of executables
  that it must ensure exist, and are at least as new as the version specified, to ensure
  there are no compatibilitiy issues running `genesis`. Format is like so:
  ```
  spruce: 1.4
  genesis: 1.5
  safe: ~ # a '~' or 'null' entry will result in just ensuring the command is present
  ```

# Bug Fixes

- The auto-population of `director.yml` and `name.yml` ended up breaking those yaml files
  on new environments. This has been resolved.

# Notes

`genesis` is now released via a Concourse pipeline, using GitHub releases.
Please update any scripts that pull genesis down from master, and update them
to use the latest released version, instead.
