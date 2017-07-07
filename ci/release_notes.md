# Bug Fixes

- Fixed bug in pipelines where local changes were not being propagated
  correctly, and cached changes were not always making it into the
  deployments. After upgrading, make sure to re-embed this copy
  of genesis into your deployment repos via `genesis embed`, and update
  your concourse pipelines via `genesis repipe`.
