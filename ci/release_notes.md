
# Improvements

* Better deployment process and output, suppression of duplicate warnings.
  This change also allows kits to use the pre-deploy hook to validate
  conditions AFTER the manifest has been fully generated.

* Extract redacted vars file into repo (along with existing redacted manifest)
  after deployment.

* When a Genesis command needs access to BOSH, it would check if it was
  reachable.  However, reachable does not mean accessible, so we now check
  that the user is authenticated with the BOSH director.

* Improvements to README.md generated when initializing a new Genesis
  repository.  Thanks to Vasyl Tretiakov.

