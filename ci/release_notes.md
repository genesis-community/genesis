# Improvements

- Increased help coverage
- When using `genesis ci stemcell`, the URL will now be updated from the
  stemcell source, as well as the version/sha1 values.
- Auto-lookup of director UUID is now disabled when the director cannot be
  contacted.
- `genesis` no longer requires the `tree` command. If it is not present,
  directory tree listings are simply not performed.
- `genesis` Concourse pipelines now use a genesis-specific Docker image.

# Fixes

- Fixed some bad defaults and confusing templates related to `genesis ci`
- Beta environments now pick up site level changes properly
- The contents of `boshes.yml` is now redacted from the `ci/pipeline.yml`
  file when `genesis ci repipe` is run.
- Smoke tests configured via `genesis ci smoke-test` are now executed properly
  in the pipeline.
- `genesis repipe` now adds `rebase: true` when pushing updated configs back
  to your deployment repo, for greater success and less failure.
