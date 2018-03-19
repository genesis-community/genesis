# Bug Fixes

- Support dash / other POSIX-compliant `/bin/sh` implementations
  whenever we call system() or `qx()` to execute things.  We now
  explicitly call bash (in `$PATH`) to get bash semantics.

# Internal improvements

- All occurances of running shell commands have been unified with improved
  debugging output (-D)
