#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::Output;
use JSON::PP qw/encode_json/;

use_ok "Service::BOSH";
use_ok "Service::BOSH::Director";
use_ok "Service::BOSH::CreateEnvProxy";
use Genesis;

sub get_bosh_director {
	my $alias = shift || 'bosh-director';
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	Service::BOSH::Director->new($alias,url => 'https://127.0.0.1', ca_cert=>"ca_cert", client=>'admin', secret=>'password', exodus_path => 'secret/exodus', @_);
}
sub get_bosh_create_env {
	my $alias = shift;
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	Service::BOSH::CreateEnvProxy->new(@_);
}
subtest 'BOSH Director object' => sub {
	local $ENV{GENESIS_BOSH_COMMAND};
	bosh_runs_as('foo');
	my $bosh = get_bosh_director('local');

	ok $bosh->execute({ passfail => 1 }, 'bosh', 'foo'),
		"(bosh foo), pre-tokenized, should execute properly";
	ok $bosh->execute({ passfail => 1 }, 'foo'),
		"(foo), pre-tokenized, should execute properly";
	ok $bosh->execute({ passfail => 1 }, 'bosh foo'),
		"simple 'bosh foo' should execute properly";
	ok $bosh->execute({ passfail => 1 }, 'bosh foo | cat $1', '/dev/null'),
		"complex 'bosh foo | ...' (with vars) should execute properly";
	ok $bosh->execute({ passfail => 1 }, 'foo | cat $1', '/dev/null'),
		"complex 'foo | ...' (with vars) should execute properly";
};

subtest 'bosh connect_and_validate' => sub {
	local $ENV{GENESIS_BOSH_COMMAND};
	my $director = fake_bosh_director('the-target');
	bosh_runs_as('env',<<EOF,BOSH_ENVIRONMENT => "https://127.0.0.1:25555", BOSH_CA_CERT => 'ca_cert', BOSH_CLIENT => 'admin', BOSH_CLIENT_SECRET => 'password', BOSH_DEPLOYMENT => '');
Using environment 'https://127.0.0.1:25555' as user 'admin'

Name               the-target-bosh
UUID               c406e16b-600e-4ceb-a736-69dd50512a80
Version            271.2.0 (00000000)
Director Stemcell  ubuntu-xenial/621.74
CPI                vsphere_cpi
Features           compiled_package_cache: disabled
                   config_server: enabled
                   local_dns: enabled
                   power_dns: disabled
                   snapshots: disabled
User               admin

Succeeded
EOF
	my $bosh = get_bosh_director('the-target');
	ok $bosh->connect_and_validate(), "bosh env on alias should ping ok";
	$director->stop();
};

subtest 'bosh create-env' => sub {
	pushd $ENV{HOME};
	local $ENV{GENESIS_BOSH_COMMAND};
	my ($out, $rc);
	bosh_runs_as("create-env --state state.json manifest.yml");
	my $bosh = get_bosh_create_env();
	($out,$rc) = $bosh->create_env("manifest.yml", state => "state.json");
	ok !$rc, "create_env with state file should work";

	quietly {
		throws_ok { $bosh->create_env() }
			qr/missing deployment manifest/i;
  };

	quietly {
		throws_ok { $bosh->create_env("manifest.yml") }
			qr/missing 'state' option/i;
	};

	mkdir_or_fail('path/to');
	mkfile_or_fail('path/to/vars-file.yml', <<'EOF');
---
name: some-name
version: some-version
EOF
	bosh_runs_as("create-env --state state.json -l path/to/vars-file.yml manifest.yml");
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	($out, $rc) = $bosh->create_env("manifest.yml", state => "state.json", vars_file => "path/to/vars-file.yml");
	ok !$rc, "create_env with state file and vars-file should work";

	local $ENV{BOSH_NON_INTERACTIVE} = 'yes';
	bosh_runs_as("-n create-env --state state.json manifest.yml");
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	($out,$rc) = $bosh->create_env("manifest.yml", state => "state.json");
	ok !$rc, "create_env honors BOSH_NON_INTERACTIVE";
	popd;
};

subtest 'bosh cloud-config' => sub {
	my $out = workdir;

	local $ENV{GENESIS_BOSH_COMMAND};
	bosh_outputs_json('config --type cloud --name default --json',"() # cloud-config");
	ok get_bosh_director('some-env')->download_configs("$out/cloud.yml", 'cloud','default'),
		"download_cloud_config should work";

	bosh_outputs_json('config --type cloud --name default --json',"");
	quietly { throws_ok { get_bosh_director('some-env')->download_configs("$out/cloud.yml", 'cloud', 'default') }
		qr/no cloud config content/i,
		"without cloud-config output, download_cloud_config should fail";
	};
};

