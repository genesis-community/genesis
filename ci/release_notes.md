# New Features

* Per-AZ CPI extension point in cloud-config hooks.

  `Genesis::Hook::CloudConfig` now exposes `cpi_name_for_az($az_key,
  $az_data)`, called for every AZ definition emitted by
  `build_az_definitions` and `build_cpi_azs` when CPI is enabled. The
  default returns the environment's single `cpi_name`, so existing kits
  render identical cloud-config. Kits that route AZs to different CPIs
  (one director serving multiple IaaSes) override just this method
  instead of duplicating the AZ definition loop.

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

* Provide create-env deployments with diff/confirm

  Since BOSH does not provide a confirmation after a diff on the
  environment to be deployed, Genesis provides this based on a previous
  deployment, assuming it was added to the repo.

  If the exodus data from the previous deployment doesn't match the local
  archived manifest, a warning will be stated, or in the case of running
  under `-y`, the deploy will be aborted.

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

* Bail on unresolved spruce operators in instance-group AZs.

  An unresolved `(( ... ))` reaching an instance group's `azs:` list means
  the manifest was not fully evaluated, so AZ and CPI resolution would run
  on unreliable data.  Genesis now fails with the offending value instead
  of proceeding.

  The usual cause is a spruce operator inside the `value:` block of a
  go-patch ops document -- `spruce merge --go-patch` applies those
  verbatim, so the marker survives into the resolved manifest.  Note that
  `type: replace` already replaces the target outright, which makes an
  inner `(( replace ))` both redundant and inert; remove it from the ops
  file.  An unresolved `(( grab ))` or `(( vault ))` arrives the same way
  and points at the merge inputs instead.

  Environments carrying this fault previously deployed with corrupted AZ
  lists -- the entries the marker was meant to drop were still present
  alongside the intended replacement.  Those environments will now fail
  preflight until the ops file is corrected.

# Bug Fixes

* Kits can now specify required prerequisites via hook.

  Although the prereqs hook was documented, it was only partially
  implemented.  This commit completes that implementation, so that if
  `hooks/prereqs` exists in a kit, it will be run prior to usage.

* Network claims no longer hand out another target's reserved address.

  A network's free pool now leaves out every other target's reserved-ips
  records, and a saved claim that holds one of those addresses stops the
  build instead of keeping it.  Set `GENESIS_ALLOW_CLAIM_PRUNE` to a
  comma-separated list of network names to drop the address for one run.  A
  director's compilation network drops it with a warning, because its VMs
  exist only during a deploy.

  A network's own in-band reserved-ips records now take away a claim's top
  address on the first build.  Before this fix the same address went on the
  second build, so a claim that was saved by an earlier Genesis may change
  by one address the first time it is built.

* Stemcells with no download source now stop with a clear message.

  When a required stemcell was missing from the director and Genesis could
  not find a download for it, `deploy` and `check` stopped with "Cannot fix
  stemcells without a valid fix_data" and never said which stemcell was the
  problem.  They now stop with "requires manual upload" and list each such
  stemcell, and `deploy --fix-stemcells --dry-run` no longer claims it would
  fix them.

* A director that hangs behind `BOSH_ALL_PROXY` is now unreachable.

  The proxied director check lost its own timeout, so a director that never
  answered was marked as validated.  Genesis now stops with an error that
  names the director and the proxy.

* Stemcells named by `name` in the manifest are now matched by name.

  As BOSH does, a manifest stemcell that gives a `name` now matches the
  director's stemcells by name and version, including `latest`, and its `os`
  is ignored.  Before this fix Genesis checked only `os`, so a name-only
  stemcell was never found, and one with both a name and an os was checked
  against the wrong image.  A named stemcell that is missing is reported for
  manual upload instead of being offered a bosh.io stemcell of another name.

* `genesis new --vault` resolves a descriptor the way `genesis.vault` does.

  The command matched every field of the descriptor exactly against the
  safe targets, so a `strongbox` or `no-strongbox` clause that the target's
  `~/.saferc` entry did not repeat, an https URL with no `verify` clause, a
  trailing `/`, or a namespace without a port found nothing, and the command
  died with "Invalid call to Genesis::Top->set_vault".  `genesis new` for a
  child environment failed the same way when an ancestor's `genesis.vault`
  had one of those shapes.  Both now use one resolver, in which strongbox
  only breaks ties, verify is compared only for https, and a descriptor with
  no matching target names the URL and the `safe target` command to run.

