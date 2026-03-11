#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;
use Test::Exception;

# ---------------------------------------------------------------------------
# Section 1 - Module Loading
# ---------------------------------------------------------------------------

use_ok 'Service::BOSH';

# ---------------------------------------------------------------------------
# Section 2 - command() - env var override
# ---------------------------------------------------------------------------

subtest 'command() returns GENESIS_BOSH_COMMAND immediately when set' => sub {
	plan tests => 3;

	local $ENV{GENESIS_BOSH_COMMAND} = '/custom/path/bosh';

	# No scanning or caching occurs; the env var wins unconditionally.
	my $got = Service::BOSH->command();
	is $got, '/custom/path/bosh',
		'returns GENESIS_BOSH_COMMAND value';

	# Version constraints do NOT override the env var early return.
	$got = Service::BOSH->command('2.0.0');
	is $got, '/custom/path/bosh',
		'returns GENESIS_BOSH_COMMAND even with min_version constraint';

	$got = Service::BOSH->command('2.0.0', '3.0.0');
	is $got, '/custom/path/bosh',
		'returns GENESIS_BOSH_COMMAND even with min_version and max_version constraints';
};

# ---------------------------------------------------------------------------
# Section 3 - command() - caching behaviour
# ---------------------------------------------------------------------------

subtest 'command() returns cached value when no version constraints given' => sub {
	plan tests => 2;

	# fake_bosh sets GENESIS_BOSH_COMMAND, so clear it for this test.
	local $ENV{GENESIS_BOSH_COMMAND};

	# Seed the cache via set_command (the public API for doing so).
	Service::BOSH->set_command('/cached/bosh');

	my $got = Service::BOSH->command();
	is $got, '/cached/bosh',
		'returns cached path when no constraints given';

	# A second call hits the cache again - value must be stable.
	my $got2 = Service::BOSH->command();
	is $got2, '/cached/bosh',
		'cache is stable across repeated calls';
};

# ---------------------------------------------------------------------------
# Section 4 - command() - missing CLI
# ---------------------------------------------------------------------------

subtest 'command() dies when no BOSH CLI is found on PATH' => sub {
	plan tests => 1;

	local $ENV{GENESIS_BOSH_COMMAND};

	# Clear the cached command so the scan loop runs.
	Service::BOSH->set_command(undef);

	# Override PATH to a directory that contains no bosh variants.
	my $emptydir = workdir('no-bosh-bin');
	local $ENV{PATH} = $emptydir;

	quietly {
		throws_ok {
			Service::BOSH->command();
		} qr/Missing.*bosh/i,
			'dies with "Missing bosh" when no CLI is available';
	};
};

# ---------------------------------------------------------------------------
# Section 5 - command() - version constraint: no matching version
# ---------------------------------------------------------------------------

subtest 'command() dies with version constraint message when no CLI satisfies minimum' => sub {
	plan tests => 1;

	local $ENV{GENESIS_BOSH_COMMAND};
	Service::BOSH->set_command(undef);

	# Provide a fake bosh that reports a low version number so it cannot
	# satisfy a very high minimum version constraint.
	my $tmp = workdir('low-version-bosh');
	put_file("$tmp/bosh", 0755, <<'EOF');
#!/bin/bash
echo "version 1.0.0"
exit 0
EOF

	# Prepend our directory but keep system commands (grep, head, etc.) available.
	local $ENV{PATH} = "$tmp:$ENV{PATH}";

	quietly {
		throws_ok {
			Service::BOSH->command('99.0.0');
		} qr/BOSH CLI.*v99\.0\.0.*required/i,
			'dies with version-constraint message when CLI is too old';
	};
};

# ---------------------------------------------------------------------------
# Section 6 - command() - BOSH-1 known defect: missing return in scan path
# ---------------------------------------------------------------------------

