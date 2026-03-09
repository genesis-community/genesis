# Genesis Check Hook Conversion Prompt

Convert this bash check hook to a Genesis Perl check hook following these requirements:

## Package Structure
```perl
package Genesis::Hook::Check::{KitName};
use v5.20;
use warnings;
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}
use parent qw(Genesis::Hook::Check);
use Genesis qw/bail info new_enough/;
```

## Method Pattern
- `init()` - Call `check_minimum_genesis_version()` with required version
- `perform()` - Call individual check methods, accumulate results with `$ok = 0 unless`
- Individual `check_*()` methods that call `start_check()`, perform validations, return single `check_result()`

## Validation Methods
- Cloud config: Use `$self->check_cloud_config_type(type, name)`
- Runtime config: Use `$self->check_runtime_config_addon(name)`
- Exodus lookup: Use `$self->env->top->exodus_for("env/type")` with eval
- Parameter lookup: Use `$self->env->lookup('key') // 'default'`

## State Management
- Each `check_*` method sets internal state via validation calls
- Single `check_result()` call at end of each method (no early returns)
- Skip checks with `check_result('name', 'skipped', 'reason')`

## Coding Standards
- Tab indentation (2 spaces)
- Fold markers: `# method_name - description {{{` ... `# }}}`
- Vim footer: `# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu`
- Use `//` for defaults, avoid intermediate error returns

Convert all bash validation logic while maintaining the same checks and error messages. Replace bash helper functions (`cloud_config_needs`, `rcq`, `lookup`, etc.) with appropriate Genesis Perl methods.

Perform a static analysis of the converted code to ensure it adheres to Genesis coding standards, references real methods, and performs the same checks as the original bash script.
