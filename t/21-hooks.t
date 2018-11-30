#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::Exception;
use Test::Deep;
use Test::Output;

use_ok 'Genesis::Kit';
use Genesis::Kit::Dev;
use Genesis::Top;
use Genesis::Vault;

my $tmp = workdir;
my $top;  # Genesis::Top
my $root; # absolute path to $top's root

# test kits from t/src/*
my $simple;
my $fancy;
my $legacy;

# test environments, created on-the-fly
my $us_west_1_prod;
my $snw_lab_dev;
my $stack_scale;

my $vault_target = vault_ok;

sub again {
	system("rm -rf $tmp; mkdir -p $tmp");
	fake_bosh;
	$top    = Genesis::Top->create($tmp, 'thing', vault=>$VAULT_URL);
	$root   = $top->path;
	$simple = Genesis::Kit::Dev->new("t/src/simple");
	$fancy  = Genesis::Kit::Dev->new("t/src/fancy");
	$legacy = Genesis::Kit::Dev->new("t/src/legacy");

	put_file "$root/dev/kit.yml", "--- {}\n";
	put_file "$root/us-west-1-prod.yml", <<EOF;
---
kit:
  name:    dev
  version: latest
genesis:
  env: us-west-1-prod
EOF
	$us_west_1_prod = $top->load_env('us-west-1-prod');

	put_file "$root/snw-lab-dev.yml", <<EOF;
---
kit:
  name:    dev
  version: latest
  features:
    - alpha
    - foxtrot
    - uniform
    - charlie
    - kilo
genesis:
  env: snw-lab-dev
EOF
	$snw_lab_dev = $top->load_env('snw-lab-dev');

	put_file "$root/stack-scale.yml", <<EOF;
---
kit:
  name:    dev
  version: latest
  subkits:
    - do-thing
genesis:
  env: stack-scale
EOF
	$stack_scale = $top->load_env('stack-scale');
}

my $has_shellcheck = !system('command shellcheck -V >/dev/null 2>&1');
printf STDERR "\n\n\e[33m%s\e[0m\n%s\n\n",
	"SKIPPING 'Validate hooks helper script' tests due to missing 'shellcheck' command",
	"See https://github.com/koalaman/shellcheck/blob/master/README.md for installation and usage instructions"
		unless ($has_shellcheck);

subtest 'Validate hooks helper script' => sub {

	plan skip_all => "Cannot validate hooks helper because shellcheck is not installed"
	unless $has_shellcheck;

	use Genesis::Helpers;

	my $helper_script = $tmp . "/helpers.sh";
	lives_ok { Genesis::Helpers->write($helper_script); } "Can write the helper script to file";
	my $out = qx{
		shellcheck $helper_script  -s bash -f json \\
		| jq -cr '.[] | select(.level == "error" or .level == "warning")'
	};

	my @msg = ();
	if ($out ne "") {
		my (@lines, $offset);
		if ($INC{'Genesis/Helpers.pm'}) {
			open my $handle, '<', $INC{'Genesis/Helpers.pm'};
			chomp(@lines = <$handle>);
			close $handle;
			my $i=0;
			foreach (@lines) {
				$i++;
				if ($_ eq '__DATA__') {
					$offset = $i;
					last;
				}
			}
		}

		my $startline = qx(grep -n '^__DATA__\$' "${INC{'Genesis/Helpers.pm'}}" | awk -F: '{print \$1}');
		foreach (split($/, $out)) {
			my $err   = decode_json($_);
			my $linen = $offset + $err->{line};
			my $coln  = $err->{column};
			my $line  = $lines[$linen-1];
			my $i = 0;
			while ($i < $coln) {
				if (substr($line,$i,1) eq "\t") {
					substr($line, $i, 1) = "  "; # replace tab with 2 spaces
					$i++;
					$coln -= 6; # realign column (tabs count as 8 spaces in shellcheck)
				}
				$i++;
			}

			push (@msg, sprintf(
					"[SC%s - %s] %s:\n%s\n%s^--- [line %d, column %d]",
					$err->{code}, uc($err->{level}), $err->{message},
					$line,
					" " x ($coln-1), $linen, $coln
			));
		}
	}
	ok($out eq "", "$INC{'Genesis/Helpers.pm'} script should not contain any errors or warnings") or
		diag "\n".join("\n\n", @msg);
};

