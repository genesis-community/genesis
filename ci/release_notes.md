# Improvements

- `genesis deploy` now only redacts in CI/CD pipelines and when
  run non-interactively (i.e. when not attached to a controlling
  terminal).

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

- `genesis create-kit` now populates a .gitignore with appropriate
  entries, to save you from the embarassment of commiting a
  compiled kit tarball to the git repo.
