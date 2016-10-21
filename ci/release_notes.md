# Bug Fixes

- Fixed an issue where `genesis`'s automatic release/stemcell detection would fail sometimes
  due to slow connections to the BOSH director, or delays returning stemcell data.
- Fixed an issue with `genesis ci stemcell` not properly updating the `url` file.
