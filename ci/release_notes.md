# Major Update Release v2.7.0
* Kit providers
* Improved secrets management
* Improved kit authorship support
* Improved debugging
* Remove support for genesis v1 repositories

----

# New Feature: Kit Providers

Until now, you could only use the kits that were provided by the `genesis_community` organization on GitHub, or by creating dev kits yourself. This release allows you to specify any GitHub org as a kit provider.

## Creating a new repo with an alternative kit provider:

```
genesis init --kit-provider        github \
             --kit-provider-org    myproject \
             --kit-provider-domain github.mycorp.com \
             --kit-provider-tls    skip\
             --kit-provider-name   "Our Custom Kit Provider" \
             --kit                 my-awesome-kit
```

There are further options, which can be shown using --help.

## Showing current kit provider:

```
genesis kit-provider

Collecting information on current kit provider for concourse deployment at ./work/concourse-deployments ...done.

         Type: github

         Name: Our Custom Kit Provider
       Domain: github.mycorp.com
          Org: myproject
      Use TLS: skip

       Status: ok

         Kits: my-awesome-kit
               another-kit

```

## Changing kit provider on existing repo:

```
genesis kit-provider --default
genesis kit-provider --kit-provider genesis-community
```

Either of these will set the kit provider to the default Genesis Community kit provider.

```
genesis kit-provider --kit-provider github [... rest of github-specific options]
```

You can also change it to another github org as its kit provider using the above.

Note:  You can't just change one option to have it update just that property -- you must set all the provider-specific options to update the provider information.  Refer to the help output (-h|--help) for details on what options are expected.

----

# Secrets Management Refactor

This release completely overhauled the `add-secrets`, `rotate-secrets` and `check-secrets`, and added `remove-secrets`.  This incorporates the following changes:

- Better real-time feedback on creation, recreation, checking and removal of secrets - each secret being processed is reported on a progress line with a completeness indicator.  Any aberrations are also reported.  With the `-v|--verbose` option, each secret along with its result is printed as its processed instead of a single progress line.

- Validation of secrets beyond simply presence is now supported with `--validate` option on `check-secrets`, with validation against the secrets specifications in the kit as well as its internal integrity, expiration, signature chain, etc...

- X509 secrets can be renewed instead of recreated using the `rotate-secrets --renew` option.  This keeps the same keys, ensuring the preservation of the signature chain integrity, but renews the expiration period.

- New `-F|--filter <str>` option to the `*-secrets` commands allows you to select a subset of secrets to act upon, either a specific secret path, or a regular expression that matches secrets paths.  This allows actions to be applied surgically instead of en-masse.

- New `remove-secrets` command allows secrets to be removed en-masse, or by using the above filter option, selectively.

- `rotate-secrets` no longer supports `--force` option to rotate fixed secrets.  You now use `remove-secrets` to remove any fixed secret and then use `add-secrets` to regenerate a new value.  Likewise, CA secrets are no longer protected as if they were marked fixed, but can now be explicitly marked fixed in the kit.

- `remove-secrets` and `rotate-secrets` support a '-X|--failed' option that will apply to only secrets not in good standing (missing, expired, or otherwise failed).

-  `remove-secrets` only remove generated secrets specified by the kit's kit.yml file, unless the `--all` option is specified, in which case all secrets under the environment's secret base path will be removed.

- Significantly improved the speed of `check-secrets`

As always, full help for any command can be found by using the `-h` option.

### Customize secrets locations

Furthermore, we've enhanced the ability to customize where secrets are stored in your vault.  In addition to `secrets_path` (aka `vault`, `vault_prefix` or `vault_path` in previous versions) which specified where under `secret/` the secrets for the environment would be stored, you can now also specify where the secrets and exodus mount points are.

As these values are needed during an environment's creation, the `--secrets-mount` and `--exodus-mount` options were added to `genesis new`, along with finally adding support for `--secrets-path` and `--bosh-env` options to provide those eponymous parameters.  For existing environments, you can add these under the `genesis:` top-level key (exchange hyphens with underscores for the property name)

### Add common root CA certificate

In effort to provide a common root CA that can be distributed for making all secrets created by the deployment trusted, you can now specify the full vault path to a root certificate that all otherwise self-signed certificates generated by the kit will use as their CA.  This can be done as the `--root_ca_path` argument to `genesis new` or by specifying `genesis.root_ca_path` in an existing environment YAML file.

