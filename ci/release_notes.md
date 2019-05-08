# Bug Fixes

- Fixes code-order bug in `ci-pipeline-deploy` that was introduced in v2.6.13
  that caused an invalid `.saferc` that was missing the vault token to be used
  in the pipeline.
