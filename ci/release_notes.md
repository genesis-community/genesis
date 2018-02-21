# Improvements

- `genesis deploy` now only redacts in CI/CD pipelines and when
  run non-interactively (i.e. when not attached to a controlling
  terminal).

- Genesis pipelines can now be configured in `unredacted: yes`
  mode, causing them to run `genesis deploy` without redaction.
  This has the potential to leak sensitive credentials like
  passwords and keys, so use this with caution, and only on
  secure Concourse installations that are not publicly viewable.