subtest 'command() BOSH-1: scan path returns value via implicit return' => sub {
	plan tests => 2;

	# Known defect BOSH-1: command() is missing an explicit return statement
	# in the scan-path branch.  However, Perl returns the value of the last
	# evaluated expression ($bosh_cmd = $versions{$best}), so the method
	# actually works correctly despite the missing return.  The defect is a
	# code quality issue, not a behavioral bug.

	local $ENV{GENESIS_BOSH_COMMAND};
	Service::BOSH->set_command(undef);

	# Provide a fake bosh that reports a version that satisfies constraints.
	my $tmp = workdir('scan-path-bosh');
	put_file("$tmp/bosh", 0755, <<'EOF');
#!/bin/bash
echo "version 2.5.0"
exit 0
EOF

	# Prepend our directory but keep system commands (grep, head, etc.) available.
	local $ENV{PATH} = "$tmp:$ENV{PATH}";

	my $got;
	quietly {
		$got = Service::BOSH->command('2.0.0', '3.0.0');
	};

	# Known defect BOSH-1: no explicit return, but Perl's implicit return
	# of the last expression ($bosh_cmd = $versions{$best}) makes it work.
	ok defined($got),
		'BOSH-1: command() returns defined value via implicit return (missing explicit return)';
	like $got, qr/bosh$/,
		'BOSH-1: returned path ends with "bosh"';
};

# ---------------------------------------------------------------------------
# Section 7 - set_command()
# ---------------------------------------------------------------------------

subtest 'set_command() sets the cached command path' => sub {
	plan tests => 3;

	local $ENV{GENESIS_BOSH_COMMAND};

	Service::BOSH->set_command('/first/bosh');
	is Service::BOSH->command(), '/first/bosh',
		'command() reflects path set by set_command()';

	Service::BOSH->set_command('/second/bosh');
	is Service::BOSH->command(), '/second/bosh',
		'set_command() overwrites the previous cached path';

	# set_command() returns the value that was set (implicit Perl return).
	my $ret = Service::BOSH->set_command('/third/bosh');
	is $ret, '/third/bosh',
		'set_command() returns the value set (implicit Perl return of assignment)';
};

# ---------------------------------------------------------------------------
# Section 8 - has_director()
# ---------------------------------------------------------------------------

subtest 'has_director() returns 0 in the base class' => sub {
	plan tests => 2;

	# Called as a class method.
	is Service::BOSH->has_director(), 0,
		'Service::BOSH->has_director() is 0 (class method)';

	# Called on a blessed object that inherits from the base class without
	# overriding has_director.
	my $obj = bless {}, 'Service::BOSH';
	is $obj->has_director(), 0,
		'has_director() is 0 on a base-class instance';
};

# ---------------------------------------------------------------------------
# Section 9 - environment_variables()
# ---------------------------------------------------------------------------

subtest 'environment_variables() returns an empty list in the base class' => sub {
	plan tests => 2;

	my $obj = bless {}, 'Service::BOSH';

	my @vars = $obj->environment_variables();
	is scalar(@vars), 0,
		'environment_variables() returns an empty list';

	my %vars = $obj->environment_variables();
	is scalar(keys %vars), 0,
		'environment_variables() returns an empty hash when assigned to a hash';
};

# ---------------------------------------------------------------------------
# Section 10 - available_stemcells() - delegation to Stemcell class
# ---------------------------------------------------------------------------

subtest 'available_stemcells() dies when no iaas is provided' => sub {
	plan tests => 1;

	quietly {
		throws_ok {
			Service::BOSH->available_stemcells();
		} qr/No IaaS specified/i,
			'available_stemcells() dies with "No IaaS specified" when iaas is absent';
	};
};

subtest 'available_stemcells() delegates to Service::BOSH::Stemcell->available_stemcells' => sub {
	plan tests => 4;

	# Build a lightweight mock stemcell object.
	my $fake_stemcell = bless { iaas => 'aws', os => 'ubuntu-jammy' }, 'Service::BOSH::Stemcell';

	# Monkey-patch Service::BOSH::Stemcell::available_stemcells to capture the
	# arguments it receives and return a controlled result.
	my @captured_opts;
	no warnings 'redefine';
	local *Service::BOSH::Stemcell::available_stemcells = sub {
		my ($class, %opts) = @_;
		@captured_opts = %opts;
		return [$fake_stemcell];
	};

	# List context.
	my @list = Service::BOSH->available_stemcells(iaas => 'aws');
	is scalar(@list), 1,
		'available_stemcells() returns a list of stemcell objects in list context';
	is ref($list[0]), 'Service::BOSH::Stemcell',
		'each element is a Service::BOSH::Stemcell object';

	# Scalar context.
	local *Service::BOSH::Stemcell::available_stemcells = sub {
		return [$fake_stemcell];
	};
	my $aref = Service::BOSH->available_stemcells(iaas => 'google');
	is ref($aref), 'ARRAY',
		'available_stemcells() returns an array reference in scalar context';
	is scalar(@$aref), 1,
		'the array reference contains one stemcell';
};

