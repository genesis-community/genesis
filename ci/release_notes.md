# Improvements

  The `--cloud-config|--cc` and `--runtime-config|--rc` have been streamlined
  into a single `--config|-c` with backwards compatibility to the existing
  `-c` (for cloud config).  You can now specify named configs as such:

  ```
  -c [type[@name]=]/path/to/config.yml
  ```

  If type is not given, it is assumed cloud, and likewise if name is not
  given, it is assumed to be the unnamed `default` config for the given
  type.

  `-c` can be specified multiple times to specify multiple configs.  It
  does not error check that you haven't specified the same type and name
  multiple times, so that's on you to ensure you're not doing that.

# Bug Fixes

* The overly agressive downloading of cloud config for most activities has
  been reduced to only deployment and check, as was the previous behaviour.
  Likewise, the downloading of cloud config is not attempted when deploying a
  proto-bosh (or anything else that uses create-env for deployment)
