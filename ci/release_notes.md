# Improvements

- Add `-L|--link-dev-kit <dir>` option to `genesis init` to allow creating a
  genesis deployment repo using a kit already found on your machine.  Though
  primarily useful for developing the dev kit itself, it could also be used
  for utilizing a distributed collection of private kits.

- The `BOSH_ENVIRONMENT` env var can be used to tell genesis which BOSH env should be
  configured when making a new environment (simialr to `genesis new -e <env>`,
  and the `GENESIS_BOSH_ENVIRONMENT` env variable)

# Bug Fixes

- Resolve issue where CLI flags were being parsed case-insenitively.

- When no git config is setup, `genesis` will now fail quickly with useful errors
  during a `genesis init`

- `genesis` no longer tries to look for the v1 bosh, as it is unused by `genesis`.
