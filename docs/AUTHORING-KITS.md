Authoring Genesis Kits
======================

<style type="text/css">
.ni { color: firebrick; font-weight: bold; }
</style>

This document serves as both and introduction to and a reference
for authoring Genesis Kits.  This document takes precedence over
any other document that purports to document the internal
mechanics of a Genesis Kit.

> For right now, we are focused on the reference-side of this
> document.  Once we are 90% certain that the formats and
> everything won't change out from under us &mdash; Genesis v2 is
> a fast-moving target &mdash; we'll focus on the _Getting
> Started_ part of the document.  -ed.

Table of Contents
-----------------

### Getting Started

  - Coming soon...

### Reference

  - [Overview](#kit-overview)
  - [The Kit Development Environment](#the-kit-development-environment)
  - [Structure of a Kit](#structure-of-a-kit)
    - [The `kit.yml` Metadata File](#kityml---kit-metadata)
      - [Defining Subkits](#defining-subkits-in-kityml)
        - [Using the subkit hook](#using-the-subkit-hook)
      - [Defining Parameters](#defining-parameters-in-kityml)
        - [Using the params hook](#using-the-params-hook)
      - [Defining Credentials](#defining-credentials-in-kityml)
      - [Defining Certificates](#defining-certificates-in-kityml)
    - [The `prereqs` Prerequisite Check Script](#prereqs---prerequisite-check-script)
    - [The `setup` Environment Provisioning Script](#setup---environment-provisioning-script)
    - [Base Templates](#base---shared-deployment-templates)
    - [Subkit Templates](#subkits---subkits)
  - [Credentials Operators](#credentials-operator-reference)




Reference
=========

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

### Subkits - Options For Your Kits

There is more than one way to deploy things, based on preference,
environment, IaaS, and purpose.  For example, when deploying
BOSH, you can use a local blobstore, or put your blobs in S3.  A
BOSH director kit should enable both.  This is where "subkits"
come into play.

A "subkit" (better names welcome) is a distinct set of
globally-applied YAML files, that are triggered based off of some
setting in the environment-level deployment templates.

For example, a Concourse kit may have a subkit for worker-only
deployments, that is activated by specifying `workers-only` in the
`kit.subkits` section of the environment's yaml file, like so:

```
---
kit:
  name: concourse
  version: 0.0.1
  subkits:
  - workers-only
```

The constituent files of the worker-only subkit would be tasked with removing
instance groups that are irrelevant to worker-only deployments,
like the web and db instances.

The Kit Development Environment
-------------------------------

Opaque tarballs are great for operational use cases, but while
assembling and refining a kit, they impose too much overhead.  The
write-archive-test-repeat feedback cycle is an onerous one.

To fix that, we should make Genesis use `dev/` (outside of the
`.genesis/` directory) as the already-unpacked kit tarball.  This
allows kit authors to write-test-repeat, and only generate a
tarball archive when the kit is complete.

To safeguard operational use cases, and prevent confusion for kit
authors, Genesis v2 needs to be explicit about when it does and
doesn't use `dev/`.  These are the ground rules:

  1. If `kit.name` is set to "dev", **only** use the `dev/`
     kit directory, and complain if it is absent.
  2. If `kit.name` is not set to "dev", and a `dev/` kit
     directory is present, issue a loud and obnoxious warning
     message, but proceed with the specified kit version.

In dev-mode, the `kit.version` parameter is *not* used, but this
is not expected to cause any confusion.

Structure of a Kit
------------------

Genesis Kits are distributed as gzipped tar archives.

Inside each archive is the following structure:

```
kit-name-x.y.z/
  kit.yml
  prereqs

  hooks/
    subkit
    params

  base/
    params.yml
    jobs.yml
    other.yml

  subkits/
    a/
      params.yml
      x.yml
    b/
      params.yml
      z.yml
```

| File                  | Required | Notes                                                                                        |
| --------------------- | -------- | -------------------------------------------------------------------------------------------- |
| kit.yml               | yes      | Defines all properties of the kit itself.                                                    |
| prereqs               | yes      | Checks for prerequisite commands / features.                                                 |
| hooks/subkit          | no       | Allows kit author to customize subkit selection                                              |
| hooks/params          | no       | Allows kit author to customize initial parameters after prompting users for param values     |
| base/                 | yes      | Houses always-on base deployment templates.                                                  |
| base/params.yml       | yes      | Contains defaults/param operators for params, to safeguard against missing kit.yml questions |
| base/\*.yml           | yes      | You must have at least one YAML template file.                                               |
| subkits/              | no       | Houses subkits (if there are any).                                                           |
| subkits/\*            | no       | One sub-directory per subkit.                                                                |
| subkits/\*/params.yml | yes      | Contains defaults/param operators for params, to safeguard against missing kit.yml questions |
| subkits/\*/\*.yml     | yes      | Each subkit must have at least one template.                                                 |

Each of these will be dealt with in the following sections.

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
homepage: https://example.com/kit/home/page
github:   https://github.com/some-org/kit-genesis-kit

description: |
  A free-form description of the kit, what it does, how to use
  it, etc...

# The `subkits` top-level key identifies the available subkits
# how they are activated when `genesis new` is called, and how
# to validate them during `genesis manifest`
#
subkits: ...

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

# The `params` top-level key describes how the initial environment
# YAML file will look after a user runs `genesis new <environment name>`.
params: ...
```

All other top-level keys are reserved for future use.

#### Defining Subkits in `kit.yml`

Genesis needs to know certain things about the available subkits,
so that it can:

  1. Prompt the user to select which subkits they want
  2. Validate that an environment doesn't have conflicting subkits
     activated (i.e. from manual changes)
  3. Determine what additional credentials need to be obtained.

To that end, the top-level `subkits` key lets you define how to
ask for subkit selections.  It looks like this:

```
subkits:
  # you have to choose an auth subkit
  - prompt:  How would you like to perform authentication?
    type:    authentication method
    choices:
      - subkit:  gh-oauth
        label:   Github OAuth2 (Organization-based Authentication)

      - subkit:  cf-uaa
        label:   Cloud Foundry UAA

      - subkit:  basic
        label:   HTTP Basic Auth over TLS/SSL
        default: yes

  # you can load toolbelt, or not.
  - prompt:  Would you like to load the most excellent Toolbelt add-on?
    subkit:  toolbelt
    default: yes

  # you may choose a backup solution.
  - prompt: How would you like to perform backups of this deployment?
    type:   backup strategy
    choices:
      - subkit:  shield
        label:   Using the super awesome SHIELD backup system
        default: yes

      - subkit:  s3-backups
        label:   Simple S3-bucket Backups

      - subkit:  ~
        label:   I do not wish to perform backups
```

`subkits` is a list of choices that the user will be asked to
make when they provision a new environment via `genesis new`.

The simplest type of prompt is the "do you want this subkit".  It
looks like this:

```
  - prompt:  Do you want extra awesomeness in your deployment?
    subkit:  more-awesomeness
    default: yes
```

The user interaction (during `genesis new`) looks like this:

```
Generating new environment *my-new-environ*...
Using the *kit-name/1.0.4* kit...

Do you want extra awesomeness in your deployment?
[Y/n]: y

Enabling the *more-awesomeness* subkit...

Done.  Your new environment has been saved in *my-new-environ.yml*
```

The user can enter any of the following answers to the prompt:

| Answer       | Meaning                       |
| ------------ | ----------------------------- |
| Y / y / yes  | activate the subkit           |
| N / n / no   | do not activate the subkit    |
|              | accept default (if specified) |

Answers are case-insensitive.

By default, there is no default, and the user will be badgered
until they answer the question.  A default can be specified as
`true` for "yes", and `false` for "no".  Invalid responses will
cause Genesis to repeat the prompt and ask again, until a Ctrl-C
terminates the `genesis new` run.  As a service to end users,
Genesis will politely remind them that they can in fact Ctrl-C
after 3 failed answers.

A more complicated choice involves selecting one subkit from a
list of mutually exclusive subkits.  That looks like this:

```
subkits:
  - prompt:  How would you like to perform authentication?
    type:    authentication method
    choices:
      - subkit:  gh-oauth
        label:   Github OAuth2 (Organization-based Authentication)

      - subkit:  cf-uaa
        label:   Cloud Foundry UAA

      - subkit:  basic
        label:   HTTP Basic Auth over TLS/SSL
        default: yes
```

The user interaction looks like this:

```
Generating new environment *my-new-environ*...
Using the *kit-name/1.0.4* kit...

How would you like to perform authentication?

  1) Github Oauth2 (Organization-based Authentication)
  2) Cloud Foundry UAA
 *3) HTTP Basic Auth over TLS/SSL (default)

choice? [1-3]: 2

Enabling the *cf-uaa* subkit...

Done.  Your new environment has been saved in *my-new-environ.yml*
```

If the user selects a value that is out of bounds, Genesis will
admonish them lightly and re-ask the question.  A blank answer
will result in choosing the default choice, if one is specified.

It is illegal to specify `default: yes` on more than one choice,
and Genesis will politely inform the user that the Kit Author has
done a bad thing, provide the Github URL, and encourage them to
report a bug.  Nothing quite like motivation, eh?

If no default is given, Genesis will continue to ask the user for
a choice until they make a valid one, or send a Ctrl-C to abort
the provisioning process altogether.

A slight variation on the multiple-choice prompt is to allow no
subkit to be provided.  In that case, one or more choices should
have a null `subkit` key:

```
subkits:
  # you may choose a backup solution.
  - prompt: How would you like to perform backups of this deployment?
    type:   backup strategy
    choices:
      - subkit:  shield
        label:   Using the super awesome SHIELD backup system
        default: yes

      - subkit:  s3-backups
        label:   Simple S3-bucket Backups

      - subkit:  ~
        label:   I do not wish to perform backups
```

If the user selects the third option, no subkit will be activated.

Subkit selections live in the environment.yml, under the `subkits`
key.  For example, if a user chose to activate SHIELD backups,
enable Toolbelt, and use CF UAA authentication, the resulting
environment YAML file might look like this:

```
---
subkits:
  - toolbelt
  - cf-uaa
  - shield

params:
  kit:     kit-name
  version: 1.0.4
  # etc...
```

This makes it possible for users to change their subkit selections
after the fact.  Therefore, we cannot guarantee that conflicting
subkits selections will not arise in practice.  To this end,
`genesis deploy` (and other commands that generate deployment
manifests) performs validation against the chosen subkits, using
the `kit.yml` metadata.  The rules are simple:

  1. Subkits that are not referenced in `kit.yml`, but are
     selected in the environment file trigger an error.
  2. For multiple-choice subkits, if more than one subkit is
     selected, trigger an error.
  3. For multiple-choice subkits without a null kit choice,
     exactly one of the choices must be selected.  If not,
     trigger an error.
  4. If no errors are triggered, proceed with manifest generation.

Here's what the errors will look like, for a variety of different
failure cases.

**User has selected an invalid / unrecognized subkit:**

```
You have selected the `not-a-subkit` subkit, which does not exist
in this version of the **kit-name** kit.
Please remove it from your list of subkits.
```

**User selected both SHIELD and S3 backups (mutually-exclusive):**

```
You have selected more than one backup strategy.
Please select either the 'shield' or 's3-backups' subkit.
```

Of note here, the phrase "backup strategy" comes straight out of
`kit.yml` &mdash; it's the `type` field right underneath where we
set the prompt.  Also, Genesis has determined that there are only
two viable non-null options, and adjusted its output verbiage
accordingly.

**User has not selected an authentication method:**

```
You have not selected an authentication method.
Please add either 'cf-uaa', 'github-oauth', or 'basic' to your subkits list.
```

Again, we see the `type` field in use &mdash; this time Genesis
selects the proper a / an article based on the vowel that starts
the type.  It's a small thing, but people notice small things.

#### Using the subkit hook

An optional hook is provided to Kit Authors that will be fired
immediately after the user-interactive subkit selection. This allows
Kit Authors to perform obscure customizations to the subkit list, if
needed. Generally, this should not be used, but is here in case there
is some edge-case the user-interactive subkit selection does not
cover well enough.

The subkit hook lives in `hooks/subkit` of the Kit. It should be
a self-contained/portable executable. There is a simple contract
for subkit hooks. `genesis` passes the hook the list of selected
subkits as CLI arguments, and expects the script to output the
updated list of subkits to STDOUT (one per line) when it is complete.

For example, let's say our user has selected the `db-ha-postgres`
and `tcp-router` subkits for Cloud Foundry. This unique combination
requires a hidden subkit to be activated, to connect the `tcp-router`
with the `db-ha-postgres` database. After the user finishes subkit-selection,
`genesis` runs the subkit hook like so:

```
$ hooks/subkit db-ha-postgres tcp-router toolbelt my-other-subkit
db-ha-postgres
tcp-router
toolbelt
my-other-kit
tcp-router-pgdb
```

The subkit hook outputs the full list of subkits, including the new
one added. Order matters for subkits. If needed, the new subkit
can be inserted in any index of the list, so long as that's the right
place for it according to the Kit Author.

#### Defining Parameters in `kit.yml`

Genesis needs to know what params your kit requires, so it
can:

  1. Prompt the end-user for user-supplied values to go in
     the environment YAML
  2. Provide commented out default values for common parameters
     in the environment YAML
  3. Prompt the end-user for secret data to be stored in Vault
     in a location defined by the Kit Author and compatible with
     the kit's YAML configurations.

This is all done via the top-level `params` key of `kit.yml`. It
looks like this:

```
name: cloudfoundryfake
version: 0.0.1

subkits:
- prompt: "Are you using S3 for your blobstore?"
  subkit: s3
  default: yes

params:
  base:
  - ask: What is the base domain of your deployment?
    param: base_domain
    description: |
      This is used to auto-calculate many domain-based values in the
      deployment. You may change it as needed, so long as your certificates
      are updated with new domain values.
    example: bosh-lite.com

  - params:
    - cell_instances
    - router_instances
    - diego_instances
    description: This is used to scale out the number of VMs of various BOSH jobs

  - param: availability_zones
    description: |
      This specifies the different availability zones your deployment is
      spread across. The values here will need to match the availability
      zones defined in your Cloud Config.

  s3:
  - ask: What is your Amazon S3 Access Key ID?
    vault: s3:access_key
    description: |
      The S3 Access Key ID is used to connect to Amazon S3. In this
      deployment, S3 is used to house the blobstores for buildpacks,
      resource groups, and app data.
```

When generating an environment using the above example, the user interaction
would look like this (presuming the user chose to enable the `s3` subkit:

```
$ genesis new my-new-environ
Generating new environment my-new-environ...

Using dev/ (development version) kit...

Checking kit pre-requisites...


Are you using S3 for your blobstore?
[Y/n]: y

(*) bosh-lite   http://10.244.8.2:8200


Currently targeting bosh-lite at http://10.244.8.2:8200

Which Vault would you like to target?
bosh-lite> bosh-lite
Currently targeting bosh-lite at http://10.244.8.2:8200

Required parameter: base_domain

This is used to auto-calculate many domain-based values in the
deployment. You may change it as needed, so long as your certificates
are updated with new domain values.

(e.g. bosh-lite.com)

What is the base domain of your deployment?
value: cf.example.com

Secret data required -- will be stored in Vault under secret/my/new/environ/cloudfoundryfake/s3:access_key

The S3 Access Key ID is used to connect to Amazon S3. In this
deployment, S3 is used to house the blobstores for buildpacks,
resource groups, and app data.


What is your Amazon S3 Access Key ID?
access_key [hidden]:
access_key [confirm]:

Generating secrets / credentials (in secret/my/new/environ/cloudfoundryfake)...

New environment my-new-environ provisioned.

```

Note that when asking for the Amazon S3 Access Key ID, the input was
masked automatically, to help prevent credential leakage.

Now that the environment YAML has been generated and saved, it should look
like this, based on the above answers to the questions:

```
kit:
  name:     cloudfoundryfake
  version: 0.0.1
  subkits:
  - s3

params:
  env:   my-new-environ
  vault: my/new/environ/cloudfoundryfake

  # This is used to auto-calculate many domain-based values in the
  # deployment. You may change it as needed, so long as your certificates
  # are updated with new domain values.
  # (e.g. bosh-lite.com)
  base_domain: cf.example.com

  # This is used to scale out the number of VMs of various BOSH jobs
  #cell_instances: 3
  #router_instances: 2
  #diego_instances: 2

  # This specifies the different availability zones your deployment is
  # spread across. The values here will need to match the availability
  # zones defined in your Cloud Config.
  #availability_zones:
  #- z1
  #- z2
  #- z3
```

Additionally, there will be a secret in vault now, set to the user-supplied
data for `admin_password`, located at `secret/my/new/environ/cloudfoundryfake/aws/s3:access_key`. If the user had not selected the `s3` subkit, they would
not have been prompted for the S3 Access Key, and it would not be present
in Vault.

It is important to note that the default values provided for the comments
on the `*_instances` and `availiblity_zones` params were retrieved from
the `base/params.yml` or `<subkit>/params.yml` file, depending on which
sub-section of `params` the parameter was defined in. If there is no default
value found, a null value will be set as the default in the comment.

###### Parameter definition rules

There is a lot of flexibility allowed the operator for defining `params`.
However, some rules must be followed. Here are some guidelines for using it:

1. Every param requires a `description`. This will be displayed in the generated
   environment YAML. If the param is a question, the description will be displayed
   when the question is asked.
2. The `example` value is optional. If present, it will be displayed
   under the same circumstances as the `description`.
3. In order to ask the user for a value, you must define the question in `ask`.
   Otherwise, the param is treated as a commented-out-default.
4. Values from commented-out-default params are pulled from the `base/params.yml`
   file, or `<subkit>/params.yml` file as appropriate to where the param
   was defined. If not present, `null` will be the default value. Take care
   not to have the default value be a `(( param ))` or other spruce operator.
5. When asking a question, you may save it to the environment YAML via `param`.
   The value of `param` should be the name of the parameter to write in the file.
6. When asking a question, you may save it to Vault for safe-keeping using `vault`.
   The value of `vault` should be the relative path in Vault where the data
   should go (same path conventions as the `credentials` block).
7. The `params` identifier is used to list out a number of parameters that
   are all similar, and only need one description, to save space. This
   **CANNOT** be used with `ask`.
8. Each param must have one and only one of `vault`, `param`, and `params`.

#### Using the params hook

An optional hook is provided to Kit Authors that will be fired
immediately after the user-interactive for asking/retreiving param information.
This allows Kit Authors to perform obscure customizations/transformations to
the param data, if needed. Generally this should not be used, but it is here in case
there are edge cases requiring the human-friendly data entry to be massaged into
something that the bosh releases support.

Examples of when it might be used:

- The [cf-genesis-kit](https://github.com/genesis-community/cf-genesis-kit) uses
  the params hook to convert lists of IPs/networks into Application Security Group
  rules, since data entry is much easier on the operator this way.
- The [cf-genesis-kit](https://github.com/genesis-community/cf-genesis-kit) uses
  the params hook to query the user if they have an SSL certificate to give to
  HAProxy, or if they would like one auto-generated. In one case, the user is prompted
  for the certificate. In the other, it is just generated for them in Vault. If
  the cert was auto-generated, it also overrides the default value for another
  param (`params.skip_ssl_validation`), to make life easier for the operator.
- The [jumpbox-genesis-kit](https://github.com/genesis-community/jumpbox-genesis-kit) uses
  the params hook to allow for complicated data entry regarding jumpbox users, that
  otherwise would not be possible via traditional params support in genesis.

The params hook lives in `hooks/params` inside the Kit. It should be a self-contained
portable executable. The contract around params hooks is slightly more complicated
than subkit hooks, as there is more going on. The hook is passed via CLI args the
path to the file containing param input, the path to the file that the hook should
output it's manipulated data, and a list of all subkits marked for inclusion in the
environment. The input file is a JSON structure containing the definitions of all
the params currently defined for the environment (any non-Vault params defined in
the `kit.yml`'s `params` section, based on the applicable subkits). This JSON structure
must be manipulated as required, and output into the specified path, for genesis to
read in. Similar to the subkit hook, if there is a param passed into this hook that
is not present in the output, it will be omitted from the environment.

Providing the input/output of this script as file paths makes it easy to interactively
query the operator for more information via stdin and stdout, as well as to provide
debugging and display errors encountered via stderr.

Example of a simple param-hook in action (it will convert `params.my_list` from a list to
a map, with each value being `1`):

```
$ cat tmpdir/in
[
  { "comment": "This is the description for the param",
    "example": "This is the example value for the param",
    "default": false, # a boolean representing if this is a default value or user-supplied
                     # if true, the param will be commented out in the resultant environment yml file
    # `values` is a list of params that apply to this param (to support the same comment across multiple
       default params). Each item of its list is an object with one key representing the param name,
       and the value associated with that key.
    "values": [{"my_list": ["red", "blue", "green"]}]
  }
]
$ hooks/params tmpdir/in tmpdir/out
Converting params.my_list into a map
$ cat tmpdir/out
[
  { "comment": "This is the description for the param",
    "example": "This is the example value for the param",
    "default": true, # a boolean representing if this is a default value or user-supplied
                     # if true, the param will be commented out in the resultant environment yml file
    "values": [{"my_list": { "red":1, "blue": 1, "green": 1}}]
  }
]
```

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

### `prereqs` - Prerequisite Check Script

The `prereqs` script, if it exists, is run prior to most Genesis
commands.

  - Before `genesis new`, to allow Kit authors to require specific
    tools that will be used in any hooks, like `jq`.
  - Before `genesis manifest`, to allow Kit authors to insist on a
    minimum version of Spruce so that they can take advantage of
    newer features.
  - Before `genesis deploy`, to enable the Kit to ensure that a
    new enough version of deployment tools (like the BOSH CLI) is
    present.

The `prereqs` script will be given a single argument, the name of
the Genesis sub-command that is currently running.  For example, a
`prereqs` script that needs to ensure that Spruce version 1.9.4
or higher is installed, in order to be able to generate manifests,
might look like this:

```
#!/bin/bash

# assuming 'semver' is a thing that checks version numbers...
if [[ -z $(command -v semver) ]]; then
  echo >&2 "semver not installed; can't check versions!"
  exit 1
fi

# we need a spruce >= 1.9.4
if [[ -z $(command -v spruce) ]]; then
  echo >&2 "spruce is not installed!"
  exit 1
fi
if ! semver check 'spruce -v' --at-least 1.9.4; then
  echo >&2 "spruce is $(semver parse 'spruce -v'); but we need 1.9.4!"
  exit 1
fi

# all good!
exit 0
```

This script will enforce the Spruce >= 1.9.4 version requirement
no matter what command we are running.  If everything works out,
and the prerequisites are met, it prints out nothing and exits 0.
Otherwise, it prints errors to standard error (file descriptor 2)
and exits non-zero.

Suppose we need to extend these requirements, and add that we need
`jq` &mdash; for our `params` hook.

```
#!/bin/bash

# assuming 'semver' is a thing that checks version numbers...
if [[ -z $(command -v semver) ]]; then
  echo >&2 "semver not installed; can't check versions!"
  exit 1
fi

# we need a spruce >= 1.9.4
if [[ -z $(command -v spruce) ]]; then
  echo >&2 "spruce is not installed!"
  exit 1
fi
if ! semver check 'spruce -v' --at-least 1.9.4; then
  echo >&2 "spruce is $(semver parse 'spruce -v'); but we need 1.9.4!"
  exit 1
fi

# also, check for certgen
if [[ -z $(command -v jq) ]]; then
  echo >&2 "jq is not installed!"
  exit 1
fi

# all good!
exit 0
```

That's all well and good, but now operators will need to load
`jq` into their pipeline CI/CD task image.  If we refine the
requirements slightly, we realize that we only need `jq` when
we are provisioning new environments, so we can key off of the
first argument, thusly:

```
#!/bin/bash

# assuming 'semver' is a thing that checks version numbers...
if [[ -z $(command -v semver) ]]; then
  echo >&2 "semver not installed; can't check versions!"
  exit 1
fi

# we need a spruce >= 1.9.4
if [[ -z $(command -v spruce) ]]; then
  echo >&2 "spruce is not installed!"
  exit 1
fi
if ! semver check 'spruce -v' --at-least 1.9.4; then
  echo >&2 "spruce is $(semver parse 'spruce -v'); but we need 1.9.4!"
  exit 1
fi

# also, check for jq (only for `genesis new`)
case $1 in
(new)
  if [[ -z $(command -v jq) ]]; then
    echo >&2 "jq is not installed!"
    exit 1
  fi
  ;;
esac

# all good!
exit 0
```

Now, we aren't forcing operators to install something new in the
CI/CD image, only on their jumpbox / laptops.

### `base/` - Shared Deployment Templates

The `base/` directory contains all of the manifest YAML templates
that will be merged in, regardless of what subkits (if any) are
active.  All `*.yml` files under `base/` will be merged,
alphabetically, before any subkits are merged.

Kits should not rely on the order of the merge, except to take
advantage of the fact that base template files are always ahead of
the subkit template files in the merge order, which allows subkits
to override base configuration.

### `subkits/*` - Subkits

Each subkit inhabits its own directory under the `subkits/`
directory.  If a subkit is listed in the environment manifest, all
of the `*.yml` files in that subkit directory will be merged on
top of the base files.  As with `base/`, kit authors should not
rely on the order in which individual files are merged.

### `hooks/` - Hooks directory

This is where the `subkit` and `params` hooks live. This directory
and both scripts inside are completely optional, and likely
rarely implemented. However, if present, the scripts must be executable
files. You may implement only one of the hooks, if desired -
they are mutually exclusive.


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

## ca

DEPRECATED: use the `certificates` section of kit.yml instead

## cert

DEPRECATED: use the `certificates` section of kit.yml instead

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

Sometimes you might want to randomly generate a password, but then format it in a way
that deployments are expecting it, commonly a hashed copy of the password. You'll still
want the original for the operator to reference, but you'll also want to perhaps crypt-sha512
hash it, for the boshrelease to use properly. Good news! That can be done relatively easily:

```
credentials:
  base:
    users/root:
      password: random 64 fmt crypt-sha512
```

You can specify any format options that are supported by `safe`, such as `crypt-sha512`, `crypt-sha256`,
`crypt-md5`, `base64`, or `bcrypt`. The formatted values are stored in vault along side the original,
with the name of the format appended to the name of the original key, e.g. `secrets/mything:supersecret`
would have a `secrets/mything:supersecret-bcrypt` if formatted with `bcrypt`.

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

On occasion, you may need to limit, or expand the characterset used to generate random passwords.
By default, genesis uses `safe`'s default characterset (`a-zA-Z0-9`). This is also fairly easy:

```
credentials:
  base:
    restricted:
      characters: random 64 allowed-chars a-c
```

This will generate a secret with 64 characters randomly chosen from the set of `a`, `b`, and `c`.

If you use this in conjunction with the `fmt` keyword, ensure that `allowed-chars` comes after the
end of the `fmt` definition.

## from file "/path/to/file"

DEPRECATED: use the `params` section of kit.yml instead

`from file` extracts a secret from a file somewhere.  This is
useful for requiring that users provide their own SSL/TLS
certificates, without forcing them to copy-paste them around
(which inevitably leads to corrupt PEM files).

Note: this one is not yet implemented, and may suffer from
usability issues - how do we use separate files for different
environments, for example.

Definition:

```
credentials:
  base:
    certs/haproxy:
      private: (( from file "haproxy.key" ))
      public:  (( from file "haproxy.pem' ))
```

Usage:

```
jobs:
  - name: haproxy
    properties:
      ssl:
        key:  (( vault "secret/" params.vault "certs/haproxy:private" ))
        cert: (( vault "secret/" params.vault "certs/haproxy:public" ))
```

## ask "prompt to display"

DEPRECATED: use the `params` section of kit.yml instead

Sometimes, you just need to ask the user to provide credentials
directly.  For example, you may need to know their vCenter
password for a BOSH director kit, and the easiest way to get it is
to ask.  This operator takes a prompt to display to the user, and
then solicits input (with terminal echo turned off).  The user
will be asked to confirm their entry.

Definition:

```
credentials:
  base:
    vsphere/vcenter:
      username: ask "What is your vCenter Service Account Username?"
      password: ask "What is your vCenter Service Account Password?"
```

Usage:

```
cloud_provider:
  vsphere:
    username: (( vault "secret/" params.vault "vsphere/vcenter:username" ))
    password: (( vault "secret/" params.vault "vsphere/vcenter:password" ))
```

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
