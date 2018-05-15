FROM starkandwayne/concourse:latest-rc

RUN apt-get update \
 && apt-get install -y \
      libexpect-perl \
      expect \
      libtest-deep-perl \
      libtest-differences-perl \
      libtest-exception-perl \
      libtest-output-perl \
 && git config --global user.name "Concourse BOT" \
 && git config --global user.email concourse-bot@starkandwayne.com
