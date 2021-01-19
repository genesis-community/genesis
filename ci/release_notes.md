# Bug Fixes

* Fix credhub warning about double-login

  Genesis uses environment variables to authenticate to Credhub, but if it was
  previously authenticated via username/password, Credhub now prints a
  warning.  This warning was being captured along with the value being
  retrieved from credhub and corrupting the values stored in exodus.

* Reauth to vault right after deploy completes

  While re-authenticating to vault before writing exodus data (added in
  v2.7.22) solved some problems, there are a multitude of activities that
  happen between the bosh deploy command completing and the writing of
  exodus data that MAY try to interact with the Vault.  To resolve this,
  re-authentication is performed immediately after the bosh deploy command
  is complete.
