## Improvements

- The `microbosh` type has been deprecated, since the bosh micro
  plugin is no longer a supported or promoted method of deploying
  an initial bosh.  `bosh-init` should be used for this purpose.
  **THIS IS A BREAKING CHANGE** for microbosh deployments.
- "development" versions of tools will (noisily) be considered
  sufficient for any version requirements.  This allows genesis to
  be tested on deployments that assert `.genesis_deps`
  requirements.
- Environment hooks can exit non-zero to abort the creation of a
  new environment.
- READMEs from deployment templates will be refreshed in new
  deployments.  This allows the template author to use the
  top-level README.md to describe how the template ought to be
  used (whether Vault is used and how, what properties should be
  overridden, etc.)

## Bug Fixes

- Fixed version checking issue where lexical comparison was used
  instead of numerical (now, 0.0.14 > 0.0.9)
- Verbiage fixes for things like "using vlatest of stemcell blah"
