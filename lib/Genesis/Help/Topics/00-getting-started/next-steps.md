# Next Steps

Now that you've completed your first Genesis deployment, here's where to go next based on your goals.

## Essential Skills

### 1. Master Environment Management

Learn how Genesis environments work:
- **[Environment Naming](../10-environments/naming-conventions.md)** - Naming patterns and hierarchies
- **[Configuration Merging](../10-environments/configuration-merging.md)** - How inheritance works
- **[Environment Files](../10-environments/file-structure.md)** - File organization best practices

### 2. Understand Secrets Management

Secure your deployments:
- **[Vault Integration](../30-secrets-management/vault-integration.md)** - Working with Vault
- **[Secret Rotation](../30-secrets-management/rotation-procedures.md)** - Rotating credentials safely
- **[CredHub Support](../30-secrets-management/credhub-support.md)** - Alternative to Vault

### 3. Explore Available Kits

Deploy additional software:
- **[Using Kits](../50-kits/using-kits.md)** - Finding and selecting kits
- **[Kit Features](../50-kits/features.md)** - Enabling optional components
- **[Popular Kits](../50-kits/popular-kits.md)** - Common deployment patterns

## Common Next Deployments

After BOSH, teams typically deploy:

### Vault (Secrets Management)
```bash
genesis init --kit vault vault-deployments
cd vault-deployments
genesis new my-vault
```
Essential for production secrets management.

### Shield (Backup & Restore)
```bash
genesis init --kit shield shield-deployments
cd shield-deployments
genesis new my-shield  
```
Protect your data with automated backups.

### Concourse (CI/CD)
```bash
genesis init --kit concourse concourse-deployments
cd concourse-deployments
genesis new my-ci
```
Automate your Genesis deployments.

### Prometheus (Monitoring)
```bash
genesis init --kit prometheus prometheus-deployments
cd prometheus-deployments
genesis new my-monitoring
```
Monitor your entire infrastructure.

## Advanced Topics

### For Operators

- **[BOSH Integration](../60-bosh/index.md)** - Advanced BOSH management
- **[Troubleshooting](../70-troubleshooting/index.md)** - Debugging deployments
- **[Runtime Configs](../60-bosh/runtime-configs.md)** - Cross-deployment configuration

### For Kit Authors

- **[Authoring Kits](../50-kits/authoring-kits.md)** - Create your own kits
- **[Kit Hooks](../50-kits/kit-hooks.md)** - Lifecycle customization
- **[Writing Hooks](../50-kits/writing-hooks.md)** - Hook development guide

### For Automation

- **[Pipeline Integration](../60-bosh/pipelines.md)** - CI/CD with Concourse
- **[Environment Variables](../90-reference-guides/environment-variables.md)** - Scripting Genesis
- **[Command Reference](../90-reference-guides/commands.md)** - All Genesis commands

## Best Practices

### Repository Organization

Structure your repositories for success:

```
infrastructure/
├── bosh-deployments/      # BOSH directors
├── vault-deployments/     # Vault clusters
├── cf-deployments/        # Cloud Foundry
└── k8s-deployments/       # Kubernetes
```

### Environment Naming

Use consistent patterns:
- `us-east-1-prod` - Production in us-east-1
- `us-west-2-staging` - Staging in us-west-2  
- `lab-dev` - Development lab

### Git Workflow

```bash
# Always work in branches
git checkout -b add-production-env

# Make changes
genesis new us-east-1-prod
vim us-east-1-prod.yml

# Commit and push
git add .
git commit -m "Add production environment"
git push origin add-production-env

# Create pull request for review
```

### Security Practices

1. **Never commit secrets** - Use Vault/CredHub
2. **Rotate regularly** - Schedule credential rotation
3. **Audit access** - Review Vault policies
4. **Backup secrets** - Use Shield for Vault backups

## Getting Help

### Documentation

- Run `genesis help` for command help
- Use `genesis help <topic>` for detailed guides
- Check kit documentation with `genesis info <kit>`

### Community

- **Slack** - Join [Genesis Community Slack](https://genesiscommunity.slack.com)
- **GitHub** - Report issues and contribute
- **Office Hours** - Weekly community calls

### Learning Resources

- **[Genesis Examples](https://github.com/genesis-community/examples)** - Sample deployments
- **[Kit Repositories](https://github.com/genesis-community)** - All official kits
- **[Training Materials](https://genesis-community.io/docs)** - Workshops and tutorials

## Certification Path

Consider this learning progression:

1. **Genesis Basics** ✓
   - First deployment
   - Environment management
   - Basic operations

2. **Intermediate Skills**
   - Multi-environment deployments
   - Pipeline automation
   - Troubleshooting

3. **Advanced Topics**
   - Kit development
   - Complex architectures
   - Performance tuning

4. **Expert Level**
   - Contributing to Genesis
   - Creating community kits
   - Training others

## Quick Reference

Essential commands for your journey:

```bash
# Deployment lifecycle
genesis init --kit <kit> <repo>  # Start new repository
genesis new <env>                 # Create environment
genesis deploy <env>              # Deploy environment
genesis info <kit>                # Kit documentation

# Operations
genesis list                      # List all environments
genesis switch <repo>             # Change repositories  
genesis describe <env>            # Environment details
genesis manifest <env>            # View manifest

# Maintenance
genesis rotate-secrets <env>      # Rotate credentials
genesis check <env>               # Pre-deployment checks
genesis do <env> -- <addon>       # Run kit addons

# Help
genesis help                      # General help
genesis help <topic>              # Topic help
genesis <cmd> -h                  # Command help
```

## Your Genesis Journey

Remember:
- Start small and iterate
- Use version control for everything
- Ask questions in the community
- Share your experiences

Welcome to the Genesis community!