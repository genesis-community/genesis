# Genesis CI Pipeline Documentation

Genesis includes a CI pipeline system that generates deployment automation
for CI/CD platforms. The system supports Concourse CI natively

This documentation is split into two audiences:

## For Operators and Users

If you are an operator who wants to set up automated deployment pipelines
for your Genesis environments, start here:

| Document | What It Covers |
|----------|----------------|
| [Getting Started](user/getting-started.md) | Writing your first `ci.yml` and deploying a pipeline |
| [Configuration Reference](user/configuration-reference.md) | Every option available in legacy `ci.yml` format |
| [Layout DSL](user/layout-dsl.md) | The pipeline layout language for defining environment progression |
| [Multi-File Configuration](user/multi-file-configuration.md) | The new `.genesis/ci/` directory format |
| [CLI Commands](user/cli-commands.md) | The `genesis repipe`, `graph`, and `describe` commands |

## For Developers

If you are contributing to the Genesis CI compiler or writing a new
CI platform provider, start here:

| Document | What It Covers |
|----------|----------------|
| [Architecture Overview](dev/architecture.md) | System design, module relationships, and data flow |
| [Compiler Pipeline](dev/compiler-pipeline.md) | The six-stage compilation process in detail |
| [AST and PipelineDescriptor](dev/ast-and-descriptor.md) | The two-layer AST design and how generic pipelines are built |
| [Writing a Provider](dev/writing-a-provider.md) | How to implement a new CI platform provider |
| [Legacy Bridge](dev/legacy-bridge.md) | How `Legacy.pm` interoperates with the modern compiler |
| [Module Reference](dev/module-reference.md) | Every Perl module, its role, and its public API |
