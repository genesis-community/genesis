#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use helper;

use Test::More;
use Test::Deep;
use Test::Differences;

use_ok 'Genesis';

# Test struct_set_value() - Set values in nested structures
subtest 'struct_set_value() - basic operations' => sub {
	my $struct;

	# Set simple value
	$struct = {};
	struct_set_value($struct, 'key', 'value');
	is $struct->{key}, 'value', 'set simple key';

	# Set nested value
	$struct = {};
	struct_set_value($struct, 'level1.level2', 'nested');
	is $struct->{level1}{level2}, 'nested', 'set nested key';

	# Set array element
	$struct = {arr => []};
	struct_set_value($struct, 'arr[0]', 'first');
	is $struct->{arr}[0], 'first', 'set array element';
};

subtest 'struct_set_value() - overwriting' => sub {
	my $struct;

	# Overwrite existing value
	$struct = {key => 'old'};
	struct_set_value($struct, 'key', 'new');
	is $struct->{key}, 'new', 'overwrite simple value';

	# Overwrite with different type
	$struct = {key => 'string'};
	struct_set_value($struct, 'key', {nested => 'hash'});
	is ref($struct->{key}), 'HASH', 'overwrite with hash';
	is $struct->{key}{nested}, 'hash', 'overwrite hash value correct';
};

# Test struct_lookup() - Retrieve values from nested structures
subtest 'struct_lookup() - basic retrieval' => sub {
	my $struct = {
		simple => 'value',
		nested => {
			deep => 'nested_value'
		},
		array => ['one', 'two', 'three']
	};

	# Simple lookup
	is struct_lookup($struct, 'simple'), 'value', 'lookup simple key';

	# Nested lookup
	is struct_lookup($struct, 'nested.deep'), 'nested_value', 'lookup nested key';

	# Array lookup
	is struct_lookup($struct, 'array[0]'), 'one', 'lookup array element';
	is struct_lookup($struct, 'array[2]'), 'three', 'lookup array element by index';
};

subtest 'struct_lookup() - missing keys' => sub {
	my $struct = {key => 'value'};

	# Missing key returns undef
	is struct_lookup($struct, 'missing'), undef, 'missing key returns undef';

	# Deep missing key returns undef
	is struct_lookup($struct, 'missing.deep'), undef, 'deep missing key returns undef';

	# Missing array index returns undef
	$struct->{arr} = ['one'];
	is struct_lookup($struct, 'arr[10]'), undef, 'missing array index returns undef';
};

# Test flatten() - Convert nested structure to flat dotted keys
subtest 'flatten() - basic flattening' => sub {
	my $nested = {
		simple => 'value',
		nested => {
			key => 'nested_value'
		}
	};

	my $flat = flatten($nested);
	is $flat->{'simple'}, 'value', 'simple key preserved';
	is $flat->{'nested.key'}, 'nested_value', 'nested key flattened';
};

subtest 'flatten() - arrays' => sub {
	my $nested = {
		array => ['one', 'two', 'three']
	};

	my $flat = flatten($nested);
	is $flat->{'array[0]'}, 'one', 'array element 0 flattened';
	is $flat->{'array[1]'}, 'two', 'array element 1 flattened';
	is $flat->{'array[2]'}, 'three', 'array element 2 flattened';
};

subtest 'flatten() - complex structures' => sub {
	my $nested = {
		top => {
			middle => {
				bottom => 'deep_value'
			}
		},
		list => [
			{name => 'first'},
			{name => 'second'}
		]
	};

	my $flat = flatten($nested);
	is $flat->{'top.middle.bottom'}, 'deep_value', 'deep nesting flattened';
	is $flat->{'list[0].name'}, 'first', 'array of hashes flattened';
	is $flat->{'list[1].name'}, 'second', 'array of hashes flattened';
};

