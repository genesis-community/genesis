Pipelines
=========

Concourse is an integral part of Genesis v2.  But rather than force operators
to define the full structure of a Concourse deployment pipeline (which can get
rather complex), we want to provide them a domain-specific language for
specifying their pipelines.

```
auto sandbox-*
auto preprod-*

sandbox-a -> sandbox-b
sandbox-b -> preprod-a
preprod-a -> preprod-b

preprod-b -> prod-a
prod-a    -> prod-b
```

We want to stay away from YAML for this one for a few reasons: (a) to avoid
the confusion of what gets merged with what, (b) to constrain the overall
pipeline structure to a single, small file, and (c) I haven't found a good
YAML structure for specifying the relationships that doesn't hurt my brain.

To wit, the pipeline language will need to be able to:

  - Identify the structure of the pipeline, explicitly and unambiguously.
  - Configure notifications for non-triggered deployments.
  - Configure the name of the pipeline.
  - Handle incomplete subsets of the deployment set.
  - Configure the Concourse endpoint for update operations.

## Propagation

The purpose of a pipeline is to test and vet configuration in less important
environments (sandbox, staging, pre-production) before attempting to deploy
them to more important environments (prod).

This can be handled directly by operations staff by manually controlling which
environments get changes and porting configuration changes between the
environments when deployments succeed, but we can do better.

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

That's a lot of files, and not all of them need to exist, but we do need to
nail down a specific and well-defined set of rules for dealing with change at
various levels.

(Keep in mind that what used to be `site/` lives in cloud-config and `global/`
is in our Genesis kits)

Now let's assume that we've configured our pipeline as follows:

```
foobar-aws-us1-preprod-east  ->   foobar-aws-us1-preprod-west
foobar-aws-us1-preprod-west  ->   foobar-aws-us1-prod-east
foobar-aws-us1-preprod-west  ->   foobar-aws-eu1-prod-east

foobar-aws-us1-prod-east     ->   foobar-aws-us1-prod-west

foobar-aws-eu1-prod-east     ->   foobar-aws-eu1-prod-west
```

Or, put more succinctly, deploy east followed by west, and the U.S.  preprod
environments lead to deployment of both U.S. and E.U. production.

Let's look at the `foobar-aws-us1-preprod-west`, which should trigger after
the east side.  When it does, Genesis needs to merge the following files:

  - foobar.yml
  - foobar-aws.yml
  - foobar-aws-us1.yml
  - foobar-aws-us1-preprod.yml
  - foobar-aws-us1-preprod-west.yml

All but the last file are shared with the east environment, and have been
vetted by the successful runs of the pipeline.  That means we can and should
use _that_ version, regardless of what has changed in the interim.

If that last sentence seems confusing, consider the effect that time may have
on the world.  Deployment in the east side could succeed on Monday, but be
delayed (either through failure, or because of required manual intervention) in
the west.  On Thursday, when the west side is deployed again, we want to
explicitly ensure that any intervening changes to common files are _not_
included, since those changes have not been vetted in the east.

This is where Genesis caching comes into play.

After a successful deployment of the east side, all of the intermediate files
used to generate that manifest will be cached in a special directory under
`.genesis/`.  Pipelines will be configured to watch the cached files shared by
any given environment and its immediate predecessor environment.  In this
case, that would be:

  - foobar.yml
  - foobar-aws.yml
  - foobar-aws-us1.yml
  - foobar-aws-us1-preprod.yml

`foobar-aws-us1-preprod-west.yml` of course, would be pulled from the main
area, as it cannot (by definition) be cached in any other environment.

To explore this method of caching, I've written `pipey`, which you can find in
the `bin/` directory of this repository.  Pipey takes two environment names
(`from` and `to`) and figures out which hypothetical files it should watch in
`from`'s cache, and which it should include directly.

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

## Configuration

There is a temptation to unify the BOSH manifest configuration with the
Concourse Pipeline manifest.  The authors fell victim to this temptation on
multiple occasions.  We must, however, resist as best we can, for a few key
reasons:

First, generating a pipeline configuration necessarily involves all
environments being pipelined.  If the configuration for the pipeline (i.e.
BOSH credentials, worker tags, etc.) is spread out across multiple files,
Genesis will have no recourse but to generate each and every manifest to put
the configuration "back together" and create the Concourse pipeline file.

