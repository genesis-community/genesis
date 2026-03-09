# Genesis::Config Refactoring Plan

**Status**: Phase 1 COMPLETE ✅ (Phase 2 Planned)
**Priority**: High
**Complexity**: Medium-High
**Estimated Effort**: ~~2-3 days~~ (Phase 1: 1 day actual)

## Executive Summary

Genesis::Config requires two major refactorings:

1. **Source Tracking**: Separate storage from computation to prevent defaults/env vars from being saved to disk
2. **Schema Integration**: Move from manual validation to automatic validation with schema attachment at construction

These refactorings will improve correctness (save only explicit values), developer experience (automatic validation), and maintainability (clearer separation of concerns).

---

## Problem Statement

### Current Issues

#### 1. Defaults Written to Disk
**Problem**: When `validate()` is called with a schema containing defaults, those defaults are added to `_contents` via `set()` and subsequently saved to disk.

**Impact**:
- Config files bloat with default values
- Difficult to distinguish user-set values from defaults
- Schema changes require manual config file updates
- Source of truth becomes ambiguous (schema vs file)

**Example**:
```perl
my $config = Genesis::Config->new($path);
$config->validate($schema);  # Adds defaults to _contents
$config->save();             # Writes defaults to file (WRONG!)
```

#### 2. Passive Validation
**Problem**: Validation is manual - caller must remember to call `validate($schema)` explicitly.

**Impact**:
- Easy to forget validation
- Schema passed every time, not associated with config
- No validation on load or save
- Invalid configs can be created and persisted

**Example**:
```perl
my $config = Genesis::Config->new($path);
$config->set('invalid_key', 'value');  # No validation
$config->save();  # Persists invalid config (WRONG!)
```

---

## Proposed Solution

### Part 1: Source Tracking Refactoring

#### Internal Structure Change
```perl
# Current: Simple hash
$self->{contents} = {
    foo => 'bar',
    with_default => 'default_value',  # Can't tell if set or default
};

# Proposed: Source-tracked hash
$self->{contents} = {
    foo => {
        value => 'bar',
        source => 'loaded',  # loaded | set | env | default
    },
    with_default => {
        value => 'default_value',
        source => 'default',
    },
};
```

#### New Methods

**`get_source($key)` - Returns value source**
```perl
$config->get_source('foo');  # 'loaded', 'set', 'env', or 'default'
```

**`get_all()` - Returns all effective values**
```perl
# Includes all sources (loaded + set + env + defaults)
my $all = $config->get_all();
```

**`is_set($key)` - Checks if explicitly loaded or set**
```perl
$config->is_set('foo');              # true  (loaded from file)
$config->is_set('with_default');     # false (only default)
$config->is_set('env_override');     # false (env var)
```

**`_explicit_contents()` - Private method for save()**
```perl
# Returns only loaded + set sources (what should be saved)
my $to_save = $config->_explicit_contents();
```

#### Priority Resolution
Priority order in `get()`: **env > set > loaded > default**

#### Modified Methods

**`validate($schema)` - No longer modifies _contents**
```perl
# Current: Calls $self->set() for defaults
# Proposed: Only validates, doesn't modify contents
```

**`get($key)` - Computes defaults on-demand**
```perl
# Check priority: env → set → loaded → default
# Return value without modifying _contents
```

**`save()` - Only writes explicit values**
```perl
# Use _explicit_contents() to get only loaded/set values
# Never writes defaults or env overrides
```

#### Test Coverage
Comprehensive TDD tests already written in `t/unit-tests/genesis_config-core.t`:
- 21 subtests covering all functionality
- New methods wrapped in SKIP blocks for incremental implementation
- Tests for save behavior (ensures defaults not written)
- Tests for priority resolution
- Tests for source tracking

---

### Part 2: Schema Integration Refactoring

#### Constructor Enhancement

**Hybrid Constructor** - Supports both old positional and new named params:

