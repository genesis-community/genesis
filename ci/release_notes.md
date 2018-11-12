# Kit Authorship Improvements

- Improved validation when compiling kits.

  Breaking Change:  `genesis compile-kit` will now error if you are using
  legacy keywords in your kit.yml, such as `subkits` and `params`.  If you are
  maintaining a legacy kit and need to compile a new version, you may use the
  `-f` option to force the compilation, but be warned, this will bypass all
  the validation.  It is recommended instead to bring your kit up to the
  latest standards.

# Bug Fixes

- `genesis deploy` checks presence of secrets prior to trying to build a
  manifest

- CA Certs specified in kits honour `valid_for` and `names` properties.  Names
  are added as Subject Alternative Names.

- Fixed error in minimum Genesis version specification in generated template
  and validation.