subtest 'flatten() - empty hashes and arrays' => sub {
	my $nested = {
		empty_hash => {},
		empty_array => [],
		nested_empty => {
			inner => {}
		},
		mixed => {
			value => 'test',
			empty => {}
		},
		some_items => [
			{odd => [1, 3]},
			{even => [2, 4]},
			{both => []},
			{}
		]
	};

	my $flat = flatten($nested);
	ok exists($flat->{empty_hash}), 'empty hash key exists in flattened structure';
	is ref($flat->{empty_hash}), 'HASH', 'empty hash value is HASH ref';
	is scalar(keys %{$flat->{empty_hash}}), 0, 'empty hash has 0 keys';
	ok exists($flat->{empty_array}), 'empty array key exists in flattened structure';
	is ref($flat->{empty_array}), 'ARRAY', 'empty array value is ARRAY ref';
	is scalar(@{$flat->{empty_array}}), 0, 'empty array has 0 elements';
	ok exists($flat->{'nested_empty.inner'}), 'nested empty hash key exists';
	is ref($flat->{'nested_empty.inner'}), 'HASH', 'nested empty hash value is HASH ref';
	is scalar(keys %{$flat->{'nested_empty.inner'}}), 0, 'nested empty hash has 0 keys';
	is $flat->{'mixed.value'}, 'test', 'value preserved alongside empty hash';
	ok exists($flat->{'mixed.empty'}), 'empty hash exists alongside value';
	is ref($flat->{'mixed.empty'}), 'HASH', 'empty hash value is HASH ref in mixed structure';
	is scalar(keys %{$flat->{'mixed.empty'}}), 0, 'empty hash in mixed structure has 0 keys';
	is $flat->{'some_items[0].odd[0]'}, 1, 'array element with values (first)';
	is $flat->{'some_items[0].odd[1]'}, 3, 'array element with values (second)';
	is $flat->{'some_items[1].even[0]'}, 2, 'array element with values (first)';
	is $flat->{'some_items[1].even[1]'}, 4, 'array element with values (second)';
	ok exists($flat->{'some_items[2].both'}), 'empty array in hash element preserved';
	is ref($flat->{'some_items[2].both'}), 'ARRAY', 'empty array in hash element is ARRAY ref';
	is scalar(@{$flat->{'some_items[2].both'}}), 0, 'empty array in hash element has 0 elements';
	ok exists($flat->{'some_items[3]'}), 'empty hash element in array preserved';
	is ref($flat->{'some_items[3]'}), 'HASH', 'empty hash element in array is HASH ref';
	is scalar(keys %{$flat->{'some_items[3]'}}), 0, 'empty hash element in array has 0 keys';
};

# Test unflatten() - Convert flat dotted keys back to nested structure
subtest 'unflatten() - basic unflattening' => sub {
	my $flat = {
		'simple' => 'value',
		'nested.key' => 'nested_value'
	};

	my $nested = unflatten($flat);
	is $nested->{simple}, 'value', 'simple key preserved';
	is $nested->{nested}{key}, 'nested_value', 'dotted key unflattened';
};

subtest 'unflatten() - arrays' => sub {
	my $flat = {
		'array[0]' => 'one',
		'array[1]' => 'two',
		'array[2]' => 'three'
	};

	my $nested = unflatten($flat);
	is ref($nested->{array}), 'ARRAY', 'array created';
	is $nested->{array}[0], 'one', 'array element 0 correct';
	is $nested->{array}[1], 'two', 'array element 1 correct';
	is $nested->{array}[2], 'three', 'array element 2 correct';
};

subtest 'flatten/unflatten roundtrip - empty hashes and arrays' => sub {
	my $original = {
		empty_hash => {},
		empty_array => [],
		nested_empty => {
			inner => {}
		},
		mixed => {
			value => 'test',
			empty => {}
		},
		some_items => [
			{odd => [1, 3]},
			{even => [2, 4]},
			{both => []},
			{}
		]
	};

	# Test flatten preserves empty structures
	my $flat = flatten($original);
	ok exists($flat->{empty_hash}), 'empty hash key exists in flattened structure';
	is ref($flat->{empty_hash}), 'HASH', 'empty hash value is HASH ref';
	is scalar(keys %{$flat->{empty_hash}}), 0, 'empty hash has 0 keys';
	ok exists($flat->{empty_array}), 'empty array key exists in flattened structure';
	is ref($flat->{empty_array}), 'ARRAY', 'empty array value is ARRAY ref';
	is scalar(@{$flat->{empty_array}}), 0, 'empty array has 0 elements';

	# Test unflatten preserves empty structures and roundtrip matches original
	my $roundtrip = unflatten($flat);
	is_deeply $roundtrip, $original, 'roundtrip matches original structure';
};

