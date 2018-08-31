Pipelines
=========

Concourse is an integral part of Genesis v2.  But rather than
force operators to define the full structure of a Concourse
deployment pipeline (which can get rather complex), we want to
provide them a domain-specific language for specifying their
pipelines.

```
auto sandbox-*
auto preprod-*

sandbox-a -> sandbox-b
sandbox-b -> preprod-a
preprod-a -> preprod-b

preprod-b -> prod-a
prod-a    -> prod-b
```

We want to stay away from YAML for this one for a few reasons: (a)
to avoid the confusion of what gets merged with what, (b) to
constrain the overall pipeline structure to a single, small file,
and (c) I haven't found a good YAML structure for specifying the
relationships that doesn't hurt my brain.

To wit, the pipeline language will need to be able to:

  - Identify the structure of the pipeline, explicitly and
    unambiguously.
  - Configure notifications for non-triggered deployments.
  - Configure the name of the pipeline.
  - Handle incomplete subsets of the deployment set.
  - Configure the Concourse endpoint for update operations.

### Propagation

The purpose of a pipeline is to test and vet configuration in less
important environments (sandbox, staging, pre-production) before
attempting to deploy them to more important environments (prod).

This can be handled directly by operations staff by manually
controlling which environments get changes and porting
configuration changes between the environments when deployments
succeed, but we can do better.

Consider the following files:

  - foobar.yml
  - foobar-aws.yml
  - foobar-aws-us1.yml
  - foobar-aws-us1-preprod.yml
  - foobar-aws-us1-preprod-east.yml \*
  - foobar-aws-us1-preprod-west.yml \*
  - foobar-aws-us1-prod.yml
  - foobar-aws-us1-prod-east.yml \*
  - foobar-aws-us1-prod-west.yml \*
  - foobar-aws-eu1.yml
  - foobar-aws-eu1-prod.yml
  - foobar-aws-eu1-prod-east.yml \*
  - foobar-aws-eu1-prod-west.yml \*

That's a lot of files, and not all of them need to exist, but we
do need to nail down a specific and well-defined set of rules for
dealing with change at various levels.

(Keep in mind that what used to be `site/` lives in cloud-config
and `global/` is in our Genesis kits)

Now let's assume that we've configured our pipeline as follows:

```
foobar-aws-us1-preprod-east  ->   foobar-aws-us1-preprod-west
foobar-aws-us1-preprod-west  ->   foobar-aws-us1-prod-east
foobar-aws-us1-preprod-west  ->   foobar-aws-eu1-prod-east

foobar-aws-us1-prod-east     ->   foobar-aws-us1-prod-west

foobar-aws-eu1-prod-east     ->   foobar-aws-eu1-prod-west
```

Or, put more succintly, deploy east followed by west, and the U.S.
preprod environments lead to deployment of both U.S. and E.U.
production.

Let's look at the `foobar-aws-us1-preprod-west`, which should
trigger after the east side.  When it does, Genesis needs to merge
the following files:

  - foobar.yml
  - foobar-aws.yml
  - foobar-aws-us1.yml
  - foobar-aws-us1-preprod.yml
  - foobar-aws-us1-preprod-west.yml

All but the last file are shared with the east environment, and
have been vetted by the successful runs of the pipeline.  That
means we can and should use _that_ version, regardless of what has
changed in the interim.

If that last sentence seems confusing, consider the effect that
time may have on the world.  Deployment in the east side could
succeed on Monday, but be delayed (either through failure, or
because of required manual intervation) in the west.  On Thursday,
when the west side is deployed again, we want to explicitly ensure
that any intervening changes to common files are _not_ included,
since those changes have not been vetted in the east.

This is where Genesis caching comes into play.

After a successful deployment of the east side, all of the
intermediate files used to generate that manifest will be cached
in a special directory under `.genesis/`.  Pipelines will be
configured to watch the cached files shared by any given
environment and its immediate predecessor environment.  In this
case, that would be:

  - foobar.yml
  - foobar-aws.yml
  - foobar-aws-us1.yml
  - foobar-aws-us1-preprod.yml

