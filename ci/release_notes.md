# New Feature

* Add `update` genesis command to get new version

  Usage: genesis update [-c|--check] [-v|--version VERSION] [-d|--details] [-f|--force]

    -c, --check       Check if a newer version (or the specified version) is
                      available.

    -v, --version <x> Install the specified version instead of the latest

    -d, --details     Print the release notes of the versions between the current
                      version and the latest (or the release notes of the
                      specified version)

    -f, --force       Replace the current genesis executable.  Otherwise,
                      confirmation will be requested.

# Improvements

* Improve `genesis kit-provider -v` status output

* Improve `genesis list-kits` hint to include -r flag.

* Make it easier to trace the stack

  Adds the -S|--show-stack debug option, and gives better context of traces
  and errors.

  Behaviour Changes:

  - internal `trace` output will show the location in the code were it was
    called. If --show-stack option specified, it will show the full stack
    instead of just the location.

  - internal `dump_vars` output will now show the full stack instead of
    just the calling location if --show-stack specified (along with
    --trace or --debug)

  - internal `bail` will show calling location if --trace or --debug is
    specified, or the full stack if --show-stack is specified (with or
    without --debug or --trace).  This allows you to see where genesis
    terminates without wading through all the trace output.

  - internal `bug` will always full stack where the bug was encountered.
    This allows the user to paste the stack into a defect report against
    the genesis project.

* Limited false positives of detected changes in pipeline notify summaries. 

# Bug Fixes

* Fix getting non-production github release version

  If user specified version by name, it should include draft and
  prereleases when looking for it.  This was the initial intent, but the
  wrong options were set when attempting it.

* Fix error when calling `genesis man` on a kit that does not exist.

* Fixes issue where proto-bosh deployment did not have up to date state file.

