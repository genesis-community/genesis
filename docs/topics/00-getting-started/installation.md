# Installing Genesis

This guide covers installing Genesis and its required dependencies.

## System Requirements

Genesis runs on:
- macOS (Intel and Apple Silicon)
- Linux (x86_64)
- Windows (via WSL2)

## Installing Genesis

### Quick Install (Recommended)

Download the latest release directly from GitHub:

```bash
# Download the latest Genesis binary
curl -sL https://github.com/genesis-community/genesis/releases/latest/download/genesis -o genesis

# Make it executable
chmod +x genesis

# Move to your PATH (may require sudo)
sudo mv genesis /usr/local/bin/

# Verify installation
genesis version
```

### Alternative Installation Methods

#### Using Homebrew (macOS)

```bash
brew tap genesis-community/genesis
brew install genesis
```

#### Manual Download

1. Visit the [Genesis releases page](https://github.com/genesis-community/genesis/releases)
2. Download the appropriate binary for your platform
3. Make it executable and place it in your PATH

## Required Dependencies

Genesis requires several tools to function properly. Install all of these before using Genesis:

### 1. Safe (Vault CLI)

Safe is used for secrets management with Vault.

```bash
# macOS
brew install starkandwayne/cf/safe

# Linux (64-bit)
curl -sL https://github.com/starkandwayne/safe/releases/latest/download/safe-linux-amd64 -o safe
chmod +x safe
sudo mv safe /usr/local/bin/
```

### 2. Spruce

Spruce is used for YAML manipulation and merging.

```bash
# macOS
brew install starkandwayne/cf/spruce

# Linux
curl -sL https://github.com/geofffranks/spruce/releases/latest/download/spruce-linux-amd64 -o spruce
chmod +x spruce
sudo mv spruce /usr/local/bin/
```

### 3. BOSH CLI v2

The BOSH CLI is used for deploying to BOSH directors.

```bash
# macOS
brew install cloudfoundry/tap/bosh-cli

# Linux
curl -sL https://github.com/cloudfoundry/bosh-cli/releases/latest/download/bosh-cli-*-linux-amd64 -o bosh
chmod +x bosh
sudo mv bosh /usr/local/bin/
```

### 4. jq

jq is used for JSON processing.

```bash
# macOS
brew install jq

# Linux (Ubuntu/Debian)
sudo apt-get update && sudo apt-get install -y jq

# Linux (RedHat/CentOS)
sudo yum install -y jq
```

### 5. Git

Git is used for version control of your deployment repositories.

```bash
# macOS (usually pre-installed)
git --version

# Linux (Ubuntu/Debian)
sudo apt-get update && sudo apt-get install -y git

# Linux (RedHat/CentOS)
sudo yum install -y git
```

## Optional Dependencies

These tools enhance Genesis functionality but aren't strictly required:

### CredHub CLI

For deployments using CredHub instead of Vault:

```bash
# macOS
brew install cloudfoundry/tap/credhub-cli

# Linux
curl -sL https://github.com/cloudfoundry-incubator/credhub-cli/releases/latest/download/credhub-linux-*.tgz -o credhub.tgz
tar -xzf credhub.tgz
sudo mv credhub /usr/local/bin/
```

### Vault

For running a local Vault server:

```bash
# macOS
brew install vault

# Linux
curl -sL https://releases.hashicorp.com/vault/*/vault_*_linux_amd64.zip -o vault.zip
unzip vault.zip
sudo mv vault /usr/local/bin/
```

## Verify Installation

After installing Genesis and its dependencies, verify everything is working:

```bash
# Check Genesis
genesis version

# Check dependencies
safe version
spruce --version
bosh --version
jq --version
git --version

# Optional: Check if all dependencies are found
genesis ping
```

## Initial Configuration

Genesis stores its configuration in `~/.genesis/config`. Create this file with basic settings:

```bash
# Create Genesis configuration directory
mkdir -p ~/.genesis

# Create basic configuration
cat > ~/.genesis/config <<EOF
---
# Genesis Configuration

# Default BOSH targeting behavior
default_bosh_target: ask

# Deployment root directories (optional)
deployment_roots:
  - ~/deployments
EOF
```

See the [Configuration Guide](configuration.md) for more details on available options.

## Troubleshooting Installation

### Command Not Found

If you get "command not found" errors:
1. Ensure the binary is in your PATH
2. Check file permissions (`ls -la /usr/local/bin/genesis`)
3. Try using the full path to the binary

### Permission Denied

If you get permission errors:
1. Ensure the binary is executable (`chmod +x genesis`)
2. Use `sudo` when moving to system directories
3. Consider using a user-local bin directory (e.g., `~/bin`)

### Missing Dependencies

Genesis will warn you about missing dependencies. Install any that are reported as missing.

## Next Steps

Now that Genesis is installed:
- Learn about [Core Concepts](concepts.md)
- Configure Genesis with your [preferences](configuration.md)
- Create your [First Deployment](first-deployment.md)