`foobar-aws-us1-preprod-west.yml` of course, would be pulled from
the main area, as it cannot (by definition) be cached in any other
environment.

To explore this method of caching, I've written `pipey`, which you
can find in the `bin/` directory of this repository.  Pipey takes
two environment names (`from` and `to`) and figures out which
hypothetical files it should watch in `from`'s cache, and which it
should include directly.

Here are some example runs.

East-to-West propagation within the same region and environment:
```
pipeline progression
  from [foobar-aws-us1-preprod-east]
    to [foobar-aws-us1-preprod-west]

CACHED foobar.yml                       (from .genesis/cached/foobar-aws-us1-preprod-east/foobar.yml)
CACHED foobar-aws.yml                   (from .genesis/cached/foobar-aws-us1-preprod-east/foobar-aws.yml)
CACHED foobar-aws-us1.yml               (from .genesis/cached/foobar-aws-us1-preprod-east/foobar-aws-us1.yml)
CACHED foobar-aws-us1-preprod.yml       (from .genesis/cached/foobar-aws-us1-preprod-east/foobar-aws-us1-preprod.yml)
DIRECT foobar-aws-us1-preprod-west.yml
```

Triggering prod in the same region:
```
pipeline progression
  from [foobar-aws-us1-preprod-west]
    to [foobar-aws-us1-prod-east]

CACHED foobar.yml                       (from .genesis/cached/foobar-aws-us1-preprod-west/foobar.yml)
CACHED foobar-aws.yml                   (from .genesis/cached/foobar-aws-us1-preprod-west/foobar-aws.yml)
CACHED foobar-aws-us1.yml               (from .genesis/cached/foobar-aws-us1-preprod-west/foobar-aws-us1.yml)
DIRECT foobar-aws-us1-prod.yml
DIRECT foobar-aws-us1-prod-east.yml
```

Triggering prod in a different region:
```
pipeline progression
  from [foobar-aws-us1-preprod-west]
    to [foobar-aws-eu1-prod-east]

CACHED foobar.yml                       (from .genesis/cached/foobar-aws-us1-preprod-west/foobar.yml)
CACHED foobar-aws.yml                   (from .genesis/cached/foobar-aws-us1-preprod-west/foobar-aws.yml)
DIRECT foobar-aws-eu1.yml
DIRECT foobar-aws-eu1-prod.yml
DIRECT foobar-aws-eu1-prod-east.yml
```

### Configuration

There is a temptation to unify the BOSH manifest configuration
with the Concourse Pipeline manifest.  The authors fell victim to
this temptation on multiple occasions.  We must, however, resist
as best we can, for a few key reasons:

First, generating a pipeline configuration necessarily involves
all environments being pipelined.  If the configuration for the
pipeline (i.e. BOSH credentials, worker tags, etc.) is spread out
across multiple files, Genesis will have no recourse but to
generate each and every manifest to put the configuration "back
together" and create the Concourse pipeline file.

This is problematic on two fronts.  It prolongs the process of
pipeline configuration, due to the additional work of parsing,
merging and evaluating all of those manifest files.  More
severely, it places undue restrictions on the Vault architecture
chosen by the operations team.

Consider what happens when you have multiple disparate virtual
private clouds, and for security reasons, you wish to run a
dedicated Vault in each, such that Vault traffic need not transit
the public Internet.  If you attempt to deploy a single unified
pipeline (perhaps utilizing remote Concourse workers), you quickly
run into the fact that you can't actually generate each
environments manifest from _outside_ of that environment.  How
do you get to the Vault?

Instead, we should try to unify as much of the pipeline
configuration into a single, Spruce-merged configuration file.
We think it looks a little something like this:

