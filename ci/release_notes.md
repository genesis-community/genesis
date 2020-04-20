# Improvements

* Add provided secrets handling for provided secrets
    
  Users can now manage provided secrets via the `*-secrets` commands.
  Provided secrets are those secrets that are not generated, but asked for
  in the `genesis new` process.  A `genesis remove-secrets --all` will
  remove them.  Copying an environment file to a new name and running
  `add-secrets` wouldn't populate these, and `check-secrets` wouldn't
  detect that they were missing.  That's no good!

  This is now fixed.

  * `check-secrets` now reports on their presence or absence
  * `add-secrets` and `rotate-secrets` now propts for values to be stored.
  * `remove-secrets` can now remove them

  Support for this functionality must be provided per kit, which requires
  a new top-level section in `kit.yml`: `provided`

  The structure is thus:

  ```
  provided:
    <"base"||feature-name>:
      <path>:
        [type: 'generic']
        keys:
          <key1>:
            [prompt: "informational discription of the source or purpose of the value"]
            [sensitive: true|false]
          [<key2>: ...]
      [<path2: ...]
    [<feature2>: ...]
  ```

  `prompt` if not given defaults to "Value for <path> <key>" so its best to
  provide one, but not fatal if you don't.

  `sensitive` defaults to true - this means the input will be hidden and
  confirmed with a second entry.  The user's input will be displayed if
  false.

* Better dev kit identity

  While a dev kit's name and version are stuck being dev and latest for
  legacy reasons, the dev kits id has been updated to reflect whatever
  name and version are found in the dev kit's kit.yml, with a "(dev)" flag
  tacked on the end.  If there is no name or version, the values of
  "unknown" and "in-development" are used as filler respectively.  This
  gives the user a better idea of what class of kit they are dealing with

  In order to use this value in hooks, $GENESIS_KIT_ID was made available.


* Add `bail` hook helper

  The internal `__bail` function was being used in hooks, and was being called
  `bail`, `_bail`, and `__bail`.  This formalizes the function as `bail` and
  approves it as an externally callable function.

* In interest of providing no more and no less information than is wanted,
  users can now set `$GENESIS_SHOW_BOSH_CMD` to a non-empty value to see the
  bosh command being called from any helper.  If this is deemed valuable, it
  will be extended to internal Genesis calls to BOSH as well (which are
  currently available via the -D/-T options as part of the debug/trace logs.)

* Improved `humanize_path` for some corner cases.

* Provide `humanize_path` as a helper function, and `$GENESIS_CALL` as a
  contained `<bin_path> -C <env_path>`, with the `-C` part only specified if
  needed.  This is for cut-and-pastable output from helpers like info,
  post-deploy, new, and addon routines.


# Bug Fixes
  
* Fixed filter bug when only paths were set.

* Version check for compile-kit to ensure this version of genesis is new
  enough to know how to compile a kit based on its `genesis_version_min`

* Fix path/bin issues with output

  * Fix ../mydir when getting humanize path of mydir when in mydir

  * Ensure executables always have a path component.
    * caveat: `humanize_bin` will drop the path component if the genesis
      binary is in the path and that is the binary being used.  If its the
      same name as the binary in the path, but was run from a different
      location, it keeps the location (ie you'll still get ./genesis if
      you called it that way and your in a path different than where your
      path genesis resides.)

  * Fixed conflated `$GENESIS_CALLER_DIR` and `$GENESIS_ROOT` usage.
    `$GENESIS_CALLER_DIR` is where genesis was called from, while
    `$GENESIS_ROOT` is where the environment files are found.  There were
    places this was incorrectly used, but would only cause a problem if `-C`
    was used.

* Bail if genesis.env isn't available for 2.7.x kits

  Kits that need v2.7.0 or greater of Genesis expect genesis.env to be set,
  not params.env.  Genesis now prints instructions on modifications needed to
  the environment .yml file to upgrade it to v2.7.x standards.
