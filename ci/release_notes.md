# Improvements

- Vastly improved handling of versions for non-bosh-init deployments. `track` still behaves
  as it used to, as do releases/stemcells with sha1 + url data specified. However, for `latest`,
  or `x.y.z` versions that do not use sha1/url data, Genesis now contacts the director to see
  if the desired versions are present. If not, it fetches the data from the Genesis index and
  uploads the release/stemcell, for you (but only during deployment). This results in a substantial
  reduction of Genesis Index calls for things like `make manifest`.

- Added warning/error message to `genesis ci repipe` when `track` is specified. It will introduce
  mostly undesirable behavior/race conditions with release + stemcell versions that break the
  intentions of only deploying known-tested versions from pre-production to production.

- Changed the default version for `genesis add release` and `genesis use stemcell` to `latest`,
  from `track`.
