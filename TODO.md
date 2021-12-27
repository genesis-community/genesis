TODO
====

BIG ONE!!!  Secrets store special type:

Use kit.yml to define secrets as classic vault, but have code to
a) build a variables block to define the same secrets as credhub values
b) copy the values from vault to credhub for deployment purposes

This will allow the following benefits:
1)  Instantly enable credhub imbeded secrets (no cleartext secrets for
deployments)
2) Move existing kits to use credhub instead of vault if desired by customer
3) A hybrid mode where vault is used to manage secrets, but the secrets get
staged to credhub just prior to deployment or restart (as updates to credhub
secrets take effect on restart instead up requiring full deploys) # NEED TO
CONFIRM THIS

The best part is that nothing needs to be updated in kits to add this
behaviour.

Implementation
--------------

0) Some mechanism for an environment to indicate if it wants to use vault,
vault-with-credhub-cache, or migrate(d)-to-credhub.  This last state may be a
two-stage process with a genesis subcommand to do the migration, or it might
migrate on detection of non-migration status (setting a value in vault
post-migration)

1) Some mechanism to read in kit.yml secrets definitions (extract this from
Genesis::Vault)

2) Some mechanism to render those definitions as a variable block.

3) Some mechanism that replaces `(( vault ... ))` spruce operators with
((variable)) operators.  This could be

  * Build a local vault and target it, but each value in the vault will be a
    ((variable)) representation.

  * A pre-merge process to replace all vault ops with defer ops, then a post
    merge process to replace all those vault ops with a determinable value

  * a pre-merge process to replace all `(( vault ` strings with 
    `(( concat "@GENESIS_TO_CREDHUB@:" ` strings then a simple post-merge regexp
    replacement with `(( some-formulaic-render-of-vault-path-to-variable ))`

4) A process to migrate vault entries referenced by kit.yml to credhub entries
under /bosh-env/deployment-env/unique-identifier-of-secret.  As vault doesn't
handle complex secrets (ie certificates), the secrets will all be scalar
representations.

