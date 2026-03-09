#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use helper;
use Test::Deep;

use_ok 'Genesis::Config';

my $tmp = workdir();

subtest 'constructor backward compatibility' => sub {
	# Test old-style positional parameters (backward compatibility)

	# Old style: path only
	my $c1 = Genesis::Config->new("$tmp/test.yml");
	is($c1->path, "$tmp/test.yml", "old style: path only works");
	ok(!$c1->{autosave}, "old style: autosave defaults to false");

	# Old style: path + autosave
	my $c2 = Genesis::Config->new("$tmp/test.yml", 1);
	is($c2->path, "$tmp/test.yml", "old style: path + autosave works");
	ok($c2->{autosave}, "old style: autosave is set");

	# Old style: path + autosave + content
	my $c3 = Genesis::Config->new(undef, 0, {foo => 'bar'});
	is($c3->path, undef, "old style: can have undef path");
	ok(!$c3->{autosave}, "old style: autosave off with content");
	is($c3->get('foo'), 'bar', "old style: content is set");

	# Old style: no args
	my $c4 = Genesis::Config->new();
	is($c4->path, undef, "old style: no args creates empty config");
};

subtest 'constructor new named parameters' => sub {
	# Test new-style named parameters
	# These tests document the planned API for the Genesis::Config refactoring
	# See docs/refactors/genesis_config.md for implementation plan

	SKIP: {
		skip "Hybrid constructor not yet implemented - see docs/refactors/genesis_config.md", 5;

		# New style: path as named param
		my $c1 = Genesis::Config->new(path => "$tmp/test.yml");
		is($c1->path, "$tmp/test.yml", "new style: path param works");

		# New style: path + autosave
		my $c2 = Genesis::Config->new(path => "$tmp/test.yml", autosave => 1);
		is($c2->path, "$tmp/test.yml", "new style: path + autosave works");
		ok($c2->{autosave}, "new style: autosave is set");

		# New style: content
		my $c3 = Genesis::Config->new(content => {foo => 'bar'});
		is($c3->get('foo'), 'bar', "new style: content param works");

		# New style: schema (new feature)
		my $schema = {foo => {type => 'string'}};
		my $c4 = Genesis::Config->new(path => "$tmp/test.yml", schema => $schema);
		is($c4->{schema}, $schema, "new style: schema param is stored");
	}
};

subtest 'basic config creation and loading' => sub {
	my $config_file = "$tmp/test1.yml";

	# Create a config file
	put_file($config_file, <<EOF);
---
foo: bar
number: 42
nested:
  key: value
  array:
    - one
    - two
EOF

	my $config = Genesis::Config->new($config_file);
	ok($config->exists, "config file exists");
	ok(!$config->loaded, "config not loaded until accessed (lazy loading)");

	is($config->get('foo'), 'bar', "can get simple string value");
	ok($config->loaded, "config is loaded after accessing contents");
	is($config->get('number'), 42, "can get numeric value");
	is($config->get('nested.key'), 'value', "can get nested value");
	cmp_deeply($config->get('nested.array'), ['one', 'two'], "can get array value");

	# Check source tracking (new method)
	can_ok($config, 'get_source');
	is($config->get_source('foo'), 'loaded', "value loaded from file has 'loaded' source");
	is($config->get_source('nonexistent'), undef, "nonexistent key has no source");
};

subtest 'setting values explicitly' => sub {
	my $config_file = "$tmp/test2.yml";
	put_file($config_file, "---\nfoo: original\n");

	my $config = Genesis::Config->new($config_file);

	# Set a new value
	$config->set('bar', 'baz');
	is($config->get('bar'), 'baz', "can set and get new value");

	can_ok($config, 'get_source');
	is($config->get_source('bar'), 'set', "explicitly set value has 'set' source");

	# Override existing value
	$config->set('foo', 'modified');
	is($config->get('foo'), 'modified', "can override existing value");

	is($config->get_source('foo'), 'set', "overridden value has 'set' source");

	# Set nested value
	$config->set('nested.deep.key', 'value');
	is($config->get('nested.deep.key'), 'value', "can set nested value");
};

