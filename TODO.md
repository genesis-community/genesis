TODO
====

To-Do for v2.8.0+

 1. Credhub add, check, rotate and remove secrets (v2.9.0)

 2. Use Cepler for pipelines (2.10.0)

		https://github.com/bodymindarts/cepler

 3. Better inheritance system (convension over configuration) (2.9.0)
		 5.1. Fix how genesis determines what is a env file or not

					This is currently done by having a genesis.env or params.env set to
					the same name as the file.	This has long been a contensious issue
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
		- better `bosh` arg handling	(remove need for --) √
			- auto bosh targetting for proto envs (no need for -d option) X - safety
				first
		- fix or replace `bosh --envs` √


More:
	(#BETTERVAULTTARGET)
	Automatically capture more vault details for automatic creation of vault on
	other systems (works in conjuction with existing auth variables)
				# TODO: capture and use a default name, namespace, and stronghold context: [namespace@]https?://<ip-or-domain>[:port] [as name] [no-verify] [no-stronghold]
				# Until done, we'll just rely on user having set up a safe at the same domain in their .saferc file.
				# as name will only be used if they don't already have a safe with that alias in that file
				# On creation, user will be asked auth method, then will be able to authenticate

				By doing this, we don't need to use env vars for strongbox, namespace
				and name in vault_auth (bin/genesis:line 237)


TODO 2023-06-30:
* Many genesis commands don't need to validate to vault, or conditionally
  validate to vault, such as most of the kit commands.  Not having a vault or
  being unable to connect to vault should not block these commands.
  - Resolved: 2023-08-01

* compile kit should:
  a) detect if you're in a repo with a dev directory containing kit.yml and
  assume -d option
  b) Not error out if the kit name doesn't already exist when trying to
  ascertain previous versions

2023-07-18:

* Genesis link-kit to allow for a dev kit to be linked to local directory,
  like genesis init -L

2023-11-16:

* Pass in cpi for offline mode, just like cloud and runtime config
* Fix specifying named runtime configs (currently only default)

* Support multiple vaults.

  Bump config to version 3, and replace secrets_provider with an array under
  `secret_stores`.  Each entry in the array is a hash with the following keys:
  - name: the name to refer to this vault by
  - type: vault (for now)
  - descriptor: the genesis-style descriptor for the vault in the form of
    [namespace@]https?://<ip-or-domain>[:port] [as name] [no-verify] [no-stronghold]

  This will be utilized by each environment to determine which vault to use
  for that environment -- unspecified vaults will default a vault named
  "default" if it exists, or the first vault in the list if not.

  There is no current plan to support multiple vaults in a single environment,
  but this may change if there is a valid method to use a different vault for
  the manifest and another for exodus data.


Turn output of `genesis envs` into json for easier parsing by other tools,
maybe also csv for easy import into spreadsheets.

* Add `genesis envs --json` and `genesis envs --csv` commands

Add ability for `genesis update` to:

* Pick a different target directory/filename for the new genesis binary
  instead of always overwriting the current one.

* Add the ability to list older versions of genesis and select one to
  install, instead of always installing the latest.
  * This may be two separate commands, with `genesis update --list` to list
    available versions, with a second option to show --older or --all (default
    is newer -- this is currently provided by `genesis update --check`).

  * Perhapse an interactive mode to select latest, or list newer/older/all
    and also include pre-releases and drafts, and then once selected, you can
    get the release notes, and then install it, prompting to overwrite the
    current binary, or install to a different location and name.  (it could 
    even be smart enough to detect a bin directory under the user's home and
    offer to install there with the version in its name ie `genesis-2.8.12` or
    `g2.8.12`)

Show what versions of releases are being overridden by the user from the ones
that come from the kit.  Make it an option to show this during deploy/manifest
generation.  Also good to see in an expanded `genesis envs` output (kit
features in use, release overrides, etc).

Genesis deploy should work like pipeline in regard to propagating the
hierarchial changes.  Make this a value in the config file (deployment) and
have it set on/off, and/or have specific environments protected from being
pushed without cache/gating.

Transitional Cert Rotation:

* Add a `--transition` option to `genesis deploy` that will do the following:

  1. Warn the user that a transitional cert rotation is about to occur, and
     they should not run any \*-secrets commands until the full deployment
     cycle is complete.

  1. Show what certs will be transitioned. Specify that any user-provided 
     certs will not be transitioned, and to consult `genesis help
     user-provided-certs` for more details. Ask for confirmation to proceed.

  1. On first deploy, copy the current certs to
     <cert-path>/transitional/old and generate new ca certs in the
     original <cert-path> path using standard rotation methods (not renew
     because we want a new key).

  1. Copy the new certs to <cert-path>/transitional/new then copy back the
     non-ca certs from <cert-path>/transitional/old to <cert-path> and merge
     the new ca certs and the old ca certs into the <cert-path>:ca location.

  1. Update exodus to show transitional state 0 - certs altered but not
     deployed.

  1. Deploy the generated manifest as normal.

  1. On successful deploy, update exodus to show transitional state 1 - new 
     ca certs deployed.

  1. Prompt the user if they want to proceed to the next transitional state
     (2 - new non-ca certs deployed).

  1. At this point, the user can run `genesis deploy --transition` again to
     proceed to the next transitional state, as tracked by exodus.  If they
     run deploy without --transition, it will error out and tell them to
     run with --transition to proceed, or if needed, `genesis deploy
     --reset-transition` to revert to the previous state.

  1. Identify that this is a transitional deployment to the user and which
     certs are in transition.  Ask for confirmation to proceed.

  1. Copy the new non-ca certs to their original locations.

  1. Deploy the generated manifest as normal.

  1. On successful deploy, update exodus to show transitional state 2 - new
     non-ca certs deployed.

  1. Prompt the user if they want to proceed to the next transitional state
     (3 - old ca certs removed).

  1. At this point, the user can run `genesis deploy --transition` again to
     complete the transitional deployment, as tracked by exodus.  If they
     need to revert, they can run `genesis deploy --reset-transition` to
     do so.

  1. Identify that this is a transitional deployment to the user and which
     certs are in transition.  Ask for confirmation to proceed.

  1. Copy over the new ca certs to the <cert-path>:ca location.

  1. Deploy the generated manifest as normal.

  1. On successful deploy, update exodus to show we are no longer in a
     transitional state.  Remove the transitional old and new paths from safe.

  1. Announce to the user that the transitional deployment is complete and
     they can now run \*-secrets commands as needed.
