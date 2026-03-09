# Using Mixins for Common Methods in Genesis

When developing multiple addon hooks for a Genesis kit, you often find yourself duplicating common functionality across multiple files. This guide shows how to use Perl's mixin pattern to share common methods cleanly across your addon hooks, and more broadly, across Genesis library modules.

## The Problem: Code Duplication

Consider a typical addon hook that needs to:
- Connect to Cloud Foundry
- Retrieve service broker credentials
- Handle version checking
- Perform similar setup tasks

Without a shared approach, each addon file would duplicate 30+ lines of identical CF login logic:

```perl
# Repeated in every addon file!
my $cf_deployment_env = $env->exodus_lookup('cf_deployment_env');
my $cf_deployment_type = $env->exodus_lookup('cf_deployment_type');
# ... 25 more lines of CF connection logic
```

## The Solution: The Mixin Pattern

Instead of complex inheritance hierarchies, we can use Perl's mixin pattern to literally include common method definitions into each consuming class. A mixin is a `.pm` file that injects methods into the caller's namespace — no subclassing, no method resolution chains, just direct method injection.

### What Is a Mixin?

A mixin is a `.pm` file with these characteristics:

- **No `package` declaration** — methods execute in the caller's namespace
- **Filename starts with `_`** — naming convention (e.g., `_addon.pm`, `_vaultify_mixin.pm`)
- **Defines methods** that become part of the consuming class's symbol table
- **May include its own `use` statements** — for modules the mixin needs directly
- **Ends with `1;`** — standard Perl true return

Unlike inheritance, where method resolution walks up a class hierarchy, mixins inject methods directly into the consuming class. The methods are indistinguishable from ones defined locally — `SUPER` calls resolve against the consuming class's own parent chain, and there's no additional method lookup overhead.

### Step 1: Create the Mixin File

Create `hooks/_addon.pm` with method definitions and any imports the mixin needs:

```perl
# CF App Autoscaler Addon Mixin
# This file provides common methods for CF App Autoscaler addon hooks
# Include with: do dirname(__FILE__) . '/_addon.pm';

use Genesis qw/info run bail/;

# Override init to add version check
sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0');
	return $obj;
}

# Common CF login method for all CF App Autoscaler addons
sub cf_login {
	my ($self) = @_;
	my $env = $self->env;

	# Get CF deployment info from exodus
	my $cf_deployment_env = $env->exodus_lookup('cf_deployment_env');
	my $cf_deployment_type = $env->exodus_lookup('cf_deployment_type');
	bail("CF deployment environment not found in exodus data") unless $cf_deployment_env;
	bail("CF deployment type not found in exodus data") unless $cf_deployment_type;

	# Get CF credentials from the CF deployment's exodus data
	my $system_domain = $env->exodus_lookup('system_domain', undef, "${cf_deployment_env}/${cf_deployment_type}");
	my $username = $env->exodus_lookup('admin_username', undef, "${cf_deployment_env}/${cf_deployment_type}");
	my $password = $env->exodus_lookup('admin_password', undef, "${cf_deployment_env}/${cf_deployment_type}");

	bail("CF system domain not found in exodus data") unless $system_domain;
	bail("CF admin username not found in exodus data") unless $username;
	bail("CF admin password not found in exodus data") unless $password;

	my $api_url = "https://api.$system_domain";

	# CF login
	info("Connecting to CF API at %s", $api_url);
	run('cf', 'api', $api_url, '--skip-ssl-validation');
	run('cf', 'auth', $username, $password);

	# Check for cf-targets plugin
	my ($out, $rc) = run('cf plugins | grep -q \'^cf-targets\'');
	if ($rc == 0) {
		run('cf', 'save-target', '-f', $cf_deployment_env);
	} else {
		info("#Y{The cf-targets plugin does not seem to be installed} -- cannot save current target");
	}

	run('cf', 'target');
	return 1;
}

# Common method to get service broker credentials
sub get_service_broker_credentials {
	my ($self) = @_;
	my $env = $self->env;

	my $sb_username = $env->exodus_lookup('service_broker_username');
	my $sb_password = $env->exodus_lookup('service_broker_password');
	my $sb_domain = $env->exodus_lookup('service_broker_domain');

	bail("Service broker username not found in exodus data") unless $sb_username;
	bail("Service broker password not found in exodus data") unless $sb_password;
	bail("Service broker domain not found in exodus data") unless $sb_domain;

	return ($sb_username, $sb_password, "https://$sb_domain");
}

1;
```