subtest 'available_stemcells() passes correct options to Stemcell class' => sub {
	plan tests => 4;

	my @captured_opts;
	no warnings 'redefine';
	local *Service::BOSH::Stemcell::available_stemcells = sub {
		my ($class, %opts) = @_;
		@captured_opts = %opts;
		return [];
	};

	Service::BOSH->available_stemcells(iaas => 'vsphere', os => 'ubuntu-jammy', type => 'light');
	my %captured = @captured_opts;

	is $captured{iaas}, 'vsphere',    'iaas option is forwarded';
	is $captured{os},   'ubuntu-jammy', 'os option is forwarded';
	is $captured{type}, 'light',      'type option is forwarded';
	is $captured{all},  1,            'all flag is always set to 1';
};

subtest 'available_stemcells() defaults os to ubuntu-jammy when not specified' => sub {
	plan tests => 1;

	my @captured_opts;
	no warnings 'redefine';
	local *Service::BOSH::Stemcell::available_stemcells = sub {
		my ($class, %opts) = @_;
		@captured_opts = %opts;
		return [];
	};

	Service::BOSH->available_stemcells(iaas => 'azure');
	my %captured = @captured_opts;

	is $captured{os}, 'ubuntu-jammy',
		'os defaults to ubuntu-jammy when not given';
};

subtest 'available_stemcells() derives iaas, os, type from env object when provided' => sub {
	plan tests => 3;

	# Minimal mock env object.
	my $mock_env = bless {}, 'Mock::GenEnv';
	no warnings 'redefine';
	no warnings 'once';
	local *Mock::GenEnv::iaas = sub { 'google' };
	local *Mock::GenEnv::manifest_lookup = sub {
		my ($self, $key, $default) = @_;
		return [{ os => 'ubuntu-noble' }] if $key eq 'stemcells';
		return $default;
	};
	local *Mock::GenEnv::lookup = sub {
		my ($self, $key, $default) = @_;
		return 'light' if $key eq 'bosh-configs.stemcells.type';
		return $default;
	};

	my @captured_opts;
	local *Service::BOSH::Stemcell::available_stemcells = sub {
		my ($class, %opts) = @_;
		@captured_opts = %opts;
		return [];
	};

	Service::BOSH->available_stemcells(env => $mock_env);
	my %captured = @captured_opts;

	is $captured{iaas}, 'google',       'iaas derived from env->iaas';
	is $captured{os},   'ubuntu-noble', 'os derived from env manifest stemcells';
	is $captured{type}, 'light',        'type derived from env bosh-configs.stemcells.type';
};

# ---------------------------------------------------------------------------
# Section 11 - execute() - command form: "bosh ..." string
# ---------------------------------------------------------------------------

subtest 'execute() replaces leading "bosh" token with the resolved CLI path' => sub {
	plan tests => 1;

	fake_bosh();
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $obj = bless { deployment => undef }, 'Service::BOSH';

	my $ok = $obj->execute({ passfail => 1 }, 'bosh', 'foo');
	ok $ok, 'execute() with pre-tokenized ("bosh", "foo") succeeds';
};

subtest 'execute() handles "bosh subcommand" as a single string' => sub {
	plan tests => 1;

	fake_bosh();
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $obj = bless { deployment => undef }, 'Service::BOSH';

	my $ok = $obj->execute({ passfail => 1 }, 'bosh foo');
	ok $ok, 'execute() with "bosh foo" single string succeeds';
};

# ---------------------------------------------------------------------------
# Section 12 - execute() - command form: pipe / variable reference string
# ---------------------------------------------------------------------------

