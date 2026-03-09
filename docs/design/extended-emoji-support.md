# Extended Emoji Support Design

## Overview

This design extends Genesis's emoji system to support the full Unicode emoji set through optional third-party applications, while maintaining backward compatibility and zero-dependency core functionality.

## Current State

Genesis currently provides a fixed set of 18 emojis in `Genesis::Term::_emojify()`:

```perl
my %emojis = (
  'crystal-ball' => "\x{1F52E}",
  'stop-sign' => "\x{1F6D1}",
  'collision' => "\x{1F4A5}",
  'information' => "\x{2139}\x{FE0F} ",
  'fire' => "\x{1F525}",
  'magnifying-glass' => "\x{1F50E}",
  'detective' => "\x{1F575}\x{FE0F} ",
  'warning' => "\x{26A0}\x{FE0F} ",
  'pancakes' => "\x{1F95E}",
  'tap' => "\x{1F6B0}",
  'memo' => "\x{1F4DD}",
  'notes' => "\x{1F5D2}\x{FE0F} ",
  'printer' => "\x{1F5A8}\x{FE0F} ",
  'tada' => "\x{1F389}",
  'tmyn' => "\x{1F320}",
  'notice' => "\x{1FAA7} ",
  'megaphone' => "\x{1F4E3}",
  'noentry' => "\x{26D4}\x{FE0F}",
);
```

## Requirements

1. **Backward Compatibility**: All existing emojis must continue to work
2. **Zero Dependencies**: Core functionality requires no external dependencies
3. **Graceful Degradation**: Unknown emojis return empty string when no external tools available
4. **Performance**: Cache results to avoid repeated external calls
5. **Cross-Platform**: Support macOS and Linux environments
6. **Genesis Standards**: Follow existing coding patterns and error handling

## Proposed Solution

### Third-Party Tool Selection

After evaluating options (emojify/npm, unicode command, custom bash functions), **Python 3 with the `emoji` library** was selected as the optimal choice:

**Advantages:**
- Python 3 pre-installed on macOS 10.15+ and most Linux distributions
- Simple installation: `pip3 install emoji`
- Uses Unicode CLDR standard (same as OS emoji support)
- Supports all OS-supported emoji including variants and skin tones
- Regular updates with new Unicode releases
- Standard `:emoji_name:` syntax (Slack/Discord compatible)

### Architecture

The extended emoji system uses a three-tier lookup strategy:

1. **Built-in emojis** (current Genesis set)
2. **Cached external lookups** (in-memory and persistent)
3. **Live external tool lookup** (fallback to Python emoji library)

### Code Modifications

#### 1. Update `_emojify` Function

**File:** `lib/Genesis/Term.pm`

**Current function:** Replace lines 149-174

```perl
sub _emojify {
  my $emoji = shift;
  my %emojis = (
    # ...existing emoji mappings...
  );

  return '' if envset('GENESIS_NO_UTF8');

  # Return built-in emoji if available
  return $emojis{$emoji} if exists $emojis{$emoji};

  # Try external emoji lookup with caching
  return _get_external_emoji($emoji);
}
```

#### 2. Add External Emoji Lookup Function

**File:** `lib/Genesis/Term.pm`

**Add new function after `_emojify`:**

```perl
# _get_external_emoji - lookup emoji from python-emoji with caching {{{
sub _get_external_emoji {
  my $emoji = shift;
  state %emoji_cache = ();
  state $python_available;

  # Return cached result if available
  return $emoji_cache{$emoji} if exists $emoji_cache{$emoji};

  # Check if python3 + emoji is available (cached check)
  unless (defined $python_available) {
    $python_available = (system('python3 -c "import emoji" 2>/dev/null') == 0);
  }
  return '' unless $python_available;

  # Try to get emoji from python-emoji
  my $result = `python3 -c "import emoji; print(emoji.emojize(':${emoji}:'), end='')" 2>/dev/null`;
  chomp $result if $result;

  # Validate result contains actual emoji characters
  if ($result && $result =~ /[\x{1F000}-\x{1F9FF}\x{2600}-\x{26FF}\x{1F300}-\x{1F5FF}]/) {
    $emoji_cache{$emoji} = $result;
    _cache_emoji_to_disk($emoji, $result) if $Genesis::RC;
    return $result;
  }

  # Cache negative result to avoid repeated lookups
  $emoji_cache{$emoji} = '';
  return '';
}
# }}}
```

