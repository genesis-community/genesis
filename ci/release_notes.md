# New Features

* Auto-connect to BOSH director.

  Genesis can now automatically connect to the correct BOSH director for the
  specified environment, without need to set up a bosh configuration or
  manually logging into the director.

  Caveat: The BOSH director that deployed your environment MUST have been
  deployed by Genesis.  If not, you will still have to target and log into the
  BOSH director manually.

* Added `genesis bosh` command.

  Instead of worrying about logging into the right BOSH director, and
  translating genesis environment into BOSH environment and deployment, let
  Genesis do the heavy lifting.

  If you want to know something about your concourse vms, for example, you
  just run `genesis bosh my-concourse-env vms --vitals` and you'll get the
  right output.  Genesis will determine which bosh director deployed
  `my-concourse-env`, how to connect to it, what the BOSH deployment is named,
  and return the results of the command you specified.

  By default, the `genesis bosh` command is deployment centric, but sometimes
  you need to talk to the BOSH director itself.  In that case, you can specify
  the BOSH deployment itself, and use the `-as-director` (or `-A`) option to
  indicate that the environment is the director, not a deployment on a
  different director.  For proto-BOSH environments, this is required.

  See `genesis bosh -h` for more usage details.

* Connect to BOSH director without using the BOSH deployment kit.

  If you still need to connect to a BOSH director directly, you can configure
  your shell by using `eval "$(genesis bosh my-target-env --connect)"`.
  Please note that this connects to the BOSH director that deployed the
  `my-target-env`.  If `my-target-env` is a bosh deployment, the command will
  authenticate to the BOSH director that deployed it, not itself.  In this
  case, you need to use the `--as-director` option to explicitly state that
  this is the BOSH environment you wish to connect to.

# Breaking Changes

* Removes legacy support for kits without new or blueprint.

  As of v2.8.0, kits must use new and blueprint hooks.  All modern kits
  support this model, so anyone actively keeping current with genesis would
  not be impacted.

* Remove subkits, error if used in env file.

  Subkits have been deprecated since at least 2.6.13, so its time to remove
  them.

* Remove `--environment` global option.

  The environment option has been replaced with `--bosh-env` option to remove
  confusion regarding the overloaded 'environment' name.  Henceforth,
  environment refers to just the deployment environment.  The `-e` shortform
  is still usable.

# Improvements

## Better Support for using BOSH create-env

  * Starting in v2.8.0, kits that indicate that they are compatible with
    v2.8.0 can support `use_create_env` as their method of indicating
    their ability to use create-env instead of deploy for deployments.

    - Valid values are `yes` for this kit always uses create-env, `no` for
      kits that cannot use create-env, and `allow` for kits that permit
      either.

    - The kit will have to detect `genesis.use_create_env` in the
      environment to determine blueprint and other create-env kit
      behaviour.  Genesis will manage the actual deployment and state file
      associated with it.

  * Genesis properly handles both legacy features (create-env,bosh-init,
    proto) and v2.8.0's `genesis.use_create_env` attribute to determine is
    create-env is to be used.  It will also detect when an incompatible
    mixture of using create-env and specifying a `genesis.bosh-env`
    attribute, and fail with an appropriate error message.  A quick update
    of the environment file by the user will resolve this issue when
    encountered.

