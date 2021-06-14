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

# Bug Fixes

* Fix getting non-production github release version

  If user specified version by name, it should include draft and
  prereleases when looking for it.  This was the initial intent, but the
  wrong options were set when attempting it.

* Improve `genesis kit-provider -v` status output

* Improve `genesis list-kits` hint to include -r flag.

* Fix error when calling `genesis man` on a kit that does not exist.

