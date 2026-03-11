#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;

use Test::More;
use Test::Exception;
use JSON::PP qw/encode_json decode_json/;

BEGIN { use_ok 'Service::Credhub' }

# --- Helpers ---

sub make_credhub {
	my (%opts) = @_;
	return Service::Credhub->new(
		$opts{name}     // 'test-bosh',
		$opts{base}     // '/test-bosh',
		$opts{url}      // 'https://credhub.example.com:8844',
		$opts{username} // 'credhub-client',
		$opts{password} // 's3cr3t',
		$opts{ca_cert}  // "-----BEGIN CERTIFICATE-----\nfake-ca\n-----END CERTIFICATE-----\n",
	);
}

sub make_exodus_data {
	my (%overrides) = @_;
	return {
		credhub_url      => 'https://10.0.0.10:8844',
		credhub_username => 'credhub-admin',
		credhub_password => 'exodus-secret',
		credhub_ca_cert  => "-----BEGIN CERTIFICATE-----\ncredhub-ca\n-----END CERTIFICATE-----\n",
		ca_cert          => "-----BEGIN CERTIFICATE-----\nbosh-ca\n-----END CERTIFICATE-----\n",
		%overrides,
	};
}

# ============================================================
# Phase 1: Pure Methods (no run() mocking needed)
# ============================================================

subtest 'Phase 1: Pure methods' => sub {

	subtest 'new() constructor' => sub {
		my $ch = make_credhub();
		isa_ok($ch, 'Service::Credhub', 'new() returns blessed object');
		is($ch->{name},     'test-bosh',                     'name stored');
		is($ch->{base},     '/test-bosh',                    'base stored');
		is($ch->{url},      'https://credhub.example.com:8844', 'url stored');
		is($ch->{username}, 'credhub-client',                'username stored');
		is($ch->{password}, 's3cr3t',                        'password stored');
		like($ch->{ca_cert}, qr/fake-ca/,                    'ca_cert stored');
	};

	subtest 'base() accessor' => sub {
		# Trailing slash added when missing
		my $ch = make_credhub(base => '/prod-bosh');
		is($ch->base(), '/prod-bosh/', 'trailing slash added');

		# Trailing slash preserved when present
		$ch = make_credhub(base => '/prod-bosh/');
		is($ch->base(), '/prod-bosh/', 'trailing slash preserved');

		# Root path
		$ch = make_credhub(base => '/');
		is($ch->base(), '/', 'root path stays /');

		# Multi-segment path
		$ch = make_credhub(base => '/a/b/c');
		is($ch->base(), '/a/b/c/', 'multi-segment gets trailing slash');

		# Empty base
		$ch = make_credhub(base => '');
		is($ch->base(), '/', 'empty base normalizes to /');
	};

	subtest 'env() accessor' => sub {
		my $ch = make_credhub();
		my $env = $ch->env();
		is(ref($env), 'HASH', 'returns hashref');
		is($env->{CREDHUB_SERVER},  'https://credhub.example.com:8844', 'CREDHUB_SERVER mapped from url');
		is($env->{CREDHUB_CLIENT},  'credhub-client',                   'CREDHUB_CLIENT mapped from username');
		is($env->{CREDHUB_SECRET},  's3cr3t',                           'CREDHUB_SECRET mapped from password');
		like($env->{CREDHUB_CA_CERT}, qr/fake-ca/,                     'CREDHUB_CA_CERT mapped from ca_cert');
		is(scalar keys %$env, 4, 'exactly 4 keys in env hash');
	};

	subtest 'is_preloaded()' => sub {
		my $ch = make_credhub();

		# Fresh object — not preloaded
		ok(!$ch->is_preloaded(), 'false on fresh object');

		# Undef cached — not preloaded
		$ch->{cached} = undef;
		ok(!$ch->is_preloaded(), 'false when cached is undef');

		# Non-hash cached — not preloaded
		$ch->{cached} = "string";
		ok(!$ch->is_preloaded(), 'false when cached is not a hashref');

		# Empty hashref — IS preloaded (distinguishes "never loaded" from "empty store")
		$ch->{cached} = {};
		ok($ch->is_preloaded(), 'true when cached is empty hashref');

		# Populated hashref
		$ch->{cached} = { 'db/password' => 'hunter2' };
		ok($ch->is_preloaded(), 'true when cached is populated hashref');
	};

	subtest '_full_path()' => sub {
		my $ch = make_credhub(base => '/test-bosh');

		# Undef returns raw base
		is($ch->_full_path(undef), '/test-bosh', 'undef returns base');

		# Empty string returns raw base
		is($ch->_full_path(''), '/test-bosh', 'empty string returns base');

		# Absolute path returned as-is
		is($ch->_full_path('/other/path'), '/other/path', 'absolute path unchanged');

		# Relative path prepended with base
		is($ch->_full_path('db/password'), '/test-bosh/db/password', 'relative path prepended');

		# Simple relative name
		is($ch->_full_path('myvar'), '/test-bosh/myvar', 'simple relative name');
	};

	subtest 'keys() stub' => sub {
		my $ch = make_credhub();

		# Override bug() to throw a testable exception
		no warnings 'redefine';
		local *Service::Credhub::bug = sub { die $_[0] };
		use warnings 'redefine';

		throws_ok { $ch->keys() } qr/not supported/,
			'keys() dies with "not supported"';
	};
};

# ============================================================
# Phase 2: from_bosh() Factory
# ============================================================

