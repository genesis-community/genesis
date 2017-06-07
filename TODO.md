TODO
====

Priorities:
* P1: Must be done before first release
* P2: Must be done before handoff to Demand Bridge
* P3: Needed for completeness, not needed for first release.
* P4: Nice to have/additive functionality, add if you're bored.
* P5: Nice to have, add if customer requests it
* P-: Don't do until further need is expressed/better understood

Herein lies the things we found while working on Genesis v2.
These things need to be done. They cannot be ignored.

- (P3) **BUG** - `genesis init` doesnt bail out if the destination repo already
  exists. Instead it carries on and commits to it as if it were brand new. Should fail
  by default, and have a flag to force-use-existing repo?

- (P3) **BUG** - `genesis init --kit <kit>` doesn't save the downloaded kit in the initial
  commit, so after it's done, there are untracked files in the repo, which should have been
  committed.

- (P3) **genesis ccck** - Cloud Config Check!  Take a manifest,
  fully-generated, and compare it against the cloud-config
  (required argument) to see if they are mutually consistent.

- (P4) **genesis sync** - Allows genesis to download the latest packed genesis and
  replace the current executable.  Command not yet implemented (Low priority
  as the jumpbox kit should grab the latest version)

- **Prompting users for Env data + Params**
  1. (P3) Ensure that we have the ability to require versions of genesis + other utilities for a specific kit
  2. (P3) Add --hooks and --hook-support-version option to `new kit` command;
     --hooks will take a list of one or more of subkit, params;
     --params-helper-version will cause the specified version of the
     params_helper bash script to be included in the hooks directory
  3. (P-) Allow `genesis rebuild env` or `genesis new env --rebuild` to read in
     existing environment yaml file and use it to help build it from scratch
     (existing values become new defaults, etc...)
  4. (P3) Currently, if --no-secrets is an option to `genesis new`, any ask that
     results in a value being stored to a vault path is skipped, and `genesis
     secrets` does not include these questions when generating the creds and
     certs.
  5. (P3) Upgrade scenario may need to ask new values for things we already have
     asked, or new parameters that weren't asked in previous versions of kits.
  6. (P5) A third level param asking AFTER the secrets have been generated that use
     those secrets.

- **New bug() util** - Provide a small utility function, called
  `bug` that will instruct the end user in how to provide a bug
  report, in the event of an "impossible" situation that the devs
  need to track down.
  - Dennis
  - Requires kit validation that author's 

- **(P4) compile-kit -Wall** option - allow kit authors to compile
  their kits in `-Wall` (warn all) mode, that will analyze the kit
  and detect some questionable behavior.

- Validation
  - validate kit and subkit when compiling
  - validate subkits when building manifests or deploying
    - subkits must have params.yml
    - subkit yml files must be parseable
  - validate kit + kit metadata when building manifests, deploying, creating
    or maybe just anything in general?
    - must have params, certificates, credentials, subkits, etc.
    - validate syntax of params, subkits, certificates, credentials
      (some of this may already be done?)
      - validates that certificates.*.server has a name param with 1 or more
        list items.
  - kit must have base/params.yml
  - kit base/\*.yml must be parseable

- (P1) Add support to the genesis pipelines to hanlde bosh-init

- (P2) docs on genesis-v2

- (P2) Add readme to genesis init production.

- (P2) rename + release genesis-v2 (not needed if we embed v1 script)

- (P1) Detect if we're in a genesis deployment or not; furthermore, if in a v1
  repo, exec embedded script and pass args, otherwise, continue processing as
  a v2 repo.

- (P3) Support for turning off deployments when done (for alpha/testing env + cost savings)
  Add a flag to CI that will shut down the environment via bosh stop --hard, after
  successful deploy (leave up on smoke test failure for troubleshooting).

  This will require adding in dependencies (cf-rabbitmq requires cf), and locking
  the dependent deployments so that cf can't upgrade and turn itself off while cf-rabbitmq
  is trying to make use of it. locker-resource should be able to support this already,
  just need to write in the logic to parse out dependencies from the CI layout, and
  add locking/shutdown/startup steps in the pipelines.

NICE-TO-HAVES
=============

These _feel_ like TODOs, and sometimes we _desperately_ want them to be
TODOs, with the same gravitas and eye towards a fix.  But they are not.
They would be nice, and might make someone life a lot easier, but they are
just that: desired.

- (P5) **Look up subkits from higher level yml**
  When running `genesis new my-new-environment`, check in the `mergeable_yamls`
  paths (`my.yml`, `my-new.yml`) for `kit.subkits` definitions to see what
  choices were already made? How will this work with spruce merging and array appending
  vs replacing vs everything else?

- (P5-) **genesis dry** (or `dedupe`): given a set of YAML files (i.e. all
  of the environment templates), analyze each for common
  sub-params, and hoist them to the highest (least specific)
  common prefix file.  It would also be nice to find anomalies
  like 'identical override' cases, and either fix or advise.

- (P3) **genesis plan** - Take a plan file that defines network ranges
  and cloud properties per infrastructure and pops out a cloud
  config YAML file with all the bits filled out. (cf. netbuilder)

- (P5) Ability to disable base param questions if a subkit is selected.  For
  example, if selecting the 'azure' subkit, disable the base param for
  availability_zones.

- (P5) Ability to run another params-style hook that was generated after the
  certificates have been added to the vault, so that things that rely on a ca
  can be produced. (Alternatives is to add executables to kits that can be run
  against a given environment.yml file.) ie jumpbox user certs that depend on 
  the ca being available.

- (P5) init -k url:repo/kit support for private/custom kit repos