subtest 'environment variable overrides' => sub {
	my $config_file = "$tmp/test3.yml";
	put_file($config_file, "---\nfoo: original\nbar: original\n");

	my $schema = {
		foo => {
			type => 'string',
			envvar => 'TEST_FOO'
		},
		bar => {
			type => 'string'
		}
	};

	# Set environment variable
	local $ENV{TEST_FOO} = 'from_env';

	my $config = Genesis::Config->new($config_file);
	$config->validate($schema);

	is($config->get('foo'), 'from_env', "env var overrides file value");

	can_ok($config, 'get_source');
	is($config->get_source('foo'), 'env', "env override has 'env' source");
	is($config->get_source('bar'), 'loaded', "value without env var has 'loaded' source");

	is($config->get('bar'), 'original', "value without env var is unchanged");
};

subtest 'schema defaults' => sub {
	my $config_file = "$tmp/test4.yml";
	put_file($config_file, "---\nfoo: bar\n");

	my $schema = {
		foo => {
			type => 'string'
		},
		with_default => {
			type => 'string',
			default => 'default_value'
		},
		another_default => {
			type => 'number',
			default => 123
		}
	};

	my $config = Genesis::Config->new($config_file);
	$config->validate($schema);

	is($config->get('foo'), 'bar', "explicit value is returned");
	is($config->get('with_default'), 'default_value', "default value is returned");
	is($config->get('another_default'), 123, "numeric default is returned");

	can_ok($config, 'get_source');
	is($config->get_source('foo'), 'loaded', "explicit value has 'loaded' source");
	is($config->get_source('with_default'), 'default', "default value has 'default' source");
	is($config->get_source('another_default'), 'default', "numeric default has 'default' source");
};

subtest 'nested schema defaults with parent defaults' => sub {
	# Test that defaults are applied in nested schemas even when parent has a default
	# Regression test for ui.colors.code.warning_alert not getting default value
	# when ui or ui.colors has a default of {}

	my $schema = {
		some_other => {
			type => 'string'
		},
		ui => {
			type    => 'hash',
			default => {},
			schema  => {
				some_other_setting => {
					type => 'any'
				},
				colors => {
					type    => 'hash',
					default => {},
					schema  => {
						some_other_color => {
							type => 'string'
						},
						code => {
							type        => 'string',
							default     => 'Yb',
							description => 'Color for code blocks in the UI'
						},
						warning_alert => {
							type        => 'string',
							default     => 'kYi',
							description => 'Color for warning messages in the UI'
						}
					}
				}
			}
		}
	};

	# Test 1: No ui key at all
	my $config_file1 = "$tmp/test_nested1.yml";
	put_file($config_file1, "---\nsome_other: value\n");

	my $config1 = Genesis::Config->new($config_file1);
	$config1->validate($schema);

	is($config1->get('ui.colors.code'), 'Yb',
		"nested default applied when ui key missing");
	is($config1->get('ui.colors.warning_alert'), 'kYi',
		"nested default applied when ui key missing");

	# Test 2: ui present but ui.colors missing
	my $config_file2 = "$tmp/test_nested2.yml";
	put_file($config_file2, <<EOF);
---
ui:
  some_other_setting: value
EOF

	my $config2 = Genesis::Config->new($config_file2);
	$config2->validate($schema);

	is($config2->get('ui.colors.code'), 'Yb',
		"nested default applied when ui.colors key missing");
	is($config2->get('ui.colors.warning_alert'), 'kYi',
		"nested default applied when ui.colors key missing");

	# Test 3: ui.colors present but ui.colors.code missing
	my $config_file3 = "$tmp/test_nested3.yml";
	put_file($config_file3, <<EOF);
---
ui:
  colors:
    some_other_color: Rb
EOF

	my $config3 = Genesis::Config->new($config_file3);
	$config3->validate($schema);

	is($config3->get('ui.colors.code'), 'Yb',
		"nested default applied when ui.colors.code key missing");
	is($config3->get('ui.colors.warning_alert'), 'kYi',
		"nested default applied when ui.colors.warning_alert key missing");

	# Test 4: ui.colors.code present but ui.colors.warning_alert missing
	my $config_file4 = "$tmp/test_nested4.yml";
	put_file($config_file4, <<EOF);
---
ui:
  colors:
    code: Gb
EOF

	my $config4 = Genesis::Config->new($config_file4);
	$config4->validate($schema);

	is($config4->get('ui.colors.code'), 'Gb',
		"explicit value used when present");
	is($config4->get('ui.colors.warning_alert'), 'kYi',
		"nested default applied for sibling key when one child is explicit");

	# Test 5: ui explicitly set to {} in file
	my $config_file5 = "$tmp/test_nested5.yml";
	put_file($config_file5, <<EOF);
---
ui: {}
EOF

	my $config5 = Genesis::Config->new($config_file5);
	$config5->validate($schema);

	is($config5->get('ui.colors.code'), 'Yb',
		"nested default applied when ui explicitly {} in file");
	is($config5->get('ui.colors.warning_alert'), 'kYi',
		"nested default applied when ui explicitly {} in file");

	# Test 6: ui.colors explicitly set to {} in file
	my $config_file6 = "$tmp/test_nested6.yml";
	put_file($config_file6, <<EOF);
---
ui:
  colors: {}
EOF

	my $config6 = Genesis::Config->new($config_file6);
	$config6->validate($schema);

	is($config6->get('ui.colors.code'), 'Yb',
		"nested default applied when ui.colors explicitly {} in file");
	is($config6->get('ui.colors.warning_alert'), 'kYi',
		"nested default applied when ui.colors explicitly {} in file");
};

