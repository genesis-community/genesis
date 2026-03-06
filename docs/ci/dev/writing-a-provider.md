# Writing a Provider

A provider translates the generic pipeline from the AST into
platform-specific CI/CD configuration. This document explains how to create
a new provider by walking through the abstract interface, the available
helpers, and the patterns used by the existing Concourse and GitHub Actions
providers.

## Provider Base Class

All providers inherit from `Genesis::CI::Compiler::PipelineProvider`, which
defines the abstract interface and provides shared helper methods. A
provider must also inherit from `Genesis::CI` to participate in the factory
system.

```perl
package Genesis::CI::MyPlatform;
use parent 'Genesis::CI', 'Genesis::CI::Compiler::PipelineProvider';

use Genesis;
```

The dual inheritance gives you two interfaces. The `PipelineProvider` parent
provides the compiler pipeline interface (what the compiler calls). The
`Genesis::CI` parent provides the trait interface (what factory-constructed
instances expose). You need both because the factory system and the
compiler pipeline are separate entry points.

## Required Methods

You must implement three methods from PipelineProvider:

### platform_name

Returns a human-readable name for your platform. This appears in log
messages and error output.

```perl
sub platform_name { return "My Platform" }
```

### generate_from_ast

This is the main compilation method. It receives a fully-populated AST
(with both source representation and generic pipeline resolved) and must
return either a YAML string or a hashref mapping filenames to content
strings.

```perl
sub generate_from_ast {
    my ($self, $ast) = @_;

    # Read the generic pipeline
    my $resource_types = $ast->resource_types;   # arrayref
    my $resources      = $ast->pipeline_resources; # arrayref
    my $jobs           = $ast->jobs;             # arrayref
    my $groups         = $ast->groups;           # arrayref

    # Serialize to your platform's format
    my $yaml = $self->dump_yaml({
        resource_types => $resource_types,
        resources      => $resources,
        jobs           => $jobs,
        groups         => $groups,
    });

    return "---\n$yaml\n";
}
```

If your platform produces multiple files (like GitHub Actions, which
creates one workflow file per pipeline), return a hashref:

```perl
return {
    'deploy.yml'    => $deploy_yaml,
    'notify.yml'    => $notify_yaml,
};
```

### output_files

Returns a hashref describing what files your provider generates. The keys
are filenames and the values are human-readable descriptions.

```perl
sub output_files {
    return { 'pipeline.yml' => 'My Platform pipeline definition' };
}
```

## Required Trait Methods

You must also implement these methods from the `Genesis::CI` trait interface
for the factory path:

### init

Class method that creates a new instance from user-provided options. Called
by `Genesis::CI->new(type => 'my-platform', ...)`.

```perl
sub init {
    my ($class, %opts) = @_;
    return bless({
        file   => $opts{file},
        top    => $opts{top},
        config => undef,
    }, $class);
}
```

### parse, generate, deploy

Instance methods for the trait interface pipeline. `parse()` loads and
validates configuration. `generate()` produces output. `deploy()` pushes
the output to the CI platform.

```perl
sub parse {
    my ($self) = @_;
    # Load config, build AST
    return $self;
}

sub generate {
    my ($self) = @_;
    # Return platform-specific YAML
}

sub deploy {
    my ($self, %opts) = @_;
    # Upload to CI platform or write files
}
```

### file_extension

Returns the file extension for generated configuration.

```perl
sub file_extension { return ".yml" }
```

## Constructor for Compiler Path

The compiler pipeline constructs providers differently than the factory.
It passes an AST object directly. Your `new()` should handle this:

```perl
sub new {
    my ($class, %opts) = @_;

    if ($opts{ast}) {
        return bless({
            ast => $opts{ast},
            top => $opts{top},
        }, $class);
    }

    bug("Use Genesis::CI->new(...) for trait construction, ".
        "or pass ast => \$ast for compiler construction");
}
```

## Registering Your Provider

Providers are registered in two places. First, in `Genesis::CI` at
`_resolve_provider_class()`:

```perl
my %providers = (
    'concourse'      => { class => 'Genesis::CI::Concourse',      file => 'Genesis/CI/Compiler/Providers/Concourse.pm' },
    'github-actions' => { class => 'Genesis::CI::GithubActions',   file => 'Genesis/CI/Compiler/Providers/GithubActions.pm' },
    'my-platform'    => { class => 'Genesis::CI::MyPlatform',      file => 'Genesis/CI/Compiler/Providers/MyPlatform.pm' },
);
```

