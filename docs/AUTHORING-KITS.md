Authoring Genesis Kits
======================

<style type="text/css">
.ni { color: firebrick; font-weight: bold; }
</style>

This document serves as both and introduction to and a reference
for authoring Genesis Kits.  This document takes precedence over
any other document that purports to document the internal
mechanics of a Genesis Kit.

Kit Overview
------------

The point of a Genesis Kit is to roll up all that beautiful
knowledge that we have about how to deploy things, and make it
easier to use.  To that end, the following holds:

  1. Kit Authors are not stupid
  2. User-facing parameters are set as single-level keys under
     a top-level `params` key
  3. What can go in Vault, does
  4. There is more than one way to do it

### Kit Authors Are Not Stupid

The expectation is that people writing Genesis Kits do not need to
be coddled.  They can write BASH scripts, and they own their Kits
when they break.  To that end, Genesis v2 provides powerful and
sharp tools for authoring kits.  Use them with care.

### User-Facing Parameters

Configurable bits of a deployment should be set as single-level
keys under `params`.  That means don't do this:

```

properties:                       # don't do this...
  cf:
    admin_username: (( param  "What is your CF admin username?" ))
```

and don't do this:

```
meta:                             # or even this...
  cf:
    creds:
      admin:
        username: (( param "What is your CF admin username?" ))

properties:
  cf:
    admin_username: (( grab meta.cf.creds.admin.username ))
```

Instead, do this:

```
params:
  cf_admin_username: (( param "What is your CF admin username?" ))

properties:
  cf:
    admin_username: (( grab params.cf_admin_username ))
```

Everything an operator could _reasonably_ expect to be able to
configure ought to be configurable via the `params` stanza.  Sane
defaults should also be supplied, where it makes sense.

### Features - Options For Your Kits

There is more than one way to deploy things, based on preference,
environment, IaaS, and purpose.  For example, when deploying Cloud
Foundry, you can use a local blobstore, or put your application
droplets in S3.  A CF kit should enable both.  This is where
"features" come into play.

A "feature" is a self-contained, but dependent set of additions to
a BOSH manifest, in the form of YAML files and credential
definitions.  A feature is _activated_ by listing it in the
environments `kit.features` list.

The CF Kit, for example, may have define  feature for each type of
blobstore backing store (IaaS-specific, S3, webdav, etc.).
Someone wishing to store their droplets in Azure's Blob Store
offering, could then set:

```
kit:
  name: cf
  features:
    - azure-blobstore
```

When activated, the `azure-blobstore` feature would bring in new
YAML files that change the blobstore configuration, and rely on
credentials for Azure, stored in the Vault.

The Kit Development Environment
-------------------------------

Opaque tarballs are great for operational use cases, but while
assembling and refining a kit, they impose too much overhead.  The
write-archive-test-repeat feedback cycle is an onerous one.

To fix that, we make Genesis use `dev/` (outside of the
`.genesis/` directory) as the already-unpacked kit tarball.  This
allows kit authors to write-test-repeat, and only generate a
tarball archive when the kit is complete.

To safeguard operational use cases, and prevent confusion for kit
authors, Genesis v2 is explicit about when it does and
doesn't use `dev/`.  These are the ground rules:

  1. If `kit.name` is set to "dev", **only** Genesis uses the
     `dev/` kit directory, and complains if it is absent.
  2. If `kit.name` is not set to "dev", and a `dev/` kit
     directory is present, issue a loud and obnoxious warning
     message, but proceed with the specified kit version.

In dev-mode, the `kit.version` parameter is ignored.

Structure of a Kit
------------------

Genesis Kits are distributed as gzipped tar archives.

Inside each archive is the following structure:

```
kit-name-x.y.z/
  kit.yml
  prereqs

  hooks/
    addon
    blueprint
    check
    info
    new

  manifests/
    base.yml

    addons/
      small-footprint.yml
      oauth.yml
```

### `kit.yml` - Kit Metadata

The `kit.yml` defines all of the metadata about the kit itself,
and will drive the behavior of the Genesis utility wherever
kit-specific decisions need to be made.  This includes:

  1. Kit Identification (name, author, etc.)
  2. Environment Provisioning
  3. Subkit Selection
  4. Credentials Generation
  5. Deployment Manifest Generation

