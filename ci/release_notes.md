# Bug Fixes

- Fixes an issue when using kits with hooks that relied on helper scripts.
  Previously the helper scripts were not being properly extracted, causing the
  hooks to fail. All contents of `hooks/` of a kit are now extracted.
