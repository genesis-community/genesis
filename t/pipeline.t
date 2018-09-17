#!perl
use strict;
use warnings;

use lib 't';
use helper;

my $tmp = workdir;
ok -d "t/repos/pipeline-test", "pipeline-test repo exists" or die;
chdir "t/repos/pipeline-test" or die;

bosh2_cli_ok;

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
    - aggregate:
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
          type: docker-image
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
          VAULT_SKIP_VERIFY: null
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
          type: docker-image
        inputs:
        - name: out
        - name: client-aws-1-preprod-cache
        outputs:
        - name: cache-out
        params:
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-preprod
          GENESIS_HONOR_ENV: 1
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
          path: client-aws-1-preprod-cache/.genesis/bin/genesis
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    - params:
        repository: cache-out/git
      put: client-aws-1-prod-cache
    on_failure:
      aggregate:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-preprod-pipeline-test
            failed'
          username: runwaybot
        put: slack
    on_success:
      aggregate:
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
  - aggregate:
    - get: client-aws-1-prod-changes
      trigger: true
    - get: client-aws-1-prod-cloud-config
      trigger: true
    - get: client-aws-1-prod-runtime-config
      trigger: true
    - get: client-aws-1-prod-cache
      passed:
      - client-aws-1-preprod-pipeline-test
      trigger: true
  - aggregate:
    - params:
        channel: '#botspam'
        icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
        text: 'aws-1: Changes are staged to be deployed to client-aws-1-prod-pipeline-test,
          please schedule + run a deploy via Concourse'
        username: runwaybot
      put: slack
  public: true
  serial: true
- name: client-aws-1-prod-pipeline-test
  plan:
  - do:
    - aggregate:
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
          type: docker-image
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
          VAULT_SKIP_VERIFY: null
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
          type: docker-image
        inputs:
        - name: out
        - name: client-aws-1-prod-cache
        outputs:
        - name: cache-out
        params:
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-prod
          GENESIS_HONOR_ENV: 1
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
          path: client-aws-1-prod-cache/.genesis/bin/genesis
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    on_failure:
      aggregate:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-prod-pipeline-test failed'
          username: runwaybot
        put: slack
    on_success:
      aggregate:
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
    - aggregate:
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
          type: docker-image
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
          VAULT_SKIP_VERIFY: null
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
          type: docker-image
        inputs:
        - name: out
        - name: client-aws-1-sandbox-changes
        outputs:
        - name: cache-out
        params:
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-sandbox
          GENESIS_HONOR_ENV: 1
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
      aggregate:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-sandbox-pipeline-test
            failed'
          username: runwaybot
        put: slack
    on_success:
      aggregate:
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
  type: docker-image
- name: email
  source:
    repository: pcfseceng/email-resource
  type: docker-image
- name: slack-notification
  source:
    repository: cfcommunity/slack-notification-resource
  type: docker-image
- name: hipchat-notification
  source:
    repository: cfcommunity/hipchat-notification-resource
  type: docker-image
- name: stride-notification
  source:
    repository: starkandwayne/stride-notification-resource
  type: docker-image
- name: bosh-config
  source:
    repository: cfcommunity/bosh-config-resource
  type: docker-image
- name: locker
  source:
    repository: cfcommunity/locker-resource
  type: docker-image
resources:
- name: git
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
- name: client-aws-1-preprod-changes
  source:
    branch: master
    paths:
    - ./client-aws-1-preprod.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- name: client-aws-1-preprod-cache
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
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
- name: client-aws-1-preprod-cloud-config
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
- name: client-aws-1-preprod-runtime-config
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
- name: client-aws-1-prod-changes
  source:
    branch: master
    paths:
    - ./client-aws-1-prod.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- name: client-aws-1-prod-cache
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
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
- name: client-aws-1-prod-cloud-config
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
- name: client-aws-1-prod-runtime-config
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
- name: client-aws-1-sandbox-changes
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
    - ./client.yml
    - ./client-aws.yml
    - ./client-aws-1.yml
    - ./client-aws-1-sandbox.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- name: client-aws-1-sandbox-cloud-config
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
- name: client-aws-1-sandbox-runtime-config
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
- name: slack
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
    - aggregate:
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
          type: docker-image
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
          VAULT_SKIP_VERIFY: null
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
          type: docker-image
        inputs:
        - name: out
        - name: client-aws-1-preprod-cache
        outputs:
        - name: cache-out
        params:
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-preprod
          GENESIS_HONOR_ENV: 1
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
      aggregate:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-preprod-pipeline-test
            failed'
          username: runwaybot
        put: slack
    on_success:
      aggregate:
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
  - aggregate:
    - get: client-aws-1-prod-changes
      trigger: true
    - get: client-aws-1-prod-cloud-config
      tags:
      - client-aws-1-prod
      trigger: true
    - get: client-aws-1-prod-runtime-config
      tags:
      - client-aws-1-prod
      trigger: true
    - get: client-aws-1-prod-cache
      passed:
      - client-aws-1-preprod-pipeline-test
      trigger: true
  - aggregate:
    - params:
        channel: '#botspam'
        icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
        text: 'aws-1: Changes are staged to be deployed to client-aws-1-prod-pipeline-test,
          please schedule + run a deploy via Concourse'
        username: runwaybot
      put: slack
  public: true
  serial: true
