# Tracking Down "Subroutine Redefined" Warnings in Perl

In Perl, "Subroutine 'xxx' redefined" warnings typically occur when a module is loaded multiple times, causing subroutines to be redefined. Here are several approaches to track down this issue:

## 1. Enable Verbose Warnings

Add these lines to get more detailed information:

```perl
use warnings FATAL => 'redefine';  # Make it fatal to stop execution
# or
use warnings;
$SIG{__WARN__} = sub {
    my $msg = shift;
    if ($msg =~ /redefined/) {
        require Carp;
        Carp::cluck($msg);  # Shows stack trace
    } else {
        warn $msg;
    }
};
```

## 2. Track Module Loading

Monitor when modules are loaded by overriding the `require` function:

```perl
BEGIN {
    my %loaded;
    my $orig_require = \&CORE::GLOBAL::require;
    *CORE::GLOBAL::require = sub {
        my $module = $_[0];
        if ($loaded{$module}) {
            require Carp;
            Carp::cluck("Module $module being reloaded!");
        }
        $loaded{$module}++;
        goto &$orig_require;
    };
}
```

## 3. Use Devel::TraceLoad

Install and use the `Devel::TraceLoad` module:

```bash
perl -d:TraceLoad your_script.pl
```

This will show exactly when and where modules are being loaded.

## 4. Check %INC Hash

Monitor the `%INC` hash to see what's loaded:

```perl
BEGIN {
    my %original_inc = %INC;
    END {
        for my $module (keys %INC) {
            if (!exists $original_inc{$module}) {
                print STDERR "Loaded: $module from $INC{$module}\n";
            }
        }
    }
}
```

## 5. Use Symbol Table Inspection

Track when specific subroutines are defined:

```perl
use Symbol qw(qualify_to_ref);

sub track_sub_definition {
    my ($package, $sub_name) = @_;
    my $full_name = "${package}::${sub_name}";

    no strict 'refs';
    if (defined &{$full_name}) {
        require Carp;
        Carp::cluck("Subroutine $full_name redefined");
    }
}
```

## 6. For Genesis Project Specifically

Given the Genesis project structure, you might want to add debugging to the hook loading mechanism. You could modify the hook loading code to track when hooks are being redefined:

```perl
# In your hook loading code
BEGIN {
    my %hook_loaded;
    # Override the hook loading mechanism
    around 'load_hook' => sub {
        my ($orig, $self, $hook_name) = @_;

        if ($hook_loaded{$hook_name}) {
            require Carp;
            Carp::cluck("Hook $hook_name being reloaded!");
        }
        $hook_loaded{$hook_name}++;

        return $self->$orig($hook_name);
    };
}
```

## 7. Use perl -w with Stack Traces

Run your script with:

```bash
perl -MCarp=verbose -w your_script.pl
```

This will provide stack traces for all warnings, including redefinition warnings.

## Most Practical Approach

For the Genesis project, I'd recommend starting with approach #1 (the `$SIG{__WARN__}` handler with `Carp::cluck`) as it's simple to implement and will immediately show you the call stack when the redefinition occurs, making it easy to identify which code path is causing the module to be reloaded.

## Genesis-Specific Considerations

When debugging in the Genesis project context:

1. **Hook Loading**: Pay special attention to how Perl hooks are loaded, as they may be getting reloaded multiple times during environment operations.

2. **Module Caching**: Check if the `Genesis::Base` memoization functionality is working correctly and not causing unexpected reloads.

3. **Environment Isolation**: Ensure that operations on different environments aren't causing cross-contamination of loaded modules.

4. **Kit Extraction**: Since compiled kits are extracted to temporary directories, verify that the same kit isn't being extracted multiple times causing module reloads.