To-Do for v2.8.0+

 1. Credhub add, check, rotate and remove secrets (v2.9.0)

 2. Use Cepler for pipelines (2.10.0)

    https://github.com/bodymindarts/cepler

 3. Better inheritance system (convension over configuration) (2.9.0)
     5.1. Fix how genesis determines what is a env file or not

          This is currently done by having a genesis.env or params.env set to
          the same name as the file.  This has long been a contensious issue
          of redundancy.

          The new method would be `<anything>.yml` could be an env file, and
          partial inherited files would be `<partial>-.yml` with the hyphen as
          the last character.

          But to do this in a backwards compatible way, the repo would have to
          be marked as a v2 of genesis config.

          A tool to scan and recommend file renames and edits is needed (and
          ideally has runable output that would do at least the renames)

 4. auto commit after deploy (2.9.0) -
    - this will be configurable via genesis config (and an option on init
 5. `genesis config` to manage .genesis/config file (2.9.0)
 6. `genesis remove` to "undeploy" a given environment.  Preferred over
    `delete` because we're not deleting the environment file. (v2.8.x) -

 7. Store what is in .genesis/manifest in vault instead so that it gets
    automatically committed and no longer needs to be redacted

 8. Innate support for generic kit - sets the deployment type based on
    repository directory name if kit type is "generic"

 9. New remote-compiled-kit provider:
    Downloads kits from repo (as files or releases) instead of embedding in
    repo.  Ensures kits aren't modified locally.

10. Auto-download missing stemcells

11. init-to-deploy mode:  Genesis bootstrap creates a local vault, creates a
    new bosh repo, creates a new bosh via wizard, generates secrets, deploys,
    initializes bosh-hosted vault, transfers secrets to bosh-hosted vault,
    removes local vault.

12.  Fix error on missing safe config/no vaults:
     `Can't call method "env" on an undefined value at /Users/dbell/.geese/lib/Genesis/Env.pm line 610.`

Notes:
  Subkits are removed completely as of 2.8.0 √
  Kits without new or blueprint are not supported as of 2.8.0 √

ToDo:
  prereqs hook - what is it?  do we still need it?  any kits actually using
  it?

  lib/Genesis/Kit.pm:
  -   if (grep { $_ eq $hook } qw/new secrets info addon check prereqs blueprint pre-deploy post-deploy features/) {
  +   if (grep { $_ eq $hook } qw/new secrets info addon check blueprint pre-deploy post-deploy features/) {

CONFIG TODOS:
=============

- Auto-commit after deploy (defaults to yes after 2.9.0, no for legacy)
- Save to safe instead of repo (defaults to yes after 2.9.0, no for legacy)
- Inheritance system


OLDER TODO's / NICE-TO-HAVES
============================

Priorities:
* P1: Must be done before first release
* P2: Highly desirable in the near future
* P3: Needed for completeness, not needed for first release.
* P4: Nice to have/additive functionality, add if you're bored.
* P5: Nice to have, add if customer requests it
* P-: Don't do until further need is expressed/better understood

Herein lies the things we found while working on Genesis v2.
These things need to be done. They cannot be ignored.

- (P3) **genesis ccck** - Cloud Config Check!  Take a manifest,
  fully-generated, and compare it against the cloud-config
  (required argument) to see if they are mutually consistent.

- (P4) **genesis sync** - Allows genesis to download the latest packed genesis and
  replace the current executable.  Command not yet implemented (Low priority
  as the jumpbox kit should grab the latest version)

- (P3) Add --hooks to `create-kit` command;
  --hooks will take a list of one or more of valid hook names;

- (P-) Allow `genesis rebuild env` or `genesis new env --rebuild` to read in
  existing environment yaml file and use it to help build it from scratch
  (existing values become new defaults, etc...)

- (P3) Support for turning off deployments when done (for alpha/testing env + cost savings)
  Add a flag to CI that will shut down the environment via bosh stop --hard, after
  successful deploy (leave up on smoke test failure for troubleshooting).

  This will require adding in dependencies (cf-rabbitmq requires cf), and locking
  the dependent deployments so that cf can't upgrade and turn itself off while cf-rabbitmq
  is trying to make use of it. locker-resource should be able to support this already,
  just need to write in the logic to parse out dependencies from the CI layout, and
  add locking/shutdown/startup steps in the pipelines.

- **genesis dry** (or `dedupe`): given a set of YAML files (i.e. all
  of the environment templates), analyze each for common
  sub-params, and hoist them to the highest (least specific)
  common prefix file.  It would also be nice to find anomalies
  like 'identical override' cases, and either fix or advise.

- **genesis plan** - Take a plan file that defines network ranges
  and cloud properties per infrastructure and pops out a cloud
  config YAML file with all the bits filled out. (cf. netbuilder)
  -- Workaround: use cc-me

## Bake in Concourse pipeline vault policies
- On genesis init, build the hcl file
- On repipe, cycle the role_id and secret_id
- Remove hack that just asks for the role_id and secret_id paths to generate
  the ci.yml file.

## Add validation that any default supplied by kit passes validation?

TODONES:
========

 1. Bosh autoconnection via env vars (v2.8.0) √
    - better proto handling
      - how to detect and deal with proto environment √
      - legacy support √

 3. kit-overrides moves into environment file (2.8.0) √

    Instead of using kit-overrides.yml to make local changes to the kit, you
    can put kit.overrides.* entries in your environment file.  This works
    better because different env files can use different kits, making a single
    override file less effective or even broken.

 6. `genesis update` to get latest genesis command (will be release in v2.7.x) (COMPLETED in 2.7.33) √

10. `genesis bosh` command
    - better `bosh` arg handling  (remove need for --) √
      - auto bosh targetting for proto envs (no need for -d option) X - safety
        first
    - fix or replace `bosh --envs` √

