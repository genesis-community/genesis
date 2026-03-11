#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use JSON::PP qw/encode_json decode_json/;

# Load JSON::PP before Service::BOSH::Stemcell to work around SC-2.
# Known defect SC-2: Stemcell.pm calls JSON::PP->new->... without
# importing JSON::PP itself; it relies on another module having loaded
# it first.  We satisfy that here by loading JSON::PP explicitly.
use JSON::PP;

use_ok 'Service::BOSH::Stemcell';

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Build a minimal valid stemcell description hash.
sub _stemcell_args {
	return (
		iaas    => 'aws',
		os      => 'ubuntu-jammy',
		type    => 'light',
		url     => 'https://bosh.io/d/stemcells/bosh-aws-xen-hvm-ubuntu-jammy-go_agent?v=1.625',
		name    => 'bosh-aws-xen-hvm-ubuntu-jammy-go_agent',
		version => '1.625',
	);
}

sub _new_stemcell {
	return Service::BOSH::Stemcell->new(_stemcell_args(), @_);
}

# Build a canned list of stemcell JSON records as the bosh.io API returns.
sub _canned_stemcell_json {
	return encode_json([
		{
			name    => 'bosh-aws-xen-hvm-ubuntu-jammy-go_agent',
			version => '1.625',
			light   => {
				url  => 'https://bosh.io/d/stemcells/bosh-aws-xen-hvm-ubuntu-jammy-go_agent?v=1.625',
				sha1 => 'aabbccdd',
				size => 500,
			},
			regular => {
				url  => 'https://s3.amazonaws.com/bosh-core-stemcells/aws/bosh-stemcell-1.625-aws-xen-hvm-ubuntu-jammy-go_agent.tgz',
				sha1 => 'ddeeff00',
				size => 700000000,
			},
		},
		{
			name    => 'bosh-aws-xen-hvm-ubuntu-jammy-go_agent',
			version => '1.600',
			light   => {
				url  => 'https://bosh.io/d/stemcells/bosh-aws-xen-hvm-ubuntu-jammy-go_agent?v=1.600',
				sha1 => '11223344',
				size => 480,
			},
			regular => {
				url  => 'https://s3.amazonaws.com/bosh-core-stemcells/aws/bosh-stemcell-1.600-aws-xen-hvm-ubuntu-jammy-go_agent.tgz',
				sha1 => '55667788',
				size => 690000000,
			},
		},
		{
			name    => 'bosh-aws-xen-hvm-ubuntu-jammy-go_agent',
			version => '2.10',
			light   => {
				url  => 'https://bosh.io/d/stemcells/bosh-aws-xen-hvm-ubuntu-jammy-go_agent?v=2.10',
				sha1 => 'aabb2222',
				size => 510,
			},
		},
	]);
}

# ---------------------------------------------------------------------------
# 1. new() constructor
# ---------------------------------------------------------------------------

