FROM starkandwayne/concourse:latest

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true apt-get install -y \
      libexpect-perl \
      expect \
      libtest-deep-perl \
      libtest-differences-perl \
      libtest-exception-perl \
      libtest-output-perl \
      libtest-tcp-perl \
      iputils-ping \
      shellcheck \
 && git config --global user.name "Concourse BOT" \
 && git config --global user.email concourse-bot@starkandwayne.com
