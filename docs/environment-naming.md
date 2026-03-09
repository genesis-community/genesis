# Genesis Environment Naming: Rules, Conventions, Purpose and Usage

This document outlines the naming conventions and patterns used throughout Genesis for various components including environment files, BOSH deployments, Vault paths, and more.

## Environment YAML Filenames

Environment files are YAML files that define the configuration for a specific deployment environment. These files are named according to a specific pattern that allows Genesis to build a hierarchy of configuration settings.  A common naming convention for environment files is `<company-identifier>[-<department-identifier>]-<infrastructure-identifier>-<region>-<purpose>.yml` (ex: `acme-ops-aws-us-east-1-dev.yml`), but other patterns are possible.  The general idea is to have a hierarchical structure that allows for inheritance of configuration settings, from the most general to the most specific.

### Valid Naming Format and Characters

Environment filenames in Genesis follow a specific pattern:

- Environment files must end with the `.yml` extension
- Environment names (the part preceeding the `.yml` extention) must follow these rules:
  - Can only contain lowercase 7-bit ASCII letters, numbers, underscores and hyphens (`-`)
  - Must start with a letter
  - Must not end with a hyphen
  - Must not contain sequential hyphens (`--`)
- Examples of valid names: 
  - `env1`
  - `us-east-1-prod`
  - `this-is-a_really_long-super-hyphenated-name`
  - `acme-us_east_1-prod`

### Hierarchical Structure

Genesis uses hyphens in environment names to separate tokens and define a hierarchical structure that is automatically merged when processing environment files.  The hierarchy is built from the most general to the most specific, left to right, with each segment of the name representing a different hierarchical level of configuration.  This allows common settings to be defined at a higher level and overridden at a lower level, following the DRY principle.

Here are a couple of examples following the `<org>-<infrastructure>-<region>-<purpose>` pattern:

- `acme-aws-us-west-2-prod.yml`
- `globex-gcp-europe-west1-dev.yml`

These examples illustrate how different organizations, infrastructures, regions, and purposes can be represented in the environment filenames.  Note that the components can have hyphens themselves.  This allows for sub-hierarchies within the environment name for finer-grained configuration inheritance.

When Genesis processes these files, it automatically builds the inheritance chain by splitting the name on hyphens:

1. For `c-aws-us-east-1-prod.yml`, Genesis will look for and merge any existing files in the following order:
   - `c.yml` (org level)
   - `c-aws.yml` (iaas level)
   - `c-aws-us.yml` (region level - most coarsely-grained)
   - `c-aws-us-east.yml` (region level - mid-grained)
   - `c-aws-us-east-1.yml` (region level - most finely-grained)
   - `c-aws-us-east-1-prod.yml` (environment/purpose level)

Each level inherits and can override settings from the previous level, allowing for fine-grained configuration management.  There is no requirement for each of the files preceeding the environment file to exist, but those that do will be merged in the order listed above.  In the previous example, configurations common across all AWS deployments could be defined in `c-aws.yml`, while configurations specific to the `us-east-1` region could be defined in `c-aws-us-east-1.yml`.

> **NOTE:** *Only the last file (the environment file) in the hierarchy has to be a "deployable" file, while those above it are expected to contain partial configurations that fit the scope and purpose of their level.*

### Overriding Configuration

When a setting is defined in multiple environment files, the most specific (last) setting takes precedence.  For example, if `c-aws-us-east-1.yml` defines a `size: small` and `c-aws-us-east-1-prod.yml` defines `size: large`, the `size` setting in the final deployment manifest will be `large`.

### Pipelines Use of Hierarchical Structure

When using the Genesis-generated Concourse pipelines to progress changes through environments, such as `sandbox->lab->qa->prod`, it is beneficial to define the changes at the broadest level possible, as the pipeline will use those settings for all environments that have that common ancestor.  This allows for a single change to be made at the broadest level and have it automatically applied to all environments that inherit from that level, including validating it in the lower environments before promoting it to production.

### Alternatives to Layered Hierarchy

#### Operations Files

Operations files ("ops files") give us a second method for modifying properties during manifest assembly. So ops files don't supplant the hierarchy, they can be used to flexibly augment it.  Specifically, they are used to alter the manifest inline during the kit's assembly process, before the environment files are merged on top of it.  However, ops files can accomplish many of the same goals as the hierarchy, such as defining common settings in a single file and overriding them in specific environments.

To use an ops file, create an `ops` directory in the same directory that contains the environment file(s) that will use it, and place the ops files within this `ops/` directory.  Then specify the ops file in the environment file's `kit.features` section, without the `ops/` directory prefix and without the `.yml` extension.

For example, if you have an operation file `ops/enable-ssl.yml`, you would specify including it in the environment file like this:

```yaml
kit:
  features:
    - enable-ssl
```

Because the features are applied in order we have precise control over the order in which the operations are applied.  However, ops files are all applied before the environment files are merged, so settings in the hierarchal environment files can not be overridden by operations files. 

#### Genesis Inherits