There may be other responsibilities added over time.

`kit.yml` is (unsurprisingly) a YAML file.  It has the following
structure:

```
name:     Name of the Kit
author:   Who Wrote The Kit <author@email.com>
docs:     https://example.com/kit/docs
code:     https://github.com/some-org/kit-genesis-kit

description: |
  A free-form description of the kit, what it does, how to use
  it, etc...

# The `certificates` top-level key describes what SSL/TLS certificates
# and custom CAs should be generated automatically for the deployment.
# Data will be stored in vault. It is used *purely* for auto-generating
# CAs and certs signed by them, and rotating them fairly often.
# Most likely these are certificates internal to the deployment itself.
# For client-facing SSL certificates provided by the user + signed by a
# trusted CA, use the `params` section to store the data in Vault.
certificates: ...

# The `credentials` top-level key describes what credentials and
# secret information that genesis will auto-generate, and periodically
# rotate in order to deploy a new environment.
credentials: ...
```

All other top-level keys are reserved for future use.

Note that the `params:` and `subkits:` top-level keys have been
deprecated, and should not be used.

#### Defining Certificates in `kit.yml`

To make life easier for generating/rotating internal certificates for deployments,
Genesis provides the `certificates` top level key. These certs are auto-generated,
and have their own Certificate Authority. As such, they won't be considered valid
by web browsers, and shouldn't be used to generate certificates that end-users
will interact with. However, for all of the internal components of Cloud Foundry
which use SSL to authenticate services, it's a great fit.

The `certificates` section looks something like this:

```
certificates:
  base:
    consul/certs:
      ca: { valid_for: 1y }
      server:
        valid_for: 1y
        names:     [ server.dc1.cf.internal ]
      agent:
        valid_for: 1y
        names:     [ consul_agent ]

    uaa/certs:
      ca: { valid_for: 1y }
      server:
        valid_for: 1y
        names:
        - "uaa.service.cf.internal"
        - "*.uaa.service.cf.internal"
        - "*.uaa.system.${params.base_domain}"
        - "uaa.system.${params.base_domain}"
        - "login.system.${params.base_domain}"
        - "*.login.system.${params.base_domain}"
        - 10.5.40.2
```

The above config will tell Genesis to create two 'zones' of certificate
data - one for Consul, and one for the UAA. Each of these 'zones' has
its own CA, meaning that the certificates in a zone cannot be validated
by a CA of another zone. This is very useful for partitioning access
when using client-side certificates as an authentication mechanism.

For Consul, Genesis will create a CA, and sign two certificates with it
 - one for a server, and one for an agent. The server cert will be valid
for only the `server.cd.cf.internal` domain. The client cert will be valid
only for the `consul_agent` domain. However, since it's a client certificate,
that's fine, as the domain isn't usually checked. All certs and the CA will
be valid for one year after they are generated.

