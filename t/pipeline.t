#!perl
use strict;
use warnings;

use lib 't';
use helper;

my $tmp = workdir;
vault_ok;
local $ENV{GENESIS_LEGACY}=1; # Allow env name mismatches
ok -d "t/repos/pipeline-test", "pipeline-test repo exists" or die;
chdir "t/repos/pipeline-test" or die;

bosh2_cli_ok;

subtest 'genesis repipe' => sub { # {{{
runs_ok "genesis repipe --dry-run --config ci/aws/pipeline" and # {{{
runs_ok "genesis repipe --dry-run --config ci/aws/pipeline >$tmp/pipeline.yml" and
yaml_is get_file("$tmp/pipeline.yml"), <<'EOF', "pipeline generated for aws/pipeline (no smoke-tests, untagged)";
groups:
- jobs:
  - client-aws-1-preprod-pipeline-test
  - client-aws-1-prod-pipeline-test
  - client-aws-1-sandbox-pipeline-test
  - notify-client-aws-1-prod-pipeline-test-changes
  name: aws-1
jobs:
- name: client-aws-1-preprod-pipeline-test
  plan:
  - do:
    - in_parallel:
      - get: client-aws-1-preprod-cloud-config
        trigger: true
      - get: client-aws-1-preprod-runtime-config
        trigger: true
      - get: client-aws-1-preprod-changes
        trigger: true
      - get: client-aws-1-preprod-cache
        passed:
        - client-aws-1-sandbox-pipeline-test
        trigger: true
    - config:
        image_resource:
          source:
            repository: starkandwayne/concourse
            tag: latest
          type: registry-image
        inputs:
        - name: client-aws-1-preprod-changes
        - name: client-aws-1-preprod-cache
        outputs:
        - name: out
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: pp-admin
          BOSH_CLIENT_SECRET: Ahti2eeth3aewohnee1Phaec
          BOSH_ENVIRONMENT: https://preprod.example.com:25555
          BOSH_NON_INTERACTIVE: true
          CACHE_DIR: client-aws-1-preprod-cache
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-preprod
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: out/git
          PREVIOUS_ENV: client-aws-1-sandbox
          VAULT_ADDR: https://127.0.0.1:8200
          VAULT_ROLE_ID: this-is-a-role
          VAULT_SECRET_ID: this-is-a-secret
          VAULT_SKIP_VERIFY: false
          WORKING_DIR: client-aws-1-preprod-changes
        platform: linux
        run:
          args:
          - ci-pipeline-deploy
          path: client-aws-1-preprod-cache/.genesis/bin/genesis
      ensure:
        params:
          repository: out/git
        put: git
      task: bosh-deploy
    - config:
        image_resource:
          source:
            repository: starkandwayne/concourse
            tag: latest
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-preprod-cache
        outputs:
        - name: cache-out
        params:
          CI_NO_REDACT: 0
          CACHE_DIR: client-aws-1-preprod-cache
          CURRENT_ENV: client-aws-1-preprod
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: cache-out/git
          PREVIOUS_ENV: client-aws-1-sandbox
          WORKING_DIR: out/git
        platform: linux
        run:
          args:
          - ci-generate-cache
          path: client-aws-1-preprod-cache/.genesis/bin/genesis
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    - params:
        repository: cache-out/git
      put: client-aws-1-prod-cache
    on_failure:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-preprod-pipeline-test
            failed'
          username: runwaybot
        put: slack
    on_success:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse successfully deployed client-aws-1-preprod-pipeline-test'
          username: runwaybot
        put: slack
  public: true
  serial: true
- name: notify-client-aws-1-prod-pipeline-test-changes
  plan:
  - in_parallel:
    - get: client-aws-1-prod-changes
      trigger: true
    - get: client-aws-1-prod-cache
      passed:
      - client-aws-1-preprod-pipeline-test
      trigger: true
    - get: client-aws-1-prod-cloud-config
      trigger: true
    - get: client-aws-1-prod-runtime-config
      trigger: true
  - config:
      image_resource:
        source:
          repository: starkandwayne/concourse
          tag: latest
        type: registry-image
      inputs:
      - name: client-aws-1-prod-changes
      - name: client-aws-1-prod-cache
      params:
        BOSH_CA_CERT: |
          ----- BEGIN CERTIFICATE -----
          cert-goes-here
          ----- END CERTIFICATE -----
        BOSH_CLIENT: pr-admin
        BOSH_CLIENT_SECRET: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
        BOSH_ENVIRONMENT: https://prod.example.com:25555
        BOSH_NON_INTERACTIVE: true
        CACHE_DIR: client-aws-1-prod-cache
        CI_NO_REDACT: 0
        CURRENT_ENV: client-aws-1-prod
        GENESIS_HONOR_ENV: 1
        GIT_AUTHOR_EMAIL: concourse@pipeline
        GIT_AUTHOR_NAME: Concourse Bot
        GIT_BRANCH: master
        GIT_PRIVATE_KEY: |
          -----BEGIN RSA PRIVATE KEY-----
          lol. you didn't really think that
          we'd put the key here, in a test,
          did you?!
          -----END RSA PRIVATE KEY-----
        OUT_DIR: out/git
        PREVIOUS_ENV: client-aws-1-preprod
        VAULT_ADDR: https://127.0.0.1:8200
        VAULT_ROLE_ID: this-is-a-role
        VAULT_SECRET_ID: this-is-a-secret
        VAULT_SKIP_VERIFY: false
        WORKING_DIR: client-aws-1-prod-changes
      platform: linux
      run:
        args:
        - ci-show-changes
        path: client-aws-1-prod-cache/.genesis/bin/genesis
    task: show-pending-changes
  - in_parallel:
    - params:
        channel: '#botspam'
        icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
        text: 'aws-1: Changes are staged to be deployed to client-aws-1-prod-pipeline-test,
          see notify-client-aws-1-prod-pipeline-test-changes job for change summary,
          then schedule and run a deploy via Concourse'
        username: runwaybot
      put: slack
  public: true
  serial: true
- name: client-aws-1-prod-pipeline-test
  plan:
  - do:
    - in_parallel:
      - get: client-aws-1-prod-changes
        passed:
        - notify-client-aws-1-prod-pipeline-test-changes
        trigger: false
      - get: client-aws-1-prod-cache
        passed:
        - notify-client-aws-1-prod-pipeline-test-changes
        trigger: false
    - config:
        image_resource:
          source:
            repository: starkandwayne/concourse
            tag: latest
          type: registry-image
        inputs:
        - name: client-aws-1-prod-changes
        - name: client-aws-1-prod-cache
        outputs:
        - name: out
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: pr-admin
          BOSH_CLIENT_SECRET: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
          BOSH_ENVIRONMENT: https://prod.example.com:25555
          BOSH_NON_INTERACTIVE: true
          CACHE_DIR: client-aws-1-prod-cache
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-prod
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: out/git
          PREVIOUS_ENV: client-aws-1-preprod
          VAULT_ADDR: https://127.0.0.1:8200
          VAULT_ROLE_ID: this-is-a-role
          VAULT_SECRET_ID: this-is-a-secret
          VAULT_SKIP_VERIFY: false
          WORKING_DIR: client-aws-1-prod-changes
        platform: linux
        run:
          args:
          - ci-pipeline-deploy
          path: client-aws-1-prod-cache/.genesis/bin/genesis
      ensure:
        params:
          repository: out/git
        put: git
      task: bosh-deploy
    - config:
        image_resource:
          source:
            repository: starkandwayne/concourse
            tag: latest
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-prod-cache
        outputs:
        - name: cache-out
        params:
          CACHE_DIR: client-aws-1-prod-cache
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-prod
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: cache-out/git
          PREVIOUS_ENV: client-aws-1-preprod
          WORKING_DIR: out/git
        platform: linux
        run:
          args:
          - ci-generate-cache
          path: client-aws-1-prod-cache/.genesis/bin/genesis
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    on_failure:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-prod-pipeline-test failed'
          username: runwaybot
        put: slack
    on_success:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse successfully deployed client-aws-1-prod-pipeline-test'
          username: runwaybot
        put: slack
  public: true
  serial: true
- name: client-aws-1-sandbox-pipeline-test
  plan:
  - do:
    - in_parallel:
      - get: client-aws-1-sandbox-cloud-config
        trigger: true
      - get: client-aws-1-sandbox-runtime-config
        trigger: true
      - get: client-aws-1-sandbox-changes
        trigger: true
    - config:
        image_resource:
          source:
            repository: starkandwayne/concourse
            tag: latest
          type: registry-image
        inputs:
        - name: client-aws-1-sandbox-changes
        outputs:
        - name: out
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: sb-admin
          BOSH_CLIENT_SECRET: PaeM2Eip
          BOSH_ENVIRONMENT: https://sandbox.example.com:25555
          BOSH_NON_INTERACTIVE: true
          CACHE_DIR: client-aws-1-sandbox-cache
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-sandbox
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: out/git
          PREVIOUS_ENV: null
          VAULT_ADDR: https://127.0.0.1:8200
          VAULT_ROLE_ID: this-is-a-role
          VAULT_SECRET_ID: this-is-a-secret
          VAULT_SKIP_VERIFY: false
          WORKING_DIR: client-aws-1-sandbox-changes
        platform: linux
        run:
          args:
          - ci-pipeline-deploy
          path: client-aws-1-sandbox-changes/.genesis/bin/genesis
      ensure:
        params:
          repository: out/git
        put: git
      task: bosh-deploy
    - config:
        image_resource:
          source:
            repository: starkandwayne/concourse
            tag: latest
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-sandbox-changes
        outputs:
        - name: cache-out
        params:
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-sandbox
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: cache-out/git
          WORKING_DIR: out/git
        platform: linux
        run:
          args:
          - ci-generate-cache
          path: client-aws-1-sandbox-changes/.genesis/bin/genesis
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    - params:
        repository: cache-out/git
      put: client-aws-1-preprod-cache
    on_failure:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-sandbox-pipeline-test
            failed'
          username: runwaybot
        put: slack
    on_success:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse successfully deployed client-aws-1-sandbox-pipeline-test'
          username: runwaybot
        put: slack
  public: true
  serial: true
resource_types:
- name: script
  source:
    repository: cfcommunity/script-resource
  type: registry-image
- name: email
  source:
    repository: pcfseceng/email-resource
  type: registry-image
- name: slack-notification
  source:
    repository: cfcommunity/slack-notification-resource
  type: registry-image
- name: hipchat-notification
  source:
    repository: cfcommunity/hipchat-notification-resource
  type: registry-image
- name: stride-notification
  source:
    repository: starkandwayne/stride-notification-resource
  type: registry-image
- name: bosh-config
  source:
    repository: cfcommunity/bosh-config-resource
  type: registry-image
- name: locker
  source:
    repository: cfcommunity/locker-resource
  type: registry-image
resources:
- icon: github
  name: git
  source:
    branch: master
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: github
  name: client-aws-1-preprod-changes
  source:
    branch: master
    paths:
    - client-aws-1-preprod.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: github
  name: client-aws-1-preprod-cache
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
    - .genesis/cached/client-aws-1-sandbox/ops/*
    - .genesis/cached/client-aws-1-sandbox/kit-overrides.yml
    - .genesis/cached/client-aws-1-sandbox/client.yml
    - .genesis/cached/client-aws-1-sandbox/client-aws.yml
    - .genesis/cached/client-aws-1-sandbox/client-aws-1.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: script-text
  name: client-aws-1-preprod-cloud-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pp-admin
    client_secret: Ahti2eeth3aewohnee1Phaec
    config: cloud
    target: https://preprod.example.com:25555
  type: bosh-config
- icon: script-text
  name: client-aws-1-preprod-runtime-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pp-admin
    client_secret: Ahti2eeth3aewohnee1Phaec
    config: runtime
    target: https://preprod.example.com:25555
  type: bosh-config
- icon: github
  name: client-aws-1-prod-changes
  source:
    branch: master
    paths:
    - client-aws-1-prod.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: github
  name: client-aws-1-prod-cache
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
    - .genesis/cached/client-aws-1-preprod/ops/*
    - .genesis/cached/client-aws-1-preprod/kit-overrides.yml
    - .genesis/cached/client-aws-1-preprod/client.yml
    - .genesis/cached/client-aws-1-preprod/client-aws.yml
    - .genesis/cached/client-aws-1-preprod/client-aws-1.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: script-text
  name: client-aws-1-prod-cloud-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pr-admin
    client_secret: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
    config: cloud
    target: https://prod.example.com:25555
  type: bosh-config
- icon: script-text
  name: client-aws-1-prod-runtime-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pr-admin
    client_secret: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
    config: runtime
    target: https://prod.example.com:25555
  type: bosh-config
- icon: github
  name: client-aws-1-sandbox-changes
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
    - ops/*
    - kit-overrides.yml
    - client.yml
    - client-aws.yml
    - client-aws-1.yml
    - client-aws-1-sandbox.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: script-text
  name: client-aws-1-sandbox-cloud-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: sb-admin
    client_secret: PaeM2Eip
    config: cloud
    target: https://sandbox.example.com:25555
  type: bosh-config
- icon: script-text
  name: client-aws-1-sandbox-runtime-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: sb-admin
    client_secret: PaeM2Eip
    config: runtime
    target: https://sandbox.example.com:25555
  type: bosh-config
- icon: slack
  name: slack
  source:
    url: http://127.0.0.1:1337
  type: slack-notification
EOF
# }}}
runs_ok "genesis repipe --dry-run --config ci/aws/pipeline.tagged" and # {{{
runs_ok "genesis repipe --dry-run --config ci/aws/pipeline.tagged >$tmp/pipeline.yml" and
yaml_is get_file("$tmp/pipeline.yml"), <<'EOF', "pipeline generated for aws/pipeline (no smoke-tests, tagged)";
groups:
- jobs:
  - client-aws-1-preprod-pipeline-test
  - client-aws-1-prod-pipeline-test
  - client-aws-1-sandbox-pipeline-test
  - notify-client-aws-1-prod-pipeline-test-changes
  name: aws-1
jobs:
- name: client-aws-1-preprod-pipeline-test
  plan:
  - do:
    - in_parallel:
      - get: client-aws-1-preprod-cloud-config
        tags:
        - client-aws-1-preprod
        trigger: true
      - get: client-aws-1-preprod-runtime-config
        tags:
        - client-aws-1-preprod
        trigger: true
      - get: client-aws-1-preprod-changes
        trigger: true
      - get: client-aws-1-preprod-cache
        passed:
        - client-aws-1-sandbox-pipeline-test
        trigger: true
    - config:
        image_resource:
          source:
            repository: starkandwayne/concourse
            tag: latest
          type: registry-image
        inputs:
        - name: client-aws-1-preprod-changes
        - name: client-aws-1-preprod-cache
        outputs:
        - name: out
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: pp-admin
          BOSH_CLIENT_SECRET: Ahti2eeth3aewohnee1Phaec
          BOSH_ENVIRONMENT: https://preprod.example.com:25555
          BOSH_NON_INTERACTIVE: true
          CACHE_DIR: client-aws-1-preprod-cache
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-preprod
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: out/git
          PREVIOUS_ENV: client-aws-1-sandbox
          VAULT_ADDR: https://127.0.0.1:8200
          VAULT_NAMESPACE: henchco
          VAULT_ROLE_ID: this-is-a-role
          VAULT_SECRET_ID: this-is-a-secret
          VAULT_SKIP_VERIFY: false
          WORKING_DIR: client-aws-1-preprod-changes
        platform: linux
        run:
          args:
          - ci-pipeline-deploy
          path: client-aws-1-preprod-cache/.genesis/bin/genesis
      ensure:
        params:
          repository: out/git
        put: git
      tags:
      - client-aws-1-preprod
      task: bosh-deploy
    - config:
        image_resource:
          source:
            repository: starkandwayne/concourse
            tag: latest
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-preprod-cache
        outputs:
        - name: cache-out
        params:
          CACHE_DIR: client-aws-1-preprod-cache
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-preprod
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: cache-out/git
          PREVIOUS_ENV: client-aws-1-sandbox
          WORKING_DIR: out/git
        platform: linux
        run:
          args:
          - ci-generate-cache
          path: client-aws-1-preprod-cache/.genesis/bin/genesis
      tags:
      - client-aws-1-preprod
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    - params:
        repository: cache-out/git
      put: client-aws-1-prod-cache
    on_failure:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-preprod-pipeline-test
            failed'
          username: runwaybot
        put: slack
    on_success:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse successfully deployed client-aws-1-preprod-pipeline-test'
          username: runwaybot
        put: slack
  public: true
  serial: true
- name: notify-client-aws-1-prod-pipeline-test-changes
  plan:
  - in_parallel:
    - get: client-aws-1-prod-changes
      trigger: true
    - get: client-aws-1-prod-cache
      passed:
      - client-aws-1-preprod-pipeline-test
      trigger: true
    - get: client-aws-1-prod-cloud-config
      tags:
      - client-aws-1-prod
      trigger: true
    - get: client-aws-1-prod-runtime-config
      tags:
      - client-aws-1-prod
      trigger: true
  - config:
      image_resource:
        source:
          repository: starkandwayne/concourse
          tag: latest
        type: registry-image
      inputs:
      - name: client-aws-1-prod-changes
      - name: client-aws-1-prod-cache
      params:
        BOSH_CA_CERT: |
          ----- BEGIN CERTIFICATE -----
          cert-goes-here
          ----- END CERTIFICATE -----
        BOSH_CLIENT: pr-admin
        BOSH_CLIENT_SECRET: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
        BOSH_ENVIRONMENT: https://prod.example.com:25555
        BOSH_NON_INTERACTIVE: true
        CACHE_DIR: client-aws-1-prod-cache
        CI_NO_REDACT: 0
        CURRENT_ENV: client-aws-1-prod
        GENESIS_HONOR_ENV: 1
        GIT_AUTHOR_EMAIL: concourse@pipeline
        GIT_AUTHOR_NAME: Concourse Bot
        GIT_BRANCH: master
        GIT_PRIVATE_KEY: |
          -----BEGIN RSA PRIVATE KEY-----
          lol. you didn't really think that
          we'd put the key here, in a test,
          did you?!
          -----END RSA PRIVATE KEY-----
        OUT_DIR: out/git
        PREVIOUS_ENV: client-aws-1-preprod
        VAULT_ADDR: https://127.0.0.1:8200
        VAULT_NAMESPACE: henchco
        VAULT_ROLE_ID: this-is-a-role
        VAULT_SECRET_ID: this-is-a-secret
        VAULT_SKIP_VERIFY: false
        WORKING_DIR: client-aws-1-prod-changes
      platform: linux
      run:
        args:
        - ci-show-changes
        path: client-aws-1-prod-cache/.genesis/bin/genesis
    tags:
    - client-aws-1-prod
    task: show-pending-changes
  - in_parallel:
    - params:
        channel: '#botspam'
        icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
        text: 'aws-1: Changes are staged to be deployed to client-aws-1-prod-pipeline-test,
          see notify-client-aws-1-prod-pipeline-test-changes job for change summary,
          then schedule and run a deploy via Concourse'
        username: runwaybot
      put: slack
  public: true
  serial: true
- name: client-aws-1-prod-pipeline-test
  plan:
  - do:
    - in_parallel:
      - get: client-aws-1-prod-changes
        passed:
        - notify-client-aws-1-prod-pipeline-test-changes
        trigger: false
      - get: client-aws-1-prod-cache
        passed:
        - notify-client-aws-1-prod-pipeline-test-changes
        trigger: false
    - config:
        image_resource:
          source:
            repository: starkandwayne/concourse
            tag: latest
          type: registry-image
        inputs:
        - name: client-aws-1-prod-changes
        - name: client-aws-1-prod-cache
        outputs:
        - name: out
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: pr-admin
          BOSH_CLIENT_SECRET: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
          BOSH_ENVIRONMENT: https://prod.example.com:25555
          BOSH_NON_INTERACTIVE: true
          CACHE_DIR: client-aws-1-prod-cache
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-prod
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: out/git
          PREVIOUS_ENV: client-aws-1-preprod
          VAULT_ADDR: https://127.0.0.1:8200
          VAULT_NAMESPACE: henchco
          VAULT_ROLE_ID: this-is-a-role
          VAULT_SECRET_ID: this-is-a-secret
          VAULT_SKIP_VERIFY: false
          WORKING_DIR: client-aws-1-prod-changes
        platform: linux
        run:
          args:
          - ci-pipeline-deploy
          path: client-aws-1-prod-cache/.genesis/bin/genesis
      ensure:
        params:
          repository: out/git
        put: git
      tags:
      - client-aws-1-prod
      task: bosh-deploy
    - config:
        image_resource:
          source:
            repository: starkandwayne/concourse
            tag: latest
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-prod-cache
        outputs:
        - name: cache-out
        params:
          CACHE_DIR: client-aws-1-prod-cache
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-prod
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: cache-out/git
          PREVIOUS_ENV: client-aws-1-preprod
          WORKING_DIR: out/git
        platform: linux
        run:
          args:
          - ci-generate-cache
          path: client-aws-1-prod-cache/.genesis/bin/genesis
      tags:
      - client-aws-1-prod
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    on_failure:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-prod-pipeline-test failed'
          username: runwaybot
        put: slack
    on_success:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse successfully deployed client-aws-1-prod-pipeline-test'
          username: runwaybot
        put: slack
  public: true
  serial: true
- name: client-aws-1-sandbox-pipeline-test
  plan:
  - do:
    - in_parallel:
      - get: client-aws-1-sandbox-cloud-config
        tags:
        - client-aws-1-sandbox
        trigger: true
      - get: client-aws-1-sandbox-runtime-config
        tags:
        - client-aws-1-sandbox
        trigger: true
      - get: client-aws-1-sandbox-changes
        trigger: true
    - config:
        image_resource:
          source:
            repository: starkandwayne/concourse
            tag: latest
          type: registry-image
        inputs:
        - name: client-aws-1-sandbox-changes
        outputs:
        - name: out
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: sb-admin
          BOSH_CLIENT_SECRET: PaeM2Eip
          BOSH_ENVIRONMENT: https://sandbox.example.com:25555
          BOSH_NON_INTERACTIVE: true
          CACHE_DIR: client-aws-1-sandbox-cache
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-sandbox
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: out/git
          PREVIOUS_ENV: null
          VAULT_ADDR: https://127.0.0.1:8200
          VAULT_NAMESPACE:  henchco
          VAULT_ROLE_ID: this-is-a-role
          VAULT_SECRET_ID: this-is-a-secret
          VAULT_SKIP_VERIFY: false
          WORKING_DIR: client-aws-1-sandbox-changes
        platform: linux
        run:
          args:
          - ci-pipeline-deploy
          path: client-aws-1-sandbox-changes/.genesis/bin/genesis
      ensure:
        params:
          repository: out/git
        put: git
      tags:
      - client-aws-1-sandbox
      task: bosh-deploy
    - config:
        image_resource:
          source:
            repository: starkandwayne/concourse
            tag: latest
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-sandbox-changes
        outputs:
        - name: cache-out
        params:
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-sandbox
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: cache-out/git
          WORKING_DIR: out/git
        platform: linux
        run:
          args:
          - ci-generate-cache
          path: client-aws-1-sandbox-changes/.genesis/bin/genesis
      tags:
      - client-aws-1-sandbox
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    - params:
        repository: cache-out/git
      put: client-aws-1-preprod-cache
    on_failure:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-sandbox-pipeline-test
            failed'
          username: runwaybot
        put: slack
    on_success:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse successfully deployed client-aws-1-sandbox-pipeline-test'
          username: runwaybot
        put: slack
  public: true
  serial: true
resource_types:
- name: script
  source:
    repository: cfcommunity/script-resource
  type: registry-image
- name: email
  source:
    repository: pcfseceng/email-resource
  type: registry-image
- name: slack-notification
  source:
    repository: cfcommunity/slack-notification-resource
  type: registry-image
- name: hipchat-notification
  source:
    repository: cfcommunity/hipchat-notification-resource
  type: registry-image
- name: stride-notification
  source:
    repository: starkandwayne/stride-notification-resource
  type: registry-image
- name: bosh-config
  source:
    repository: cfcommunity/bosh-config-resource
  type: registry-image
- name: locker
  source:
    repository: cfcommunity/locker-resource
  type: registry-image
resources:
- icon: github
  name: git
  source:
    branch: master
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: github
  name: client-aws-1-preprod-changes
  source:
    branch: master
    paths:
    - client-aws-1-preprod.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: github
  name: client-aws-1-preprod-cache
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
    - .genesis/cached/client-aws-1-sandbox/ops/*
    - .genesis/cached/client-aws-1-sandbox/kit-overrides.yml
    - .genesis/cached/client-aws-1-sandbox/client.yml
    - .genesis/cached/client-aws-1-sandbox/client-aws.yml
    - .genesis/cached/client-aws-1-sandbox/client-aws-1.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: script-text
  name: client-aws-1-preprod-cloud-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pp-admin
    client_secret: Ahti2eeth3aewohnee1Phaec
    config: cloud
    target: https://preprod.example.com:25555
  tags:
    - client-aws-1-preprod
  type: bosh-config
- icon: script-text
  name: client-aws-1-preprod-runtime-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pp-admin
    client_secret: Ahti2eeth3aewohnee1Phaec
    config: runtime
    target: https://preprod.example.com:25555
  tags:
    - client-aws-1-preprod
  type: bosh-config
- icon: github
  name: client-aws-1-prod-changes
  source:
    branch: master
    paths:
    - client-aws-1-prod.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: github
  name: client-aws-1-prod-cache
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
    - .genesis/cached/client-aws-1-preprod/ops/*
    - .genesis/cached/client-aws-1-preprod/kit-overrides.yml
    - .genesis/cached/client-aws-1-preprod/client.yml
    - .genesis/cached/client-aws-1-preprod/client-aws.yml
    - .genesis/cached/client-aws-1-preprod/client-aws-1.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: script-text
  name: client-aws-1-prod-cloud-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pr-admin
    client_secret: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
    config: cloud
    target: https://prod.example.com:25555
  tags:
    - client-aws-1-prod
  type: bosh-config
- icon: script-text
  name: client-aws-1-prod-runtime-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pr-admin
    client_secret: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
    config: runtime
    target: https://prod.example.com:25555
  tags:
    - client-aws-1-prod
  type: bosh-config
- icon: github
  name: client-aws-1-sandbox-changes
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
    - ops/*
    - kit-overrides.yml
    - client.yml
    - client-aws.yml
    - client-aws-1.yml
    - client-aws-1-sandbox.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: script-text
  name: client-aws-1-sandbox-cloud-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: sb-admin
    client_secret: PaeM2Eip
    config: cloud
    target: https://sandbox.example.com:25555
  tags:
    - client-aws-1-sandbox
  type: bosh-config
- icon: script-text
  name: client-aws-1-sandbox-runtime-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: sb-admin
    client_secret: PaeM2Eip
    config: runtime
    target: https://sandbox.example.com:25555
  tags:
    - client-aws-1-sandbox
  type: bosh-config
- icon: slack
  name: slack
  source:
    url: http://127.0.0.1:1337
  type: slack-notification
EOF
# }}}
runs_ok "genesis repipe --dry-run --config ci/aws/pipeline.tests" and # {{{
runs_ok "genesis repipe --dry-run --config ci/aws/pipeline.tests >$tmp/pipeline.yml" and
yaml_is get_file("$tmp/pipeline.yml"), <<'EOF', "pipeline generated for aws/pipeline (smoke-tests, untagged)";
groups:
- jobs:
  - preprod-pipeline-test
  - prod-pipeline-test
  - sandbox-pipeline-test
  - notify-prod-pipeline-test-changes
  name: aws-1
jobs:
- name: preprod-pipeline-test
  plan:
  - do:
    - in_parallel:
      - get: preprod-cloud-config
        trigger: true
      - get: preprod-runtime-config
        trigger: true
      - get: preprod-changes
        trigger: true
      - get: preprod-cache
        passed:
        - sandbox-pipeline-test
        trigger: true
    - config:
        image_resource:
          source:
            repository: starkandwayne/concourse
            tag: latest
          type: registry-image
        inputs:
        - name: preprod-changes
        - name: preprod-cache
        outputs:
        - name: out
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: pp-admin
          BOSH_CLIENT_SECRET: Ahti2eeth3aewohnee1Phaec
          BOSH_ENVIRONMENT: https://preprod.example.com:25555
          BOSH_NON_INTERACTIVE: true
          CACHE_DIR: preprod-cache
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-preprod
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PASSWORD: weneedareplacement!
          GIT_USERNAME: fleemco
          OUT_DIR: out/git
          PREVIOUS_ENV: client-aws-1-sandbox
          VAULT_ADDR: https://127.0.0.1:8200
          VAULT_ROLE_ID: this-is-a-role
          VAULT_SECRET_ID: this-is-a-secret
          VAULT_SKIP_VERIFY: false
          WORKING_DIR: preprod-changes
        platform: linux
        run:
          args:
          - ci-pipeline-deploy
          path: preprod-cache/.genesis/bin/genesis
      ensure:
        params:
          repository: out/git
        put: git
      task: bosh-deploy
    - config:
        image_resource:
          source:
            repository: starkandwayne/concourse
            tag: latest
          type: registry-image
        inputs:
        - name: out
        - name: preprod-cache
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: pp-admin
          BOSH_CLIENT_SECRET: Ahti2eeth3aewohnee1Phaec
          BOSH_ENVIRONMENT: https://preprod.example.com:25555
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-preprod
          DEBUG: 1
          ERRAND_NAME: a-testing-errand-for-the-ages
          GENESIS_HONOR_ENV: 1
        platform: linux
        run:
          args:
          - ci-pipeline-run-errand
          dir: out/git
          path: ../../preprod-cache/.genesis/bin/genesis
      task: a-testing-errand-for-the-ages-errand
    - config:
        image_resource:
          source:
            repository: starkandwayne/concourse
            tag: latest
          type: registry-image
        inputs:
        - name: out
        - name: preprod-cache
        outputs:
        - name: cache-out
        params:
          CACHE_DIR: preprod-cache
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-preprod
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PASSWORD: weneedareplacement!
          GIT_USERNAME: fleemco
          OUT_DIR: cache-out/git
          PREVIOUS_ENV: client-aws-1-sandbox
          WORKING_DIR: out/git
        platform: linux
        run:
          args:
          - ci-generate-cache
          path: preprod-cache/.genesis/bin/genesis
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    - params:
        repository: cache-out/git
      put: prod-cache
    on_failure:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-preprod-pipeline-test
            failed'
          username: runwaybot
        put: slack
    on_success:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse successfully deployed client-aws-1-preprod-pipeline-test'
          username: runwaybot
        put: slack
  public: true
  serial: true
- name: notify-prod-pipeline-test-changes
  plan:
  - in_parallel:
    - get: prod-changes
      trigger: true
    - get: prod-cache
      passed:
      - preprod-pipeline-test
      trigger: true
    - get: prod-cloud-config
      trigger: true
    - get: prod-runtime-config
      trigger: true
  - config:
      image_resource:
        source:
          repository: starkandwayne/concourse
          tag: latest
        type: registry-image
      inputs:
      - name: prod-changes
      - name: prod-cache
      params:
        BOSH_CA_CERT: |
          ----- BEGIN CERTIFICATE -----
          cert-goes-here
          ----- END CERTIFICATE -----
        BOSH_CLIENT: pr-admin
        BOSH_CLIENT_SECRET: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
        BOSH_ENVIRONMENT: https://prod.example.com:25555
        BOSH_NON_INTERACTIVE: true
        CACHE_DIR: prod-cache
        CI_NO_REDACT: 0
        CURRENT_ENV: client-aws-1-prod
        DEBUG: 1
        GENESIS_HONOR_ENV: 1
        GIT_AUTHOR_EMAIL: concourse@pipeline
        GIT_AUTHOR_NAME: Concourse Bot
        GIT_BRANCH: master
        GIT_PASSWORD: weneedareplacement!
        GIT_USERNAME: fleemco
        OUT_DIR: out/git
        PREVIOUS_ENV: client-aws-1-preprod
        VAULT_ADDR: https://127.0.0.1:8200
        VAULT_ROLE_ID: this-is-a-role
        VAULT_SECRET_ID: this-is-a-secret
        VAULT_SKIP_VERIFY: false
        WORKING_DIR: prod-changes
      platform: linux
      run:
        args:
        - ci-show-changes
        path: prod-cache/.genesis/bin/genesis
    task: show-pending-changes
  - in_parallel:
    - params:
        channel: '#botspam'
        icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
        text: 'aws-1: Changes are staged to be deployed to client-aws-1-prod-pipeline-test,
          see notify-prod-pipeline-test-changes job for change summary, then schedule
          and run a deploy via Concourse'
        username: runwaybot
      put: slack
  public: true
  serial: true
- name: prod-pipeline-test
  plan:
  - do:
    - in_parallel:
      - get: prod-changes
        passed:
        - notify-prod-pipeline-test-changes
        trigger: false
      - get: prod-cache
        passed:
        - notify-prod-pipeline-test-changes
        trigger: false
    - config:
        image_resource:
          source:
            repository: starkandwayne/concourse
            tag: latest
          type: registry-image
        inputs:
        - name: prod-changes
        - name: prod-cache
        outputs:
        - name: out
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: pr-admin
          BOSH_CLIENT_SECRET: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
          BOSH_ENVIRONMENT: https://prod.example.com:25555
          BOSH_NON_INTERACTIVE: true
          CACHE_DIR: prod-cache
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-prod
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PASSWORD: weneedareplacement!
          GIT_USERNAME: fleemco
          OUT_DIR: out/git
          PREVIOUS_ENV: client-aws-1-preprod
          VAULT_ADDR: https://127.0.0.1:8200
          VAULT_ROLE_ID: this-is-a-role
          VAULT_SECRET_ID: this-is-a-secret
          VAULT_SKIP_VERIFY: false
          WORKING_DIR: prod-changes
        platform: linux
        run:
          args:
          - ci-pipeline-deploy
          path: prod-cache/.genesis/bin/genesis
      ensure:
        params:
          repository: out/git
        put: git
      task: bosh-deploy
    - config:
        image_resource:
          source:
            repository: starkandwayne/concourse
            tag: latest
          type: registry-image
        inputs:
        - name: out
        - name: prod-cache
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: pr-admin
          BOSH_CLIENT_SECRET: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
          BOSH_ENVIRONMENT: https://prod.example.com:25555
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-prod
          DEBUG: 1
          ERRAND_NAME: a-testing-errand-for-the-ages
          GENESIS_HONOR_ENV: 1
        platform: linux
        run:
          args:
          - ci-pipeline-run-errand
          dir: out/git
          path: ../../prod-cache/.genesis/bin/genesis
      task: a-testing-errand-for-the-ages-errand
    - config:
        image_resource:
          source:
            repository: starkandwayne/concourse
            tag: latest
          type: registry-image
        inputs:
        - name: out
        - name: prod-cache
        outputs:
        - name: cache-out
        params:
          CACHE_DIR: prod-cache
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-prod
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PASSWORD: weneedareplacement!
          GIT_USERNAME: fleemco
          OUT_DIR: cache-out/git
          PREVIOUS_ENV: client-aws-1-preprod
          WORKING_DIR: out/git
        platform: linux
        run:
          args:
          - ci-generate-cache
          path: prod-cache/.genesis/bin/genesis
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    on_failure:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-prod-pipeline-test failed'
          username: runwaybot
        put: slack
    on_success:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse successfully deployed client-aws-1-prod-pipeline-test'
          username: runwaybot
        put: slack
  public: true
  serial: true
- name: sandbox-pipeline-test
  plan:
  - do:
    - in_parallel:
      - get: sandbox-cloud-config
        trigger: true
      - get: sandbox-runtime-config
        trigger: true
      - get: sandbox-changes
        trigger: true
    - config:
        image_resource:
          source:
            repository: starkandwayne/concourse
            tag: latest
          type: registry-image
        inputs:
        - name: sandbox-changes
        outputs:
        - name: out
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: sb-admin
          BOSH_CLIENT_SECRET: PaeM2Eip
          BOSH_ENVIRONMENT: https://sandbox.example.com:25555
          BOSH_NON_INTERACTIVE: true
          CACHE_DIR: sandbox-cache
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-sandbox
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PASSWORD: weneedareplacement!
          GIT_USERNAME: fleemco
          OUT_DIR: out/git
          PREVIOUS_ENV: null
          VAULT_ADDR: https://127.0.0.1:8200
          VAULT_ROLE_ID: this-is-a-role
          VAULT_SECRET_ID: this-is-a-secret
          VAULT_SKIP_VERIFY: false
          WORKING_DIR: sandbox-changes
        platform: linux
        run:
          args:
          - ci-pipeline-deploy
          path: sandbox-changes/.genesis/bin/genesis
      ensure:
        params:
          repository: out/git
        put: git
      task: bosh-deploy
    - config:
        image_resource:
          source:
            repository: starkandwayne/concourse
            tag: latest
          type: registry-image
        inputs:
        - name: out
        - name: sandbox-changes
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: sb-admin
          BOSH_CLIENT_SECRET: PaeM2Eip
          BOSH_ENVIRONMENT: https://sandbox.example.com:25555
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-sandbox
          DEBUG: 1
          ERRAND_NAME: a-testing-errand-for-the-ages
          GENESIS_HONOR_ENV: 1
        platform: linux
        run:
          args:
          - ci-pipeline-run-errand
          dir: out/git
          path: ../../sandbox-changes/.genesis/bin/genesis
      task: a-testing-errand-for-the-ages-errand
    - config:
        image_resource:
          source:
            repository: starkandwayne/concourse
            tag: latest
          type: registry-image
        inputs:
        - name: out
        - name: sandbox-changes
        outputs:
        - name: cache-out
        params:
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-sandbox
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PASSWORD: weneedareplacement!
          GIT_USERNAME: fleemco
          OUT_DIR: cache-out/git
          WORKING_DIR: out/git
        platform: linux
        run:
          args:
          - ci-generate-cache
          path: sandbox-changes/.genesis/bin/genesis
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    - params:
        repository: cache-out/git
      put: preprod-cache
    on_failure:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-sandbox-pipeline-test
            failed'
          username: runwaybot
        put: slack
    on_success:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse successfully deployed client-aws-1-sandbox-pipeline-test'
          username: runwaybot
        put: slack
  public: true
  serial: true
resource_types:
- name: script
  source:
    repository: cfcommunity/script-resource
  type: registry-image
- name: email
  source:
    repository: pcfseceng/email-resource
  type: registry-image
- name: slack-notification
  source:
    repository: cfcommunity/slack-notification-resource
  type: registry-image
- name: hipchat-notification
  source:
    repository: cfcommunity/hipchat-notification-resource
  type: registry-image
- name: stride-notification
  source:
    repository: starkandwayne/stride-notification-resource
  type: registry-image
- name: bosh-config
  source:
    repository: cfcommunity/bosh-config-resource
  type: registry-image
- name: locker
  source:
    repository: cfcommunity/locker-resource
  type: registry-image
resources:
- icon: github
  name: git
  source:
    branch: master
    password: weneedareplacement!
    uri: github.mycorp.com/myproj/mystuff/myrepo.git
    username: fleemco
  type: git
- icon: github
  name: preprod-changes
  source:
    branch: master
    paths:
    - client-aws-1-preprod.yml
    password: weneedareplacement!
    uri: github.mycorp.com/myproj/mystuff/myrepo.git
    username: fleemco
  type: git
- icon: github
  name: preprod-cache
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
    - .genesis/cached/client-aws-1-sandbox/ops/*
    - .genesis/cached/client-aws-1-sandbox/kit-overrides.yml
    - .genesis/cached/client-aws-1-sandbox/client.yml
    - .genesis/cached/client-aws-1-sandbox/client-aws.yml
    - .genesis/cached/client-aws-1-sandbox/client-aws-1.yml
    password: weneedareplacement!
    uri: github.mycorp.com/myproj/mystuff/myrepo.git
    username: fleemco
  type: git
- icon: script-text
  name: preprod-cloud-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pp-admin
    client_secret: Ahti2eeth3aewohnee1Phaec
    config: cloud
    target: https://preprod.example.com:25555
  type: bosh-config
- icon: script-text
  name: preprod-runtime-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pp-admin
    client_secret: Ahti2eeth3aewohnee1Phaec
    config: runtime
    target: https://preprod.example.com:25555
  type: bosh-config
- icon: github
  name: prod-changes
  source:
    branch: master
    paths:
    - client-aws-1-prod.yml
    password: weneedareplacement!
    uri: github.mycorp.com/myproj/mystuff/myrepo.git
    username: fleemco
  type: git
- icon: github
  name: prod-cache
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
    - .genesis/cached/client-aws-1-preprod/ops/*
    - .genesis/cached/client-aws-1-preprod/kit-overrides.yml
    - .genesis/cached/client-aws-1-preprod/client.yml
    - .genesis/cached/client-aws-1-preprod/client-aws.yml
    - .genesis/cached/client-aws-1-preprod/client-aws-1.yml
    password: weneedareplacement!
    uri: github.mycorp.com/myproj/mystuff/myrepo.git
    username: fleemco
  type: git
- icon: script-text
  name: prod-cloud-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pr-admin
    client_secret: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
    config: cloud
    target: https://prod.example.com:25555
  type: bosh-config
- icon: script-text
  name: prod-runtime-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pr-admin
    client_secret: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
    config: runtime
    target: https://prod.example.com:25555
  type: bosh-config
- icon: github
  name: sandbox-changes
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
    - ops/*
    - kit-overrides.yml
    - client.yml
    - client-aws.yml
    - client-aws-1.yml
    - client-aws-1-sandbox.yml
    password: weneedareplacement!
    uri: github.mycorp.com/myproj/mystuff/myrepo.git
    username: fleemco
  type: git
- icon: script-text
  name: sandbox-cloud-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: sb-admin
    client_secret: PaeM2Eip
    config: cloud
    target: https://sandbox.example.com:25555
  type: bosh-config
- icon: script-text
  name: sandbox-runtime-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: sb-admin
    client_secret: PaeM2Eip
    config: runtime
    target: https://sandbox.example.com:25555
  type: bosh-config
- icon: slack
  name: slack
  source:
    url: http://127.0.0.1:1337
  type: slack-notification
EOF
# }}}

runs_ok "genesis repipe --dry-run --config ci/aws/pipeline.everything" and # {{{
runs_ok "genesis repipe --dry-run --config ci/aws/pipeline.everything >$tmp/pipeline.yml" and
yaml_is get_file("$tmp/pipeline.yml"), <<'EOF', "pipeline generated for aws/pipeline (kitchen sink)";
groups:
- jobs:
  - client-aws-1-preprod-pipeline-test
  - client-aws-1-prod-pipeline-test
  - client-aws-1-sandbox-pipeline-test
  - notify-client-aws-1-prod-pipeline-test-changes
  name: aws-1
- jobs:
  - update-genesis-assets
  name: genesis-updates
jobs:
- name: client-aws-1-preprod-pipeline-test
  plan:
  - do:
    - params:
        key: dont-upgrade-bosh-on-me
        lock_op: lock
        locked_by: client-aws-1-preprod-pipeline-test
      put: client-aws-1-preprod-bosh-lock
      tags:
      - client-aws-1-preprod
    - params:
        key: i-need-to-deploy-myself
        lock_op: lock
        locked_by: client-aws-1-preprod-pipeline-test
      put: client-aws-1-preprod-deployment-lock
      tags:
      - client-aws-1-preprod
    - in_parallel:
      - get: client-aws-1-preprod-cloud-config
        tags:
        - client-aws-1-preprod
        trigger: true
      - get: client-aws-1-preprod-runtime-config
        tags:
        - client-aws-1-preprod
        trigger: true
      - get: client-aws-1-preprod-changes
        trigger: true
      - get: client-aws-1-preprod-cache
        passed:
        - client-aws-1-sandbox-pipeline-test
        trigger: true
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: client-aws-1-preprod-changes
        - name: client-aws-1-preprod-cache
        outputs:
        - name: out
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: pp-admin
          BOSH_CLIENT_SECRET: Ahti2eeth3aewohnee1Phaec
          BOSH_ENVIRONMENT: https://preprod.bosh-lite.com:25555
          BOSH_NON_INTERACTIVE: true
          CACHE_DIR: client-aws-1-preprod-cache
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-preprod
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_GENESIS_ROOT: cf/legacy
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: out/git
          PREVIOUS_ENV: client-aws-1-sandbox
          VAULT_ADDR: http://myvault.myorg.com:5999
          VAULT_ROLE_ID: this-is-a-role
          VAULT_SECRET_ID: this-is-a-secret
          VAULT_SKIP_VERIFY: true
          WORKING_DIR: client-aws-1-preprod-changes
        platform: linux
        run:
          args:
          - ci-pipeline-deploy
          path: client-aws-1-preprod-cache/cf/legacy/.genesis/bin/genesis
      ensure:
        params:
          repository: out/git
        put: git
      privileged: true
      tags:
      - client-aws-1-preprod
      task: bosh-deploy
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-preprod-cache
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: pp-admin
          BOSH_CLIENT_SECRET: Ahti2eeth3aewohnee1Phaec
          BOSH_ENVIRONMENT: https://preprod.bosh-lite.com:25555
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-preprod
          DEBUG: 1
          ERRAND_NAME: run-something-good
          GENESIS_HONOR_ENV: 1
        platform: linux
        run:
          args:
          - ci-pipeline-run-errand
          dir: out/git/cf/legacy
          path: ../../client-aws-1-preprod-cache/cf/legacy/.genesis/bin/genesis
      tags:
      - client-aws-1-preprod
      task: run-something-good-errand
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-preprod-cache
        outputs:
        - name: cache-out
        params:
          CACHE_DIR: client-aws-1-preprod-cache
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-preprod
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_GENESIS_ROOT: cf/legacy
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: cache-out/git
          PREVIOUS_ENV: client-aws-1-sandbox
          WORKING_DIR: out/git
        platform: linux
        run:
          args:
          - ci-generate-cache
          path: client-aws-1-preprod-cache/cf/legacy/.genesis/bin/genesis
      tags:
      - client-aws-1-preprod
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    - params:
        repository: cache-out/git
      put: client-aws-1-prod-cache
    ensure:
      do:
      - params:
          key: dont-upgrade-bosh-on-me
          lock_op: unlock
          locked_by: client-aws-1-preprod-pipeline-test
        put: client-aws-1-preprod-bosh-lock
        tags:
        - client-aws-1-preprod
      - params:
          key: i-need-to-deploy-myself
          lock_op: unlock
          locked_by: client-aws-1-preprod-pipeline-test
        put: client-aws-1-preprod-deployment-lock
        tags:
        - client-aws-1-preprod
    on_failure:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-preprod-pipeline-test
            failed'
          username: runwaybot
        put: slack
      - params:
          color: gray
          from: runwaybot
          message: 'aws-1: Concourse deployment to client-aws-1-preprod-pipeline-test
            failed'
          notify: false
        put: hipchat
    on_success:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse successfully deployed client-aws-1-preprod-pipeline-test'
          username: runwaybot
        put: slack
      - params:
          color: gray
          from: runwaybot
          message: 'aws-1: Concourse successfully deployed client-aws-1-preprod-pipeline-test'
          notify: false
        put: hipchat
  public: true
  serial: true
- name: notify-client-aws-1-prod-pipeline-test-changes
  plan:
  - in_parallel:
    - get: client-aws-1-prod-changes
      trigger: true
    - get: client-aws-1-prod-cache
      passed:
      - client-aws-1-preprod-pipeline-test
      trigger: true
    - get: client-aws-1-prod-cloud-config
      tags:
      - client-aws-1-prod
      trigger: true
    - get: client-aws-1-prod-runtime-config
      tags:
      - client-aws-1-prod
      trigger: true
  - config:
      image_resource:
        source:
          repository: custom/concourse-image
          tag: rc1
        type: registry-image
      inputs:
      - name: client-aws-1-prod-changes
      - name: client-aws-1-prod-cache
      params:
        BOSH_CA_CERT: |
          ----- BEGIN CERTIFICATE -----
          cert-goes-here
          ----- END CERTIFICATE -----
        BOSH_CLIENT: pr-admin
        BOSH_CLIENT_SECRET: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
        BOSH_ENVIRONMENT: https://prod.bosh-lite.com:25555
        BOSH_NON_INTERACTIVE: true
        CACHE_DIR: client-aws-1-prod-cache
        CI_NO_REDACT: 1
        CURRENT_ENV: client-aws-1-prod
        DEBUG: 1
        GENESIS_HONOR_ENV: 1
        GIT_AUTHOR_EMAIL: concourse@pipeline
        GIT_AUTHOR_NAME: Concourse Bot
        GIT_BRANCH: master
        GIT_GENESIS_ROOT: cf/legacy
        GIT_PRIVATE_KEY: |
          -----BEGIN RSA PRIVATE KEY-----
          lol. you didn't really think that
          we'd put the key here, in a test,
          did you?!
          -----END RSA PRIVATE KEY-----
        OUT_DIR: out/git
        PREVIOUS_ENV: client-aws-1-preprod
        VAULT_ADDR: http://myvault.myorg.com:5999
        VAULT_ROLE_ID: this-is-a-role
        VAULT_SECRET_ID: this-is-a-secret
        VAULT_SKIP_VERIFY: true
        WORKING_DIR: client-aws-1-prod-changes
      platform: linux
      run:
        args:
        - ci-show-changes
        path: client-aws-1-prod-cache/cf/legacy/.genesis/bin/genesis
    tags:
    - client-aws-1-prod
    task: show-pending-changes
  - in_parallel:
    - params:
        channel: '#botspam'
        icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
        text: 'aws-1: Changes are staged to be deployed to client-aws-1-prod-pipeline-test,
          see notify-client-aws-1-prod-pipeline-test-changes job for change summary,
          then schedule and run a deploy via Concourse'
        username: runwaybot
      put: slack
    - params:
        color: gray
        from: runwaybot
        message: 'aws-1: Changes are staged to be deployed to client-aws-1-prod-pipeline-test,
          see notify-client-aws-1-prod-pipeline-test-changes job for change summary,
          then schedule and run a deploy via Concourse'
        notify: false
      put: hipchat
  public: true
  serial: true
- name: client-aws-1-prod-pipeline-test
  plan:
  - do:
    - params:
        key: dont-upgrade-bosh-on-me
        lock_op: lock
        locked_by: client-aws-1-prod-pipeline-test
      put: client-aws-1-prod-bosh-lock
      tags:
      - client-aws-1-prod
    - params:
        key: i-need-to-deploy-myself
        lock_op: lock
        locked_by: client-aws-1-prod-pipeline-test
      put: client-aws-1-prod-deployment-lock
      tags:
      - client-aws-1-prod
    - in_parallel:
      - get: client-aws-1-prod-changes
        passed:
        - notify-client-aws-1-prod-pipeline-test-changes
        trigger: false
      - get: client-aws-1-prod-cache
        passed:
        - notify-client-aws-1-prod-pipeline-test-changes
        trigger: false
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: client-aws-1-prod-changes
        - name: client-aws-1-prod-cache
        outputs:
        - name: out
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: pr-admin
          BOSH_CLIENT_SECRET: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
          BOSH_ENVIRONMENT: https://prod.bosh-lite.com:25555
          BOSH_NON_INTERACTIVE: true
          CACHE_DIR: client-aws-1-prod-cache
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-prod
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_GENESIS_ROOT: cf/legacy
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: out/git
          PREVIOUS_ENV: client-aws-1-preprod
          VAULT_ADDR: http://myvault.myorg.com:5999
          VAULT_ROLE_ID: this-is-a-role
          VAULT_SECRET_ID: this-is-a-secret
          VAULT_SKIP_VERIFY: true
          WORKING_DIR: client-aws-1-prod-changes
        platform: linux
        run:
          args:
          - ci-pipeline-deploy
          path: client-aws-1-prod-cache/cf/legacy/.genesis/bin/genesis
      ensure:
        params:
          repository: out/git
        put: git
      tags:
      - client-aws-1-prod
      task: bosh-deploy
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-prod-cache
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: pr-admin
          BOSH_CLIENT_SECRET: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
          BOSH_ENVIRONMENT: https://prod.bosh-lite.com:25555
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-prod
          DEBUG: 1
          ERRAND_NAME: run-something-good
          GENESIS_HONOR_ENV: 1
        platform: linux
        run:
          args:
          - ci-pipeline-run-errand
          dir: out/git/cf/legacy
          path: ../../client-aws-1-prod-cache/cf/legacy/.genesis/bin/genesis
      tags:
      - client-aws-1-prod
      task: run-something-good-errand
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-prod-cache
        outputs:
        - name: cache-out
        params:
          CACHE_DIR: client-aws-1-prod-cache
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-prod
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_GENESIS_ROOT: cf/legacy
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: cache-out/git
          PREVIOUS_ENV: client-aws-1-preprod
          WORKING_DIR: out/git
        platform: linux
        run:
          args:
          - ci-generate-cache
          path: client-aws-1-prod-cache/cf/legacy/.genesis/bin/genesis
      tags:
      - client-aws-1-prod
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    ensure:
      do:
      - params:
          key: dont-upgrade-bosh-on-me
          lock_op: unlock
          locked_by: client-aws-1-prod-pipeline-test
        put: client-aws-1-prod-bosh-lock
        tags:
        - client-aws-1-prod
      - params:
          key: i-need-to-deploy-myself
          lock_op: unlock
          locked_by: client-aws-1-prod-pipeline-test
        put: client-aws-1-prod-deployment-lock
        tags:
        - client-aws-1-prod
    on_failure:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-prod-pipeline-test failed'
          username: runwaybot
        put: slack
      - params:
          color: gray
          from: runwaybot
          message: 'aws-1: Concourse deployment to client-aws-1-prod-pipeline-test
            failed'
          notify: false
        put: hipchat
    on_success:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse successfully deployed client-aws-1-prod-pipeline-test'
          username: runwaybot
        put: slack
      - params:
          color: gray
          from: runwaybot
          message: 'aws-1: Concourse successfully deployed client-aws-1-prod-pipeline-test'
          notify: false
        put: hipchat
  public: true
  serial: true
- name: client-aws-1-sandbox-pipeline-test
  plan:
  - do:
    - params:
        key: dont-upgrade-bosh-on-me
        lock_op: lock
        locked_by: client-aws-1-sandbox-pipeline-test
      put: client-aws-1-sandbox-bosh-lock
      tags:
      - client-aws-1-sandbox
    - params:
        key: i-need-to-deploy-myself
        lock_op: lock
        locked_by: client-aws-1-sandbox-pipeline-test
      put: client-aws-1-sandbox-deployment-lock
      tags:
      - client-aws-1-sandbox
      tags:
      - client-aws-1-sandbox
    - in_parallel:
      - get: client-aws-1-sandbox-cloud-config
        tags:
        - client-aws-1-sandbox
        trigger: true
      - get: client-aws-1-sandbox-runtime-config
        tags:
        - client-aws-1-sandbox
        trigger: true
      - get: client-aws-1-sandbox-changes
        trigger: true
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: client-aws-1-sandbox-changes
        outputs:
        - name: out
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: sb-admin
          BOSH_CLIENT_SECRET: PaeM2Eip
          BOSH_ENVIRONMENT: https://sandbox.bosh-lite.com:25555
          BOSH_NON_INTERACTIVE: true
          CACHE_DIR: client-aws-1-sandbox-cache
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-sandbox
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_GENESIS_ROOT: cf/legacy
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: out/git
          PREVIOUS_ENV: null
          VAULT_ADDR: http://myvault.myorg.com:5999
          VAULT_ROLE_ID: this-is-a-role
          VAULT_SECRET_ID: this-is-a-secret
          VAULT_SKIP_VERIFY: true
          WORKING_DIR: client-aws-1-sandbox-changes
        platform: linux
        run:
          args:
          - ci-pipeline-deploy
          path: client-aws-1-sandbox-changes/cf/legacy/.genesis/bin/genesis
      ensure:
        params:
          repository: out/git
        put: git
      privileged: true
      tags:
      - client-aws-1-sandbox
      task: bosh-deploy
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-sandbox-changes
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: sb-admin
          BOSH_CLIENT_SECRET: PaeM2Eip
          BOSH_ENVIRONMENT: https://sandbox.bosh-lite.com:25555
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-sandbox
          DEBUG: 1
          ERRAND_NAME: run-something-good
          GENESIS_HONOR_ENV: 1
        platform: linux
        run:
          args:
          - ci-pipeline-run-errand
          dir: out/git/cf/legacy
          path: ../../client-aws-1-sandbox-changes/cf/legacy/.genesis/bin/genesis
      tags:
      - client-aws-1-sandbox
      task: run-something-good-errand
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-sandbox-changes
        outputs:
        - name: cache-out
        params:
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-sandbox
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_GENESIS_ROOT: cf/legacy
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: cache-out/git
          WORKING_DIR: out/git
        platform: linux
        run:
          args:
          - ci-generate-cache
          path: client-aws-1-sandbox-changes/cf/legacy/.genesis/bin/genesis
      tags:
      - client-aws-1-sandbox
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    - params:
        repository: cache-out/git
      put: client-aws-1-preprod-cache
    ensure:
      do:
      - params:
          key: dont-upgrade-bosh-on-me
          lock_op: unlock
          locked_by: client-aws-1-sandbox-pipeline-test
        put: client-aws-1-sandbox-bosh-lock
        tags:
        - client-aws-1-sandbox
      - params:
          key: i-need-to-deploy-myself
          lock_op: unlock
          locked_by: client-aws-1-sandbox-pipeline-test
        put: client-aws-1-sandbox-deployment-lock
        tags:
        - client-aws-1-sandbox
    on_failure:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-sandbox-pipeline-test
            failed'
          username: runwaybot
        put: slack
      - params:
          color: gray
          from: runwaybot
          message: 'aws-1: Concourse deployment to client-aws-1-sandbox-pipeline-test
            failed'
          notify: false
        put: hipchat
    on_success:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse successfully deployed client-aws-1-sandbox-pipeline-test'
          username: runwaybot
        put: slack
      - params:
          color: gray
          from: runwaybot
          message: 'aws-1: Concourse successfully deployed client-aws-1-sandbox-pipeline-test'
          notify: false
        put: hipchat
  public: true
  serial: true
- name: update-genesis-assets
  plan:
  - in_parallel:
    - get: git
    - get: kit-release
      trigger: true
    - get: genesis-release
  - config:
      image_resource:
        source:
          repository: custom/concourse-image
          tag: rc1
        type: registry-image
      inputs:
      - name: git
      params:
        GENESIS_KIT_NAME: somekit-genesis-kit
      platform: linux
      run:
        args:
        - -ce
        - |
          .genesis/bin/genesis list-kits ${GENESIS_KIT_NAME} -u
        dir: git/cf/legacy
        path: sh
    task: list-kits
  - config:
      image_resource:
        source:
          repository: custom/concourse-image
          tag: rc1
        type: registry-image
      inputs:
      - name: git
      - name: genesis-release
      outputs:
      - name: git
      params:
        CI_LABEL: CI
        GITHUB_EMAIL: concourse@pipeline
        GITHUB_USER: Concourse Bot
      platform: linux
      run:
        args:
        - -ce
        - |
          chmod +x ../genesis-release/genesis
          upstream="$(../genesis-release/genesis -v 2>/dev/null | sed -e 's/Genesis v\([^ ]*\) .*/\1/')"
          current="$('cf/legacy/.genesis/bin/genesis' -v 2>/dev/null | sed -e 's/Genesis v\([^ ]*\) .*/\1/')"
          if [[ -z "$upstream" || ! "$upstream" =~ ^[0-9]+(.[0-9]+){2}(-rc[0-9]+)?$ ]]; then
            echo >&2 "Error: could not get upstream genesis version"
            exit 1
          fi
          if [[ -z "$current" || ! "$current" =~ ^[0-9]+(.[0-9]+){2}(-rc[0-9]+)?$ ]]; then
            echo >&2 "Error: could not get embedded genesis version"
            exit 1
          fi
          if ../genesis-release/genesis ui-semver $upstream ge $current && \
           ! ../genesis-release/genesis ui-semver $current ge $upstream ; then
            ../genesis-release/genesis -C 'cf/legacy' embed
            if ! git diff --stat --exit-code 'cf/legacy/.genesis/bin/genesis'; then
              git config --global user.email "${GITHUB_EMAIL}"
              git config --global user.name "${GITHUB_USER}"
              git add 'cf/legacy/.genesis/bin/genesis'
              git commit -m "[${CI_LABEL}] bump genesis to $('cf/legacy/.genesis/bin/genesis' version) under cf/legacy"
            fi
          fi
        dir: git
        path: bash
    task: update-genesis
  - config:
      image_resource:
        source:
          repository: custom/concourse-image
          tag: rc1
        type: registry-image
      inputs:
      - name: git
      - name: kit-release
      outputs:
      - name: git
      params:
        CI_LABEL: CI
        GENESIS_KIT_NAME: somekit
        GITHUB_AUTH_TOKEN: borkborkbork
        GITHUB_EMAIL: concourse@pipeline
        GITHUB_USER: Concourse Bot
        KIT_VERSION_FILE: client.yml
      platform: linux
      run:
        args:
        - -ce
        - |
          version="$(cat ../kit-release/version)"
          pushd 'cf/legacy' &> /dev/null
          if ! .genesis/bin/genesis --no-color list-kits ${GENESIS_KIT_NAME} | grep "v$version\$"; then
            .genesis/bin/genesis fetch-kit ${GENESIS_KIT_NAME}/$version
          fi
          sed -i'' "/^kit:/,/^  version:/{s/version.*/version: $version/}" "${KIT_VERSION_FILE}"
          if git diff --stat --exit-code '.genesis/kits' "${KIT_VERSION_FILE}"; then
            echo "No change detected - still using ${GENESIS_KIT_NAME}/$version under cf/legacy"
            exit 0
          fi
          git config --global user.email "${GITHUB_EMAIL}"
          git config --global user.name "${GITHUB_USER}"
          git add '.genesis/kits' "${KIT_VERSION_FILE}"
          popd &> /dev/null
          git commit -m "[${CI_LABEL}] bump kit ${GENESIS_KIT_NAME} to version $version under cf/legacy"
        dir: git
        path: bash
    task: fetch-kit
  - params:
      rebase: true
      repository: git
    put: git
resource_types:
- name: script
  source:
    repository: cfcommunity/script-resource
  type: registry-image
- name: email
  source:
    repository: pcfseceng/email-resource
  type: registry-image
- name: slack-notification
  source:
    repository: cfcommunity/slack-notification-resource
  type: registry-image
- name: hipchat-notification
  source:
    repository: cfcommunity/hipchat-notification-resource
  type: registry-image
- name: stride-notification
  source:
    repository: starkandwayne/stride-notification-resource
  type: registry-image
- name: bosh-config
  source:
    repository: cfcommunity/bosh-config-resource
  type: registry-image
- name: locker
  source:
    repository: cfcommunity/locker-resource
  type: registry-image
resources:
- icon: github
  name: git
  source:
    branch: master
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: github
  name: client-aws-1-preprod-changes
  source:
    branch: master
    paths:
    - cf/legacy/client-aws-1-preprod.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: github
  name: client-aws-1-preprod-cache
  source:
    branch: master
    paths:
    - cf/legacy/.genesis/bin/genesis
    - cf/legacy/.genesis/kits
    - cf/legacy/.genesis/config
    - cf/legacy/.genesis/cached/client-aws-1-sandbox/ops/*
    - cf/legacy/.genesis/cached/client-aws-1-sandbox/kit-overrides.yml
    - cf/legacy/.genesis/cached/client-aws-1-sandbox/client.yml
    - cf/legacy/.genesis/cached/client-aws-1-sandbox/client-aws.yml
    - cf/legacy/.genesis/cached/client-aws-1-sandbox/client-aws-1.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: script-text
  name: client-aws-1-preprod-cloud-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pp-admin
    client_secret: Ahti2eeth3aewohnee1Phaec
    config: cloud
    target: https://preprod.bosh-lite.com:25555
  tags:
  - client-aws-1-preprod
  type: bosh-config
- icon: script-text
  name: client-aws-1-preprod-runtime-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pp-admin
    client_secret: Ahti2eeth3aewohnee1Phaec
    config: runtime
    target: https://preprod.bosh-lite.com:25555
  tags:
  - client-aws-1-preprod
  type: bosh-config
- icon: shield-lock-outline
  name: client-aws-1-preprod-bosh-lock
  source:
    bosh_lock: https://preprod.bosh-lite.com:25555
    ca_cert: null
    locker_uri: https://127.0.0.1:8910
    password: locker
    skip_ssl_validation: true
    username: locker
  tags:
  - client-aws-1-preprod
  type: locker
- icon: shield-lock-outline
  name: client-aws-1-preprod-deployment-lock
  source:
    ca_cert: null
    lock_name: client-aws-1-preprod-pipeline-test
    locker_uri: https://127.0.0.1:8910
    password: locker
    skip_ssl_validation: true
    username: locker
  tags:
  - client-aws-1-preprod
  type: locker
- icon: github
  name: client-aws-1-prod-changes
  source:
    branch: master
    paths:
    - cf/legacy/client-aws-1-prod.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: github
  name: client-aws-1-prod-cache
  source:
    branch: master
    paths:
    - cf/legacy/.genesis/bin/genesis
    - cf/legacy/.genesis/kits
    - cf/legacy/.genesis/config
    - cf/legacy/.genesis/cached/client-aws-1-preprod/ops/*
    - cf/legacy/.genesis/cached/client-aws-1-preprod/kit-overrides.yml
    - cf/legacy/.genesis/cached/client-aws-1-preprod/client.yml
    - cf/legacy/.genesis/cached/client-aws-1-preprod/client-aws.yml
    - cf/legacy/.genesis/cached/client-aws-1-preprod/client-aws-1.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: script-text
  name: client-aws-1-prod-cloud-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pr-admin
    client_secret: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
    config: cloud
    target: https://prod.bosh-lite.com:25555
  tags:
  - client-aws-1-prod
  type: bosh-config
- icon: script-text
  name: client-aws-1-prod-runtime-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pr-admin
    client_secret: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
    config: runtime
    target: https://prod.bosh-lite.com:25555
  tags:
  - client-aws-1-prod
  type: bosh-config
- icon: shield-lock-outline
  name: client-aws-1-prod-bosh-lock
  source:
    bosh_lock: https://prod.bosh-lite.com:25555
    ca_cert: null
    locker_uri: https://127.0.0.1:8910
    password: locker
    skip_ssl_validation: true
    username: locker
  tags:
  - client-aws-1-prod
  type: locker
- icon: shield-lock-outline
  name: client-aws-1-prod-deployment-lock
  source:
    ca_cert: null
    lock_name: client-aws-1-prod-pipeline-test
    locker_uri: https://127.0.0.1:8910
    password: locker
    skip_ssl_validation: true
    username: locker
  tags:
  - client-aws-1-prod
  type: locker
- icon: github
  name: client-aws-1-sandbox-changes
  source:
    branch: master
    paths:
    - cf/legacy/.genesis/bin/genesis
    - cf/legacy/.genesis/kits
    - cf/legacy/.genesis/config
    - cf/legacy/ops/*
    - cf/legacy/kit-overrides.yml
    - cf/legacy/client.yml
    - cf/legacy/client-aws.yml
    - cf/legacy/client-aws-1.yml
    - cf/legacy/client-aws-1-sandbox.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: script-text
  name: client-aws-1-sandbox-cloud-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: sb-admin
    client_secret: PaeM2Eip
    config: cloud
    target: https://sandbox.bosh-lite.com:25555
  tags:
  - client-aws-1-sandbox
  type: bosh-config
- icon: script-text
  name: client-aws-1-sandbox-runtime-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: sb-admin
    client_secret: PaeM2Eip
    config: runtime
    target: https://sandbox.bosh-lite.com:25555
  tags:
  - client-aws-1-sandbox
  type: bosh-config
- icon: shield-lock-outline
  name: client-aws-1-sandbox-bosh-lock
  source:
    bosh_lock: https://sandbox.bosh-lite.com:25555
    ca_cert: null
    locker_uri: https://127.0.0.1:8910
    password: locker
    skip_ssl_validation: true
    username: locker
  tags:
  - client-aws-1-sandbox
  type: locker
- icon: shield-lock-outline
  name: client-aws-1-sandbox-deployment-lock
  source:
    ca_cert: null
    lock_name: client-aws-1-sandbox-pipeline-test
    locker_uri: https://127.0.0.1:8910
    password: locker
    skip_ssl_validation: true
    username: locker
  tags:
  - client-aws-1-sandbox
  type: locker
- icon: slack
  name: slack
  source:
    url: http://127.0.0.1:1337
  type: slack-notification
- icon: bell-ring
  name: hipchat
  source:
    hipchat_server_url: http://api.hipchat.com
    room_id: 1234
    token: abcdefg
  type: hipchat-notification
- check_every: 24h
  icon: package-variant
  name: kit-release
  source:
    access_token: borkborkbork
    github_api_url: https://api.mygitservice.cc/
    repository: somekit-genesis-kit
    user: someorg
  type: github-release
- check_every: 24h
  icon: leaf
  name: genesis-release
  source:
    access_token: ""
    repository: genesis
    user: genesis-community
  type: github-release
EOF
# }}}

runs_ok "genesis repipe --dry-run --config ci/aws/pipeline.parallel_notifications" and # {{{
runs_ok "genesis repipe --dry-run --config ci/aws/pipeline.parallel_notifications >$tmp/pipeline.yml" and
yaml_is get_file("$tmp/pipeline.yml"), <<'EOF', "pipeline generated for aws/pipeline (parallel notifications)";
groups:
- jobs:
  - client-aws-1-preprod-pipeline-test
  - client-aws-1-prod-pipeline-test
  - client-aws-1-sandbox-pipeline-test
  - notify-client-aws-1-preprod-pipeline-test-changes
  - notify-client-aws-1-prod-pipeline-test-changes
  name: aws-1
jobs:
- name: notify-client-aws-1-preprod-pipeline-test-changes
  plan:
  - in_parallel:
    - get: client-aws-1-preprod-changes
      trigger: true
    - get: client-aws-1-preprod-cache
      passed:
      - client-aws-1-sandbox-pipeline-test
      trigger: true
    - get: client-aws-1-preprod-cloud-config
      tags:
      - client-aws-1-preprod
      trigger: true
    - get: client-aws-1-preprod-runtime-config
      tags:
      - client-aws-1-preprod
      trigger: true
  - config:
      image_resource:
        source:
          repository: custom/concourse-image
          tag: rc1
        type: registry-image
      inputs:
      - name: client-aws-1-preprod-changes
      - name: client-aws-1-preprod-cache
      params:
        BOSH_CA_CERT: |
          ----- BEGIN CERTIFICATE -----
          cert-goes-here
          ----- END CERTIFICATE -----
        BOSH_CLIENT: pp-admin
        BOSH_CLIENT_SECRET: Ahti2eeth3aewohnee1Phaec
        BOSH_ENVIRONMENT: https://preprod.bosh-lite.com:25555
        BOSH_NON_INTERACTIVE: true
        CACHE_DIR: client-aws-1-preprod-cache
        CI_NO_REDACT: 1
        CURRENT_ENV: client-aws-1-preprod
        DEBUG: 1
        GENESIS_HONOR_ENV: 1
        GIT_AUTHOR_EMAIL: concourse@pipeline
        GIT_AUTHOR_NAME: Concourse Bot
        GIT_BRANCH: master
        GIT_PRIVATE_KEY: |
          -----BEGIN RSA PRIVATE KEY-----
          lol. you didn't really think that
          we'd put the key here, in a test,
          did you?!
          -----END RSA PRIVATE KEY-----
        OUT_DIR: out/git
        PREVIOUS_ENV: client-aws-1-sandbox
        VAULT_ADDR: http://myvault.myorg.com:5999
        VAULT_ROLE_ID: this-is-a-role
        VAULT_SECRET_ID: this-is-a-secret
        VAULT_SKIP_VERIFY: true
        WORKING_DIR: client-aws-1-preprod-changes
      platform: linux
      run:
        args:
        - ci-show-changes
        path: client-aws-1-preprod-cache/.genesis/bin/genesis
    tags:
    - client-aws-1-preprod
    task: show-pending-changes
  - in_parallel:
    - params:
        channel: '#botspam'
        icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
        text: 'aws-1: Changes are staged to be deployed to client-aws-1-preprod-pipeline-test,
          see notify-client-aws-1-preprod-pipeline-test-changes job for change summary,
          then schedule and run a deploy via Concourse'
        username: runwaybot
      put: slack
    - params:
        color: gray
        from: runwaybot
        message: 'aws-1: Changes are staged to be deployed to client-aws-1-preprod-pipeline-test,
          see notify-client-aws-1-preprod-pipeline-test-changes job for change summary,
          then schedule and run a deploy via Concourse'
        notify: false
      put: hipchat
  public: true
  serial: true
- name: client-aws-1-preprod-pipeline-test
  plan:
  - do:
    - params:
        key: dont-upgrade-bosh-on-me
        lock_op: lock
        locked_by: client-aws-1-preprod-pipeline-test
      put: client-aws-1-preprod-bosh-lock
      tags:
      - client-aws-1-preprod
    - params:
        key: i-need-to-deploy-myself
        lock_op: lock
        locked_by: client-aws-1-preprod-pipeline-test
      put: client-aws-1-preprod-deployment-lock
      tags:
      - client-aws-1-preprod
    - in_parallel:
      - get: client-aws-1-preprod-changes
        trigger: false
      - get: client-aws-1-preprod-cache
        passed:
        - client-aws-1-sandbox-pipeline-test
        trigger: false
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: client-aws-1-preprod-changes
        - name: client-aws-1-preprod-cache
        outputs:
        - name: out
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: pp-admin
          BOSH_CLIENT_SECRET: Ahti2eeth3aewohnee1Phaec
          BOSH_ENVIRONMENT: https://preprod.bosh-lite.com:25555
          BOSH_NON_INTERACTIVE: true
          CACHE_DIR: client-aws-1-preprod-cache
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-preprod
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: out/git
          PREVIOUS_ENV: client-aws-1-sandbox
          VAULT_ADDR: http://myvault.myorg.com:5999
          VAULT_ROLE_ID: this-is-a-role
          VAULT_SECRET_ID: this-is-a-secret
          VAULT_SKIP_VERIFY: true
          WORKING_DIR: client-aws-1-preprod-changes
        platform: linux
        run:
          args:
          - ci-pipeline-deploy
          path: client-aws-1-preprod-cache/.genesis/bin/genesis
      ensure:
        params:
          repository: out/git
        put: git
      tags:
      - client-aws-1-preprod
      task: bosh-deploy
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-preprod-cache
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: pp-admin
          BOSH_CLIENT_SECRET: Ahti2eeth3aewohnee1Phaec
          BOSH_ENVIRONMENT: https://preprod.bosh-lite.com:25555
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-preprod
          DEBUG: 1
          ERRAND_NAME: run-something-good
          GENESIS_HONOR_ENV: 1
        platform: linux
        run:
          args:
          - ci-pipeline-run-errand
          dir: out/git
          path: ../../client-aws-1-preprod-cache/.genesis/bin/genesis
      tags:
      - client-aws-1-preprod
      task: run-something-good-errand
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-preprod-cache
        outputs:
        - name: cache-out
        params:
          CACHE_DIR: client-aws-1-preprod-cache
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-preprod
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: cache-out/git
          PREVIOUS_ENV: client-aws-1-sandbox
          WORKING_DIR: out/git
        platform: linux
        run:
          args:
          - ci-generate-cache
          path: client-aws-1-preprod-cache/.genesis/bin/genesis
      tags:
      - client-aws-1-preprod
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    - params:
        repository: cache-out/git
      put: client-aws-1-prod-cache
    ensure:
      do:
      - params:
          key: dont-upgrade-bosh-on-me
          lock_op: unlock
          locked_by: client-aws-1-preprod-pipeline-test
        put: client-aws-1-preprod-bosh-lock
        tags:
        - client-aws-1-preprod
      - params:
          key: i-need-to-deploy-myself
          lock_op: unlock
          locked_by: client-aws-1-preprod-pipeline-test
        put: client-aws-1-preprod-deployment-lock
        tags:
        - client-aws-1-preprod
    on_failure:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-preprod-pipeline-test
            failed'
          username: runwaybot
        put: slack
      - params:
          color: gray
          from: runwaybot
          message: 'aws-1: Concourse deployment to client-aws-1-preprod-pipeline-test
            failed'
          notify: false
        put: hipchat
    on_success:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse successfully deployed client-aws-1-preprod-pipeline-test'
          username: runwaybot
        put: slack
      - params:
          color: gray
          from: runwaybot
          message: 'aws-1: Concourse successfully deployed client-aws-1-preprod-pipeline-test'
          notify: false
        put: hipchat
  public: true
  serial: true
- name: notify-client-aws-1-prod-pipeline-test-changes
  plan:
  - in_parallel:
    - get: client-aws-1-prod-changes
      trigger: true
    - get: client-aws-1-prod-cache
      passed:
      - client-aws-1-preprod-pipeline-test
      trigger: true
    - get: client-aws-1-prod-cloud-config
      tags:
      - client-aws-1-prod
      trigger: true
    - get: client-aws-1-prod-runtime-config
      tags:
      - client-aws-1-prod
      trigger: true
  - config:
      image_resource:
        source:
          repository: custom/concourse-image
          tag: rc1
        type: registry-image
      inputs:
      - name: client-aws-1-prod-changes
      - name: client-aws-1-prod-cache
      params:
        BOSH_CA_CERT: |
          ----- BEGIN CERTIFICATE -----
          cert-goes-here
          ----- END CERTIFICATE -----
        BOSH_CLIENT: pr-admin
        BOSH_CLIENT_SECRET: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
        BOSH_ENVIRONMENT: https://prod.bosh-lite.com:25555
        BOSH_NON_INTERACTIVE: true
        CACHE_DIR: client-aws-1-prod-cache
        CI_NO_REDACT: 1
        CURRENT_ENV: client-aws-1-prod
        DEBUG: 1
        GENESIS_HONOR_ENV: 1
        GIT_AUTHOR_EMAIL: concourse@pipeline
        GIT_AUTHOR_NAME: Concourse Bot
        GIT_BRANCH: master
        GIT_PRIVATE_KEY: |
          -----BEGIN RSA PRIVATE KEY-----
          lol. you didn't really think that
          we'd put the key here, in a test,
          did you?!
          -----END RSA PRIVATE KEY-----
        OUT_DIR: out/git
        PREVIOUS_ENV: client-aws-1-preprod
        VAULT_ADDR: http://myvault.myorg.com:5999
        VAULT_ROLE_ID: this-is-a-role
        VAULT_SECRET_ID: this-is-a-secret
        VAULT_SKIP_VERIFY: true
        WORKING_DIR: client-aws-1-prod-changes
      platform: linux
      run:
        args:
        - ci-show-changes
        path: client-aws-1-prod-cache/.genesis/bin/genesis
    tags:
    - client-aws-1-prod
    task: show-pending-changes
  - in_parallel:
    - params:
        channel: '#botspam'
        icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
        text: 'aws-1: Changes are staged to be deployed to client-aws-1-prod-pipeline-test,
          see notify-client-aws-1-prod-pipeline-test-changes job for change summary,
          then schedule and run a deploy via Concourse'
        username: runwaybot
      put: slack
    - params:
        color: gray
        from: runwaybot
        message: 'aws-1: Changes are staged to be deployed to client-aws-1-prod-pipeline-test,
          see notify-client-aws-1-prod-pipeline-test-changes job for change summary,
          then schedule and run a deploy via Concourse'
        notify: false
      put: hipchat
  public: true
  serial: true
- name: client-aws-1-prod-pipeline-test
  plan:
  - do:
    - params:
        key: dont-upgrade-bosh-on-me
        lock_op: lock
        locked_by: client-aws-1-prod-pipeline-test
      put: client-aws-1-prod-bosh-lock
      tags:
      - client-aws-1-prod
    - params:
        key: i-need-to-deploy-myself
        lock_op: lock
        locked_by: client-aws-1-prod-pipeline-test
      put: client-aws-1-prod-deployment-lock
      tags:
      - client-aws-1-prod
    - in_parallel:
      - get: client-aws-1-prod-changes
        trigger: false
      - get: client-aws-1-prod-cache
        passed:
        - client-aws-1-preprod-pipeline-test
        trigger: false
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: client-aws-1-prod-changes
        - name: client-aws-1-prod-cache
        outputs:
        - name: out
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: pr-admin
          BOSH_CLIENT_SECRET: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
          BOSH_ENVIRONMENT: https://prod.bosh-lite.com:25555
          BOSH_NON_INTERACTIVE: true
          CACHE_DIR: client-aws-1-prod-cache
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-prod
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: out/git
          PREVIOUS_ENV: client-aws-1-preprod
          VAULT_ADDR: http://myvault.myorg.com:5999
          VAULT_ROLE_ID: this-is-a-role
          VAULT_SECRET_ID: this-is-a-secret
          VAULT_SKIP_VERIFY: true
          WORKING_DIR: client-aws-1-prod-changes
        platform: linux
        run:
          args:
          - ci-pipeline-deploy
          path: client-aws-1-prod-cache/.genesis/bin/genesis
      ensure:
        params:
          repository: out/git
        put: git
      tags:
      - client-aws-1-prod
      task: bosh-deploy
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-prod-cache
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: pr-admin
          BOSH_CLIENT_SECRET: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
          BOSH_ENVIRONMENT: https://prod.bosh-lite.com:25555
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-prod
          DEBUG: 1
          ERRAND_NAME: run-something-good
          GENESIS_HONOR_ENV: 1
        platform: linux
        run:
          args:
          - ci-pipeline-run-errand
          dir: out/git
          path: ../../client-aws-1-prod-cache/.genesis/bin/genesis
      tags:
      - client-aws-1-prod
      task: run-something-good-errand
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-prod-cache
        outputs:
        - name: cache-out
        params:
          CACHE_DIR: client-aws-1-prod-cache
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-prod
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: cache-out/git
          PREVIOUS_ENV: client-aws-1-preprod
          WORKING_DIR: out/git
        platform: linux
        run:
          args:
          - ci-generate-cache
          path: client-aws-1-prod-cache/.genesis/bin/genesis
      tags:
      - client-aws-1-prod
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    ensure:
      do:
      - params:
          key: dont-upgrade-bosh-on-me
          lock_op: unlock
          locked_by: client-aws-1-prod-pipeline-test
        put: client-aws-1-prod-bosh-lock
        tags:
        - client-aws-1-prod
      - params:
          key: i-need-to-deploy-myself
          lock_op: unlock
          locked_by: client-aws-1-prod-pipeline-test
        put: client-aws-1-prod-deployment-lock
        tags:
        - client-aws-1-prod
    on_failure:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-prod-pipeline-test failed'
          username: runwaybot
        put: slack
      - params:
          color: gray
          from: runwaybot
          message: 'aws-1: Concourse deployment to client-aws-1-prod-pipeline-test
            failed'
          notify: false
        put: hipchat
    on_success:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse successfully deployed client-aws-1-prod-pipeline-test'
          username: runwaybot
        put: slack
      - params:
          color: gray
          from: runwaybot
          message: 'aws-1: Concourse successfully deployed client-aws-1-prod-pipeline-test'
          notify: false
        put: hipchat
  public: true
  serial: true
- name: client-aws-1-sandbox-pipeline-test
  plan:
  - do:
    - params:
        key: dont-upgrade-bosh-on-me
        lock_op: lock
        locked_by: client-aws-1-sandbox-pipeline-test
      put: client-aws-1-sandbox-bosh-lock
      tags:
      - client-aws-1-sandbox
    - params:
        key: i-need-to-deploy-myself
        lock_op: lock
        locked_by: client-aws-1-sandbox-pipeline-test
      put: client-aws-1-sandbox-deployment-lock
      tags:
      - client-aws-1-sandbox
      tags:
      - client-aws-1-sandbox
    - in_parallel:
      - get: client-aws-1-sandbox-cloud-config
        tags:
        - client-aws-1-sandbox
        trigger: true
      - get: client-aws-1-sandbox-runtime-config
        tags:
        - client-aws-1-sandbox
        trigger: true
      - get: client-aws-1-sandbox-changes
        trigger: true
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: client-aws-1-sandbox-changes
        outputs:
        - name: out
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: sb-admin
          BOSH_CLIENT_SECRET: PaeM2Eip
          BOSH_ENVIRONMENT: https://sandbox.bosh-lite.com:25555
          BOSH_NON_INTERACTIVE: true
          CACHE_DIR: client-aws-1-sandbox-cache
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-sandbox
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: out/git
          PREVIOUS_ENV: null
          VAULT_ADDR: http://myvault.myorg.com:5999
          VAULT_ROLE_ID: this-is-a-role
          VAULT_SECRET_ID: this-is-a-secret
          VAULT_SKIP_VERIFY: true
          WORKING_DIR: client-aws-1-sandbox-changes
        platform: linux
        run:
          args:
          - ci-pipeline-deploy
          path: client-aws-1-sandbox-changes/.genesis/bin/genesis
      ensure:
        params:
          repository: out/git
        put: git
      tags:
      - client-aws-1-sandbox
      task: bosh-deploy
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-sandbox-changes
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: sb-admin
          BOSH_CLIENT_SECRET: PaeM2Eip
          BOSH_ENVIRONMENT: https://sandbox.bosh-lite.com:25555
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-sandbox
          DEBUG: 1
          ERRAND_NAME: run-something-good
          GENESIS_HONOR_ENV: 1
        platform: linux
        run:
          args:
          - ci-pipeline-run-errand
          dir: out/git
          path: ../../client-aws-1-sandbox-changes/.genesis/bin/genesis
      tags:
      - client-aws-1-sandbox
      task: run-something-good-errand
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-sandbox-changes
        outputs:
        - name: cache-out
        params:
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-sandbox
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: cache-out/git
          WORKING_DIR: out/git
        platform: linux
        run:
          args:
          - ci-generate-cache
          path: client-aws-1-sandbox-changes/.genesis/bin/genesis
      tags:
      - client-aws-1-sandbox
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    - params:
        repository: cache-out/git
      put: client-aws-1-preprod-cache
    ensure:
      do:
      - params:
          key: dont-upgrade-bosh-on-me
          lock_op: unlock
          locked_by: client-aws-1-sandbox-pipeline-test
        put: client-aws-1-sandbox-bosh-lock
        tags:
        - client-aws-1-sandbox
      - params:
          key: i-need-to-deploy-myself
          lock_op: unlock
          locked_by: client-aws-1-sandbox-pipeline-test
        put: client-aws-1-sandbox-deployment-lock
        tags:
        - client-aws-1-sandbox
    on_failure:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-sandbox-pipeline-test
            failed'
          username: runwaybot
        put: slack
      - params:
          color: gray
          from: runwaybot
          message: 'aws-1: Concourse deployment to client-aws-1-sandbox-pipeline-test
            failed'
          notify: false
        put: hipchat
    on_success:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse successfully deployed client-aws-1-sandbox-pipeline-test'
          username: runwaybot
        put: slack
      - params:
          color: gray
          from: runwaybot
          message: 'aws-1: Concourse successfully deployed client-aws-1-sandbox-pipeline-test'
          notify: false
        put: hipchat
  public: true
  serial: true
resource_types:
- name: script
  source:
    repository: cfcommunity/script-resource
  type: registry-image
- name: email
  source:
    repository: pcfseceng/email-resource
  type: registry-image
- name: slack-notification
  source:
    repository: cfcommunity/slack-notification-resource
  type: registry-image
- name: hipchat-notification
  source:
    repository: cfcommunity/hipchat-notification-resource
  type: registry-image
- name: stride-notification
  source:
    repository: starkandwayne/stride-notification-resource
  type: registry-image
- name: bosh-config
  source:
    repository: cfcommunity/bosh-config-resource
  type: registry-image
- name: locker
  source:
    repository: cfcommunity/locker-resource
  type: registry-image
resources:
- icon: github
  name: git
  source:
    branch: master
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: github
  name: client-aws-1-preprod-changes
  source:
    branch: master
    paths:
    - client-aws-1-preprod.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: github
  name: client-aws-1-preprod-cache
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
    - .genesis/cached/client-aws-1-sandbox/ops/*
    - .genesis/cached/client-aws-1-sandbox/kit-overrides.yml
    - .genesis/cached/client-aws-1-sandbox/client.yml
    - .genesis/cached/client-aws-1-sandbox/client-aws.yml
    - .genesis/cached/client-aws-1-sandbox/client-aws-1.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: script-text
  name: client-aws-1-preprod-cloud-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pp-admin
    client_secret: Ahti2eeth3aewohnee1Phaec
    config: cloud
    target: https://preprod.bosh-lite.com:25555
  tags:
  - client-aws-1-preprod
  type: bosh-config
- icon: script-text
  name: client-aws-1-preprod-runtime-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pp-admin
    client_secret: Ahti2eeth3aewohnee1Phaec
    config: runtime
    target: https://preprod.bosh-lite.com:25555
  tags:
  - client-aws-1-preprod
  type: bosh-config
- icon: shield-lock-outline
  name: client-aws-1-preprod-bosh-lock
  source:
    bosh_lock: https://preprod.bosh-lite.com:25555
    ca_cert: null
    locker_uri: https://127.0.0.1:8910
    password: locker
    skip_ssl_validation: true
    username: locker
  tags:
  - client-aws-1-preprod
  type: locker
- icon: shield-lock-outline
  name: client-aws-1-preprod-deployment-lock
  source:
    ca_cert: null
    lock_name: client-aws-1-preprod-pipeline-test
    locker_uri: https://127.0.0.1:8910
    password: locker
    skip_ssl_validation: true
    username: locker
  tags:
  - client-aws-1-preprod
  type: locker
- icon: github
  name: client-aws-1-prod-changes
  source:
    branch: master
    paths:
    - client-aws-1-prod.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: github
  name: client-aws-1-prod-cache
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
    - .genesis/cached/client-aws-1-preprod/ops/*
    - .genesis/cached/client-aws-1-preprod/kit-overrides.yml
    - .genesis/cached/client-aws-1-preprod/client.yml
    - .genesis/cached/client-aws-1-preprod/client-aws.yml
    - .genesis/cached/client-aws-1-preprod/client-aws-1.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: script-text
  name: client-aws-1-prod-cloud-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pr-admin
    client_secret: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
    config: cloud
    target: https://prod.bosh-lite.com:25555
  tags:
  - client-aws-1-prod
  type: bosh-config
- icon: script-text
  name: client-aws-1-prod-runtime-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pr-admin
    client_secret: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
    config: runtime
    target: https://prod.bosh-lite.com:25555
  tags:
  - client-aws-1-prod
  type: bosh-config
- icon: shield-lock-outline
  name: client-aws-1-prod-bosh-lock
  source:
    bosh_lock: https://prod.bosh-lite.com:25555
    ca_cert: null
    locker_uri: https://127.0.0.1:8910
    password: locker
    skip_ssl_validation: true
    username: locker
  tags:
  - client-aws-1-prod
  type: locker
- icon: shield-lock-outline
  name: client-aws-1-prod-deployment-lock
  source:
    ca_cert: null
    lock_name: client-aws-1-prod-pipeline-test
    locker_uri: https://127.0.0.1:8910
    password: locker
    skip_ssl_validation: true
    username: locker
  tags:
  - client-aws-1-prod
  type: locker
- icon: github
  name: client-aws-1-sandbox-changes
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
    - ops/*
    - kit-overrides.yml
    - client.yml
    - client-aws.yml
    - client-aws-1.yml
    - client-aws-1-sandbox.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: script-text
  name: client-aws-1-sandbox-cloud-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: sb-admin
    client_secret: PaeM2Eip
    config: cloud
    target: https://sandbox.bosh-lite.com:25555
  tags:
  - client-aws-1-sandbox
  type: bosh-config
- icon: script-text
  name: client-aws-1-sandbox-runtime-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: sb-admin
    client_secret: PaeM2Eip
    config: runtime
    target: https://sandbox.bosh-lite.com:25555
  tags:
  - client-aws-1-sandbox
  type: bosh-config
- icon: shield-lock-outline
  name: client-aws-1-sandbox-bosh-lock
  source:
    bosh_lock: https://sandbox.bosh-lite.com:25555
    ca_cert: null
    locker_uri: https://127.0.0.1:8910
    password: locker
    skip_ssl_validation: true
    username: locker
  tags:
  - client-aws-1-sandbox
  type: locker
- icon: shield-lock-outline
  name: client-aws-1-sandbox-deployment-lock
  source:
    ca_cert: null
    lock_name: client-aws-1-sandbox-pipeline-test
    locker_uri: https://127.0.0.1:8910
    password: locker
    skip_ssl_validation: true
    username: locker
  tags:
  - client-aws-1-sandbox
  type: locker
- icon: slack
  name: slack
  source:
    url: http://127.0.0.1:1337
  type: slack-notification
- icon: bell-ring
  name: hipchat
  source:
    hipchat_server_url: http://api.hipchat.com
    room_id: 1234
    token: abcdefg
  type: hipchat-notification
EOF
# }}}

runs_ok "genesis repipe --dry-run --config ci/aws/pipeline.groups" and # {{{
runs_ok "genesis repipe --dry-run --config ci/aws/pipeline.groups >$tmp/pipeline.yml" and
yaml_is get_file("$tmp/pipeline.yml"), <<'EOF', "pipeline generated for aws/pipeline (with groups)";
groups:
- jobs:
  - client-aws-1-preprod-pipeline-test
  - client-aws-1-prod-pipeline-test
  - notify-client-aws-1-prod-pipeline-test-changes
  - client-aws-1-sandbox-pipeline-test
  name: allinone
- jobs:
  - client-aws-1-preprod-pipeline-test
  - client-aws-1-sandbox-pipeline-test
  name: group1
- jobs:
  - client-aws-1-preprod-pipeline-test
  - client-aws-1-prod-pipeline-test
  - notify-client-aws-1-prod-pipeline-test-changes
  name: group2
jobs:
- name: client-aws-1-preprod-pipeline-test
  plan:
  - do:
    - params:
        key: dont-upgrade-bosh-on-me
        lock_op: lock
        locked_by: client-aws-1-preprod-pipeline-test
      put: client-aws-1-preprod-bosh-lock
      tags:
      - client-aws-1-preprod
    - params:
        key: i-need-to-deploy-myself
        lock_op: lock
        locked_by: client-aws-1-preprod-pipeline-test
      put: client-aws-1-preprod-deployment-lock
      tags:
      - client-aws-1-preprod
    - in_parallel:
      - get: client-aws-1-preprod-cloud-config
        tags:
        - client-aws-1-preprod
        trigger: true
      - get: client-aws-1-preprod-runtime-config
        tags:
        - client-aws-1-preprod
        trigger: true
      - get: client-aws-1-preprod-changes
        trigger: true
      - get: client-aws-1-preprod-cache
        passed:
        - client-aws-1-sandbox-pipeline-test
        trigger: true
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: client-aws-1-preprod-changes
        - name: client-aws-1-preprod-cache
        outputs:
        - name: out
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: pp-admin
          BOSH_CLIENT_SECRET: Ahti2eeth3aewohnee1Phaec
          BOSH_ENVIRONMENT: https://preprod.bosh-lite.com:25555
          BOSH_NON_INTERACTIVE: true
          CACHE_DIR: client-aws-1-preprod-cache
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-preprod
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: out/git
          PREVIOUS_ENV: client-aws-1-sandbox
          VAULT_ADDR: http://myvault.myorg.com:5999
          VAULT_ROLE_ID: this-is-a-role
          VAULT_SECRET_ID: this-is-a-secret
          VAULT_SKIP_VERIFY: true
          WORKING_DIR: client-aws-1-preprod-changes
        platform: linux
        run:
          args:
          - ci-pipeline-deploy
          path: client-aws-1-preprod-cache/.genesis/bin/genesis
      ensure:
        params:
          repository: out/git
        put: git
      tags:
      - client-aws-1-preprod
      task: bosh-deploy
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-preprod-cache
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: pp-admin
          BOSH_CLIENT_SECRET: Ahti2eeth3aewohnee1Phaec
          BOSH_ENVIRONMENT: https://preprod.bosh-lite.com:25555
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-preprod
          DEBUG: 1
          ERRAND_NAME: run-something-good
          GENESIS_HONOR_ENV: 1
        platform: linux
        run:
          args:
          - ci-pipeline-run-errand
          dir: out/git
          path: ../../client-aws-1-preprod-cache/.genesis/bin/genesis
      tags:
      - client-aws-1-preprod
      task: run-something-good-errand
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-preprod-cache
        outputs:
        - name: cache-out
        params:
          CACHE_DIR: client-aws-1-preprod-cache
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-preprod
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: cache-out/git
          PREVIOUS_ENV: client-aws-1-sandbox
          WORKING_DIR: out/git
        platform: linux
        run:
          args:
          - ci-generate-cache
          path: client-aws-1-preprod-cache/.genesis/bin/genesis
      tags:
      - client-aws-1-preprod
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    - params:
        repository: cache-out/git
      put: client-aws-1-prod-cache
    ensure:
      do:
      - params:
          key: dont-upgrade-bosh-on-me
          lock_op: unlock
          locked_by: client-aws-1-preprod-pipeline-test
        put: client-aws-1-preprod-bosh-lock
        tags:
        - client-aws-1-preprod
      - params:
          key: i-need-to-deploy-myself
          lock_op: unlock
          locked_by: client-aws-1-preprod-pipeline-test
        put: client-aws-1-preprod-deployment-lock
        tags:
        - client-aws-1-preprod
    on_failure:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-preprod-pipeline-test
            failed'
          username: runwaybot
        put: slack
      - params:
          color: gray
          from: runwaybot
          message: 'aws-1: Concourse deployment to client-aws-1-preprod-pipeline-test
            failed'
          notify: false
        put: hipchat
    on_success:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse successfully deployed client-aws-1-preprod-pipeline-test'
          username: runwaybot
        put: slack
      - params:
          color: gray
          from: runwaybot
          message: 'aws-1: Concourse successfully deployed client-aws-1-preprod-pipeline-test'
          notify: false
        put: hipchat
  public: true
  serial: true
- name: notify-client-aws-1-prod-pipeline-test-changes
  plan:
  - in_parallel:
    - get: client-aws-1-prod-changes
      trigger: true
    - get: client-aws-1-prod-cache
      passed:
      - client-aws-1-preprod-pipeline-test
      trigger: true
    - get: client-aws-1-prod-cloud-config
      tags:
      - client-aws-1-prod
      trigger: true
    - get: client-aws-1-prod-runtime-config
      tags:
      - client-aws-1-prod
      trigger: true
  - config:
      image_resource:
        source:
          repository: custom/concourse-image
          tag: rc1
        type: registry-image
      inputs:
      - name: client-aws-1-prod-changes
      - name: client-aws-1-prod-cache
      params:
        BOSH_CA_CERT: |
          ----- BEGIN CERTIFICATE -----
          cert-goes-here
          ----- END CERTIFICATE -----
        BOSH_CLIENT: pr-admin
        BOSH_CLIENT_SECRET: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
        BOSH_ENVIRONMENT: https://prod.bosh-lite.com:25555
        BOSH_NON_INTERACTIVE: true
        CACHE_DIR: client-aws-1-prod-cache
        CI_NO_REDACT: 1
        CURRENT_ENV: client-aws-1-prod
        DEBUG: 1
        GENESIS_HONOR_ENV: 1
        GIT_AUTHOR_EMAIL: concourse@pipeline
        GIT_AUTHOR_NAME: Concourse Bot
        GIT_BRANCH: master
        GIT_PRIVATE_KEY: |
          -----BEGIN RSA PRIVATE KEY-----
          lol. you didn't really think that
          we'd put the key here, in a test,
          did you?!
          -----END RSA PRIVATE KEY-----
        OUT_DIR: out/git
        PREVIOUS_ENV: client-aws-1-preprod
        VAULT_ADDR: http://myvault.myorg.com:5999
        VAULT_ROLE_ID: this-is-a-role
        VAULT_SECRET_ID: this-is-a-secret
        VAULT_SKIP_VERIFY: true
        WORKING_DIR: client-aws-1-prod-changes
      platform: linux
      run:
        args:
        - ci-show-changes
        path: client-aws-1-prod-cache/.genesis/bin/genesis
    tags:
    - client-aws-1-prod
    task: show-pending-changes
  - in_parallel:
    - params:
        channel: '#botspam'
        icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
        text: 'aws-1: Changes are staged to be deployed to client-aws-1-prod-pipeline-test,
          see notify-client-aws-1-prod-pipeline-test-changes job for change summary,
          then schedule and run a deploy via Concourse'
        username: runwaybot
      put: slack
    - params:
        color: gray
        from: runwaybot
        message: 'aws-1: Changes are staged to be deployed to client-aws-1-prod-pipeline-test,
          see notify-client-aws-1-prod-pipeline-test-changes job for change summary,
          then schedule and run a deploy via Concourse'
        notify: false
      put: hipchat
  public: true
  serial: true
- name: client-aws-1-prod-pipeline-test
  plan:
  - do:
    - params:
        key: dont-upgrade-bosh-on-me
        lock_op: lock
        locked_by: client-aws-1-prod-pipeline-test
      put: client-aws-1-prod-bosh-lock
      tags:
      - client-aws-1-prod
    - params:
        key: i-need-to-deploy-myself
        lock_op: lock
        locked_by: client-aws-1-prod-pipeline-test
      put: client-aws-1-prod-deployment-lock
      tags:
      - client-aws-1-prod
    - in_parallel:
      - get: client-aws-1-prod-changes
        passed:
        - notify-client-aws-1-prod-pipeline-test-changes
        trigger: false
      - get: client-aws-1-prod-cache
        passed:
        - notify-client-aws-1-prod-pipeline-test-changes
        trigger: false
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: client-aws-1-prod-changes
        - name: client-aws-1-prod-cache
        outputs:
        - name: out
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: pr-admin
          BOSH_CLIENT_SECRET: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
          BOSH_ENVIRONMENT: https://prod.bosh-lite.com:25555
          BOSH_NON_INTERACTIVE: true
          CACHE_DIR: client-aws-1-prod-cache
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-prod
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: out/git
          PREVIOUS_ENV: client-aws-1-preprod
          VAULT_ADDR: http://myvault.myorg.com:5999
          VAULT_ROLE_ID: this-is-a-role
          VAULT_SECRET_ID: this-is-a-secret
          VAULT_SKIP_VERIFY: true
          WORKING_DIR: client-aws-1-prod-changes
        platform: linux
        run:
          args:
          - ci-pipeline-deploy
          path: client-aws-1-prod-cache/.genesis/bin/genesis
      ensure:
        params:
          repository: out/git
        put: git
      tags:
      - client-aws-1-prod
      task: bosh-deploy
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-prod-cache
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: pr-admin
          BOSH_CLIENT_SECRET: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
          BOSH_ENVIRONMENT: https://prod.bosh-lite.com:25555
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-prod
          DEBUG: 1
          ERRAND_NAME: run-something-good
          GENESIS_HONOR_ENV: 1
        platform: linux
        run:
          args:
          - ci-pipeline-run-errand
          dir: out/git
          path: ../../client-aws-1-prod-cache/.genesis/bin/genesis
      tags:
      - client-aws-1-prod
      task: run-something-good-errand
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-prod-cache
        outputs:
        - name: cache-out
        params:
          CACHE_DIR: client-aws-1-prod-cache
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-prod
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: cache-out/git
          PREVIOUS_ENV: client-aws-1-preprod
          WORKING_DIR: out/git
        platform: linux
        run:
          args:
          - ci-generate-cache
          path: client-aws-1-prod-cache/.genesis/bin/genesis
      tags:
      - client-aws-1-prod
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    ensure:
      do:
      - params:
          key: dont-upgrade-bosh-on-me
          lock_op: unlock
          locked_by: client-aws-1-prod-pipeline-test
        put: client-aws-1-prod-bosh-lock
        tags:
        - client-aws-1-prod
      - params:
          key: i-need-to-deploy-myself
          lock_op: unlock
          locked_by: client-aws-1-prod-pipeline-test
        put: client-aws-1-prod-deployment-lock
        tags:
        - client-aws-1-prod
    on_failure:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-prod-pipeline-test failed'
          username: runwaybot
        put: slack
      - params:
          color: gray
          from: runwaybot
          message: 'aws-1: Concourse deployment to client-aws-1-prod-pipeline-test
            failed'
          notify: false
        put: hipchat
    on_success:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse successfully deployed client-aws-1-prod-pipeline-test'
          username: runwaybot
        put: slack
      - params:
          color: gray
          from: runwaybot
          message: 'aws-1: Concourse successfully deployed client-aws-1-prod-pipeline-test'
          notify: false
        put: hipchat
  public: true
  serial: true
- name: client-aws-1-sandbox-pipeline-test
  plan:
  - do:
    - params:
        key: dont-upgrade-bosh-on-me
        lock_op: lock
        locked_by: client-aws-1-sandbox-pipeline-test
      put: client-aws-1-sandbox-bosh-lock
      tags:
      - client-aws-1-sandbox
    - params:
        key: i-need-to-deploy-myself
        lock_op: lock
        locked_by: client-aws-1-sandbox-pipeline-test
      put: client-aws-1-sandbox-deployment-lock
      tags:
      - client-aws-1-sandbox
      tags:
      - client-aws-1-sandbox
    - in_parallel:
      - get: client-aws-1-sandbox-cloud-config
        tags:
        - client-aws-1-sandbox
        trigger: true
      - get: client-aws-1-sandbox-runtime-config
        tags:
        - client-aws-1-sandbox
        trigger: true
      - get: client-aws-1-sandbox-changes
        trigger: true
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: client-aws-1-sandbox-changes
        outputs:
        - name: out
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: sb-admin
          BOSH_CLIENT_SECRET: PaeM2Eip
          BOSH_ENVIRONMENT: https://sandbox.bosh-lite.com:25555
          BOSH_NON_INTERACTIVE: true
          CACHE_DIR: client-aws-1-sandbox-cache
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-sandbox
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: out/git
          PREVIOUS_ENV: null
          VAULT_ADDR: http://myvault.myorg.com:5999
          VAULT_ROLE_ID: this-is-a-role
          VAULT_SECRET_ID: this-is-a-secret
          VAULT_SKIP_VERIFY: true
          WORKING_DIR: client-aws-1-sandbox-changes
        platform: linux
        run:
          args:
          - ci-pipeline-deploy
          path: client-aws-1-sandbox-changes/.genesis/bin/genesis
      ensure:
        params:
          repository: out/git
        put: git
      tags:
      - client-aws-1-sandbox
      task: bosh-deploy
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-sandbox-changes
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: sb-admin
          BOSH_CLIENT_SECRET: PaeM2Eip
          BOSH_ENVIRONMENT: https://sandbox.bosh-lite.com:25555
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-sandbox
          DEBUG: 1
          ERRAND_NAME: run-something-good
          GENESIS_HONOR_ENV: 1
        platform: linux
        run:
          args:
          - ci-pipeline-run-errand
          dir: out/git
          path: ../../client-aws-1-sandbox-changes/.genesis/bin/genesis
      tags:
      - client-aws-1-sandbox
      task: run-something-good-errand
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-sandbox-changes
        outputs:
        - name: cache-out
        params:
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-sandbox
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: cache-out/git
          WORKING_DIR: out/git
        platform: linux
        run:
          args:
          - ci-generate-cache
          path: client-aws-1-sandbox-changes/.genesis/bin/genesis
      tags:
      - client-aws-1-sandbox
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    - params:
        repository: cache-out/git
      put: client-aws-1-preprod-cache
    ensure:
      do:
      - params:
          key: dont-upgrade-bosh-on-me
          lock_op: unlock
          locked_by: client-aws-1-sandbox-pipeline-test
        put: client-aws-1-sandbox-bosh-lock
        tags:
        - client-aws-1-sandbox
      - params:
          key: i-need-to-deploy-myself
          lock_op: unlock
          locked_by: client-aws-1-sandbox-pipeline-test
        put: client-aws-1-sandbox-deployment-lock
        tags:
        - client-aws-1-sandbox
    on_failure:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-sandbox-pipeline-test
            failed'
          username: runwaybot
        put: slack
      - params:
          color: gray
          from: runwaybot
          message: 'aws-1: Concourse deployment to client-aws-1-sandbox-pipeline-test
            failed'
          notify: false
        put: hipchat
    on_success:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse successfully deployed client-aws-1-sandbox-pipeline-test'
          username: runwaybot
        put: slack
      - params:
          color: gray
          from: runwaybot
          message: 'aws-1: Concourse successfully deployed client-aws-1-sandbox-pipeline-test'
          notify: false
        put: hipchat
  public: true
  serial: true
resource_types:
- name: script
  source:
    repository: cfcommunity/script-resource
  type: registry-image
- name: email
  source:
    repository: pcfseceng/email-resource
  type: registry-image
- name: slack-notification
  source:
    repository: cfcommunity/slack-notification-resource
  type: registry-image
- name: hipchat-notification
  source:
    repository: cfcommunity/hipchat-notification-resource
  type: registry-image
- name: stride-notification
  source:
    repository: starkandwayne/stride-notification-resource
  type: registry-image
- name: bosh-config
  source:
    repository: cfcommunity/bosh-config-resource
  type: registry-image
- name: locker
  source:
    repository: cfcommunity/locker-resource
  type: registry-image
resources:
- icon: github
  name: git
  source:
    branch: master
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: github
  name: client-aws-1-preprod-changes
  source:
    branch: master
    paths:
    - client-aws-1-preprod.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: github
  name: client-aws-1-preprod-cache
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
    - .genesis/cached/client-aws-1-sandbox/ops/*
    - .genesis/cached/client-aws-1-sandbox/kit-overrides.yml
    - .genesis/cached/client-aws-1-sandbox/client.yml
    - .genesis/cached/client-aws-1-sandbox/client-aws.yml
    - .genesis/cached/client-aws-1-sandbox/client-aws-1.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: script-text
  name: client-aws-1-preprod-cloud-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pp-admin
    client_secret: Ahti2eeth3aewohnee1Phaec
    config: cloud
    target: https://preprod.bosh-lite.com:25555
  tags:
  - client-aws-1-preprod
  type: bosh-config
- icon: script-text
  name: client-aws-1-preprod-runtime-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pp-admin
    client_secret: Ahti2eeth3aewohnee1Phaec
    config: runtime
    target: https://preprod.bosh-lite.com:25555
  tags:
  - client-aws-1-preprod
  type: bosh-config
- icon: shield-lock-outline
  name: client-aws-1-preprod-bosh-lock
  source:
    bosh_lock: https://preprod.bosh-lite.com:25555
    ca_cert: null
    locker_uri: https://127.0.0.1:8910
    password: locker
    skip_ssl_validation: true
    username: locker
  tags:
  - client-aws-1-preprod
  type: locker
- icon: shield-lock-outline
  name: client-aws-1-preprod-deployment-lock
  source:
    ca_cert: null
    lock_name: client-aws-1-preprod-pipeline-test
    locker_uri: https://127.0.0.1:8910
    password: locker
    skip_ssl_validation: true
    username: locker
  tags:
  - client-aws-1-preprod
  type: locker
- icon: github
  name: client-aws-1-prod-changes
  source:
    branch: master
    paths:
    - client-aws-1-prod.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: github
  name: client-aws-1-prod-cache
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
    - .genesis/cached/client-aws-1-preprod/ops/*
    - .genesis/cached/client-aws-1-preprod/kit-overrides.yml
    - .genesis/cached/client-aws-1-preprod/client.yml
    - .genesis/cached/client-aws-1-preprod/client-aws.yml
    - .genesis/cached/client-aws-1-preprod/client-aws-1.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: script-text
  name: client-aws-1-prod-cloud-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pr-admin
    client_secret: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
    config: cloud
    target: https://prod.bosh-lite.com:25555
  tags:
  - client-aws-1-prod
  type: bosh-config
- icon: script-text
  name: client-aws-1-prod-runtime-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pr-admin
    client_secret: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
    config: runtime
    target: https://prod.bosh-lite.com:25555
  tags:
  - client-aws-1-prod
  type: bosh-config
- icon: shield-lock-outline
  name: client-aws-1-prod-bosh-lock
  source:
    bosh_lock: https://prod.bosh-lite.com:25555
    ca_cert: null
    locker_uri: https://127.0.0.1:8910
    password: locker
    skip_ssl_validation: true
    username: locker
  tags:
  - client-aws-1-prod
  type: locker
- icon: shield-lock-outline
  name: client-aws-1-prod-deployment-lock
  source:
    ca_cert: null
    lock_name: client-aws-1-prod-pipeline-test
    locker_uri: https://127.0.0.1:8910
    password: locker
    skip_ssl_validation: true
    username: locker
  tags:
  - client-aws-1-prod
  type: locker
- icon: github
  name: client-aws-1-sandbox-changes
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
    - ops/*
    - kit-overrides.yml
    - client.yml
    - client-aws.yml
    - client-aws-1.yml
    - client-aws-1-sandbox.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: script-text
  name: client-aws-1-sandbox-cloud-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: sb-admin
    client_secret: PaeM2Eip
    config: cloud
    target: https://sandbox.bosh-lite.com:25555
  tags:
  - client-aws-1-sandbox
  type: bosh-config
- icon: script-text
  name: client-aws-1-sandbox-runtime-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: sb-admin
    client_secret: PaeM2Eip
    config: runtime
    target: https://sandbox.bosh-lite.com:25555
  tags:
  - client-aws-1-sandbox
  type: bosh-config
- icon: shield-lock-outline
  name: client-aws-1-sandbox-bosh-lock
  source:
    bosh_lock: https://sandbox.bosh-lite.com:25555
    ca_cert: null
    locker_uri: https://127.0.0.1:8910
    password: locker
    skip_ssl_validation: true
    username: locker
  tags:
  - client-aws-1-sandbox
  type: locker
- icon: shield-lock-outline
  name: client-aws-1-sandbox-deployment-lock
  source:
    ca_cert: null
    lock_name: client-aws-1-sandbox-pipeline-test
    locker_uri: https://127.0.0.1:8910
    password: locker
    skip_ssl_validation: true
    username: locker
  tags:
  - client-aws-1-sandbox
  type: locker
- icon: slack
  name: slack
  source:
    url: http://127.0.0.1:1337
  type: slack-notification
- icon: bell-ring
  name: hipchat
  source:
    hipchat_server_url: http://api.hipchat.com
    room_id: 1234
    token: abcdefg
  type: hipchat-notification
EOF
# }}}

runs_ok "genesis repipe --dry-run --config ci/aws/pipeline.groups_and_notifications" and # {{{
runs_ok "genesis repipe --dry-run --config ci/aws/pipeline.groups_and_notifications >$tmp/pipeline.yml" and
yaml_is get_file("$tmp/pipeline.yml"), <<'EOF', "pipeline generated for aws/pipeline (with grouped notifications)";
groups:
- jobs:
  - client-aws-1-preprod-pipeline-test
  - client-aws-1-prod-pipeline-test
  - client-aws-1-sandbox-pipeline-test
  name: allinone
- jobs:
  - client-aws-1-preprod-pipeline-test
  - client-aws-1-sandbox-pipeline-test
  name: group1
- jobs:
  - client-aws-1-preprod-pipeline-test
  - client-aws-1-prod-pipeline-test
  name: group2
- jobs:
  - notify-client-aws-1-prod-pipeline-test-changes
  name: notifications
jobs:
- name: client-aws-1-preprod-pipeline-test
  plan:
  - do:
    - params:
        key: dont-upgrade-bosh-on-me
        lock_op: lock
        locked_by: client-aws-1-preprod-pipeline-test
      put: client-aws-1-preprod-bosh-lock
      tags:
      - client-aws-1-preprod
    - params:
        key: i-need-to-deploy-myself
        lock_op: lock
        locked_by: client-aws-1-preprod-pipeline-test
      put: client-aws-1-preprod-deployment-lock
      tags:
      - client-aws-1-preprod
    - in_parallel:
      - get: client-aws-1-preprod-cloud-config
        tags:
        - client-aws-1-preprod
        trigger: true
      - get: client-aws-1-preprod-runtime-config
        tags:
        - client-aws-1-preprod
        trigger: true
      - get: client-aws-1-preprod-changes
        trigger: true
      - get: client-aws-1-preprod-cache
        passed:
        - client-aws-1-sandbox-pipeline-test
        trigger: true
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: client-aws-1-preprod-changes
        - name: client-aws-1-preprod-cache
        outputs:
        - name: out
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: pp-admin
          BOSH_CLIENT_SECRET: Ahti2eeth3aewohnee1Phaec
          BOSH_ENVIRONMENT: https://preprod.bosh-lite.com:25555
          BOSH_NON_INTERACTIVE: true
          CACHE_DIR: client-aws-1-preprod-cache
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-preprod
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: out/git
          PREVIOUS_ENV: client-aws-1-sandbox
          VAULT_ADDR: http://myvault.myorg.com:5999
          VAULT_ROLE_ID: this-is-a-role
          VAULT_SECRET_ID: this-is-a-secret
          VAULT_SKIP_VERIFY: true
          WORKING_DIR: client-aws-1-preprod-changes
        platform: linux
        run:
          args:
          - ci-pipeline-deploy
          path: client-aws-1-preprod-cache/.genesis/bin/genesis
      ensure:
        params:
          repository: out/git
        put: git
      tags:
      - client-aws-1-preprod
      task: bosh-deploy
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-preprod-cache
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: pp-admin
          BOSH_CLIENT_SECRET: Ahti2eeth3aewohnee1Phaec
          BOSH_ENVIRONMENT: https://preprod.bosh-lite.com:25555
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-preprod
          DEBUG: 1
          ERRAND_NAME: run-something-good
          GENESIS_HONOR_ENV: 1
        platform: linux
        run:
          args:
          - ci-pipeline-run-errand
          dir: out/git
          path: ../../client-aws-1-preprod-cache/.genesis/bin/genesis
      tags:
      - client-aws-1-preprod
      task: run-something-good-errand
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-preprod-cache
        outputs:
        - name: cache-out
        params:
          CACHE_DIR: client-aws-1-preprod-cache
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-preprod
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: cache-out/git
          PREVIOUS_ENV: client-aws-1-sandbox
          WORKING_DIR: out/git
        platform: linux
        run:
          args:
          - ci-generate-cache
          path: client-aws-1-preprod-cache/.genesis/bin/genesis
      tags:
      - client-aws-1-preprod
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    - params:
        repository: cache-out/git
      put: client-aws-1-prod-cache
    ensure:
      do:
      - params:
          key: dont-upgrade-bosh-on-me
          lock_op: unlock
          locked_by: client-aws-1-preprod-pipeline-test
        put: client-aws-1-preprod-bosh-lock
        tags:
        - client-aws-1-preprod
      - params:
          key: i-need-to-deploy-myself
          lock_op: unlock
          locked_by: client-aws-1-preprod-pipeline-test
        put: client-aws-1-preprod-deployment-lock
        tags:
        - client-aws-1-preprod
    on_failure:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-preprod-pipeline-test
            failed'
          username: runwaybot
        put: slack
      - params:
          color: gray
          from: runwaybot
          message: 'aws-1: Concourse deployment to client-aws-1-preprod-pipeline-test
            failed'
          notify: false
        put: hipchat
    on_success:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse successfully deployed client-aws-1-preprod-pipeline-test'
          username: runwaybot
        put: slack
      - params:
          color: gray
          from: runwaybot
          message: 'aws-1: Concourse successfully deployed client-aws-1-preprod-pipeline-test'
          notify: false
        put: hipchat
  public: true
  serial: true
- name: notify-client-aws-1-prod-pipeline-test-changes
  plan:
  - in_parallel:
    - get: client-aws-1-prod-changes
      trigger: true
    - get: client-aws-1-prod-cache
      passed:
      - client-aws-1-preprod-pipeline-test
      trigger: true
    - get: client-aws-1-prod-cloud-config
      tags:
      - client-aws-1-prod
      trigger: true
    - get: client-aws-1-prod-runtime-config
      tags:
      - client-aws-1-prod
      trigger: true
  - config:
      image_resource:
        source:
          repository: custom/concourse-image
          tag: rc1
        type: registry-image
      inputs:
      - name: client-aws-1-prod-changes
      - name: client-aws-1-prod-cache
      params:
        BOSH_CA_CERT: |
          ----- BEGIN CERTIFICATE -----
          cert-goes-here
          ----- END CERTIFICATE -----
        BOSH_CLIENT: pr-admin
        BOSH_CLIENT_SECRET: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
        BOSH_ENVIRONMENT: https://prod.bosh-lite.com:25555
        BOSH_NON_INTERACTIVE: true
        CACHE_DIR: client-aws-1-prod-cache
        CI_NO_REDACT: 1
        CURRENT_ENV: client-aws-1-prod
        DEBUG: 1
        GENESIS_HONOR_ENV: 1
        GIT_AUTHOR_EMAIL: concourse@pipeline
        GIT_AUTHOR_NAME: Concourse Bot
        GIT_BRANCH: master
        GIT_PRIVATE_KEY: |
          -----BEGIN RSA PRIVATE KEY-----
          lol. you didn't really think that
          we'd put the key here, in a test,
          did you?!
          -----END RSA PRIVATE KEY-----
        OUT_DIR: out/git
        PREVIOUS_ENV: client-aws-1-preprod
        VAULT_ADDR: http://myvault.myorg.com:5999
        VAULT_ROLE_ID: this-is-a-role
        VAULT_SECRET_ID: this-is-a-secret
        VAULT_SKIP_VERIFY: true
        WORKING_DIR: client-aws-1-prod-changes
      platform: linux
      run:
        args:
        - ci-show-changes
        path: client-aws-1-prod-cache/.genesis/bin/genesis
    tags:
    - client-aws-1-prod
    task: show-pending-changes
  - in_parallel:
    - params:
        channel: '#botspam'
        icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
        text: 'aws-1: Changes are staged to be deployed to client-aws-1-prod-pipeline-test,
          see notify-client-aws-1-prod-pipeline-test-changes job for change summary,
          then schedule and run a deploy via Concourse'
        username: runwaybot
      put: slack
    - params:
        color: gray
        from: runwaybot
        message: 'aws-1: Changes are staged to be deployed to client-aws-1-prod-pipeline-test,
          see notify-client-aws-1-prod-pipeline-test-changes job for change summary,
          then schedule and run a deploy via Concourse'
        notify: false
      put: hipchat
  public: true
  serial: true
- name: client-aws-1-prod-pipeline-test
  plan:
  - do:
    - params:
        key: dont-upgrade-bosh-on-me
        lock_op: lock
        locked_by: client-aws-1-prod-pipeline-test
      put: client-aws-1-prod-bosh-lock
      tags:
      - client-aws-1-prod
    - params:
        key: i-need-to-deploy-myself
        lock_op: lock
        locked_by: client-aws-1-prod-pipeline-test
      put: client-aws-1-prod-deployment-lock
      tags:
      - client-aws-1-prod
    - in_parallel:
      - get: client-aws-1-prod-changes
        trigger: false
      - get: client-aws-1-prod-cache
        passed:
        - client-aws-1-preprod-pipeline-test
        trigger: false
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: client-aws-1-prod-changes
        - name: client-aws-1-prod-cache
        outputs:
        - name: out
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: pr-admin
          BOSH_CLIENT_SECRET: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
          BOSH_ENVIRONMENT: https://prod.bosh-lite.com:25555
          BOSH_NON_INTERACTIVE: true
          CACHE_DIR: client-aws-1-prod-cache
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-prod
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: out/git
          PREVIOUS_ENV: client-aws-1-preprod
          VAULT_ADDR: http://myvault.myorg.com:5999
          VAULT_ROLE_ID: this-is-a-role
          VAULT_SECRET_ID: this-is-a-secret
          VAULT_SKIP_VERIFY: true
          WORKING_DIR: client-aws-1-prod-changes
        platform: linux
        run:
          args:
          - ci-pipeline-deploy
          path: client-aws-1-prod-cache/.genesis/bin/genesis
      ensure:
        params:
          repository: out/git
        put: git
      tags:
      - client-aws-1-prod
      task: bosh-deploy
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-prod-cache
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: pr-admin
          BOSH_CLIENT_SECRET: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
          BOSH_ENVIRONMENT: https://prod.bosh-lite.com:25555
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-prod
          DEBUG: 1
          ERRAND_NAME: run-something-good
          GENESIS_HONOR_ENV: 1
        platform: linux
        run:
          args:
          - ci-pipeline-run-errand
          dir: out/git
          path: ../../client-aws-1-prod-cache/.genesis/bin/genesis
      tags:
      - client-aws-1-prod
      task: run-something-good-errand
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-prod-cache
        outputs:
        - name: cache-out
        params:
          CACHE_DIR: client-aws-1-prod-cache
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-prod
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: cache-out/git
          PREVIOUS_ENV: client-aws-1-preprod
          WORKING_DIR: out/git
        platform: linux
        run:
          args:
          - ci-generate-cache
          path: client-aws-1-prod-cache/.genesis/bin/genesis
      tags:
      - client-aws-1-prod
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    ensure:
      do:
      - params:
          key: dont-upgrade-bosh-on-me
          lock_op: unlock
          locked_by: client-aws-1-prod-pipeline-test
        put: client-aws-1-prod-bosh-lock
        tags:
        - client-aws-1-prod
      - params:
          key: i-need-to-deploy-myself
          lock_op: unlock
          locked_by: client-aws-1-prod-pipeline-test
        put: client-aws-1-prod-deployment-lock
        tags:
        - client-aws-1-prod
    on_failure:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-prod-pipeline-test failed'
          username: runwaybot
        put: slack
      - params:
          color: gray
          from: runwaybot
          message: 'aws-1: Concourse deployment to client-aws-1-prod-pipeline-test
            failed'
          notify: false
        put: hipchat
    on_success:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse successfully deployed client-aws-1-prod-pipeline-test'
          username: runwaybot
        put: slack
      - params:
          color: gray
          from: runwaybot
          message: 'aws-1: Concourse successfully deployed client-aws-1-prod-pipeline-test'
          notify: false
        put: hipchat
  public: true
  serial: true
- name: client-aws-1-sandbox-pipeline-test
  plan:
  - do:
    - params:
        key: dont-upgrade-bosh-on-me
        lock_op: lock
        locked_by: client-aws-1-sandbox-pipeline-test
      put: client-aws-1-sandbox-bosh-lock
      tags:
      - client-aws-1-sandbox
    - params:
        key: i-need-to-deploy-myself
        lock_op: lock
        locked_by: client-aws-1-sandbox-pipeline-test
      put: client-aws-1-sandbox-deployment-lock
      tags:
      - client-aws-1-sandbox
      tags:
      - client-aws-1-sandbox
    - in_parallel:
      - get: client-aws-1-sandbox-cloud-config
        tags:
        - client-aws-1-sandbox
        trigger: true
      - get: client-aws-1-sandbox-runtime-config
        tags:
        - client-aws-1-sandbox
        trigger: true
      - get: client-aws-1-sandbox-changes
        trigger: true
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: client-aws-1-sandbox-changes
        outputs:
        - name: out
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: sb-admin
          BOSH_CLIENT_SECRET: PaeM2Eip
          BOSH_ENVIRONMENT: https://sandbox.bosh-lite.com:25555
          BOSH_NON_INTERACTIVE: true
          CACHE_DIR: client-aws-1-sandbox-cache
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-sandbox
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: out/git
          PREVIOUS_ENV: null
          VAULT_ADDR: http://myvault.myorg.com:5999
          VAULT_ROLE_ID: this-is-a-role
          VAULT_SECRET_ID: this-is-a-secret
          VAULT_SKIP_VERIFY: true
          WORKING_DIR: client-aws-1-sandbox-changes
        platform: linux
        run:
          args:
          - ci-pipeline-deploy
          path: client-aws-1-sandbox-changes/.genesis/bin/genesis
      ensure:
        params:
          repository: out/git
        put: git
      tags:
      - client-aws-1-sandbox
      task: bosh-deploy
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-sandbox-changes
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: sb-admin
          BOSH_CLIENT_SECRET: PaeM2Eip
          BOSH_ENVIRONMENT: https://sandbox.bosh-lite.com:25555
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-sandbox
          DEBUG: 1
          ERRAND_NAME: run-something-good
          GENESIS_HONOR_ENV: 1
        platform: linux
        run:
          args:
          - ci-pipeline-run-errand
          dir: out/git
          path: ../../client-aws-1-sandbox-changes/.genesis/bin/genesis
      tags:
      - client-aws-1-sandbox
      task: run-something-good-errand
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-sandbox-changes
        outputs:
        - name: cache-out
        params:
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-sandbox
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PRIVATE_KEY: |
            -----BEGIN RSA PRIVATE KEY-----
            lol. you didn't really think that
            we'd put the key here, in a test,
            did you?!
            -----END RSA PRIVATE KEY-----
          OUT_DIR: cache-out/git
          WORKING_DIR: out/git
        platform: linux
        run:
          args:
          - ci-generate-cache
          path: client-aws-1-sandbox-changes/.genesis/bin/genesis
      tags:
      - client-aws-1-sandbox
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    - params:
        repository: cache-out/git
      put: client-aws-1-preprod-cache
    ensure:
      do:
      - params:
          key: dont-upgrade-bosh-on-me
          lock_op: unlock
          locked_by: client-aws-1-sandbox-pipeline-test
        put: client-aws-1-sandbox-bosh-lock
        tags:
        - client-aws-1-sandbox
      - params:
          key: i-need-to-deploy-myself
          lock_op: unlock
          locked_by: client-aws-1-sandbox-pipeline-test
        put: client-aws-1-sandbox-deployment-lock
        tags:
        - client-aws-1-sandbox
    on_failure:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-sandbox-pipeline-test
            failed'
          username: runwaybot
        put: slack
      - params:
          color: gray
          from: runwaybot
          message: 'aws-1: Concourse deployment to client-aws-1-sandbox-pipeline-test
            failed'
          notify: false
        put: hipchat
    on_success:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse successfully deployed client-aws-1-sandbox-pipeline-test'
          username: runwaybot
        put: slack
      - params:
          color: gray
          from: runwaybot
          message: 'aws-1: Concourse successfully deployed client-aws-1-sandbox-pipeline-test'
          notify: false
        put: hipchat
  public: true
  serial: true
resource_types:
- name: script
  source:
    repository: cfcommunity/script-resource
  type: registry-image
- name: email
  source:
    repository: pcfseceng/email-resource
  type: registry-image
- name: slack-notification
  source:
    repository: cfcommunity/slack-notification-resource
  type: registry-image
- name: hipchat-notification
  source:
    repository: cfcommunity/hipchat-notification-resource
  type: registry-image
- name: stride-notification
  source:
    repository: starkandwayne/stride-notification-resource
  type: registry-image
- name: bosh-config
  source:
    repository: cfcommunity/bosh-config-resource
  type: registry-image
- name: locker
  source:
    repository: cfcommunity/locker-resource
  type: registry-image
resources:
- icon: github
  name: git
  source:
    branch: master
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: github
  name: client-aws-1-preprod-changes
  source:
    branch: master
    paths:
    - client-aws-1-preprod.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: github
  name: client-aws-1-preprod-cache
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
    - .genesis/cached/client-aws-1-sandbox/ops/*
    - .genesis/cached/client-aws-1-sandbox/kit-overrides.yml
    - .genesis/cached/client-aws-1-sandbox/client.yml
    - .genesis/cached/client-aws-1-sandbox/client-aws.yml
    - .genesis/cached/client-aws-1-sandbox/client-aws-1.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: script-text
  name: client-aws-1-preprod-cloud-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pp-admin
    client_secret: Ahti2eeth3aewohnee1Phaec
    config: cloud
    target: https://preprod.bosh-lite.com:25555
  tags:
  - client-aws-1-preprod
  type: bosh-config
- icon: script-text
  name: client-aws-1-preprod-runtime-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pp-admin
    client_secret: Ahti2eeth3aewohnee1Phaec
    config: runtime
    target: https://preprod.bosh-lite.com:25555
  tags:
  - client-aws-1-preprod
  type: bosh-config
- icon: shield-lock-outline
  name: client-aws-1-preprod-bosh-lock
  source:
    bosh_lock: https://preprod.bosh-lite.com:25555
    ca_cert: null
    locker_uri: https://127.0.0.1:8910
    password: locker
    skip_ssl_validation: true
    username: locker
  tags:
  - client-aws-1-preprod
  type: locker
- icon: shield-lock-outline
  name: client-aws-1-preprod-deployment-lock
  source:
    ca_cert: null
    lock_name: client-aws-1-preprod-pipeline-test
    locker_uri: https://127.0.0.1:8910
    password: locker
    skip_ssl_validation: true
    username: locker
  tags:
  - client-aws-1-preprod
  type: locker
- icon: github
  name: client-aws-1-prod-changes
  source:
    branch: master
    paths:
    - client-aws-1-prod.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: github
  name: client-aws-1-prod-cache
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
    - .genesis/cached/client-aws-1-preprod/ops/*
    - .genesis/cached/client-aws-1-preprod/kit-overrides.yml
    - .genesis/cached/client-aws-1-preprod/client.yml
    - .genesis/cached/client-aws-1-preprod/client-aws.yml
    - .genesis/cached/client-aws-1-preprod/client-aws-1.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: script-text
  name: client-aws-1-prod-cloud-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pr-admin
    client_secret: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
    config: cloud
    target: https://prod.bosh-lite.com:25555
  tags:
  - client-aws-1-prod
  type: bosh-config
- icon: script-text
  name: client-aws-1-prod-runtime-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: pr-admin
    client_secret: eeheelod3veepaepiepee8ahc3rukaefo6equiezuapohS2u
    config: runtime
    target: https://prod.bosh-lite.com:25555
  tags:
  - client-aws-1-prod
  type: bosh-config
- icon: shield-lock-outline
  name: client-aws-1-prod-bosh-lock
  source:
    bosh_lock: https://prod.bosh-lite.com:25555
    ca_cert: null
    locker_uri: https://127.0.0.1:8910
    password: locker
    skip_ssl_validation: true
    username: locker
  tags:
  - client-aws-1-prod
  type: locker
- icon: shield-lock-outline
  name: client-aws-1-prod-deployment-lock
  source:
    ca_cert: null
    lock_name: client-aws-1-prod-pipeline-test
    locker_uri: https://127.0.0.1:8910
    password: locker
    skip_ssl_validation: true
    username: locker
  tags:
  - client-aws-1-prod
  type: locker
- icon: github
  name: client-aws-1-sandbox-changes
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
    - ops/*
    - kit-overrides.yml
    - client.yml
    - client-aws.yml
    - client-aws-1.yml
    - client-aws-1-sandbox.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- icon: script-text
  name: client-aws-1-sandbox-cloud-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: sb-admin
    client_secret: PaeM2Eip
    config: cloud
    target: https://sandbox.bosh-lite.com:25555
  tags:
  - client-aws-1-sandbox
  type: bosh-config
- icon: script-text
  name: client-aws-1-sandbox-runtime-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: sb-admin
    client_secret: PaeM2Eip
    config: runtime
    target: https://sandbox.bosh-lite.com:25555
  tags:
  - client-aws-1-sandbox
  type: bosh-config
- icon: shield-lock-outline
  name: client-aws-1-sandbox-bosh-lock
  source:
    bosh_lock: https://sandbox.bosh-lite.com:25555
    ca_cert: null
    locker_uri: https://127.0.0.1:8910
    password: locker
    skip_ssl_validation: true
    username: locker
  tags:
  - client-aws-1-sandbox
  type: locker
- icon: shield-lock-outline
  name: client-aws-1-sandbox-deployment-lock
  source:
    ca_cert: null
    lock_name: client-aws-1-sandbox-pipeline-test
    locker_uri: https://127.0.0.1:8910
    password: locker
    skip_ssl_validation: true
    username: locker
  tags:
  - client-aws-1-sandbox
  type: locker
- icon: slack
  name: slack
  source:
    url: http://127.0.0.1:1337
  type: slack-notification
- icon: bell-ring
  name: hipchat
  source:
    hipchat_server_url: http://api.hipchat.com
    room_id: 1234
    token: abcdefg
  type: hipchat-notification
EOF
# }}}

runs_ok "genesis repipe --dry-run --config ci/aws/pipeline.singleton" and # {{{
runs_ok "genesis repipe --dry-run --config ci/aws/pipeline.singleton >$tmp/pipeline.yml" and
yaml_is get_file("$tmp/pipeline.yml"), <<'EOF', "pipeline generated for aws/pipeline (singleton job)";
groups:
- jobs:
  - client-aws-1-sandbox-pipeline-test
  name: aws-1
jobs:
- name: client-aws-1-sandbox-pipeline-test
  plan:
  - do:
    - in_parallel:
      - get: client-aws-1-sandbox-cloud-config
        trigger: true
      - get: client-aws-1-sandbox-runtime-config
        trigger: true
      - get: client-aws-1-sandbox-changes
        trigger: true
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: client-aws-1-sandbox-changes
        outputs:
        - name: out
        params:
          BOSH_CA_CERT: |
            ----- BEGIN CERTIFICATE -----
            cert-goes-here
            ----- END CERTIFICATE -----
          BOSH_CLIENT: sb-admin
          BOSH_CLIENT_SECRET: PaeM2Eip
          BOSH_ENVIRONMENT: https://sandbox.bosh-lite.com:25555
          BOSH_NON_INTERACTIVE: true
          CACHE_DIR: client-aws-1-sandbox-cache
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-sandbox
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PASSWORD: weneedareplacement!
          GIT_USERNAME: fleemco
          OUT_DIR: out/git
          PREVIOUS_ENV: null
          VAULT_ADDR: http://myvault.myorg.com:5999
          VAULT_ROLE_ID: this-is-a-role
          VAULT_SECRET_ID: this-is-a-secret
          VAULT_SKIP_VERIFY: true
          WORKING_DIR: client-aws-1-sandbox-changes
        platform: linux
        run:
          args:
          - ci-pipeline-deploy
          path: client-aws-1-sandbox-changes/.genesis/bin/genesis
      ensure:
        params:
          repository: out/git
        put: git
      task: bosh-deploy
    - config:
        image_resource:
          source:
            repository: custom/concourse-image
            tag: rc1
          type: registry-image
        inputs:
        - name: out
        - name: client-aws-1-sandbox-changes
        outputs:
        - name: cache-out
        params:
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-sandbox
          GENESIS_HONOR_ENV: 1
          GIT_AUTHOR_EMAIL: concourse@pipeline
          GIT_AUTHOR_NAME: Concourse Bot
          GIT_BRANCH: master
          GIT_PASSWORD: weneedareplacement!
          GIT_USERNAME: fleemco
          OUT_DIR: cache-out/git
          WORKING_DIR: out/git
        platform: linux
        run:
          args:
          - ci-generate-cache
          path: client-aws-1-sandbox-changes/.genesis/bin/genesis
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    on_failure:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-sandbox-pipeline-test
            failed'
          username: runwaybot
        put: slack
    on_success:
      in_parallel:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse successfully deployed client-aws-1-sandbox-pipeline-test'
          username: runwaybot
        put: slack
  public: true
  serial: true
resource_types:
- name: script
  source:
    repository: cfcommunity/script-resource
  type: registry-image
- name: email
  source:
    repository: pcfseceng/email-resource
  type: registry-image
- name: slack-notification
  source:
    repository: cfcommunity/slack-notification-resource
  type: registry-image
- name: hipchat-notification
  source:
    repository: cfcommunity/hipchat-notification-resource
  type: registry-image
- name: stride-notification
  source:
    repository: starkandwayne/stride-notification-resource
  type: registry-image
- name: bosh-config
  source:
    repository: cfcommunity/bosh-config-resource
  type: registry-image
- name: locker
  source:
    repository: cfcommunity/locker-resource
  type: registry-image
resources:
- icon: github
  name: git
  source:
    branch: master
    password: weneedareplacement!
    uri: https://github.com/someco/something-deployments.git
    username: fleemco
  type: git
- icon: github
  name: client-aws-1-sandbox-changes
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
    - ops/*
    - kit-overrides.yml
    - client.yml
    - client-aws.yml
    - client-aws-1.yml
    - client-aws-1-sandbox.yml
    password: weneedareplacement!
    uri: https://github.com/someco/something-deployments.git
    username: fleemco
  type: git
- icon: script-text
  name: client-aws-1-sandbox-cloud-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: sb-admin
    client_secret: PaeM2Eip
    config: cloud
    target: https://sandbox.bosh-lite.com:25555
  type: bosh-config
- icon: script-text
  name: client-aws-1-sandbox-runtime-config
  source:
    ca_cert: |
      ----- BEGIN CERTIFICATE -----
      cert-goes-here
      ----- END CERTIFICATE -----
    client: sb-admin
    client_secret: PaeM2Eip
    config: runtime
    target: https://sandbox.bosh-lite.com:25555
  type: bosh-config
- icon: slack
  name: slack
  source:
    url: http://127.0.0.1:1337
  type: slack-notification
EOF
# }}}

output_ok "genesis describe --config ci/pipeline.all", <<EOF, "large pipelines are described properly"; # {{{
sandbox-1
  `--> dev-1
        |--> preprod-1
        |     `--> prod-1
        `--> qa-1

sandbox-2
  |--> preprod-2
  |     `--> prod-2
  `--> preprod-3
        |--> prod-3
        |--> prod-4
        `--> prod-5
EOF
 # }}}
output_ok "genesis describe --config ci/aws/pipeline", <<EOF, "small pipelines are described properly"; # {{{
client-aws-1-sandbox
  `--> client-aws-1-preprod
        `--> client-aws-1-prod
EOF
# }}}
}; # }}}

subtest 'ci-generate-cache' => sub { # {{{

  my $workdir=workdir();
  `cp -R ../pipeline-test $workdir/sandbox`;
  `cp -R ../pipeline-test $workdir/preprod`;
  `cp -R ../pipeline-test $workdir/prod`;
  `cp -R ../pipeline-test $workdir/prod-backup`;

  chdir $workdir;
  for my $src (qw/sandbox preprod prod prod-backup/) {
    put_file "$src/client-aws-1-prod-backup.yml", <<EOF;

---
genesis:
  env: prod-backup

params:
  source: prod-backup
  domain: prod.thing.example.com
EOF

    for my $file (qw/client client-aws-1/) {
      put_file "$src/${file}.yml", <<EOF;
---
params:
  $file-source: $src
EOF
    }
    for my $badfile (qw/client.yml.old client-vsphere.yml client-aws-1/) {
      put_file "$src/${badfile}", <<EOF;
---
params:
  $badfile-source: $src
  bad-file: $badfile
EOF
    }
  }
  put_file "preprod/client-aws.yml", <<EOF;
---
params:
  client-aws-source: preprod
EOF

  local $ENV;
  $ENV{GENESIS_TESTING}=1;
  $ENV{GIT_BRANCH}='master';
  $ENV{GIT_PRIVATE_KEY}='dummy';
  $ENV{OUT_DIR}='not-used-for-testing';

  # Test 1: initial, no cache # {{{
  $ENV{CURRENT_ENV}="client-aws-1-sandbox";
  $ENV{WORKING_DIR}="sandbox";
  runs_ok "genesis ci-generate-cache", "[sandbox] Can generate cache from deployment";
  matches `ls -1a sandbox/.genesis/cached/ 2>&1 | sort`, <<EOF, "[sandbox] Correct cache directory is created";
.
..
client-aws-1-sandbox
EOF
  matches `ls -1a sandbox/.genesis/cached/client-aws-1-sandbox/ 2>&1 | sort`, <<EOF, "[sandbox] Correct files are cached";
.
..
client-aws-1-sandbox.yml
client-aws-1.yml
client.yml
EOF
  matches `grep 'source:' sandbox/.genesis/cached/client-aws-1-sandbox/*.yml`, <<EOF, "[sandbox] Cached files are from the correct source";
sandbox/.genesis/cached/client-aws-1-sandbox/client-aws-1-sandbox.yml:  source: sandbox
sandbox/.genesis/cached/client-aws-1-sandbox/client-aws-1.yml:  client-aws-1-source: sandbox
sandbox/.genesis/cached/client-aws-1-sandbox/client.yml:  client-source: sandbox
EOF
  # }}}
  # Test 2: first consumer of cache # {{{
  $ENV{PREVIOUS_ENV}="client-aws-1-sandbox";
  $ENV{CURRENT_ENV}="client-aws-1-preprod";
  $ENV{CACHE_DIR}="sandbox";
  $ENV{WORKING_DIR}="preprod";
  runs_ok "genesis ci-generate-cache", "[preprod] Can generate cache from deployment";
  matches `ls -1a preprod/.genesis/cached/ 2>&1 | sort`, <<EOF, "[preprod] Correct cache directory is created";
.
..
client-aws-1-preprod
EOF
  matches `ls -1a preprod/.genesis/cached/client-aws-1-preprod/ 2>&1 | sort`, <<EOF, "[preprod] Correct files are cached";
.
..
client-aws-1-preprod.yml
client-aws-1.yml
client.yml
EOF
  matches `grep 'source:' preprod/.genesis/cached/client-aws-1-preprod/*.yml`, <<EOF, "[preprod] Cached files are from the correct source";
preprod/.genesis/cached/client-aws-1-preprod/client-aws-1-preprod.yml:  source: preprod
preprod/.genesis/cached/client-aws-1-preprod/client-aws-1.yml:  client-aws-1-source: sandbox
preprod/.genesis/cached/client-aws-1-preprod/client.yml:  client-source: sandbox
EOF
  # }}}
  # Test 3: second consumer of cache # {{{
  $ENV{PREVIOUS_ENV}="client-aws-1-preprod";
  $ENV{CURRENT_ENV}="client-aws-1-prod";
  $ENV{CACHE_DIR}="preprod";
  $ENV{WORKING_DIR}="prod";
  runs_ok "genesis ci-generate-cache", "[prod] Can generate cache from deployment";
  matches `ls -1a prod/.genesis/cached/ 2>&1 | sort`, <<EOF, "[prod] Correct cache directory is created";
.
..
client-aws-1-prod
EOF
  matches `ls -1a prod/.genesis/cached/client-aws-1-prod/ 2>&1 | sort`, <<EOF, "[prod] Correct files are cached";
.
..
client-aws-1-prod.yml
client-aws-1.yml
client.yml
EOF
  matches `grep 'source:' prod/.genesis/cached/client-aws-1-prod/*.yml`, <<EOF, "[prod] Cached files are from the correct source";
prod/.genesis/cached/client-aws-1-prod/client-aws-1-prod.yml:  source: prod
prod/.genesis/cached/client-aws-1-prod/client-aws-1.yml:  client-aws-1-source: sandbox
prod/.genesis/cached/client-aws-1-prod/client.yml:  client-source: sandbox
EOF
  # }}}
  # Test 4: consumer of two-levels of cache # {{{
  $ENV{PREVIOUS_ENV}="client-aws-1-sandbox";
  $ENV{CURRENT_ENV}="client-aws-1-prod-backup";
  $ENV{CACHE_DIR}="sandbox";
  $ENV{WORKING_DIR}="prod-backup";
  runs_ok "genesis ci-generate-cache", "[prod-backup] Can generate cache from deployment";
  matches `ls -1a prod-backup/.genesis/cached/ 2>&1 | sort`, <<EOF, "[prod-backup] Correct cache directory is created";
.
..
client-aws-1-prod-backup
EOF
  matches `ls -1a prod-backup/.genesis/cached/client-aws-1-prod-backup/ 2>&1 | sort`, <<EOF, "[prod-backup] Correct files are cached";
.
..
client-aws-1-prod-backup.yml
client-aws-1-prod.yml
client-aws-1.yml
client.yml
EOF
  matches `grep 'source:' prod-backup/.genesis/cached/client-aws-1-prod-backup/*.yml`, <<EOF, "[prod-backup] Cached files are from the correct source";
prod-backup/.genesis/cached/client-aws-1-prod-backup/client-aws-1-prod-backup.yml:  source: prod-backup
prod-backup/.genesis/cached/client-aws-1-prod-backup/client-aws-1-prod.yml:  source: prod
prod-backup/.genesis/cached/client-aws-1-prod-backup/client-aws-1.yml:  client-aws-1-source: sandbox
prod-backup/.genesis/cached/client-aws-1-prod-backup/client.yml:  client-source: sandbox
EOF
  # }}}
}; # }}}
teardown_vault();
done_testing;

# vim: fdm=marker:foldlevel=1:noet
