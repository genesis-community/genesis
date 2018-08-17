# Improvements

- Certificates in kit.yml can now have subject alt names that
  are optional, using the new `${maybe:params.name}` syntax.
  If `params.name` isn't found in the environment file(s) then
  that SAN entry will be skipped entirely.

  This allows Kit Authors to generate certificates with
  user-provided external domains, optionally.