```
pipeline:
  name: redis-deployments
  git:
    owner: someco
    repo:  something-deployments
    private_key: (( vault "secret/concourse/git:private" ))

  slack:
    channel: '#botspam'
    webhook: (( vault "secret/concourse/slack:webhook" ))

  email:
    stanza: here

  vault:
    secret: this-is-a-super-secret
    role:   this-is-a-vault-app-role
    url:    https://127.0.0.1:8200
    verify: yes

  stemcells:
    bosh-lite: bosh-warden-boshlite-ubuntu-trusty-go_agent
    aws: bosh-aws-xen-hvm-ubuntu-trusty-go_agent

  boshes:
    sandbox:
      alias:    sb # Optional
      url:      https://sandbox.example.com:25555
      ca_cert:  (( vault "secret/bosh/sandbox/ssl/ca:certificate" ))
      username: sb-admin
      password: (( vault "secret/bosh/sandbox/admin:password" ))
      stemcells:
      - bosh-lite

    preprod:
      url:      https://preprod.example.com:25555
      ca_cert:  (( vault "secret/bosh/preprod/ssl/ca:certificate" ))
      username: pp-admin
      password: (( vault "secret/bosh/preprod/admin:password" ))
      stemcells:
      - aws

    prod:
      url:      https://prod.example.com:25555
      ca_cert:  (( vault "secret/bosh/prod/ssl/ca:certificate" ))
      username: pr-admin
      password: (( vault "secret/bosh/prod/admin:password" ))
      stemcells:
      - aws

  smoke-tests: run-my-smoke-tests
  tagged: yes

  layouts:
    # genesis repipe                 ; if target is 'default'
    # genesis repipe -t azure        ; if target is 'azure' instead
    default: |+
      auto *sandbox *preprod
      sandbox -> preprod -> prod

    # genesis repipe onprem          ; if target is 'onprem'
    # genesis repipe -t ci onprem    ; if it is 'ci' instead
    onprem: |+
      auto *sandbox *preprod
      on-prem-1-sandbox -> on-prem-1-preprod -> on-prem-1-prod
      on-prem-2-sandbox -> on-prem-2-preprod -> on-prem-2-prod
```

### Pipeline YAML Field Guide

- **pipeline.name** - The name of your pipeline, as displayed in
  Concourse (i.e. 'redis-deployments').  This setting is
  **required**.

- **pipeline.public** - Whether or not the pipeline is visible to
  everyone.  Setting this to `yes` will make the Concourse
  pipeline (and all logs related to deployments) public.
  This is off by default.

- **pipeline.tagged** - Whether or not the Concourse pipeline
  configuration uses tags on each job, for use in multi-site,
  distributed Concourse implementations.  This is off by default,
  and if you don't know why you would need it, you don't need it.

- **pipeline.unredacted** - Whether or not deployment output will
  be redacted when run in the pipeline.  This is off by default.
  If you set it to 'yes', the `genesis deploy` output in pipeline
  build logs will be unredacted, showing you all of the changes
  that are taking place, including any changes in potentially
  sensitive credentials.

- **pipeline.smoke-tests** - The name of the BOSH smoke test
  errand to run after a successsful deployment / upgrade.  If not
  specified, no smoke testing will be carried out.

- **pipeline.skip_upkeep** - If set, disables the automatic
  stemcell updating behavior of the pipeline.

- **pipeline.stemcells** - A map of stemcell alias to stemcell
  name. This configures what stemcells are tracking new releases.
  The `alias` is used for abbreviating stemcell name display in
  the Concourse UI, as well as in `ci.yml`. The name, must match
  an official BOSH stemcell name found on https://bosh.io/stemcells.

- **pipeline.vault.url** - The URL of your Vault installation,
  i.e. `https://vault.example.com`.  This is **required**.

- **pipeline.vault.role** - The AppRole GUID of a given Vault
  AppRole, used to generate temporary tokens for Vault accessing
  during deploys. This is **required**.

- **pipeline.vault.secret** - The secret key GUID of a given Vault
  AppRole, used to authenticate the AppRole to vault. This is
  **required**.

- **pipeline.vault.verify** - Instruct Concourse to validate the
  Vault TLS certificate (if using `https://` for your Vault).
  This is on by default, and you probably don't want to change it.

- **pipeline.git.host** - The hostname of Github.  Useful for
  on-premise, Enterprise Github installations.  Defaults to
  `github.com`.