subtest 'Phase 2: from_bosh() factory' => sub {

	subtest 'happy path' => sub {
		my $exodus = make_exodus_data();
		my $mock_vault = Mock->new(
			name => 'test-vault',
			get  => sub { return $exodus },
		);
		my $mock_bosh = Mock->new(
			alias        => 'test-bosh',
			exodus_vault => $mock_vault,
			exodus_path  => 'secret/exodus/test/bosh',
		);

		my $ch = Service::Credhub->from_bosh($mock_bosh);
		isa_ok($ch, 'Service::Credhub', 'returns Service::Credhub object');
		is($ch->{name},     'test-bosh',               'name from bosh alias');
		is($ch->{url},      'https://10.0.0.10:8844',  'url from exodus');
		is($ch->{username}, 'credhub-admin',            'username from exodus');
		is($ch->{password}, 'exodus-secret',            'password from exodus');
		# CA cert is ca_cert + credhub_ca_cert concatenated
		like($ch->{ca_cert}, qr/bosh-ca/,    'ca_cert includes bosh CA');
		like($ch->{ca_cert}, qr/credhub-ca/, 'ca_cert includes credhub CA');
	};

	subtest 'vault resolution: opts exodus_vault' => sub {
		my $exodus = make_exodus_data();
		my $opt_vault = Mock->new(
			name => 'opt-vault',
			get  => sub { return $exodus },
		);
		my $bosh_vault = Mock->new(
			name => 'bosh-vault',
			get  => sub { die "should not be called" },
		);
		my $mock_bosh = Mock->new(
			alias        => 'test-bosh',
			exodus_vault => $bosh_vault,
			exodus_path  => 'secret/exodus/test/bosh',
		);

		my $ch = Service::Credhub->from_bosh($mock_bosh, exodus_vault => $opt_vault);
		isa_ok($ch, 'Service::Credhub', 'opts exodus_vault takes priority');
	};

	subtest 'vault resolution: bosh exodus_vault fallback' => sub {
		my $exodus = make_exodus_data();
		my $bosh_vault = Mock->new(
			name => 'bosh-vault',
			get  => sub { return $exodus },
		);
		my $mock_bosh = Mock->new(
			alias        => 'test-bosh',
			exodus_vault => $bosh_vault,
			exodus_path  => 'secret/exodus/test/bosh',
		);

		my $ch = Service::Credhub->from_bosh($mock_bosh);
		isa_ok($ch, 'Service::Credhub', 'falls back to bosh exodus_vault');
	};

	subtest 'vault resolution: Service::Vault::current fallback' => sub {
		my $exodus = make_exodus_data();
		my $current_vault = Mock->new(
			name => 'current-vault',
			get  => sub { return $exodus },
		);
		my $mock_bosh = Mock->new(
			alias        => 'test-bosh',
			exodus_vault => undef,
			exodus_path  => 'secret/exodus/test/bosh',
		);

		no warnings 'redefine';
		local *Service::Vault::current = sub { return $current_vault };
		use warnings 'redefine';

		my $ch = Service::Credhub->from_bosh($mock_bosh);
		isa_ok($ch, 'Service::Credhub', 'falls back to Vault::current');
	};

	subtest 'vault resolution: Service::Vault::default fallback' => sub {
		my $exodus = make_exodus_data();
		my $default_vault = Mock->new(
			name => 'default-vault',
			get  => sub { return $exodus },
		);
		my $mock_bosh = Mock->new(
			alias        => 'test-bosh',
			exodus_vault => undef,
			exodus_path  => 'secret/exodus/test/bosh',
		);

		no warnings 'redefine';
		local *Service::Vault::current = sub { return undef };
		local *Service::Vault::default = sub { return $default_vault };
		use warnings 'redefine';

		my $ch = Service::Credhub->from_bosh($mock_bosh);
		isa_ok($ch, 'Service::Credhub', 'falls back to Vault::default');
	};

	subtest 'missing exodus data — dies' => sub {
		my $mock_vault = Mock->new(
			name => 'test-vault',
			get  => sub { return undef },
		);
		my $mock_bosh = Mock->new(
			alias        => 'test-bosh',
			exodus_vault => $mock_vault,
			exodus_path  => 'secret/exodus/test/bosh',
		);

		no warnings 'redefine';
		local *Service::Credhub::bail = sub { die @_ > 1 ? sprintf($_[0], @_[1..$#_]) : $_[0] };
		use warnings 'redefine';

		throws_ok { Service::Credhub->from_bosh($mock_bosh) }
			qr/No exodus data found/,
			'dies when no exodus data';
	};

	subtest 'missing exodus data — return_on_error' => sub {
		my $mock_vault = Mock->new(
			name => 'test-vault',
			get  => sub { return undef },
		);
		my $mock_bosh = Mock->new(
			alias        => 'test-bosh',
			exodus_vault => $mock_vault,
			exodus_path  => 'secret/exodus/test/bosh',
		);

		# Override debug to prevent output
		no warnings 'redefine';
		local *Service::Credhub::debug = sub { };
		use warnings 'redefine';

		my $ch = Service::Credhub->from_bosh($mock_bosh, return_on_error => 1);
		ok(!defined($ch), 'returns undef with return_on_error');
	};

	subtest 'missing required keys — dies' => sub {
		# Exodus data missing credhub_url
		my $exodus = make_exodus_data(credhub_url => undef);
		my $mock_vault = Mock->new(
			name => 'test-vault',
			get  => sub { return $exodus },
		);
		my $mock_bosh = Mock->new(
			alias        => 'test-bosh',
			exodus_vault => $mock_vault,
			exodus_path  => 'secret/exodus/test/bosh',
		);

		no warnings 'redefine';
		local *Service::Credhub::bail = sub { die @_ > 1 ? sprintf($_[0], @_[1..$#_]) : $_[0] };
		use warnings 'redefine';

		throws_ok { Service::Credhub->from_bosh($mock_bosh) }
			qr/does not appear to be.*Missing keys.*credhub_url/s,
			'dies listing missing keys';
	};

	subtest 'missing required keys — return_on_error' => sub {
		my $exodus = make_exodus_data(credhub_password => undef);
		my $mock_vault = Mock->new(
			name => 'test-vault',
			get  => sub { return $exodus },
		);
		my $mock_bosh = Mock->new(
			alias        => 'test-bosh',
			exodus_vault => $mock_vault,
			exodus_path  => 'secret/exodus/test/bosh',
		);

		no warnings 'redefine';
		local *Service::Credhub::debug = sub { };
		use warnings 'redefine';

		my $ch = Service::Credhub->from_bosh($mock_bosh, return_on_error => 1);
		ok(!defined($ch), 'returns undef with return_on_error for missing keys');
	};

	subtest 'base path resolution: exodus credhub_base' => sub {
		my $exodus = make_exodus_data(credhub_base => '/custom-base');
		my $mock_vault = Mock->new(
			name => 'test-vault',
			get  => sub { return $exodus },
		);
		my $mock_bosh = Mock->new(
			alias        => 'test-bosh',
			exodus_vault => $mock_vault,
			exodus_path  => 'secret/exodus/test/bosh',
		);

		my $ch = Service::Credhub->from_bosh($mock_bosh, base => '/opts-base');
		is($ch->{base}, '/custom-base', 'exodus credhub_base takes priority');
	};

	subtest 'base path resolution: opts base fallback' => sub {
		my $exodus = make_exodus_data();  # no credhub_base
		my $mock_vault = Mock->new(
			name => 'test-vault',
			get  => sub { return $exodus },
		);
		my $mock_bosh = Mock->new(
			alias        => 'test-bosh',
			exodus_vault => $mock_vault,
			exodus_path  => 'secret/exodus/test/bosh',
		);

		my $ch = Service::Credhub->from_bosh($mock_bosh, base => '/opts-base');
		is($ch->{base}, '/opts-base', 'falls back to opts base');
	};

	subtest 'base path resolution: defaults to /' => sub {
		my $exodus = make_exodus_data();
		my $mock_vault = Mock->new(
			name => 'test-vault',
			get  => sub { return $exodus },
		);
		my $mock_bosh = Mock->new(
			alias        => 'test-bosh',
			exodus_vault => $mock_vault,
			exodus_path  => 'secret/exodus/test/bosh',
		);

		my $ch = Service::Credhub->from_bosh($mock_bosh);
		is($ch->{base}, '/', 'defaults to / when neither exodus nor opts');
	};

	subtest 'CA cert concatenation' => sub {
		my $exodus = make_exodus_data(
			ca_cert         => 'BOSH-CA-PEM',
			credhub_ca_cert => 'CREDHUB-CA-PEM',
		);
		my $mock_vault = Mock->new(
			name => 'test-vault',
			get  => sub { return $exodus },
		);
		my $mock_bosh = Mock->new(
			alias        => 'test-bosh',
			exodus_vault => $mock_vault,
			exodus_path  => 'secret/exodus/test/bosh',
		);

		my $ch = Service::Credhub->from_bosh($mock_bosh);
		is($ch->{ca_cert}, 'BOSH-CA-PEMCREDHUB-CA-PEM',
			'ca_cert is ca_cert + credhub_ca_cert concatenated');
	};

	subtest 'exodus_path override via opts' => sub {
		my $exodus = make_exodus_data();
		my $captured_path;
		my $mock_vault = Mock->new(
			name => 'test-vault',
			get  => sub { $captured_path = $_[1]; return $exodus },
		);
		my $mock_bosh = Mock->new(
			alias        => 'test-bosh',
			exodus_vault => $mock_vault,
			exodus_path  => 'secret/exodus/default/bosh',
		);

		Service::Credhub->from_bosh($mock_bosh,
			exodus_path => 'secret/exodus/custom/bosh');
		is($captured_path, 'secret/exodus/custom/bosh',
			'opts exodus_path overrides bosh exodus_path');
	};

	subtest 'multiple missing required keys' => sub {
		my $exodus = make_exodus_data(
			credhub_url      => undef,
			credhub_username => undef,
		);
		my $mock_vault = Mock->new(
			name => 'test-vault',
			get  => sub { return $exodus },
		);
		my $mock_bosh = Mock->new(
			alias        => 'test-bosh',
			exodus_vault => $mock_vault,
			exodus_path  => 'secret/exodus/test/bosh',
		);

		no warnings 'redefine';
		local *Service::Credhub::bail = sub { die @_ > 1 ? sprintf($_[0], @_[1..$#_]) : $_[0] };
		use warnings 'redefine';

		throws_ok { Service::Credhub->from_bosh($mock_bosh) }
			qr/Missing keys.*credhub_url.*credhub_username|Missing keys.*credhub_username.*credhub_url/s,
			'lists all missing keys';
	};
};

# ============================================================
# Phase 3: Read Operations (mock run())
# ============================================================

subtest 'Phase 3: Read operations' => sub {

	subtest 'data() — success' => sub {
		my $ch = make_credhub();
		my @captured_args;
		my $mock_json = encode_json({ value => 'hunter2', id => 'cred-id-1' });

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			shift; # opts hashref
			@captured_args = @_;
			return ($mock_json, 0, '');
		};
		use warnings 'redefine';

		my $data = $ch->data('db/password');
		is(ref($data), 'HASH', 'returns hashref on success');
		is($data->{value}, 'hunter2', 'parsed JSON value correct');
		is($data->{id}, 'cred-id-1', 'parsed JSON id correct');
	};

	subtest 'data() — failure' => sub {
		my $ch = make_credhub();

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			return ('', 1, 'some error');
		};
		use warnings 'redefine';

		my $data = $ch->data('nonexistent');
		is(ref($data), 'HASH', 'returns hashref on failure');
		ok(defined($data->{error}), 'error key present');
		like($data->{error}, qr/some error/, 'error contains stderr message');
	};

	subtest 'data() — strips login warning from stderr' => sub {
		my $ch = make_credhub();
		my $warning_err = "WARNING: Two different login methods were detected. Please use one.\n\n\nActual error here";

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			return ('', 1, $warning_err);
		};
		use warnings 'redefine';

		my $data = $ch->data('test');
		unlike($data->{error}, qr/WARNING.*login methods/, 'login warning stripped');
		like($data->{error}, qr/Actual error here/, 'real error preserved');
	};

	subtest 'data() — passes correct args to run()' => sub {
		my $ch = make_credhub(base => '/my-bosh');
		my ($captured_opts, @captured_cmd);

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			$captured_opts = shift;
			@captured_cmd = @_;
			return (encode_json({ value => 'test' }), 0, '');
		};
		use warnings 'redefine';

		$ch->data('db/password');
		is($captured_cmd[0], 'credhub', 'first arg is credhub');
		is($captured_cmd[1], 'get', 'second arg is get');
		is($captured_cmd[2], '-j', 'third arg is -j');
		is($captured_cmd[3], '-n', 'fourth arg is -n');
		is($captured_cmd[4], '/my-bosh/db/password', 'fifth arg is full path');
		ok(exists $captured_opts->{env}, 'env passed in opts');
		is($captured_opts->{redact_env}, 1, 'redact_env set');
		is($captured_opts->{stderr}, 0, 'stderr suppressed');
	};

	subtest 'get() — scalar context' => sub {
		my $ch = make_credhub();

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			return (encode_json({ value => 'secret123' }), 0, '');
		};
		use warnings 'redefine';

		my $val = $ch->get('db/password');
		is($val, 'secret123', 'scalar context returns value');
	};

	subtest 'get() — list context' => sub {
		my $ch = make_credhub();

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			return (encode_json({ value => 'secret123' }), 0, '');
		};
		use warnings 'redefine';

		my ($val, $err) = $ch->get('db/password');
		is($val, 'secret123', 'list context returns value');
		ok(!defined($err) || $err eq '', 'no error on success');
	};

	subtest 'get() — uses cache when populated' => sub {
		my $ch = make_credhub();
		$ch->{cached} = { 'db/password' => 'cached-value' };
		my $run_called = 0;

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			$run_called = 1;
			return ('', 0, '');
		};
		use warnings 'redefine';

		my $val = $ch->get('db/password');
		is($val, 'cached-value', 'returns cached value');
		ok(!$run_called, 'run() not called when cache hit');
	};

	subtest 'get() — specific key within value' => sub {
		my $ch = make_credhub();
		my $cert_data = {
			value => {
				certificate => 'cert-pem',
				private_key => 'key-pem',
				ca          => 'ca-pem',
			}
		};

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			return (encode_json($cert_data), 0, '');
		};
		use warnings 'redefine';

		my $cert = $ch->get('tls/cert', 'certificate');
		is($cert, 'cert-pem', 'returns specific key from value hash');
	};

	subtest 'get() — specific key from cache' => sub {
		my $ch = make_credhub();
		$ch->{cached} = {
			'tls/cert' => {
				certificate => 'cached-cert',
				private_key => 'cached-key',
			}
		};

		my $cert = $ch->get('tls/cert', 'certificate');
		is($cert, 'cached-cert', 'returns specific key from cached value');
	};

	subtest 'get() — error propagation in list context' => sub {
		my $ch = make_credhub();

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			return ('', 1, 'credential not found');
		};
		use warnings 'redefine';

		my ($val, $err) = $ch->get('nonexistent');
		ok(!defined($val), 'value is undef on error');
		like($err, qr/credential not found/, 'error propagated');
	};

	subtest 'has() — true via data()' => sub {
		my $ch = make_credhub();

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			return (encode_json({ value => 'exists' }), 0, '');
		};
		use warnings 'redefine';

		ok($ch->has('db/password'), 'returns true when credential exists');
	};

	subtest 'has() — false via data() error' => sub {
		my $ch = make_credhub();

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			return ('', 1, 'not found');
		};
		use warnings 'redefine';

		is($ch->has('nonexistent'), '', 'returns empty string on error');
	};

	subtest 'has() — cache-aware' => sub {
		my $ch = make_credhub();
		$ch->{cached} = { 'db/password' => 'cached' };
		my $run_called = 0;

		no warnings 'redefine';
		local *Service::Credhub::run = sub { $run_called = 1; return ('', 1, '') };
		use warnings 'redefine';

		ok($ch->has('db/password'), 'returns true from cache');
		ok(!$run_called, 'run() not called for cached path');
	};

	subtest 'has() — key parameter checks nested hash' => sub {
		my $ch = make_credhub();

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			return (encode_json({
				value => { certificate => 'cert-data', private_key => 'key-data' }
			}), 0, '');
		};
		use warnings 'redefine';

		ok($ch->has('tls/cert', 'certificate'), 'key exists in nested hash');
		ok(!$ch->has('tls/cert', 'nonexistent_key'), 'key missing from nested hash');
	};

	subtest 'has() — key parameter with cached composite value' => sub {
		my $ch = make_credhub();
		$ch->{cached} = {
			'tls/cert' => {
				certificate => 'cert-data',
				private_key => 'key-data',
			}
		};

		ok($ch->has('tls/cert', 'certificate'), 'cached key exists');
		ok($ch->has('tls/cert', 'private_key'), 'cached key private_key exists');
	};

	subtest 'preload() — success populates cache' => sub {
		my $ch = make_credhub(base => '/test-bosh');
		my $export_json = encode_json({
			Credentials => [
				{ Name => '/test-bosh/db/password',  Value => 'hunter2' },
				{ Name => '/test-bosh/tls/cert',     Value => { certificate => 'cert', private_key => 'key' } },
			]
		});

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			return ($export_json, 0, '');
		};
		use warnings 'redefine';

		my $result = $ch->preload();
		is($result, $ch, 'preload() returns self for chaining');
		ok($ch->is_preloaded(), 'cache is populated after preload');
		is($ch->{cached}{'db/password'}, 'hunter2', 'simple value cached as scalar');
		is(ref($ch->{cached}{'tls/cert'}), 'HASH', 'composite value cached as hashref');
		is($ch->{cached}{'tls/cert'}{certificate}, 'cert', 'composite key accessible');
	};

	subtest 'preload() — failure clears cache' => sub {
		my $ch = make_credhub();
		# Pre-set cache to verify it gets cleared
		$ch->{cached} = { old => 'data' };

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			return ('', 1, 'connection failed');
		};
		use warnings 'redefine';

		my $result = $ch->preload();
		is($result, $ch, 'returns self even on failure');
		ok(!$ch->is_preloaded(), 'cache cleared on failure');
	};

	subtest 'preload() — empty credential store' => sub {
		my $ch = make_credhub();
		my $export_json = encode_json({ Credentials => [] });

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			return ($export_json, 0, '');
		};
		use warnings 'redefine';

		$ch->preload();
		ok($ch->is_preloaded(), 'cache populated even when empty');
		is_deeply($ch->{cached}, {}, 'cache is empty hashref');
	};

	subtest 'preload() — passes correct args' => sub {
		my $ch = make_credhub(base => '/prod-bosh');
		my @captured_cmd;

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			shift;
			@captured_cmd = @_;
			return (encode_json({ Credentials => [] }), 0, '');
		};
		use warnings 'redefine';

		$ch->preload();
		is($captured_cmd[0], 'credhub', 'command is credhub');
		is($captured_cmd[1], 'export',  'subcommand is export');
		is($captured_cmd[2], '-j',      'json flag');
		is($captured_cmd[3], '-p',      'path flag');
		is($captured_cmd[4], '/prod-bosh/', 'base path with trailing slash');
	};
};

