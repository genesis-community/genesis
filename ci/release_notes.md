# Bug Fixes

* Resolve adaptive merge errors caused by inject operator.

  If the manifest contains a inject operator, which is injecting another
  spruce operator (ie grab or vault) that cannot be resolved, the adaptive
  merge code could not find and resolve this.  This has now been handled.
