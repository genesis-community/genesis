# Improvements

* Added support for having environment name in file different than the
  enviornment file name.

# Bug Fixes

* Resolved issues found in `genesis ci`:
  * Fixed GIT SSH generation storage
  * Fixed supporting same BOSH for different environment
  * Ensure `stemcells:` key set to `[]` if not tracking stemcells
