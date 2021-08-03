# Improvements

* `genesis init` can now take the path of a compiled kit tar-ball as an
  argument to the `-k` option instead of a name/version of a remote kit.  This
  will install the provided file in the .genesis/kits subdirectory.

# Bug Fixes

* `genesis kit-manual` now works on dev kits, or environments that use dev
  kits

* Bump bosh cli to v6.4.4

  Recently bosh started using storage.googleapis.com to contain their
  stemcells, but this broke the downloads.  See the bosh-cli release
  https://github.com/cloudfoundry/bosh-cli/releases/tag/v6.4.4 for more
  details.

