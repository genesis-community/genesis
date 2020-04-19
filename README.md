Genesis - A BOSH Deployment Paradigm
==================================

## Genesis v2

Genesis v2 is the first version of Genesis to fully support BOSH v2. It is primarily geared
to deployments that make use of Cloud Config, and Runtime Config. The BOSH v2 CLI is also a
requirement of Genesis v2.

Genesis v2 builds upon the previous generation of Genesis, eliminating
the vast majority of YAML files all over the place, leading to confusion and
questions like "Where do I put property X - properties.yml, networking.yml, or credentials.yml?"

It also supports the next generation of Genesis deployment templates - Kits.
In the old genesis, deployment templates were pulled in once, forked from their upstream,
and likely never reconciled. With kits, you can keep upgrading the kit, pulling in
newer versions of your deployment to make life much easier down the road.

### Credential Rotation Built-in

Genesis v2 makes use of Vault as a back-end for storing credentials, most easily deployed
+ managed via the [Vault kit](https://github.com/genesis-community/vault-genesis-kit), and
the [safe CLI](https://github.com/starkandwayne/safe). Each kit will auto-generate credentials
where appropriate, ensuring that each environment has unique and secure credentials. Secrets
can be manually or automatically rotated at the drop of hat with the `genesis secrets` command.
Kits will define certain credentials as fixed, indicating that they should not be rotated
under normal circumstances, as that would have ill effects on the deployment (the CF db encryption
key for example).

### The New Tiered Architecture

In Genesis v2, the data that was previously stored in `global` and `site` by and large go away.
Most of `global` is provided via Kits. Most of `site` is now moved into Cloud Config. As a result,
we can stick most of the customization into a single file per environment, and the directory
structure has been flattened. To share information between environments, and reduce config repitition,
you can create files based on shared prefixes of the environment. For example, `us-west-1` and `us-west-2`
share both `us`, and `us-west` prefixes, and could share configuration in files named as such).

Here's what the new layout looks like:

```
.
├── ci.yml
├── us-boshlite-alpha.yml
├── us-east-dev.yml
├── us-east-prod.yml
├── us.yml # shared with us-*.yml
├── LICENSE
└── README.md
```

### Using Kits

When using a kit with Genesis v2, Genesis will automatically download the latest (or
specified) version of a kit, when you initialize your deployment repo. Any new
versions of the kit can be retrieved with `genesis download`. Each deployment environment
must have at some point in its merge-path, a `kit` section, indicating what kit + version
should be deployed. It will look something like this:

```
---
kit:
  name: jumpbox
  version: 2.0
```
To get the full benefit of CI, operators should place this in a file
that is shared across all environments, so that upgrades can be vetted in the deployment pipeline
in non-production environments, before going to production.

### Flexible Deployment Pipelines

The pipeline strategy of Genesis v2 is much more flexible than the previous approach. Operators
are able to define what environments should trigger, which should not, as well as which environments
are gateways to deploying in later environments. Stemcell management is built-in, as are locking
mechanisms to ensure that your BOSH isn't upgraded while it's in the middle of deploying something.

For a full run-down on Genesis v2 + deployment pipelines, see our [pipeline documentation](docs/PIPELINES.md)

## Installation

On Ubuntu/Debian you can install `genesis` and all its dependencies:

```
wget -q -O - https://raw.githubusercontent.com/starkandwayne/homebrew-cf/master/public.key | apt-key add -
echo "deb http://apt.starkandwayne.com stable main" | tee /etc/apt/sources.list.d/starkandwayne.list
apt-get update
apt-get install genesis -y
```

On OS X/Mac:

```
brew tap starkandwayne/cf
brew tap cloudfoundry/tap
brew install genesis spruce safe bosh-cli vault git
```

On Centos 7 / Amazon Linux

```
# Install Dependencies
sudo yum install -y perl perl-Data-Dumper perl-Time-Local perl-Time-Piece \
  perl-local-lib perl-Carp perl-PathTools perl-Digest perl-File-Temp perl-Socket

# Grab latest url from releases page
wget https://github.com/starkandwayne/genesis/releases/download/${GENESIS_VERSION}/genesis
chmod 0755 genesis
```

`genesis` requires Perl. But Perl is everywhere.

You will need to set up Git:

```
git config --global user.name "Your Name"
git config --global user.email your@email.com
```

## Using Genesis

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
genesis init --kit shield/1.2.3
```

Create a new deployment named us-west-1-sandbox:

```
genesis new us-west-1-sandbox
```

Generate a manifest for an environment:

```
# Using the live the cloud-config from the BOSH director
genesis manifest my-sandbox
# or, using the local file cached-cloud-config.yml:
genesis manifest -c cached-cloud-config.yml
```

Deploy a deployment, manually:

```
genesis deploy us-west-1-sandbox
```

Rotate credentials for a deployment:

```
genesis secrets us-west-1-sandbox
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
genesis repipe
```

Describe a given pipeline, in words:

```
genesis describe
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

## Transitioning to Genesis v2

Due to the sweeping changes involved in Genesis v2, it is recommended to start
with a fresh deployment repo, and migrate existing deployments slowly but surely
over to Genesis v2 using the appropriate kits, or if necessary, a `dev` kit (see
[Authoring Kits](docs/AUTHORING-KITS.md) for more info). The `genesis` command will
auto-detect if you are running inside a Genesis v1 repo, and switch to a `v1` mode,
for compatibility.

## Design Notes + Genesis Developer Resources

Genesis v2 design documentation that was previously found here has moved.

  - [Design Notes](docs/DESIGN.md)
  - [Pipelines](docs/PIPELINES.md)
  - [Authoring Kits](docs/AUTHORING-KITS.md)
  - [Environment Parameters](docs/PARAMS.md)
