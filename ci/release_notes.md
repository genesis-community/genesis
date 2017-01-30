# Bug Fixes
- Over the course of time, a few calls to sha1sum had been added,
  which would cause issues on Darwin, if you did not have the GNU
  coreutils installed. This has been resolved

- Fix a regression in `genesis ci smoke-tests` that would not
  allow any test name to be used, due to misplaced initialization.

- Fix a regression that was itself a fix of an imaginary
  regression.  I'll just be over hear, deploying pipelines...
