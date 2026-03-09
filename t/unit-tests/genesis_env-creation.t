#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use helper;
use Test::More;
use Test::Deep;
use Test::Exception;
use Test::Output;

use Genesis;
$Genesis::VERSION = '999.999.999'; # force dev mode for testing
use Genesis::Config;
$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");

use Genesis::Top;
use Genesis::Env;

# Disable color output for cleaner test output
local $ENV{NOCOLOR} = 1;

# Setup common test fixtures
my $top = make_top(name => 'simple', no_vault => 1);
$top->link_dev_kit('t/src/simple');

my $kit = $top->local_kit_version('dev');

subtest 'Genesis::Env->new() - basic constructor' => sub {
	# Test successful creation
	my $env;
	lives_ok {
		$env = Genesis::Env->new(
			name => 'test-env',
			top  => $top,
		);
	} 'new() creates environment object with valid parameters';

	isa_ok($env, 'Genesis::Env', 'returned object');
	is($env->name, 'test-env', 'environment name is set correctly');
	is($env->file, 'test-env.yml', 'file name is set correctly');
	is($env->top, $top, 'top is set correctly');
	ok(-d $env->{__tmp}, 'temporary work directory created');
};

subtest 'Genesis::Env->new() - name normalization' => sub {
	# Test .yml suffix stripping
	my $env;
	lives_ok {
		$env = Genesis::Env->new(
			name => 'prod.yml',
			top  => $top,
		);
	} 'new() accepts name with .yml suffix';

	is($env->name, 'prod', 'name has .yml suffix stripped');
	is($env->file, 'prod.yml', 'file still has .yml suffix');
};

subtest 'Genesis::Env->new() - parameter validation' => sub {
	# Test missing name parameter
	throws_ok {
		Genesis::Env->new(top => $top);
	} qr/No 'name' specified/ims, 'new() dies with bug() when name parameter is missing';

	# Test missing top parameter
	throws_ok {
		Genesis::Env->new(name => 'test');
	} qr/No 'top' specified/ims, 'new() dies with bug() when top parameter is missing';
};

subtest 'Genesis::Env->new() - environment name validation' => sub {
	# Test invalid names are rejected
	my @invalid_cases = (
		{
			name => 'Prod',
			pattern => qr/Bad environment name.*must start with.*lowercase.*letter/ims,
			desc => 'starts with uppercase',
		},
		{
			name => 'test-',
			pattern => qr/Bad environment name.*must not end with.*hyphen/ims,
			desc => 'ends with hyphen',
		},
		{
			name => 'my--env',
			pattern => qr/Bad environment name.*sequential hyphens/ims,
			desc => 'contains sequential hyphens',
		},
		{
			name => '_test',
			pattern => qr/Bad environment name.*must start with.*lowercase.*letter/ims,
			desc => 'starts with underscore',
		},
		{
			name => '123-env',
			pattern => qr/Bad environment name.*must start with.*lowercase.*letter/ims,
			desc => 'starts with number',
		},
	);

	foreach my $case (@invalid_cases) {
		throws_ok {
			Genesis::Env->new(
				name => $case->{name},
				top  => $top,
			);
		} $case->{pattern}, "new() rejects invalid name '$case->{name}' ($case->{desc})";
	}

	# Test valid names are accepted
	my @valid_names = qw(
		prod
		test-env
		my-env-123
		env_test
	);

	foreach my $valid_name (@valid_names) {
		my $env;
		lives_ok {
			$env = Genesis::Env->new(
				name => $valid_name,
				top  => $top,
			);
		} "new() accepts valid name '$valid_name'";
		is($env->name, $valid_name, "name is set to '$valid_name'");
	}
};

subtest 'Genesis::Env->new() - deployment type requirement' => sub {
	# Test defensive check for deployment type
	# Create a valid Top, then remove deployment type using Config API
	my $test_top = make_top(name => 'test-type', no_vault => 1);

	# Use Config::clear() to remove deployment_type
	# This simulates a corrupted or incomplete Top object
	$test_top->config->clear('deployment_type');

	throws_ok {
		Genesis::Env->new(
			name => 'test',
			top  => $test_top,
		);
	} qr/No deployment type specified/ims,
		'new() dies when Top object has no deployment type (defensive check)';
};

subtest 'Genesis::Env->create() - parameter validation' => sub {
	# Missing name
	throws_ok {
		Genesis::Env->create(
			top => $top,
			kit => $kit,
		);
	} qr/No 'name' specified/ims, 'create() dies with bug() when name is missing';

	# Missing top
	throws_ok {
		Genesis::Env->create(
			name => 'test',
			kit  => $kit,
		);
	} qr/No 'top' specified/ims, 'create() dies with bug() when top is missing';

	# Missing kit
	throws_ok {
		Genesis::Env->create(
			name => 'test',
			top  => $top,
		);
	} qr/No 'kit' specified/ims, 'create() dies with bug() when kit is missing';
};

subtest 'Genesis::Env->create() - prevents overwriting existing file' => sub {
	# Create an existing environment file
	put_file $top->path("existing.yml"), <<EOF;
---
genesis:
  env: existing
kit:
  name: dev
  version: latest
EOF

	# Try to create with same name
	throws_ok {
		Genesis::Env->create(
			name => 'existing',
			top  => $top,
			kit  => $kit,
		);
	} qr/Environment file.*already exists/ims, 'create() dies when environment file already exists';
};

subtest 'Genesis::Env->create() - smoke test for name validation' => sub {
	# Test that invalid names are rejected during create (via new())
	my @invalid_cases = (
		{
			name => 'Prod',
			pattern => qr/Bad environment name.*must start with.*lowercase.*letter/ims,
		},
		{
			name => 'test-',
			pattern => qr/Bad environment name.*must not end with.*hyphen/ims,
		},
		{
			name => 'my--env',
			pattern => qr/Bad environment name.*sequential hyphens/ims,
		},
	);

	foreach my $case (@invalid_cases) {
		throws_ok {
			Genesis::Env->create(
				name => $case->{name},
				top  => $top,
				kit  => $kit,
			);
		} $case->{pattern}, "create() rejects invalid name '$case->{name}' (via new())";
	}
};

# NOTE: Successful environment creation testing is not included in this unit test
# because Genesis::Env->create() requires vault operations (remove_secrets() at
# line 406) which cannot be mocked with no_vault => 1. Full create() workflow
# testing (file creation, content verification) belongs in integration tests.

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
