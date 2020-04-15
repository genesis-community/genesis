# Improvements

* `genesis kit-manual` (man for short) can now display the manual for a given
  kit/version instead of indirectly referencing through specifying a
  deployment that uses it.  It also allows users to specify just the kit name
  (showing the latest local version), just the version (if there is just one
  kit type in the repo) or nothing at all (which will display the latest
  version of the singular kit in the repo. If you have multiple local kit
  types, you must specify the kit name (or environment file that uses it)

  This change allows you to do some pretty useful things:
  * View the manual while creating an environment file by hand, giving you
    full details of the valid properties and features.
  * diff the manual between two files to see if there were any functional
    changes:

    ```
    diff <(genesis man mykit/1.0.1) <(genesis man mykit/1.0.2)
    ```

* After some feedback from the secrets management changes so far in 2.7.x,
  terminology and usage has been adjusted (and hopefully simplified)

  * Secrets that block a deployment from running are considered invalid, while
    secrets that allow the deployment to proceed but might cause an issue are
    considered problematic.

  * `genesis check-secrets` can detect three levels of issues:
    * missing secrets that will block the manifest from being created
    * invalid secrets that will cause the deployment to fail
    * problem secrets that may cause obscure issues

    These can be reported with the `-l|--level` option, which takes the
    arguments of `missing`, `invalid` and `problem`, or their initial for a
    short form.  Lower levels include the ones above, and default is the
    `invalid` level.

    This replaces the --validate and --fail-on-warn flags.

  * Similarly, `genesis rotate-secrets` and `genesis remove-secrets` simplify
    their interface for dealing with invalid and problematic secrets.  The
    `-X|--failed` and `--fail-on-warn` options have been removed, replaced
    with `-I|--invalid` and `-P|--problematic` options as more representative
    names, and with the added behaviour that if --problematic is specified, it
    also includes those secrets that are invalid.

  * `-F|--filter` option has been removed, and simplified to being able to
    specify a list of paths on the command line on which to operate.

  * `genesis remove` and `genesis rotate` support a `-i|--interactive` option
    that will ask for confirmation before respectively removing or
    recreating/renewing each secret.  This was preferred ofer having to
    construct possibly complicated regex filters.

  * `genesis deploy` has lost its --no-validate option, and will always
    validate against the `invalid` level.  It made no sense to allow
    deployments that will knowingly fail.

# Bug Fixes

* Scoping has been improved, so that commands that need to be run from a repo,
  or a kit or against a environment file, or none of the above give the right
  error message when their conditions aren't met.  This also fixes a problem
  where `genesis init` couldn't be run if -C option was specified.

* Fixes incorrect help info for `remove-secrets`
