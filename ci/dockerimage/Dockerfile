FROM --platform=linux/amd64 ubuntu:jammy
MAINTAINER Dennis J. Bell <dennis.j.bell@gmail.com>

RUN apt-get update \
 && apt-get install -yy wget gnupg \
 && mkdir -p -m 755 /etc/apt/keyrings \
 && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
 && wget -q -O - https://raw.githubusercontent.com/cloudfoundry-community/homebrew-cf/master/public.key | apt-key add - \
 && echo "deb http://apt.community.cloudfoundry.org stable main" | tee /etc/apt/sources.list.d/cloudfoundry-community.list \
 && apt-get update && apt-get install -yy \
    aha \
    autoconf \
    bosh-cli \
    build-essential \
    bzip2 \
    cf-cli \
    cf6-cli \
    credhub-cli \
    curl \
    file \
    git \
    gh \
    gotcha \
    jq \
    libreadline8 \
    libreadline-dev \
    libsqlite3-dev \
    libssl-dev \
    libtool \
    libxml2-dev \
    libxslt-dev \
    libyaml-dev \
    libyaml-perl \
    lsof \
    om \
    openssl \
    pivnet-cli \
    ruby \
    ruby-dev \
    sipcalc \
    safe \
    spruce \
    sqlite3 \
    vault \
    vim-common \
    unzip \
    zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

ARG GENESIS_VERSION

RUN curl -Lo /usr/bin/genesis https://github.com/genesis-community/genesis/releases/download/v$GENESIS_VERSION/genesis \
     && chmod 0755 /usr/bin/genesis

RUN genesis -v