subtest 'new() - valid construction with all keys' => sub {
	plan tests => 11;

	my $sc = Service::BOSH::Stemcell->new(
		iaas    => 'aws',
		os      => 'ubuntu-jammy',
		type    => 'light',
		url     => 'https://bosh.io/d/stemcells/foo?v=1.625',
		name    => 'bosh-aws-xen-hvm-ubuntu-jammy-go_agent',
		version => '1.625',
		sha1    => 'deadbeef',
		md5     => 'cafebabe',
		sha256  => 'abcdef01',
		size    => 12345,
	);

	isa_ok($sc, 'Service::BOSH::Stemcell',
		'new() returns a Service::BOSH::Stemcell object');
	is($sc->{iaas},    'aws',               'iaas stored correctly');
	is($sc->{os},      'ubuntu-jammy',      'os stored correctly');
	is($sc->{type},    'light',             'type stored correctly');
	like($sc->{url},   qr{^https://},       'url stored correctly');
	is($sc->{name},    'bosh-aws-xen-hvm-ubuntu-jammy-go_agent',
		'name stored correctly');
	is($sc->{version}, '1.625',             'version stored correctly');
	is($sc->{sha1},    'deadbeef',          'sha1 stored correctly');
	is($sc->{md5},     'cafebabe',          'md5 stored correctly');
	is($sc->{sha256},  'abcdef01',          'sha256 stored correctly');
	is($sc->{size},    12345,               'size stored correctly');
};

subtest 'new() - minimal valid construction (required keys only)' => sub {
	plan tests => 2;

	my $sc;
	quietly { $sc = eval { Service::BOSH::Stemcell->new(_stemcell_args()) } };
	ok(defined $sc, 'new() succeeds with required keys only');
	isa_ok($sc, 'Service::BOSH::Stemcell',
		'returns Service::BOSH::Stemcell object');
};

subtest 'new() - missing required key dies' => sub {
	plan tests => 6;

	for my $missing (qw/iaas os type url name version/) {
		my %args = _stemcell_args();
		delete $args{$missing};
		my $err;
		quietly { eval { Service::BOSH::Stemcell->new(%args) }; $err = $@ };
		like($err, qr/Missing keys:.*\b$missing\b/i,
			"dies with 'Missing keys' when '$missing' is absent");
	}
};

subtest 'new() - invalid key dies' => sub {
	plan tests => 1;

	my $err;
	quietly {
		eval {
			Service::BOSH::Stemcell->new(
				_stemcell_args(),
				totally_bogus_key => 'value',
			);
		};
		$err = $@;
	};
	like($err, qr/Invalid keys:.*totally_bogus_key/i,
		'dies with "Invalid keys" when an unrecognised key is given');
};

subtest 'new() - optional keys accepted without error' => sub {
	plan tests => 4;

	for my $opt (qw/sha1 md5 sha256 size/) {
		my $sc;
		quietly {
			$sc = eval {
				Service::BOSH::Stemcell->new(_stemcell_args(), $opt => 'val');
			};
		};
		ok(defined $sc && !$@,
			"new() accepts optional key '$opt'");
	}
};

# ---------------------------------------------------------------------------
# 2. cpi_stemcell_prefix()
# ---------------------------------------------------------------------------

subtest 'cpi_stemcell_prefix() - all 8 known IaaS mappings' => sub {
	plan tests => 9;

	my %expected = (
		aws        => 'aws-xen-hvm',
		azure      => 'azure-hyperv',
		google     => 'google-kvm',
		openstack  => 'openstack-kvm',
		stackit    => 'openstack-kvm',
		vsphere    => 'vsphere-esxi',
		virtualbox => 'warden-boshlite',
		warden     => 'warden-boshlite',
	);

	while (my ($iaas, $prefix) = each %expected) {
		is(
			Service::BOSH::Stemcell->cpi_stemcell_prefix($iaas),
			$prefix,
			"cpi_stemcell_prefix('$iaas') returns '$prefix'",
		);
	}

	is(
		Service::BOSH::Stemcell->cpi_stemcell_prefix('unknown-iaas'),
		'',
		'cpi_stemcell_prefix returns empty string for unknown IaaS',
	);
};

subtest 'cpi_stemcell_prefix() - callable as instance method' => sub {
	plan tests => 1;

	my $sc = _new_stemcell();
	is(
		$sc->cpi_stemcell_prefix('google'),
		'google-kvm',
		'cpi_stemcell_prefix works as an instance method',
	);
};

# ---------------------------------------------------------------------------
# 3. Predicate methods
# ---------------------------------------------------------------------------

subtest 'is_type() / is_light() / is_full()' => sub {
	plan tests => 6;

	my $light = _new_stemcell(type => 'light');
	my $regular = _new_stemcell(
		type => 'regular',
		url  => 'https://bosh.io/d/stemcells/bosh-aws-xen-hvm-ubuntu-jammy-go_agent?v=1.625',
	);

	ok($light->is_type('light'),      'is_type("light") true for light stemcell');
	ok(!$light->is_type('regular'),   'is_type("regular") false for light stemcell');
	ok($light->is_light(),            'is_light() true for light stemcell');
	ok(!$light->is_full(),            'is_full() false for light stemcell');

	ok($regular->is_full(),           'is_full() true for regular stemcell');
	ok(!$regular->is_light(),         'is_light() false for regular stemcell');
};

subtest 'is_local() - URL patterns' => sub {
	plan tests => 4;

	my $http_sc = _new_stemcell(
		url => 'http://bosh.io/d/stemcells/foo',
	);
	ok(!$http_sc->is_local(), 'is_local() false for http:// URL');

	my $https_sc = _new_stemcell(
		url => 'https://bosh.io/d/stemcells/foo',
	);
	ok(!$https_sc->is_local(), 'is_local() false for https:// URL');

	my $abs_path_sc = _new_stemcell(
		url => '/path/to/local/stemcell.tgz',
	);
	ok($abs_path_sc->is_local(), 'is_local() true for absolute file path');

	my $rel_path_sc = _new_stemcell(
		url => 'stemcells/local.tgz',
	);
	ok($rel_path_sc->is_local(), 'is_local() true for relative file path');
};

# ---------------------------------------------------------------------------
# 4. download() - always dies
# ---------------------------------------------------------------------------

subtest 'download() always dies with not-implemented message' => sub {
	plan tests => 1;

	my $sc = _new_stemcell();
	my $err;
	quietly { eval { $sc->download('/tmp/some-stemcell.tgz') }; $err = $@ };
	like(
		$err,
		qr/Downloading stemcell from .* is not implemented yet/i,
		'download() dies with "not implemented yet" message',
	);
};

# ---------------------------------------------------------------------------
# 5. upload()
# ---------------------------------------------------------------------------

# Build a small mock BOSH director that captures execute/dryrun_of calls.
sub _mock_bosh {
	my @executed;
	my $bosh = bless {
		_executed => \@executed,
		execute   => sub {
			my ($self, $opts, @cmd) = @_;
			push @{$self->{_executed}}, { opts => $opts, cmd => [@cmd] };
			return ('output', 0, '');
		},
		dryrun_of => sub {
			my ($self, @cmd) = @_;
			push @{$self->{_executed}}, { dryrun => 1, cmd => [@cmd] };
		},
	}, 'MockBOSH';

	no strict 'refs';
	no warnings 'redefine';
	*MockBOSH::execute   = sub { my ($s,$o,@c) = @_; push @{$s->{_executed}}, {opts=>$o,cmd=>[@c]}; return ('output',0,'') };
	*MockBOSH::dryrun_of = sub { my ($s,@c)    = @_; push @{$s->{_executed}}, {dryrun=>1,cmd=>[@c]} };

	return ($bosh, \@executed);
}

subtest 'upload() - remote light stemcell includes sha1/version/name flags' => sub {
	plan tests => 5;

	my ($bosh, $executed) = _mock_bosh();
	my $sc = _new_stemcell(sha1 => 'abc123');

	my $ok = $sc->upload($bosh);

	is($ok, 1, 'upload() returns 1 in scalar context on success');
	my $cmd = $executed->[0]{cmd};
	is($cmd->[0], 'upload-stemcell', 'command is upload-stemcell');

	my $cmd_str = join(' ', @$cmd);
	like($cmd_str, qr/--sha1\s+abc123/, 'includes --sha1 flag');
	like($cmd_str, qr/--version\s+1\.625/, 'includes --version flag');
	like($cmd_str, qr/--name\s+bosh-aws-xen-hvm-ubuntu-jammy-go_agent/, 'includes --name flag');
};

subtest 'upload() - remote stemcell without sha1 omits --sha1 flag' => sub {
	plan tests => 2;

	my ($bosh, $executed) = _mock_bosh();
	my $sc = _new_stemcell();  # no sha1

	quietly { $sc->upload($bosh) };
	my $cmd_str = join(' ', @{$executed->[0]{cmd}});

	unlike($cmd_str, qr/--sha1/, 'omits --sha1 when sha1 not set');
	like($cmd_str, qr/--version\s+1\.625/, 'still includes --version');
};

subtest 'upload() - fix flag adds --fix to command' => sub {
	plan tests => 1;

	my ($bosh, $executed) = _mock_bosh();
	my $sc = _new_stemcell();

	quietly { $sc->upload($bosh, fix => 1) };
	my $cmd_str = join(' ', @{$executed->[0]{cmd}});
	like($cmd_str, qr/--fix/, 'upload with fix=>1 includes --fix flag');
};

subtest 'upload() - local stemcell omits --sha1/--version/--name flags' => sub {
	plan tests => 3;

	my ($bosh, $executed) = _mock_bosh();
	my $sc = _new_stemcell(
		url  => '/local/path/to/stemcell.tgz',
		sha1 => 'localsha1',
	);

	quietly { $sc->upload($bosh) };
	my $cmd_str = join(' ', @{$executed->[0]{cmd}});

	unlike($cmd_str, qr/--sha1/,    'local upload omits --sha1');
	unlike($cmd_str, qr/--version/, 'local upload omits --version');
	unlike($cmd_str, qr/--name/,    'local upload omits --name');
};

subtest 'upload() - dryrun mode calls dryrun_of and returns 1 (scalar)' => sub {
	plan tests => 3;

	my ($bosh, $executed) = _mock_bosh();
	my $sc = _new_stemcell();

	my $result = $sc->upload($bosh, dryrun => 1);

	is($result, 1, 'dryrun upload returns 1 in scalar context');
	ok(scalar @$executed, 'dryrun_of was called');
	ok($executed->[0]{dryrun}, 'recorded entry is marked as dryrun');
};

subtest 'upload() - dryrun mode returns (undef,0,undef) in list context' => sub {
	plan tests => 3;

	my ($bosh, $executed) = _mock_bosh();
	my $sc = _new_stemcell();

	my ($out, $rc, $err) = $sc->upload($bosh, dryrun => 1);

	is($rc,  0,     'dryrun list context: exit code is 0');
	ok(!defined $out, 'dryrun list context: output is undef');
	ok(!defined $err, 'dryrun list context: stderr is undef');
};

subtest 'upload() - list context returns (output, rc, err)' => sub {
	plan tests => 3;

	my ($bosh, $executed) = _mock_bosh();
	my $sc = _new_stemcell();

	my ($out, $rc, $err) = quietly { $sc->upload($bosh) };

	is($rc,  0,        'upload list context: rc is 0 on success');
	is($out, 'output', 'upload list context: output returned');
	is($err, '',       'upload list context: stderr returned');
};

subtest 'upload() - silent option passes interactive=>0 to execute' => sub {
	plan tests => 1;

	my ($bosh, $executed) = _mock_bosh();
	my $sc = _new_stemcell();

	quietly { $sc->upload($bosh, silent => 1) };
	is($executed->[0]{opts}{interactive}, 0,
		'silent=>1 passes interactive=>0 to execute');
};

subtest 'upload() - non-silent passes interactive=>1 to execute' => sub {
	plan tests => 1;

	my ($bosh, $executed) = _mock_bosh();
	my $sc = _new_stemcell();

	quietly { $sc->upload($bosh) };
	is($executed->[0]{opts}{interactive}, 1,
		'default (non-silent) passes interactive=>1 to execute');
};

# ---------------------------------------------------------------------------
# 6. description()
# ---------------------------------------------------------------------------

subtest 'description() - default title uses stemcell name' => sub {
	plan tests => 1;

	my $sc = _new_stemcell(sha1 => 'abc123', size => 42);
	my $text;
	quietly { $text = $sc->description() };
	like(
		$text,
		qr/bosh-aws-xen-hvm-ubuntu-jammy-go_agent/,
		'default title contains stemcell name',
	);
};

subtest 'description() - custom title appears in output' => sub {
	plan tests => 1;

	# sha1 and size must be provided: csprintf dies on undef sprintf args
	my $sc = _new_stemcell(sha1 => 'abc', size => 1);
	my $text;
	quietly { $text = $sc->description('My Custom Title') };
	like($text, qr/My Custom Title/, 'custom title appears in description');
};

subtest 'description() - fields present in output' => sub {
	plan tests => 6;

	my $sc = _new_stemcell(sha1 => 'deadbeef', size => 12345);
	my $text;
	quietly { $text = $sc->description() };

	like($text, qr/aws/,           'IaaS present in description');
	like($text, qr/ubuntu-jammy/,  'OS present in description');
	like($text, qr/light/,         'type present in description');
	like($text, qr/1\.625/,        'version present in description');
	like($text, qr/deadbeef/,      'sha1 present in description');
	like($text, qr/12345/,         'size present in description');
};

subtest 'description() - remote stemcell shows URL label' => sub {
	plan tests => 1;

	my $sc = _new_stemcell(sha1 => 'abc', size => 1);  # https URL
	my $text;
	quietly { $text = $sc->description() };
	like($text, qr/URL:/, 'remote stemcell description contains "URL:" label');
};

subtest 'description() - local stemcell shows File label' => sub {
	plan tests => 1;

	my $sc = _new_stemcell(url => '/local/stemcell.tgz', sha1 => 'abc', size => 1);
	my $text;
	quietly { $text = $sc->description() };
	like($text, qr/File:/, 'local stemcell description contains "File:" label');
};

# ---------------------------------------------------------------------------
# 7. available_stemcells() - mocked curl
# ---------------------------------------------------------------------------

subtest 'available_stemcells() - requires iaas' => sub {
	plan tests => 1;

	my $err;
	quietly {
		eval { Service::BOSH::Stemcell->available_stemcells(os => 'ubuntu-jammy') };
		$err = $@;
	};
	like($err, qr/No IaaS specified/i,
		'dies with "No IaaS specified" when iaas is omitted');
};

subtest 'available_stemcells() - unknown IaaS dies' => sub {
	plan tests => 1;

	my $err;
	quietly {
		eval {
			Service::BOSH::Stemcell->available_stemcells(iaas => 'unknown-iaas')
		};
		$err = $@;
	};
	like($err, qr/No stemcells found/i,
		'dies with "No stemcells found" for unrecognised IaaS');
};

subtest 'available_stemcells() - strips -cpi suffix from iaas' => sub {
	plan tests => 2;

	my $captured;
	{
		no warnings 'redefine';
		local *Service::BOSH::Stemcell::curl = sub {
			my @args = @_;
			$captured = \@args;
			return (200, 'HTTP/1.1 200 OK', '[]', {});
		};

		# Known defect SC-2: JSON::PP must already be loaded (we loaded it above)
		quietly {
			eval {
				Service::BOSH::Stemcell->available_stemcells(iaas => 'aws-cpi');
			};
		};
	}

	ok(defined $captured, 'curl was called');
	like(
		$captured->[1],
		qr{/bosh-aws-xen-hvm-},
		'-cpi suffix stripped from iaas before URL construction',
	);
};

subtest 'available_stemcells() - returns sorted array ref' => sub {
	# NOTE: available_stemcells() sorts by calling by_semver($b, $a) where $b
	# and $a are Service::BOSH::Stemcell objects.  by_semver() calls semver()
	# on its arguments; semver() tries to match a version string and returns
	# undef for an object reference.  As a result the semver comparison always
	# returns 0 and only the secondary sort key (type: light < regular) takes
	# effect.  All light stemcells therefore appear before all regular stemcells
	# regardless of version.  This test documents the actual behaviour.
	plan tests => 4;

	my $json = _canned_stemcell_json();

	{
		no warnings 'redefine';
		local *Service::BOSH::Stemcell::curl = sub {
			return (200, 'HTTP/1.1 200 OK', $json, {});
		};

		my $results;
		quietly { $results = Service::BOSH::Stemcell->available_stemcells(iaas => 'aws') };

		isa_ok($results, 'ARRAY', 'returns array ref');
		ok(scalar @$results > 0, 'returns non-empty list');

		# All light stemcells appear before all regular ones (secondary sort key)
		my @light   = grep { $_->{type} eq 'light'   } @$results;
		my @regular = grep { $_->{type} eq 'regular' } @$results;
		ok(scalar @light   > 0, 'light stemcells present in results');

		# Verify light entries all appear before any regular entries
		my $last_light_idx   = -1;
		my $first_regular_idx = scalar @$results;
		for my $i (0 .. $#$results) {
			$last_light_idx    = $i if $results->[$i]{type} eq 'light';
			$first_regular_idx = $i if $results->[$i]{type} eq 'regular' && $i < $first_regular_idx;
		}
		ok(
			!@regular || $last_light_idx < $first_regular_idx,
			'all light stemcells precede all regular stemcells in sort output',
		);
	}
};

subtest 'available_stemcells() - type filter returns only matching type' => sub {
	plan tests => 3;

	my $json = _canned_stemcell_json();

	{
		no warnings 'redefine';
		local *Service::BOSH::Stemcell::curl = sub {
			return (200, 'HTTP/1.1 200 OK', $json, {});
		};

		my $results;
		quietly {
			$results = Service::BOSH::Stemcell->available_stemcells(
				iaas => 'aws',
				type => 'light',
			);
		};

		ok(scalar @$results > 0, 'type filter returns at least one result');
		my @non_light = grep { $_->{type} ne 'light' } @$results;
		is(scalar @non_light, 0, 'all returned stemcells have type=light');

		quietly {
			$results = Service::BOSH::Stemcell->available_stemcells(
				iaas => 'aws',
				type => 'regular',
			);
		};
		my @non_regular = grep { $_->{type} ne 'regular' } @$results;
		is(scalar @non_regular, 0, 'all returned stemcells have type=regular');
	}
};

subtest 'available_stemcells() - ubuntu-jammy gets go_agent suffix in URL' => sub {
	plan tests => 1;

	my $captured;
	{
		no warnings 'redefine';
		local *Service::BOSH::Stemcell::curl = sub {
			$captured = $_[1];
			return (200, 'HTTP/1.1 200 OK', '[]', {});
		};

		quietly {
			eval {
				Service::BOSH::Stemcell->available_stemcells(
					iaas => 'aws',
					os   => 'ubuntu-jammy',
				);
			};
		};
	}

	like($captured, qr/-go_agent\?/, 'ubuntu-jammy URL includes -go_agent suffix');
};

subtest 'available_stemcells() - ubuntu-noble omits go_agent suffix' => sub {
	plan tests => 1;

	my $captured;
	{
		no warnings 'redefine';
		local *Service::BOSH::Stemcell::curl = sub {
			$captured = $_[1];
			return (200, 'HTTP/1.1 200 OK', '[]', {});
		};

		quietly {
			eval {
				Service::BOSH::Stemcell->available_stemcells(
					iaas => 'aws',
					os   => 'ubuntu-noble',
				);
			};
		};
	}

	unlike($captured, qr/-go_agent/, 'ubuntu-noble URL omits -go_agent suffix');
};

subtest 'available_stemcells() - custom stemcell_url overrides default' => sub {
	plan tests => 1;

	my $captured;
	{
		no warnings 'redefine';
		local *Service::BOSH::Stemcell::curl = sub {
			$captured = $_[1];
			return (200, 'HTTP/1.1 200 OK', '[]', {});
		};

		quietly {
			eval {
				Service::BOSH::Stemcell->available_stemcells(
					iaas         => 'aws',
					stemcell_url => 'https://internal.example.com/api/stemcells/',
				);
			};
		};
	}

	like(
		$captured,
		qr{^https://internal\.example\.com/api/stemcells/},
		'custom stemcell_url replaces the default base URL',
	);
};

subtest 'available_stemcells() - default os is ubuntu-jammy' => sub {
	plan tests => 1;

	my $captured;
	{
		no warnings 'redefine';
		local *Service::BOSH::Stemcell::curl = sub {
			$captured = $_[1];
			return (200, 'HTTP/1.1 200 OK', '[]', {});
		};

		quietly {
			eval {
				Service::BOSH::Stemcell->available_stemcells(iaas => 'aws');
			};
		};
	}

	like($captured, qr/ubuntu-jammy/, 'default OS is ubuntu-jammy');
};

# ---------------------------------------------------------------------------
# 8. find() - mocked available_stemcells
# ---------------------------------------------------------------------------

# Override available_stemcells for find() tests using a local redefine.
sub _with_canned_stemcells (&) {
	my ($block) = @_;
	my $json = _canned_stemcell_json();
	no warnings 'redefine';
	local *Service::BOSH::Stemcell::curl = sub {
		return (200, 'HTTP/1.1 200 OK', $json, {});
	};
	return $block->();
}

subtest 'find() - exact version match' => sub {
	plan tests => 2;

	my $sc;
	quietly {
		_with_canned_stemcells {
			$sc = Service::BOSH::Stemcell->find('aws', 'ubuntu-jammy', '1.625');
		};
	};

	ok(defined $sc, 'find() returns a stemcell for exact version');
	is($sc->{version}, '1.625', 'found stemcell has the requested version');
};

subtest 'find() - "latest" returns first stemcell from sorted list' => sub {
	# NOTE: find("latest") delegates to available_stemcells, which sorts by
	# type (light < regular) but NOT by version (due to the broken semver sort
	# described in the available_stemcells sort test above).  The "latest"
	# result is therefore the first light stemcell in API response order.
	# With our canned JSON that is version 1.625 (not the semantically newest
	# 2.10).  This test documents the actual behaviour.
	plan tests => 2;

	my $sc;
	quietly {
		_with_canned_stemcells {
			$sc = Service::BOSH::Stemcell->find('aws', 'ubuntu-jammy', 'latest');
		};
	};

	ok(defined $sc, 'find("latest") returns a stemcell');
	# Actual result is 1.625 (first light stemcell in API order) not 2.10,
	# because version-based sorting is broken (see sort test above)
	is($sc->{version}, '1.625',
		'find("latest") returns first stemcell in API order (version sort defect)');
};

subtest 'find() - "N.latest" returns newest in that major line' => sub {
	plan tests => 3;

	my $sc_1_latest;
	my $sc_2_latest;
	quietly {
		_with_canned_stemcells {
			$sc_1_latest = Service::BOSH::Stemcell->find('aws', 'ubuntu-jammy', '1.latest');
			$sc_2_latest = Service::BOSH::Stemcell->find('aws', 'ubuntu-jammy', '2.latest');
		};
	};

	ok(defined $sc_1_latest, 'find("1.latest") returns a stemcell');
	is($sc_1_latest->{version}, '1.625',
		'find("1.latest") returns newest 1.x version');
	is($sc_2_latest->{version}, '2.10',
		'find("2.latest") returns newest 2.x version');
};

subtest 'find() - no match returns undef' => sub {
	plan tests => 1;

	my $sc;
	quietly {
		_with_canned_stemcells {
			$sc = Service::BOSH::Stemcell->find('aws', 'ubuntu-jammy', '9.999');
		};
	};

	ok(!defined $sc, 'find() returns undef when no stemcell matches');
};

subtest 'find() - type filter is forwarded to available_stemcells' => sub {
	plan tests => 2;

	my $sc_light;
	my $sc_regular;
	quietly {
		_with_canned_stemcells {
			$sc_light   = Service::BOSH::Stemcell->find('aws', 'ubuntu-jammy', '1.625', 'light');
			$sc_regular = Service::BOSH::Stemcell->find('aws', 'ubuntu-jammy', '1.625', 'regular');
		};
	};

	is($sc_light->{type},   'light',   'find() with type=light returns a light stemcell');
	is($sc_regular->{type}, 'regular', 'find() with type=regular returns a regular stemcell');
};

# ---------------------------------------------------------------------------
# 9. Constants
# ---------------------------------------------------------------------------

subtest 'default_stemcell_url constant' => sub {
	plan tests => 1;

	is(
		Service::BOSH::Stemcell::default_stemcell_url(),
		'https://bosh.io/api/v1/stemcells/',
		'default_stemcell_url is the expected bosh.io endpoint',
	);
};

subtest 'valid_stemcell_types constant' => sub {
	plan tests => 3;

	my $types = Service::BOSH::Stemcell::valid_stemcell_types();
	isa_ok($types, 'ARRAY', 'valid_stemcell_types is an array ref');
	ok(grep({ $_ eq 'regular' } @$types), 'valid_stemcell_types contains "regular"');
	ok(grep({ $_ eq 'light'   } @$types), 'valid_stemcell_types contains "light"');
};

done_testing;
