# Improvements:

* Added ability to generate vault policies for Concourse pipelines as part of
  the `genesis ci` wizard.

* Allows user to select to not add specific environments to the pipeline in
  the `genesis ci` wizard.

* Added `--prefix <path>` option to `genesis new` to allow alternative safe
  paths to support legacy environments.

# Kit Handling Improvements:

* `params.vault` is now resolvable in kit prompts (equivalent to depricated
  `params.vault_prefix`).

* Added ability to echo vault-stored parameters using `echo: true`.

* Added `vault_path_and_key` validation type to ensure key present (Fixes
  #190).

# Bug Fixes:

* When generating ci.yml, the `genesis ci` wizard defaults to port 25555 for
  BOSH director URLs when no port is provided by the local BOSH config.

* Resolves issue in `genesis ci` when retrieving stemcells if `~/.bosh/config`
  doesn't match the requested bosh director URL exactly. (Uses the requested
  credentials instead of relying on `~/.bosh/config`).