subtest 'bosh deploy' => sub {
	local $ENV{GENESIS_BOSH_COMMAND};
	bosh_runs_as(
		"deploy --some --flags manifest.yml",undef,
		BOSH_ALIAS=>'my-env',
		BOSH_ENVIRONMENT=>'http://10.0.0.1:25678',
		BOSH_DEPLOYMENT=>'my-dep'
	);
	lives_ok {
		get_bosh_director('my-env',deployment => 'my-dep',url => 'http://10.0.0.1:25678')
			->deploy( 'manifest.yml', flags => ['--some', '--flags']);
	} "deploy should pass through options and flags properly";

	bosh_runs_as(
		"--some --flags -l path/to/vars-file.yml manifest.yml", undef,
		BOSH_ENVIRONMENT=>'https://127.0.0.1:25555',
		BOSH_DEPLOYMENT=>'my-dep'
	);
	lives_ok {
		get_bosh_director('some-env',deployment => 'my-dep')
			->deploy('manifest.yml',
			         vars_file  => "path/to/vars-file.yml",
			         flags      => ['--some', '--flags']);
	} "deploy should pass through vars-file, options and flags properly";

	bosh_runs_as(
		"--some --flags -l path/to/vars-file.yml manifest.yml", undef,
		BOSH_ALIAS=>'an-env',
		BOSH_ENVIRONMENT=>'https://127.0.0.1:25555',
		BOSH_DEPLOYMENT=>'some-dep'
	);
	quietly { throws_ok { get_bosh_director('an-env',deployment => 'some-dep')->deploy() }
		qr/Missing manifest/i;
	};
	quietly {throws_ok { get_bosh_director('an-env')->deploy('manifest.yml') }
		qr/No deployment name/i;
	};
};

subtest 'bosh run_errand' => sub {
	local $ENV{GENESIS_BOSH_COMMAND};
	bosh_runs_as(
		"-n run-errand smoke-tests", undef,
		BOSH_ALIAS=>'an-env',
		BOSH_ENVIRONMENT=>'https://127.0.0.1:25555',
		BOSH_DEPLOYMENT=>'some-deployment'
	);
	lives_ok {
		get_bosh_director('an-env',deployment=>'some-deployment')->run_errand('smoke-tests');
	} "run_errand works with env, deploytment, and errand name set";

	quietly {throws_ok {
		get_bosh_director('an-env')->run_errand("an-env")
	} qr/No deployment name/i; };
	quietly {throws_ok {
		get_bosh_director('an-env',deployment=>'some-deployment')->run_errand()
	} qr/Missing errand name/i; };
};

subtest 'environment variable management' => sub {
	my $home = $ENV{HOME};
	my $path = $ENV{PATH};
	local %ENV;
	$ENV{HOME}=$home; # Genesis always needs $HOME
	$ENV{PATH}=$path; # Genesis relies on programs found under $PATH
	for (qw/ENVIRONMENT CA_CERT CLIENT CLIENT_SECRET DEPLOYMENT ALIAS/) {
		$ENV{"BOSH_$_"} = "calling_environment_$_";
	}

	fake_bosh(<<'EOF');
echo HTTPS_PROXY=$HTTPS_PROXY...
echo https_proxy=$https_proxy...
echo BOSH_ENVIRONMENT=$BOSH_ENVIRONMENT...
echo BOSH_CA_CERT=$BOSH_CA_CERT...
echo BOSH_CLIENT=$BOSH_CLIENT...
echo BOSH_CLIENT_SECRET=$BOSH_CLIENT_SECRET...
echo BOSH_DEPLOYMENT=$BOSH_DEPLOYMENT...
echo BOSH_ALIAS=$BOSH_ALIAS...
EOF

	$ENV{$_} = "a {$_} got missed" for (qw(
		HTTPS_PROXY        https_proxy
		BOSH_ENVIRONMENT   BOSH_CA_CERT
		BOSH_CLIENT        BOSH_CLIENT_SECRET));

	my $bosh=get_bosh_director('my-bosh');
	stdout_is(sub { $bosh->execute(
		{ interactive => 1 }, 'bosh', 'foo'
	); }, <<EOF,
HTTPS_PROXY=...
https_proxy=...
BOSH_ENVIRONMENT=https://127.0.0.1:25555...
BOSH_CA_CERT=ca_cert...
BOSH_CLIENT=admin...
BOSH_CLIENT_SECRET=password...
BOSH_DEPLOYMENT=...
BOSH_ALIAS=my-bosh...
EOF
		"bosh() helper should clear out the environment implicitly");

	$bosh->deployment('the-best-deployment');
	stdout_is(sub {$bosh->execute({
			interactive => 1,
			env => {
				BOSH_CA_CERT       => 'save my ca cert',
				BOSH_CLIENT        => 'save my client id',
				BOSH_CLIENT_SECRET => 'save my client secret',
			},
		}, 'bosh foo'); }, <<EOF,
HTTPS_PROXY=...
https_proxy=...
BOSH_ENVIRONMENT=https://127.0.0.1:25555...
BOSH_CA_CERT=save my ca cert...
BOSH_CLIENT=save my client id...
BOSH_CLIENT_SECRET=save my client secret...
BOSH_DEPLOYMENT=the-best-deployment...
BOSH_ALIAS=my-bosh...
EOF
		"bosh() helper should clear out the environment implicitly");
};

