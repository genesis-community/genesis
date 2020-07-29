# Improvements

- Add better kit id to exodus data

  As more things use the previously deployed kit to determine what needs
  to be upgraded, it is important to have this information correctly
  identified.  Prior to this change, dev kits reported the name as dev and
  the version as latest (from the env yaml file)

  This change uses the kit name and version located in the kit.yml file
  directly, and also adds `kit_is_dev` to record that a dev kit is being
  used.

- Added features to exodus export, info script

  Features are now stored in exodus on successful deploy, and reported by
  the info command.

- *BREAKING CHANGE* Hooks now use `CREDHUB_*` environment variables to
  connect to credhub.  This required your BOSH to be deployed with
  bosh-genesis-kit v1.15.1 or later - please upgrade your bosh prior to
  deploying any kits that use Credhub (cf, cf-app-autoscaler)

- Decouple vault/bosh with loading of env

  Not all genesis commands need vault or bosh, but it was being
  proactively connected any time the env was loaded.

# Kit Development Improvements

- Add ability to require connections to kit hooks

  Normally, hook don't need bosh or vault, but if they do, the kit can
  specify which hook needs vault or bosh (or in the future credhub) so
  the connection can be validated before the hooks are run (similar to the
  required_configs behaviour)

- Allow feature hook to access the same environment variables and helper
  script that the other hooks use.

# Bug Fixes

- When safe was not configured with any targets, the error that occurred in
  Genesis was confusing and not explanatory.  It will now plainly explain that
  it is can't read `.saferc` and therefore not select the desired vault.

- Fixed some BOSH config requirements that were problematic for some edge cases

- Improve hook standard error handling.

  Previous improvements stopped STDERR from being output directly to
  screen.  This has been reverted so that STDERR would be output directly to
  the terminal in real time.

- Resolve recursion issue with feature hook checking if bosh create-env is
  specified, which needs to check features, which runs feature hook...

- Prevent double check_prereq calls

# Minimum Dependencies

- bosh: v5.0.1
- spruce: v1.26.0
