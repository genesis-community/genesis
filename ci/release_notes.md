# Bug Fixes

- Handle proxy-injected headers when downloading assets via curl.
  Some proxies will give back provisional, non-3xx responses to
  indicate that they are connecting to the requested resource.
  This no longer confounds genesis.
