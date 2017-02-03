# Bug Fixes

- If using aliases + os types with your stemcells,
  `genesis` would fail to check that the stemcell was
  present on your BOSH, and auto-upload it for you.
  This has been resolved.