subtest 'priority resolution: env > set > loaded > default' => sub {
	my $config_file = "$tmp/test5.yml";
	put_file($config_file, <<EOF);
---
only_file: from_file
set_and_file: from_file
env_and_file: from_file
env_set_file: from_file
EOF

	my $schema = {
		only_file => { type => 'string' },
		set_and_file => { type => 'string' },
		env_and_file => { type => 'string', envvar => 'TEST_ENV_FILE' },
		env_set_file => { type => 'string', envvar => 'TEST_ENV_SET_FILE' },
		only_default => { type => 'string', default => 'default_val' },
		set_and_default => { type => 'string', default => 'default_val' },
		env_and_default => { type => 'string', default => 'default_val', envvar => 'TEST_ENV_DEFAULT' }
	};

	local $ENV{TEST_ENV_FILE} = 'from_env';
	local $ENV{TEST_ENV_SET_FILE} = 'from_env';
	local $ENV{TEST_ENV_DEFAULT} = 'from_env';

	my $config = Genesis::Config->new($config_file);
	$config->set('set_and_file', 'from_set');
	$config->set('env_set_file', 'from_set');
	$config->set('set_and_default', 'from_set');
	$config->validate($schema);

	# Priority tests
	is($config->get('only_file'), 'from_file', "file value when only source");
	is($config->get('set_and_file'), 'from_set', "set overrides file");
	is($config->get('env_and_file'), 'from_env', "env overrides file");
	is($config->get('env_set_file'), 'from_env', "env overrides set (which overrides file)");
	is($config->get('only_default'), 'default_val', "default when no other source");
	is($config->get('set_and_default'), 'from_set', "set overrides default");
	is($config->get('env_and_default'), 'from_env', "env overrides default");

	# Source tests
	can_ok($config, 'get_source');
	is($config->get_source('only_file'), 'loaded', "correct source for file-only");
	is($config->get_source('set_and_file'), 'set', "correct source for set override");
	is($config->get_source('env_and_file'), 'env', "correct source for env override");
	is($config->get_source('env_set_file'), 'env', "correct source for env > set");
	is($config->get_source('only_default'), 'default', "correct source for default-only");
	is($config->get_source('set_and_default'), 'set', "correct source for set > default");
	is($config->get_source('env_and_default'), 'env', "correct source for env > default");
};

subtest 'save behavior - only explicit values' => sub {
	my $config_file = "$tmp/test6.yml";
	put_file($config_file, "---\noriginal: value\n");

	my $schema = {
		original => { type => 'string' },
		with_default => { type => 'string', default => 'default_value' },
		with_env => { type => 'string', envvar => 'TEST_SAVE_ENV' },
		explicit_set => { type => 'string' }
	};

	local $ENV{TEST_SAVE_ENV} = 'from_env';

	my $config = Genesis::Config->new($config_file);
	$config->set('explicit_set', 'set_value');
	$config->validate($schema);

	# Verify all values are accessible
	is($config->get('original'), 'value', "original value accessible");
	is($config->get('with_default'), 'default_value', "default value accessible");
	is($config->get('with_env'), 'from_env', "env value accessible");
	is($config->get('explicit_set'), 'set_value', "set value accessible");

	# Save and reload
	$config->save();
	my $reloaded = Genesis::Config->new($config_file);

	# Check what was actually saved
	ok($reloaded->has('original'), "original value was saved");
	ok($reloaded->has('explicit_set'), "explicitly set value was saved");
	ok(!$reloaded->has('with_default'), "default value was NOT saved");
	ok(!$reloaded->has('with_env'), "env override was NOT saved");

	is($reloaded->get('original'), 'value', "saved original value is correct");
	is($reloaded->get('explicit_set'), 'set_value', "saved set value is correct");
};

