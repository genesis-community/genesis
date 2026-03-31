#!/bin/bash
# @genesis-script
# @description: Run smoke tests against deployed Cloud Foundry
# @version: 1.0
# @requires: cf>=8.0.0, curl
# @input: deployment-repo (git-repository, required)
# @env-required: CURRENT_ENV, CF_API, CF_USERNAME, CF_PASSWORD
# @timeout: 15m

set -eu
set -o pipefail

REPO_ROOT="${1:-.}"
cd "$REPO_ROOT"

echo "========================================="
echo "Cloud Foundry Smoke Tests: $CURRENT_ENV"
echo "========================================="
echo "CF API: $CF_API"
echo ""

# Login to CF
echo "Logging in to Cloud Foundry..."
if ! cf login -a "$CF_API" -u "$CF_USERNAME" -p "$CF_PASSWORD" --skip-ssl-validation; then
  echo "ERROR: Failed to login to CF API"
  exit 1
fi

# Check API health
echo ""
echo "Checking API health..."
if ! cf api; then
  echo "ERROR: CF API is not healthy"
  exit 1
fi

# Run smoke tests
echo ""
echo "Running smoke tests..."

# Test 1: Can we list orgs?
echo "  - Testing org listing..."
if ! cf orgs &>/dev/null; then
  echo "ERROR: Cannot list orgs"
  exit 1
fi
echo "    ✓ Org listing works"

# Test 2: Can we list spaces?
echo "  - Testing space listing..."
if ! cf spaces &>/dev/null; then
  echo "ERROR: Cannot list spaces"
  exit 1
fi
echo "    ✓ Space listing works"

# Test 3: Can we check buildpacks?
echo "  - Testing buildpack listing..."
if ! cf buildpacks &>/dev/null; then
  echo "ERROR: Cannot list buildpacks"
  exit 1
fi
echo "    ✓ Buildpack listing works"

# Test 4: Can we check service marketplace?
echo "  - Testing service marketplace..."
if ! cf marketplace &>/dev/null; then
  echo "ERROR: Cannot access service marketplace"
  exit 1
fi
echo "    ✓ Service marketplace accessible"

echo ""
echo "========================================="
echo "All smoke tests passed!"
echo "========================================="
exit 0
