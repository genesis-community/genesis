# Multi-File Configuration

The multi-file configuration format splits pipeline configuration across
several files in a `.genesis/ci/` directory. This format is used by the
compiler pipeline (activated with `--platform`) and provides a cleaner
separation of concerns than the monolithic `ci.yml`.

When you run `genesis repipe --platform concourse`, the system checks for
`.genesis/ci/` first. If that directory exists and contains a `pipeline.yml`,
it uses the multi-file format. Otherwise it falls back to reading `ci.yml`
in the legacy format.

## Directory Structure

```
.genesis/ci/
  pipeline.yml         # Required - metadata, branches, workflows, configuration
  targets.yml          # Required - BOSH directors and connection info
  integrations.yml     # Required - vault, git, slack, email, locker
  scripts/
    manifest.yml       # Optional - script metadata declarations
    deploy.sh          # Optional - custom scripts
    smoke-test.sh      # Optional - custom scripts
  provider-config/
    concourse.yml      # Optional - Concourse-specific overrides
    github-actions.yml # Optional - GitHub Actions-specific overrides
```

The three required files are `pipeline.yml`, `targets.yml`, and
`integrations.yml`. The parser loads each through `spruce merge` so
spruce operators work in all files.

## pipeline.yml

This file defines the pipeline identity, branch configuration, workflows,
and global settings.

```yaml
metadata:
  name: my-cf-deployments
  version: "1.0"

branches:
  live: main
  target_prefix: target/

workflows:
  default:
    type: deployment
    triggers:
      - type: git
        pattern: "*.yml"
    stages:
      - name: deploy-sandbox
        script: deploy
        inputs: [deployment-repo]
        outputs: [manifests]
      - name: deploy-staging
        script: deploy
      - name: approve-prod
        type: manual-approval
        approvers: [ops-team]
      - name: deploy-prod
        script: deploy

configuration:
  public: false
  tagged: false
  task:
    image: genesiscommunity/concourse
    version: latest
  notifications:
    style: inline
```

The `metadata` section names the pipeline and assigns a version. The
`branches` section defines which Git branch the pipeline monitors (`live`)
and the prefix used for target branches.

The `workflows` section is the heart of the configuration. Each workflow
is a named deployment topology. When using the legacy layout DSL (via a
fallback from `ci.yml`), the parser converts the layout into a workflow
automatically. In the multi-file format, you can define workflows with
explicit stages and trigger relationships.

The `configuration` section holds global settings that correspond to the
top-level boolean flags and task/registry/notification settings from the
legacy format.

## targets.yml

This file defines deployment targets (BOSH directors).

```yaml
targets:
  sandbox:
    name: sandbox
    alias: sandbox
    type: bosh-director
    tags: []
    connection:
      url: https://bosh.sandbox.example.com
      auth:
        type: basic
        client_id: admin
        client_secret: (( vault "secret/bosh/sandbox/admin:password" ))
      ca_cert: (( vault "secret/bosh/sandbox/ssl/ca:certificate" ))

  proto:
    name: proto
    alias: proto-bosh
    type: bosh-create-env
    tags:
      - create-env
```

Each target has a `type` that is either `bosh-director` for standard
deployments or `bosh-create-env` for proto-BOSH create-env deployments.
The `connection` section mirrors the fields from `pipeline.boshes` in the
legacy format but uses a structured `auth` map instead of flat
`username`/`password` fields.

The `alias` and `genesis_env` fields work the same way as in the legacy
`boshes` section.

## integrations.yml

This file defines external service integrations: Vault, Git source control,
notifications, and the optional Locker service.

