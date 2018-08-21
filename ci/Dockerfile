FROM starkandwayne/concourse:latest-rc

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true apt-get install -y \
      libexpect-perl \
      expect \
      libtest-deep-perl \
      libtest-differences-perl \
      libtest-exception-perl \
      libtest-output-perl \
      spruce \
      safe \
      shellcheck \
 && git config --global user.name "Concourse BOT" \
 && git config --global user.email concourse-bot@starkandwayne.com \
 && curl -Lo /tmp/vault.zip https://releases.hashicorp.com/vault/0.9.6/vault_0.9.6_linux_amd64.zip \
 && unzip /tmp/vault.zip \
 && rm -f /tmp/vault.zip \
 && mv vault /usr/bin/vault
