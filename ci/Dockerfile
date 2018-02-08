FROM starkandwayne/concourse:latest-rc

RUN apt-get update \
 && apt-get install -y \
      libexpect-perl \
      expect \
      libtest-differences-perl \
 && git config --global user.name "Concourse BOT" \
 && git config --global user.email concourse-bot@starkandwayne.com