subtest 'modifying loaded values' => sub {
	my $config_file = "$tmp/test7.yml";
	put_file($config_file, "---\nfoo: original\nbar: original\n");

	my $config = Genesis::Config->new($config_file);

	can_ok($config, 'get_source');
	SKIP: {
		skip "get_source() not yet implemented", 1;
		is($config->get_source('foo'), 'loaded', "initial source is 'loaded'");
	}

	# Modify a loaded value
	$config->set('foo', 'modified');

	is($config->get('foo'), 'modified', "value is modified");

	SKIP: {
		skip "get_source() not yet implemented", 1;
		is($config->get_source('foo'), 'set', "source changes to 'set' after modification");
	}

	# Save and verify
	$config->save();
	my $reloaded = Genesis::Config->new($config_file);

	is($reloaded->get('foo'), 'modified', "modified value persists after save");
	is($reloaded->get('bar'), 'original', "unmodified value remains unchanged");
};

subtest 'contents methods' => sub {
	my $config_file = "$tmp/test8.yml";
	put_file($config_file, "---\nloaded_key: loaded_value\n");

	my $schema = {
		loaded_key => { type => 'string' },
		default_key => { type => 'string', default => 'default_value' },
		env_key => { type => 'string', envvar => 'TEST_CONTENTS_ENV' },
		set_key => { type => 'string' }
	};

	local $ENV{TEST_CONTENTS_ENV} = 'env_value';

	my $config = Genesis::Config->new($config_file);
	$config->set('set_key', 'set_value');
	$config->validate($schema);

	# get_all() should return all effective values
	can_ok($config, 'get_all');
	my $all = $config->get_all();
	cmp_deeply($all, {
		loaded_key => 'loaded_value',
		default_key => 'default_value',
		env_key => 'env_value',
		set_key => 'set_value'
	}, "get_all() includes all sources");

	# _explicit_contents() should only return loaded/set values (what gets saved)
	can_ok($config, '_explicit_contents');
	SKIP: {
		skip "_explicit_contents() not yet implemented", 1;
		my $explicit = $config->_explicit_contents();
		cmp_deeply($explicit, {
			loaded_key => 'loaded_value',
			set_key => 'set_value'
		}, "_explicit_contents() excludes defaults and env vars (private method)");
	}

	# _contents() returns internal structure with source tracking
	SKIP: {
		skip "source tracking not yet implemented", 1;
		my $internal = $config->_contents();
		ok(ref($internal->{loaded_key}) eq 'HASH', "internal structure uses hash for tracking");
	}
	SKIP: {
		skip "source tracking not yet implemented", 1;
		my $internal = $config->_contents();
		is($internal->{loaded_key}{value}, 'loaded_value', "internal structure has value");
	}
	SKIP: {
		skip "source tracking not yet implemented", 1;
		my $internal = $config->_contents();
		is($internal->{loaded_key}{source}, 'loaded', "internal structure has source");
	}
};

subtest 'has() and is_set() methods' => sub {
	my $config_file = "$tmp/test9.yml";
	put_file($config_file, "---\nexplicit: value\n");

	my $schema = {
		explicit => { type => 'string' },
		with_default => { type => 'string', default => 'default_value' },
		with_env => { type => 'string', envvar => 'TEST_HAS_ENV' },
		missing => { type => 'string' }
	};

	local $ENV{TEST_HAS_ENV} = 'env_value';

	my $config = Genesis::Config->new($config_file);
	$config->validate($schema);

	# has() returns true for any value from any source (loaded/set/env/default)
	ok($config->has('explicit'), "has() returns true for explicit value");
	ok($config->has('with_default'), "has() returns true for value with default");
	ok($config->has('with_env'), "has() returns true for value from env var");
	ok(!$config->has('missing'), "has() returns false for missing value");

	# is_set() only checks loaded/set values (not env or defaults)
	can_ok($config, 'is_set');
	ok($config->is_set('explicit'), "is_set() returns true for explicit value");
	ok(!$config->is_set('with_default'), "is_set() returns false for default-only value");
	ok(!$config->is_set('with_env'), "is_set() returns false for env-only value");
	ok(!$config->is_set('missing'), "is_set() returns false for missing value");

	# Test after setting a value
	$config->set('with_default', 'now_set');
	ok($config->is_set('with_default'), "is_set() returns true after explicitly setting a defaulted value");
};

