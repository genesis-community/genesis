#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::Output;

use_ok "Genesis::BOSH";
use Genesis;

subtest '_bosh helper magic' => sub {
	local $ENV{GENESIS_BOSH_COMMAND};
	bosh_runs_as('foo');

	ok Genesis::BOSH->_bosh({ passfail => 1 }, 'bosh', 'foo'),
		"(bosh foo), pre-tokenized, should execute properly";
	ok Genesis::BOSH->_bosh({ passfail => 1 }, 'foo'),
		"(foo), pre-tokenized, should execute properly";
	ok Genesis::BOSH->_bosh({ passfail => 1 }, 'bosh foo'),
		"simple 'bosh foo' should execute properly";
	ok Genesis::BOSH->_bosh({ passfail => 1 }, 'bosh foo | cat $1', '/dev/null'),
		"complex 'bosh foo | ...' (with vars) should execute properly";
	ok Genesis::BOSH->_bosh({ passfail => 1 }, 'foo | cat $1', '/dev/null'),
		"complex 'foo | ...' (with vars) should execute properly";
};

subtest 'bosh ping' => sub {
	local $ENV{GENESIS_BOSH_COMMAND};
	my $director = fake_bosh_director('the-target');
	bosh_runs_as("-e the-target env --json");
	ok Genesis::BOSH->ping('the-target'), "bosh env on alias should ping ok";

	bosh_runs_as("-e https://127.0.0.1:25555 env --json");
	ok Genesis::BOSH->ping('https://127.0.0.1:25555'), "bosh env on url should ping ok";
	$director->stop();
};

subtest 'bosh create-env' => sub {
	local $ENV{GENESIS_BOSH_COMMAND};
	bosh_runs_as("create-env --state state.json manifest.yml");
	ok Genesis::BOSH->create_env("manifest.yml", state => "state.json"),
		"create_env with state file should work";

	quietly {
		throws_ok { Genesis::BOSH->create_env() }
			qr/missing deployment manifest/i;
  };

	quietly {
		throws_ok { Genesis::BOSH->create_env("manifest.yml") }
			qr/missing 'state' option/i;
	};

	bosh_runs_as("create-env --state state.json -l path/to/vars-file.yml manifest.yml");
	ok Genesis::BOSH->create_env("manifest.yml", state => "state.json", vars_file => "path/to/vars-file.yml"),
		"create_env with state file and vars-file should work";

	local $ENV{BOSH_NON_INTERACTIVE} = 'yes';
	bosh_runs_as("-n create-env --state state.json manifest.yml");
	ok Genesis::BOSH->create_env("manifest.yml", state => "state.json"),
		"create_env honors BOSH_NON_INTERACTIVE";
};

subtest 'bosh cloud-config' => sub {
	my $out = workdir;

	local $ENV{GENESIS_BOSH_COMMAND};
	bosh_outputs_json('-e "some-env" config --type cloud --name default --json',"() # cloud-config");
	ok Genesis::BOSH->download_cloud_config('some-env', "$out/cloud.yml"),
		"download_cloud_config should work";

	bosh_outputs_json('-e "some-env" config --type cloud --name default --json',"");
	quietly {
		throws_ok { Genesis::BOSH->download_cloud_config('some-env', "$out/cloud.yml") }
			qr/no cloud-config defined/i,
			"without cloud-config output, download_cloud_config should fail";
	};
};

subtest 'bosh deploy' => sub {
	local $ENV{GENESIS_BOSH_COMMAND};
	bosh_runs_as("-e my-env -d my-dep deploy --some --flags manifest.yml");
	lives_ok { Genesis::BOSH->deploy("my-env", manifest   => 'manifest.yml',
	                                           deployment => 'my-dep',
	                                           flags      => ['--some', '--flags']); }
		"deploy should pass through options and flags properly";

	bosh_runs_as("-e my-env -d my-dep deploy --some --flags -l path/to/vars-file.yml manifest.yml");
	lives_ok { Genesis::BOSH->deploy("my-env", manifest   => 'manifest.yml',
	                                           deployment => 'my-dep',
	                                           vars_file  => "path/to/vars-file.yml",
	                                           flags      => ['--some', '--flags']); }
		"deploy should pass through vars-file, options and flags properly";

	quietly { throws_ok { Genesis::BOSH->deploy } qr/missing bosh environment name/i; };
	quietly {
		throws_ok { Genesis::BOSH->deploy("an-env") }
			qr/missing 'manifest' option/i;
	};
	quietly {
		throws_ok { Genesis::BOSH->deploy("an-env", manifest => 'manifest.yml') }
			qr/missing 'deployment' option/i;
	};
};