subtest 'invalid or nonexistent hooks' => sub {
	again();

	ok $fancy->has_hook('xyzzy');
	throws_ok { $fancy->run_hook('xyzzy', env => $snw_lab_dev); }
		qr/unrecognized/i;

	ok !$simple->has_hook('info');
	throws_ok { $simple->run_hook('info', env => $us_west_1_prod); }
		qr/no 'info' hook script found/i;
};

subtest 'new hook' => sub {
	again();

	my $vault = Genesis::Vault::default();

	ok $simple->run_hook('new', env => $us_west_1_prod),
	   "[simple] running the 'new' hook should succeed";

	ok -f "$root/us-west-1-prod.yml",
	   "[simple] the 'new' hook should create the env yaml file";

	yaml_is get_file("$root/us-west-1-prod.yml"), <<EOF,
kit:
  name:     dev
  version:  latest
  features: []
genesis:
  env:   us-west-1-prod
  secrets_path: us/west/1/prod/thing
EOF
		"[simple] the 'new' hook should populate the env yaml file properly";


	ok $fancy->run_hook('new', env => $snw_lab_dev),
	   "[fancy] running the 'new' hook should succeed";
	
	ok -f "$root/snw-lab-dev.yml",
	   "[fancy] the 'new' hook should create the env yaml file";

	yaml_is get_file("$root/snw-lab-dev.yml"), <<EOF,
kit:
  name:     dev
  version:  latest
  features: []
genesis:
  env: snw-lab-dev
  secrets_path: snw/lab/dev/thing
params:
  GENESIS_KIT_NAME:     dev
  GENESIS_KIT_VERSION:  latest
  GENESIS_ENVIRONMENT:  snw-lab-dev
  GENESIS_VAULT_PREFIX: snw/lab/dev/thing
  GENESIS_ROOT:         $root
  GENESIS_TARGET_VAULT: "$VAULT_URL"
  GENESIS_VERIFY_VAULT: 1

  root:   $root
  prefix: snw/lab/dev/thing
  extra:  (none)
EOF
		"[fancy] the 'new' hook should populate the env yaml file properly";


	{
		local $ENV{HOOK_SHOULD_FAIL} = 'yes';
		throws_ok {
			$fancy->run_hook('new',
				env => Genesis::Env->new(top => $top, name => 'env-should-fail', vault => $vault));
		} qr/could not create/i;

		ok ! -f "$root/env-should-fail.yml",
		   "[fancy] if the 'new' hook script exists non-zero, the env file should not get created";
	}

	{
		local $ENV{HOOK_SHOULD_CREATE_ENV_FILE} = 'no';
		throws_ok {
			$fancy->run_hook('new',
				env => Genesis::Env->new(top => $top, name => 'env-should-fail', vault => $vault));
		} qr/could not create/i;

		ok ! -f "$root/env-should-fail.yml",
		   "[fancy] if the 'new' hook script fails, the env file shoud be missing";
	}
};

subtest 'blueprint hook' => sub {
	again();

	cmp_deeply([$simple->run_hook('blueprint', env => $us_west_1_prod)], [qw[
			manifest.yml
		]], "[simple] blueprint hook should return the relative manifest file paths");

	cmp_deeply([$fancy->run_hook('blueprint', env => $snw_lab_dev)], [qw[
			base.yml
			addons/alpha.yml
			addons/foxtrot.yml
			addons/uniform.yml
			addons/charlie.yml
			addons/kilo.yml
			addons/bravo.yml
		]], "[fancy] blueprint hook should return the relative manifest file paths");

	{
		local $ENV{HOOK_SHOULD_FAIL} = 'yes';
		throws_ok { $fancy->run_hook('blueprint', env => $snw_lab_dev); }
			qr/could not determine which yaml files/i;
	}

	{
		local $ENV{HOOK_NO_BLUEPRINT} = 'yes';
		throws_ok { $fancy->run_hook('blueprint', env => $snw_lab_dev); }
			qr/could not determine which yaml files/i;
	}

	{
		local $ENV{HOOK_SHOULD_BE_AIRY} = 'yes';
		cmp_deeply([$fancy->run_hook('blueprint', env => $snw_lab_dev)], [qw[
				base.yml
				addons/alpha.yml
				addons/foxtrot.yml
				addons/uniform.yml
				addons/charlie.yml
				addons/kilo.yml
				addons/bravo.yml
			]], "[fancy] blueprint hook should ignore whitespace");
	}
};

