#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::Output;

use_ok "Genesis::BOSH";
use Genesis;

sub bosh_runs_as {
	my ($expect, $output) = @_;
	$output = $output ? "echo \"$output\"" : "";
	fake_bosh(<<EOF);
$output
[[ "\$@" == "$expect" ]] && exit 0;
echo >&2 "got  '\$@\'"
echo >&2 "want '$expect'"
exit 2
EOF
}

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
	bosh_runs_as("-e the-target env");
	ok Genesis::BOSH->ping('the-target'), "bosh env on alias should ping ok";

	bosh_runs_as("-e https://127.0.0.1:25555 env");
	ok Genesis::BOSH->ping('https://127.0.0.1:25555'), "bosh env on url should ping ok";
	$director->stop();
};

subtest 'bosh create-env' => sub {
	local $ENV{GENESIS_BOSH_COMMAND};
	bosh_runs_as("create-env --state state.json manifest.yml");
	ok Genesis::BOSH->create_env("manifest.yml", state => "state.json"),
		"create_env with state file should work";

	throws_ok { Genesis::BOSH->create_env() }
		qr/missing deployment manifest/i;

	throws_ok { Genesis::BOSH->create_env("manifest.yml") }
		qr/missing 'state' option/i;

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
	bosh_runs_as('-e "some-env" cloud-config', "{} # cloud-config");
	ok Genesis::BOSH->download_cloud_config('some-env', "$out/cloud.yml"),
		"download_cloud_config should work";

	bosh_runs_as('-e "some-env" cloud-config');
	throws_ok { Genesis::BOSH->download_cloud_config('some-env', "$out/cloud.yml") }
		qr/no cloud-config defined/i,
		"without cloud-config output, download_cloud_config should fail";
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

	throws_ok { Genesis::BOSH->deploy } qr/missing bosh environment name/i;
	throws_ok { Genesis::BOSH->deploy("an-env") }
		qr/missing 'manifest' option/i;
	throws_ok { Genesis::BOSH->deploy("an-env", manifest => 'manifest.yml') }
		qr/missing 'deployment' option/i;
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

	throws_ok { Genesis::BOSH->run_errand } qr/missing bosh environment name/i;
	throws_ok { Genesis::BOSH->run_errand("an-env") }
		qr/missing 'deployment' option/i;
	throws_ok { Genesis::BOSH->run_errand("an-env", deployment => 'my-dep') }
		qr/missing 'errand' option/i;
};

subtest 'environment variable management' => sub {
	local %ENV;

	fake_bosh(<<'EOF');
echo HTTPS_PROXY=$HTTPS_PROXY...
echo https_proxy=$https_proxy...
echo BOSH_ENVIRONMENT=$BOSH_ENVIRONMENT...
echo BOSH_CA_CERT=$BOSH_CA_CERT...
echo BOSH_CLIENT=$BOSH_CLIENT...
echo BOSH_CLIENT_SECRET=$BOSH_CLIENT_SECRET...
EOF

	$ENV{$_} = "a {$_} got missed" for (qw(
		HTTPS_PROXY        https_proxy
		BOSH_ENVIRONMENT   BOSH_CA_CERT
		BOSH_CLIENT        BOSH_CLIENT_SECRET));

	stdout_is(sub { Genesis::BOSH::_bosh({ interactive => 1 }, 'bosh', 'foo'); }, <<EOF,
HTTPS_PROXY=...
https_proxy=...
BOSH_ENVIRONMENT=...
BOSH_CA_CERT=...
BOSH_CLIENT=...
BOSH_CLIENT_SECRET=...
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
BOSH_ENVIRONMENT=...
BOSH_CA_CERT=save my ca cert...
BOSH_CLIENT=save my client id...
BOSH_CLIENT_SECRET=save my client secret...
EOF
		"bosh() helper should clear out the environment implicitly");
};


done_testing;