If there are specific modifications to apply that don't fit a hierarchical structure, we can use the `genesis.inherits` directive in the environment file to specify additional files to include.  The inherited file(s) will be merged in just before the environment file that specifies it, in the order specified in the `genesis.inherits` array.  If an inherited file specifies its own `genesis.inherits` directive, these files will be included as well, and so on.  Circular references are handled by ignoring any files that have already been included in the inheritance chain, including the environment file that started the chain. This means that an inherited file will not be loaded twice, and will apply its values only the first time it is encountered.

The `genesis.inherits` directive allows you to explicitly include specific environment files regardless of naming convention:

```yaml
# In my-environment.yml
genesis:
  inherits:
    - base-config
    - regional-settings
```

This approach gives more control over the inheritance chain when the default hyphen-based hierarchy isn't suitable.  However, in the spirit of convention over configuration, it is recommended to use the hierarchical structure when possible to keep configurations organized and easy to understand.  This reduces human error and maintainability of environment configurations over time.

## BOSH Environments

Genesis uses the environment name to determine several BOSH-related identifiers:

### BOSH Director Selection

With the exception of the deployment of the BOSH director itself, all environments are deployed to the BOSH director it shares its name with.  For example, the `aws-us-east-1-prod.yml` environment under a `cf` deployment directory would deploy to the `aws-us-east-1-prod` BOSH director.  Notably, a BOSH director can not be deployed to itself, so the key `genesis.bosh_env` exists to override the BOSH director name in an environment file:

```yaml
genesis:
  env: c-aws-us-east-1-prod
  bosh_env: c-aws-us-east-1-mgmt
```

This can also be used to deploy to a different BOSH director than the one that shares the environment name, but this is not recommended as it can lead to confusion and maintenance issues.

### Deployment Name

When Genesis deploys an environment through BOSH, it specifies the BOSH deployment name in the manifest, in the form of `<environment>-<kit-type>`.  For example, deploying the cf environment `c-aws-us-east-1-prod.yml` would result in a BOSH deployment named `c-aws-us-east-1-prod-cf`.

By default, the kit type is the same name as the kit name, without the `-genesis-kit` suffix, which is also the default name for the deployment directory when using the `genesis init -k <kit-name>` command.  However, the directory name can be changed by specifying the `-d <directory-name>` option when running the `genesis init` command, and the kit name can be changed by specifying the `<name>` argument.  The type can also be changed after the fact by editing the `.genesis/config` file in the deployment directory:

```yaml
---
# This file is generated by Genesis - do not edit manually.
# Last updated by <some-user> on <date> at <time>

# ... other settings ...
deployment_type: cloudfoundry-supreme
# ... more settings ...
```

As noted in the example above, it is not recommended to edit the `.genesis/config` file manually, as it is generated by Genesis and can be overwritten by future Genesis commands.  Again, it is recommended to use the default naming conventions to avoid confusion and maintainability issues.

### BOSH Config Entries

Starting from Genesis 3.1, Genesis manages the various BOSH configurations, such as `cloud`, `runtime` and `cpi` configs.  These are added to or removed from the BOSH director under specific circumstances, such as when the environment is deployed or removed.  These are named after the environment name used in the deployment.  By using the environment name, Genesis can ensure that it updates or removes the correct configurations corresponding to each environment without having to keep track of additional identifiers.

Furthermore, BOSH cloud config entries are prefixed with the environment name to ensure uniqueness across environments.  This is especially important when deploying multiple environments to the same BOSH director, as reuse of the same vm or disk type names with different configurations could lead to confusion or errors.

## Vault Path Structure

Genesis stores secrets and exodus data in Vault using paths derived directly from the environment name.

### Secrets Path

For secrets generated for the deployment of an environment, the path is:

```
/secret/<environment-segments>/<kit-type>/...
```

where `<environment-segments>` is the environment name split on hyphens,joined by slashes. For example, with a `cf` environment defined in `aws-us-east-1-prod.yml`, the path would be `/secret/aws/us/east/1/prod/cf/...`.

#### Custom Secrets Path

You can customize the secrets path with values in the environment file:

```yaml
genesis:
  secrets_mount: custom-mount/genesis-secrets # default is "secret"
  secrets_slug: aws-us-east-1-prod # default would be aws/us/east/1/prod
```

This would result in a path of `/custom-mount/genesis-secrets/aws-us-east-1-prod/cf/...` for the generated secrets.  The `secrets_mount` and `secrets_slug` values are used to generate the path segments, so they must be valid Vault path segments.  

Mount path override may be required if your organization has restricted access to a subset of Vault paths and you need to store secrets in a different location.

The only functional reason to override the `secrets_slug` value is that the environment name contains too many segments to be a valid Vault path (eg. Vault can only handle so many segments).  In this case, we use the `secrets_slug` value to specify a shorter (eg. less `/` characters), valid path segment to use in the secrets path.  However, it may be more beneficial to instead adjust the environment name to be more manageable.

> **NOTE:** *This behavour may be changed in future versions of Genesis, so it is recommended to use the default secrets path structure to keep things organized and easy to understand. Detection and movement of secrets from the old path to the new path will be done automatically should this be implemented.*

### Exodus Data Path