Second, in `Genesis::CI::Compiler` at `_resolve_provider_class()` (which
has its own identical copy of this map):

```perl
my %providers = (
    'concourse'      => { class => 'Genesis::CI::Concourse',      file => 'Genesis/CI/Compiler/Providers/Concourse.pm' },
    'github-actions' => { class => 'Genesis::CI::GithubActions',   file => 'Genesis/CI/Compiler/Providers/GithubActions.pm' },
    'my-platform'    => { class => 'Genesis::CI::MyPlatform',      file => 'Genesis/CI/Compiler/Providers/MyPlatform.pm' },
);
```
Here GitHub Actions is provided as a secondary example


Note that the class name uses a short form (e.g., `Genesis::CI::Concourse`)
while the file path uses the providers subdirectory
(`Genesis/CI/Compiler/Providers/Concourse.pm`). The file is loaded with
`eval { require $file }` at runtime.

## Available Helpers

The `PipelineProvider` base class provides several helpers you can use:

### dump_yaml

Serializes a Perl data structure to YAML without requiring an external YAML
module. Handles hashes, arrays, scalars, booleans (`JSON::PP::Boolean`),
multi-line strings (using `|` block scalar), and proper quoting of strings
that could be confused with YAML keywords.

```perl
my $yaml = $self->dump_yaml($data_structure);
```

Be aware that this serializer sorts hash keys alphabetically, uses
two-space indentation, and does not produce flow-style collections. If you
need a more capable serializer, the GitHub Actions provider uses `YAML::PP`
directly, but this introduces an external dependency.

### git_uri

Builds a Git URI from the source control configuration. Handles GitHub
(`git@github.com:org/repo.git`), GitLab
(`git@gitlab.com:org/repo.git`), explicit `uri` fields, and bare
repository strings.

```perl
my $uri = $self->git_uri($ast->integrations->{source_control});
```

### secret_ref

Formats a secret reference for your platform. The default implementation
returns Concourse-style `(($ref))` interpolation. Override this if your
platform uses a different syntax.

```perl
sub secret_ref {
    my ($self, $ref) = @_;
    # GitHub Actions style
    return '${{ secrets.' . uc($ref) . ' }}';
}
```

### topological_sort

Performs a topological sort on a workflow graph. Takes a graph hashref with
`nodes` and `edges` keys and returns an ordered list of node names. Bails
on cycles.

```perl
my @order = $self->topological_sort($workflow->{graph});
```

### matches_pattern

Checks if a name matches a glob pattern (`*` matches any sequence, `?`
matches one character).

```perl
if ($self->matches_pattern('us-sandbox', '*-sandbox')) { ... }
```

## Accessing Source Data

While providers should primarily read the generic pipeline (via
`$ast->resource_types`, `$ast->pipeline_resources`, `$ast->jobs`,
`$ast->groups`), there are cases where you need source data. For example,
the GitHub Actions provider reads `$ast->integrations` to set up vault
authentication steps and `$ast->metadata` to name the workflow.

The source accessors are: `$ast->branches`, `$ast->integrations`,
`$ast->targets`, `$ast->workflows`, `$ast->configuration`,
`$ast->provider_config`.

## Example: The Concourse Provider

The Concourse provider in `_generate_native()` is a minimal serializer:

```perl
sub _generate_native {
    my ($self, $ast) = @_;
    $self->_ensure_pipeline_resolved();
    my $pipeline = {
        groups         => $ast->groups,
        resources      => $ast->pipeline_resources,
        resource_types => $ast->resource_types,
        jobs           => $ast->jobs,
    };
    return "---\n" . $self->dump_yaml($pipeline) . "\n";
}
```

It reads the four generic pipeline arrays and dumps them to YAML. The
`_ensure_pipeline_resolved()` call is a safety check that runs
PipelineDescriptor if the generic pipeline has not been built yet.

The `generate_from_ast()` method in Concourse also has the legacy bridge
path for backward compatibility, but for new providers you would not
need that.

## Testing Your Provider

Place your provider file at
`lib/Genesis/CI/Compiler/Providers/MyPlatform.pm`. Test it by running:

```bash
genesis repipe --platform my-platform --dry-run
```

Use `--debug-dir` to inspect intermediate artifacts and verify that your
provider receives the expected AST data. Use `--output-dir` to write all
generated files to disk for manual review.
