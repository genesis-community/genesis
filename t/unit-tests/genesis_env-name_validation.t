#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use helper;
use Test::More;
use Test::Deep;
use Test::Exception;

use Genesis::Env;

subtest 'environment name validation - valid names' => sub {
	# All valid names should return empty string (no errors)
	my @valid_names = qw(
		a
		z
		prod
		dev
		staging
		dev-west
		us-east-1
		my-env-123
		env_test
		test_env_name
		multi-word-name
		env123
		test-123-prod
		a1b2c3
		long-environment-name-with-many-segments
		env_with_underscores
		env-with-hyphens
		mixed_env-name-123
	);

	foreach my $valid_name (@valid_names) {
		my $error = Genesis::Env::_env_name_errors($valid_name);
		is($error, '', "valid name '$valid_name' passes validation");
	}
};

subtest 'environment name validation - must start with lowercase letter' => sub {
	my @invalid_names = (
		['123-env',    'starts with number 123'],
		['9test',      'starts with single digit'],
		['0env',       'starts with zero'],
		['My-Env',     'starts with uppercase M'],
		['PROD',       'starts with uppercase P (all caps)'],
		['Prod',       'starts with uppercase P'],
		['Test',       'starts with uppercase T'],
		['_env',       'starts with underscore'],
		['_test',      'starts with underscore'],
		['-env',       'starts with hyphen'],
		['-test',      'starts with hyphen'],
	);

	foreach my $test (@invalid_names) {
		my ($name, $desc) = @$test;
		my $error = Genesis::Env::_env_name_errors($name);
		ok($error, "invalid name '$name' ($desc) produces error");
		like($error, qr/must start with.*lowercase.*letter/i,
			"error for '$name' mentions 'must start with lowercase letter'");
	}
};

subtest 'environment name validation - character restrictions' => sub {
	my @invalid_names = (
		['my env',      'contains space'],
		["my\tenv",     'contains tab'],
		["my\nenv",     'contains newline'],
		['My-Env',      'contains uppercase letters'],
		['PROD',        'all uppercase'],
		['tEsT',        'mixed case'],
		['env!',        'contains exclamation mark'],
		['test@prod',   'contains @ symbol'],
		['my.env',      'contains period'],
		['env#123',     'contains hash'],
		['test$var',    'contains dollar sign'],
		['env%20',      'contains percent'],
		['test&prod',   'contains ampersand'],
		['env*',        'contains asterisk'],
		['env+extra',   'contains plus'],
		['env=value',   'contains equals'],
		['env[0]',      'contains brackets'],
		['env{a}',      'contains braces'],
		['env|pipe',    'contains pipe'],
		['env\\slash',  'contains backslash'],
		['env:colon',   'contains colon'],
		['env;semi',    'contains semicolon'],
		["env'quote",   'contains single quote'],
		['env"quote',   'contains double quote'],
		['env<less',    'contains less-than'],
		['env>greater', 'contains greater-than'],
		['env?question', 'contains question mark'],
		['env/slash',   'contains forward slash'],
		['env,comma',   'contains comma'],
		['env~tilde',   'contains tilde'],
		['env`backtick', 'contains backtick'],
	);

	foreach my $test (@invalid_names) {
		my ($name, $desc) = @$test;
		my $error = Genesis::Env::_env_name_errors($name);
		ok($error, "invalid name '$name' ($desc) produces error");
		like($error, qr/lowercase letters.*numbers.*underscores.*hyphens|whitespace/i,
			"error for '$name' mentions character restrictions or whitespace");
	}
};

subtest 'environment name validation - must not end with hyphen' => sub {
	my @invalid_names = qw(
		env-
		test-
		my-env-
		prod-west-
		a-
	);

	foreach my $name (@invalid_names) {
		my $error = Genesis::Env::_env_name_errors($name);
		ok($error, "invalid name '$name' (ends with hyphen) produces error");
		like($error, qr/must not end with.*hyphen/i,
			"error for '$name' mentions 'must not end with hyphen'");
	}
};

subtest 'environment name validation - no sequential hyphens' => sub {
	my @invalid_names = qw(
		my--env
		test--prod
		a--b
		env--123
		multi--word--name
		test---prod
	);

	foreach my $name (@invalid_names) {
		my $error = Genesis::Env::_env_name_errors($name);
		ok($error, "invalid name '$name' (sequential hyphens) produces error");
		like($error, qr/must not contain sequential hyphens|'--'/i,
			"error for '$name' mentions sequential hyphens");
	}
};

