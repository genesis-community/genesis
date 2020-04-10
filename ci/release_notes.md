# Improvements

* When the user is prompted for confirmation to recreate, renew, or remove
  secrets, it now shows the base path for those secrets.

* Better human-readable paths when outputing references to paths

# Bug Fixes

* Chicken-Egg issue resolved when creating a new environment needs an
  environment to save secrets prompted for in the creation process. (#398)