- name: client-aws-1-prod-pipeline-test
  plan:
  - do:
    - aggregate:
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
          type: docker-image
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
          VAULT_SKIP_VERIFY: null
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
          type: docker-image
        inputs:
        - name: out
        - name: client-aws-1-prod-cache
        outputs:
        - name: cache-out
        params:
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-prod
          GENESIS_HONOR_ENV: 1
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
          path: client-aws-1-prod-cache/.genesis/bin/genesis
      tags:
      - client-aws-1-prod
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    on_failure:
      aggregate:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-prod-pipeline-test failed'
          username: runwaybot
        put: slack
    on_success:
      aggregate:
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
    - aggregate:
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
          type: docker-image
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
          VAULT_SKIP_VERIFY: null
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
          type: docker-image
        inputs:
        - name: out
        - name: client-aws-1-sandbox-changes
        outputs:
        - name: cache-out
        params:
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-sandbox
          GENESIS_HONOR_ENV: 1
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
      aggregate:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-sandbox-pipeline-test
            failed'
          username: runwaybot
        put: slack
    on_success:
      aggregate:
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
  type: docker-image
- name: email
  source:
    repository: pcfseceng/email-resource
  type: docker-image
- name: slack-notification
  source:
    repository: cfcommunity/slack-notification-resource
  type: docker-image
- name: hipchat-notification
  source:
    repository: cfcommunity/hipchat-notification-resource
  type: docker-image
- name: stride-notification
  source:
    repository: starkandwayne/stride-notification-resource
  type: docker-image
- name: bosh-config
  source:
    repository: cfcommunity/bosh-config-resource
  type: docker-image
- name: locker
  source:
    repository: cfcommunity/locker-resource
  type: docker-image
resources:
- name: git
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
- name: client-aws-1-preprod-changes
  source:
    branch: master
    paths:
    - ./client-aws-1-preprod.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- name: client-aws-1-preprod-cache
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
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
- name: client-aws-1-preprod-cloud-config
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
- name: client-aws-1-preprod-runtime-config
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
- name: client-aws-1-prod-changes
  source:
    branch: master
    paths:
    - ./client-aws-1-prod.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- name: client-aws-1-prod-cache
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
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
- name: client-aws-1-prod-cloud-config
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
- name: client-aws-1-prod-runtime-config
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
- name: client-aws-1-sandbox-changes
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
    - ./client.yml
    - ./client-aws.yml
    - ./client-aws-1.yml
    - ./client-aws-1-sandbox.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- name: client-aws-1-sandbox-cloud-config
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
- name: client-aws-1-sandbox-runtime-config
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
- name: slack
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
    - aggregate:
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
          type: docker-image
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
          VAULT_SKIP_VERIFY: null
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
          type: docker-image
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
          type: docker-image
        inputs:
        - name: out
        - name: preprod-cache
        outputs:
        - name: cache-out
        params:
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-preprod
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
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
          path: preprod-cache/.genesis/bin/genesis
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    - params:
        repository: cache-out/git
      put: prod-cache
    on_failure:
      aggregate:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-preprod-pipeline-test
            failed'
          username: runwaybot
        put: slack
    on_success:
      aggregate:
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
  - aggregate:
    - get: prod-changes
      trigger: true
    - get: prod-cloud-config
      trigger: true
    - get: prod-runtime-config
      trigger: true
    - get: prod-cache
      passed:
      - preprod-pipeline-test
      trigger: true
  - aggregate:
    - params:
        channel: '#botspam'
        icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
        text: 'aws-1: Changes are staged to be deployed to client-aws-1-prod-pipeline-test,
          please schedule + run a deploy via Concourse'
        username: runwaybot
      put: slack
  public: true
  serial: true