# Test deep_merge() - Recursive hash merging
subtest 'deep_merge() - simple merging' => sub {
	my $base = {
		a => 1,
		b => 2
	};
	my $override = {
		b => 3,
		c => 4
	};

	my $merged = deep_merge($base, $override);
	is $merged->{a}, 1, 'base key preserved';
	is $merged->{b}, 3, 'override key wins';
	is $merged->{c}, 4, 'new key added';
};

subtest 'priority_merge() - priority-aware merging with conflict detection' => sub {
	# Test 1: Basic priority - first structure wins
	my $high_priority = {
		foo => 'high',
		bar => 1
	};
	my $low_priority = {
		foo => 'low',
		baz => 2
	};

	my $result = priority_merge($high_priority, $low_priority);
	is $result->{foo}, 'high', 'high priority value preserved';
	is $result->{bar}, 1, 'high priority key preserved';
	is $result->{baz}, 2, 'non-conflicting low priority key added';

	# Test 2: Ancestor blocks descendants - deployment_roots => [] blocks deployment_roots[0].default
	$high_priority = {
		deployment_roots => []
	};
	$low_priority = {
		'deployment_roots' => [
			{ default => 'some/path' }
		]
	};

	$result = priority_merge($high_priority, $low_priority);
	is_deeply $result->{deployment_roots}, [], 'empty array from high priority preserved';

	# Test 3: Descendants block ancestors - deployment_roots[0].my_lab blocks deployment_roots => []
	$high_priority = {
		deployment_roots => [
			{ my_lab => 'some/path' }
		]
	};
	$low_priority = {
		deployment_roots => []
	};

	$result = priority_merge($high_priority, $low_priority);
	is_deeply $result->{deployment_roots}, [{ my_lab => 'some/path' }],
		'array with value from high priority preserved, ancestor blocked';

	# Test 4: Complex nested case with multiple conflicts
	$high_priority = {
		ui => {
			colors => {
				code => 'Yb'
			}
		}
	};
	$low_priority = {
		ui => {
			colors => {
				code => 'default',
				warning_alert => 'kYi'
			},
			theme => 'dark'
		}
	};

	$result = priority_merge($high_priority, $low_priority);
	is $result->{ui}{colors}{code}, 'Yb', 'high priority nested value preserved';
	is $result->{ui}{colors}{warning_alert}, 'kYi', 'non-conflicting nested value added';
	is $result->{ui}{theme}, 'dark', 'non-conflicting sibling key added';

	# Test 5: Empty hash/array preservation with priority
	$high_priority = {
		empty_config => {}
	};
	$low_priority = {
		empty_config => {
			default => 'value'
		}
	};

	$result = priority_merge($high_priority, $low_priority);
	is_deeply $result->{empty_config}, {}, 'empty hash from high priority preserved';
};

subtest 'deep_merge() - nested merging' => sub {
	my $base = {
		top => {
			a => 1,
			b => 2
		}
	};
	my $override = {
		top => {
			b => 3,
			c => 4
		}
	};

	my $merged = deep_merge($base, $override);
	is $merged->{top}{a}, 1, 'nested base key preserved';
	is $merged->{top}{b}, 3, 'nested override key wins';
	is $merged->{top}{c}, 4, 'nested new key added';
};

subtest 'deep_merge() - array handling' => sub {
	my $base = {
		list => ['one', 'two']
	};
	my $override = {
		list => ['three', 'four']
	};

	my $merged = deep_merge($base, $override);
	is ref($merged->{list}), 'ARRAY', 'array preserved';
	# Arrays are typically replaced, not merged
	is scalar(@{$merged->{list}}), 2, 'override array replaces base';
};

subtest 'deep_merge() - multiple sources' => sub {
	my $a = {key => 'a', a_only => 1};
	my $b = {key => 'b', b_only => 2};
	my $c = {key => 'c', c_only => 3};

	my $merged = deep_merge($a, $b, $c);
	is $merged->{key}, 'c', 'last source wins';
	is $merged->{a_only}, 1, 'first source keys preserved';
	is $merged->{b_only}, 2, 'middle source keys preserved';
	is $merged->{c_only}, 3, 'last source keys preserved';
};

