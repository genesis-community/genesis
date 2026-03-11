#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 't';
use helper;
use Test::More;
use Test::Deep;
use Test::Exception;
use Test::Output;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;

use_ok 'Genesis::UI';

# ---------------------------------------------------------------------------
# prompt_for_boolean - yes responses
# ---------------------------------------------------------------------------
subtest 'prompt_for_boolean - yes responses return true' => sub {
	my ($t, $f) = (JSON::PP::true, JSON::PP::false);

	for my $input (qw(y yes Y YES true True)) {
		set_stdin("$input\n");
		my $result;
		stderr_from { $result = prompt_for_boolean("Enable feature?", undef) };
		reset_stdin();
		is($result, $t, "'$input' returns JSON::PP::true");
	}

	# default 'y' + empty Enter returns true
	set_stdin("\n");
	my $result;
	stderr_from { $result = prompt_for_boolean("Enable feature?", "y") };
	reset_stdin();
	is($result, $t, "empty Enter with default 'y' returns JSON::PP::true");
};

# ---------------------------------------------------------------------------
# prompt_for_boolean - no responses
# ---------------------------------------------------------------------------
subtest 'prompt_for_boolean - no responses return false' => sub {
	my ($t, $f) = (JSON::PP::true, JSON::PP::false);

	for my $input (qw(n no N NO false False)) {
		set_stdin("$input\n");
		my $result;
		stderr_from { $result = prompt_for_boolean("Enable feature?", undef) };
		reset_stdin();
		is($result, $f, "'$input' returns JSON::PP::false");
	}

	# default 'n' + empty Enter returns false
	set_stdin("\n");
	my $result;
	stderr_from { $result = prompt_for_boolean("Enable feature?", "n") };
	reset_stdin();
	is($result, $f, "empty Enter with default 'n' returns JSON::PP::false");
};

# ---------------------------------------------------------------------------
# prompt_for_boolean - invert flag
# ---------------------------------------------------------------------------
subtest 'prompt_for_boolean - invert reverses y/n meanings' => sub {
	my ($t, $f) = (JSON::PP::true, JSON::PP::false);

	set_stdin("y\n");
	my $result;
	stderr_from { $result = prompt_for_boolean("Skip this?", undef, 1) };
	reset_stdin();
	is($result, $f, "invert=1: 'y' returns JSON::PP::false");

	set_stdin("n\n");
	stderr_from { $result = prompt_for_boolean("Skip this?", undef, 1) };
	reset_stdin();
	is($result, $t, "invert=1: 'n' returns JSON::PP::true");

	set_stdin("yes\n");
	stderr_from { $result = prompt_for_boolean("Skip this?", undef, 1) };
	reset_stdin();
	is($result, $f, "invert=1: 'yes' returns JSON::PP::false");

	set_stdin("no\n");
	stderr_from { $result = prompt_for_boolean("Skip this?", undef, 1) };
	reset_stdin();
	is($result, $t, "invert=1: 'no' returns JSON::PP::true");
};

# ---------------------------------------------------------------------------
# prompt_for_boolean - default normalization (numeric 0 / 1)
# ---------------------------------------------------------------------------
subtest 'prompt_for_boolean - numeric defaults are normalized' => sub {
	my ($t, $f) = (JSON::PP::true, JSON::PP::false);

	# numeric 0 normalizes to "n" -> default false on empty Enter
	set_stdin("\n");
	my $result;
	stderr_from { $result = prompt_for_boolean("Enable?", 0) };
	reset_stdin();
	is($result, $f, "numeric default 0 normalizes to 'n' -> false on Enter");

	# numeric 1 normalizes to "y" -> default true on empty Enter
	set_stdin("\n");
	stderr_from { $result = prompt_for_boolean("Enable?", 1) };
	reset_stdin();
	is($result, $t, "numeric default 1 normalizes to 'y' -> true on Enter");
};