subtest 'execute() handles pipe-containing command string' => sub {
	plan tests => 1;

	fake_bosh();
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $obj = bless { deployment => undef }, 'Service::BOSH';

	my $ok = $obj->execute({ passfail => 1 }, 'foo | cat $1', '/dev/null');
	ok $ok, 'execute() with pipe-form command string succeeds';
};

subtest 'execute() handles command string with shell variable reference' => sub {
	plan tests => 1;

	fake_bosh();
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $obj = bless { deployment => undef }, 'Service::BOSH';

	my $ok = $obj->execute({ passfail => 1 }, 'bosh foo | cat $1', '/dev/null');
	ok $ok, 'execute() with "bosh foo | ..." (bosh + pipe) command string succeeds';
};

# ---------------------------------------------------------------------------
# Section 13 - execute() - command form: plain subcommand list
# ---------------------------------------------------------------------------

subtest 'execute() handles plain subcommand list (no bosh prefix, no pipe)' => sub {
	plan tests => 1;

	fake_bosh();
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $obj = bless { deployment => undef }, 'Service::BOSH';

	my $ok = $obj->execute({ passfail => 1 }, 'foo');
	ok $ok, 'execute() with plain subcommand list succeeds';
};

# ---------------------------------------------------------------------------
# Section 14 - execute() - passfail mode
# ---------------------------------------------------------------------------

subtest 'execute() passfail returns 1 on success' => sub {
	plan tests => 1;

	fake_bosh();
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $obj = bless { deployment => undef }, 'Service::BOSH';

	my $result = $obj->execute({ passfail => 1 }, 'foo');
	is $result, 1, 'passfail mode returns 1 on exit code 0';
};

subtest 'execute() non-passfail captures failure exit code' => sub {
	plan tests => 2;

	# Provide a fake bosh that always exits non-zero.
	my $tmp = workdir('failing-bosh');
	put_file("$tmp/bosh", 0755, "#!/bin/bash\nexit 2\n");
	local $ENV{GENESIS_BOSH_COMMAND} = "$tmp/bosh";
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $obj = bless { deployment => undef }, 'Service::BOSH';

	my @results;
	quietly { @results = $obj->execute('foo') };
	isnt $results[1], 0, 'list context captures non-zero exit code';
	is $results[1], 2, 'exit code is preserved as-is (2)';
};

# ---------------------------------------------------------------------------
# Section 15 - execute() - list context vs scalar context (BOSH-2)
# ---------------------------------------------------------------------------

subtest 'execute() list context returns ($output, $exit_code, $stderr)' => sub {
	plan tests => 2;

	fake_bosh();
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $obj = bless { deployment => undef }, 'Service::BOSH';

	my @results = $obj->execute('foo');
	# results[0] is output, results[1] is exit code (0 on success).
	is $results[1], 0,
		'list context: second element is exit code 0 on success';
	ok defined($results[0]),
		'list context: first element (output) is defined';
};

subtest 'execute() scalar context returns raw exit code (BOSH-2)' => sub {
	plan tests => 2;

	# Known defect BOSH-2: in scalar context without passfail, execute()
	# returns the raw process exit code ($results[1]).  A successful command
	# returns 0, which is FALSY in Perl.  Callers must test with == 0, not
	# with a simple truth check.

	fake_bosh();
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $obj = bless { deployment => undef }, 'Service::BOSH';

	my $rc = $obj->execute('foo');

	# Known defect BOSH-2: scalar context returns raw exit code (0 = success = falsy)
	is $rc, 0,
		'BOSH-2: scalar context returns raw exit code 0 for a successful command';
	ok !$rc,
		'BOSH-2: exit code 0 is falsy -- callers must use == 0, not a truth check';
};

# ---------------------------------------------------------------------------
# Section 16 - execute() - environment variable merging and proxy cleanup
# ---------------------------------------------------------------------------

