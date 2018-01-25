# Paradigm Shift:  Subkits -> Features

Kits provide custom behaviours for different needs by making use of subkits that provide extra configuration.  While this works for most things, there were a few drawbacks:

- Hard to handle combinatoric relationships where interactions of multiple subkits required further "artificial" subkits to provide the glue.
- Requiring the subkits to be partitioned into their own directory meant it would be near impossible to support upstream repos like cf-deployment and its use of ops files.
- Ordering subkits was tied to the order they were asked in the `new` wizard and the files were merged in alphabetical order.

To resolve this, we have added a support for `hooks/blueprint` in the kit.  It is the job of this blueprint script to lay out the selection and order of the files in the kit to be merged.  Unlike subkits, these files can be anywhere in the kit, and organized in any order.  The blueprint script must output a list of yaml files separated by spaces for a valid configuration, or exit with an error message and exit code of 1 if there is an issue assembling the yaml files.  This script is executed from the root path of the kit.

**Note:** *We have also renamed `subkit/subkits` to `feature/features` to differentiate from the more restrictive usage patter of subkits.  More on this below.*

The blueprint script can be any kind of executable, but if its a Bash script, it gains the following functions it can use:

- `want_feature <feature>` provids an exitcode of 0 if the feature was requested in the environment, non-zero otherwise.  Useful in the following structure: `if want_feature "my_feature"; then …`
- `valid_features <feature1> ... <featureN> ` provids an exitcode of 0 if the features that were requested by the environment fall within the set of specified features, non-zero otherwise. Useful to determine if any error handling is needed.
- `invalid_features <feature1> … <featureN>` outputs a list of requested features that are outsite the set of specified features.  Useful to provide error message of unsupported features.

- `validate_features <feature1> … <featureN>` combines the two functions above to make an one-stop generic error handler to validate the requested features for the environment.  Setting the `GENESIS_KIT_FEATURE_USAGE` environment variable will output its content before exiting the script with a exit code of 1.

The script (bash or otherwise) also gains access to the following environment variables:

- `GENESIS_KIT_NAME`: the version of the kit being processed - useful for output messages
- `GENESIS_KIT_VERSION`: the version of the kit being processed - useful for output messages
- `GENESIS_ENV_FILE`: the full path to the environment file being processed.
- `GENESIS_REQUESTED_FEATURES`: space separated list of features requested.

Most of these are primarily given for error message output.  While the `GENESIS_REQUESTED_FEATURE` variable is available for direct access, it is highly recommended to use the `want_feature` function instead as future development may cause changes to its internal structure.

### Note: Backwards Compatibility Considerations

- As stated above, anywhere that used to use entities named `subkit` or `subkits` should now use `feature` and `features` respectively.  Existant kits that still use `subkit` directories and yaml keys are still supported, but creating new kits using subkits are deprecated, and mixing paradigms will cause errors.

# New Features

- In anticipation for new features in Genesis that kits may rely on, Genesis now allows kits to specify the minimum version of Genesis that they can be used on.  Specify `genesis_version_min` to a semver value in your kit.yml to make use of this.  By default, creating a new kit with `genesis create-kit`
  will set this to your current version of Genesis.
- **BETA FEATURE:** Instead of relying on the `genesis new` wizard to prompt the user to build the environment yaml file, advanced kit authors can provide a `hooks/new` script that will be called instead.  It is the complete responsibility of this script to prompt the user for the features provided and the parameters needed by the kit and write the output to the requrested environment yaml.  It is run from the root path of the kit, and is provided with the environment repo path and the environment yaml file.

# Improvements

- In `genesis ci`, you can defer the setup of the Vault AppRole for Concourse to be done manually after.
- Can now create Concourse pipelines for a single environment.
- Show all yaml files that will be merged, both those from the kit and those in the environment using the new `—include-kit` option to `genesis yamls`.
- Added support for new BOSH Genesis Kit that uses UAA when creating Concourse Pipelines for Genesis deployments.

# Bug Fixes

- `genesis repipe` no longer fails when using locker without keeping stemcells up-to-date.
- Gracefully handles not finding a given BOSH alias in your `~/.bosh/config` when using the `genesis ci` wizard.
