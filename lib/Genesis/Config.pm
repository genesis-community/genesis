package Genesis::Config;
use strict;
use warnings;

use Genesis qw/bail bug debug info struct_lookup struct_set_value struct_has in_array load_yaml_file run workdir mkdir_or_fail semver save_to_yaml_file spruce_diff priority_merge flatten unflatten/;
use Genesis::Term qw/bullet decolorize/;

use JSON::PP ();
use Digest::SHA qw/sha1_hex/;
use File::Basename qw/dirname/;
use POSIX qw/strftime/;

### Class Constants {{{

use constant {
	TRUE  => JSON::PP::true,
	FALSE => JSON::PP::false,
};

# }}}

### Class Methods {{{

# new - return a bare config object {{{
sub new {
	my ($class,$path,$autosave,$content) = @_;

	bug('No path to config file was specified - cannot autosave') if $autosave && !$path;

	return bless({
			path => $path,
			persistent_signature => undef,
			autosave => ($autosave && $path)? 1 : 0,
			loaded_values => {},
			set_values => $content//{},
			env_values => {},
			default_values => {},
		}, $class);
}

# }}}
# }}}

# Instance Methods {{{
# path - get the path to the configuration file {{{
sub path {
	$_[0]->{path}
}

# }}}
# exists - returns true if the configuration file exists on the filesystem {{{
sub exists {
	return 0 unless $_[0]->{path};
	-f $_[0]->{path}
}

# }}}
# loaded - returns true if the file has been initialized (loaded from or saved to disk) {{{
sub loaded {
	return 1 if defined($_[0]->{persistent_signature});
}

# }}}
# changed - returns true if the local representation differs from the filesystem {{{
sub changed {
	my $self = shift;
	($self->{persistent_signature}||'') ne $self->_signature;
}

# }}}
# get - read a value from the configuration {{{
sub get {
	my ($self,$key,$default,$set_if_missing) = @_;

	# Caching
	$key ||= '';
	return $self->{cache}{$key} if exists($self->{cache}{$key});

	my ($value,$found) = Genesis::struct_lookup($self->_contents,$key,$default);
	if ($set_if_missing && ! defined($found)) {
		$self->set($key,$value);
		$found = $key;
	}
	$self->{cache}{$key} = $value if $found;
	return $value;
}

# }}}
# get_all - get all effective configuration values from all sources {{{
sub get_all {
	my ($self) = @_;
	# Return a deep copy to prevent external mutation of internal state
	return JSON::PP->new->decode(JSON::PP->new->encode($self->_contents));
}

# }}}
# has - check if a key exists in the configuration {{{
sub has {
	my ($self, $key) = @_;

	bug("Cannot check for key in configuration without a key") unless defined($key);

	return 1 if exists($self->{cache}{$key});
	my (undef,$found) = Genesis::struct_lookup($self->_contents,$key);
	return $found;
}

# }}}
# is_set - check if a key was explicitly loaded or set (not from env/defaults) {{{
sub is_set {
	my ($self, $key) = @_;

	bug("Cannot check for key in configuration without a key") unless defined($key);

	# Check if key exists in explicit contents (loaded + set, excludes env + defaults)
	return struct_has($self->_explicit_contents, $key);
}

# }}}
# get_source - returns the source of a configuration value {{{
sub get_source {
	my ($self, $key) = @_;

	# Access contents to trigger lazy loading
	$self->_contents;

	# Check each source in priority order (env > set > loaded > default)
	# Return the highest priority source that has this key
	return 'env'     if $self->{env_values}     && struct_has($self->{env_values},     $key);
	return 'set'     if $self->{set_values}     && struct_has($self->{set_values},     $key);
	return 'loaded'  if $self->{loaded_values}  && struct_has($self->{loaded_values},  $key);
	return 'default' if $self->{default_values} && struct_has($self->{default_values}, $key);

	# Key doesn't exist in any source
	return undef;
}

