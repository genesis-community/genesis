#!/bin/bash

for target_dsn in $(get_creds_for_all_bosh); do
  bosh target ${target_dsn}
  bosh login $(username_from ${target_dsn}) $(password_from ${target_dsn})
done

cat ~/.bosh_config

cd site/env
make manifest
bosh target $(spruce json manifests/manifest.yml | jq -r .director_uuid))
make deploy