subtest 'secrets hook' => sub {
	my ($rc, $s, $value);

	again();

	## secrets check
	qx(safe rm secret/snw/lab/dev/thing/args secret/snw/lab/dev/thing/env);
	stdout_is(sub { $rc = $fancy->run_hook('secrets', env => $snw_lab_dev,
	                                                  action => 'check') }, <<EOF,
[admin:password] is missing
EOF
		"[fancy] 'secrets check' hook output should be correct");
	ok !$rc, "[fancy] running the 'secrets check' hook should return failure if anything is missing";

	$s = 'secret/snw/lab/dev/thing/args';
	is secret("$s:all"), '{}', "'secrets check' hook should get no arguments";

	$s = 'secret/snw/lab/dev/thing/env';
	is secret("$s:GENESIS_KIT_NAME"),      'dev',               'check:GENESIS_KIT_NAME';
	is secret("$s:GENESIS_KIT_VERSION"),   'latest',            'check:GENESIS_KIT_VERISON';
	is secret("$s:GENESIS_ROOT"),          $top->path,          'check:GENESIS_ROOT';
	is secret("$s:GENESIS_ENVIRONMENT"),   'snw-lab-dev',       'check:GENESIS_ENVIRONMENT';
	is secret("$s:GENESIS_VAULT_PREFIX"),  'snw/lab/dev/thing', 'check:GENESIS_VAULT_PREFIX';
	is secret("$s:GENESIS_SECRET_ACTION"), 'check',             'check:GENESIS_SECRET_ACTION';


	## secrets add
	qx(safe rm secret/snw/lab/dev/thing/args secret/snw/lab/dev/thing/env);
	stdout_is(sub { $rc = $fancy->run_hook('secrets', env => $snw_lab_dev,
	                                                  action => 'add') }, <<EOF,
[admin:password] generating new administrator password
EOF
		"[fancy] 'secrets add' hook output should be correct");
	ok $rc, "[fancy] running the 'secrets add' hook should succeed";

	$s = 'secret/snw/lab/dev/thing/args';
	is secret "$s:all", '{}', "'secrets add' hook should get no arguments";

	$s = 'secret/snw/lab/dev/thing/env';
	is secret("$s:GENESIS_KIT_NAME"),      'dev',               'add:GENESIS_KIT_NAME';
	is secret("$s:GENESIS_KIT_VERSION"),   'latest',            'add:GENESIS_KIT_VERISON';
	is secret("$s:GENESIS_ROOT"),          $top->path,          'add:GENESIS_ROOT';
	is secret("$s:GENESIS_ENVIRONMENT"),   'snw-lab-dev',       'add:GENESIS_ENVIRONMENT';
	is secret("$s:GENESIS_VAULT_PREFIX"),  'snw/lab/dev/thing', 'add:GENESIS_VAULT_PREFIX';
	is secret("$s:GENESIS_SECRET_ACTION"), 'add',               'add:GENESIS_SECRET_ACTION';

	## secrets check (after an add)
	stdout_is(sub { $rc = $fancy->run_hook('secrets', env => $snw_lab_dev,
	                                                  action => 'check') }, <<EOF,
all secrets and certs present!
EOF
		"[fancy] 'secrets check' hook output should be correct");
	ok $rc, "[fancy] running the 'secrets check' hook should succeed if all secrets are present";


	## secrets rotate
	stdout_is(sub { $rc = $fancy->run_hook('secrets', env => $snw_lab_dev,
	                                                  action => 'rotate') }, <<EOF,
[admin:password] rotating administrator password
EOF
		"[fancy] 'secrets rotate' hook should succeed");

	$s = 'secret/snw/lab/dev/thing/args';
	is secret "$s:all", '{}', "'secrets rotate' hook should get no arguments";

	$s = 'secret/snw/lab/dev/thing/env';
	is secret("$s:GENESIS_KIT_NAME"),      'dev',               'rotate:GENESIS_KIT_NAME';
	is secret("$s:GENESIS_KIT_VERSION"),   'latest',            'rotate:GENESIS_KIT_VERISON';
	is secret("$s:GENESIS_ROOT"),          $top->path,          'rotate:GENESIS_ROOT';
	is secret("$s:GENESIS_ENVIRONMENT"),   'snw-lab-dev',       'rotate:GENESIS_ENVIRONMENT';
	is secret("$s:GENESIS_VAULT_PREFIX"),  'snw/lab/dev/thing', 'rotate:GENESIS_VAULT_PREFIX';
	is secret("$s:GENESIS_SECRET_ACTION"), 'rotate',            'rotate:GENESIS_SECRET_ACTION';
};

