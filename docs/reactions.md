
## Pre-deploy and post-deploy reactions

Reactions can be specified on a per-environment basis.

Sometimes different environments need to perform tasks prior to and after
doing a deploy. This feature allows you to specify scripts that will be run in
those circumstances. Add the following structure to your environment file:

```yaml
genesis:
reactions:
    pre-deploy:
    - script: put-up-maintenance-page
    - script: update-jira
        args:   [ 'some-argument', '$SOME_ENV_VAR' ]
    post-deploy:
    - addon: valid-addon-for-kit
    - script: remove-maintenance-page
```

The scripts are located in the `bin/` dir under the repository root directory,
and are propagated via the pipeline cache system.

The scripts have access to the following environment variables:

* `GENESIS_PREDEPLOY_DATAFILE` -- file path that contains any data gathered by
  the predeploy hook

* `GENESIS_MANIFEST_FILE` -- file path to the full unredacted unpruned
  manifest for the current deployment

* `GENESIS_BOSHVARS_FILE` -- file path to any BOSH variables for the
  deployment

* `GENESIS_DEPLOY_OPTIONS` -- JSON representation of the options passed to the
  deploy call

* `GENESIS_DEPLOY_DRYRUN` -- `true` if the deployment is a dry-run, `false`
  otherwise

* `GENESIS_DEPLOY_RC` -- return code of the BOSH deploy call. `0` if
  successful, `1` otherwise. Only available for post-deploy reactions
