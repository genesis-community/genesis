# Improvements

- The Genesis CI/CD BOSH lock definitions (for ensuring that Concourse doesn't
  try to re-deploy a BOSH director we are using) now run their checks on the
  workers tagged with the same env as that BOSH director.  This fixes
  automatic detection of the lock name so that it works in completely
  sequestered environments.

- Improved various aspects of the tests for Genesis itself, including but not
  limited to standing up the dev test vault so dont have to shut down your own
  dev vault if you are using one.

- Improved Genesis's own CI/CD pipeline and Docker images.

# Kit Management Improvements

- Kit versions are now being injected into the kit.yml file during
  `compile-kit`, so that compiled assets properly report their version in both
  the filename and the metadata file.

# Bug Fixes

- Fixed bug when using blueprint hook in dev kits.