This is problematic on two fronts.  It prolongs the process of pipeline
configuration, due to the additional work of parsing, merging and evaluating
all of those manifest files.  More severely, it places undue restrictions on
the Vault architecture chosen by the operations team.

Consider what happens when you have multiple disparate virtual private clouds,
and for security reasons, you wish to run a dedicated Vault in each, such that
Vault traffic need not transit the public Internet.  If you attempt to deploy
a single unified pipeline (perhaps utilizing remote Concourse workers), you
quickly run into the fact that you can't actually generate each environments
manifest from _outside_ of that environment.  How do you get to the Vault?

Instead, we should try to unify as much of the pipeline configuration into a
single, Spruce-merged configuration file.  We think it looks a little
something like this:

```
pipeline:
  name: redis-deployments
  git:
    owner: someco
    repo:  something-deployments
    private_key: (( vault "secret/concourse/git:private" ))

  notifications: parallel

  slack:
    channel: '#botspam'
    webhook: (( vault "secret/concourse/slack:webhook" ))

  email:
    stanza: here

  vault:
    url:    https://127.0.0.1:8200
    verify: yes

  locker:
    

  boshes:
    sandbox:
      alias:    sb # Optional
      url:      https://sandbox.example.com:25555
      ca_cert:  (( vault "secret/bosh/sandbox/ssl/ca:certificate" ))
      username: sb-admin
      password: (( vault "secret/bosh/sandbox/admin:password" ))

    preprod:
      url:      https://preprod.example.com:25555
      ca_cert:  (( vault "secret/bosh/preprod/ssl/ca:certificate" ))
      username: pp-admin
      password: (( vault "secret/bosh/preprod/admin:password" ))

    prod:
      url:      https://prod.example.com:25555
      ca_cert:  (( vault "secret/bosh/prod/ssl/ca:certificate" ))
      username: pr-admin
      password: (( vault "secret/bosh/prod/admin:password" ))

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

  groups:
    default:
    - sandbox
    - preprod
    - prod

    onprem1:
    - on-prem-1-sandbox
    - on-prem-1-preprod
    - on-prem-1-prod

    onprem2:
    - on-prem-2-sandbox
    - on-prem-2-preprod
    - on-prem-2-prod
```

### Schema

#### Pipeline YAML Field Guide

- **pipeline.name** - The name of your pipeline, as displayed in Concourse
  (i.e. 'redis-deployments').  This setting is **required**.

- **pipeline.public** - Whether or not the pipeline is visible to everyone.
  Setting this to `yes` will make the Concourse pipeline (and all logs related
  to deployments) public.  This is off by default.

- **pipeline.tagged** - Whether or not the Concourse pipeline configuration
  uses tags on each job, for use in multi-site, distributed Concourse
  implementations.  This is off by default, and if you don't know why you
  would need it, you don't need it.

- **pipeline.unredacted** - Whether or not deployment output will be redacted
  when run in the pipeline.  This is off by default.  If you set it to 'yes',
  the `genesis deploy` output in pipeline build logs will be unredacted,
  showing you all of the changes that are taking place, including any changes
  in potentially sensitive credentials.

- **pipeline.debug** - Turns on debug output when set to a YAML truthy value.
  Defaults to false.

- **pipeline.smoke-tests** - The name of the BOSH smoke test errand to run
  after a successful deployment / upgrade.  If not specified, no smoke
  testing will be carried out.

#### Secrets

- **pipeline.vault.url** - The URL of your Vault installation, i.e.
  `https://vault.example.com`.  This is **required**.

- **pipeline.vault.role** - The AppRole GUID of a given Vault AppRole, used to
  generate temporary tokens for Vault-accessing during deploys. This field is
  optional, provided that the `setup-approle` Genesis addon was executed on
  the targeted Concourse. If you'd prefer to manage your own AppRole and
  policy, you may fill out this field.

- **pipeline.vault.secret** - The secret key GUID of a given Vault AppRole,
  used to authenticate the AppRole to vault. Like the above field, it is
  optional provided that the `setup-approle` addon was executed on the
  targeted Concourse. If you'd prefer to manage your own AppRole and policy,
  you may fill out this field.

- **pipeline.vault.verify** - Instruct Concourse to validate the Vault TLS
  certificate (if using `https://` for your Vault).  This is on by default,
  and you probably don't want to change it.

