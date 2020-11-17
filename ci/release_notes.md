# Bug Fix

- Fixes adaptive loading of environment that would otherwise break due to
  spruce operator errors (missing paths or vault access).  This was required
  to support multi-doc parsing released in v2.7.20, but contained edge cased
  that have now been resolved.

  If you continue to have issues loading environments, you may use `export
  GENESIS_UNEVALED_PARAMS=1` to restore previous behaviour (assuming you are
  not using multi-doc yaml files.  Please open a github ticket if you
  encounter such an error, and provide the content (sanitized of any private
  information by replacing with dummy values) of your environment hierarchy.

- Pipeline deploy now correctly checks enviornment prior to deploying, as per
  the method manual `genesis deploy` does it.

- Fix missing BOSH variable during the pipeline show-pending-changes step.
  This resulted in any location using a BOSH variable showing up as a change.

- Handle missing cloud config fields when checking environment has the correct
  cloud config settings.  If an entire field was missing instead of just a
  entry in that field, the check script would fail with a `jq` error.
