# Improvements

- Releases and Stemcells can now be set to the version keyword
  `track` to pull latest information from the Genesis Index at
  deploy / manifest-generation time.  The keyword `latest` has
  reverted to its original meaning of 'latest available on the
  BOSH director'

# Bug Fixes

- `set release` command now queries the Genesis Index for URL /
  SHA1 information
