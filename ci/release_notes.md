# Breaking Changes

* No longer set $HTTPS_PROXY to $BOSH_ALL_PROXY

  This broke under two conditions:

  1) If you wanted to use BOSH via a proxy, but your vault was on your
     home network

  2) If you used a protocol of ssh+socks5, which is not supported by
     HTTPS_PROXY.

  Instead, if you are setting BOSH_ALL_PROXY, you must set HTTPS_PROXY or
  alternatively SAFE_ALL_PROXY instead of relying on Genesis to do that
  for you.

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

* Add features hook

  While blueprint hook has the ability to make decisions on when a feature
  is NOT present, or on specific combinations of features, that ability is
  beyond other interactions.

  We used to have a subkit hook which would allow you to create derived
  features so that default features and not-features could show up as
  explicit features, which allows things like secrets management to
  determine dependencies for these. (ie lack of a features can result in a
  `not-feature` derived feature to add secrets for a default state)

  This has been re-realized as a `features` hook, which given a list of
  features in the `$GENESIS_REQUESTED_FEATURES` value, can provide a
  derived list of features, which will be used by internal genesis for the
  environment's features list, which in turn will be used to populate
  `$GENESIS_REQUESTED_FEATURES` for other hooks.