```yaml
vault:
  url: https://vault.example.com
  namespace: null
  auth:
    type: approle
    role_id: (( vault "secret/ci/pipeline:role_id" ))
    secret_id: (( vault "secret/ci/pipeline:secret_id" ))
  options:
    tls_verify: true
    no_strongbox: false

source_control:
  provider: github
  repository: my-org/my-deployments
  uri: null
  default_branch: main
  root: .
  version_depth: 0
  commit_author:
    name: Concourse Bot
    email: concourse@pipeline
  auth:
    type: ssh-key
    private_key: (( vault "secret/ci/pipeline:git_private_key" ))

notifications:
  - type: slack
    name: slack
    webhook: (( vault "secret/ci/pipeline:slack_webhook" ))
    channel: "#deployments"
    username: runwaybot
    icon: http://cl.ly/image/.../concourse-logo.png
    events: [started, failed, succeeded]

  - type: email
    name: email
    recipients:
      - ops@example.com
    from: concourse@example.com
    smtp:
      host: smtp.example.com
      username: smtp-user
      password: (( vault "secret/ci:smtp" ))
    events: [failed]

locker:
  url: https://locker.example.com
  username: locker-user
  password: (( vault "secret/ci:locker" ))
  ca_cert: null
  skip_ssl_validation: true
```

The `vault` and `source_control` sections are required. The validator
checks for `vault.url` and the presence of `source_control`. Notifications
are a list because you can have multiple notification providers active
simultaneously.

The `source_control.provider` field accepts `github` or `gitlab` and is
used to construct the Git URI automatically from the `repository` field
(e.g., `github` + `my-org/my-repo` becomes `git@github.com:my-org/my-repo.git`).
If you need a custom URI, set the `uri` field directly.

## scripts/ Directory

The `scripts/` directory under `.genesis/ci/` can contain shell scripts
referenced by workflow stages. Scripts can declare their metadata in two
ways.

The first way is through a `scripts/manifest.yml` file that explicitly
lists each script and its requirements:

```yaml
scripts:
  deploy:
    description: Execute Genesis deployment
    path: scripts/deploy.sh
    executor: bash
    version: "1.0"
    requirements:
      - tool: genesis-cli
        version: ">=3.1.0"
    inputs:
      - name: deployment-repo
        type: git-repository
        required: true
    outputs:
      - name: manifests
        type: directory
        path: .genesis/manifests/
    environment:
      required: [CURRENT_ENV, VAULT_ADDR]
      optional: [GENESIS_TRACE]
    timeout: 60m
```

The second way is through inline annotations in the script file itself:

```bash
#!/bin/bash
# @genesis-script
# @description: Execute Genesis deployment
# @version: 1.0
# @requires: genesis-cli>=3.1.0, bosh-cli>=7.0
# @input: deployment-repo (git-repository, required)
# @output: manifests (directory, .genesis/manifests/)
# @env-required: CURRENT_ENV, VAULT_ADDR
# @env-optional: GENESIS_TRACE
# @timeout: 60m
```

Scripts without either manifest entries or inline annotations are still
discovered. The system infers basic metadata from the filename, assigning
a default description based on the path and assuming `bash` as the executor.

## provider-config/ Directory

This directory holds platform-specific configuration overrides. Each file
is named after the provider (`concourse.yml`, `github-actions.yml`) and
its contents are passed through to the provider during compilation. The
exact format depends on the provider implementation.

## Relationship to Legacy Format

When the compiler pipeline reads a legacy `ci.yml`, the parser normalizes
it into the same internal structure as the multi-file format. The `boshes`
section becomes `targets`, the `vault`/`git`/`slack`/`email` sections
become `integrations`, and the `layout` string is parsed into a workflow
with a graph of nodes and edges.

This means that both formats flow through the same Validator, ASTBuilder,
and provider pipeline. The only difference is where the configuration
comes from initially.

## Migrating from ci.yml

To migrate an existing `ci.yml` to the multi-file format, split its
contents according to the sections described above. Here is a mapping:

The `pipeline.name`, `pipeline.layout` (or `layouts`), `pipeline.public`,
`pipeline.tagged`, `pipeline.task`, `pipeline.notifications`, and other
global settings go into `pipeline.yml`.

The `pipeline.boshes` section maps to `targets.yml`, with each BOSH
director becoming a target with a `type` and `connection` block.

The `pipeline.vault`, `pipeline.git`, `pipeline.slack`, `pipeline.email`,
and `pipeline.locker` sections all go into `integrations.yml`.

Once migrated, deploy with:

```bash
genesis repipe --platform concourse
```
