# Improvements

- Add `-L|--link-dev-kit <dir>` option to `genesis init` to allow creating a
  genesis deployment repo using a kit already found on your machine.  Though
  primarily useful for developing the dev kit itself, it could also be used
  for utilizing a distributed collection of private kits.

# Bug Fixes

- Resolve issue where CLI flags were being parsed case-insenitively.
