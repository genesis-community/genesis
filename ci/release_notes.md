# Improvements

* Soften secrets validation assessment

  This commit lowers the validation assesment from error to warning on the
  following:

  X509:
    - CN doesn't match kit's expected CN
    - SAN doesn't match kit's expected SAN, or if CN matches a diffent SAN
    - Usage doesn't match kit's expected usage.

  dhparams, rsa and ssh:
    - size doesn't match kit's expectation

  random string:
    - size doesn't match kits expection
    - characters used contain invalid characters

  Added warnings for when certificate is expected to expire withing the
  next 30 days.

* Ensure genesis.env is present, warn on params.env

  2.6.13 deprecated `params.env`, and for a brief time printed a warning
  to that effect until it was determined that it was too noisy.

  2.7.0-2.7.6 removed the usage of `params.env` and enforced the migration
  of params.env to genesis.env, and kits declared with minimum version of
  2.7.0 were expected to use `genesis.env` where they before used
  `params.env`.

  After pushback, we have decided to soften the stance, and print warnings
  when the environment uses a kit with genesis_version_min of 2.7.0 or
  higher.  As these kits require genesis.env to be set, we do so as part
  of the manifest merge.

# Bug Fixes

* Fix kit version lookup on unsaved new environments

* Fix expanded path in GENESIS_CALLBACK_BIN

  If the genesis binary invoked involved a symlink in the path, then the
  binary reference would have the full path.  This fixes that.