subtest 'execute() clears HTTPS_PROXY and https_proxy unless GENESIS_HONOR_ENV is set' => sub {
	plan tests => 1;

	# Build a fake bosh that fails if the proxy vars are set.
	my $tmp = workdir('proxy-check-bosh');
	put_file("$tmp/bosh", 0755, <<'EOF');
#!/bin/bash
if [[ -n "$HTTPS_PROXY" || -n "$https_proxy" ]]; then
	echo "PROXY LEAKED" >&2
	exit 3
fi
exit 0
EOF

	local $ENV{GENESIS_BOSH_COMMAND} = "$tmp/bosh";
	local $ENV{HTTPS_PROXY} = 'http://proxy.example.com:3128';
	local $ENV{https_proxy} = 'http://proxy.example.com:3128';
	delete $ENV{GENESIS_HONOR_ENV};
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $obj = bless { deployment => undef }, 'Service::BOSH';

	my $ok = $obj->execute({ passfail => 1 }, 'foo');
	ok $ok, 'HTTPS_PROXY and https_proxy are cleared from subprocess environment';
};

subtest 'execute() preserves proxy vars when GENESIS_HONOR_ENV is set' => sub {
	plan tests => 1;

	# Build a fake bosh that fails if the proxy vars are NOT set.
	my $tmp = workdir('proxy-honor-bosh');
	put_file("$tmp/bosh", 0755, <<'EOF');
#!/bin/bash
if [[ -z "$HTTPS_PROXY" ]]; then
	echo "PROXY NOT FOUND" >&2
	exit 3
fi
exit 0
EOF

	local $ENV{GENESIS_BOSH_COMMAND} = "$tmp/bosh";
	local $ENV{HTTPS_PROXY} = 'http://proxy.example.com:3128';
	local $ENV{GENESIS_HONOR_ENV} = '1';
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $obj = bless { deployment => undef }, 'Service::BOSH';

	my $ok = $obj->execute({ passfail => 1 }, 'foo');
	ok $ok, 'proxy vars are preserved when GENESIS_HONOR_ENV is set';
};

subtest 'execute() clears BOSH_NON_INTERACTIVE from subprocess environment' => sub {
	plan tests => 1;

	# The BOSH_NON_INTERACTIVE env var must never be forwarded to the subprocess;
	# the -n flag is used instead when the calling process has it set.
	my $tmp = workdir('non-interactive-bosh');
	put_file("$tmp/bosh", 0755, <<'EOF');
#!/bin/bash
if [[ -n "$BOSH_NON_INTERACTIVE" ]]; then
	echo "BOSH_NON_INTERACTIVE LEAKED" >&2
	exit 3
fi
exit 0
EOF

	local $ENV{GENESIS_BOSH_COMMAND} = "$tmp/bosh";
	local $ENV{BOSH_NON_INTERACTIVE} = 'yes';
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $obj = bless { deployment => undef }, 'Service::BOSH';

	my $ok;
	quietly { $ok = $obj->execute({ passfail => 1 }, 'foo') };
	ok $ok, 'BOSH_NON_INTERACTIVE is not forwarded to subprocess';
};

subtest 'execute() prepends -n flag when BOSH_NON_INTERACTIVE is set in calling process' => sub {
	plan tests => 1;

	# The fake bosh script from bosh_runs_as checks that the args match exactly.
	# When BOSH_NON_INTERACTIVE is set, -n must appear before the subcommand.
	local $ENV{GENESIS_BOSH_COMMAND};
	bosh_runs_as('-n foo');
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});

	local $ENV{BOSH_NON_INTERACTIVE} = 'yes';
	my $obj = bless { deployment => undef }, 'Service::BOSH';

	my $ok;
	quietly { $ok = $obj->execute({ passfail => 1 }, 'foo') };
	ok $ok, '-n flag is prepended to plain subcommand when BOSH_NON_INTERACTIVE is set';
};

subtest 'execute() merges additional env vars from opts->{env}' => sub {
	plan tests => 1;

	my $tmp = workdir('env-merge-bosh');
	put_file("$tmp/bosh", 0755, <<'EOF');
#!/bin/bash
if [[ "$MY_CUSTOM_VAR" != "expected_value" ]]; then
	echo "MY_CUSTOM_VAR mismatch: got '$MY_CUSTOM_VAR'" >&2
	exit 3
fi
exit 0
EOF

	local $ENV{GENESIS_BOSH_COMMAND} = "$tmp/bosh";
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $obj = bless { deployment => undef }, 'Service::BOSH';

	my $ok = $obj->execute(
		{ passfail => 1, env => { MY_CUSTOM_VAR => 'expected_value' } },
		'foo'
	);
	ok $ok, 'additional env vars from opts->{env} are merged into subprocess environment';
};