Unlike secrets, the exodus path does not split the environment name into segments.  Instead, it uses the full environment name as-is, under the `exodus` subpath:

```
/secret/exodus/<environment-name>/<kit-type>
```

#### Custom Exodus Path

Just like with secrets, the exodus path can be customized with values in the environment file:

```yaml
genesis:
  exodus_mount: custom-mount/exodus-data # default is "<secrets_mount>/exodus"
  exodus_slug: cf-prod-on-aws/us-east-1 # default would be aws-us-east-1-prod
```

This would result in a path of `/custom-mount/exodus-data/cf-prod-on-aws/us-east-1/cf` for the generated exodus data.  The `exodus_mount` and `exodus_slug` values are used to generate the path segments, so they must be valid Vault path segments.

There are no known reasons to override the `exodus_slug` value, and it may lead to maintainablity issues and confusion.  It is recommended to use the default exodus path structure to keep things organized and easy to understand.

## Deployment Root Structure

Genesis relies on specific directories to organize deployment configurations for each Genesis kit's environments.  The deployment root is the directory that contains all the deployment directories for a specific kit.  There is no specific naming conventions for this directory, but it is generally named `ops` or `deployments`.

Currently there aren't any specific requirements for any configuration files, but the intention is to have a `.genesis/config` file or similar to facilitate common settings across all environments.

### Deployment Root Organization

This directory will contain a directory for each deployment type, such as `cf`, `concourse`, `vault`, `jumpbox`, and `shield`:

```
ops/
├── cf/
├── concourse/
├── vault/
├── jumpbox/
└── shield/
```
Each of these directories will contain the environment files for that deployment type, following the naming conventions outlined above.  It is per "deployment-type" and not per "kit" as different "deployment-types" can use the same "kit", such as the `generic-genesis-kit` being used to create bespoke `postgresql` and `datadog` deployments for example.

The deployment root structure is not required to use Genesis, but it is recommended to keep things organized and easy to understand.  However, it is required to use the match mode feature, which is described below.

Genesis supports having this root directory as a single git repository, or as a collection of git repositories for each deployment type.  While most operations in Genesis doesn't care about this detail, the pipelines that Genesis generates will need to be configured to pull from the correct repository for each deployment type, as well as its directory in that repository.

> **NOTE:** *The use of the `ops` directory here as an example should not be confused with the `ops` directory used inside each "deployment-type" directory that contains the deployment environment files for that type.*

### Match Mode Configuration

> **See [matcher.md](matcher.md) for the full match mode reference**, including syntax, pattern matching rules, the search algorithm, disambiguation behavior, BOSH target defaults, and troubleshooting.

When issuing Genesis CLI commands, certain (and most used) commands require an environment or deployment repo to be specified.  In normal mode, Genesis will look for an exact match of the name provided (.yml extension is optional) in the current directory.  You can also specify the absolute or relative path to the environment if you're not in the deployment directory.  Given how long environment names can be, this can become burdensome.

However, Genesis also supports a *match mode* that allows you to use glob-style pattern matching to find the environment file.  That way, you only have to specify the unique part of the environment name and/or type to reference it.

For example, if the following environments are in the `cf` deployment directory:

```
c-aws-us-east-1-prod.yml
c-aws-us-west-1-prod.yml
c-aws-us-east-1-dev.yml
c-aws-us-east-1-staging.yml
```

then we deploy `c-aws-us-east-1-prod.yml` with the following command:

```bash
$ genesis deploy "@ea*p:cf"
```

While this is an extreme example, it is normal to just use `@east-1-prod:cf` to deploy the `c-aws-us-east-1-prod.yml` environment, which is both easier to type and remember.

This doesn't necessarily need it to be unique; to deploy a cf environment, to see a list of what's available, use the following command:

```bash
$ genesis "@*:cf" deploy

Multiple environment files found matching @*:cf:

  📁 Deployment Root 'genesis-deployments': ~/ops
  1) cf/c-aws-us-east-1-dev (default)
  2) cf/c-aws-us-east-1-staging
  3) cf/c-aws-us-east-1-prod
  4) cf/c-aws-us-west-1-prod

  5) None of these - cancel

Select the desired environment file >

```

The default will be the first one listed (alphabetically), but we can select any of the environments listed.

#### Enabling Match Mode

To enable match mode, you need to specify one or more deployment roots in our user `~/.genesis/config` file.  This file is used to store user's personal Genesis configuration settings, such as output options, logging, and other personal preferences in addition to the deployment roots.  The deployment roots are specified in the `deployment_roots` array:

```yaml
---
# ... other settings ...
deployment_roots:
- <label>: <path>
- <another-path>
```

The deployment root array entries can be specified as a key-value pair, with the key being a label for the deployment root and the value being the path to the deployment root.  If a label is not specified, Genesis will use the last segment of the path as the label.

## Best Practices

1. **Be consistent** with naming patterns across all deployments
2. **Document the naming schema** for team reference
3. **Use meaningful segments** in environment names that reflect the infrastructure
4. **Leverage the hierarchy** to minimize duplication of configuration
5. **Consider match mode** needs when designing environment names
