# New Feature

* Added `genesis ci` to generate CI pipeline configuration from a Genesis
  repository.

  * No longer have to hand-generate the ci.yml file.

  * Prompts for needed configuration information, using smart defaults to
    minimize typing and cognitive strains by analysing the repository files.

# Improvements

* Expanded kit param question capabilities

  * Added `choice` and `multi-choice` param question types, for when kits need
    the user to select from a specific list of valid options.

  * Added `url`, `port`, integer range (`n-m`), negative regex and list
    matching validation for string and list param questions.

  * Improved error checking for valid min and max counts with list questions.

* Improved error messages for kit authors when validating kits.

# Bug Fixes

  * Cleaned up kit param question interface in `genesis new` for improved
    consistancy.
  
  * Fixed typos.
