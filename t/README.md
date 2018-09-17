While Genesis was designed to be distributed with no Perl dependencies besides
a version of Perl that was released within the last decade, testing it does
require some CPAN modules and further configurations.

Furthermore, testing Genesis also requires the same system dependencies on
spruce, safe, vault, jq, etc that would be required to run in in production:
namely the same things that the jumpbox boshrelease or script uses.

In order to configure for testing do the following:

On OSX:
  * `brew tap starkandwayne/cf`
  * `brew install spruce safe`
  * `brew install cloudfoundry/tap/bosh-cli` 
    # alternatively, add the tap and install bosh-cli
  * `brew install jq`
  * install install from https://www.vaultproject.io/downloads.html

On Linux:
  * The most straight-forward method of installing under linux is to install
    the jumpbox script:

  ```
  sudo curl -o /usr/local/bin/jumpbox \
  https://raw.githubusercontent.com/starkandwayne/jumpbox/master/bin/jumpbox

  sudo chmod 0755 /usr/local/bin/jumpbox

  jumpbox system

  jumpbox user # optional
  ```

  You may also need to install expect with your OS package manager if its not
  present by default.  For example, on Ubuntu you would issue:
  `sudo apt install expect`

---

CPAN Modules:

You will need the following cpan modules to run tests:

Expect
Test::Exception
Test::Deep
Test::Differences
Test::Output

