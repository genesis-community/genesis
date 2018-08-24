# Bug Fixes

- `genesis embed` now properly handles packed (2.6+) genesis
  distributions, and instead of just copying the extracted driver
  script, now embeds the packed archive binary.  This makes the
  pipelines a lot happier.

- `genesis repipe` now properly hides / unhides pipelines per
  configuration.  All this talk of pipelines and we misspelled
  piepline.