subtest 'check hook' => sub {
	again();

	my $rc;
	stdout_is(sub { $rc = $fancy->run_hook('check', env => $snw_lab_dev) }, <<EOF,
everything checks out!
EOF
		"[fancy] check hook output should be correct");
	ok $rc, "[fancy] running the 'check' hook should succeed";

	{
		local $ENV{HOOK_SHOULD_FAIL} = 'yes';
		ok !$fancy->run_hook('check', env => $snw_lab_dev),
			"check hooks return non-zero when they fail";
	}
};

subtest 'addon hook' => sub {
	again();

	my $rc;
	stdout_is(sub {
			$rc = $fancy->run_hook('addon', env => $snw_lab_dev,
			                                script => 'stooge',
			                                args => [qw[larry curly moe]]);
		}, <<EOF,
fancy:>> executing [stooge]
  - [larry]
  - [curly]
  - [moe]
EOF
		"[fancy] addon hook output should be correct");
	ok $rc, "[fancy] running the 'addon' hook should succeed";

	stdout_is(sub {
			$rc = $fancy->run_hook('addon', env => $snw_lab_dev,
			                                script => 'stooge');
		}, <<EOF,
fancy:>> executing [stooge]
EOF
		"[fancy] addon hook output should be correct (without args)");
	ok $rc, "[fancy] running the 'addon' hook should succeed (without args)";
};

subtest 'info hook' => sub {
	again();

	my $rc;
	stdout_is(sub { $rc = $fancy->run_hook('info', env => $snw_lab_dev); }, <<EOF,
===[ your HOOK deployment ]======================

   env name  : snw-lab-dev
   deploying : dev/latest
   from      : $root
   vault at  : snw/lab/dev/thing

   arguments : [(none)]

=================================================
EOF
		"[fancy] info hook output should be correct");
	ok $rc, "[fancy] running the 'info' hook should succeed";

	{
		local $ENV{HOOK_SHOULD_FAIL} = 'yes';
		throws_ok { $fancy->run_hook('info', env => $snw_lab_dev) }
			qr/could not run 'info' hook/i;
	}
};

subtest 'LEGACY prereqs hook' => sub {
	ok 1;
};

subtest 'LEGACY subkit hook' => sub {
	again();

	cmp_deeply([$legacy->run_hook('subkit', features => [$stack_scale->features])], [qw[
			do-thing
			forced-subkit
		]], "[legacy] the 'subkit' hook can force new subkits");

	{
		local $ENV{HOOK_SHOULD_FAIL} = 'yes';
		throws_ok { $legacy->run_hook('subkit', features => [$stack_scale->features]); }
			qr/could not determine which auxiliary subkits/i;
	}

	{
		local $ENV{HOOK_NO_SUBKITS} = 'yes';
		cmp_deeply([$legacy->run_hook('subkit', features => [$stack_scale->features])], [],
			"[legacy] the 'subkit' hook can remove all subkits");
	}

	{
		local $ENV{HOOK_SHOULD_BE_AIRY} = 'yes';
		cmp_deeply([$legacy->run_hook('subkit', features => [$stack_scale->features])], [qw[
				do-thing
			]], "[legacy] the 'subkit' hook ignores whitespace");
	}
};

teardown_vault();
done_testing;
