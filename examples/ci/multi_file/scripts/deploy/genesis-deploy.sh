#!/bin/bash
# @genesis-script
# @description: Execute Genesis deployment to BOSH director
# @version: 1.0
# @requires: genesis>=3.1.0, bosh>=7.0.0, safe>=1.7.0
# @input: deployment-repo (git-repository, required)
# @output: deployment-manifest (file, .genesis/manifests/)
# @env-required: CURRENT_ENV, VAULT_ADDR, BOSH_ENVIRONMENT
# @env-optional: GENESIS_TRACE, GENESIS_DEBUG
# @timeout: 60m

set -eu
set -o pipefail

# Enable debug output if requested
[[ "${GENESIS_TRACE:-false}" == "true" ]] && set -x

REPO_ROOT="${1:-.}"
cd "$REPO_ROOT"

echo "========================================="
echo "Genesis Deployment: $CURRENT_ENV"
echo "========================================="
echo "BOSH Director: $BOSH_ENVIRONMENT"
echo "Vault: $VAULT_ADDR"
echo ""

# Validate environment exists
if [[ ! -f "$CURRENT_ENV.yml" ]]; then
  echo "ERROR: Environment file '$CURRENT_ENV.yml' not found"
  exit 2
fi

# Check BOSH director connectivity
echo "Checking BOSH director connectivity..."
if ! bosh env &>/dev/null; then
  echo "ERROR: Cannot connect to BOSH director at $BOSH_ENVIRONMENT"
  exit 3
fi

# Check Vault connectivity
echo "Checking Vault connectivity..."
if ! safe targets &>/dev/null; then
  echo "ERROR: Cannot connect to Vault at $VAULT_ADDR"
  exit 3
fi

# Generate manifest
echo ""
echo "Generating deployment manifest..."
if ! genesis manifest "$CURRENT_ENV" > ".genesis/manifests/$CURRENT_ENV.yml"; then
  echo "ERROR: Failed to generate manifest"
  exit 2
fi

# Validate manifest
echo "Validating manifest..."
if ! bosh interpolate ".genesis/manifests/$CURRENT_ENV.yml" > /dev/null; then
  echo "ERROR: Manifest validation failed"
  exit 2
fi

# Deploy
echo ""
echo "Deploying $CURRENT_ENV..."
if genesis deploy "$CURRENT_ENV" -y; then
  echo ""
  echo "========================================="
  echo "Deployment successful!"
  echo "========================================="
  exit 0
else
  echo ""
  echo "========================================="
  echo "Deployment failed!"
  echo "========================================="
  exit 1
fi