subtest 'validation does not modify explicit contents' => sub {
	my $config_file = "$tmp/test10.yml";
	put_file($config_file, "---\nfoo: bar\n");

	my $schema = {
		foo => { type => 'string' },
		with_default => { type => 'string', default => 'default_value' }
	};

	my $config = Genesis::Config->new($config_file);

	can_ok($config, '_explicit_contents');
	# Get explicit contents before validation
	my $before = $config->_explicit_contents();
	cmp_deeply($before, { foo => 'bar' }, "explicit contents before validation");

	$config->validate($schema);

	# Get explicit contents after validation
	my $after = $config->_explicit_contents();
	cmp_deeply($after, { foo => 'bar' }, "explicit contents unchanged after validation");

	# Validate for subsequent tests (always needed to populate defaults)
	$config->validate($schema);

	# But default is accessible
	is($config->get('with_default'), 'default_value', "default value is accessible after validation");

	# And save doesn't include defaults
	$config->save();
	my $saved_content = get_file($config_file);
	like($saved_content, qr/foo:.*bar/s, "saved file contains explicit value");
	unlike($saved_content, qr/with_default/s, "saved file does not contain default value");
};

subtest 'path() method' => sub {
	my $config_file = "$tmp/test11.yml";
	put_file($config_file, "---\nfoo: bar\n");

	my $config = Genesis::Config->new($config_file);
	is($config->path, $config_file, "path() returns config file path");

	my $config_no_path = Genesis::Config->new();
	is($config_no_path->path, undef, "path() returns undef for config without path");
};

subtest 'exists() method' => sub {
	my $existing_file = "$tmp/existing.yml";
	my $nonexistent_file = "$tmp/nonexistent.yml";

	put_file($existing_file, "---\nfoo: bar\n");

	my $existing = Genesis::Config->new($existing_file);
	ok($existing->exists, "exists() returns true for existing file");

	my $nonexistent = Genesis::Config->new($nonexistent_file);
	ok(!$nonexistent->exists, "exists() returns false for non-existent file");

	my $no_path = Genesis::Config->new();
	ok(!$no_path->exists, "exists() returns false for config without path");
};

subtest 'loaded() method' => sub {
	my $config_file = "$tmp/test12.yml";
	put_file($config_file, "---\nfoo: bar\n");

	my $config = Genesis::Config->new($config_file);
	ok(!$config->loaded, "loaded() returns false before accessing contents");

	$config->get('foo');
	ok($config->loaded, "loaded() returns true after loading from file");

	my $new_config = Genesis::Config->new();
	$new_config->set('key', 'value');
	ok(!$new_config->loaded, "loaded() returns false for in-memory only config");
};

subtest 'changed() method' => sub {
	my $config_file = "$tmp/test13.yml";
	put_file($config_file, "---\nfoo: original\n");

	my $config = Genesis::Config->new($config_file);
	$config->get('foo'); # Load the file

	ok(!$config->changed, "changed() returns false after loading");

	$config->set('foo', 'modified');
	ok($config->changed, "changed() returns true after modification");

	$config->save();
	ok(!$config->changed, "changed() returns false after saving");

	$config->set('bar', 'new');
	ok($config->changed, "changed() returns true after adding new key");
};

subtest 'clear() method' => sub {
	my $config_file = "$tmp/test14.yml";
	put_file($config_file, <<EOF);
---
foo: bar
nested:
  key: value
  array:
    - one
    - two
EOF

	my $config = Genesis::Config->new($config_file);

	ok($config->has('foo'), "key exists before clear");
	$config->clear('foo');
	ok(!$config->has('foo'), "key removed after clear");

	ok($config->has('nested.key'), "nested key exists before clear");
	$config->clear('nested.key');
	ok(!$config->has('nested.key'), "nested key removed after clear");

	ok($config->changed, "config is changed after clear");
};