```perl
# Old style (backward compatible)
Genesis::Config->new($path);
Genesis::Config->new($path, $autosave);
Genesis::Config->new($path, $autosave, $content);

# New style (named parameters)
Genesis::Config->new(
    path => $path,
    schema => $schema,          # NEW: attach schema
    autosave => 1,
    content => {},
    validate_on_load => 1,      # NEW: auto-validate on load
    validate_on_save => 1,      # NEW: auto-validate on save
    validate_on_set => 0,       # NEW: validate individual sets (opt-in)
);
```

#### When to Validate

**Always Validate (if schema provided):**
1. **On Load** - When `_contents` first accessed/loaded from file
2. **Before Save** - Catch invalid state before persisting

**Optional Validate:**
3. **On Set** - Can be enabled, but may be too aggressive for partial configs

#### Implementation Pattern

```perl
sub new {
    my $class = shift;
    my ($path, %opts);

    # Detect old vs new style
    if (@_ == 0) {
        $path = undef;
    } elsif (@_ == 1 && !ref($_[0])) {
        $path = $_[0];
    } elsif (@_ >= 2 && $_[0] !~ /^(path|schema|content|autosave|validate_on_\w+)$/) {
        # Old style positional
        ($path, $opts{autosave}, $opts{content}) = @_;
    } else {
        # New style named params
        %opts = @_;
        $path = delete $opts{path};
    }

    return bless({
        path => $path,
        schema => $opts{schema},
        validate_on_load => $opts{validate_on_load} // 1,
        validate_on_save => $opts{validate_on_save} // 1,
        validate_on_set => $opts{validate_on_set} // 0,
        # ... existing fields
    }, $class);
}

sub _contents {
    my $self = shift;
    unless ($self->{contents_loaded}) {
        # Load from file...
        $self->{contents_loaded} = 1;
        $self->_validate if $self->{schema} && $self->{validate_on_load};
    }
    return $self->{contents};
}

sub save {
    my $self = shift;
    $self->_validate if $self->{schema} && $self->{validate_on_save};
    # Use _explicit_contents() to only save loaded/set values
    # ... existing save logic
}

sub _validate {
    my $self = shift;
    return unless $self->{schema};
    # Call existing validate() logic but don't modify _contents
}
```

---

## Current Usage Audit

### Production Code (4 occurrences)
All use simple path-only style - **no breaking changes needed**:

1. `lib/Genesis/Config.pm:468` - `Genesis::Config->new($self->{path})`
2. `lib/Genesis/Top.pm:896` - `Genesis::Config->new($self->path(".genesis/config"))`
3. `lib/Genesis/Top.pm:1149` - `Genesis::Config->new()`
4. `lib/Genesis/Helpers.pm:25` - `Genesis::Config->new($ENV{HOME}."/.genesis/config")`

### Test Code (47+ occurrences)
Mix of styles - **tests can be freely updated**:

- **Path only**: ~37 occurrences
- **Path + autosave**: 1 occurrence (`t/e2e-tests/init.t:24`)
- **Path + autosave + content**: 5 occurrences (`t/unit-tests/genesis-core.t`)

---

## Implementation Plan

### Phase 1: Source Tracking (Core Refactoring) ✅ COMPLETE

**Goal**: Fix save() behavior - don't write defaults/env vars

**Steps**:
1. ✅ Create comprehensive TDD tests (DONE - 23 subtests in genesis_config-core.t)
2. ✅ Change internal structure to use four source tracking structures (loaded_values, set_values, env_values, default_values)
3. ✅ Implement `get_source()` method
4. ✅ Implement `get_all()` method with deep copy protection
5. ✅ Implement `is_set()` method
6. ✅ Implement `_explicit_contents()` private method
7. ✅ Modify `validate()` to populate env_values/default_values structures (not set())
8. ✅ Modify `_contents()` to compute with priority resolution (env > set > loaded > default)
9. ✅ Modify `save()` to use `_explicit_contents()`
10. ✅ Fix `clear()` to work with source tracking
11. ✅ Fix `_signature()` to avoid deep recursion and use explicit contents
12. ✅ Run tests incrementally with TDD red-green-refactor cycle

