# Improvements

- `genesis deploy` now only redacts in CI/CD pipelines and when
  run non-interactively (i.e. when not attached to a controlling
  terminal).

- `genesis secrets` now properly detects a missing environment
  name, instead of throwing obtuse errors about uninitialized
  variables in pattern matching.

- When running in debug mode, genesis now runs curl with the `-v`
  flag, so that operators can see what headers and responses are
  being sent across the wire.

- Genesis pipeline steps now print the version of Genesis that
  they are running, to ease debugging / troubleshooting of
  pipeline weirdness.

- Genesis pipelines can now be configured in `unredacted: yes`
  mode, causing them to run `genesis deploy` without redaction.
  This has the potential to leak sensitive credentials like
  passwords and keys, so use this with caution, and only on
  secure Concourse installations that are not publicly viewable.

- `genesis compile-kit` now halts, refusing to compile the kit
  tarball, if you have unstaged or uncommitted changes to your
  working directory.

- `genesis create-kit` now populates a .gitignore with appropriate
  entries, to save you from the embarassment of commiting a
  compiled kit tarball to the git repo.

- If you are an Atlassian shop, you can use their new Stride chat
  system for Concourse CI/CD pipeline notifications!  Something
  something curiously long-lasting chats.

# Bug Fixes

- Fix bad reference in `valid_features()` helper made available to
  the blueprint hook.

- If a blueprint hook emits a non-existent YAML file for merging,
  the errors from Genesis are now (a) correct and (b) helpful.

# Kit Authoring Improvements

- Your hook scripts can now set `-e` and `-u` bash options,
  without running afoul of poor programming practices in the
  helper scripts.

- The `secret-line` prompt type now supports an `--echo` boolean
  option for storing stuff in Vault, but not using secure, noecho
  prompting to do so.  This is great if you want to store things
  like user names or IPs in the Vault, but don't want to make
  operators enter them double-blind with confirmation.

- Kit authors no longer have to define `meta.vault` as a concat of
  "secret/" and the `params.vault` value; Genesis now does this
  for you.  You are welcome.

- New unbounded maximum range validation: e.g.: 3+ for 3 or greater.

- The `prompt_for` helper (used in `hooks/new` scripts) can now
  validate IPv4 addresses, natively.  Just specify `ip` as the
  validation type!

- `genesis compile-kit` is a bit less opinionated on what files
  are required now, since `hooks/blueprint` removes the need for
  the `base/` and `subkit/` directories, and `base/params.yml`
  no longer holds special value.
