# New Features

- **Email Notification Support.**
  Genesis Pipelines now support both Slack notification and Email
  notification (well, really, one or the other).  Existing pipeline
  installations that use slack will continue to work without modification.

  To use the new email notifications, drop the `meta.slack` bits from your
  `ci/settings.yml`, and rpelace them with `meta.email` settings, that
  look like this:

  ```
   meta:
     email:
       to: [ops@example.com, cf@example.com, ...]
       from: concourse@example.com
       smtp:
         host: mailrelay.example.com
         port: 587
         username: concourse
         password: secret
  ```

# Improvements

- **Pipeline Upkeep is now optional.**
  If you set `meta.skip_upkeep` to a non-empty true value, Genesis will
  now skip the stemcells upkeep job, and not include it in your pipeline.
  This can be helpful if you don't want to roll stemcells automatically.

- **Support BOSH directors with the same URLs.**
  Some environments like to re-use IP addresses.  This change allows them
  to do so (assuming tagged workers), by changing the structure of
  `ci/boshes.yml` in a backwards-compatible way.

  Old (still supported) file format:

  ```
  auth:
    $url:
      username: ...
      password: ...

  aliases:
    target:
      $uuid: $url
  ```

  New format:

  ```
  $site-$env:
    auth:
      $url:
        username: ...
        password: ...
    aliases:
      target:
        $uuid: $url

  $othersite-$env: ...
  ```

- **Vault user-id can now be overridden.**
  Sometimes, the defaults are too guessable.  If your Vault exists on an
  open network (like the Public Internet) you may want to generate a more
  secure 'secret' to use as the user-id.  Now you can.

- **Tagged Worker Pipeline Support.**
  If you set `meta.tagged` to a true (non-empty) value, Genesis will tag
  each task with the site-env name, so that you can implement against
  globally-distributed concourse platforms, with lots of tagged workers.

# Bug Fixes

- **Handle `-p` in CI jobs.**  Now, Genesis fully supports
  separate pipelines for different subsets of environments.
