# Genesis Pipeline Refactor - Branch-Based System

**Jira Epic:** [FWT-549](https://fivetwenty.atlassian.net/browse/FWT-549)
**Branch:** `genesis-pipeline-refactor` (based on `v3.0.x-dev`)
**Worktree:** `worktrees/clis/genesis/genesis-pipeline-refactor`

## Overview

Replace the cache-based pipeline system with a branch-based system where:
- All changes originate on a `live` branch
- Each deployment environment has its own branch
- Changes propagate from `live` to environment branches via PR or direct push (configurable)
- Existing layout/progression semantics are preserved

## Problems Being Solved

1. **CLI vs Pipeline behavior mismatch** - Pipeline used cached values; CLI deployed repo state
2. **Complex cache system** - Hard to understand, debug, and recover from failures
3. **Feature gaps** - ops/, bin/ propagation poorly supported
4. **Recovery difficulty** - Failed deployments hard to fix without manual cache manipulation

## New Architecture

### Branch Structure
```
live                           # All changes originate here
├── lm-aws-useast2-hs-lab      # Lab environment branch (full repo)
├── lm-aws-useast1-hs-nonprod  # Nonprod branch (full repo)
├── lm-aws-useast1-hs-prod     # Prod branch (full repo)
└── ...
```

### Change Flow
```
live ──[detect changes]──> pipeline ──[PR or push]──> env-branch ──[trigger]──> deploy
                                      (configurable)              (auto or manual)
```

### File Classification (convention-over-config)
- **Shared files**: Match multiple environments via naming hierarchy (e.g., `lm.yml`, `lm-aws.yml`)
- **Environment-specific**: Match single environment (e.g., `lm-aws-useast1-hs-prod.yml`)
- **ops/, bin/**: Configurable propagation rules

## MVP Scope

1. Branch creation from `live`
2. Change detection and propagation (`live` → env branches)
3. Configurable PR vs direct push
4. Concourse pipeline YAML generation
5. Preserve layout/auto trigger semantics

**Deferred:**
- Sync-back mechanism (env branch → live)
- Conflict resolution strategies
- Migration markers / unskippable commits
- GitHub Actions backend

## Code Structure

```
lib/Genesis/CI.pm                      # Main entry point, orchestration
lib/Genesis/CI/Backend.pm              # Abstract backend interface
lib/Genesis/CI/Backend/Concourse.pm    # Concourse-specific implementation
lib/Genesis/CI/Layout.pm               # Layout parsing (progression chains, auto triggers)
lib/Genesis/CI/Propagation.pm          # Change detection, file classification, propagation logic
lib/Genesis/Commands/Pipelines.pm      # Updated commands (repipe, etc.)
```

### Module Responsibilities

**Genesis::CI**
- Load and validate ci.yml
- Coordinate layout parsing and backend selection
- Entry point for `genesis repipe`

**Genesis::CI::Backend**
- Abstract interface: `generate_pipeline()`, `validate_config()`
- Defines required methods for backends

**Genesis::CI::Backend::Concourse**
- Generate Concourse pipeline YAML
- Create resources, jobs, triggers
- Handle Concourse-specific config (locker, notifications, etc.)

**Genesis::CI::Layout**
- Parse layout definitions (`env1 -> env2 -> env3`)
- Parse auto-trigger patterns (`auto *-lab`)
- Build progression graph
- Extracted from Legacy.pm layout parsing logic

**Genesis::CI::Propagation**
- Determine which files propagate to which branches
- Use `relate()` logic for naming-convention detection
- Support explicit overrides in ci.yml
- Handle ops/, bin/ propagation rules

## ci.yml Changes

### New Keys (additive)
```yaml
pipeline:
  mode: branch                    # New: 'branch' or 'legacy' (default: legacy for compat)

  branches:
    live: live                    # Branch where changes originate (default: live, can be main)
    propagation: pr               # 'pr' or 'push' (default: push)
    # Per-environment overrides possible:
    # lm-aws-useast1-hs-prod:
    #   propagation: pr           # Require PR for prod

  propagation:
    shared:                       # Files that propagate to all downstream
      - "*.yml"                   # Default: all yml files via naming convention
      - "ops/**"                  # ops directory
      - "bin/**"                  # bin directory
    exclude:                      # Never propagate
      - ".genesis/**"
      - "ci.yml"
```

### Preserved Keys
- `layouts:` - progression chains unchanged
- `auto` within layouts - trigger rules unchanged
- `boshes:`, `vault:`, `git:`, `slack:`, `email:`, `locker:` - unchanged

## Implementation Phases

### Phase 1: Foundation (Parallel Support)
1. Create `Genesis::CI::Layout` - extract layout parsing from Legacy.pm
2. Create `Genesis::CI::Backend` abstract class
3. Create `Genesis::CI::Backend::Concourse` skeleton
4. Create `Genesis::CI` orchestrator with mode detection (branch vs legacy)
5. **Keep Legacy.pm working** - `genesis repipe` uses Legacy.pm when `mode: branch` not set
6. Add `mode: branch` config key to switch to new implementation

### Phase 2: Branch Propagation
1. Create `Genesis::CI::Propagation` module
2. Implement file classification logic (shared vs specific)
3. Implement change detection between branches
4. Generate propagation jobs in Concourse pipeline

### Phase 3: Pipeline Generation
1. Implement full Concourse pipeline generation in Backend::Concourse
2. Generate branch-watching resources
3. Generate propagation jobs (PR creation or direct push)
4. Generate deployment jobs triggered by branch changes
5. Handle auto vs manual triggers per layout

### Phase 4: Integration
1. Update `genesis repipe` command
2. Add `genesis pipeline init` to create initial branch structure
3. Add validation and error handling
4. Documentation

## Key Files to Modify

- `lib/Genesis/Commands/Pipelines.pm` - Update repipe command
- `lib/Genesis/CI/Legacy.pm` - Reference for extraction, eventually remove
- `lib/Genesis/Env.pm` - `relate()` and `relate_by_name()` for file classification

## New Files to Create

- `lib/Genesis/CI.pm`
- `lib/Genesis/CI/Backend.pm`
- `lib/Genesis/CI/Backend/Concourse.pm`
- `lib/Genesis/CI/Layout.pm`
- `lib/Genesis/CI/Propagation.pm`
- `t/genesis-ci.t` (or similar test files)

## Verification

### Unit Tests
- Layout parsing with various progression chains
- File classification (shared vs specific)
- Propagation logic

### Integration Tests
- Generate Concourse pipeline YAML
- Verify resources and jobs are correct
- Verify trigger relationships match layout

### Manual Testing
1. Run `genesis repipe` on test repo with branch mode
2. Verify generated pipeline in Concourse
3. Make change on `live`, verify propagation to lab branch
4. Verify deployment triggers correctly

## Open Questions (Deferred)

1. **State tracking**: How to track which live commit is propagated to each branch?
2. **Sync-back**: How to handle manual fixes on env branches syncing to live?
3. **Conflicts**: Strategy when live and env branch have conflicting changes?
4. **Trigger delay**: Batch multiple PRs before triggering deploy?
5. **Migration markers**: Tag commits as unskippable?

## Risk Considerations

- **GitHub Actions compatibility**: Design abstractions to not be Concourse-specific
- **Large repos**: Full repo per branch means more git operations
- **Merge conflicts**: Full repo branches will have more potential for conflicts