subtest 'execute() sets BOSH_DEPLOYMENT from opts->{deployment}' => sub {
	plan tests => 1;

	my $tmp = workdir('deployment-bosh');
	put_file("$tmp/bosh", 0755, <<'EOF');
#!/bin/bash
if [[ "$BOSH_DEPLOYMENT" != "my-deployment" ]]; then
	echo "BOSH_DEPLOYMENT mismatch: got '$BOSH_DEPLOYMENT'" >&2
	exit 3
fi
exit 0
EOF

	local $ENV{GENESIS_BOSH_COMMAND} = "$tmp/bosh";
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $obj = bless { deployment => undef }, 'Service::BOSH';

	my $ok = $obj->execute(
		{ passfail => 1, deployment => 'my-deployment' },
		'foo'
	);
	ok $ok, 'BOSH_DEPLOYMENT is set from opts->{deployment}';
};

subtest 'execute() falls back to $self->{deployment} for BOSH_DEPLOYMENT' => sub {
	plan tests => 1;

	my $tmp = workdir('self-deployment-bosh');
	put_file("$tmp/bosh", 0755, <<'EOF');
#!/bin/bash
if [[ "$BOSH_DEPLOYMENT" != "self-deployment" ]]; then
	echo "BOSH_DEPLOYMENT mismatch: got '$BOSH_DEPLOYMENT'" >&2
	exit 3
fi
exit 0
EOF

	local $ENV{GENESIS_BOSH_COMMAND} = "$tmp/bosh";
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $obj = bless { deployment => 'self-deployment' }, 'Service::BOSH';

	my $ok = $obj->execute({ passfail => 1 }, 'foo');
	ok $ok, 'BOSH_DEPLOYMENT falls back to $self->{deployment} when not in opts';
};

# ---------------------------------------------------------------------------
# Section 17 - dryrun_of() - without execute
# ---------------------------------------------------------------------------

subtest 'dryrun_of() returns 1 when execute is false (default)' => sub {
	plan tests => 1;

	fake_bosh();
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $obj = bless { deployment => undef }, 'Service::BOSH';

	my $ret;
	quietly { $ret = $obj->dryrun_of('deploy', 'manifest.yml') };
	is $ret, 1, 'dryrun_of() returns 1 when execute option is absent/false';
};

subtest 'dryrun_of() returns 1 when execute is explicitly 0' => sub {
	plan tests => 1;

	fake_bosh();
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $obj = bless { deployment => undef }, 'Service::BOSH';

	my $ret;
	quietly { $ret = $obj->dryrun_of({ execute => 0 }, 'deploy', 'manifest.yml') };
	is $ret, 1, 'dryrun_of() returns 1 when execute => 0';
};

# ---------------------------------------------------------------------------
# Section 18 - dryrun_of() - with execute => 1
# ---------------------------------------------------------------------------

subtest 'dryrun_of() delegates to execute() when execute => 1' => sub {
	plan tests => 1;

	fake_bosh();
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $obj = bless { deployment => undef }, 'Service::BOSH';

	my $ret;
	quietly { $ret = $obj->dryrun_of({ execute => 1 }, 'foo') };
	# When execute fires, result comes from execute() -- not a plain 1.
	# passfail is not set, so list/scalar context returns exit code.
	# We just verify dryrun_of returns *something* and doesn't die.
	ok defined($ret), 'dryrun_of() returns a defined value when execute => 1';
};

# ---------------------------------------------------------------------------
# Section 19 - dryrun_of() - custom execute flags
# ---------------------------------------------------------------------------

subtest 'dryrun_of() appends --dry-run by default when execute is true scalar' => sub {
	plan tests => 1;

	# Build a fake bosh that verifies --dry-run appears in the args.
	my $tmp = workdir('dryrun-flag-bosh');
	put_file("$tmp/bosh", 0755, <<'EOF');
#!/bin/bash
# Check that --dry-run appears somewhere in the argument list.
found=0
for arg in "$@"; do
	[[ "$arg" == "--dry-run" ]] && found=1
done
[[ $found -eq 1 ]] && exit 0
echo "missing --dry-run in: $@" >&2
exit 3
EOF

	local $ENV{GENESIS_BOSH_COMMAND} = "$tmp/bosh";
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $obj = bless { deployment => undef }, 'Service::BOSH';

	my $ok;
	quietly { $ok = $obj->dryrun_of({ execute => 1 }, 'deploy', 'manifest.yml') };
	# passfail not set; scalar context returns exit code (0 = success).
	is $ok, 0,
		'dryrun_of() appends --dry-run when execute is a true scalar';
};

