# Improvements

* Expanded config support.  Kits can now specify which configs are required
  and for what hook scripts.  This allows for custom cloud and runtime configs
  to be validated and used for information.  Furthermore, cloud config can now
  be used during the `new` script to check if the required keys are present or
  even propose values that can be added.

  This is done using one of the following two styles:

  ```
  --- # kit.yml required_configs style 1
  required_configs:
    - cloud
    - runtime
    - runtime@thiskit
  ```

  ```
  --- # kit.yml required configs style 2
  required_configs:
    cloud: true
    runtime: [blueprint new]
    funky: false
  ```

  In the first style, all hooks will require the listed configurations.  In
  the second style, `cloud` config will always be required, `runtime` will
  only be required when processing `blueprint` and `new` hooks, and `funky`
  will never be required.

  By default, if no `required_configs` block is specified, only `cloud` config
  is requred when processing `blueprint`, and no other hooks.  This is
  effectively the previous behaviour.

* Add `move_secrets_to_credhub` bash helper function

  `move_secrets_to_credhub src_path:key dst_path`

  This will move a secret under the environments Vault area to the
  environments credhub area.  Do not include the secrets base before the
  `src_path`, or the bosh env/deployment prefix before the `dst_path`.


# Bug Fixes

* Kit releases that preceed the current version by 30 or more releases are no
  longer reported as non-existant.

* Compiled kits no longer contain the spec tests and kit devtools, as they
  aren't needed to use the kit.

* Improved details given when hooks fail, specifically when `blueprint` fails
  to determine which manifest fragments are requied for merging

* Don't populate missing `maybe` params

  When a parameter is conditionally available, the `maybe:` parameter
  dereference would prevent errors if the parameter was missing, but it would
  leave an empty string as the value.  This changes that behaviour to drop the
  key or the array element that was being set to the missing parameter.