subtest 'Director accessor methods' => sub {
	plan tests => 8;

	# Create a director with known values
	local $ENV{GENESIS_BOSH_COMMAND};
	fake_bosh('');
	my $bosh = get_bosh_director('test-director', deployment => 'test-deployment');

	# Test alias()
	is($bosh->alias, 'test-director', 'alias() returns director alias');

	# Test deployment() getter
	is($bosh->deployment, 'test-deployment', 'deployment() getter returns deployment name');

	# Test deployment() setter
	$bosh->deployment('new-deployment');
	is($bosh->deployment, 'new-deployment', 'deployment() setter updates deployment name');

	# Test url()
	is($bosh->url, 'https://127.0.0.1:25555', 'url() returns full URL with schema and port');

	# Test host()
	is($bosh->host, '127.0.0.1', 'host() returns hostname');

	# Test exodus_path()
	is($bosh->exodus_path, 'secret/exodus', 'exodus_path() returns exodus path');

	# Test env() - should be undef since we didn't pass an env object
	is($bosh->env, undef, 'env() returns undef when no env object provided');

	# Test has_director() class method
	ok(Service::BOSH::Director->has_director(), 'has_director() class method returns true');

	# Note: vault()/exodus_vault() and constructor pattern tests
	# (from_exodus, from_alias, from_environment) require real vault instance.
	# These are tested in integration-tests/service_bosh_director.t
};

subtest 'bosh configs - list all configurations' => sub {
	plan tests => 6;

	local $ENV{GENESIS_BOSH_COMMAND};

	# Test with multiple configs of different types
	fake_bosh(<<'SCRIPT');
#!/bin/bash
case "$*" in
	*"configs -r=99999 --json"*)
		cat <<'JSON'
{"Tables":[{"Content":"configs","Header":{"id":"ID","type":"Type","name":"Name","team":"Team","created_at":"Created At"},"Rows":[{"id":"1*","type":"cloud","name":"default","team":"","created_at":"2024-01-15T10:30:00Z"},{"id":"2","type":"cloud","name":"default","team":"","created_at":"2024-01-10T09:00:00Z"},{"id":"3*","type":"cloud","name":"az1","team":"dev","created_at":"2024-01-20T14:00:00Z"},{"id":"4*","type":"runtime","name":"default","team":"","created_at":"2024-01-18T11:00:00Z"},{"id":"5","type":"runtime","name":"default","team":"","created_at":"2024-01-12T08:00:00Z"}],"Notes":null}],"Blocks":null,"Lines":["Using environment 'https://127.0.0.1:25555' as user 'admin'","Succeeded"]}
JSON
		;;
esac
SCRIPT

	my $bosh = get_bosh_director('test-env');
	my $configs = $bosh->configs();

	# Test cloud configs
	ok(exists $configs->{cloud}, 'configs() returns cloud configs');
	ok(exists $configs->{cloud}{default}, 'cloud config "default" exists');
	is($configs->{cloud}{default}{current}, 1, 'cloud config "default" current version is 1');
	ok(exists $configs->{cloud}{az1}, 'cloud config "az1" exists');

	# Test runtime configs
	ok(exists $configs->{runtime}{default}, 'runtime config "default" exists');
	is($configs->{runtime}{default}{current}, 4, 'runtime config "default" current version is 4');
};