It will also create a CA for the UAA, and a single server certificate.
The server cert will be valid for a number of names, including wildcard
domains, and if it is accessed directly by the IP `10.5.40.2`. Another
interesting note is that you can interpolate param values from the deployment
in these names, if needed (e.g. if my `params.base_domain` was `bosh-lite.com`,
the UAA cert would be valid for `uaa.system.bosh-lite.com`. **NOTE:** the interpolation
only allows you to read data from end-user params (environment yaml data).
This means, that if you request the user to fill in `params.base_domain`, but
wish to use a value that the manifest will concat with the base domain, you
must manually do that concat in your `kit.yml`, hence `*.login.system.${params.base_domain}`
instead of `*.login.${params.system_domain}`.

These certificates will all be stored in Vault. The Consul certs will
be located in `secrets/<vault_prefix>/consul/certs/<ca|server|agent>`,
and the UAA certs will be located in `secrets/<vault_prefix>/uaa/<ca|uaa>`.
The `certificate` and `key` attributes of those paths are used to store the certificate,
and private key, respectively.

To access the certs in your kit's YAML, you can use the `(( vault ))` spruce
operator, as you would any Vault secret:

```
params:
  consul_server_cert: (( vault "secret/" params.vault "/consul/certs/server:certficate" ))
```

Data in `certificates` is **NOT CURRENTLY** rotated automatically, but will be
in the future.

#### Defining Credentials in `kit.yml`

Credentials should go in Vault.  Vault is a requisite component of
Genesis v2-style deployments.  Kits should rely on that, and
neither encourage nor allow the placement of secrets directly in
the YAML files.

A kit should define a `credentials` subsection of the `kit.yml`
metadata file that identifies what credentials are required, which
ones can be generated, and how.  It should also identify which of
the generated credentials can be automatically re-generated on a
credentials rotation schedule.

It looks like this:

```
credentials:
  base:
    # randomize (and rotate) database credentials
    internal/database:
      username: random 32
      password: random 32

    # generate (and rotate) an ephemeral RSA 4096-bit signing key
    internal/signing_key: rsa 4096

    # generate (but do not rotate) an SSH RSA 2048-bit key
    external/ssh: ssh 2048 fixed

  # below credentials will only be generated when the nats subkit is active
  nats:
    password: random 64

```

In this example, without using the `nats` subkit, we'll end up
with a Vault that looks like this:

```
.
└── secret/my/new/environ/type/
    ├── external/
    │   └── ssh/
    │       ├── private
    │       └── public
    └── internal/
        ├── database/
        │   ├── password
        │   └── username
        └── signing_key
            ├── public
            └── private
```

Activating the `nats` subkit, either during `genesis new`, or
afterwards via manual file edits, we pick up the
`secret/my/new/environ/type/nats:password` tree in Vault.

This allow you to define conditional credentials that are only
generated when the associated subkit is actually in use.

Time for an example.  If you want your kit to generate a random,
40-character password for the admin account, you can put this in
your `kit.yml`:

```
credentials:
  base:
    users/admin:
      password: gen 40
```

Then, from the template files in the kit, you can use it like
this:

```
---
properties:
  admin:
    username: admin
    password: (( vault "secret/" params.vault "users/admin:password" ))
```

Whenever an operator provisions a new environment, or rotates
credentials on an existing environment, Genesis will make sure
they get a new admin password, stored in the Vault,
transparently.

Sometimes you don't want to automatically rotate credentials.
Consider the case where you are generating SSH RSA public/private
keys, where the public key will be used on other deployments.  You
could put this in your `kit.yml`:

```
---
credentials:
  base:
    system/remote/auth: ssh 2048 fixed
```

The `ssh` operation generates keypairs, putting the private key in
the `private` attribute of the path, and the public key in the
`public` attribute.  (This is why we didn't specify the attributes
as sub-keys in the YAML).  The `2048` is an argument to the `ssh`
operation, that forces it into 2048-bit mode (you could also have
specified `4096`).

The final argument, `fixed`, is not seen by the `ssh` operation.
Instead, Genesis pulls that one out and uses it for its own
purpose &mdash; to protect this secret from automatic rotation.

The `fixed` keyword is opt-in for two very simple reasons: (1) most
credentials in BOSH deployments are internal, and (2) automatic
rotation of such credentials is a highly sought-after capability.

### `hooks/*` - Genesis Lifecycle Hooks

The `hooks` directory provides (optional) executable scripts for
specific Genesis lifecycle hooks.  Genesis will ignore hooks it
does not yet know about.

In practice, hooks are written in Bash, which allows them to take
advantage of bash functions exported by Genesis.

The following hooks are currently recognized by Genesis:

- `new` - Interactively guide the user through the process of
  configuring a new deployment environment.

- `blueprint` - Convert a set of feature flags into the correct
  set of YAML files to be merged, in the correct order.

- `check` - Validate an environment, before deployment.
  Common uses for this hook are to validate that the selected VM
  types, networks, and disk types exist in the live BOSH cloud
  config, and to ensure that generated certificates have the
  correct subject alternate names, per environment configuration.

- `prereqs` - Validates the jumpbox environment, to ensure that
  required tools are installed.  This hook is called before most
  Genesis commands, including `new`, `manifest`, and `deploy`.

- `secrets` - Manage Vault contents, in addition to the facilities
  provided by `kit.yml`.  This hook is fired after each of the
  `*-secrets` Genesis commands.

- `info` - Prints out information relevant to a single deployment.
  This includes things like URLs, username, passwords, etc.

- `addon` - Provides small tasks that can be run by operators,
  against a deployed environment.  This includes things like
  visiting deployed web user interfaces, logging into APIs, etc.

- `post-deploy` - Runs after a deployment attempts, whether
  successful or not.  This is useful for giving the operator hints
  about their next steps, including what addons to try.

Credentials Operator Reference
------------------------------

## ssh [bits]

Generates an SSH RSA public/private keypair, putting the private
key into the `private` attribute, and the public key into
`public`.  The optional `bits` argument allows you to control the
RSA key strength, and must be one of either 1024 (not
recommended), 2048 or 4096.  `bits` defaults to 2048.

Definition:

```
credentials:
  base:
    remote/authkey: ssh 4096
```

Usage:

```
properties:
  remote_agent_key:
    private: (( vault "secret/" params.vault "remote/authkey:private" ))
    public:  (( vault "secret/" params.vault "remote/authkey:public" ))
```

## rsa [bits]

Generates an RSA public/private keypair, putting the private key
into the `private` attribute, and the public key into `public`.
The optional `bits` argument allows you to control the RSA key
strength, and must be one of either 1024 (not recommended), 2048
or 4096.  `bits` defaults to 2048.

Definition:

```
credentials:
  base:
    signing/key: rsa 2048
```

Usage:

```
properties:
  signing:
    private_key: (( vault "secret/" params.vault "signing/key:private" ))
    public_key:  (( vault "secret/" params.vault "signing/key:public" ))
```

## random [length]

Generate a random password, `length` characters long (default 32),
and stores it in the named attribute under the given path.

Definition:

```
credentials:
  base:
    account/passwords:
      admin: random 64
```

Usage:

```
properties:
  users:
    - name: admin
      password: (( vault "secret/" params.vault "account/passswords:admin" ))
```

#### Special Formatting

Sometimes you might want to randomly generate a password, but then
format it in a way that deployments are expecting it, commonly a
hashed copy of the password. You'll still want the original for
the operator to reference, but you'll also want to perhaps
crypt-sha512 hash it, for the boshrelease to use properly. Good
news! That can be done relatively easily:

```
credentials:
  base:
    users/root:
      password: random 64 fmt crypt-sha512
```

You can specify any format options that are supported by `safe`,
such as `crypt-sha512`, `crypt-sha256`, `crypt-md5`, `base64`, or
`bcrypt`. The formatted values are stored in vault along side the
original, with the name of the format appended to the name of the
original key, e.g. `secrets/mything:supersecret` would have a
`secrets/mything:supersecret-bcrypt` if formatted with `bcrypt`.

You can then reference the values as follows:

```
raw_password: (( vault "secret/" params.vault "users/root:password" ))
hashed_password: (( vault "secret/" params.vault "users/root:password-crypt-sha512" ))
```

You can even specify where you want the formatted password to go:

```
credentials:
  base:
    users/root:
      password: random 64 fmt crypt-sha512 at hashed_passwd
```

You would then reference these values as follows:

```
raw_password: (( vault "secret/" params.vault "users/root:password" ))
hashed_password: (( vault "secret/" params.vault "users/root:hashed_passwd" ))
```

#### Limiting randomly generated characters

On occasion, you may need to limit, or expand the characterset
used to generate random passwords.  By default, genesis uses
`safe`'s default characterset (`a-zA-Z0-9`). This is also fairly
easy:

```
credentials:
  base:
    restricted:
      characters: random 64 allowed-chars a-c
```

This will generate a secret with 64 characters randomly chosen
from the set of `a`, `b`, and `c`.

If you use this in conjunction with the `fmt` keyword, ensure that
`allowed-chars` comes after the end of the `fmt` definition.

## dhparam [bits]

`dhparam` generates pem-encoded DH param data. The data is
stored in the `dhparam-pem` key in the specified path. This
operator is mainly useful for things like OpenVPN which require
custom generated DH params for the server.

Note: This also can be used as the `dhparams` operator (the trailing
`s` is optional).

Definition:

```
credentials:
  base:
    vpn/dh_param: dhparam 2048
```

Usage:

```
properties:
  openvpn:
    dh_pem: (( vault "secret/" params.vault "/vpn/dh_param:dhparam-pem" ))
```
