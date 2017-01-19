## The Documentation Release

This release overhauls the documentation system to provide help for not
only the commands, but the concepts around Genesis.  Also improved
error handling messages for usage errors.

You can access these by typing `genesis help` for the help overview or
`genesis help --topics` for the list of all topics.

## Other Noteworthy Improvements

- `genesis ci` commands now take a `-p pipeline` argument, for
  specifying alternate pipeline configurations, of separate
  environments.

- Added parent support to the CI pipeline, so that you can select which
  environment preceeds another environment instead of all preceeded by
  alpha->beta.  See `genesis help ci parent`

- Added support for correct handling of stemcells in v2-style manifests.
  See `genesis help use stemcell` for more information