subtest 'bosh alias' => sub {
	local $ENV{GENESIS_BOSH_COMMAND};
	bosh_runs_as("alias-env the-alias");
	lives_ok { Genesis::BOSH->alias("the-alias") } "alias works";
};

subtest 'bosh run_errand' => sub {
	local $ENV{GENESIS_BOSH_COMMAND};
	bosh_runs_as("-n -e an-env -d some-deployment run-errand smoke-tests");
	lives_ok { Genesis::BOSH->run_errand("an-env", deployment => "some-deployment",
	                                               errand     => "smoke-tests") }
		"run_errand works with env, deploytment, and errand name set";

	quietly { throws_ok { Genesis::BOSH->run_errand } qr/missing bosh environment name/i; };
	quietly {
		throws_ok { Genesis::BOSH->run_errand("an-env") }
			qr/missing 'deployment' option/i;
	};
	quietly {
		throws_ok { Genesis::BOSH->run_errand("an-env", deployment => 'my-dep') }
			qr/missing 'errand' option/i;
	};
};

subtest 'environment variable management' => sub {
	local %ENV;

	fake_bosh(<<'EOF');
echo HTTPS_PROXY=${HTTPS_PROXY-"<unset>"}...
echo https_proxy=${https_proxy-"<unset>"}...
echo BOSH_ENVIRONMENT=${BOSH_ENVIRONMENT-"<unset>"}...
echo BOSH_CA_CERT=${BOSH_CA_CERT-"<unset>"}...
echo BOSH_CLIENT=${BOSH_CLIENT-"<unset>"}...
echo BOSH_CLIENT_SECRET=${BOSH_CLIENT_SECRET-"<unset>"}...
EOF

	$ENV{$_} = "a {$_} got missed" for (qw(
		HTTPS_PROXY        https_proxy
		BOSH_ENVIRONMENT   BOSH_CA_CERT
		BOSH_CLIENT        BOSH_CLIENT_SECRET));

	stdout_is(sub { Genesis::BOSH::_bosh({ interactive => 1 }, 'bosh', 'foo'); }, <<EOF,
HTTPS_PROXY=...
https_proxy=...
BOSH_ENVIRONMENT=<unset>...
BOSH_CA_CERT=<unset>...
BOSH_CLIENT=<unset>...
BOSH_CLIENT_SECRET=<unset>...
EOF
		"bosh() helper should clear out the environment implicitly");

	stdout_is(sub { Genesis::BOSH::_bosh({
			interactive => 1,
			env => {
				BOSH_CA_CERT       => 'save my ca cert',
				BOSH_CLIENT        => 'save my client id',
				BOSH_CLIENT_SECRET => 'save my client secret',
			},
		}, 'bosh foo'); }, <<EOF,
HTTPS_PROXY=...
https_proxy=...
BOSH_ENVIRONMENT=<unset>...
BOSH_CA_CERT=save my ca cert...
BOSH_CLIENT=save my client id...
BOSH_CLIENT_SECRET=save my client secret...
EOF
		"bosh() helper should clear out the environment implicitly");

	$ENV{GENESIS_HONOR_ENV}=1;
	stdout_is(sub { Genesis::BOSH::_bosh({
			interactive => 1,
			env => {
				BOSH_CA_CERT       => 'save my ca cert',
				BOSH_CLIENT        => 'save my client id',
				BOSH_CLIENT_SECRET => 'save my client secret',
			},
		}, 'bosh foo'); }, <<EOF,
HTTPS_PROXY=a {HTTPS_PROXY} got missed...
https_proxy=a {https_proxy} got missed...
BOSH_ENVIRONMENT=a {BOSH_ENVIRONMENT} got missed...
BOSH_CA_CERT=save my ca cert...
BOSH_CLIENT=save my client id...
BOSH_CLIENT_SECRET=save my client secret...
EOF
		"bosh() helper should not clear out the environment if told to honour env");
};


done_testing;