----

# Integrated Credhub Support (Still under Development in RC4)

If using a deployment that provides Credhub, such as the BOSH Genesis Kit, hook scripts for other kits have access to a `credhub` function via its Exodus data.  This allows kits that use Credhub instead of Vault for secrets management to access their secrets directly during the creation and deployment of the environment, as well as in helpful addons via the `genesis do` command.

By default, this will expect the bosh environment for the deployment, but you can specify the exact environment via `genesis.credhub_env`

----

# Improved Kit Authoring Support

### Secrets Management Improvements

Improved Functionality for X509 Certificates:

- More flexible signing chain specification.  By default (and prevously only method), a certificate named 'ca' will be the signing CA certificate for all sibling certificates for the given secrets path under `certificates:` key in `kit.yml`.   Alternatively, you can specify an alternatively named certificate as the default ca for the cohorts using the `is_ca` boolean property.  Finally, you can explicitly state another path as the signing CA certificate (relative to environment's base secrets path) by using the `signed-by:` property.  This allows multiple levels of CA signature chains.

- As mentioned above, the user can specify a root CA certificate to be used to sign all base CAs for the kit that would otherwise be self-signed.  If you want to have an explicitly self-signed CA certificate even with the presence of a root CA, you can ensure a CA is self-signed by providing its secrets path as its `signed-by:` property.

- Can now specify `usage:` property per certificate, which takes a list of key usage and extended key usage values.  Supported usages are: digital_signature, non_repudiation, content_commitment, key_encipherment, data_encipherment ,key_agreement, key_cert_sign, crl_sign, encipher_only, decipher_only, client_auth, server_auth, code_signing, email_protection, and timestamping.

Parameter values in Secrets Specifications:

- Kits can specify default values for parameter references in the form of `${param.key||default value}`

- Kits can now specify parameter values in the secrets properties that will be dereferenced from not only the environment, but also from the kits manifests, albeit unevaluated.  This works best for simple defaults for parameters that can be overwritten in the environment file.

The above X509 and parameter dereferencing improvements fix #362

### Check secrets integrity on `compile-kit`

When the kit is compiled with `genesis compile-kit`, it now validates all the secrets specifications in `kit.yml`, to ensure that the end user does not get stuck with a kit that cannot generate valid secrets.

----

# Improved Debugging Features

### Traceable BASH hook scripts

If the hook script is a BASH script, you can now get the `set -x` trace turned on to see each command in the script executed and its result.  Just use `-T` option, or set `GENESIS_TRACE` environment variable to `y`.

### Timestamps

When debugging time-sensitive issues, it is handy to see when everything is happening.  To get timestamps in the debug log, add a second `-D` argument.  For timestamps while tracing, you still need two or more `-D`, so `-TDD` is required to get tracing and timestamps together.

----

# Removed Feature: Genesis v1 Support

This is a breaking change for anyone who still uses Genesis v1 repositories.

When Genesis v2 came out, it included full backwards compatibility with Genesis v1 repositories, which were very different in structure and behaviour.  As v1 was a Bash script, and v2 was built in Perl, this was accomplished by simply embedding the Bash script in the Perl (as data up to v2.4.x, and as a separate file after that) and passing control to that script when a v1 repo was detected.

However, with BOSH no longer supporting v1-style manifests, it seemed a good time to remove this obsolete functionality and shrink down the package.  If you still need this, any version from v2.5.x or v2.6.x will work for you, as the v1 embedded in those versions haven't changed.

----

# Other Minor Improvements

- More human-readable output of paths.
- You can combine the -C option with the actual environment YAML file, making tab completion easier.  For example, instead of `genesis -C ../another/deployment do myenv.yml -- thing` you can specify it as `genesis -C ../another/deployment/myenv.yml do -- thing`.

# Bug Fixes
- No longer allows mixed usage of `kit.features` and deprecated `kit.subkits`.  Occurrences of this were rare, but caused anything defined under `subkits` to be ignored without warning.  This now fails fast with an instructive error message.
- `cloud_config_needs` will only check for a specific resource once, regardless of how many times the kit request a check for it. - Fixes #339
- Fixed output color errors and missing newlines. (Fixes #360)
- Instead of not allowing Genesis to run if you have a bad $LANG env var set, Genesis will warn you that you may experience garbled output on non-ascii characters.
- Get the highest kit version when no version specified, not the chronologically "latest" (Fixes #366)
