## Pipeline Improvements

- Added `pipeline.task.privilege` in ci.yml, which allows you to provide a
  list of evironments that will run the `bosh_deploy` task in privileged mode
  (which may be needed when deploying proto-BOSH environments).  See 
  https://concourse-ci.org/jobs.html#schema.step.task-step.privileged for more
  information.

- Allow genesis to create and authenticate to safe targets, which is used in
  the pipeline to target the vault specified in the configuration.

- Allow genesis to reauthenticate to safe after a long-running bosh deployment
  so it can store the updates to the deployment's exodus data.

- Add auto-update to pipeline

  This creates a genesis-updates group that contains a job that is
  triggered when a new verison of the kit is released, and will update the
  kit version in the deployment repo, and embed the latest version of
  genesis if not at the latest version.

  It will then commit these changes, which will trigger the primary
  pipeline for the repo to progress through the various environments.

  The `pipeline.auto-update` block in ci.yml, requires a `file` key to specify
  which file contains the `kit.version` entry.  More details can be found in 
  `docs/PIPELINES.md`.

- Adds `pipeline.git.commits` map entry to ci.yml, that can contain
  `user_name` and `user_email` keys for specifying the user name and email
  when the pipeline makes commits to the deployment repo.  Defaults to
  'Concourse Bot' and 'concourse@pipeline' respectively.

- Add a safe "dry-run" on notifications to identify what changes will be
  deployed on the pending environment.  This is different that `bosh deploy
  --dry-run` in that it doesn't alter the director's databases, nor upload
  releases, and it identifies changes in credhub values (but doesn't leak them
  to the output log)

# Other Improvements

- Support auto-authenticate with Safe.

  As a side effect of enabling pipelines to re-authenticate after timeout,
  users can now set environment variables to automatically authenticate with
  their safe.  The environment variables are `VAULT_AUTH_TOKEN` for token
  authentication, `VAULT_USERNAME` and `VAULT_PASSWORD` for userpass
  authentication, and `VAULT_GITHUB_TOKEN` for authenticating with a Github
  Personal Access Token.

# Bug Fixes

* Vault detection fix to allow conditions when no vault is available (a valid
  condition for some Genesis sub-commands)

# BREAKING CHANGES

If you are still specifying stemcell update information in your ci.yml
configuration, you will need to remove it.  It has not been supported for many
releases, but this release removes it validity.

# Dependency Updates

- Safe bumped to v1.5.8

