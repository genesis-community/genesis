# Improvements

* Refactored the `genesis secrets` command to take a sub-command of `check`,
  `add`, or `rotate`.  Rotate behaves the same way as the original command,
  including supporting a `--force` option to force rotation of ALL
  secrets.<br><br>The `add` command allows you to generate any missing secrets
  while leaving existing secrets in place.  Useful for when you run `genesis
    new --no-secrets` or after upgrading the kit to a version that may add new
    secret requirements.<br><br>The `check` command will allow you to check if
    any secrets are missing.  It will list the missing secrets, and for
    automation purpose, will return an exit code of 1 if any are missing, 0
    otherwise.
    
## Breaking Change
    
If you omit a subcommand, it defaults to `check`.  If you have any automation
that uses this, please update to specify `rotate` explicitly.  Furthermore,
the `--force-rotate-all` has been shortened to `--force`, but still accepts
the original.