subtest 'bosh has_config - check config existence' => sub {
	plan tests => 3;

	local $ENV{GENESIS_BOSH_COMMAND};

	fake_bosh(<<'SCRIPT');
#!/bin/bash
case "$*" in
	*"configs -r=1 --type=cloud --name=default --json"*)
		cat <<'JSON'
{"Tables":[{"Rows":[{"id":"1*","type":"cloud","name":"default","team":"","created_at":"2024-01-15T10:30:00Z"}]}]}
JSON
		;;
	*"configs -r=1 --type=cloud --name=nonexistent --json"*)
		cat <<'JSON'
{"Tables":[{"Rows":[]}]}
JSON
		;;
	*"configs -r=1 --type=runtime --name=default --json"*)
		cat <<'JSON'
{"Tables":[{"Rows":[{"id":"4*","type":"runtime","name":"default","team":"","created_at":"2024-01-18T11:00:00Z"}]}]}
JSON
		;;
esac
SCRIPT

	my $bosh = get_bosh_director('test-env');
	ok($bosh->has_config('cloud', 'default'), 'has_config() returns true for existing config');
	ok(!$bosh->has_config('cloud', 'nonexistent'), 'has_config() returns false for non-existent config');
	ok($bosh->has_config('runtime', 'default'), 'has_config() works for runtime configs');
};

subtest 'bosh get_config - retrieve config content' => sub {
	plan tests => 2;

	local $ENV{GENESIS_BOSH_COMMAND};

	fake_bosh(<<'SCRIPT');
#!/bin/bash
case "$*" in
	*"config --type=cloud --name=default --json"*)
		cat <<'JSON'
{"Tables":[{"Rows":[{"content":"---\nazs:\n- name: z1\n  cloud_properties:\n    availability_zone: us-east-1a\n- name: z2\n  cloud_properties:\n    availability_zone: us-east-1b\n"}]}]}
JSON
		;;
esac
SCRIPT

	my $bosh = get_bosh_director('test-env');
	my $config = $bosh->get_config('cloud', 'default');

	ok(defined $config, 'get_config() returns config content');
	like($config, qr/azs:/, 'config content contains expected YAML');
};

subtest 'bosh deployments - list all deployments' => sub {
	plan tests => 3;

	local $ENV{GENESIS_BOSH_COMMAND};

	fake_bosh(<<'SCRIPT');
#!/bin/bash
case "$*" in
	*"deployments --json"*)
		cat <<'JSON'
{"Tables":[{"Content":"deployments","Header":{"name":"Name","release_s":"Release(s)","stemcell_s":"Stemcell(s)","team_s":"Team(s)"},"Rows":[{"name":"cf-production","release_s":"cf/290.0.0\ncflinuxfs3/1.290.0","stemcell_s":"ubuntu-xenial/621.74","team_s":""},{"name":"concourse","release_s":"concourse/7.8.2\ngarden-runc/1.19.16","stemcell_s":"ubuntu-xenial/621.74","team_s":""}]}]}
JSON
		;;
esac
SCRIPT

	my $bosh = get_bosh_director('test-env');
	my $deployments = $bosh->deployments();

	is(ref($deployments), 'HASH', 'deployments() returns hash reference');
	is(scalar keys %$deployments, 2, 'deployments() returns correct count');
	ok(exists $deployments->{'cf-production'}, 'cf-production deployment exists');
};

subtest 'bosh has_deployment - check deployment existence' => sub {
	plan tests => 2;

	local $ENV{GENESIS_BOSH_COMMAND};

	fake_bosh(<<'SCRIPT');
#!/bin/bash
case "$*" in
	*"deployments --json"*)
		cat <<'JSON'
{"Tables":[{"Rows":[{"name":"cf-production"},{"name":"concourse"}]}]}
JSON
		;;
esac
SCRIPT

	my $bosh = get_bosh_director('test-env');
	ok($bosh->has_deployment('cf-production'), 'has_deployment() returns true for existing deployment');
	ok(!$bosh->has_deployment('vault'), 'has_deployment() returns false for non-existent deployment');
};

subtest 'bosh status - connection and authorization check' => sub {
	plan tests => 3;

	local $ENV{GENESIS_BOSH_COMMAND};

	# Set up fake director with listening socket
	my $director = fake_bosh_director('test-env');

	# Test successful connection
	fake_bosh(<<'SCRIPT');
#!/bin/bash
case "$*" in
	*"env"*)
		cat <<'OUTPUT'
Using environment 'https://127.0.0.1:25555' as user 'admin'

