# Improvements

* Now supports extraction of bosh variables and credhub secrets into exodus
  data for cross-kit integration and addon support.

* When testing availability of the vault, it specifies the alias and url of
  the vault instead of specifying "selected vault"

* Clarify usage of --recreate and --fix options for deploy

# Bug Fixes

* Universal support for timeout detection when attempting to connect to remote
  BOSH and Vault, with better feedback in case of timeout (Fixes #412)

* Adds support for multiline provided secrets rotation and addition (Fixes #413)

* Fix typo in rotate-secrets help (Fixes #414)

* Deployments using legacy mode for secrets providers now get the vault
  connection validated prior to using it

* Fixed bug where non-standard secrets mount would report the vault was
  uninitialized.

# Kit Authoring Improvements

* Kit manifests can now use the same environment variables used by the hooks
  script, via spruce, to perform actions such as:
  `(( vault $GENESIS_EXODUS_MOUNT params.cf_deployment_name ":admin_password" ))`