# Test in_array() - Check if value exists in array
subtest 'in_array() - value checking' => sub {
	my @arr = ('one', 'two', 'three');

	ok in_array('two', @arr), 'value exists in array';
	ok !in_array('four', @arr), 'value not in array';
	ok in_array('one', @arr), 'first element found';
	ok in_array('three', @arr), 'last element found';
};

# Test index_of() - Find index of value in array
subtest 'index_of() - index finding' => sub {
	my @arr = ('one', 'two', 'three');

	is index_of('one', @arr), 0, 'first element index';
	is index_of('two', @arr), 1, 'middle element index';
	is index_of('three', @arr), 2, 'last element index';
	is index_of('missing', @arr), undef, 'missing element returns undef';
};

# Test compare_arrays() - Array difference analysis
# Returns: ([only in arr1], [in both], [only in arr2])
subtest 'compare_arrays() - identical arrays' => sub {
	my @a = (1, 2, 3);
	my @b = (1, 2, 3);
	my ($only_a, $both, $only_b) = compare_arrays(\@a, \@b);

	is scalar(@$only_a), 0, 'no items only in first array';
	is scalar(@$both), 3, 'all items in both arrays';
	is scalar(@$only_b), 0, 'no items only in second array';
	cmp_deeply $both, [1, 2, 3], 'common items correct';
};

subtest 'compare_arrays() - different arrays' => sub {
	my @a = (1, 2, 3);
	my @c = (1, 2, 4);
	my ($only_a, $both, $only_c) = compare_arrays(\@a, \@c);

	cmp_deeply $only_a, [3], 'items only in first array';
	cmp_deeply $both, [1, 2], 'items in both arrays';
	cmp_deeply $only_c, [4], 'items only in second array';
};

subtest 'compare_arrays() - length differences' => sub {
	my @a = (1, 2, 3);
	my @b = (1, 2);
	my ($only_a, $both, $only_b) = compare_arrays(\@a, \@b);

	cmp_deeply $only_a, [3], 'extra item in first array';
	cmp_deeply $both, [1, 2], 'common items';
	is scalar(@$only_b), 0, 'no extra items in second array';
};

# Test uniq() - Remove duplicate values
subtest 'uniq() - deduplication' => sub {
	my @arr = (1, 2, 2, 3, 3, 3, 4);
	my @unique = uniq(@arr);

	is scalar(@unique), 4, 'duplicates removed';
	cmp_deeply \@unique, [1, 2, 3, 4], 'unique values preserved';
};

subtest 'uniq() - order preservation' => sub {
	my @arr = (3, 1, 2, 1, 3, 2);
	my @unique = uniq(@arr);

	is scalar(@unique), 3, 'duplicates removed';
	is $unique[0], 3, 'first occurrence order preserved';
	is $unique[1], 1, 'second occurrence order preserved';
	is $unique[2], 2, 'third occurrence order preserved';
};

# Test get_opts() - Hash slicing with underscore-to-dash conversion
subtest 'get_opts() - hash slicing' => sub {
	my %config = (
		name => 'test-env',
		region => 'us-west-2',
		'instance-type' => 't2.micro',
		count => 5
	);

	# Simple key extraction
	my %result = get_opts(\%config, 'name', 'region');
	is $result{name}, 'test-env', 'extracted name key';
	is $result{region}, 'us-west-2', 'extracted region key';
	ok !exists($result{count}), 'did not extract unspecified key';

	# Underscore to dash conversion
	%result = get_opts(\%config, 'instance_type');
	is $result{instance_type}, 't2.micro', 'underscore key maps to dash key';

	# Mixed keys
	%result = get_opts(\%config, 'name', 'instance_type', 'count');
	is $result{name}, 'test-env', 'mixed: extracted name';
	is $result{instance_type}, 't2.micro', 'mixed: underscore to dash conversion';
	is $result{count}, 5, 'mixed: extracted count';

	# Non-existent keys
	%result = get_opts(\%config, 'missing', 'also_missing');
	ok !exists($result{missing}), 'non-existent key not in result';
	ok !exists($result{also_missing}), 'non-existent underscore key not in result';

	# Empty extraction
	%result = get_opts(\%config);
	is scalar(keys %result), 0, 'empty key list returns empty hash';
};

