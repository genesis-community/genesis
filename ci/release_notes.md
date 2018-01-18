# New Feature

* In anticipation for new features in Genesis that kits may rely on, Genesis
  now allows kits to specify the minimum version of Genesis that they can be
  used on.  Specify `genesis_version_min` to a semver value in your kit.yml to
  make use of this.  By default, creating a new kit with `genesis create-kit`
  will set this to your current version of Genesis.

# Bug Fix

* `genesis repipe` no longer fails when using locker without keeping stemcells up-to-date
