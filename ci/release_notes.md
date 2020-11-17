# Improvements

- Support multi-doc environment files, so that spruce-specific layering can be
  done in a single file.

# Bug Fixes

- Fix errant pipeline warning without cause.  This was introduced in v2.7.19,
  but was overly-aggressive and mistook an empty list as an entry.

- Remove double-deep cached files from git repo.  Fixed in v2.7.19, Genesis no
  longer creates the double-deep cache.  However, this meant that existing
  erroneous entries would show up as differences, and cause the
  `c-generate-cache` job to fail to "copy" over the now absent file.
