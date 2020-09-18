# Improvements

- Allow `genesis repipe` to keep pipelines paused.

- Update generated pipelines:
  - Add icons to resources.

  - Replace deprecated `aggregate` with `in_parallel`.

  - Support for git resource extra configurations.

    This allows adding configurations to all git resource types.  The extra
    configurations can be specified under `pipeline.git.config`.  Common
    configurations that are expected to be utilized would be `check_every`
    and `webhook_token`, but any value specified on
    https://concourse-ci.org/resources.html could be used (with the exception
    of `name` and `type`).

- Support for an upcoming `generic` Genesis Kit.

# Bug Fixes

- Prevent new_enough helper from exiting on false

- Error if create-env deploy uses invalid options

  In particular, specifying --dry-run on a create-env, has no effect.  It
  actually changes the target, which can be destructive and allowing this
  option gives users a false sense of security.  Options --yes, --fix and
  --recreate are also considered invalid for `genesis deploy` when deploying
  a create-env.
