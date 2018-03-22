# Bug Fixes

- Now checks for minimum versions of jq (1.5) and curl (7.30.0).

- Support dash / other POSIX-compliant `/bin/sh` implementations
  whenever we call system() or `qx()` to execute things.  We now
  explicitly call bash (in `$PATH`) to get bash semantics.

- `genesis deploy` exits with the correct exit code (received from BOSH
	deploy)

# Internal improvements

- All occurrences of running shell commands have been unified with improved
  debugging output (-D)
