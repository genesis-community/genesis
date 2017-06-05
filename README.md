genesis v2 - super secret research
==================================

**PRIVATE REPO BECAUSE CREDENTIALS / not quite ready for the light**

## Design Notes

Design documentation that was previously found here has moved.

  - [Design Notes](docs/DESIGN.md)
  - [Pipelines](docs/PIPELINES.md)
  - [Authoring Kits](docs/AUTHORING-KITS.md)
  - [Environment Parameters](docs/PARAMS.md)

**NOTE: This README should begin to transition to a more
operator-centric document, to assist in the setup and
provisioning, deployment, CI configuration, etc.**

## Using Kits

Environment manifests will have to specify their kit using the
top-level (reserved) parameters `params.kit` and `params.version`:

```
---
params:
  kit:     jumpbox
  version: 2.0
```

These parameters are **required**.  They can be set at
higher-levels if necessary / desired.

### Kits and the Genesis Index

Kits will be distributed primarily via the Genesis Index, and
secondarily through the use of local files.  We will have to add a
new type (`kit`) to the index to support these, but the new type
should behave similarly to releases and stemcells - probably via
Github Release URLs.

Possible bootstrap secnario:

```
$ genesis bootstrap --kit shield [shield-deployments]
```

Possible upgrade command:

```
$ genesis kit shield 6.3.7
```

(to download version 6.3.7 of the `shield` kit)

## Reserved Parameters

The following top-level parameters are reserved:

- **params.kit** - The name of the kit to use for this
  environment.
- **params.version** - The version of the kit to deploy.
- **params.env** - The name of the environment.
- **params.bosh** - The alias (or URL) of the BOSH director that
  owns this environment.  Defaults to `params.env`.
- **params.vault** - The prefix to store credentials in the Vault.

## The Genesis CLI - A Cookbook

Here are a few thoughts on the Genesis CLI.

Global options should be recognized for all commands:

  - `-D` / `--debug` - Enable debugging mode, wherein Genesis
    prints messages to standard error, detailing what tasks it is
    doing, what commands it is running, return values, etc.
  - `-T` / `--trace` - Enable debugging mode in all called
    utilities, like `spruce` and `bosh`, where available.
  - `-C PATH` - Perform all operations from `PATH` as the current
    working directory.
  - `-y` / `--yes` - Answer "yes" to all questions, automatically,
    on behalf of the user.  This means, for example, running `bosh
    -n`, instead of just `bosh`.

Initialize a Genesis repo:

```
genesis init --kit shield
genesis init --kit shield --version 1.2.3
```

Create a new deployment named us-west-1-sandbox:

```
genesis new us-west-1-sandbox
genesis new-deployment us-west-1-sandbox
```

Generate a manifest for an environment:

```
# download the cloud-config from the BOSH director
genesis manifest my-sandbox
# or, using the local file cached-cloud-config.yml:
genesis manifest -c cached-cloud-config.yml
```

Deploy a deployment, manually:

```
genesis deploy us-west-1-sandbox
```

Summarize the current state of deployments and what kits they are
using:

```
genesis summary
```

Download version 1.3.4 of the SHIELD kit:

```
genesis download shield 1.3.4
```

Deploy the Genesis CI/CD pipeline configuration to Concourse:

```
genesis push aws
genesis repipe aws
```

Describe a given pipeline, in words:

```
genesis describe pipelines/aws
```

Draw a pretty picture of a pipeline, using `dot`, suitable for
embedding in documentation and putting on your blog:

```
genesis graph pipelines/aws
```

Embed the calling Genesis script in the Genesis repo:

```
genesis embed
```

Update the calling copy of the Genesis script, from the latest
upstream release on Github:

```
genesis sync
```

I'm sure there are others.