# Test delete_from_array() - Remove matching elements from array
subtest 'delete_from_array() - basic removal' => sub {
	my @arr = ('one', 'two', 'three', 'four');
	my @removed = delete_from_array(\@arr, qr/^two$/);

	is scalar(@arr), 3, 'array has 3 elements after removal';
	is scalar(@removed), 1, 'one element was removed';
	is $removed[0], 'two', 'correct element removed';
	cmp_deeply \@arr, ['one', 'three', 'four'], 'remaining elements correct';
};

subtest 'delete_from_array() - multiple matches' => sub {
	my @arr = ('apple', 'banana', 'apricot', 'cherry', 'avocado');
	my @removed = delete_from_array(\@arr, qr/^a/);

	is scalar(@removed), 3, 'three elements removed';
	cmp_deeply \@removed, ['apple', 'apricot', 'avocado'], 'all a-prefixed items removed';
	cmp_deeply \@arr, ['banana', 'cherry'], 'remaining elements correct';
};

subtest 'delete_from_array() - multiple patterns' => sub {
	my @arr = ('one', 'two', 'three', 'four', 'five');
	my @removed = delete_from_array(\@arr, qr/^t/, qr/our$/);

	is scalar(@removed), 3, 'three elements removed';
	cmp_deeply \@removed, ['two', 'three', 'four'], 'items matching either pattern removed';
	cmp_deeply \@arr, ['one', 'five'], 'remaining elements correct';
};

subtest 'delete_from_array() - no matches' => sub {
	my @arr = ('one', 'two', 'three');
	my @removed = delete_from_array(\@arr, qr/^missing$/);

	is scalar(@removed), 0, 'no elements removed';
	cmp_deeply \@arr, ['one', 'two', 'three'], 'array unchanged';
};

subtest 'delete_from_array() - empty array' => sub {
	my @arr = ();
	my @removed = delete_from_array(\@arr, qr/anything/);

	is scalar(@removed), 0, 'no elements removed from empty array';
	is scalar(@arr), 0, 'array still empty';
};

# ============================================================================
# Coverage gap tests - struct_lookup with array keys (multi-key fallback)
# ============================================================================

subtest 'struct_lookup() - array of keys (multi-key fallback)' => sub {
	my $struct = {
		primary => 'primary_value',
		fallback => 'fallback_value',
		last_resort => 'last_value'
	};

	# First key exists - should return it
	my $val = struct_lookup($struct, ['primary', 'fallback', 'last_resort']);
	is $val, 'primary_value', 'returns first matching key value';

	# First key missing, second exists
	$val = struct_lookup($struct, ['missing', 'fallback', 'last_resort']);
	is $val, 'fallback_value', 'falls back to second key when first missing';

	# First two missing, third exists
	$val = struct_lookup($struct, ['missing', 'also_missing', 'last_resort']);
	is $val, 'last_value', 'falls back to third key';

	# All keys missing - returns default
	$val = struct_lookup($struct, ['missing', 'nope', 'gone'], 'default_val');
	is $val, 'default_val', 'returns default when all keys missing';

	# Nested keys in array
	$struct = {
		genesis => { secrets_path => 'genesis/path' },
		params => { vault_prefix => 'params/prefix', vault => 'params/vault' }
	};
	$val = struct_lookup($struct, ['genesis.secrets_path', 'params.vault_prefix', 'params.vault']);
	is $val, 'genesis/path', 'nested key lookup with array works';

	# Second nested key used when first missing
	delete $struct->{genesis}{secrets_path};
	$val = struct_lookup($struct, ['genesis.secrets_path', 'params.vault_prefix', 'params.vault']);
	is $val, 'params/prefix', 'falls back to second nested key';

	# Third nested key used when first two missing
	delete $struct->{params}{vault_prefix};
	$val = struct_lookup($struct, ['genesis.secrets_path', 'params.vault_prefix', 'params.vault']);
	is $val, 'params/vault', 'falls back to third nested key';
};

subtest 'struct_lookup() - list context returns (value, matched_key)' => sub {
	my $struct = {
		primary => 'primary_value',
		fallback => 'fallback_value'
	};

	# List context with single key
	my ($val, $key) = struct_lookup($struct, 'primary');
	is $val, 'primary_value', 'list context returns correct value';
	is $key, 'primary', 'list context returns matched key';

	# List context with array keys - first match
	($val, $key) = struct_lookup($struct, ['primary', 'fallback']);
	is $val, 'primary_value', 'list context array keys returns correct value';
	is $key, 'primary', 'list context array keys returns first matched key';

	# List context with array keys - fallback match
	($val, $key) = struct_lookup($struct, ['missing', 'fallback']);
	is $val, 'fallback_value', 'list context fallback returns correct value';
	is $key, 'fallback', 'list context fallback returns matched key';

	# List context with no match
	($val, $key) = struct_lookup($struct, ['missing', 'also_missing'], 'default');
	is $val, 'default', 'list context no match returns default';
	is $key, undef, 'list context no match returns undef key';
};

