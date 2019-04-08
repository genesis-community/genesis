# Feature: Better Integration of Safe

Since inception, Genesis has used your local `safe` target to determine what
vault is being used for the environment secrets.  If you only have a single
vault, this is fine.

However, some systems have multiple `safe` targets, and if you switch targets,
you may inadvertantly try to use a vault where your environment's targets are
not located, or worse, write, delete or overwrite secrets in the wrong
vault.

Furthermore, when repositories are used on more than one system, there is no
mechanism to convey what `safe` target needs to be used for that repository.

As of this release, you can now _register_ the correct vault with a deployment
repository, so that it always uses that vault, regardless of what the local
safe configuration has as the target.

To provide this behaviour, the following changes have been made:

- `genesis init` will ask for the user to select a vault from their safe
  targets list.  Alternatively, the correct safe target can be passed in via
  the --vault <target> option.

- `genesis new` no longer prompts for the vault when creating a new
  environment.

- When using a repository on a new system, if the registered vault is not
  known, or if there are multiple targets for the registered vault url,
  instructions will be provided instructing the user how to ensure the
  correct vault is available.

- To view and manage what vault is registered, the `genesis secrets-provider`
  command is used.  Without any arguments it displays the status of the
  registered vault.

```
$ genesis secrets-provider

Secrets provider for concourse deployment at /path/to/concourse-deployments:
         Type: Safe/Vault
          URL: http://127.0.0.1:8201 (insecure)
  Local Alias: toughened-coffer
       Status: ok
```

  With the -i|--interactive option, it will provide you with the same menu of
  valid safe targets that is presented when creating a new repository.  The
  selected target will then be registered to the repository.  Similarly, you
  can skip the menu and just specify the target name or full url as an
  argument.

  Finally, the -c|--clear option can be used to remove the registered safe,
  and put the deployment repository in Legacy mode.  While this is highly not
  recommended, if you **need** to use the old model of relying on the system-
  targetted safe, this can be used.

- The deployment repository configuration file `.genesis/config` is updated
  when `genesis secrets-provider` is called with an argument, and should not
  be edited by hand.  If there is a use-case for need to change this file
  manually, please open an issue.

- You must have at least one safe target with a unique url.  Normally, when
  initially deploying your first BOSH and Vault using genesis, you will stand
  up a local vault using `safe local -m`, then once the permanent Vault is in
  place, you will move your secrets to that Vault, and then update your
  registered secrets provider to point to the permanent Vault.

  More information on the design of and reason for this change can be found at
  https://trello.com/c/n4WhOC6p

**Note on Legacy Mode:**

All existing deployment repositories will run in Legacy mode until you use
`genesis secrets-provider` to register a vault with them.  While in Legacy
mode, the --vault option is valid for the `new`, `check-secrets`, `add-secrets`,
`rotate-secrets` and `secrets` subcommands to specify the safe target you want
to use.  The `new` subcommand will error if in Legacy mode and no `--vault`
option is provided.  All other command will use whatever the current vault
being used by the system for determining what vault to access.

**Note on valid safe targets:**

For a safe target to qualify for a registered vault, it must be the
only target that uses its url (this is due to how safe associates the
authentication token).  If you have multiple aliases for a given URL, remove
the duplicates, or if you need separate alais, use /etc/hosts to create unique
domain names that can be used as the host.

# Improvements

- Creating new environment will now warn you that existing secrets exist under
  the path set for the environment.  You will then be prompted to allow them
  to be deleted, or abort the creation of the environment.  This serves two
  purposes: It informs you in case you're accidentally about to overwrite
  existing secrets, and ensures there are no out-dated secrets left around in
  the case that you intended to over-write them.

- Reorganized environment file for future improvements.  Introduced new
  `genesis` top-level key to hold Genesis-level values, leaving `params` for
  kit-level values.  This moves `params.env` to `genesis.env`, and
  `params.vault` to `genesis.secrets_path`.  Existing kits that make use of
  `params.env` will continue to be supported (see below in Kit Authorship
  Improvments)

- `genesis download` is now `genesis fetch-kit`, and supports fetching new
  versions of local kits without having to specify any arguments.

- Cleaned up check and deployment interface to move towards a more standardized
  output.

- BOSH connection checks now first check if the host and port are reachable
  and listening rather than hanging while attempting to connect.

# Kit Authorship Improvements

- Improved validation when compiling kits.

  **Breaking Change:**  `genesis compile-kit` will now error if you are using
  legacy keywords in your kit.yml, such as `subkits` and `params`.  If you are
  maintaining a legacy kit and need to compile a new version, you may use the
  `-f` option to force the compilation, but be warned, this will bypass all
  the validation.  It is recommended instead to bring your kit up to the
  latest standards.

- Kit's `genesis_version_minimum` now means both _I need this version of
  Genesis_ (original intention) as well as _I fully support this verison of
  Genesis._ This means it can be used to deprecate or protect from deprecation
  features that are introduced in new versions of Genesis.

  For example, kits that don't specify a `genesis_version_minimum` of 2.6.13
  will not be expected to support the new `genesis.env` environment parameter,
  so Genesis will auto-populate the `params.env` for them, ensuring that any
  reliance on this does not break existing kits.

- Added `genesis_config_block` helper to print the `genesis:` block to standard
  output, so it can be redirected into the environment file being constructed
  by the `new` hook.  Use this instead of constructing it yourself to ensure
  future compatability without having to update your kit (further changes in
  this area are coming).

- Added `bullet` hooks helper to print green checkmark (`bullet "√"`) or red X
  (`bullet "x"`) in the same style that `genesis check-secrets` uses.

- `prompt_for line` helper can now accept an empty response by using the
  `--default ''` option.

- Improved `cloud_config_needs`:

  - Now uses same green checkmark/red x that check-secrets uses. _(uses
    `bullet` helper above)_

  - `static_ip` checks for both valid static ip ranges as well as sufficient
    counts.

- Added the following environment variables for use in hooks:

  - `SAFE_TARGET` - while not to be directly used, this ensures all safe calls
  will target the environments registered vault.

  - `GENESIS_TOPDIR` - for kits that alter $HOME, this will point back to the
    Genesis top directory (usually ~/.geese) even after $HOME is changed.

# Kit Deprecations

- Setting your kit to use `genesis_version_minimum` of 2.6.13 (or higher) have
  the following changes.

  - The root path, env name and vault prefix will no longer be provided as
    positional arguments to the `hooks/new` script.  Instead, the script must
    make use of the `GENESIS_ROOT`, `GENESIS_ENVIRONMENT`, and
    `GENESIS_SECRETS_PATH` environment variables respectively.

  - `params.env` will no longer be provided in the environment file stack.

# Bug Fixes

- `genesis deploy` checks presence of secrets prior to trying to build a
  manifest

- CA Certs specified in kits honour `valid_for` and `names` properties.  Names
  are added as Subject Alternative Names.

- Fixed error in minimum Genesis version specification in generated template
  and validation.

# Developer Support

- Improved output for trace and debug output so its move visually obvious.

- Added `dump_var` function that will dump the contents of one or more
  variables when in debug or trace mode (as per Data::Dumper)

- Added `dump_stack` function that will dump the stack trace when in debug or
  trace mode.

- Trace and debug output will always be in color, even if redirect.  To turn
  off color, use --no-color or set NOCOLOR environment variable to 'y'