- **pipeline.vault.namespace** - If using Enterprise Vault, you will need to
  specify the desired namespace using this parameter.

- **pipeline.vault.no-strongbox** - Set this to false to connect with Vault
  deployments not based on the Genesis Vault kit, which uses Strongbox to
  facilitate.  Defaults to true.

#### Git Integration

- **pipeline.git.host** - The hostname of Github.  Useful for on-premise,
  Enterprise Github installations.  Defaults to `github.com`.

- **pipeline.git.owner** - The name of the user or organization who owns the
  Genesis deployment repository, in Github.  This is **required**.

- **pipeline.git.repo** - The name of the Genesis deployment repository, in
  Github.  This is **required**.

- **pipeline.git.private_key** - The private component (i.e.  `----BEGIN RSA
  PRIVATE KEY--- ...`) of the SSH Deployment Key for this repository, in
  Github.  Since the pipeline will push to the repository, this key needs to
  be installed in the Github web interface with the `Allow write access` box
  checked. This is **required** if connecting to git via ssh.

- **pipeline.git.username** - The username for connecting to git.  This is
  **required** if connecting via https.

- **pipeline.git.password** - The password for connecting to git.  This is
  **required** if connecting via https.

- **pipeline.git.commits.user\_name** - Specify the user name for commits
  performed by the pipeline.  Defaults to `Concourse Bot`.

- **pipeline.git.commits.user\_email** - Specify the user email for commits
  performed by the pipeline.  Defaults to `concourse@pipeline`.

