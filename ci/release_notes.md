# Improvements

- `prompt_for` not treats any non-option arguments as individual lines, making
  it easy to have multiple-line prompts in BASH.

# Bug Fixes

- Temporary directory for `offer_environment_editor` helper now works on Linux
- Fixed misnamed method call in `ci-pipeline-deploy`
- Updated ci pipeline to resolve cyclic runaway on rc version bumps

# Software Updates

- Bumped dependency on `spruce` to 1.20.0 to support kv v2 backends.