subtest 'environment name validation - empty or whitespace' => sub {
	my @invalid_names = (
		['',           'empty string'],
		[' ',          'single space'],
		['  ',         'multiple spaces'],
		["\t",         'tab'],
		["\n",         'newline'],
		[" \t\n",      'mixed whitespace'],
	);

	foreach my $test (@invalid_names) {
		my ($name, $desc) = @$test;
		my $error = Genesis::Env::_env_name_errors($name);
		ok($error, "invalid name ($desc) produces error");
		like($error, qr/must not be empty|must not contain whitespace/i,
			"error for empty/whitespace mentions restriction");
	}
};

subtest 'environment name validation - multiple violations' => sub {
	# Names that violate multiple rules should return errors for all violations
	my @test_cases = (
		{
			name => 'My--Env-',
			desc => 'uppercase, sequential hyphens, ends with hyphen',
			patterns => [
				qr/lowercase letters.*numbers.*underscores.*hyphens/i,
				qr/sequential hyphens/i,
				qr/must not end with.*hyphen/i,
			],
		},
		{
			name => '123--test-',
			desc => 'starts with number, sequential hyphens, ends with hyphen',
			patterns => [
				qr/must start with.*lowercase.*letter/i,
				qr/sequential hyphens/i,
				qr/must not end with.*hyphen/i,
			],
		},
		{
			name => '_My Env-',
			desc => 'starts with underscore, uppercase, whitespace, ends with hyphen',
			patterns => [
				qr/must start with.*lowercase.*letter/i,
				qr/must not contain whitespace/i,
				qr/lowercase letters.*numbers.*underscores.*hyphens/i,
				qr/must not end with.*hyphen/i,
			],
		},
	);

	foreach my $test (@test_cases) {
		my $name = $test->{name};
		my $desc = $test->{desc};
		my $error = Genesis::Env::_env_name_errors($name);

		ok($error, "invalid name '$name' ($desc) produces error");

		# Check that error mentions all violations
		foreach my $pattern (@{$test->{patterns}}) {
			like($error, $pattern,
				"error for '$name' includes violation: " . $pattern);
		}
	}
};

subtest 'environment name validation - edge cases' => sub {
	# Single character names
	is(Genesis::Env::_env_name_errors('a'), '', 'single letter "a" is valid');
	is(Genesis::Env::_env_name_errors('z'), '', 'single letter "z" is valid');
	ok(Genesis::Env::_env_name_errors('1'), 'single digit "1" is invalid');
	ok(Genesis::Env::_env_name_errors('_'), 'single underscore is invalid');
	ok(Genesis::Env::_env_name_errors('-'), 'single hyphen is invalid');

	# Names with underscores (valid)
	is(Genesis::Env::_env_name_errors('env_name'), '', 'underscore in middle is valid');
	is(Genesis::Env::_env_name_errors('my_env_123'), '', 'multiple underscores are valid');
	is(Genesis::Env::_env_name_errors('env_'), '', 'ending with underscore is valid');

	# Mixed hyphens and underscores (valid)
	is(Genesis::Env::_env_name_errors('my-env_name'), '', 'mixed hyphens and underscores valid');
	is(Genesis::Env::_env_name_errors('env-123_test'), '', 'hyphens, underscores, numbers valid');

	# Very long names (valid as long as format is correct)
	my $long_name = 'very-long-environment-name-with-many-segments-for-testing';
	is(Genesis::Env::_env_name_errors($long_name), '', 'very long valid name passes');

	# Numbers in various positions (valid as long as not at start)
	is(Genesis::Env::_env_name_errors('env123'), '', 'ending with numbers is valid');
	is(Genesis::Env::_env_name_errors('env1test2'), '', 'numbers in middle are valid');
	is(Genesis::Env::_env_name_errors('a1b2c3'), '', 'alternating letters and numbers valid');
};

subtest 'environment name validation - undefined or reference input' => sub {
	# _env_name_errors should call bug() for undefined or reference inputs
	# These should die with a bug message, not return validation errors

	dies_ok {
		Genesis::Env::_env_name_errors(undef);
	} 'undefined name dies with bug()';

	dies_ok {
		Genesis::Env::_env_name_errors([]);
	} 'array reference dies with bug()';

	dies_ok {
		Genesis::Env::_env_name_errors({});
	} 'hash reference dies with bug()';

	dies_ok {
		Genesis::Env::_env_name_errors(sub {});
	} 'code reference dies with bug()';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