Name               proto-bosh
UUID               c406e16b-600e-4ceb-a736-69dd50512a80
Version            271.2.0 (00000000)
Director Stemcell  ubuntu-xenial/621.74
CPI                vsphere_cpi
User               admin

Succeeded
OUTPUT
		;;
esac
SCRIPT

	my $bosh = get_bosh_director('test-env');
	my $status = $bosh->status();

	is($status->{status}, 'ok', 'status() returns ok for successful connection');
	like($status->{msg}, qr/authorized as/, 'status() returns authorization message');
	ok(exists $status->{msg}, 'status() includes message');

	$director->stop();
};

subtest 'bosh upload_config_from_file - upload configuration' => sub {
	plan tests => 2;

	local $ENV{GENESIS_BOSH_COMMAND};

	# Test cloud config upload
	fake_bosh(<<'SCRIPT');
#!/bin/bash
case "$*" in
	*"update-config --type=cloud --name=default"*"-n"*)
		echo "Successfully uploaded cloud config"
		exit 0
		;;
	*"update-runtime-config --name=dns"*"-n"*)
		echo "Successfully uploaded runtime config"
		exit 0
		;;
esac
SCRIPT

	my $bosh = get_bosh_director('test-env');

	# Create temp config file
	my $tmp = workdir;
	my $cloud_config = "$tmp/cloud.yml";
	put_file($cloud_config, "---\nnetworks: []");

	ok($bosh->upload_config_from_file($cloud_config, 'cloud', 'default'),
		'upload_config_from_file() successfully uploads cloud config');

	my $runtime_config = "$tmp/runtime.yml";
	put_file($runtime_config, "---\nreleases: []");

	ok($bosh->upload_config_from_file($runtime_config, 'runtime', 'dns'),
		'upload_config_from_file() successfully uploads runtime config');
};

subtest 'bosh delete_config - delete configuration' => sub {
	plan tests => 2;

	local $ENV{GENESIS_BOSH_COMMAND};

	# Test config deletion
	fake_bosh(<<'SCRIPT');
#!/bin/bash
case "$*" in
	*"delete-config --type=cloud --name=old"*"-n"*)
		echo "Config deleted"
		exit 0
		;;
	*"delete-config --type=runtime --name=deprecated"*"-n"*)
		echo "Config deleted"
		exit 0
		;;
esac
SCRIPT

	my $bosh = get_bosh_director('test-env');

	ok($bosh->delete_config('cloud', 'old'),
		'delete_config() successfully deletes cloud config');

	ok($bosh->delete_config('runtime', 'deprecated'),
		'delete_config() successfully deletes runtime config');
};

subtest 'bosh delete_deployment - delete deployment' => sub {
	plan tests => 2;

	local $ENV{GENESIS_BOSH_COMMAND};

	# Test deployment deletion
	fake_bosh(<<'SCRIPT');
#!/bin/bash
case "$*" in
	*"delete-deployment -d my-deployment"*)
		echo "Deployment deleted"
		exit 0
		;;
	*"delete-deployment --force -d old-deployment"*)
		echo "Deployment force deleted"
		exit 0
		;;
esac
SCRIPT

	# Test normal deletion
	my $bosh = Service::BOSH::Director->new(
		'test-env',
		url => 'https://127.0.0.1:25555',
		client => 'admin',
		secret => 'password',
		ca_cert => 'fake-cert',
		deployment => 'my-deployment'
	);

	ok($bosh->delete_deployment(),
		'delete_deployment() successfully deletes deployment');

	# Test force deletion
	$bosh->{deployment} = 'old-deployment';
	ok($bosh->delete_deployment(force => 1),
		'delete_deployment() successfully force deletes deployment');
};

subtest 'bosh cleanup - cleanup BOSH director' => sub {
	plan tests => 2;

	local $ENV{GENESIS_BOSH_COMMAND};

	# Test cleanup
	fake_bosh(<<'SCRIPT');
#!/bin/bash
case "$*" in
	*"clean-up"*)
		echo "Cleanup completed"
		exit 0
		;;
	*"clean-up --all --keep-orphaned-disks"*)
		echo "Full cleanup with orphaned disks kept"
		exit 0
		;;
esac
SCRIPT

	my $bosh = get_bosh_director('test-env');

	ok($bosh->cleanup(),
		'cleanup() successfully cleans up BOSH director');

	ok($bosh->cleanup(all => 1, 'keep-orphaned-disks' => 1),
		'cleanup() with options works correctly');
};


done_testing;
