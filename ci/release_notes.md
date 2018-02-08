# Improvements

- The Genesis CI/CD BOSH lock definitions (for ensuring that
  Concourse doesn't try to re-deploy a BOSH director we are using)
  now run their checks on the workers tagged with the same env as
  that BOSH director.  This fixes automatic detection of the lock
  name so that it works in completely sequestered environments.

# Kit Management Improvements

- Kit versions are now being injected into the kit.yml file during
  `compile-kit`, so that compiled assets properly report their
  version in both the filename and the metadata file.
