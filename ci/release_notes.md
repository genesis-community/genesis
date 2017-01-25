# Improvements

- Track the site/env directory itself in Concourse pipeines
  (watch git for changes).  This allows environments to be
  symlinked, in case you want to colo your alpha/beta environments
  and save on some cloud usage costs.

# Bug Fixes

- Remove an errant `cp` of a temporary file to `/tmp`, which
  causes some issues with shared environments (i.e. jumpboxen)
  Sorry.

- Fix a stray call to `ci_update`, which was causing the upkeep
  job to never be created, and corrupted .ci.yml configurations.
  Thanks to @bodymindarts for find, researching and reporting this
  fix so quickly.