subtest 'struct_lookup() - CODE ref default' => sub {
	my $struct = { existing => 'value' };
	my $call_count = 0;

	# CODE default not called when key exists
	my $val = struct_lookup($struct, 'existing', sub { $call_count++; return 'computed' });
	is $val, 'value', 'CODE default not used when key exists';
	is $call_count, 0, 'CODE default not called when key exists';

	# CODE default called when key missing
	$val = struct_lookup($struct, 'missing', sub { $call_count++; return 'computed' });
	is $val, 'computed', 'CODE default returns computed value';
	is $call_count, 1, 'CODE default called exactly once';

	# CODE default with closure
	my $counter = 10;
	$val = struct_lookup($struct, 'missing', sub { $counter += 5; return $counter });
	is $val, 15, 'CODE default can use closure variables';
};

# ============================================================================
# Coverage gap tests - struct_has
# ============================================================================

subtest 'struct_has() - basic existence checks' => sub {
	my $struct = {
		simple => 'value',
		nested => { deep => 'nested_value' },
		array => ['one', 'two', 'three'],
		zero => 0,
		empty_string => '',
		undef_val => undef
	};

	# Simple key exists
	ok struct_has($struct, 'simple'), 'simple key exists';

	# Simple key missing
	ok !struct_has($struct, 'missing'), 'missing key does not exist';

	# Nested key exists
	ok struct_has($struct, 'nested.deep'), 'nested key exists';

	# Nested key missing
	ok !struct_has($struct, 'nested.missing'), 'nested missing key does not exist';

	# Array element exists
	ok struct_has($struct, 'array[0]'), 'array element exists';
	ok struct_has($struct, 'array[2]'), 'array element 2 exists';

	# Array element out of bounds
	ok !struct_has($struct, 'array[10]'), 'array element out of bounds does not exist';

	# Falsy values still exist
	ok struct_has($struct, 'zero'), 'zero value exists';
	ok struct_has($struct, 'empty_string'), 'empty string exists';

	# Note: undef value - the key exists but value is undef
	# struct_has checks if the key exists, not if value is defined
};

subtest 'struct_has() - array of keys' => sub {
	my $struct = {
		primary => 'value',
		fallback => 'other'
	};

	# At least one key exists
	ok struct_has($struct, ['primary', 'fallback']), 'struct_has with array - first exists';
	ok struct_has($struct, ['missing', 'fallback']), 'struct_has with array - second exists';

	# No keys exist
	ok !struct_has($struct, ['missing', 'also_missing']), 'struct_has with array - none exist';
};

# ============================================================================
# Coverage gap tests - _lookup_key edge cases (via struct_lookup)
# ============================================================================

subtest 'struct_lookup() - named element in array (name=value)' => sub {
	my $struct = {
		instances => [
			{ name => 'web', memory => '1G' },
			{ name => 'worker', memory => '2G' },
			{ name => 'scheduler', memory => '512M' }
		]
	};

	# Lookup by name
	my $val = struct_lookup($struct, 'instances[name=worker].memory');
	is $val, '2G', 'lookup array element by name=value';

	$val = struct_lookup($struct, 'instances[name=web].memory');
	is $val, '1G', 'lookup first array element by name';

	$val = struct_lookup($struct, 'instances[name=scheduler].memory');
	is $val, '512M', 'lookup last array element by name';

	# Non-existent name
	$val = struct_lookup($struct, 'instances[name=missing].memory');
	is $val, undef, 'lookup non-existent name returns undef';
};