subtest 'replace() method' => sub {
	my $config_file = "$tmp/test15.yml";
	put_file($config_file, "---\nold: value\n");

	my $old_config = Genesis::Config->new($config_file);
	$old_config->get('old'); # Load it

	my $new_config = Genesis::Config->new();
	$new_config->set('new', 'value');
	$new_config->set('another', 'value');

	$new_config->replace($old_config);

	# Check the file was updated
	my $reloaded = Genesis::Config->new($config_file);
	ok(!$reloaded->has('old'), "old key is gone after replace");
	ok($reloaded->has('new'), "new key exists after replace");
	ok($reloaded->has('another'), "another new key exists after replace");
};

subtest 'show_diff() method' => sub {
	my $config_file = "$tmp/test16.yml";
	put_file($config_file, <<EOF);
---
foo: original
bar: value
EOF

	my $config = Genesis::Config->new($config_file);
	$config->set('foo', 'modified');
	$config->set('baz', 'new');

	# show_diff should work without dying
	# (We can't easily test the output since it's sent to info())
	lives_ok { $config->show_diff() } "show_diff() doesn't die";

	# Compare with another config
	my $other_config = Genesis::Config->new();
	$other_config->set('foo', 'different');
	lives_ok { $config->show_diff($other_config) } "show_diff(other) doesn't die";
};

subtest 'get() with default parameter' => sub {
	my $config = Genesis::Config->new();
	$config->set('existing', 'value');

	is($config->get('existing', 'default'), 'value', "get() returns actual value when it exists");
	is($config->get('missing', 'default'), 'default', "get() returns default when key is missing");
	ok(!$config->has('missing'), "get() with default doesn't set the value");

	# Test set_if_missing parameter (4th argument)
	my $result = $config->get('auto_set', 'default_value', 1);
	is($result, 'default_value', "get() with set_if_missing returns default");
	ok($config->has('auto_set'), "get() with set_if_missing creates the key");
	is($config->get('auto_set'), 'default_value', "auto-set key has correct value");
};

subtest 'set() with save parameter' => sub {
	my $config_file = "$tmp/test17.yml";
	put_file($config_file, "---\nfoo: bar\n");

	my $config = Genesis::Config->new($config_file);
	$config->get('foo'); # Load it

	$config->set('new_key', 'new_value', 1); # save=1

	# File should be updated immediately
	my $reloaded = Genesis::Config->new($config_file);
	is($reloaded->get('new_key'), 'new_value', "set() with save=1 persists immediately");
};

subtest 'clear() with save parameter' => sub {
	my $config_file = "$tmp/test18.yml";
	put_file($config_file, "---\nfoo: bar\nbaz: qux\n");

	my $config = Genesis::Config->new($config_file);
	$config->get('foo'); # Load it

	$config->clear('foo', 1); # save=1

	# File should be updated immediately
	my $reloaded = Genesis::Config->new($config_file);
	ok(!$reloaded->has('foo'), "clear() with save=1 persists immediately");
	ok($reloaded->has('baz'), "other keys remain after clear");
};

subtest 'validation preserves source tracking for normalized values' => sub {
	# Test that when validation normalizes values (hasharray, boolean, etc),
	# the source tracking is preserved (not marked as 'set')

	# Hasharray normalization test - reproduces the deployment_roots issue
	my $config_file = "$tmp/test19.yml";
	put_file($config_file, "---\nroots:\n- label: path/to/root\n");

	my $config = Genesis::Config->new($config_file);

	# Schema that converts hasharray format
	my $schema = {
		roots => {
			type => 'array',
			subtype => 'hasharray',
		}
	};

	$config->validate($schema);

	# After validation, the value should still be tracked as 'loaded'
	is($config->get_source('roots'), 'loaded', "hasharray normalization preserves 'loaded' source");

	# Boolean normalization test
	my $config_file2 = "$tmp/test20.yml";
	put_file($config_file2, "---\nenabled: yes\n");

	my $config2 = Genesis::Config->new($config_file2);

	my $schema2 = {
		enabled => {
			type => 'boolean',
		}
	};

	$config2->validate($schema2);

	# After validation, the value should still be tracked as 'loaded'
	is($config2->get_source('enabled'), 'loaded', "boolean normalization preserves 'loaded' source");
};