- name: prod-pipeline-test
  plan:
  - do:
    - aggregate:
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
          type: docker-image
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
          VAULT_SKIP_VERIFY: null
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
          type: docker-image
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
          type: docker-image
        inputs:
        - name: out
        - name: prod-cache
        outputs:
        - name: cache-out
        params:
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-prod
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
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
          path: prod-cache/.genesis/bin/genesis
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    on_failure:
      aggregate:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-prod-pipeline-test failed'
          username: runwaybot
        put: slack
    on_success:
      aggregate:
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
    - aggregate:
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
          type: docker-image
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
          VAULT_SKIP_VERIFY: null
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
          type: docker-image
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
          type: docker-image
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
          path: sandbox-changes/.genesis/bin/genesis
      task: generate-cache
    - params:
        repository: cache-out/git
      put: git
    - params:
        repository: cache-out/git
      put: preprod-cache
    on_failure:
      aggregate:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-sandbox-pipeline-test
            failed'
          username: runwaybot
        put: slack
    on_success:
      aggregate:
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
  type: docker-image
- name: email
  source:
    repository: pcfseceng/email-resource
  type: docker-image
- name: slack-notification
  source:
    repository: cfcommunity/slack-notification-resource
  type: docker-image
- name: hipchat-notification
  source:
    repository: cfcommunity/hipchat-notification-resource
  type: docker-image
- name: stride-notification
  source:
    repository: starkandwayne/stride-notification-resource
  type: docker-image
- name: bosh-config
  source:
    repository: cfcommunity/bosh-config-resource
  type: docker-image
- name: locker
  source:
    repository: cfcommunity/locker-resource
  type: docker-image
resources:
- name: git
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
- name: preprod-changes
  source:
    branch: master
    paths:
    - ./client-aws-1-preprod.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- name: preprod-cache
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
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
- name: preprod-cloud-config
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
- name: preprod-runtime-config
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
- name: prod-changes
  source:
    branch: master
    paths:
    - ./client-aws-1-prod.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- name: prod-cache
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
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
- name: prod-cloud-config
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
- name: prod-runtime-config
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
- name: sandbox-changes
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
    - ./client.yml
    - ./client-aws.yml
    - ./client-aws-1.yml
    - ./client-aws-1-sandbox.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- name: sandbox-cloud-config
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
- name: sandbox-runtime-config
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
- name: slack
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
    - aggregate:
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
          type: docker-image
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
          VAULT_SKIP_VERIFY: 1
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
          type: docker-image
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
          type: docker-image
        inputs:
        - name: out
        - name: client-aws-1-preprod-cache
        outputs:
        - name: cache-out
        params:
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-preprod
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
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
      aggregate:
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
      aggregate:
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
  - aggregate:
    - get: client-aws-1-prod-changes
      trigger: true
    - get: client-aws-1-prod-cloud-config
      tags:
      - client-aws-1-prod
      trigger: true
    - get: client-aws-1-prod-runtime-config
      tags:
      - client-aws-1-prod
      trigger: true
    - get: client-aws-1-prod-cache
      passed:
      - client-aws-1-preprod-pipeline-test
      trigger: true
  - aggregate:
    - params:
        channel: '#botspam'
        icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
        text: 'aws-1: Changes are staged to be deployed to client-aws-1-prod-pipeline-test,
          please schedule + run a deploy via Concourse'
        username: runwaybot
      put: slack
    - params:
        color: gray
        from: runwaybot
        message: 'aws-1: Changes are staged to be deployed to client-aws-1-prod-pipeline-test,
          please schedule + run a deploy via Concourse'
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
    - aggregate:
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
          type: docker-image
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
          VAULT_SKIP_VERIFY: 1
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
          type: docker-image
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
          type: docker-image
        inputs:
        - name: out
        - name: client-aws-1-prod-cache
        outputs:
        - name: cache-out
        params:
          CI_NO_REDACT: 1
          CURRENT_ENV: client-aws-1-prod
          DEBUG: 1
          GENESIS_HONOR_ENV: 1
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
      aggregate:
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
      aggregate:
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
    - aggregate:
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
          type: docker-image
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
          VAULT_SKIP_VERIFY: 1
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
          type: docker-image
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
          type: docker-image
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
      aggregate:
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
      aggregate:
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
  type: docker-image
