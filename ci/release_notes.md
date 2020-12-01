# Improvements

* Pipeline: ci-show-changes now states explicitly when no differences were
  found.

* Unless explicitly a config of a given type is explicitly identified by name,
  we now fetch and merge all configs of a given type (ie cloud, runtime) when
  a kit indicates that they are needed.

# Bug Fixes

* Better error message if `genesis.env` (and also `params.env`) is missing from
  the environment file.

* Pipeline: cpi configs are not associates with deployment, so there's no way
  to tell which version of the CPI configs were used on the previous
  deployment.  Therefore, we now exclude cpi config in ci-show-changes.

* Auto-authenticate to vault after running a long-deployment so that exodus
  data could be added successfully was added a few releases back, but for kits
  that use credhub (ie cf-genesis-kit), access to the bosh director's exodus
  data (and thus vault) was needed to assemble the exodus data to be stored.
  This happened prior to reauthenticating to vault, and therefore failed.
  This has now been resolved.

* Better support for multi-doc yaml: Ensure YAML partition is on a new line

  YAML files are text files, and text files (in \*nix) consist of a series
  of lines, each terminated by a newline character, including the last
  one.  So this is the behaviour Genesis expected when merging multiple
  source YAML files into a multi-doc file.

  HOWEVER, _certain_ editors don't naturally obey this spec, and when
  Genesis encountered these files in the wild, the `"---\n"` separator was
  appended to whatever the last value in the previous file was, which
  didn't result in a proper multi-doc file and data was corrupted.  We now
  join with `"\n---\n"` just in case.

