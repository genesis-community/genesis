# Improvements:

* Added ability to generate vault policies for Concourse pipelines as part of
  the `genesis ci` wizard.

* Allows user to select to not add specific environments to the pipeline in
  the `genesis ci` wizard.

* Added ability to echo vault-stored parameters in `genesis new`.

# Bug Fixes:

* When generating ci.yml, the `genesis ci` wizard defaults to port 25555 for
  BOSH director URLs when no port is provided by the local BOSH config.