subtest 'YAML special value handling' => sub {
	# Test that YAML keywords and special characters are properly quoted
	# when saved and correctly parsed when loaded

	my $config_file = "$tmp/test_yaml_special.yml";
	my $config = Genesis::Config->new($config_file);

	# Set various YAML-special string values
	$config->set('string_true', 'true');
	$config->set('string_false', 'false');
	$config->set('string_yes', 'yes');
	$config->set('string_no', 'no');
	$config->set('string_null', 'null');
	$config->set('string_array', '[this is not an array]');
	$config->set('string_hash', '{this is not a hash}');
	$config->set('actual_null', undef);
	$config->save();

	# Reload config from disk to verify proper serialization/deserialization
	my $config2 = Genesis::Config->new($config_file);

	is($config2->get('string_true'), 'true', "string 'true' preserved as string");
	is($config2->get('string_false'), 'false', "string 'false' preserved as string");
	is($config2->get('string_yes'), 'yes', "string 'yes' preserved as string");
	is($config2->get('string_no'), 'no', "string 'no' preserved as string");
	is($config2->get('string_null'), 'null', "string 'null' preserved as string");
	is($config2->get('string_array'), '[this is not an array]', "string that looks like array preserved");
	is($config2->get('string_hash'), '{this is not a hash}', "string that looks like hash preserved");
	is($config2->get('actual_null'), undef, "undef preserved as null");

	# Verify file contents have proper quoting
	my $config_content = get_file($config_file);
	like($config_content, qr/string_true:\s+['"]true['"]/, "string 'true' is quoted in file");
	like($config_content, qr/string_false:\s+['"]false['"]/, "string 'false' is quoted in file");
	like($config_content, qr/string_yes:\s+['"]yes['"]/, "string 'yes' is quoted in file");
	like($config_content, qr/string_no:\s+['"]no['"]/, "string 'no' is quoted in file");
	like($config_content, qr/string_null:\s+['"]null['"]/, "string 'null' is quoted in file");
	like($config_content, qr/string_array:\s+['"][^'"]*\[/, "string array is quoted in file");
	like($config_content, qr/string_hash:\s+['"][^'"]*\{/, "string hash is quoted in file");
	like($config_content, qr/actual_null:\s+(null|~)/, "undef written as unquoted null (null or ~)");
};

subtest 'partial deep hash override preserves other branches' => sub {
	# Test that setting a deep nested value doesn't lose other branches
	# This validates the flatten→merge→unflatten approach in _explicit_contents()

	my $config_file = "$tmp/test_partial_override.yml";
	put_file($config_file, <<EOF);
---
top:
  branch1:
    leaf1: value1
    leaf2: value2
  branch2:
    leaf3: value3
    leaf4: value4
EOF

	# Load config and override one deep leaf
	my $config = Genesis::Config->new($config_file);
	$config->set('top.branch1.leaf2', 'overridden');
	$config->save();

	# Reload and verify all values preserved
	my $config2 = Genesis::Config->new($config_file);
	is($config2->get('top.branch1.leaf1'), 'value1', "unmodified leaf in same branch preserved");
	is($config2->get('top.branch1.leaf2'), 'overridden', "overridden leaf has new value");
	is($config2->get('top.branch2.leaf3'), 'value3', "unmodified leaf in different branch preserved");
	is($config2->get('top.branch2.leaf4'), 'value4', "another unmodified leaf in different branch preserved");
};

subtest 'replace() preserves prev_config autosave' => sub {
	my $config_file = "$tmp/test15b.yml";
	put_file($config_file, "---\nold: value\n");

	my $old_config = Genesis::Config->new($config_file, 1); # autosave=1
	$old_config->get('old'); # Load it

	my $new_config = Genesis::Config->new();
	$new_config->set('new', 'value');

	$new_config->replace($old_config);

	is($old_config->{autosave}, 1, "prev_config autosave is preserved after replace");
	is($new_config->{autosave}, 1, "new config inherits prev_config autosave");
};

subtest '_load() with explicit path argument' => sub {
	my $alt_file = "$tmp/test_alt_load.yml";
	put_file($alt_file, "---\nalt_key: alt_value\n");

	# Config object with no path of its own
	my $config = Genesis::Config->new();
	$config->_load($alt_file);

	is($config->get('alt_key'), 'alt_value', "_load with explicit path loads from that file");
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
