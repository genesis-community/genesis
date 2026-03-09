# Genesis Project - Copilot Instructions

Perl-based OOP BOSH environment management CLI for Cloud Foundry ecosystem. Manages deployment repositories, environments, secrets, and BOSH deployments.

## Core Components

- **Repository** (`Genesis::Top`): Collection of environments for a kit type
- **Environment** (`Genesis::Env`): Specific deployment instance with manifest and secrets
- **Kit** (`Genesis::Kit`): Deployment templates with manifest fragments and hooks
- **Hooks**: Scripts executed during environment lifecycle (blueprint, check, pre/post-deploy, etc.)

## Key Classes

| Class | Purpose |
|-------|---------|
| `Genesis::Top` | Repository management |
| `Genesis::Env` | Environment lifecycle |
| `Genesis::Kit` | Kit management |
| `Genesis::Command::*` | CLI command implementations |
| `Genesis::Hook::*` | Hook implementations |
| `Genesis::Secret::*` | Secret type implementations |

## Core Directory Structure

- **`lib/Genesis/`**: Main modules (Command.pm, Top.pm, Env.pm, Kit.pm, Hook.pm)
- **`lib/Genesis/Command/`**: CLI commands (Env.pm, Kit.pm, Repo.pm, Bosh.pm, etc.)
- **`lib/Genesis/Env/`**: Environment components (Manifest.pm, Secrets/, ManifestProvider.pm)
- **`lib/Genesis/Kit/`**: Kit management (Compiled.pm, Dev.pm, Provider.pm, Compiler.pm)
- **`lib/Genesis/Hook/`**: Hook types (Blueprint, CloudConfig, etc.)
- **`lib/Genesis/Service/`**: External service libraries (Vault, Credhub, BOSH)
- **`bin/`**: Main executables
- **`t/`**: Test suite with numbered prefixes

## Coding Standards

### Pragmas
- **`lib/` files**: `use v5.20; use warnings;` (no strict needed)
- **Files outside `lib/Genesis`**: Should use `use feature 'signatures'; no warnings 'experimental::signatures';`

### Style
- Tab indentation (2 spaces)
- Vim config: `# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu`
- Method fold comments: `# method_name - description {{{` ... `# }}}`
- Conditional calls: `call() if $condition;` preferred over if blocks
- Use `//` for defaults: `$env->lookup('key') // 'default'`
- Explicit imports: `use Genesis::Term qw/wrap colorize bullet/;`

### Logging
- Functions: `info`, `warning`, `error`, `notice`, `bail`, `bug` (printf-style)
- UTF-8 glyphs: Use `Genesis::Term::colorize` with `#@{x}` syntax
- No CPAN dependencies (core Perl + lib/ only)

## Hooks

### Structure
```perl
package Genesis::Hook::HookType::KitType[::HookSubtype];
use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}
use parent 'Genesis::Hook::BaseType';

use Genesis::Module;

use File::Basename;

sub init { ... }

sub perform {
	# ...
	return $self->done($result);
}

1;
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
```

### Common Hook Types
- `blueprint`: Feature validation and manifest fragment selection
- `check`: Pre-deployment validation
- `cloud-config`, `cpi-config`: Infrastructure configuration
- `pre-deploy`, `post-deploy`: Lifecycle hooks
- `addon-*`: Custom environment tasks
