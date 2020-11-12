# Pipeline Cache Propagation Bug Fixes

* Source of errant duplicate drectories found and fixed.  If you have
  `.genesis/cached/cached/` or `.genesis/cached/<env>/<env>/` directories, the
  deeper directory can be safely removed.

* Pipeline deploys correctly propagates the cached versions it was deployed
  with.  There was a scenario that caused the pipeline to deploy with the
  cached version of a common ancestor file, but then propagate its local file.

* Detection of cached files now occurs earlier in the pipeline deploy process,
  which solves a race condition that caused the deployment to use the uncached
  (outdated) files, or not include a file at all.

# Improvements

* `genesis init` can now use `GIT_AUTHOR_NAME` and `GIT_AUTHOR_EMAIL` instead
  of requiring the .gitconfig to have those values set.  For the initial
  commit, `GIT_COMMITTER_NAME` and `GIT_COMMITTER_EMAIL` will be used, but
  will default to the equivalent `GIT_AUTHOR_*` values if not also present.

# Bug Fixes
    
* Fixed exodus helper for hooks.  This is required for vault-genesis-kit
  v1.6.1 if using the explicitly listed static IPs

* Fix deploy continuing on failed environment check. Prior to this fix, if
  environment check failed, but secret check succeeded, the failed environment
  check would be ignored, and deployment would continue. 