- **pipeline.git.config** - This is a map of parameters for all the
  `git_resource` resource types used by the pipeline.  This is used to specify
  check times, web_hooks, icons or anything else that could be configured for
  a resource.  See [Concourse-CI Resource](https://concourse-ci.org/resources.html) for details.

#### Locker Integration

Enable Locker to prevent deploying to a BOSH director that is in the middle of
being deployed, or vice versa.

- **pipeline.locker.url** - The URL for the Locker server.  This is **required**.

- **pipeline.locker.username** - The username for the Locker server.  This is
  **required**.

- **pipeline.locker.password** - The password for the Locker server.  This is
  **required**.

- **pipeline.locker.skip\_ssl\_validation** - Set to `false` to validate SSL
  against the given ca\_cert.  Defaults to `true`.

- **pipeline.locker.ca\_cert** - The CA Certificate for the Locker server,
  used for SSL validation.  Defaults to `null` - required if
  `skip_ssl_validation` is false.

#### Auto-Update Genesis Assets

- **pipeline.auto-update.file** - This is the name of the file containing the
  `kit.version` value to propagate through the environments.  It is usually
  the highest hierarchical file, but can be lower.  For example, if your
  environments follow the pattern of `<corpname>-<iaas>-<region>-<purpose>.yml`,
  then it is recommended that you put the `kit.name` and `kit.version` in
  `<corpname>.yml`.  Be sure to remove the kit.name/version from the lower
  environment, or the version won't propagate.

- **pipeline.auto-update.kit** - Specify the kit being updated.  This is
  automatically determined by the content of the deployment repo, but may need
  to be specified explicitly if the repo contains more than one kit.

- **pipeline.auto-update.org** - Specify the git org that contains the kit.
  This is automatically determined by the content of the deployment repo, but
  can be specified explicitly if it cannot be determined.

- **pipeline.auto-update.api\_url** - Specify the API URL for the git server
  that holds the kit releases.  This is usually automatically determined by
  the deployment repo's kit provider configuration, but can be explicitly
  specified if it cannot be determined.

- **pipeline.auto-update.auth\_token** - While optional, specifying the
  `auth_token` can prevent throttling when checking or fetching releases.  If
  using Github as the kit provider, you only have to specify `auth_token`;
  however if you have a different git provider for the kit (such as an
  internal Enterprise Github), you can specify the auth tokens separately as
  `kit_auth_token` and `github_auth_token`.

- **pipeline.auto-update.label** - Specify a label for the commit message when
  updating the deployment repo with kit and genesis assets.  Defaults to
  `concourse`

#### Notifications

- **pipeline.notifications** - Determines how notifications for pending manual
  jobs are handles.  Defaults to `inline`, which puts the notification job
  between the completion of the proceeding job and the manual job.  The
  alternative values of `parallel` and `grouped` both put the notification
  task in parallel to the manual job, meaning the notification does not have
  to complete before being able to trigger the manual job.  The difference
  between the two is presentation: `parallel` puts the notification in the
  same column on the same page as the manual deployment (above or below
  depending on the name of the deployment job), while `grouped` puts the
  notifications in a different group page names `notifications`.

##### Notification: Slack
- **pipeline.slack.webhook** - The Slack Integration WebHook URL, provided by
  Slack when you configure a new integration.  This is **required**.

- **pipeline.slack.channel** - The name of the channel (`#channel`) or user
  (`@user`) who will receive Slack notifications.  This is **required** if you
  wish to use Slack for notifications.

- **pipeline.slack.username** - The username to use when posting notifications
  to Slack.  Defaults to `runwaybot`.

- **pipeline.slack.icon** - URL of an image to use as the avatar / profile
  picture when posting notifications to Slack.  Defaults to an
  airplane-looking thing.

##### Notification: Email
- **pipeline.email.to** - A list of email addresses to send notifications to.
  This is **required** if you wish to use email for notification.

- **pipeline.email.from** - An email address from which to send notification
  emails.  This is **required**.

- **pipeline.email.smtp.host** - The IP address or FQDN of the SMTP relay /
  mail server to send email through.  This is **required**.

- **pipeline.email.smtp.port** - The SMTP port that the relay / mail server
  listens on for mail submission.  Defaults to the standard mail submission
  port, `587` (**not** `25`).

- **pipeline.email.smtp.username** - The username to authenticate to the SMTP
  relay / mail server as.  This is **required**.  Anonymous relays are not
  supported, as they are harmful to the Internet.

- **pipeline.email.smtp.password** - The password to use when authenticating
  to the SMTP relay / mail server.  This is **required**.

#### BOSH Associations

- **pipeline.boshes** - The `pipeline.boshes` map allows you to specify the
  connectivity parameters of the BOSH Director to which the specified
  environment is deployed to.  In normal circumstances, this will be the BOSH
  director with the same name as the environment being deployed, so it is easy
  to confuse the keys under this map as the name of the BOSH environment
  instead.

  However, in the case of **deploying BOSH kit environments**, you will
  want to specify the parent BOSH director's connection details under the name
  of the environment _being deployed_, not the name of the BOSH director
  _being deployed to_.  Furthermore, if the BOSH being deployed is a
  proto-BOSH (aka one deployed with create-env), the map under the environment
  name should be empty, but it must be there.

- **pipeline.boshes.&lt;env-name&gt;.url** - The URL to the BOSH director API
  (i.e. what you would normally `bosh target`).  Each environment to be
  deployed via the pipeline **must** have one of these set.

- **pipeline.boshes.&lt;env-name&gt;.alias** - An optional alias to use in the
  concourse pipeline, when generating job names, and resource names, in case
  your bosh **env-name** is rather long.  If not specified, the **env-name**
  will be used.

- **pipeline.boshes.&lt;env-name&gt;.ca\_cert** - The CA Certificate of the
  BOSH director. This is **required**.

- **pipeline.boshes.&lt;env-name&gt;.username** - The username to use when
  authenticating to this BOSH director.  This is **required**.

- **pipeline.boshes.&lt;env-name&gt;.password** - The password for the
  configured BOSH user account.  This is **required**.


#### Task Configuration

- **pipeline.task.image** - The name of the Docker image to use for running
  tasks.  This defaults to `starkandwayne/concourse`, and you are highly
  encouraged _not_ to change it without good reason.

- **pipeline.task.version** - The version of the Docker image to use for
  running tasks.  This defaults to `latest`, which should work well for most
  implementations.

- **pipeline.task.privileged** - A list of environments that require the
  bosh-deployment tasks to be run in privileged mode.  Defaults to empty list.

#### Groups

- pipeline.groups - Groups jobs together under a header and show them on
  different tabs in the user interface. It does not change functionality of
  the pipeline.

#### Pipeline Override Configuration

If you need to edit and make changes to your deployment pipeline, simply add
the changes you need to the bottom of your ci.yml located in your
*-deployments repo. For example, if we have a pipeline we need to edit the
'check_every:' parameter of a resource named git we can add the block below
under our pipeline layouts:

**ci.yml**
```
layouts:
  test-sandbox-ops: |+
    auto *test-sandbox *test-staging
    test-sandbox -> test-staging

resources:
- name: git
  check_every: 15m
```
