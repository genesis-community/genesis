# Refactor: Move Kit Decompilation to Genesis::Kit::Compiled

## Status
**Blocked - Needs Design Decision**

Unresolved behavioral differences between `_decompile_kit()` and `extract()` need to be resolved before implementation.

## What
Move the `_decompile_kit` functionality from `Genesis::Commands::Kit` to `Genesis::Kit::Compiled` as a public `decompile()` method, and refactor `extract()` to use it internally.

## Why

### Current Issues
1. **Poor Separation of Concerns**: Kit decompilation logic currently lives in the Commands layer (`Genesis::Commands::Kit::_decompile_kit`) rather than with the kit abstraction itself.

2. **Code Duplication**: The `extract()` method in `Genesis::Kit::Compiled` performs similar tarball extraction operations but with different semantics (temporary workdir with helpers vs permanent directory without).

3. **Limited Reusability**: Tests and other code that need to decompile kits must either:
   - Call a private Commands method (`_decompile_kit`)
   - Manually duplicate tarball extraction logic
   - Use `extract()` which has different semantics (workdir + helpers)

4. **Inconsistent Interface**:
   - `extract()` returns the kit in a workdir with `.helper` file added
   - `_decompile_kit()` extracts to a specified directory without helpers
   - No unified interface for "get kit contents on disk"

### Benefits of Refactoring
1. **Better Encapsulation**: Kit objects should know how to decompile themselves
2. **Improved Testability**: Tests can directly call `$kit->decompile($target_dir)`
3. **Clearer Intent**: Separate methods for different use cases (temporary extraction vs permanent decompilation)
4. **Code Reuse**: Single implementation of tarball extraction logic

## Unresolved Design Questions

### Directory Management Behavior

**Question 1: Should `decompile()` create the target directory if it doesn't exist?**

Current behaviors:
- `_decompile_kit()` (line 1017): Uses `mkdir -p "$2"` which creates directory and all parent directories
- `extract()` (line 85): Uses `workdir()` which creates a temporary directory (assumed empty)

Options:
- A. Create directory if it doesn't exist (matches `_decompile_kit()`)
- B. Require directory to exist (stricter validation)
- C. Create only if parent exists (fail if deep path missing)

**Question 2: Should `decompile()` work with existing directories?**

Current behaviors:
- `_decompile_kit()` (lines 1005-1009): Allows extraction only if:
  - Directory doesn't exist (`! -e $dir`), OR
  - Directory exists AND contains `kit.yml` (`-d $dir && -f "$dir/kit.yml"`)
  - Bails with "Cowardly refusing to continue" otherwise
- `_decompile_kit()` (line 1017): Does `rm -rf "$2"` to completely remove existing directory first
- `extract()`: Assumes fresh empty workdir, no explicit validation

Options:
- A. Allow overwrite only if directory contains `kit.yml` (matches `_decompile_kit()` safety check)
- B. Allow overwrite of empty directories only (stricter)
- C. Allow overwrite of any directory (less safe, simpler)
- D. Never overwrite, require empty/non-existent directory

**Question 3: Should `decompile()` remove existing directory contents before extraction?**

Current behaviors:
- `_decompile_kit()` (line 1017): Yes - `rm -rf "$2" && mkdir -p "$2"` completely removes and recreates
- `extract()`: No explicit removal (but workdir() should be empty)
- Archive::Tar `extract_file()`: Overwrites existing files, doesn't remove unrelated files

Options:
- A. Remove all existing contents first (matches `_decompile_kit()` behavior)
- B. Overwrite files, leave other contents alone (Archive::Tar default)
- C. Fail if directory not empty (safest)

### Proposed Resolution Strategy

1. **Analyze use cases**: Review all callers of `_decompile_kit()` and `extract()` to understand requirements
2. **Safety first**: Default to more restrictive behavior, allow override flags if needed
3. **Consistency**: Both methods should have similar safety characteristics
4. **Documentation**: Clearly document expected behavior and edge cases

## How

### Proposed API Design

**Design Decision**: Move directory validation/creation/removal logic to callers, making `decompile()` a simple extraction method that assumes an existing empty directory.

**Rationale**:
- Separates concerns: directory management (caller) vs extraction (decompile)
- Simpler implementation: `decompile()` doesn't need complex directory handling
- Flexibility: Different callers can have different directory policies
- Consistency: Matches how `extract()` currently works (assumes workdir is empty)

