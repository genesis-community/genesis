# Improvements

* `genesis kit-manual` (man for short) can now display the manual for a given
  kit/version instead of indirectly referencing through specifying a
  deployment that uses it.  It also allows users to specify just the kit name
  (showing the latest local version), just the version (if there is just one
  kit type in the repo) or nothing at all (which will display the latest
  version of the singular kit in the repo. If you have multiple local kit
  types, you must specify the kit name (or environment file that uses it)

# Bug Fixes

* Scoping has been improved, so that commands that need to be run from a repo,
  or a kit or against a environment file, or none of the above give the right
  error message when their conditions aren't met.  This also fixes a problem
  where `genesis init` couldn't be run if -C option was specified.

* Fixes incorrect help info for `remove-secrets`