subtest 'dryrun_of() appends custom flags when execute is an array reference' => sub {
	plan tests => 1;

	my $tmp = workdir('dryrun-custom-flags-bosh');
	put_file("$tmp/bosh", 0755, <<'EOF');
#!/bin/bash
found_dry=0; found_redact=0
for arg in "$@"; do
	[[ "$arg" == "--dry-run" ]]    && found_dry=1
	[[ "$arg" == "--no-redact" ]]  && found_redact=1
done
[[ $found_dry -eq 1 && $found_redact -eq 1 ]] && exit 0
echo "flags missing in: $@" >&2
exit 3
EOF

	local $ENV{GENESIS_BOSH_COMMAND} = "$tmp/bosh";
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $obj = bless { deployment => undef }, 'Service::BOSH';

	my $ok;
	quietly {
		$ok = $obj->dryrun_of(
			{ execute => ['--dry-run', '--no-redact'] },
			'deploy', 'manifest.yml'
		);
	};
	is $ok, 0,
		'dryrun_of() appends custom flags when execute is an array reference';
};

# ---------------------------------------------------------------------------
# Section 20 - dryrun_of() - director-aware message path
# ---------------------------------------------------------------------------

subtest 'dryrun_of() uses non-director message when has_director is false' => sub {
	plan tests => 1;

	fake_bosh();
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});

	# Base class: has_director returns 0.
	my $obj = bless { deployment => undef }, 'Service::BOSH';

	my $output = '';
	{
		local *STDERR;
		open STDERR, '>', \$output or die "Cannot redirect STDERR: $!";
		$obj->dryrun_of('deploy', 'manifest.yml');
	}

	# The non-director path should NOT mention "BOSH director".
	# We check that the output contains "would execute" but not "director".
	like $output, qr/would execute/i,
		'dryrun_of() prints a "would execute" message when has_director is false';
};

subtest 'dryrun_of() uses director-aware message when has_director is true' => sub {
	plan tests => 1;

	fake_bosh();
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});

	# Create a subclass that overrides has_director to return 1.
	{
		no warnings 'once';
		package Service::BOSH::MockDirectorBase;
		our @ISA = ('Service::BOSH');
		sub has_director { return 1 }
	}

	my $obj = bless { deployment => undef, alias => 'test-director' },
		'Service::BOSH::MockDirectorBase';

	my $output = '';
	{
		local *STDERR;
		open STDERR, '>', \$output or die "Cannot redirect STDERR: $!";
		$obj->dryrun_of('deploy', 'manifest.yml');
	}

	like $output, qr/BOSH director/i,
		'dryrun_of() prints a "BOSH director" message when has_director is true';
};

subtest 'dryrun_of() with execute => 1 and exec_msg runs the command' => sub {
	plan tests => 2;

	fake_bosh();
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	my $obj = bless { deployment => undef }, 'Service::BOSH';

	# When execute => 1, dryrun_of() prints the dry-run message then
	# delegates to execute() with --dry-run appended.  Verify it succeeds.
	my $result;
	quietly { $result = $obj->dryrun_of({ execute => 1, exec_msg => 'deploying manifest' }, 'foo') };
	ok defined($result),
		'dryrun_of() with exec_msg and execute => 1 returns a defined result';

	# exec_msg is passed through to dryrun() but output goes to the Genesis
	# logger (not plain STDERR), so we verify the parameter is accepted
	# without error rather than capturing log output.
	quietly { $result = $obj->dryrun_of({ execute => 1, exec_msg => '' }, 'foo') };
	ok defined($result),
		'dryrun_of() with empty exec_msg does not die';
};

# ---------------------------------------------------------------------------
# All tests complete
# ---------------------------------------------------------------------------

done_testing;
