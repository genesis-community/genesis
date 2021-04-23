# Improvements

- credhub-cli is now a requirement. A check for credhub-cli has been added

- jq v1.6 is now the minimum version required

# Bug Fixes

- The -no-config option to `genesis check` is properly documented.

- CF validates X.509 issuer by comparing the subject of the CA cert, which
  causes a problem when renewing certificates that changed their subjects.
  To work around this, `genesis rotate --renew` will only renew subject if
  `GENESIS_RENEW_SUBJECT` environment variable is truthy.

- Suppress error on missing `GIT_GENESIS_ROOT` value

  This only needs to be set to override the default of `.`, but when it
  was missing, perl complained about comparing undef to empty string.

- Use proper spruce merge for `ci-show-changes`

  The previous method of just sprinting the manifest, secrets and configs
  together failed when they configs had duplicate yaml nodes.


- Ensure we're in the proper directory before merging manifest in
  `ci-show-changes`

- Improve vault auto-authentication routines

  The existing support for Vault auth-authentication worked well, except for
  two issues:

  1) If the vault being authenticated to was the vault being deployed, the
     post-deploy hooks would never run to unseal the vault because the
     vault couldn't be authenticated because it was sealed.

  2) Checking the status of the vault automatically authenticated to the
     vault instead of telling the real status (internal) which caused
     failures.

  The behaviour is now corrected for these cases.