**Success Criteria**: ✅ ALL MET
- ✅ All 23/23 subtests in genesis_config-core.t passing (100%)
- ✅ `save()` only writes loaded/set values (defaults/env excluded)
- ✅ Defaults accessible via `get()` but not saved to disk
- ✅ Source tracking works for all value types
- ✅ Priority resolution correct (env > set > loaded > default)
- ✅ No regressions in existing functionality
- ✅ External mutation protection via deep copy in get_all()
- ✅ Cache invalidation working correctly

**Actual Effort**: 1 day (2025-11-06)

**Implementation Notes**:
- Used four separate hash structures instead of embedded source tracking for cleaner separation
- Discovered and fixed deep recursion bug in _signature() method
- _contents() and _explicit_contents() both use caching with proper invalidation
- Constructor initializes all four source structures (no `// {}` defaults needed)

**Bug Fixes During Implementation**:
- **Validation normalization bug** (2025-11-06): Fixed _validate_key() calling set() for normalization (hasharray, boolean conversions), which incorrectly marked values as 'set' source instead of preserving original source. Added _update_source(source, key, value) method to update values in their specific source structure. Reproduced with user's deployment_roots config containing hasharray format. Refactored set() to use _update_source() for consistency.
  - Commits: f88517d (fix), 7823a22 (refactor)
  - Test: [t/unit-tests/genesis_config-core.t:594](t/unit-tests/genesis_config-core.t#L594) "validation preserves source tracking"

### Phase 2: Schema Integration
**Goal**: Automatic validation with schema attachment

**Steps**:
1. Implement hybrid constructor (old + new styles)
2. Add schema storage in blessed object
3. Add validation flags (validate_on_load, validate_on_save, validate_on_set)
4. Implement auto-validation in `_contents()` (on load)
5. Implement auto-validation in `save()` (before save)
6. Update Genesis::Top to pass schema at construction
7. Keep manual `validate()` for backward compatibility

**Success Criteria**:
- Hybrid constructor tests pass (already written, currently skipped)
- Old-style calls continue working (backward compatibility)
- New-style calls work with schema parameter
- Auto-validation prevents invalid configs
- Genesis::Top uses new schema parameter

**Estimated Effort**: 1 day

### Phase 3: Flattened Internal Storage (Performance Optimization)
**Goal**: Optimize read performance by storing values in flattened form internally

**Rationale**:
The primary use case for Genesis::Config is **reading** values, not deep structure manipulation.
Currently every `get()` call requires `struct_lookup()` to traverse nested structures, and
`is_set()`/`get_source()` require `struct_has()` traversal. Since we already have `flatten()`
and `unflatten()` utilities, we can optimize for the common case (reading) at the cost of
slightly more work during rare operations (loading/saving).

**Current Architecture** (Deep Structures):
```perl
# Four deep source structures
$self->{loaded_values} = { nested => { key => 'value' } };
$self->{set_values} = { another => { deep => { key => 'val' } } };

# Every read requires traversal
$val = struct_lookup($self->{loaded_values}, 'nested.key');  # O(depth)
$exists = struct_has($self->{set_values}, 'another.deep.key');  # O(depth)
```

**Proposed Architecture** (Flattened):
```perl
# Four flattened source structures
$self->{loaded_values} = { 'nested.key' => 'value' };
$self->{set_values} = { 'another.deep.key' => 'val' };

# Direct hash access
$val = $self->{loaded_values}{'nested.key'};  # O(1)
$exists = exists $self->{set_values}{'another.deep.key'};  # O(1)
```

**Performance Impact**:
- **get()**: O(depth) → O(1) - Direct hash lookup instead of traversal
- **get_source()**: O(depth * 4) → O(4) - Four hash lookups instead of four traversals
- **is_set()**: O(depth * 2) → O(2) - Two hash lookups instead of two traversals
- **has()**: O(depth) → O(1) - Direct hash lookup
- **Caching**: Can potentially eliminate path-based cache since lookups are already fast

**Implementation Changes**:

**Loading** (convert to flattened on load):
```perl
sub _load {
    my ($self, $path) = @_;
    # ... existing load logic ...

    # Flatten on load (one-time cost)
    $self->{loaded_values} = flatten(load_yaml_file($path));
}
```

**Saving** (unflatten before save):
```perl
sub save {
    my ($self) = @_;
    # Unflatten explicit contents before save
    my $explicit = unflatten($self->_explicit_contents);
    # ... save deep structure as YAML ...
}
```

**Validation** (flatten defaults/env):
```perl
sub validate {
    my ($self, $schema) = @_;
    for my $key (keys %$schema) {
        if (env var) {
            # Direct hash assignment (flattened key)
            $self->{env_values}{$key} = $ENV{...};
        }
        if (default) {
            $self->{default_values}{$key} = $schema->{$key}{default};
        }
    }
}
```

**get_all()** (unflatten and merge):
```perl
sub get_all {
    my ($self) = @_;
    # Unflatten each source, then merge
    return deep_merge(
        unflatten($self->{default_values}),
        unflatten($self->{loaded_values}),
        unflatten($self->{set_values}),
        unflatten($self->{env_values})
    );
}
```

**Modified Methods**:
- `get()`: Remove struct_lookup, use direct hash access
- `set()`: Use direct hash assignment instead of struct_set_value
- `clear()`: Use direct hash delete instead of struct_set_value(..., undef, 1)
- `has()`: Use exists() instead of struct_lookup
- `get_source()`: Use exists() instead of struct_has
- `is_set()`: Use exists() instead of struct_has
- `_contents()`: Unflatten each source before deep_merge
- `_explicit_contents()`: Unflatten before merge

**Trade-offs**:
- ✅ **Reads** (common): O(depth) → O(1) - **Much faster**
- ✅ **Simpler code**: exists() and hash access vs struct_lookup/struct_has
- ✅ **Less caching needed**: Direct access is already fast
- ❌ **Load** (rare): Small overhead to flatten on load
- ❌ **Save** (rare): Small overhead to unflatten before save
- ❌ **get_all()** (rare): Must unflatten all four sources

**Success Criteria**:
- All 23/23 tests still passing
- No behavior changes (refactor only)
- Measurable performance improvement on read-heavy workloads
- Simpler code without struct_lookup/struct_has/struct_set_value calls

**Estimated Effort**: 0.5-1 day

**Dependencies**: Phase 1 must be complete (source tracking architecture in place)

### Phase 4: Test Migration (Optional, Can Be Done Incrementally)
**Goal**: Modernize test code to use new named-params style

**Steps**:
1. Update `t/e2e-tests/init.t` (1 occurrence)
2. Update `t/unit-tests/genesis-core.t` (5 occurrences)
3. Update other test files as encountered (~37 occurrences)

**Success Criteria**:
- All test files use new named-params style
- Tests remain passing throughout migration
- Better test readability and maintainability

**Estimated Effort**: 0.5 days (spread over time)

---

## Backward Compatibility

### Guaranteed Compatibility
- ✅ All existing positional parameter calls work unchanged
- ✅ `validate($schema)` manual calls continue working
- ✅ Existing production code requires zero changes
- ✅ Old test code works without modification

### Migration Path
- New schema parameter is **opt-in**
- Auto-validation only happens if schema provided
- Named parameters are **optional**, not required
- Gradual migration supported - mix old and new styles

---

## Risk Assessment

### Low Risk
- ✅ Comprehensive TDD test coverage already in place
- ✅ Backward compatibility maintained via hybrid constructor
- ✅ Production code uses simplest patterns (path-only)
- ✅ Can be implemented incrementally (source tracking → schema → tests)

### Medium Risk
- Internal structure change (`_contents` format) affects all get/set operations
- Must ensure cache invalidation works correctly with new structure
- Need to verify all code paths handle source-tracked values

### Mitigation
- Run full test suite after each phase
- Keep manual `validate()` method as fallback
- Extensive testing of edge cases (nested keys, arrays, etc.)
- Can roll back changes per-phase if issues detected

---

## Testing Strategy

### Unit Tests (Already Written)
`t/unit-tests/genesis_config-core.t` - 21 comprehensive subtests:

1. ✅ Constructor backward compatibility (old-style positional params)
2. ⏸️ Constructor new named parameters (SKIPPED until Phase 2)
3. Basic config creation and loading
4. Setting values explicitly
5. Environment variable overrides
6. Schema defaults
7. Priority resolution: env > set > loaded > default
8. Save behavior - only explicit values (core refactoring goal)
9. Modifying loaded values
10. Contents methods (`get_all()`, `_explicit_contents()`)
11. `has()` and `is_set()` methods
12. Validation does not modify explicit contents
13-21. Existing method coverage (path, exists, loaded, changed, clear, replace, show_diff, get, set)

### Integration Tests
- Genesis::Top config loading/validation
- Full deployment repo config lifecycle
- Kit compilation config handling

### Manual Testing
- Create repo, modify .genesis/config, verify only explicit values saved
- Test env var overrides don't persist to file
- Verify schema defaults available but not saved

---

## Code Changes Summary

### Files to Modify

**Primary Changes**:
1. `lib/Genesis/Config.pm` (~200 lines changed)
   - Constructor: +35 lines (hybrid detection logic)
   - Internal structure: modify `_contents` to track sources
   - New methods: `get_source()`, `get_all()`, `is_set()`, `_explicit_contents()`
   - Modified methods: `validate()`, `get()`, `save()`

**Secondary Changes**:
2. `lib/Genesis/Top.pm` (2 lines changed)
   - Line 896: Add schema parameter to Config construction
   - Line 1149: Optionally add schema to new config

**Test Changes**:
3. `t/unit-tests/genesis_config-core.t` (already updated)
   - Enable skipped constructor tests when Phase 2 complete

**Optional Changes** (Phase 3):
4. Various test files - migrate to named-params style

---

## Success Metrics

### Functional
- ✅ Config files no longer contain default values
- ✅ Environment variable overrides don't persist to disk
- ✅ Schema defaults always available via `get()`
- ✅ Invalid configs rejected before save
- ✅ All existing functionality preserved

### Code Quality
- ✅ 100% of genesis_config-core.t tests passing
- ✅ No regressions in existing tests
- ✅ Clear separation: storage vs computation
- ✅ Backward compatible API

### Developer Experience
- ✅ Automatic validation prevents invalid configs
- ✅ Schema attached at construction (no manual validate calls needed)
- ✅ Clear API for checking value sources
- ✅ Easier to understand what gets saved vs computed

---

## References

- **Test File**: `t/unit-tests/genesis_config-core.t`
- **Implementation**: `lib/Genesis/Config.pm`
- **Usage**: `lib/Genesis/Top.pm`, `lib/Genesis/Helpers.pm`
- **Related**: Genesis::Top refactoring (config validation on load)

---

## Notes

- Tests are already written and properly structured for red-green-refactor TDD
- Constructor tests exist but are skipped pending Phase 2 implementation
- All production code uses simple patterns - minimal impact
- Can implement Phase 1 (source tracking) independently of Phase 2 (schema integration)
- Phase 3 (test migration) is optional and can be done over time

---

**Last Updated**: 2025-11-06 (Phase 1 Complete)
**Author**: Claude Code Session
**Phase 1 Status**: ✅ COMPLETE - All 23/23 tests passing
**Phase 2 Status**: Planned
**Phase 3 Status**: Proposed (Performance Optimization)
