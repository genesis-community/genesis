#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::Deep;

# Test Genesis::Secret::UserProvided class
# User-provided secrets are entered interactively by the user

use_ok 'Genesis::Secret::UserProvided';

subtest 'constructor validation - valid definitions' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# Minimal valid definition
	my $simple = Genesis::Secret::UserProvided->new('path:key',
		prompt => 'Enter your password'
	);
	isa_ok($simple, 'Genesis::Secret::UserProvided');
	is($simple->get('prompt'), 'Enter your password', "prompt is stored");

	# With all optional fields
	my $full = Genesis::Secret::UserProvided->new('path:key',
		prompt => 'Enter secret',
		sensitive => 1,
		multiline => 1,
		subtype => 'certificate',
		fixed => 1
	);
	isa_ok($full, 'Genesis::Secret::UserProvided');
	is($full->get('sensitive'), 1, "sensitive stored");
	is($full->get('multiline'), 1, "multiline stored");
	is($full->get('subtype'), 'certificate', "subtype stored");
	is($full->get('fixed'), 1, "fixed stored");
};

subtest 'constructor validation - error cases' => sub {
	# Missing prompt - should return Invalid
	my $no_prompt = Genesis::Secret->build('userprovided', 'kit', 'path:key');
	isa_ok($no_prompt, 'Genesis::Secret::Invalid', "missing prompt returns Invalid");

	# Invalid option - should return Invalid
	my $bad_opt = Genesis::Secret->build('userprovided', 'kit', 'path:key',
		prompt => 'test', unknown_option => 'value'
	);
	isa_ok($bad_opt, 'Genesis::Secret::Invalid', "unknown option returns Invalid");
};

subtest 'build() type aliases' => sub {
	# Both 'userprovided' and 'user-provided' should work
	my $up1 = Genesis::Secret->build('userprovided', 'kit', 'path:key',
		prompt => 'Enter value'
	);
	isa_ok($up1, 'Genesis::Secret::UserProvided', "build('userprovided') works");

	my $up2 = Genesis::Secret->build('user-provided', 'kit', 'path:key',
		prompt => 'Enter value'
	);
	isa_ok($up2, 'Genesis::Secret::UserProvided', "build('user-provided') works");
};

subtest 'type and label' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::UserProvided->new('path:key', prompt => 'test');
	is($secret->type, 'userprovided', "type() returns 'userprovided'");
	is($secret->label, 'User-provided', "label() returns 'User-provided'");
};

subtest 'is_command_interactive' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::UserProvided->new('path:key', prompt => 'test');

	# add and rotate are interactive
	ok($secret->is_command_interactive('add'), "add is interactive");
	ok($secret->is_command_interactive('rotate'), "rotate is interactive");

	# remove is not interactive
	ok(!$secret->is_command_interactive('remove'), "remove is not interactive");

	# other actions are not interactive
	ok(!$secret->is_command_interactive('check'), "check is not interactive");
	ok(!$secret->is_command_interactive(''), "empty action is not interactive");
};

subtest 'describe()' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::UserProvided->new('path:key',
		prompt => 'Please enter your API key'
	);

	my $desc = $secret->describe;
	like($desc, qr/User-provided/i, "describe includes label");
	like($desc, qr/API key/i, "describe includes prompt text");

	# List context
	my @parts = $secret->describe;
	is($parts[0], 'path:key', "list context: first is path");
	like($parts[1], qr/User-provided/i, "list context: second is label");
};

subtest 'vault_operator' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::UserProvided->new('my/secret:apikey',
		prompt => 'Enter API key'
	);
	my $op = $secret->vault_operator;
	like($op, qr/vault/, "vault_operator contains 'vault'");
	like($op, qr/my\/secret:apikey/, "vault_operator contains path");
};

subtest 'inherits base class functionality' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::UserProvided->new('test/path:value',
		prompt => 'Test prompt',
		_feature => 'my-feature'
	);

	# Path accessor
	is($secret->path, 'test/path:value', "path() works");

	# Source tracking
	is($secret->source, 'kit', "source() works");
	ok($secret->from_kit, "from_kit() works");
	is($secret->feature, 'my-feature', "feature() works");

	# Definition accessors
	ok($secret->has('prompt'), "has() works");
	is($secret->get('prompt'), 'Test prompt', "get() works");
};

subtest 'value handling' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret::UserProvided->new('path:key',
		prompt => 'Enter value'
	);

	# No value initially
	ok(!$secret->has_value, "no value initially");

	# Set value
	$secret->set_value('user_entered_secret', in_sync => 1);
	ok($secret->has_value, "has_value after set");
	is($secret->value, 'user_entered_secret', "value returns stored value");

	# Reset
	$secret->reset;
	ok(!$secret->has_value, "no value after reset");
};

done_testing;
