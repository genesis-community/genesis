# TODO: Feature Bosh Configs

## Components

### Environment File

* [ ] Contains section `kit.scale` with one of the following values:
  * [ ] `dev` - suitable for development and testing
  * [ ] `lab` - suitable for internal organizational testing
  * [ ] `prod` - suitable for nominal production deployments
  * [ ] `xlprod` - suitable for large production deployments
  * [ ] *other* - must be specified in the `ops/other-cloud-config.yml` file - **expert level only**

* [ ] Contains section `bosh-configs` with the following keys:
  * [ ] cloud
    * [ ] networks - an array of network descriptions (director kits only)
      * [ ] name - the name of the arry (required)
      * [ ] type - the type of the network (default: manual)
      * [ ] subnets - an array of subnet descriptions  (Optional: if only one subnet is defined, it can be defined directly in the network)
        * [ ] az|azs - a singluar or list of availability zones (defaults to params.availability\_zones or meta.availability\_zones)
        * [ ] range - the range of the subnet in CIDR or range format (required or network.range if provided)
        * [ ] gateway - the gateway of the subnet (default: network.gateway or first IP in the subnet range)
        * [ ] dns - the DNS server of the subnet (default: params.dns)
        * [ ] available: a list of available IP addresses, in either CIDR or range format (default: all IPs in the range)
        * [ ] static - a list of reserved static IP addresses (default: none)
        * [ ] cloud\_properties - a hash of cloud-specific properties (default: depends on IaaS\*)

      * [ ] az|azs - a singluar or list of availability zones (defaults to params.availability\_zones or meta.availability\_zones)
      * [ ] range - the range of the network in CIDR or range format (required)
      * [ ] gateway - the gateway of the network (default: params.default\_gateway or first IP in the network range)
      * [ ] dns - the DNS server of the network (default: params.dns)
      * [ ] available: a list of available IP addresses, in either CIDR bits (/[bits], full CIDR, or range format (default: all IPs in the CIDR)
      * [ ] static: a scalar value expressed as a single integer (N static IPs, a percent of total IPs in the range, or an explicit range.  Can also be a list of specific ranges.  (default: 0)
      * [ ] cloud\_properties: a hash of cloud-specific properties (default: depends on IaaS\*)

    * [ ] vm\_types - an array of VM type descriptions - defaults to IaaS\* defaults per kit type and scale
    * [ ] disk\_types - an array of disk type descriptions - defaults to IaaS\* defaults per kit type and scale
    * [ ] vm\_extensions - an array of VM extension descriptions - defaults to IaaS\* defaults per kit type and scale
    * [ ] compilation - a compilation description (director kits only)
      * [ ] az|azs - a singluar or list of availability zones (defaults to params.availability\_zones or meta.availability\_zones)
      * [ ] workers - the number of compilation workers (default: based on `kit.scale` value)
      * [ ] network - the network to use for compilation (default: `compilation`)
      * [ ] vm\_type - the VM type to use for compilation (default: `compilation`))
      * [ ] reuse - whether to reuse existing VMs for compilation (default: false)
      * [ ] cloud\_properties - a hash of cloud-specific properties (default: depends on IaaS\*)


  * [ ] runtime - tbd
  * [ ] cpi - tbd
  * [ ] other? - tbd

#### NOTE:  We need to figure out how to separate the bosh-provides network
range from the bosh-lives-in network range.  This may require a new key/value
pair specifically for non-create-env bosh deployments.  If the range is the
full range as per some IaaS's, then the available block for a bosh network has
to specify the whole range available to it and everything it deploys.  We can
continue using the static count, or we can just use the bosh-cloud-config hook
for the kit to work around it, which now that I say that makes the most sense
becase that kit will also need to provide a could config for its deploying
bosh as well as a network map for it and what it deploys.

### BOSH Kit Hook: `bosh-configs`

This will be a script, initially accessible as an addon script, that will
utilize the `bosh-configs` section of the environment file to generate a
`cloud-config.yml` file that can be used to deploy a BOSH director.


### Exodus Data

There will be a new section in exodus data, under
`<exodus-mount>/<environment>/_network` that will contain the last
deployed cloud config network construction data.  This will be used to build
the network additively across the needs of various kits without requiring the
bosh deployment to know all the network needs of the kits, and without the
kits needing to know about the bosh network topology.  This will be
accomplished by a routine in `Genesis::Hook::BoshCloudConfig[1]` that can compare
what is already allocated and what changes are needed (additions, deletions,
shrinkage, or expansion) and compute the necessary range adjustments without
having to move or re-allocate existing VMs.

[1] This will initially be prototyped in `Genesis::Hook::Addon::BoshCloudConfigs`
    and then moved to `Genesis::Hook::BoshConfigs` when it is ready for
    general use.  If also may just go by ...::BoshConfigs if it is not
    specific to the cloud-config generation, but all bosh-configs in general.

### Genesis Hook:  `BoshCloudConfigs`

This will be a perl module that will supply the basic functionality for
building the cloud-config.yml file from the `bosh-configs` section of the
environment file combined with the existing exodus data and the kit cloud
config fragments.

Alternatively, the blueprint code could be used to generate the cloud-configs
as part of the manifest generation process, and then extracted from the
manifest using `--subset cloud-config` to be deployed up to the director.
This was the original plan, but it will remain to be seen if it is more useful
to leverage the existing manifest merge strategies (including secrets
validation, entombment, and un-pruned storage of entire scope of deployment vs
purpose-build explicit cloud config generation. 

The main challenge to this model is that the cloud config will need
transformation and calculations to be done that is not currently part of
spruce's abilities.  The possibility remains that both methods will be used,
with a pre-process step to generate the dynamic fragments based on the
bosh-configs section of the environment and the kit-specific cloud config
fragments, that will then be merged into the manifest and extracted for
deployment.

#### Workflow Possibilities and Issues

A) The cloud config is build by blueprint hook.

   Issues:
   - The check config hook runs before blueprint, and downloads the current
     cloud config (and runtime config) from the director.

B) The cloud config is built by the bosh-cloud-config hook.

   Issues:
   - The check config hook runs before the blueprint hook, so we can't
     directly reference things that will get merged in by the blueprint hook,
     such as default param values.