# ---------------------------------------------------------------------------
# prompt_for_line - basic usage
# ---------------------------------------------------------------------------
subtest 'prompt_for_line - basic input and defaults' => sub {
	# Simple text input
	set_stdin("hello\n");
	my $result;
	stderr_from {
		$result = prompt_for_line("Enter text:", undef, undef, undef, undef);
	};
	reset_stdin();
	is($result, 'hello', "returns typed input");

	# Default applied on empty Enter
	set_stdin("\n");
	stderr_from {
		$result = prompt_for_line("Enter text:", undef, 'mydefault', undef, undef);
	};
	reset_stdin();
	is($result, 'mydefault', "empty Enter applies non-empty default");

	# Empty string default allows blank return
	set_stdin("\n");
	stderr_from {
		$result = prompt_for_line("Enter text:", undef, '', undef, undef);
	};
	reset_stdin();
	is($result, '', "empty string default allows blank input");

	# Explicit non-empty answer with a default present
	set_stdin("typed\n");
	stderr_from {
		$result = prompt_for_line("Enter text:", undef, 'ignored', undef, undef);
	};
	reset_stdin();
	is($result, 'typed', "typed value overrides default");
};

# ---------------------------------------------------------------------------
# prompt_for_line - ip validation
# ---------------------------------------------------------------------------
subtest 'prompt_for_line - ip validation' => sub {
	# Valid IP accepted immediately
	set_stdin("10.0.0.1\n");
	my $result;
	stderr_from {
		$result = prompt_for_line("IP:", undef, undef, 'ip', undef);
	};
	reset_stdin();
	is($result, '10.0.0.1', "valid IPv4 accepted");

	# Invalid then valid: consumes two lines
	set_stdin("999.999.999.999\n10.0.0.2\n");
	stderr_from {
		$result = prompt_for_line("IP:", undef, undef, 'ip', undef);
	};
	reset_stdin();
	is($result, '10.0.0.2', "invalid IP rejected, then valid IP accepted");

	# Zero-padded octets rejected
	set_stdin("010.0.0.1\n192.168.1.1\n");
	stderr_from {
		$result = prompt_for_line("IP:", undef, undef, 'ip', undef);
	};
	reset_stdin();
	is($result, '192.168.1.1', "zero-padded octet rejected, then valid IP accepted");

	# Boundary values
	set_stdin("255.255.255.255\n");
	stderr_from {
		$result = prompt_for_line("IP:", undef, undef, 'ip', undef);
	};
	reset_stdin();
	is($result, '255.255.255.255', "255.255.255.255 is valid");

	set_stdin("0.0.0.0\n");
	stderr_from {
		$result = prompt_for_line("IP:", undef, undef, 'ip', undef);
	};
	reset_stdin();
	is($result, '0.0.0.0', "0.0.0.0 is valid");
};

# ---------------------------------------------------------------------------
# prompt_for_line - bounded numeric validation
# ---------------------------------------------------------------------------
subtest 'prompt_for_line - bounded numeric validation' => sub {
	# "0-65535" range: valid value accepted, returned as number
	set_stdin("8080\n");
	my $result;
	stderr_from {
		$result = prompt_for_line("Port:", undef, undef, '0-65535', undef);
	};
	reset_stdin();
	is($result, 8080, "port 8080 accepted for '0-65535' validation");
	ok(($result == $result + 0), "returned value is numeric");

	# Out-of-range rejected, then valid accepted
	set_stdin("99999\n443\n");
	stderr_from {
		$result = prompt_for_line("Port:", undef, undef, '0-65535', undef);
	};
	reset_stdin();
	is($result, 443, "out-of-range port rejected, valid port accepted");

	# "1+" minimum: any value >= 1 accepted
	set_stdin("5\n");
	stderr_from {
		$result = prompt_for_line("Count:", undef, undef, '1+', undef);
	};
	reset_stdin();
	is($result, 5, "'1+' validation accepts 5");
	ok(($result == $result + 0), "returned value is numeric for '1+' validation");

	# Zero rejected by "1+", then valid accepted
	set_stdin("0\n1\n");
	stderr_from {
		$result = prompt_for_line("Count:", undef, undef, '1+', undef);
	};
	reset_stdin();
	is($result, 1, "0 rejected by '1+', 1 accepted");
};

