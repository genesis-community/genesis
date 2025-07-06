# Getting Started with Genesis

Welcome to Genesis! This guide will help you understand Genesis concepts and get your first deployment running.

## Topics in This Section

1. **[Introduction](introduction.md)** - What is Genesis and why use it?
2. **[Installation](installation.md)** - Installing Genesis and required dependencies
3. **[Concepts](concepts.md)** - Core Genesis concepts and terminology
4. **[Configuration](configuration.md)** - Basic Genesis configuration
5. **[First Deployment](first-deployment.md)** - Deploy your first environment
6. **[Next Steps](next-steps.md)** - Where to go from here

## Quick Start

If you're in a hurry, here's the minimum you need to get started:

### Install Genesis

```bash
# Download and install the latest Genesis
curl -sL https://github.com/genesis-community/genesis/releases/latest/download/genesis -o genesis
chmod +x genesis
sudo mv genesis /usr/local/bin/

# Verify installation
genesis version
```

### Install Dependencies

Genesis requires several tools to function:

```bash
# Required tools
# - safe (Vault CLI)
# - spruce (YAML processor)
# - bosh (BOSH CLI v2)
# - jq (JSON processor)

# On macOS with Homebrew:
brew install starkandwayne/cf/safe
brew install starkandwayne/cf/spruce
brew install cloudfoundry/tap/bosh-cli
brew install jq

# On Linux, follow individual tool installation guides
```

### Initialize Your First Repository

```bash
# Create a new Genesis repository for BOSH deployments
genesis init --kit bosh my-bosh-deployments
cd my-bosh-deployments

# Create your first environment
genesis new my-lab
```

### Next Steps

Continue with the detailed guides in this section to:
- Understand Genesis architecture and concepts
- Configure Genesis for your environment
- Deploy and manage your first BOSH director
- Learn about environment hierarchies and configuration management

## Getting Help

- Run `genesis help` for command reference
- Visit specific help topics with `genesis help <topic>`
- Check the [troubleshooting guide](../70-troubleshooting/index.md) for common issues
- Join the Genesis community Slack for support