- name: email
  source:
    repository: pcfseceng/email-resource
  type: docker-image
- name: slack-notification
  source:
    repository: cfcommunity/slack-notification-resource
  type: docker-image
- name: hipchat-notification
  source:
    repository: cfcommunity/hipchat-notification-resource
  type: docker-image
- name: stride-notification
  source:
    repository: starkandwayne/stride-notification-resource
  type: docker-image
- name: bosh-config
  source:
    repository: cfcommunity/bosh-config-resource
  type: docker-image
- name: locker
  source:
    repository: cfcommunity/locker-resource
  type: docker-image
resources:
- name: git
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
- name: client-aws-1-preprod-changes
  source:
    branch: master
    paths:
    - ./client-aws-1-preprod.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- name: client-aws-1-preprod-cache
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
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
- name: client-aws-1-preprod-cloud-config
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
- name: client-aws-1-preprod-runtime-config
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
- name: client-aws-1-preprod-bosh-lock
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
- name: client-aws-1-preprod-deployment-lock
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
- name: client-aws-1-prod-changes
  source:
    branch: master
    paths:
    - ./client-aws-1-prod.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- name: client-aws-1-prod-cache
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
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
- name: client-aws-1-prod-cloud-config
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
- name: client-aws-1-prod-runtime-config
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
- name: client-aws-1-prod-bosh-lock
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
- name: client-aws-1-prod-deployment-lock
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
- name: client-aws-1-sandbox-changes
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
    - ./client.yml
    - ./client-aws.yml
    - ./client-aws-1.yml
    - ./client-aws-1-sandbox.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- name: client-aws-1-sandbox-cloud-config
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
- name: client-aws-1-sandbox-runtime-config
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
- name: client-aws-1-sandbox-bosh-lock
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
- name: client-aws-1-sandbox-deployment-lock
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
- name: slack
  source:
    url: http://127.0.0.1:1337
  type: slack-notification
- name: hipchat
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
    - aggregate:
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
          type: docker-image
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
          VAULT_SKIP_VERIFY: 1
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
          type: docker-image
        inputs:
        - name: out
        - name: client-aws-1-sandbox-changes
        outputs:
        - name: cache-out
        params:
          CI_NO_REDACT: 0
          CURRENT_ENV: client-aws-1-sandbox
          GENESIS_HONOR_ENV: 1
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
    on_failure:
      aggregate:
      - params:
          channel: '#botspam'
          icon_url: http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
          text: 'aws-1: Concourse deployment to client-aws-1-sandbox-pipeline-test
            failed'
          username: runwaybot
        put: slack
    on_success:
      aggregate:
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
  type: docker-image
- name: email
  source:
    repository: pcfseceng/email-resource
  type: docker-image
- name: slack-notification
  source:
    repository: cfcommunity/slack-notification-resource
  type: docker-image
- name: hipchat-notification
  source:
    repository: cfcommunity/hipchat-notification-resource
  type: docker-image
- name: stride-notification
  source:
    repository: starkandwayne/stride-notification-resource
  type: docker-image
- name: bosh-config
  source:
    repository: cfcommunity/bosh-config-resource
  type: docker-image
- name: locker
  source:
    repository: cfcommunity/locker-resource
  type: docker-image
resources:
- name: git
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
- name: client-aws-1-sandbox-changes
  source:
    branch: master
    paths:
    - .genesis/bin/genesis
    - .genesis/kits
    - .genesis/config
    - ./client.yml
    - ./client-aws.yml
    - ./client-aws-1.yml
    - ./client-aws-1-sandbox.yml
    private_key: |
      -----BEGIN RSA PRIVATE KEY-----
      lol. you didn't really think that
      we'd put the key here, in a test,
      did you?!
      -----END RSA PRIVATE KEY-----
    uri: git@github.com:someco/something-deployments
  type: git
- name: client-aws-1-sandbox-cloud-config
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
- name: client-aws-1-sandbox-runtime-config
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
- name: slack
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

done_testing;
