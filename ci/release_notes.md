# Improvements

- Added adaptive merging for manifests and dereferencing kit parameters.  This
  adds the following behaviours:

  - The `genesis manifest` command can now take `--partial` as an argument,
    which will print out the list of spruce operators that could not be
    resolved, and a manifest that has been merged with everything that could
    be resolved.  This can help debug the unresolved operators.

  - Kits can now be authored (with `genesis_version_min: 2.7.24`) that can
    take parameters from the anywhere in the manifest fragments in the kit or
    the environment hierarchy provided by the user (or even bosh config files
    in conjuction with `required_configs` ).

- Added explicit inheritance

  By specifying a `genesis.inherits` list, you can include files outside
  of the hierarchical naming system.  Inherited files can also inherit
  other files, and cyclical references are resolved by reverse-first-
  reference ordering.

# Bug Fixes

- Fix unauthenticated BOSH report

  The `bosh -e <env> env` command erroneously states you're not logged in
  if your access token has expired but your refresh token is still valid.
  The command also does not refresh your access token, but other
  commands do, so we run a stemcell command to trigger the refresh and
  then check env again to see if we are in fact logged in.

- Strip preceeding v from fetch kit version if present (prevents the double-v
  in the progress messages)