subtest 'struct_lookup() - named element with key= and id=' => sub {
	my $struct = {
		items_by_key => [
			{ key => 'alpha', value => 'A' },
			{ key => 'beta', value => 'B' }
		],
		items_by_id => [
			{ id => '001', label => 'first' },
			{ id => '002', label => 'second' }
		]
	};

	# Lookup by key=
	my $val = struct_lookup($struct, 'items_by_key[key=alpha].value');
	is $val, 'A', 'lookup array element by key=value';

	$val = struct_lookup($struct, 'items_by_key[key=beta].value');
	is $val, 'B', 'lookup second element by key=value';

	# Lookup by id=
	$val = struct_lookup($struct, 'items_by_id[id=001].label');
	is $val, 'first', 'lookup array element by id=value';

	$val = struct_lookup($struct, 'items_by_id[id=002].label');
	is $val, 'second', 'lookup second element by id=value';
};

subtest 'struct_lookup() - implicit name/key/id lookup' => sub {
	# When no explicit key is given (e.g., [value] instead of [name=value]),
	# the code tries name, key, id in order
	my $struct = {
		by_name => [
			{ name => 'foo', data => 'name_data' }
		],
		by_key => [
			{ key => 'bar', data => 'key_data' }
		],
		by_id => [
			{ id => 'baz', data => 'id_data' }
		]
	};

	# Implicit lookup tries name first
	my $val = struct_lookup($struct, 'by_name[foo].data');
	is $val, 'name_data', 'implicit lookup finds by name';

	# Implicit lookup tries key
	$val = struct_lookup($struct, 'by_key[bar].data');
	is $val, 'key_data', 'implicit lookup finds by key';

	# Implicit lookup tries id
	$val = struct_lookup($struct, 'by_id[baz].data');
	is $val, 'id_data', 'implicit lookup finds by id';
};

subtest 'struct_lookup() - empty key returns whole structure' => sub {
	my $struct = { a => 1, b => 2 };

	my $val = struct_lookup($struct, '');
	is_deeply $val, { a => 1, b => 2 }, 'empty key returns entire structure';
};

# ============================================================================
# Coverage gap tests - struct_set_value edge cases
# ============================================================================

subtest 'struct_set_value() - nested array creation' => sub {
	my $struct = {};

	# Set deeply nested array value
	struct_set_value($struct, 'data[0].items[0]', 'first');
	is $struct->{data}[0]{items}[0], 'first', 'creates nested arrays as needed';

	struct_set_value($struct, 'data[0].items[1]', 'second');
	is $struct->{data}[0]{items}[1], 'second', 'adds to existing nested array';
};

# ============================================================================
# Literal dot escaping with .. syntax
# ============================================================================

subtest 'struct_lookup() - literal dot escaping with ..' => sub {
	# Keys with literal dots in their names require .. to escape
	my $struct = {
		"a.b" => "literal_dot_value",
		"a" => { "b" => "nested_value" },
		"x.y.z" => "multi_dot_key",
		"config" => {
			"db.host" => "localhost",
			"db" => { "host" => "remote" }
		}
	};

	# a..b should access key "a.b", not nested a->b
	my $val = struct_lookup($struct, 'a..b');
	is $val, 'literal_dot_value', 'a..b accesses literal key "a.b"';

	# a.b should access nested a->b
	$val = struct_lookup($struct, 'a.b');
	is $val, 'nested_value', 'a.b accesses nested path';

	# Multiple dots in key name
	$val = struct_lookup($struct, 'x..y..z');
	is $val, 'multi_dot_key', 'x..y..z accesses literal key "x.y.z"';

	# Nested path with literal dot key
	$val = struct_lookup($struct, 'config.db..host');
	is $val, 'localhost', 'config.db..host accesses config->{"db.host"}';

	# Contrast with nested path
	$val = struct_lookup($struct, 'config.db.host');
	is $val, 'remote', 'config.db.host accesses config->db->host';

	# List context returns original key with double dots
	my ($lval, $lkey) = struct_lookup($struct, 'a..b');
	is $lval, 'literal_dot_value', 'list context value correct for escaped dot';
	is $lkey, 'a..b', 'list context returns original key with double dots';
};

subtest 'struct_has() - literal dot escaping with ..' => sub {
	my $struct = {
		"a.b" => "value",
		"a" => { "b" => "nested" }
	};

	ok struct_has($struct, 'a..b'), 'struct_has finds literal key "a.b"';
	ok struct_has($struct, 'a.b'), 'struct_has finds nested a->b';
	ok !struct_has($struct, 'x..y'), 'struct_has returns false for missing literal dot key';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