- **pipeline.git.owner** - The name of the user or organization
  who owns the Genesis deployment repository, in Github.  This is
  **required**.

- **pipeline.git.repo** - The name of the Genesis deployment
  repository, in Github.  This is **required**.

- **pipeline.git.private_key** - The private component (i.e.
  `----BEGIN RSA PRIVATE KEY--- ...`) of the SSH Deployment Key
  for this repository, in Github.  Since the pipeline will push to
  the repository, this key needs to be installed in the Github web
  interface with the `Allow write access` box checked.

- **pipeline.slack.webhook** - The Slack Integration WebHook URL,
  provided by Slack when you configure a new integration.  This is
  **required**.

- **pipeline.slack.channel** - The name of the channel
  (`#channel`) or user (`@user`) who will receive Slack
  notifications.  This is **required** if you wish to use Slack
  for notifications.

- **pipeline.slack.username** - The username to use when posting
  notifications to Slack.  Defaults to `runwaybot`.

- **pipeline.slack.icon** - URL of an image to use as the avatar /
  profile picture when posting notifications to Slack.  Defaults
  to an airplane-looking thing.

- **pipeline.stride.client_id** - The Client ID of the Stride app that
  you would like to post notifications as. **required**.

- **pipeline.stride.client_secret** - The Client Secret of the Stride app
  that you would like to post notifications as. **required**.

- **pipeline.stride.cloud_id** - The ID of the Stride cloud that you would like
  to post to. **required**.

- **pipeline.stride.conversation** - Name of the stride conversation (channel)
  that you would like notifications to go to. **required**

- **pipeline.email.to** - A list of email addresses to send
  notifications to.  This is **required** if you wish to use email
  for notification.

- **pipeline.email.from** - An email address from which to send
  notification emails.  This is **required**.

- **pipeline.email.smtp.host** - The IP address or FQDN of the
  SMTP relay / mail server to send email through.  This is
  **required**.

- **pipeline.email.smtp.port** - The SMTP port that the relay /
  mail server listens on for mail submission.  Defaults to the
  standard mail submission port, `587` (**not** `25`).

- **pipeline.email.smtp.username** - The username to authenticate
  to the SMTP relay / mail server as.  This is **required**.
  Anonymous relays are not supported, as they are harmful to the
  Internet.

- **pipeline.email.smtp.password** - The password to use when
  authenticating to the SMTP relay / mail server.  This is
  **required**.

- **pipeline.boshes.&lt;env-name&gt;.url** - The URL to the BOSH
  director API (i.e. what you would normally `bosh target`).
  Each environment to be deployed via the pipeline **must** have
  one of these set.

- **pipeline.boshes.&lt;env-name&gt;.alias** - An optional alias
  to use in the concourse pipeline, when generating job names, and
  resource names, in case your bosh **env-name** is rather long.
  If not specified, the **env-name** will be used.

- **pipeline.boshes.&lt;env-name&gt;.ca_cert** - The CA Certificate
  of the BOSH director. This is **required**.

- **pipeline.boshes.&lt;env-name&gt;.username** - The username to
  use when authenticating to this BOSH director.  This is
  **required**.

- **pipeline.boshes.&lt;env-name&gt;.password** - The password for
  the configured BOSH user account.  This is **required**.

- **pipeline.boshes.&lt;env-name&gt;.stemcells** - A list of stemcell
  aliases that this environment will require. Genesis will automatically
  upload new versions of these stemcells as they come out, triggering
  new deployments, or notify you of the pending changes, in the case of
  manual deployments. This list must be present, unless
  `pipeline.skip_upkeep` is set. If you wish to have the pipeline manage
  stemcells for one environment, but not another, you may set this to an
  empty array.

- **pipeline.task.image** - The name of the Docker image to use
  for running tasks.  This defaults to `starkandwayne/concourse`,
  and you are highly encouraged _not_ to change it without good
  reason.

- **pipeline.task.version** - The version of the Docker image to
  use for running tasks.  This defaults to `latest`, which should
  work well for most implementations.
