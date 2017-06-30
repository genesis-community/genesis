# Bug Fixes

- Resolved a bug where `genesis init` would ignore
  if the destination it was about to create existed or not,
  resulting in a "new" deployment repo inside an existing
  directory. This now triggers a failure.
- Resolved a bug where `genesis init -k` did not commit
  the downloaded kit to the repo during setup, causing
  the operator to do this manually. It is now committed
  automatically.

# Improvements

- `genesis create-kit` will now include a `Cloud Config` stub
  in the README file that it generates for the kit.
