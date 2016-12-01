## Improvements

- Add `meta.type`, `meta.env`, and `meta.site` to name.yml.
  Fixes #85

- We now use more finesse when dealing with BOSH directors:

   1. ICMP (ping) is no longer a requirement, we use curl with the
      `--max-time` argument
   2. Responses from BOSH will be cached in a temporary director,
      to be re-used by future jq-y goodness and avoid the extra
      round-trip to a potentially laggy BOSH director
   3. The code for handling BOSH director aliveness is now more
      in-line with the assertion-based architecture of Genesis.
   4. Timeouts for interacting with BOSH can be set via the new
      `$DIRECTOR_TIMEOUT` environment variable.  Value is in
      seconds, and defaults to '3'.

- Checking / verification of stemcells and releases is now only
  done once, minimizing roundtrip interaction with both the BOSH
  director and (if in play) the Genesis Index.

- New command, `genesis update` to pull down the latest _released_
  version of Genesis from Github, and update your local copy.
  Fixes #86


## Bug Fixes

- `cmd ci` commands now properly handle site and environment names
  that contain embedded (non-leadng) hyphens.

- Target bosh director earlier in pipeline based deployment.
  Fixes #91

- `env_hook` failure is now detected and handled properly in
  bosh-init deployments.

- Updating a release version will clear out sha1 and url files to
  force a genesis-index lookup on next deploy.
