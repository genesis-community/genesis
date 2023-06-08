FROM registry.ops.scalecf.net/genesis-community/genesis:latest

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
 && curl -Lo shellcheck.tar.xz "https://github.com/koalaman/shellcheck/releases/download/v0.7.2/shellcheck-v0.7.2.linux.x86_64.tar.xz" \
     && tar -xf shellcheck.tar.xz \
     && mv shellcheck*/shellcheck /usr/bin/shellcheck \
     && chmod 0755 /usr/bin/shellcheck \
     && rm -rf shellcheck* \
 && git config --global user.name "Genesis CI Bot" \
 && git config --global user.email genesis-ci@rubidiumstudios.com