* `genesis new --vault` accepts the name of a safe target, as its help says.

  A bare name such as `--vault prod-vault` died with "Unknown clause", because only vault descriptors were understood. A single word with no URL scheme is now looked up as a safe target name, even when it contains `:` or `/` or matches a descriptor keyword such as `verify`, and an unknown name is reported by name along with how to list the targets. The new environment's `genesis.vault` records the descriptor of the target the name resolved to, leaving out an alias that would not read back as that name, such as one starting with `$` or containing a space. A name whose URL another safe target shares is refused with both target names, because Genesis hands the vault to safe by URL and safe cannot choose between them. When a descriptor holds characters YAML would misread, such as an alias of `#ops` or `ops:`, the env file now writes it quoted, so the environment reads it back intact. Anything else is still parsed as a descriptor and recorded as given, exactly as before. An ancestor's `genesis.vault` still has to be a descriptor, because a target name only means something in one operator's `~/.saferc`.

* `genesis new --vault` no longer repoints the whole repository.

  The vault given to `genesis new` was always written to `.genesis/config` as the repository's secrets provider, which every environment without its own `genesis.vault` relies on, so creating one environment on another vault silently moved all of those. The vault is now recorded only when the repository has no secrets provider yet. When one is recorded, the given vault is used for that command alone, and if it differs, a note says that `.genesis/config` was left alone and where it still points. A vault picked interactively with `--vault ?` or inherited from an ancestor's `genesis.vault` is handled the same way, and a picked vault is now recorded in the new environment as its descriptor, where the literal `?` used to fail the command.

* Fix bug where default config type was lost when fetching configs from BOSH
  director, resulting in bad messages and error reports.

* Export `GENESIS_EXODUS_MOUNT` to hooks environment.  This was missing from the
  set of vault path environment variables available to hook scripts.

* Interactive BOSH commands report their exit code on Linux.

  Genesis runs interactive bosh commands under `script` so that bosh keeps a
  terminal.  util-linux `script` exits 0 whatever bosh did unless it is given
  `-e`, so on Linux a failed command never raised its failure message, and a
  bosh killed by a signal was reported as a success.  Genesis now passes `-e`
  there, and to the `script` that runs `spruce diff`.  macOS `script` already
  returned bosh's exit code.

* `run_errand` fails when the errand fails.

  Kit addons that run an errand through `run_errand` printed success after a
  failed errand on Linux, because `run_errand` returned 1 whatever happened
  and relied on a failure message that never fired there.  It now checks the
  exit code bosh returns and stops with an error when the errand fails.

* A refused connection no longer kills Genesis with SIGALRM.

  Checking a vault or BOSH director whose port refused the connection left
  the connection timeout armed, so Genesis was killed by SIGALRM
  `GENESIS_NETWORK_TIMEOUT` seconds later (10 by default) if it was still
  running.  The timeout is now cancelled however the check ends.

* Redeploying a `create-env` environment no longer reports a false manifest
  mismatch.

  Before a `create-env` deploy, Genesis checks that the manifest kept in the
  repository is the one that was last deployed.  Since create-env started
  writing its state to `-state.json`, that check hashed the state file
  instead of the manifest, so every redeploy reported that "Manifest in the
  deployment archive does not match the manifest in the local repository".
  At a terminal you were asked whether to proceed, and without one Genesis
  refused to deploy.  The check now compares the manifest in the repository,
  even when the last manifest was downloaded from exodus, and the warning
  appears once instead of twice when that manifest really is stale.  A state
  file in the repository with no manifest beside it is now reported, because
  nothing shows which deployment it belongs to.  An environment with no
  recorded state file now stops with "Cannot find state file for previous
  deployment" instead of "failed to open ''".

* Genesis reads every `safe export` format.  safe writes a versioned export (format 2) when a secret has more than one version, and safe 1.26 writes format 3 when a value is not a string, such as an object or a number written by another tool.  Genesis read only format 1, so deploys, secret checks, entombment, and exodus lookups died with "Not a HASH reference".  They now read the current version of each secret in any format, leave out a secret whose current version is deleted or destroyed, and stop with an error naming the path and key of any value that is not a string, since Genesis reads every secret as a string.  An export format Genesis does not know also stops with a clear error.

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