#### 3. Add Persistent Caching Function

**File:** `lib/Genesis/Term.pm`

**Add new function:**

```perl
# _cache_emoji_to_disk - persist emoji lookups to user's genesis config {{{
sub _cache_emoji_to_disk {
  my ($emoji, $unicode) = @_;

  return unless $Genesis::RC;
  my $cache_dir = $Genesis::RC->get_config_dir();
  my $cache_file = "$cache_dir/emoji_cache.yml";

  eval {
    require YAML::PP;
    my $cache = {};
    $cache = YAML::PP::LoadFile($cache_file) if -f $cache_file;
    $cache->{$emoji} = $unicode;
    YAML::PP::DumpFile($cache_file, $cache);
  };
  # Silently ignore cache write failures
}
# }}}
```

#### 4. Load Cached Emojis on Startup

**File:** `lib/Genesis/Term.pm`

**Add initialization function:**

```perl
# _load_emoji_cache - load persistent emoji cache on startup {{{
sub _load_emoji_cache {
  return unless $Genesis::RC;
  my $cache_dir = $Genesis::RC->get_config_dir();
  my $cache_file = "$cache_dir/emoji_cache.yml";
  return unless -f $cache_file;

  eval {
    require YAML::PP;
    my $cache = YAML::PP::LoadFile($cache_file);
    # Pre-populate the state cache
    no warnings 'once';
    $Genesis::Term::_get_external_emoji::{emoji_cache} = $cache;
  };
  # Silently ignore cache load failures
}
# }}}
```

#### 5. Update Module Exports

**File:** `lib/Genesis/Term.pm`

**Update @EXPORT array to include new functions if needed for testing:**

```perl
our @EXPORT = qw/
  terminal_width
  wrap fix_wrap
  colored_block
  # ...existing exports...
  _load_emoji_cache  # For testing only
/;
```

## Usage Examples

### Backward Compatible Usage

```perl
# Built-in emojis continue to work unchanged
info("#E{fire} Build completed successfully!");  # 🔥
info("#E{tada} Deployment finished!");          # 🎉
```

### Extended Emoji Usage

```perl
# New emojis available when python3 + emoji installed
info("#E{rocket} Launching deployment...");     # 🚀 (external lookup)
info("#E{checkmark} All tests passed!");        # ✅ (external lookup)
info("#E{thumbs_up} Ready to deploy!");         # 👍 (external lookup)
```

### Graceful Degradation

```perl
# Unknown emojis return empty string when tools unavailable
info("#E{nonexistent} This still works");       # "This still works"
```

## Installation Instructions

Users who want extended emoji support can install the Python emoji library:

```bash
# Using pip3
pip3 install emoji

# Using pip3 with user install (no sudo required)
python3 -m pip install --user emoji

# Verify installation
python3 -c "import emoji; print(emoji.emojize(':fire:'))"  # Should print 🔥
```

## Performance Considerations

1. **Built-in emojis**: Zero overhead (hash lookup)
2. **Cached external emojis**: Single hash lookup after first use
3. **First-time external lookup**: ~100-200ms Python startup cost
4. **Tool availability check**: Cached after first check
5. **Persistent cache**: Survives Genesis restarts

## Testing Strategy

1. **Unit tests** for `_emojify` with and without Python available
2. **Integration tests** for cache persistence
3. **Performance tests** for lookup timing
4. **Cross-platform tests** on macOS and Linux
5. **Fallback tests** when external tools unavailable

## Migration Impact

- **Zero breaking changes**: All existing emoji usage continues unchanged
- **Optional feature**: Users can choose to install external tools
- **No configuration required**: Auto-detection of available tools
- **Backward compatible**: Works on systems without external tools

## Future Enhancements

1. **Custom emoji definitions**: Allow users to define custom emoji in Genesis config
2. **Multiple tool support**: Add fallback to other emoji tools
3. **Emoji validation**: Warn when using non-existent emoji names
4. **Cache management**: Commands to clear or refresh emoji cache

## Implementation Timeline

1. **Phase 1**: Core external lookup functionality
2. **Phase 2**: Persistent caching system
3. **Phase 3**: Testing and documentation
4. **Phase 4**: User documentation and examples

## Conclusion

This design provides a robust, performant, and user-friendly way to extend Genesis's emoji support while maintaining all existing design principles and compatibility requirements. The implementation leverages widely available tools and follows Genesis coding standards throughout.