#### Possible Solutions

Since the kit is in control of both the fragments it provides and the hook
that will be used to build the cloud config, it would probably be best to
refactor the manifests fragments to isolate the params that can be used in
both the manifest and cloud config and have blueprint AND bosh-cloud-config
hooks merge them.  In this case, we'd use a partial-environment manifest and
then merge that with the bosh-cloud-config fragments to generate the
descriptions for the cloud-config.yml file(s), then return those fragments
back to the caller of check-config that can then be passed into the blueprint
hook to generate the actual cloud-config block in the manifest.  This allows
the end user to write explicit cloud-config blocks in the manifest that will
override the generated cloud-config.yml file, but still allows the generated
cloud-config to use the environment file as its source.

#### Generating the cloud-config.yml file

There are several places that the bosh-configs.cloud data cannot just be
merged with upstream fragments but has to be transformed or calculated.  These
include:

* Network section shortcuts on a per-network basis.  Each network block will
  need to have the following properties calculated:
  - `range` -- if this is expressed in just the /[bits] format, it will need
    to look in the existing network data in exodus to calculate its actual
    range based on what exists there currently.

  - `available` -- this needs to be converted to an exclusionary list of
    ranges that need to use cidr or range calculation to flip the provided
    CIDR range, hyphenated range or numbers.  It will also need the current
    upstream network data to figure out what is already allocated and what is
    available.  If expanding the range, it may have to draw from
    non-contiguous ranges (technically this is an added benefit not currently
    present in cc-me)

  - `static` -- this needs to be converted to an inclusionary list of ranges
    or numbers based on the available ranges.

  - Others???


The upstream exodus network data will need a locking mechanism so that two
deployments happening simultaneously do not try to allocate the same IP
addresses.  This will be done by having the bosh-cloud-config hook lock the
network data in the exodus data before it starts to calculate the new network
ranges, and then unlock it when it is done.  If the lock is already in place,
it will wait for the lock to be released before it continues or aborts if
there's a timeout.  If the lock is erroneously left in place, there will be a
manual unlock command that can be run to release the lock (TBD)


## Changes to Genesis

* [ ] Determine if bosh configs will be generated.  This can be done by one of
  the following three methods, in addition to the last one:
  - detecting the presence of the `bosh-configs` section in the environment file
  - having a `manage-bosh-configs` flag in the deployment config file for the
    bosh kit
  - detect minimum version of kit and environment that it meets or exceeds
    v3.1.0-rc.1
  - Furthermore, detecting presence of the network section in the exodus data
    for other kits deployed to that environment name.

* [ ] Expand the role of the `Genesis::Env::check_config` routine to include:
  * [ ] validating the `bosh-configs` section of the environment file
  * [ ] validating environment exodus data is compatible with the `bosh-configs`
  * [ ] validate there are no naming conflicts with different properties (ie
    two different `small` vm types with different cpu and memory values)
  * [ ] detect differences in cloud config network allocations and
    kit-specific non-network properties (vm\_types, disk\_types, etc) list
    them, and prompt for permission to update the cloud config or abort the
    deployment.
  * [ ] upload the cloud-config.yml to the director if there are any changes
    detected and the user has approved the changes.

* [ ] In the case of the BOSH kit, both the upstream director exodus network
  enviornment has to be consulted for its network range, as well as its own
  network environment, and then any changes to the former will have 

Note: Similar changes to check-secrets and check-stemcells where normally they
would abort on missing or conflicting entities are detected, should now prompt
for permition to rotate/add the missing secrets or upload the missing stemcells
to the director and continue the deployment.  This may be scoped to a
secondary work item, but should be considered if generalization of the above
code can be done to accomodate this.
