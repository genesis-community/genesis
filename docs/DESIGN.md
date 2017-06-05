Design Notes
============

## Motivating Factors

This project is an attempt to build a better version of the
Genesis software for BOSH deployment management, using lessons
learned from real client environments, lifecycle events and
training / pairing sessions.

The stated goals of this project are to:

  1. Support BOSH v2 cloud-config as a first-class concept
  2. Provide a smoother, less labor-intensive upgrade experience
  3. Facillitate a less hands-on approach to BOSH releases

The overall timbre of these goals should be interpreted as:

> Make The Ops Team's Life Easier

## Problems Identified with Genesis v1

Genesis v1 gave us a lot of good stuff.  We're not going to focus
on that; instead, here's the bad:

**People were confused by all the different files.**  There was
often a question of why a given property went into
`credentials.yml` instead of `properties.yml`, why the BOSH
deployments had a `cloudfoundry.yml`, etc.  Given that Genesis
generated lots of completely empty files, with little hint or
direction of what went where (aside from README files that
literally no one read), this confusion is understandable.

In practice, most of these files were either left empty, or were
very small.(less than 40 lines).  The need for multiple "topical"
files was grossly skewed by the needs of Cloud Foundry
deployments.

**The potential for same-level override confusion was high.**
Because of the multiple different files at each level, it was
possible to (accidentally or purposefully) set the same properties
to different values, leading to perplexing override situations.

For example, if a property was set in `properties.yml`, it could
be reliably overridden in `name.yml`, at the environment level.
This lead to situations where the property was changed in the
first file, without affecting the final manifest.  This surprising
behavior should not be possible.

**Files in global/ were often not portable.**  Whether because of
client need, or legacy / pedigree / history (i.e. migration),
global template files were not easily ported across clients.  GE
and Ford are prime examples - changes have been made to global
templates to facilitate client needs in both cases, making them
mutually irreconcilable for future reuse.

**Use of &lt;release&gt;/ and stemcell/ caused confusion and didn't pan
out for their intended use.**  Initially, we used the "small
files" approach to specifying stemcell and release versions so
that we could take advantage of the bosh-io-release and
bosh-io-stemcell Concourse resources.  Prevailing thought at the
time was the pipelines were going to attempt to constantly upgrade
releases as point-revisions were cut, and that new stemcells would
be rolled out automatically.

In practice, meaningful release upgrades invariably brought
manifest changes, including property renames / reorganization, and
sometimes entirely new jobs into the picture.  It was impossible
(or at least infeasible) to automate these changes, so release
upgrades were performed manually (aided by the pipeline).

Stemcell upgrades _should_ be fully orthogonal to the releases,
and with a few notable exceptions (mainly, garden-\* and kernel
versions), they are.  However, several clients were hesitant to
automatically roll new stemcells without testing for security
issues, compliance problems and loss of functionality, above and
beyond bundled smoke tests.  This again because a mostly manual
process.

**Support for "best practices" like Vault and Concourse was
spotty.**  Ford is perfectly happy doing manual deployments, and
the pain of moving over to Concourse is diminishing the desire to
do so.  It's a relative gains kind of thing -- what they had
before Genesis (v1) was terrible; Genesis made it 10x better.
Concourse will only make _that_ 2x better, so why bother?

**Pipeline structure was rigid.**  If your chain of deployments
didn't match the alpha -> beta -> remainder formula baked into
Genesis v1, you were pretty much on your own.  This made it
impossible to chain more than 3 "levels" deep on the approval /
passed=true logic.  Put another way, alpha -> sandbox -> preprod
-> prod was not possible.

## Big Changes

The structure of a Genesis deployment is:

```
whatever-deployments/
  .genesis/
    config
    bin/
      genesis
    cache/
      foobar-azure-us-east-sandbox
      foobar-azure-us-east-preprod
    kits/
      whatever-1.2.1.kit
      whatever-1.2.3.kit
  foobar.yml
  foobar-azure-us.yml
  foobar-azure-us-east-sandbox.yml
  foobar-azure-us-east-preprod.yml

  manifests/
    foobar-azure-us-east-sandbox.yml
    foobar-azure-us-east-preprod.yml
```

A few things to note:

**Housekeeping bits go into .genesis/.**  Instead of having lots
of dot-files sitting around at the top-level (i.e. `.env_hooks`,
`.deployment`, etc.), we have one `.genesis/` directory that
contains all the "behind-the-scenes" magic.  This includes a
config file for housing any specific flags and parameters we need
to track / honor (should we go to the Genesis Index?  use an
internal one?).  The `bin/` directory is where we embed genesis.
The `cache/` directory houses our cached YAML files for each
environment, so that we can faithfully handle multiple update
flows.  The `kits/` directory houses Genesis Kits (more on that
later).

**The site and environment directory structure is gone**.  BOSH
cloud-config handles 95% of what we put in the site-level anyway.

**Each deployment is specified in a single file**.  For example,
`foobar-azure-us-east-preprod.yml` defines all the overrides and
specialization for the us-east preprod environment in Azure.  This
eliminates the multi-file confusion and "what goes where"
questions.

**Multiple levels of commonality are handled via `spruce merge`
and prefix matching.**  When generating the manifest for a given
environment, Genesis v2 will treat the file name as a hyphenated
list of name components, and attempt to merge each found prefix
file, in order of least specific to most specific.

Here's an example.  To generate the manifest for
`foobar-azure-us-east-preprod`, Genesis would look at the following
files, in order:

  1. foobar.yml
  2. foobar-azure.yml (which does not exist in our example)
  3. foobar-azure-us.yml
  4. foobar-azure-us-east.yml (again, not extant)
  4. foobar-azure-us-east-preprod.yml

This allows configuration affecting all Ford sites to live in
`foobar.yml`, but still be overridden by the site (foobar-azure-us)
and environment levels.  Allowing arbitrary numbers of levels
affoobars us more flexibility than the global/site/env convention of
Genesis v1.

**global/ has been replaced by Genesis Kits**.  Global is where
most of our configuration normally lives.  For Genesis v2, we want
to bundle up these files and distribute them as a separate
artifact, the outcome of a process of _release engineering_,
whereby Stark & Wayne consultants determine the best practices for
deploying BOSH releases, and codify those best practices using
judicious use of Spruce, Vault and some custom glue scripts.

Unlike Genesis v1 deployment templates, Genesis v2 Kits are
versioned, and distributed as opaque archives.  Really, these are
gzipped (or xz'd) tarballs that will be expanded for merges.  The
salient point is that these are **opaque** and **versioned**.

By being opaque, client operators will avoid modifying them,
helping to ensure that they do not deviate from the vision of
Stark & Wayne, and essentially fork the kit at the espense of
future upgrades.

Versioning these kits means CI pipelines and release notes.
Having a CI pipeline that is controlling the official releases
allows us to inject whatever method of testing we want to, and
have that automated for every commit.  Hopefully, these tests will
vet our Kits for various scenarios like "a new deployment should
succeed" and "upgrades from v1.4 to v1.5 work ok".  Making the
release process explicit will also force us to write release
notes, and better documentation on how to use the kits.

**Final BOSH manifests live under manifests/**. Since we have no
directory structure to speak of, the manifests have to live
somewhere.  These manifests will be _sabotaged_ so that they
cannot easily be used to directly deploy via BOSH.  This lets us
reap the benefit of having a commited manifest, without running
the risk of someone attempting to circumvent the merge structure.
In the case of Vaultified deployments, such activity is incredibly
harmful.