# ============================================================
# Phase 4: Write Operations (set())
# ============================================================

subtest 'Phase 4: Write operations — set()' => sub {

	# Helper to capture run() args and simulate success
	my $set_result_json;
	my @set_captured_cmd;
	my $set_captured_opts;

	my $mock_set_run = sub {
		$set_captured_opts = shift;
		@set_captured_cmd = @_;
		$set_result_json //= encode_json({ id => 'cred-id-abc', value => 'written' });
		return ($set_result_json, 0, '');
	};

	subtest 'value type — auto-detected for scalar' => sub {
		my $ch = make_credhub();
		$set_result_json = encode_json({ id => 'val-id-1', value => 'test-value' });
		@set_captured_cmd = ();

		no warnings 'redefine';
		local *Service::Credhub::run = $mock_set_run;
		use warnings 'redefine';

		my $id = $ch->set('db/password', 'test-value');
		is($id, 'val-id-1', 'returns credential id');

		# Check the type arg in the command
		my %cmd_map;
		for (my $i = 0; $i < $#set_captured_cmd; $i++) {
			$cmd_map{$set_captured_cmd[$i]} = $set_captured_cmd[$i+1]
				if $set_captured_cmd[$i] =~ /^-/;
		}
		is($cmd_map{'-t'}, 'value', 'auto-detected type is value');
	};

	subtest 'value type — rejects empty string' => sub {
		my $ch = make_credhub();

		no warnings 'redefine';
		local *Service::Credhub::bail = sub { die @_ > 1 ? sprintf($_[0], @_[1..$#_]) : $_[0] };
		local *Service::Credhub::run = $mock_set_run;
		use warnings 'redefine';

		throws_ok { $ch->set('path', '') }
			qr/non-empty string/,
			'rejects empty string for value type';
	};

	subtest 'value type — rejects undef' => sub {
		my $ch = make_credhub();

		no warnings 'redefine';
		local *Service::Credhub::bail = sub { die @_ > 1 ? sprintf($_[0], @_[1..$#_]) : $_[0] };
		local *Service::Credhub::run = $mock_set_run;
		use warnings 'redefine';

		throws_ok { $ch->set('path', undef, 'value') }
			qr/non-empty string/,
			'rejects undef for explicit value type';
	};

	subtest 'value type — dollar sign escaping' => sub {
		my $ch = make_credhub();
		$set_result_json = encode_json({ id => 'dollar-id', value => 'pa$$word' });
		my $captured_env;

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			$captured_env = $_[0];
			@set_captured_cmd = @_[1..$#_];
			return ($set_result_json, 0, '');
		};
		use warnings 'redefine';

		$ch->set('db/pass', 'pa$$word');
		ok(exists $captured_env->{env}{__dollar_symbol__},
			'__dollar_symbol__ env var set for dollar escaping');
		is($captured_env->{env}{__dollar_symbol__}, '$',
			'__dollar_symbol__ maps to $');

		# Verify the -v payload was actually rewritten with ${__dollar_symbol__}
		my $v_arg;
		for (my $i = 0; $i < @set_captured_cmd - 1; $i++) {
			next if ref $set_captured_cmd[$i];
			if ($set_captured_cmd[$i] eq '-v') {
				$v_arg = $set_captured_cmd[$i+1];
				last;
			}
		}
		ok(defined $v_arg, 'captured -v argument');
		# set() wraps the value in {redact => $escaped_value}
		is(ref($v_arg), 'HASH', '-v arg is a redact hashref');
		like($v_arg->{redact}, qr/\$\{__dollar_symbol__\}/,
			'-v payload uses ${__dollar_symbol__} for dollar escaping');
	};

	subtest 'json type — auto-detected for hashref' => sub {
		my $ch = make_credhub();
		$set_result_json = encode_json({ id => 'json-id-1', value => { foo => 'bar' } });
		@set_captured_cmd = ();

		no warnings 'redefine';
		local *Service::Credhub::run = $mock_set_run;
		use warnings 'redefine';

		my $id = $ch->set('app/config', { foo => 'bar' });
		is($id, 'json-id-1', 'returns id for json type');

		my %cmd_map;
		for (my $i = 0; $i < $#set_captured_cmd; $i++) {
			$cmd_map{$set_captured_cmd[$i]} = $set_captured_cmd[$i+1]
				if !ref($set_captured_cmd[$i]) && $set_captured_cmd[$i] =~ /^-/;
		}
		is($cmd_map{'-t'}, 'json', 'auto-detected type is json');
	};

	subtest 'json type — auto-detected for arrayref' => sub {
		my $ch = make_credhub();
		$set_result_json = encode_json({ id => 'json-id-2', value => [1, 2, 3] });

		no warnings 'redefine';
		local *Service::Credhub::run = $mock_set_run;
		use warnings 'redefine';

		my $id = $ch->set('app/list', [1, 2, 3]);
		is($id, 'json-id-2', 'returns id for array json type');
	};

	subtest 'json type — rejects scalar' => sub {
		my $ch = make_credhub();

		no warnings 'redefine';
		local *Service::Credhub::bail = sub { die @_ > 1 ? sprintf($_[0], @_[1..$#_]) : $_[0] };
		local *Service::Credhub::run = $mock_set_run;
		use warnings 'redefine';

		throws_ok { $ch->set('path', 'not-a-ref', 'json') }
			qr/HASH or an ARRAY/,
			'rejects scalar for json type';
	};

	subtest 'certificate type — valid with root' => sub {
		my $ch = make_credhub();
		$set_result_json = encode_json({ id => 'cert-id-1', value => 'cert-data' });
		@set_captured_cmd = ();

		no warnings 'redefine';
		local *Service::Credhub::run = $mock_set_run;
		use warnings 'redefine';

		my $id = $ch->set('tls/cert', {
			certificate => 'cert-pem',
			private_key => 'key-pem',
			root        => 'ca-pem',
		}, 'certificate');
		is($id, 'cert-id-1', 'certificate with root succeeds');
	};

	subtest 'certificate type — valid with root_path' => sub {
		my $ch = make_credhub();
		$set_result_json = encode_json({ id => 'cert-id-2', value => 'cert-data' });

		no warnings 'redefine';
		local *Service::Credhub::run = $mock_set_run;
		use warnings 'redefine';

		my $id = $ch->set('tls/cert', {
			certificate => 'cert-pem',
			private_key => 'key-pem',
			root_path   => '/ca-path',
		}, 'certificate');
		is($id, 'cert-id-2', 'certificate with root_path succeeds');
	};

	subtest 'certificate type — missing certificate' => sub {
		my $ch = make_credhub();

		no warnings 'redefine';
		local *Service::Credhub::bail = sub { die @_ > 1 ? sprintf($_[0], @_[1..$#_]) : $_[0] };
		local *Service::Credhub::run = $mock_set_run;
		use warnings 'redefine';

		throws_ok {
			$ch->set('tls/cert', {
				private_key => 'key-pem',
				root        => 'ca-pem',
			}, 'certificate')
		} qr/certificate.*private_key/,
			'dies when certificate key missing';
	};

	subtest 'certificate type — missing private_key' => sub {
		my $ch = make_credhub();

		no warnings 'redefine';
		local *Service::Credhub::bail = sub { die @_ > 1 ? sprintf($_[0], @_[1..$#_]) : $_[0] };
		local *Service::Credhub::run = $mock_set_run;
		use warnings 'redefine';

		throws_ok {
			$ch->set('tls/cert', {
				certificate => 'cert-pem',
				root        => 'ca-pem',
			}, 'certificate')
		} qr/certificate.*private_key/,
			'dies when private_key missing';
	};

	subtest 'certificate type — both root and root_path' => sub {
		my $ch = make_credhub();

		no warnings 'redefine';
		local *Service::Credhub::bail = sub { die @_ > 1 ? sprintf($_[0], @_[1..$#_]) : $_[0] };
		local *Service::Credhub::run = $mock_set_run;
		use warnings 'redefine';

		throws_ok {
			$ch->set('tls/cert', {
				certificate => 'cert-pem',
				private_key => 'key-pem',
				root        => 'ca-pem',
				root_path   => '/ca-path',
			}, 'certificate')
		} qr/root.*root_path.*not both/,
			'dies when both root and root_path provided';
	};

	subtest 'certificate type — neither root nor root_path' => sub {
		my $ch = make_credhub();

		no warnings 'redefine';
		local *Service::Credhub::bail = sub { die @_ > 1 ? sprintf($_[0], @_[1..$#_]) : $_[0] };
		local *Service::Credhub::run = $mock_set_run;
		use warnings 'redefine';

		throws_ok {
			$ch->set('tls/cert', {
				certificate => 'cert-pem',
				private_key => 'key-pem',
			}, 'certificate')
		} qr/root.*root_path/,
			'dies when neither root nor root_path';
	};

	subtest 'certificate type — invalid keys' => sub {
		my $ch = make_credhub();

		no warnings 'redefine';
		local *Service::Credhub::bail = sub { die @_ > 1 ? sprintf($_[0], @_[1..$#_]) : $_[0] };
		local *Service::Credhub::run = $mock_set_run;
		use warnings 'redefine';

		throws_ok {
			$ch->set('tls/cert', {
				certificate => 'cert-pem',
				private_key => 'key-pem',
				root        => 'ca-pem',
				bogus_key   => 'bad',
			}, 'certificate')
		} qr/Invalid parameters.*bogus_key/,
			'dies on invalid keys';
	};

	subtest 'ssh type — valid' => sub {
		my $ch = make_credhub();
		$set_result_json = encode_json({ id => 'ssh-id-1', value => 'ssh-data' });

		no warnings 'redefine';
		local *Service::Credhub::run = $mock_set_run;
		use warnings 'redefine';

		my $id = $ch->set('keys/deploy', {
			public_key  => 'ssh-rsa AAAA...',
			private_key => '-----BEGIN RSA PRIVATE KEY-----...',
		}, 'ssh');
		is($id, 'ssh-id-1', 'ssh type succeeds');
	};

	subtest 'ssh type — missing keys' => sub {
		my $ch = make_credhub();

		no warnings 'redefine';
		local *Service::Credhub::bail = sub { die @_ > 1 ? sprintf($_[0], @_[1..$#_]) : $_[0] };
		local *Service::Credhub::run = $mock_set_run;
		use warnings 'redefine';

		throws_ok {
			$ch->set('keys/deploy', { public_key => 'pub' }, 'ssh')
		} qr/private_key/,
			'dies when ssh missing private_key';
	};

	subtest 'rsa type — valid' => sub {
		my $ch = make_credhub();
		$set_result_json = encode_json({ id => 'rsa-id-1', value => 'rsa-data' });

		no warnings 'redefine';
		local *Service::Credhub::run = $mock_set_run;
		use warnings 'redefine';

		my $id = $ch->set('keys/rsa', {
			public_key  => 'rsa-pub',
			private_key => 'rsa-priv',
		}, 'rsa');
		is($id, 'rsa-id-1', 'rsa type succeeds');
	};

	subtest 'rsa type — missing keys' => sub {
		my $ch = make_credhub();

		no warnings 'redefine';
		local *Service::Credhub::bail = sub { die @_ > 1 ? sprintf($_[0], @_[1..$#_]) : $_[0] };
		local *Service::Credhub::run = $mock_set_run;
		use warnings 'redefine';

		throws_ok {
			$ch->set('keys/rsa', { private_key => 'priv' }, 'rsa')
		} qr/public_key/,
			'dies when rsa missing public_key';
	};

	subtest 'user type — valid' => sub {
		my $ch = make_credhub();
		$set_result_json = encode_json({ id => 'user-id-1', value => 'user-data' });

		no warnings 'redefine';
		local *Service::Credhub::run = $mock_set_run;
		use warnings 'redefine';

		my $id = $ch->set('app/admin', {
			username => 'admin',
			password => 's3cret',
		}, 'user');
		is($id, 'user-id-1', 'user type succeeds');
	};

	subtest 'user type — missing password' => sub {
		my $ch = make_credhub();

		no warnings 'redefine';
		local *Service::Credhub::bail = sub { die @_ > 1 ? sprintf($_[0], @_[1..$#_]) : $_[0] };
		local *Service::Credhub::run = $mock_set_run;
		use warnings 'redefine';

		throws_ok {
			$ch->set('app/admin', { username => 'admin' }, 'user')
		} qr/password/,
			'dies when user missing password';
	};

	subtest 'password type — valid' => sub {
		my $ch = make_credhub();
		$set_result_json = encode_json({ id => 'pw-id-1', value => 'pass-data' });

		no warnings 'redefine';
		local *Service::Credhub::run = $mock_set_run;
		use warnings 'redefine';

		my $id = $ch->set('db/pass', { password => 'hunter2' }, 'password');
		is($id, 'pw-id-1', 'password type succeeds');
	};

	subtest 'password type — missing password' => sub {
		my $ch = make_credhub();

		no warnings 'redefine';
		local *Service::Credhub::bail = sub { die @_ > 1 ? sprintf($_[0], @_[1..$#_]) : $_[0] };
		local *Service::Credhub::run = $mock_set_run;
		use warnings 'redefine';

		throws_ok {
			$ch->set('db/pass', {}, 'password')
		} qr/password/,
			'dies when password type missing password';
	};

	subtest 'unknown type — dies' => sub {
		my $ch = make_credhub();

		no warnings 'redefine';
		local *Service::Credhub::bail = sub { die @_ > 1 ? sprintf($_[0], @_[1..$#_]) : $_[0] };
		local *Service::Credhub::run = $mock_set_run;
		use warnings 'redefine';

		throws_ok { $ch->set('path', 'val', 'bogus') }
			qr/Unknown CredHub type.*bogus/,
			'dies on unknown type';
	};

	subtest 'set() — list context returns tuple' => sub {
		my $ch = make_credhub();
		my $out_json = encode_json({ id => 'tuple-id', value => 'v' });

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			return ($out_json, 0, '');
		};
		use warnings 'redefine';

		my ($out, $rc, $err) = $ch->set('db/pass', 'myval');
		is($rc, 0, 'rc is 0 on success');
		is($out, $out_json, 'stdout returned');
		is($err, '', 'no stderr');
	};

	subtest 'set() — scalar context dies on error' => sub {
		my $ch = make_credhub();

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			return ('stdout-output', 42, 'set failed');
		};
		local *Service::Credhub::bail = sub { die @_ > 1 ? sprintf($_[0], @_[1..$#_]) : $_[0] };
		use warnings 'redefine';

		throws_ok { scalar $ch->set('db/pass', 'val') }
			qr/Could not create/,
			'scalar context dies on non-zero rc';
	};

	subtest 'set() — list context returns error without dying' => sub {
		my $ch = make_credhub();

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			return ('error-output', 1, 'error-stderr');
		};
		use warnings 'redefine';

		my ($out, $rc, $err) = $ch->set('db/pass', 'val');
		is($rc, 1, 'non-zero rc returned');
		is($err, 'error-stderr', 'stderr returned');
	};

	subtest 'set() — cache updated when populated' => sub {
		my $ch = make_credhub();
		$ch->{cached} = { 'existing' => 'old' };
		my $result_json = encode_json({ id => 'cache-id', value => 'new-value' });

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			return ($result_json, 0, '');
		};
		use warnings 'redefine';

		$ch->set('db/password', 'new-value');
		is($ch->{cached}{'db/password'}, 'new-value', 'cache updated after set');
		is($ch->{cached}{'existing'}, 'old', 'existing cache entries preserved');
	};

	subtest 'set() — cache not created when not populated' => sub {
		my $ch = make_credhub();
		# No cache initialized

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			return (encode_json({ id => 'no-cache-id', value => 'v' }), 0, '');
		};
		use warnings 'redefine';

		$ch->set('db/password', 'val');
		ok(!defined($ch->{cached}), 'cache not created when not previously populated');
	};
};

# ============================================================
# Phase 5: List/Delete/Query/Execute
# ============================================================

subtest 'Phase 5: List/Delete/Query/Execute' => sub {

	subtest 'paths() — no filter' => sub {
		my $ch = make_credhub(base => '/test-bosh');
		my @captured_cmd;
		my $find_json = encode_json({
			credentials => [
				{ name => '/test-bosh/db/password' },
				{ name => '/test-bosh/tls/cert' },
			]
		});

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			shift;
			@captured_cmd = @_;
			return ($find_json, 0, '');
		};
		use warnings 'redefine';

		my @paths = $ch->paths();
		is(scalar(@paths), 2, 'returns 2 paths');
		is($paths[0], '/test-bosh/db/password', 'first path correct');
		is($paths[1], '/test-bosh/tls/cert', 'second path correct');

		# Verify -n flag passes base path
		my $found_n = 0;
		for (my $i = 0; $i < $#captured_cmd; $i++) {
			if ($captured_cmd[$i] eq '-n') {
				is($captured_cmd[$i+1], '/test-bosh/', '-n flag uses base()');
				$found_n = 1;
			}
		}
		ok($found_n, '-n flag present for no-filter call');
	};

	subtest 'paths() — string filter (server-side)' => sub {
		my $ch = make_credhub(base => '/test-bosh');
		my @captured_cmd;
		my $find_json = encode_json({
			credentials => [
				{ name => '/test-bosh/db/password' },
			]
		});

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			shift;
			@captured_cmd = @_;
			return ($find_json, 0, '');
		};
		use warnings 'redefine';

		my @paths = $ch->paths('db/');
		is(scalar(@paths), 1, 'string filter returns matching paths');

		# Verify the full path was passed to -n
		my $found_n = 0;
		for (my $i = 0; $i < $#captured_cmd; $i++) {
			if ($captured_cmd[$i] eq '-n') {
				is($captured_cmd[$i+1], '/test-bosh/db/', '-n uses _full_path for string filter');
				$found_n = 1;
			}
		}
		ok($found_n, '-n flag present for string filter');
	};

	subtest 'paths() — regexp filter (client-side)' => sub {
		my $ch = make_credhub(base => '/test-bosh');
		my $find_json = encode_json({
			credentials => [
				{ name => '/test-bosh/db/password' },
				{ name => '/test-bosh/tls/cert' },
				{ name => '/test-bosh/db/username' },
			]
		});
		my @captured_cmd;

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			shift;
			@captured_cmd = @_;
			return ($find_json, 0, '');
		};
		use warnings 'redefine';

		my @paths = $ch->paths(qr/\/db\//);
		is(scalar(@paths), 2, 'regexp filter returns matching paths only');
		ok((grep { /db\/password/ } @paths), 'db/password matched');
		ok((grep { /db\/username/ } @paths), 'db/username matched');
		ok(!(grep { /tls/ } @paths), 'tls/cert excluded by regexp');

		# Verify no -n filter was passed (client-side filtering)
		my $found_n = 0;
		for (my $i = 0; $i < $#captured_cmd; $i++) {
			$found_n = 1 if $captured_cmd[$i] eq '-n';
		}
		ok(!$found_n, 'no -n flag for regexp filter (client-side)');
	};

	subtest 'paths() — empty result' => sub {
		my $ch = make_credhub();

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			return ('', 1, 'No credentials exist which match the provided parameters.');
		};
		use warnings 'redefine';

		my @paths = $ch->paths();
		is(scalar(@paths), 0, 'returns empty list for no matches');
	};

	subtest 'paths() — error handling (non-match error)' => sub {
		my $ch = make_credhub();

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			return ('', 1, 'connection refused');
		};
		local *Service::Credhub::bail = sub { die @_ > 1 ? sprintf($_[0], @_[1..$#_]) : $_[0] };
		use warnings 'redefine';

		throws_ok { $ch->paths() }
			qr/Could not list CredHub paths/,
			'dies on non-match error';
	};

	subtest 'delete() — calls correct command' => sub {
		my $ch = make_credhub(base => '/test-bosh');
		my @captured_cmd;

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			shift;
			@captured_cmd = @_;
			return ('', 0, '');
		};
		use warnings 'redefine';

		my ($out, $rc, $err) = $ch->delete('db/password');
		is($rc, 0, 'returns success rc');
		is($captured_cmd[0], 'credhub', 'command is credhub');
		is($captured_cmd[1], 'delete', 'subcommand is delete');
		is($captured_cmd[2], '--name', 'uses --name flag');
		is($captured_cmd[3], '/test-bosh/db/password', 'passes full path');
	};

	subtest 'delete_all() — calls correct command' => sub {
		my $ch = make_credhub(base => '/test-bosh');
		my @captured_cmd;

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			shift;
			@captured_cmd = @_;
			return ('', 0, '');
		};
		use warnings 'redefine';

		my ($out, $rc, $err) = $ch->delete_all('db/');
		is($rc, 0, 'returns success rc');
		is($captured_cmd[0], 'credhub', 'command is credhub');
		is($captured_cmd[1], 'delete', 'subcommand is delete');
		is($captured_cmd[2], '--path', 'uses --path flag');
		is($captured_cmd[3], '/test-bosh/db/', 'passes full path');
	};

	subtest 'query() — basic GET' => sub {
		my $ch = make_credhub();
		my @captured_cmd;
		my $api_json = encode_json({ data => [{ name => '/cred1' }] });

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			shift;
			@captured_cmd = @_;
			return ($api_json, 0, '');
		};
		use warnings 'redefine';

		my $result = $ch->query('/api/v1/data');
		is(ref($result), 'HASH', 'returns parsed JSON hashref');
		ok(exists $result->{data}, 'parsed data key present');
		is($captured_cmd[0], 'credhub', 'command is credhub');
		is($captured_cmd[1], 'curl', 'subcommand is curl');
		is($captured_cmd[2], '--path', '--path flag');
		is($captured_cmd[3], '/api/v1/data', 'path passed correctly');
	};

	subtest 'query() — with _method' => sub {
		my $ch = make_credhub();
		my @captured_cmd;

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			shift;
			@captured_cmd = @_;
			return (encode_json({}), 0, '');
		};
		use warnings 'redefine';

		$ch->query('/api/v1/data', _method => 'post');
		ok((grep { $_ eq '-X' } @captured_cmd), '-X flag present');
		ok((grep { $_ eq 'POST' } @captured_cmd), 'method uppercased to POST');
	};

	subtest 'query() — with _data' => sub {
		my $ch = make_credhub();
		my @captured_cmd;
		my $body = '{"name":"/test"}';

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			shift;
			@captured_cmd = @_;
			return (encode_json({}), 0, '');
		};
		use warnings 'redefine';

		$ch->query('/api/v1/data', _data => $body);
		ok((grep { $_ eq '-d' } @captured_cmd), '-d flag present');
		ok((grep { $_ eq $body } @captured_cmd), 'data body passed');
	};

	subtest 'query() — combined _method and _data' => sub {
		my $ch = make_credhub();
		my @captured_cmd;

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			shift;
			@captured_cmd = @_;
			return (encode_json({ status => 'ok' }), 0, '');
		};
		use warnings 'redefine';

		my $result = $ch->query('/api/v1/data',
			_method => 'put',
			_data   => '{"value":"new"}',
		);
		ok((grep { $_ eq '-X' } @captured_cmd), '-X flag for combined');
		ok((grep { $_ eq 'PUT' } @captured_cmd), 'PUT method for combined');
		ok((grep { $_ eq '-d' } @captured_cmd), '-d flag for combined');
		is($result->{status}, 'ok', 'parsed response returned');
	};

	subtest 'execute() — passes args and env' => sub {
		my $ch = make_credhub();
		my ($captured_opts, @captured_cmd);

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			$captured_opts = shift;
			@captured_cmd = @_;
			return ('version 2.9.0', 0, '');
		};
		use warnings 'redefine';

		my ($out, $rc, $err) = $ch->execute('version');
		is($rc, 0, 'returns success');
		is($captured_cmd[0], 'credhub', 'command is credhub');
		is($captured_cmd[1], 'version', 'subcommand passed');
		ok($captured_opts->{interactive}, 'interactive mode set');
		ok(exists $captured_opts->{env}, 'env passed');
		is($captured_opts->{redact_env}, 1, 'env redacted');
	};

	subtest 'execute() — passes extra args' => sub {
		my $ch = make_credhub();
		my @captured_cmd;

		no warnings 'redefine';
		local *Service::Credhub::run = sub {
			shift;
			@captured_cmd = @_;
			return ('', 0, '');
		};
		use warnings 'redefine';

		$ch->execute('find', '-j', '-n', '/prod-bosh/');
		is($captured_cmd[0], 'credhub', 'command is credhub');
		is($captured_cmd[1], 'find', 'subcommand passed');
		is($captured_cmd[2], '-j', 'extra arg 1');
		is($captured_cmd[3], '-n', 'extra arg 2');
		is($captured_cmd[4], '/prod-bosh/', 'extra arg 3');
	};
};

done_testing;
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1
