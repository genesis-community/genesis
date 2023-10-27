#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::Output;

use_ok "Genesis::BOSH";
use_ok "Genesis::BOSH::Director";
use_ok "Genesis::BOSH::CreateEnvProxy";
use Genesis;

sub get_bosh_director {
	my $alias = shift || 'bosh-director';
	Genesis::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	Genesis::BOSH::Director->new($alias,url => 'https://127.0.0.1', ca_cert=>"ca_cert", client=>'admin', secret=>'password', @_);
}
sub get_bosh_create_env {
	my $alias = shift;
	Genesis::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	Genesis::BOSH::CreateEnvProxy->new(@_);
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

	bosh_runs_as("create-env --state state.json -l path/to/vars-file.yml manifest.yml");
	Genesis::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	($out, $rc) = $bosh->create_env("manifest.yml", state => "state.json", vars_file => "path/to/vars-file.yml");
	ok !$rc, "create_env with state file and vars-file should work";

	local $ENV{BOSH_NON_INTERACTIVE} = 'yes';
	bosh_runs_as("-n create-env --state state.json manifest.yml");
	Genesis::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	($out,$rc) = $bosh->create_env("manifest.yml", state => "state.json");
	ok !$rc, "create_env honors BOSH_NON_INTERACTIVE";
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
	local %ENV;
	$ENV{HOME}=$home; # Genesis always needs $HOME
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


done_testing;