## Kit Overrides by Environment

  * Environments can now customize kit behaviour directly, by specifying a
    `overrides` parameter under the top-level `kit` attribute.  This
    replaces the repo-wide `kit-overrides.yml` file (though it is still
    supported.

    This improves the previous behaviour because environments can target
    different versions of a kit, meaning the one-file-fits-all can be
    sub-optimal or even broken.  It also means the overrides can propagate
    through the repo using hierarchical inheritance.

    It comes in three forms:

    - Simple string: By placing the overrides (in yml form) inside a
      string block, it is applied verbatim. Any spruce operators will be
      applied to the kits kit.yml only.

      ```
      kit:
        overrides: |
          docs: "https://internal-docs-for-kit.mycorp.com"
          genesis_version_min: 2.8.0
          use_create_env: yes
      ```

    - Simple YAML hashmap:  By using a hash-map, you can use spruce
      operators to take values from the environment yaml hierarchy (though
      not the full manifest, as that would be a chicken/egg issue with the
      kit itself).  If you want to use spruce operators against values in
      the kits `kit.yml` file, use the `defer` operator in front:

      ```
      kit:
        overrides:
          credentials:
            base:
              my-secret: (( grab params.my-secret )) # from env.yml
              old-secret: (( defer concat credentials.base.secret "-disabled" )) # from kit.yml
      ```

    - Array of the above types: By permitting an array, you can apply the
      changes in layers, or build from hierarchical ancestors

      ```
      kit:
        overrides:
        - |
          first_stuff: 1

        - second:
            stuff: also

      ```

      And in an inheritting file:

      ```
      kit:
        overrides:
        - (( append ))
        - second:
            stuff: overwritten
        - |
          even_more: true
        ```

## Improved Kit Behaviour

* Improve params handling for use in `new` hook.

  - Support multiline values in keys and arrays in `param_entry`.

  - Echo `param_comment` to screen so the same information that prefaces the
    value in the env.yml file can be used as an explanatory blurb prior to the
    prompt.

* Improve decompile-kit

  - Can decompile kit to directories other than ./dev (`--directory <dir>`)

  - Can specify an environment YAML file to identify which kit to decompile,
    instead of explicitly stating the kit/version.

## Better BOSH Config Management

* Support downloading multiple configs.

  Before, if you specified to download a config type (ie cloud or runtime)
  without a name, it would download only the unnamed *default* config of that
  type.  Experience has shown that the more correct interpretation should be
  to download all configs of that type, and merge them (in the order they are
  specified in the BOSH director).  The old behaviour can still be used by
  explicitly stating `default` as the name.

## Messaging / Error Handling / Debugging

* Added stderr output capture for `Genesis::Vault#get`.

  Rather than have the raw safe stderr leak out to the user, we now capture it
  and write it to the DEBUG stream.

* Improve deploy help output for create-env environments

  There are difference behaviours for create-env environment than from
  environments deployed via a BOSH director.  This update calls them out
  and gives instructions on their use.

# Bug Fixes

* Kits can now specify required prerequisites via hook.

  Although the prereqs hook was documented, it was only partially
  implemented.  This commit completes that implementation, so that if
  `hooks/prereqs` exists in a kit, it will be run prior to usage.

* Fix bug where default config type was lost when fetching configs from BOSH
  director, resulting in bad messages and error reports.

* Export `GENESIS_EXODUS_MOUNT` to hooks environment.  This was missing from the
  set of vault path environment variables available to hook scripts.

# Internal Changes/Improvements

## BOSH Refactor

* Add `Genesis::BOSH` for controlling BOSH director.

  This is a major refactor to facilitate better operation and connections
  to BOSH directors.  Connections to Bosh will use exodus data to
  determine the corresponding BOSH director address and connection
  details.

* Set `GENESIS_BOSH_COMMAND` when checking BOSH cmd

  Also removes `check_bosh_version` subroutine that was replaced by
  `Genesis::BOSH#command`

* Change `needs_bosh_create_env` to `use_create_env`

## Functionality Improvement

* Allow `Genesis::Kit#metadata` to take args.

  If Genesis::Kit#metadata receives no arguments, it will return a hash
  reference for all metadata for the kit.  If it gets a single value, it
  returns the metadata corresponding to the key of that value.  Finally,
  if it gets a list of values, it will return a list of the metadata
  corresponding to the keys of the given values.

## Efficiencies

* Lazy-load kit provider types as needed.

  By using `require` instead of `use` for loading the
  `Genesis::Kit::Provider::*` classes, they are loaded as needed during
  runtime instead of fully loaded at compile-time.

* Memoize `Genesis::Env` `params` and `actual_environment_files`.

## Structure / Maintainability

* Reordered `lib/Genesis/Env.pm`, with folding and grouping.

  This is done to be consistent with the other lib files.  No actual code
  changed in this release, but the diff is massive because blocks were
  moved into logical groupings.

* Privatized `Genesis::Env#validate_name`.

  `validate_name` method should only be used internally, so it was renamed
  `_validate_env_name`.

* Fixes inconsistant private variable naming.

  * `_configs` has been changed to `__configs` in `Genesis::Env`, to match all
    other private instance variables.