```perl
package Genesis::Kit::Compiled;

# Public method - decompile kit to an existing empty target directory
# Caller is responsible for directory validation/creation/cleanup
sub decompile {
    my ($self, $target_dir) = @_;

    # Target directory is required (no default - no Top context available)
    bug("decompile() requires an explicit target directory") unless $target_dir;

    # Directory must exist
    bug("Target directory $target_dir does not exist") unless -d $target_dir;

    # Can be called as class method with archive path
    if (!ref($self)) {
        my $archive = $self;
        $self = Genesis::Kit::Compiled->new(archive => $archive);
    }

    # Use the validated Archive::Tar object (already validated in new())
    my $basedir = sprintf("%s-%s/", $self->{name}, $self->{version});

    # Remove basedir prefix if it exists (for idempotent calls)
    $self->{tar}->remove($basedir) if grep { /^\Q$basedir\E/ } $self->{tar}->list_files;

    # Set extraction target and extract all files
    $self->{tar}->setcwd($target_dir);
    for my $file (sort $self->{tar}->list_files) {
        $self->{tar}->extract_file($file, "$target_dir/".($file =~ s{^$basedir}{}r));
    }

    return $target_dir;
}

# Refactor extract() to use decompile() internally
sub extract {
    my ($self) = @_;
    return if $self->{root}; # Already extracted

    # Set root to workdir, then decompile to it
    $self->{root} = workdir();
    $self->decompile($self->{root});

    # Add helpers file for Genesis runtime
    Genesis::Helpers->write("$self->{root}/.helper");

    return 1;
}
```

### Usage Examples

```perl
# As instance method
my $kit = Genesis::Kit::Compiled->new(archive => $path);
$kit->decompile('/path/to/target');  # Explicit target
$kit->decompile();                   # Defaults to 'dev'

# As class method (convenience)
Genesis::Kit::Compiled->decompile($archive_path, $target);

# Extract for runtime (temporary workdir with helpers)
my $kit = Genesis::Kit::Compiled->new(archive => $path);
$kit->extract();  # Uses decompile() internally
my $root = $kit->{root};
```

### Migration Steps

1. **Add `decompile()` method** to `Genesis::Kit::Compiled`
   - Support both class and instance method calling conventions
   - Move tarball extraction logic from `_decompile_kit` using Archive::Tar methods
   - Add proper error handling and path validation
   - Require explicit target directory (bug if not provided)

2. **Refactor `extract()` method**
   - Change to use `decompile()` internally
   - Keep workdir + helpers behavior for backward compatibility
   - Maintain existing return values and semantics

3. **Update `Genesis::Commands::Kit::decompile_kit`** (public command at line 288)
   - Move directory validation/creation logic from `_decompile_kit()` to `decompile_kit` command (before calling decompile)
   - Add validation check (lines 1005-1009 from _decompile_kit):
     ```perl
     my $target = $top->path($dir);
     bail(
         "#C{%s} already exists, but does not appear to be a kit directory.\n".
         "Cowardly refusing to continue...",
         humanize_path($target)
     ) unless ! -e $target || (-d $target && -f "$target/kit.yml");
     ```
   - Add directory cleanup and creation (from line 1017 of _decompile_kit):
     ```perl
     run('rm -rf "$1" && mkdir -p "$1"', $target) if -e $target;
     mkdir_or_fail($target) unless -d $target;
     ```
   - Change line 360 from: `_decompile_kit($top,$file,get_options->{directory});`
   - To: `Genesis::Kit::Compiled->decompile($file, $target);`
   - Note: `$dir` already computed/normalized at line 292, use `$top->path($dir)` for absolute path

4. **Update `Genesis::Commands::Kit::fetch_kit`** (public command)
   - Add directory handling before decompile when `--as-dev` is used:
     ```perl
     if (get_options->{'as-dev'}) {
         my $dev_dir = $top->path('dev');
         bail(
             "#C{%s} already exists, but does not appear to be a kit directory.\n".
             "Cowardly refusing to continue...",
             humanize_path($dev_dir)
         ) unless ! -e $dev_dir || (-d $dev_dir && -f "$dev_dir/kit.yml");
         run('rm -rf "$1" && mkdir -p "$1"', $dev_dir) if -e $dev_dir;
         mkdir_or_fail($dev_dir) unless -d $dev_dir;
         Genesis::Kit::Compiled->decompile($target, $dev_dir);
     }
     ```
   - This replaces line 404: `_decompile_kit($top,$target) if (get_options->{'as-dev'});`
   - **Note**: Directory validation logic is duplicated between decompile_kit and fetch_kit commands (see Future Enhancements for DRY refactor)

