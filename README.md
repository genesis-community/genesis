Genesis - A BOSH Deployment Paradigm
====================================

Deploying across multiple environments can be a daunting task,
especially when it comes to ensuring that commonalities like IaaS
properties and networking are common where they should be and
specialized where they shouldn't.

An ideal deployment pipeline might look something like this:

![Environments](docs/envs.png)

Where sandbox is used to validate that deployments are sane, test
stemcell upgrades, etc., preprod enables integration and
acceptance testing, and prod is the thing that shouldn't break.
For reasons of sanity, these environments should all be deployed
on similar infrastructure, like Amazon EC2 or a hosted VMWare ESXi
cluster.

Challenges arise when you need to make changes to the "common
elements" of these different environments, like what AWS region
the deployments should be done in, or what version of the BOSH
release is being deployed.  Without intense discipline, these
different environments can easily drift, which may have disastrous
consequences.

Genesis changes this by breaking up your BOSH configuration
manifest along three logical strata: _global_, _site_ and
_environment_.

![Tiered Architecture](docs/tiers.png)

At the top, the most generic configuration is considered
**global**.  The general outline of your deployment, what jobs run
on what instances, is specified here, and used everywhere.
Defaults for job and global properties are defined here as well.

Beneath that, the **site** stratum defines the composition and
configuration of your infrastructure.  For example, if you are
deploying on the Amazon AWS EC2 platform, you would set your
S3/EC2 credentials, which AMI to use as a stemcell, etc. here.

At the lowest and most specific level, **environment** provides a
place to set the networking for a single deployment, and override
properties and scaling factors here.  Your sandbox environment
probably doesn't need to run as many instances as production, and
they are most likely in different subnets.

Genesis combines these different levels of configuration to
produce a single BOSH manifest for each environment, and uses a
tool called [spruce](https://github.com/geofffranks/spruce) to handle overrides and references in
a straightforward and predictable manner.

## More Information

For more information, check out these fantastic Stark & Wayne blog
articles about using Genesis in real world situations:

  - [Managing Multiple BOSH Environments with Genesis][blog-bosh]
  - [Standing up Vault with Genesis][blog-vault]
  - [Using Genesis to Deploy Cloud Foundry][blog-cf]

[blog-bosh]:  https://www.starkandwayne.com/blog/managing-multiple-bosh-environments-with-genesis/
[blog-vault]: https://www.starkandwayne.com/blog/standing-up-vault-using-genesis/
[blog-cf]:    https://www.starkandwayne.com/blog/using-genesis-to-deploy-cloud-foundry/


## Installation

There are a couple ways to get Genesis on your machine. If you're on a Mac, the easiest
is to use homebrew:

```
brew tap starkandwayne/cf
brew install genesis
```

Otherwise, you can grab the latest release artifact from our [GitHub Releases](https://github.com/starkandwayne/genesis/releases).

# Managing BOSH Release/Stemcell Versions with Genesis

Genesis offers the following commands for manipulating release
and stemcells globally, and across sites:

| Command | Purpose |
| ------- | ------- |
| `genesis add release <release-name> [<version>]` | Adds the release to global/releases, at the specified version, or 'latest' if not specified |
| `genesis use release <release-name>` | Adds the release to site/releases, so it gets included in environments of this site ||
| `genesis set release <release-name> <version>` | Updates the release to the specified version at the global level |
| `genesis use stemcell <stemcell-name/alias> <version>` | Sets the site's stemcell and version |

### Stemcell Aliases

To make working with stemcells easier, there are a few aliases built in for stemcells,
so you don't need to remember/look up the full stemcell name for each architecture.
Currently, they're all set to use the Ubuntu versions of the stemcell, so if you
want CentOS, you'll need to specify the full name:

| Alias | Stemcell |
| ----- | -------- |
| aws | bosh-aws-xen-hvm-ubuntu-trusty-go_agent |
| azure | bosh-azure-hyperv-ubuntu-trusty-go_agent |
| hyperv | bosh-azure-hyperv-ubuntu-trusty-go_agent |
| openstack | bosh-openstack-kvm-ubuntu-trusty-go_agent |
| vcloud | bosh-vcloud-esxi-ubuntu-trusty-go_agent |
| vsphere | bosh-vsphere-esxi-ubuntu-trusty-go_agent |
| warden | bosh-warden-boshlite-ubuntu-trusty-go_agent |
| bosh-lite | bosh-warden-boshlite-ubuntu-trusty-go_agent |

### Version Keywords

Genesis allows you to specify some keywords for your release & stemcell
versions, and attempts to make life easier for you where it can. Here's a
run-down of the keywords, and how Genesis helps.

#### track

Specifying a version of `track` tells Genesis to fetch the latest version information
from the [Genesis Index][genesis-index] whenever it's building the manifest. This way you will always
get the latest version.

This keyword is mostly useful for keeping stemcells up-to-date, when not using the
`genesis ci` pipelines. When you use `genesis ci`, there is an automated task that
monitors stemcells and propagates upgrades to them through your infrastructure, using
explicit versions.

#### latest

This piggyback's on BOSH's `latest` version functionality. When specified, genesis
will simply pass this version on to BOSH, to let BOSH chose the latest uploaded
release/stemcell, and use that.

If the release/stemcell does not exist yet on BOSH, Genesis will contact the [Genesis Index][genesis-index]
and upload it for you, just-prior to deploying.

This keyword cannot be used with bosh-init style deployments.

#### x.y.z

If you specify a raw version (3262.12, 241, 1.2.3), Genesis will tell BOSH to use that
version explicitly. If you specify a sha1 and URL for the release/stemcell, BOSH will
include that when it does the deploy. If you do not specify the sha1 or URL, Genesis
will contact the [Genesis Index][genesis-index] to upload the release/stemcell,
just prior to deploy. For bosh-init deployments, instead of uploading the release/stemcell,
the sha1/url are saved to the local directory, since there isn't a BOSH to upload to.

#### The Genesis Index

The [Genesis Index][genesis-index] is a service designed to make managing releases and stemcells easier.
It watches new versions of common releases and stemcells, and updates the index with
their metadata. It is only contacted under the following circumstances:

- When generating manifests for each stemcell/release that specified `track` as its version
- When deploying a manifest which does not have a `sha1` or `url` attribute for a release/stemcell,
  unless that release/stemcell is already present with the correct version on the BOSH director
- When deploying a manifest which specifies `latest` as the version of a release/stemcell,
  and that stemcell/release is not already present on the BOSH director.

There is a wide range of commonly used releases already present in the [Genesis Index][genesis-index].
If you need additional releases, feel free to submit a GitHub issue on the [genesis-index repo][genesis-index].
If you have private releases that you wish to manage using the [Genesis Index][genesis-index], or cannot
contact the public [Genesis Index][genesis-index], you can run your own internally, and specify the `$GENESIS\_INDEX`
environment variable to override the default index.

[genesis-index]: http://github.com/starkandwayne/genesis-index
