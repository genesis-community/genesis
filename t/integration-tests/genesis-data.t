#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use helper;

use Test::More;
use Test::Deep;
use Test::Differences;
use Test::Exception;
use File::Temp qw/tempfile tempdir/;

use_ok 'Genesis';

my $tmp_dir = tempdir(CLEANUP => 1);

# Test load_yaml() - Load YAML from string
subtest 'load_yaml() - basic loading' => sub {
	my $yaml = <<'EOF';
---
simple: value
nested:
  key: nested_value
list:
  - one
  - two
  - three
EOF

	my $data = load_yaml($yaml);
	is ref($data), 'HASH', 'returns hash reference';
	is $data->{simple}, 'value', 'simple key correct';
	is $data->{nested}{key}, 'nested_value', 'nested key correct';
	is scalar(@{$data->{list}}), 3, 'list has 3 elements';
	is $data->{list}[0], 'one', 'list element correct';
};

subtest 'load_yaml() - complex structures' => sub {
	my $yaml = <<'EOF';
---
meta:
  name: test-deployment
  version: 1.0.0
params:
  network:
    - name: default
      static: [10.0.0.10-10.0.0.20]
    - name: public
      static: [192.168.1.10-192.168.1.20]
EOF

	my $data = load_yaml($yaml);
	is $data->{meta}{name}, 'test-deployment', 'nested string correct';
	is $data->{meta}{version}, '1.0.0', 'nested version correct';
	is scalar(@{$data->{params}{network}}), 2, 'array of hashes loaded';
	is $data->{params}{network}[0]{name}, 'default', 'array element hash key correct';
};

# Test load_yaml_file() - Load YAML from file
subtest 'load_yaml_file() - file loading' => sub {
	my ($fh, $filename) = tempfile(DIR => $tmp_dir, SUFFIX => '.yml');
	print $fh <<'EOF';
---
test: file_value
nested:
  deep: value
EOF
	close $fh;

	my $data = load_yaml_file($filename);
	is ref($data), 'HASH', 'returns hash reference';
	is $data->{test}, 'file_value', 'file value loaded';
	is $data->{nested}{deep}, 'value', 'nested file value loaded';

	unlink $filename;
};

subtest 'load_yaml_file() - error handling' => sub {
	# Non-existent file
	my ($data, $rc, $err) = load_yaml_file('/nonexistent/file.yml');
	isnt $rc, 0, 'non-existent file returns error code';
	ok !defined($data), 'non-existent file returns undef data';
};

# Test to_yaml() - Convert data to YAML string
subtest 'to_yaml() - basic conversion' => sub {
	my $data = {
		simple => 'value',
		number => 42
	};

	my $yaml = to_yaml($data);
	ok defined($yaml), 'returns YAML string';
	like $yaml, qr/simple:/, 'contains simple key';
	like $yaml, qr/value/, 'contains simple value';
	like $yaml, qr/number:/, 'contains number key';
	like $yaml, qr/42/, 'contains number value';
};

subtest 'to_yaml() - nested structures' => sub {
	my $data = {
		top => {
			middle => {
				bottom => 'deep_value'
			}
		}
	};

	my $yaml = to_yaml($data);
	like $yaml, qr/top:/, 'contains top key';
	like $yaml, qr/middle:/, 'contains middle key';
	like $yaml, qr/bottom:/, 'contains bottom key';
	like $yaml, qr/deep_value/, 'contains deep value';
};

subtest 'to_yaml() - arrays' => sub {
	my $data = {
		list => ['one', 'two', 'three']
	};

	my $yaml = to_yaml($data);
	like $yaml, qr/list:/, 'contains list key';
	like $yaml, qr/one/, 'contains first element';
	like $yaml, qr/two/, 'contains second element';
	like $yaml, qr/three/, 'contains third element';
};

# Test save_to_yaml_file() - Save data to YAML file
subtest 'save_to_yaml_file() - file saving' => sub {
	my $data = {
		test => 'yaml_save',
		nested => {
			key => 'value'
		}
	};

	my ($fh, $filename) = tempfile(DIR => $tmp_dir, SUFFIX => '.yml');
	close $fh;

	save_to_yaml_file($data, $filename);
	ok -f $filename, 'file created';

	# Verify by loading it back
	my $loaded = load_yaml_file($filename);
	is $loaded->{test}, 'yaml_save', 'saved value correct';
	is $loaded->{nested}{key}, 'value', 'saved nested value correct';

	unlink $filename;
};

# Test load_json() - Load JSON from string
subtest 'load_json() - basic loading' => sub {
	my $json = '{"key":"value","number":42}';
	my $data = load_json($json);

	is ref($data), 'HASH', 'returns hash reference';
	is $data->{key}, 'value', 'string value correct';
	is $data->{number}, 42, 'number value correct';
};

subtest 'load_json() - nested structures' => sub {
	my $json = '{"top":{"middle":{"bottom":"deep"}}}';
	my $data = load_json($json);

	is $data->{top}{middle}{bottom}, 'deep', 'nested value correct';
};

# Test load_json_file() - Load JSON from file
subtest 'load_json_file() - file loading' => sub {
	my ($fh, $filename) = tempfile(DIR => $tmp_dir, SUFFIX => '.json');
	print $fh '{"test":"json_file","nested":{"key":"value"}}';
	close $fh;

	my $data = load_json_file($filename);
	is ref($data), 'HASH', 'returns hash reference';
	is $data->{test}, 'json_file', 'file value loaded';
	is $data->{nested}{key}, 'value', 'nested file value loaded';

	unlink $filename;
};

# Test save_to_json_file() - Save data to JSON file
subtest 'save_to_json_file() - file saving' => sub {
	my $data = {
		test => 'json_save',
		nested => {
			key => 'value'
		}
	};

	my ($fh, $filename) = tempfile(DIR => $tmp_dir, SUFFIX => '.json');
	close $fh;

	save_to_json_file($data, $filename);
	ok -f $filename, 'file created';

	# Verify by loading it back
	my $loaded = load_json_file($filename);
	is $loaded->{test}, 'json_save', 'saved value correct';
	is $loaded->{nested}{key}, 'value', 'saved nested value correct';

	unlink $filename;
};

# Test read_json_from() - Parse JSON from run() output
subtest 'read_json_from() - parsing run output' => sub {
	my $json_output = '{"status":"success","value":42}';
	my $data = read_json_from($json_output, 0, '');

	is ref($data), 'HASH', 'returns hash reference';
	is $data->{status}, 'success', 'status correct';
	is $data->{value}, 42, 'value correct';
};

subtest 'read_json_from() - error handling' => sub {
	# Invalid JSON
	throws_ok {
		read_json_from('not valid json', 0, '');
	} qr//, 'invalid JSON throws error';

	# Non-zero exit code
	my ($data, $rc, $err) = read_json_from('{}', 1, 'command failed');
	is $rc, 1, 'error code preserved';
	is $err, 'command failed', 'error message preserved';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
