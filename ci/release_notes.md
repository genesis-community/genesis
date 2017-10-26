# Improvements

* `genesis compile-kit` now has a more natural interface for building new
  versions of kits:
  * Name can now be automatically determined by directory context, as can dev
    mode if called from a directory in the form of <name>-genesis-kit or
    <name>-deployments.
  * No longer requires you to build one directory above the kit contents.
    This is required to support CI where the directory name may not conform to
    the expected pattern.
  * Now ensures that the kit contents are present and the kit.yml file is
    valid.

# Bug Fixes

  * Fixes #174: No longer tries to make sure there's a BOSH director target
    when bootstrapping a new BOSH director with the BOSH genesis kit.