Note that the mixin includes its own `use Genesis` import. Mixins should import the modules they need directly rather than relying on the consumer to have already imported them. This makes the mixin self-contained and avoids subtle breakage when consumers change their imports.

### Step 2: Include the Mixin in Each Addon

In each addon file, use this minimal pattern to include the mixin:

```perl
package Genesis::Hook::Addon::CFAppAutoscaler::BindAutoscaler;

use v5.20;
use warnings;

# Only needed for development
BEGIN { push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME} . '/.genesis/lib' }

use parent qw(Genesis::Hook::Addon);
use Genesis qw/info run bail/;

# Include common methods from mixin
BEGIN {
	require File::Basename;
	my $mixin_file = File::Basename::dirname(__FILE__) . '/_addon.pm';
	do $mixin_file or die "Failed to include addon mixin $mixin_file: " . ($@ || $!);
}

sub cmd_details {
	return "Binds the Autoscaler service broker to your deployed CF.";
}

sub perform {
	my ($self) = @_;
	my $env = $self->env;

	# Use mixin methods - they're now part of this class!
	$self->cf_login();
	my ($sb_username, $sb_password, $sb_url) = $self->get_service_broker_credentials();

	# Create and enable service broker
	run('cf', 'create-service-broker', 'autoscaler', $sb_username, $sb_password, $sb_url);
	run('cf', 'enable-service-access', 'autoscaler');

	info("\n#G{[OK]} Successfully created the service broker.");
	return $self->done();
}

1;
```

## How It Works

1. **No package declaration** — methods defined in the mixin file execute in the caller's package, so they become part of that class's symbol table
2. **Compile-time inclusion** — wrapping `do` in a `BEGIN` block runs it during compilation, ensuring methods are available before any runtime code executes
3. **Full method integration** — mixed-in methods are real entries in the class's symbol table, identical to locally-defined methods. `SUPER` calls resolve against the consuming class's own inheritance chain
4. **Single source of truth** — all common logic lives in one place but is available everywhere it's needed

## Inclusion Methods: `do` vs `require`

There are two ways to include a mixin in Perl. They behave differently in important ways:

### `do` — Path-Based Inclusion

```perl
do File::Basename::dirname(__FILE__) . '/_addon.pm';
```

The `do` statement executes a file by literal path. It does not cache the result — every `do` re-executes the file. It also fails silently if the file is missing (returns `undef` and sets `$@` or `$!`), so you should always check for errors:

```perl
do $mixin_file or die "Failed to include $mixin_file: " . ($@ || $!);
```

