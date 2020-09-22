# Improvements

- Updates to pipelines:

  - Commit state file on failed create-env deployment.

  - Add pipeline.notifications to ci.yml.  Can take the arguments of
    `inline` (default), `parallel`, and `grouped`.

    Both `parallel` and `grouped` make the notifications parallel to the
    task that is being notified as ready, so don`t block the manual
    trigger progression.  `grouped` has the additional behaviour that
    moves the notification tasks into a separate group.  The default `inline`
    maintains the original behaviour of notification preceeding the manual
    task.

# Bug Fixes

- Don't block -y|--yes for create-env deploys

  Since create-env deploys follow the spirit of the 'yes' option, we will
  allow it even though it has no effect.  This will allow automation to
  blindly specify -y without having to check if the deployment is a
  create-env.

  This reverts a change found in Genesis 2.7.14

- Fix failures when no safe target is available

  Detection of the safe target was moved to Genesis::Top in v2.7.14, but
  there are a select few circumstances that does not require the safe
  target to be known, such as `genesis embed`.  This fix makes the missing
  safe target non-fatal, but adds a debug warning message if missing.