# ---------------------------------------------------------------------------
# prompt_for_line - regex validation
# ---------------------------------------------------------------------------
subtest 'prompt_for_line - regex validation' => sub {
	# Matching pattern accepted
	set_stdin("abc123\n");
	my $result;
	stderr_from {
		$result = prompt_for_line("Enter:", undef, undef, '/^[a-z]+\d+$/i', undef);
	};
	reset_stdin();
	is($result, 'abc123', "value matching pattern accepted");

	# Non-matching pattern rejected, then valid accepted
	set_stdin("!!!\nabc123\n");
	stderr_from {
		$result = prompt_for_line("Enter:", undef, undef, '/^[a-z]+\d+$/i', undef);
	};
	reset_stdin();
	is($result, 'abc123', "non-matching value rejected, matching value accepted");

	# Case-insensitive flag
	set_stdin("ABC123\n");
	stderr_from {
		$result = prompt_for_line("Enter:", undef, undef, '/^[a-z]+\d+$/i', undef);
	};
	reset_stdin();
	is($result, 'ABC123', "case-insensitive regex flag works");

	# Negation: pattern must NOT match
	# "admin" matches /admin/i so it is REJECTED by !/admin/i
	# "bob" does not match /admin/i so it is accepted
	set_stdin("admin\nbob\n");
	stderr_from {
		$result = prompt_for_line("Username:", undef, undef, '!/admin/i', undef);
	};
	reset_stdin();
	is($result, 'bob', "negation pattern rejects matching input, accepts non-matching");
};

# ---------------------------------------------------------------------------
# prompt_for_line - list validation
# ---------------------------------------------------------------------------
subtest 'prompt_for_line - list and exclusion validation' => sub {
	my $result;

	# "b" is not in [alpha,beta,gamma] -> rejected; then "alpha" is accepted
	set_stdin("b\nalpha\n");
	stderr_from {
		$result = prompt_for_line("Pick:", undef, undef, '[alpha,beta,gamma]', undef);
	};
	reset_stdin();
	is($result, 'alpha', "invalid list item rejected, valid item accepted");

	set_stdin("beta\n");
	stderr_from {
		$result = prompt_for_line("Pick:", undef, undef, '[alpha,beta,gamma]', undef);
	};
	reset_stdin();
	is($result, 'beta', "valid list item 'beta' accepted directly");

	# ![a,b,c] exclusion list: must NOT be one of these
	# "root" is excluded -> rejected; "alice" is not excluded -> accepted
	set_stdin("root\nalice\n");
	stderr_from {
		$result = prompt_for_line("User:", undef, undef, '![root,admin,superuser]', undef);
	};
	reset_stdin();
	is($result, 'alice', "excluded value rejected, non-excluded value accepted");

	set_stdin("bob\n");
	stderr_from {
		$result = prompt_for_line("User:", undef, undef, '![root,admin,superuser]', undef);
	};
	reset_stdin();
	is($result, 'bob', "non-excluded value 'bob' accepted directly");
};

# ---------------------------------------------------------------------------
# prompt_for_block
# ---------------------------------------------------------------------------
subtest 'prompt_for_block - reads until EOF' => sub {
	set_stdin("line one\nline two\n");
	my $result;
	combined_from { $result = prompt_for_block("Enter text") };
	reset_stdin();
	like($result, qr/line one/, "captures first line");
	like($result, qr/line two/, "captures second line");

	# preserves newlines
	set_stdin("alpha\nbeta\ngamma\n");
	combined_from { $result = prompt_for_block("Enter block") };
	reset_stdin();
	is($result, "alpha\nbeta\ngamma\n", "preserves newlines in multi-line input");

	# single line
	set_stdin("only line\n");
	combined_from { $result = prompt_for_block("Enter block") };
	reset_stdin();
	is($result, "only line\n", "single line captured correctly");
};

done_testing;