5. **Remove `Genesis::Commands::Kit::_decompile_kit`** (private method at line 1002)
   - Delete entire _decompile_kit() function (lines 1002-1020)
   - No longer needed with new decompile() method
   - All functionality moved to Genesis::Kit::Compiled

6. **Update tests**
   - Replace all `Genesis::Commands::Kit::_decompile_kit()` calls with `Genesis::Kit::Compiled->decompile()`
   - Update test in `t/integration-tests/genesis_top-complete.t` line ~380
   - Add unit tests for `decompile()` method in `t/unit-tests/kit-compiled.t`
   - Verify `extract()` still works as expected

7. **Documentation**
   - Update POD for `Genesis::Kit::Compiled`
   - Add examples of both `extract()` and `decompile()` usage
   - Document differences between the two methods
   - Note migration of functionality from Commands to Kit abstraction

### Backward Compatibility

- `extract()` behavior unchanged (still creates workdir with helpers)
- Public `decompile_kit` command continues to work with improved implementation
- No breaking changes to public APIs
- Tests updated to use new decompile() method directly

### Testing Strategy

1. **Unit Tests** (`t/unit-tests/kit-compiled.t`):
   - Test `decompile()` with explicit target directory
   - Test `decompile()` with default 'dev' directory
   - Test class method calling convention
   - Verify `extract()` still creates workdir and helpers

2. **Integration Tests** (`t/integration-tests/genesis_top-complete.t`):
   - Update existing dev kit tests to use `$kit->decompile()`
   - Verify both symlink and literal dev directories work
   - Confirm kit version detection works correctly

3. **Regression Tests**:
   - Verify all existing kit compilation/decompilation workflows
   - Test `genesis compile-kit` and `genesis decompile-kit` commands
   - Ensure dev kit loading works in all scenarios

## Related Issues

- Addresses test complexity discovered in `t/integration-tests/genesis_top-complete.t`
- Improves separation between Commands and Kit abstractions
- Lays groundwork for future multi-dev-kit support (versioned dev directories)

## Future Enhancements

Once this refactoring is complete, it enables:

1. **Directory Validation Method** (DRY Refactor): Extract duplicated directory validation logic from `decompile_kit` and `fetch_kit` commands into `Genesis::Top->prepare_kit_directory($target, %options)` method
   - Centralizes validation: directory existence, kit.yml check, cleanup, creation
   - Options could include: force (override non-kit directories), preserve (skip cleanup), create_parents (mkdir -p)
   - Returns absolute path to validated directory ready for decompilation
   - Example: `my $dir = $top->prepare_kit_directory($target, force => get_options->{force});`

2. **Multiple named/versioned Dev Kits**: Support `dev/`, `bosh/1.0.0/`, `bosh/4.0.5/` for parallel development

3. **Kit Compilation Pipeline**: Better composition of compile → test → decompile workflows

4. **Kit Diffing**: Easy comparison between compiled kit versions

5. **Kit Migration Tools**: Scripts to upgrade kits between Genesis versions

## Implementation Checklist

- [ ] Add `decompile()` method to `Genesis::Kit::Compiled`
- [ ] Refactor `extract()` to use `decompile()` internally
- [ ] Update `_decompile_kit()` to wrap `decompile()`
- [ ] Update `decompile_kit` command
- [ ] Add unit tests for `decompile()`
- [ ] Update integration tests
- [ ] Add POD documentation
- [ ] Verify backward compatibility
- [ ] Run full test suite
- [ ] Update CHANGELOG

## References

- Current implementation: `lib/Genesis/Commands/Kit.pm:1002` (`_decompile_kit`)
- Current extract: `lib/Genesis/Kit/Compiled.pm:82` (`extract`)
- Related test: `t/integration-tests/genesis_top-complete.t:378` (dev kit test)
