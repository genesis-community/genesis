# New Features

Genesis 2.6 is a landmark release that introduces several new
hooks to make it easier for kits to control the Genesis
interaction:

  - `hooks/new` - Bring your own wizard for standing up a new
    environment, with more flexibility and power.

  - `hooks/blueprint` - Explicitly prescribe how feature flags
    (formerly "subkits") translate into a set of Kit YAML files to
    merge.  This removes the need for _parametric_ subkits, and
    allows Kit authors to prescribe merge order.

  - `hooks/info` - Allows the Kit to pull information from the
    Vault, and display it to operators, without getting bogged
    down in implementation (deployment) details like internal
    passwords.

  - `hooks/addon` - Provide small tasks that can be executed by
    the new `genesis do` machinery, for everything from loggin in
    to download CLI utilities and more.

  - `hooks/check` - Pre-flight tests for environment files, which
    empower Genesis to inspect things like cloud-config (did you
    define that vm_type you want to use?) and the Vault (are the
    certificates still valid, or did you change the IPs?), to
    ensure a smoother deployment experience.

The `genesis do env ...` command is new in 2.6, and takes
advantage of the new addon hook to allow operators to run small
convenience tasks.  The BOSH kit, for example, has an addon task
for logging into the newly-deployed BOSH director, and another for
uploading the appropriate stemcell (based on the IaaS in play)

The `genesis info env` command is also new in 2.6.  It combs
through the Vault and the environment manifest, looking for useful
or interesting things about the deploy, to show to the operator.
No more Vault diving!

# Bug Fixes

- Now checks for minimum versions of jq (1.5) and curl (7.30.0).

- Support dash / other POSIX-compliant `/bin/sh` implementations
  whenever we call system() or `qx()` to execute things.  We now
  explicitly call bash (in `$PATH`) to get bash semantics.

- `genesis deploy` exits with the correct exit code (received from
  BOSH deploy)

# Internal improvements

- All occurrences of running shell commands have been unified with
  improved debugging output (-D)

- The megalo-script that was bin/genesis is now a series of
  independently testable modules that get mashed back together as
  part of the build process (via `./pack`) into a distributable
  archive.