# }}}
# _update_source - updates a value in a specific source structure {{{
sub _update_source {
	my ($self, $source, $key, $value) = @_;
	bug("Cannot update key in configuration without a source") unless defined($source);
	bug("Cannot update key in configuration without a key") unless defined($key);

	my $source_field = "${source}_values";
	bug("Invalid source '$source' - must be one of: env, set, loaded, default")
		unless exists $self->{$source_field};

	# Update the value in the specified source structure
	struct_set_value($self->{$source_field}, $key, $value);

	# Invalidate caches - both the key itself, its descendants, and any parent keys
	# that might contain it (since flatten uses literal empty refs, not actual refs)
	delete($self->{cache}{$_}) for (grep {
		$_ =~ /^$key($|[\.\[])/  ||  # Invalidate self and all descendants
		$key =~ /^\Q$_\E[\.\[]/      # Invalidate if updating a descendant of a cached parent
	} keys(%{$self->{cache}}));
	delete $self->{_contents};
	# Only invalidate _explicit_contents if we modified loaded or set
	delete $self->{_explicit_contents} if $source eq 'loaded' || $source eq 'set';
}

# }}}
# set - write a value to the configuration {{{
sub set {
	my ($self, $key, $value, $save) = @_;
	# TODO: Validate key and value against schema

	bug("Cannot save configuration without a path") if $save && ! $self->{path};

	# Use _update_source to handle cache invalidation
	$self->_update_source('set', $key, $value);

	$self->save if $self->changed && ($save || $self->{autosave});
	return $self->changed;
}

# }}}
# clear - remove a key from the configuration {{{
sub clear {
	my ($self, $key, $save) = @_;
	# TODO: Delete entire structure if key is undefined, or should that be an error?
	# TODO: Validate key and value against schema

	# Trigger lazy loading
	$self->_contents;

	# Remove from both loaded_values and set_values (whichever has it)
	struct_set_value($self->{loaded_values}, $key, undef, 1);
	struct_set_value($self->{set_values}, $key, undef, 1);

	# Invalidate caches
	delete($self->{cache}{$_}) for (grep {$_ =~ /^$key($|[\.\[])/} keys(%{$self->{cache}}));
	delete $self->{_contents};
	delete $self->{_explicit_contents};

	$self->save if $self->changed && ($save || $self->{autosave});
	return $self->changed;
}

# }}}
# save - save the configuration to the filesystem {{{
sub save {
	my ($self) = @_;

	bug("Cannot save configuration without a path") unless $self->{path};

	my $tmp = workdir();
	my $i=1; while (-f "$tmp/$i.json") {$i++};
	open my $fh, ">", "$tmp/$i.json"
		or bail "Unable to create tempfile for YAML conversion: $!";
	print $fh JSON::PP->new->canonical->encode($self->_explicit_contents);
	close $fh;
	my ($out,$rc,$err) = run(
		{stderr => 0},
		'cat "$1" | spruce merge --skip-eval - ; rm "$1"',
		"$tmp/$i.json"
	);
	bail(
		"Failed to convert configuration file %s to yaml: %s",
		$self->{path}, $err
	) if $rc;
	mkdir_or_fail(dirname($self->{path}));

	my $now = strftime("%Y-%m-%d at %H:%M:%S UTC", gmtime());
	open my $fh2, ">", $self->{path}
		or bail(
			"Failed to write configuration file to %s: %s",
			$self->{path}, $!
		);
	printf $fh2 "---\n# This file is generated by Genesis - do not edit manually.\n# Last updated by %s on %s\n\n", $ENV{USER}, $now;
	print $fh2 $out."\n";
	close $fh2;
	$self->{persistent_signature} = $self->_signature;
	return;
}

# }}}
# replace - replace the configuration with a new hash {{{
sub replace {
	my ($self, $prev_config) = @_;
	my $autosave = $prev_config->{autosave};
	local $prev_config->{autosave} = 0;
	$self->{path} = $prev_config->path;
	$self->{persistent_signature} = $prev_config->{persistent_signature};
	$self->save;
	$self->{autosave} = $autosave;
	return;
}


# }}}
# validate - validate the configuration against a schema {{{
sub validate {
	my ($self, $schema) = @_;
	$self->{schema} = $schema;
	my @errors = ();

	# Ensure all required keys are present, and all defaults are set
	for my $key (keys %$schema) {
		if (exists($schema->{$key}{envvar}) and exists($ENV{$schema->{$key}{envvar}})) {
			# Environment variables take precedence over configuration values.
			$self->_update_source('env', $key, $ENV{$schema->{$key}{envvar}});
		} elsif (exists($schema->{$key}{default}) and ! struct_has($self->{loaded_values}, $key) and ! struct_has($self->{set_values}, $key)) {
			# Set default only if not loaded or explicitly set
			$self->_update_source('default', $key, $schema->{$key}{default});
		} elsif ($schema->{$key}{required} and ! struct_has($self->{loaded_values}, $key) and ! struct_has($self->{set_values}, $key)) {
			push @errors, "#R{$key}: missing required key";
			next;
		}
	}

	for my $key (sort keys %{$self->_contents}) {
		if (! exists($schema->{$key})) {
			push @errors, "#R{$key}: unknown configuration key: expected one of ".join(', ', keys %$schema);
			next;
		}
		my $value = $self->get($key);
		my @key_errors = $self->_validate_key($key, $schema->{$key});
		push @errors, @key_errors if @key_errors;
	}

	if (@errors) {
		bail("Configuration validation failed for #C{%s}:%s",
			$self->{path},
			join('', map {"\n[[".bullet('', inline => 1, indent => 0).">>$_"} @errors));
	}

	# Invalidate contents cache after all validation is complete
	delete $self->{_contents};

	return 1;
}
# }}}
# }}}

### Instance Private Methods {{{

# _contents - the contents of the configuration object computed from source structures {{{
sub _contents {
	my ($self) = @_;
	$self->_load() unless ($self->loaded) || (! $self->exists && exists($self->{loaded_values}));

	# Merge all sources with priority: env > set > loaded > default
	# priority_merge takes multiple hashes in priority order (highest first)
	# and prevents ancestor/descendant conflicts
	# (if it it hasn't been cached already)
	return $self->{_contents} //= priority_merge(
		$self->{env_values},
		$self->{set_values},
		$self->{loaded_values},
		$self->{default_values}
	);
}

# }}}
# _explicit_contents - only loaded and set values (for saving to disk) {{{
sub _explicit_contents {
	my ($self) = @_;
	$self->_load() unless ($self->loaded) || (! $self->exists && exists($self->{loaded_values}));

	# Return cached explicit contents if available
	return $self->{_explicit_contents} if exists $self->{_explicit_contents};

	# Merge only explicit sources: set > loaded
	# Exclude env and default values from disk persistence
	# priority_merge preserves undef values and prevents ancestor/descendant conflicts
	return $self->{_explicit_contents} //= priority_merge(
		$self->{set_values},
		$self->{loaded_values}
	);
}

# }}}
# _load - load the contents of the configuration file from disk {{{
sub _load {
	my ($self, $path) = @_;

	# Re-entrancy guard: prevent infinite recursion when debug/bail
	# triggers configure_log which reads from this same config object
	return if $self->{_loading};
	local $self->{_loading} = 1;

	$path ||= $self->{path};
	bug("Cannot load configuration without a path") unless $path;

	if (-f $path) {
		($self->{loaded_values}, my $rc, my $err) = load_yaml_file($path);
		debug "Loaded ".$path." - rc:$rc";
		bail("Failed to load %s: %s", $path, $err) if ($rc || ! $self->{loaded_values});

		$self->{persistent_signature} = $self->_signature;
	} else {
		$self->{loaded_values} = {};
		$self->save if $self->{autosave} && $self->{path};
	}
}

# }}}
# _signature - generate a signature for the current in-memory contents {{{
sub _signature {
	my ($self) = @_;
	# Don't trigger loading - directly compute from source structures
	# Merge loaded + set (explicit contents) without calling _explicit_contents()
	# Uses priority_merge to match _explicit_contents() behavior
	my $explicit = priority_merge($self->{set_values}, $self->{loaded_values});
	return sha1_hex(JSON::PP->new->canonical->encode($explicit));
}
# }}}
# _validate_key - validate a value against a schema {{{
sub _validate_key {
	my ($self, $key, $schema) = @_;
	my @errors = ();
	my $type = $schema->{type} or bug "Schema for $key has no type";
	my $value = $self->get($key);

	if ($type =~ m/\|\|/) {
		# Allows for multiple types - check that at least one is valid
		my @types = split(/\|\|/, $type);
		my $valid = 0;
		for my $t (@types) {
			if ($self->_validate_key($key, {type => $t})) {
				$valid = 1;
				last;
			}
		}
		if (! $valid) {
			push @errors, "#R{$key}: expected one of ".join(', ', @types);
		}
	} elsif ($type eq 'hasharray') { # Special type that allows an array to be specified as a hash in yaml or a string in environment
		if (ref($value) ne 'ARRAY') {
			push @errors, "#R{$key}: expected an array";
		} else {
			for my $i (0..$#{$value}) {
				my @subkey_errors = $self->_validate_key("$key\[$i\]", $schema->{schema});
				push @errors, @subkey_errors if @subkey_errors;
			}
		}
	} elsif ($type eq 'hash') {
		if (ref($value) ne 'HASH') {
			push @errors, "#R{$key}: expected a hash";
		} else {
			# Check if loaded_values has an explicit empty hash for this key
			my $loaded_is_empty_hash = 0;
			if (keys(%$value) == 0 && struct_has($self->{loaded_values}, $key)) {
				my $loaded_val = struct_lookup($self->{loaded_values}, $key);
				$loaded_is_empty_hash = (ref($loaded_val) eq 'HASH' && keys(%$loaded_val) == 0);
			}
			# Ensure all required keys are present, and all defaults are set
			for my $subkey (keys %{$schema->{schema}}) {
				my $subschema = $schema->{schema}{$subkey};
				if (exists($subschema->{envvar}) && exists($ENV{$subschema->{envvar}})) {
					# Environment variables take precedence over configuration values.
					$self->_update_source('env', "$key.$subkey", $ENV{$subschema->{envvar}});
				} elsif (exists($subschema->{default}) and ! exists($value->{$subkey})) {
					# When the parent key was explicitly {} in loaded_values, apply
					# defaults at loaded priority so they aren't blocked by
					# the empty hash placeholder in priority_merge
					my $source = $loaded_is_empty_hash ? 'loaded' : 'default';
					$self->_update_source($source, "$key.$subkey", $subschema->{default});
				} elsif ($subschema->{required} and ! exists($value->{$subkey})) {
					push @errors, "#R{$key}: missing required key #ri{$subkey}";
				}
			}
			# Refetch value to include newly-added defaults for recursive validation
			# TODO: Optimize to only refetch if defaults or env values were actually set
			$value = $self->get($key);
			for my $subkey (sort keys %$value) {
				if (! exists($schema->{schema}{$subkey})) {
					push @errors, "#R{$key.$subkey}: unknown configuration key: expected one of ".join(', ', keys %{$schema->{schema}});
					next;
				}
				my @subkey_errors = $self->_validate_key("$key.$subkey", $schema->{schema}{$subkey});
				push @errors, @subkey_errors if @subkey_errors;
			}
		}

	} elsif ($type eq 'array') {
		if (ref($value) ne 'ARRAY') {
			# If the value is a scalar, it most likely came from the environment and needs to be split
			# into an array of values
			my $split = $schema->{envsplit};
			bug(
				"Schema for array $key has no envsplit, but was given a string value: #ri{%s}",
				$value
			) unless $split;
			$value = [split(/$split/, $value, -1)];

			if (defined($schema->{envconvert})) {
				# Convert the values to the specified type based on matches to
				# conversion rules
				for my $idx (0..(scalar(@$value)-1)) {
					my $found = 0;
					my @conversion_errors = ();
					for my $match (@{$schema->{envconvert}}) {
						if ($match->{type} eq 'hasharray') {
							# In string form, hasharray is restricted to pairs of key/value pairs
							my @pairs;
							eval { @pairs = split(qr($match->{pair_split}), $value->[$idx]); };
							if ($@) {
								push @conversion_errors, "Invalid hasharray value: %s", $value->[$idx];
								next;
							}
							my $kvs = $match->{kv_split};
							my $failed = 0;
							my @converted_pairs;
							for (@pairs) {
								# Check that the pair is in the form key=value
								my ($key, $value) = $_ =~ qr(^([^$kvs]+)$kvs([^$kvs]*)$);
								if (!defined($key)) {
									$failed = 1;
									push @conversion_errors, "Invalid hasharray string value: %s", $value->[$idx]; # continue processing to get all errors
								} else {
									push @converted_pairs, {$key => $value};
								}
							}
							next if ($failed);
							$value->[$idx] = \@converted_pairs;
							$found = 1;
							last;
						} elsif ($match->{type} eq 'string') {
							# Pretty much any string will match this, but not null or empty strings
							if (!defined($value->[$idx]) || $value->[$idx] eq '') {
								push @conversion_errors, "Invalid string value: %s", $value->[$idx] ? '""' : '<null>';
							} else {
								$found = 1;
								last;
							}
						} else {
							push @conversion_errors, "Unknown conversion type: %s", $match->{type};
						}
					}
					if (! $found) {
						my $error_list = join("", map {"  - $_\n"} @conversion_errors) || "  - No conversion rule matched the value";
						push @errors, "No conversion rule matched the value: %s\n%s", $value->[$idx], $error_list;
					}
				}
			}
		} # end conversion of strings to an array

		if (ref($value) ne 'ARRAY') {
			push @errors, "#R{$key}: expected an array";
		} else {
			my @subtypes = split(/\|\|/, $schema->{subtype});
			for my $i (0..$#{$value}) {
				my $subschema;
				my $found = 0;
				my @subtype_errors = ();
				for my $subtype (@subtypes) {
					if ($subtype eq 'hasharray') {
						# Hasharray is a special type that allows for a hash representation in of an array
						if (ref($value->[$i]) eq 'HASH') {
							$value->[$i] = [map {($_, $value->[$i]{$_})} keys %{$value->[$i]}];
						} elsif (ref($value->[$i]) eq 'ARRAY') {
							# Already in the correct format
						} else {
							push @subtype_errors, "#R{$key}[$i]: expected a hash or array, not #ri{".($value->[$i] ? $value->[$i] : "<null>")."}";
							next
						}
						$found = 1;
						last;
					} elsif ($subtype eq 'string') {
						if (ref($value->[$i]) ne '' || !defined($value->[$i]) || $value->[$i] eq '') {
							push @subtype_errors, "#R{$key}[$i]: expected a string, not #ri{".($value->[$i] ? $value->[$i] : "<null>")."}";
							next;
						}
						$found = 1;
						last;
					} else {
						if ($subtype eq 'hash') {
							bug "Schema for array $key hash value has no schema" unless $schema->{schema};
							$subschema = {schema => $schema->{schema}, type => 'hash'};
						} else {
							$subschema = $schema->{schema}//{};
							$subschema->{type} //= $subtype;
						}
						if (my @subkey_errors = $self->_validate_key("${key}[$i]", $subschema)) {
							push @subtype_errors, @subkey_errors;
						} else {
							$found = 1;
							last;
						}
					}
				}
				if (!$found) {
					my $error_list = join("", map {"  - $_\n"} @subtype_errors) || "  - No conversion rule matched the value";
					push @errors, sprintf("No subtype matched the value: %s\n%s", $value->[$i], $error_list);
				}
			}
			# Normalize array in place - update the source structure, not set()
			my $source = $self->get_source($key);
			bug("Cannot normalize key '$key' - no source found") unless $source;
			$self->_update_source($source, $key, $value);
		}

	} elsif ($type eq 'boolean') {
		if (! in_array($value, TRUE, FALSE, 1, 0, '', undef, 'true', 'false', 'yes', 'no')) {
			push @errors, "#R{$key}: expected a boolean, not #ri{".($value ? $value : '<null>')."}";
		}
		# Normalize boolean in place - update the source structure, not set()
		my $source = $self->get_source($key);
		bug("Cannot normalize key '$key' - no source found") unless $source;
		$self->_update_source($source, $key, $value ? TRUE : FALSE);
	} elsif ($type eq 'enum') {
		if (! in_array($value, @{$schema->{values}})) {
			push @errors, "#R{$key}: unknown value: #ri{".($value ? $value : "<null>")."}; expected one of ".join(', ', @{$schema->{values}});
		}
	} elsif ($type eq 'string') {
		if (ref($value) ne '' || !defined($value)) {
			push @errors, "#R{$key}: expected a string, not #ri{".($value ? $value : "<null>")."}";
		}
	} elsif ($type eq 'number') {
		if (ref($value) ne '' || !defined($value) || $value !~ m/^-?\d+(\.\d+)?$/) {
			push @errors, "#R{$key}: expected a number, not #ri{".($value ? $value : "<null>")."}";
		}
	} elsif ($type eq 'integer') {
		if (ref($value) ne '' || !defined($value) || $value !~ m/^-?[1-9]\d*$/) {
			push @errors, "#R{$key}: expected an integer, not #ri{".($value ? $value : "<null>")."}";
		}
	} elsif ($type eq 'semver') {
		if (ref($value) ne '' || !defined($value) || ! semver($value)) {
			push @errors, "#R{$key}: expected a number, not #ri{".($value ? $value : "<null>")."}"
				unless (!defined($value) && $schema->{allow_null});
		}
	} elsif ($type =~ /^"(.*?)"$/) {
		if (ref($value) ne '' || !defined($value) || $value ne $1) {
			push @errors, "#R{$key}: expected #ri{$1}, not #ri{".($value ? $value : "<null>")."}";
		}
	} elsif ($type eq 'null') {
		if (defined($value)) {
			push @errors, "#R{$key}: expected null, not #ri{".($value ? $value : "<null>")."}";
		}
	} elsif ($type eq 'any') {
		# Do nothing
	} else {
		push @errors, "#R{$key}: unknown schema type $type";
	}
	return @errors;
}

sub show_diff {

	# Shows the difference between the current configuration and another
	# configuration, which defaults to the last saved configuration.
	my ($self, $other) = @_;
	$other ||= Genesis::Config->new($self->{path});

	# Use Genesis::spruce_diff to compare configurations
	my $diff = spruce_diff(
		{object => $other->_contents, label => 'saved'},
		{object => $self->_contents, label => 'current'}
	);

	if ($diff) {
		info("Differences between existing and updated configuration:\n%s", $diff);
	} else {
		info("No differences found between existing and updated configuration");
	}
}

# }}}
# TODO: extract the hash schema validation into a separate method
# }}}
1;
# vim: fdm=marker:foldlevel=1:noet
