# Bug Fixes

* `genesis deploy` checks presence of secrets prior to trying to build a
  manifest

* CA Certs specified in kits honour `valid_for` and `names` properties.  Names
  are added as Subject Alternative Names.
