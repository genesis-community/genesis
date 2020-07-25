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

# Bug Fixes

- When safe was not configured with any targets, the error that occurred in
  Genesis was confusing and not explanatory.  It will now plainly explain that
  it is can't read `.saferc` and therefore not select the desired vault.

- Fixed some BOSH config requirements that were problematic for some edge cases

- Improve hook standard error handling.

  Previous improvements stopped stderr from being output directly to
  screen.  This has been fixed so that STDERR will be written directly to
  screen when in interactive mode, and will still be output by blueprint
  even when its not fatal.

# Minimum Dependencies

- bosh: v5.0.1
- spruce: v1.26.0