**Use `do` when** the mixin lives alongside the consuming files (e.g., in a kit's `hooks/` directory) and isn't on Perl's `@INC` path. This is the typical case for kit addon hooks.

### `require` — Module-Based Inclusion

```perl
require Genesis::Env::Secrets::Parser::_legacy_cf_support_mixin;
```

The `require` statement resolves the module name through `@INC` (converting `::` to `/` and appending `.pm`). It caches the result in `%INC` — subsequent `require` calls for the same module are no-ops. It throws a fatal error if the file cannot be found.

**Use `require` when** the mixin lives in `lib/` and follows standard Perl module naming. This is the preferred pattern for Genesis core library modules where the file is on `@INC`.

### Comparison

| | `do` | `require` |
|--|------|-----------|
| Resolution | Literal file path | `@INC` search by module name |
| Caching | None — re-executes every time | Cached in `%INC` — runs once per process |
| Error on missing | Silent (returns `undef`) | Fatal (`Can't locate...`) |
| Multiple consumers | Each `do` re-runs initialization | Safe — second `require` is a no-op |
| Best for | Kit hooks (path-relative) | Library modules (on `@INC`) |

The lack of caching with `do` is harmless when the mixin contains only pure method definitions — re-defining the same subs is idempotent. However, if a mixin has initialization side effects (e.g., setting package variables), `do` could cause unexpected behavior when multiple consumers load the same mixin.

## Benefits Over Other Approaches

### Cleaner Than Inheritance
- No complex package hierarchies
- No `-norequire` parent options
- No symbol table inspection

### More Self-Contained Than the Old Way
- Mixins import their own dependencies
- No fragile coupling to the consumer's `use` statements
- Adding a mixin to a new consumer doesn't require matching imports

### More Maintainable Than Copy-Paste
- Update common logic in one place
- Consistent behavior across all consumers
- Easy to add new common methods

### Direct Method Calls
- Methods are in the class symbol table — no dispatch overhead
- No inheritance chain lookups at call time
- `SUPER` works naturally against the consuming class's parents

## Usage Pattern Summary

For each new addon that needs common functionality:

1. **Create the addon file** with the standard Genesis addon structure
2. **Add the mixin inclusion** with the `BEGIN { do ... }` pattern
3. **Call mixin methods** directly on `$self` as if they were local methods
4. **Focus on addon-specific logic** — let the mixin handle the boilerplate

## File Organization

For kit addon hooks:

```
hooks/
├── _addon.pm                          # Mixin file (starts with _)
├── addon-bind-autoscaler~bind.pm      # Consumes mixin
├── addon-test-bind-autoscaler~test.pm # Consumes mixin
├── addon-update-autoscaler~update.pm  # Consumes mixin
├── addon-setup-cf-plugin.pm           # Consumes mixin
└── addon-config-autoscaler~config.pm  # Consumes mixin
```

For Genesis core library modules:

```
lib/Genesis/Env/Manifest/
├── _entombment_mixin.pm               # Mixin (included via do)
├── _vaultify_mixin.pm                 # Mixin (included via do)
├── Entombed.pm                        # Consumes _entombment_mixin
├── Vaultified.pm                      # Consumes _vaultify_mixin
├── VaultifiedEntombed.pm              # Consumes both mixins
└── VaultifiedRedacted.pm              # Consumes _vaultify_mixin
```

## Best Practices

1. **Start the filename with `_`** — this is the convention that identifies a file as a mixin, not a standalone module
2. **No `package` declaration** — this is what makes it a mixin; methods run in the caller's namespace
3. **Import your own dependencies** — use the modules you need directly; don't rely on the consumer's imports
4. **Include early** — use a `BEGIN` block so methods are available at compile time
5. **Check for errors with `do`** — `do $file or die "...:" . ($@ || $!)` to catch missing files
6. **Prefer `require` for `lib/` modules** — cached, fatal on missing, uses standard `@INC` resolution
7. **Use `do` for kit hooks** — path-relative inclusion for files not on `@INC`
8. **End with `1;`** — required for both `do` and `require` to succeed
9. **Document usage** — the mixin's POD should explain how to include it; consumers should reference the mixin via `L<>` in their POD

## Compatibility with Genesis

This pattern is fully compatible with Genesis's hook loading mechanism:

- Genesis reads the package name from the first line of the addon file
- Genesis calls `require` on the addon file
- The mixin is included during the addon's compilation phase
- Genesis calls `->init()` which can be overridden by the mixin
- Everything works seamlessly

The mixin pattern provides a clean, efficient way to share common functionality across Genesis modules without the complexity of inheritance hierarchies or module loading boilerplate.

## POD Documentation for Mixins

Mixins should have companion `.pod` files just like regular modules. The POD should:

- Identify the module as a mixin in the `NAME` section
- Include a `USAGE` section documenting how to include the mixin via `do` or `require`
- Document all methods the mixin provides
- Consuming classes should reference the mixin via `L<>` in their own POD

See `.claude/agents/pod-author.md` for the full POD authoring workflow and `.claude/skills/pod-validate/` for mechanical validation.