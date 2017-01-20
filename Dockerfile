FROM ubuntu

ENV SPRUCE_VERSION=1.5.0 \
  CF_CLI_VERSION=6.13.0 \
  VAULT_VERSION=0.6.0 \
  GENESIS_VERSION=1.7.0

# base packages
RUN apt-get update \
      && apt-get install -yy curl file unzip git ruby \
      && gem install bosh_cli

# base packages
RUN apt-get install -yy curl file

# spruce
RUN curl -L >/usr/bin/spruce https://github.com/geofffranks/spruce/releases/download/v${SPRUCE_VERSION}/spruce-linux-amd64 \
      && chmod 0755 /usr/bin/spruce

# jq
RUN curl -L >/usr/bin/jq http://stedolan.github.io/jq/download/linux64/jq \
      && chmod 755 /usr/bin/jq

# vault
RUN curl -L >/tmp/vault.zip https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip \
     && unzip /tmp/vault.zip -d /usr/bin/

RUN curl -L >/usr/bin/genesis https://github.com/starkandwayne/genesis/releases/download/v${GENESIS_VERSION}/genesis \
      && chmod 755 /usr/bin/genesis \
      && genesis -v

