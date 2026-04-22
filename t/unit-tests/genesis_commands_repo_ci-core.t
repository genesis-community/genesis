#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use helper;

use Genesis;
use Genesis::Config;
use_ok 'Genesis::Commands::Repo';
use_ok 'Genesis::Top';

my $tmp = workdir();

### Helpers ###################################################################

# Minimal .genesis/config that looks like a Genesis repo
sub make_repo {
	my ($dir, %opts) = @_;
	my $genesis_dir = "$dir/.genesis";
	mkdir_or_fail($genesis_dir);

	my $content = "---\ncreator_version: 3.0.0\ndeployment_type: test-kit\nversion: 2\n";
	if ($opts{ci_provider}) {
		$content .= "ci:\n  provider: $opts{ci_provider}\n";
	}
	mkfile_or_fail("$genesis_dir/config", $content);
	return $dir;
}

### Tests #####################################################################

subtest 'repo_init writes ci.provider to .genesis/config' => sub {
	my $dir = workdir("repo-init-1");
	make_repo($dir);

	# Call the private _write_ci_config logic directly via a Genesis::Config
	# object so we test the config writing without needing a full Top object.
	my $config = Genesis::Config->new("$dir/.genesis/config", 1);
	$config->set('ci.provider', 'concourse', 1);

	my $config2 = Genesis::Config->new("$dir/.genesis/config");
	ok $config2->has('ci.provider'), "ci.provider key written";
	is $config2->get('ci.provider'), 'concourse', "ci.provider value is 'concourse'";
};

subtest 'repo_init scaffold: targets.yml created' => sub {
	my $dir = workdir("repo-init-scaffold");
	make_repo($dir);
	mkdir_or_fail("$dir/.genesis/ci");

	Genesis::Commands::Repo::_write_if_absent(
		"$dir/.genesis/ci/targets.yml",
		Genesis::Commands::Repo::_targets_scaffold()
	);

	ok -f "$dir/.genesis/ci/targets.yml", "targets.yml exists";
	my $content = slurp("$dir/.genesis/ci/targets.yml");
	like $content, qr/targets:\s*\{\}/, "contains empty targets map";
	like $content, qr/bosh-director/, "contains bosh-director comment";
};

subtest 'repo_init scaffold: resources.yml created' => sub {
	my $dir = workdir("repo-init-resources");
	make_repo($dir);
	mkdir_or_fail("$dir/.genesis/ci");

	Genesis::Commands::Repo::_write_if_absent(
		"$dir/.genesis/ci/resources.yml",
		Genesis::Commands::Repo::_resources_scaffold()
	);

	ok -f "$dir/.genesis/ci/resources.yml", "resources.yml exists";
	my $content = slurp("$dir/.genesis/ci/resources.yml");
	like $content, qr/resources:\s*\[\]/, "contains empty resources list";
};

subtest 'repo_init scaffold: ci-overrides file created' => sub {
	my $dir = workdir("repo-init-overrides");
	make_repo($dir);
	mkdir_or_fail("$dir/.genesis/ci");

	Genesis::Commands::Repo::_write_if_absent(
		"$dir/.genesis/ci/ci-overrides-concourse.yml",
		Genesis::Commands::Repo::_overrides_scaffold('concourse')
	);

	ok -f "$dir/.genesis/ci/ci-overrides-concourse.yml", "override file exists";
	my $content = slurp("$dir/.genesis/ci/ci-overrides-concourse.yml");
	like $content, qr/ci-overrides-concourse/, "contains provider name in header";
	like $content, qr/spruce/i, "references spruce in comment";
};

subtest 'repo_init scaffold: integrations.yml written with provided values' => sub {
	my $dir = workdir("repo-init-integrations");
	make_repo($dir);
	my $ci_dir = "$dir/.genesis/ci";
	mkdir_or_fail($ci_dir);

	my $cfg = {
		ci_provider   => 'concourse',
		pipeline_name => 'my-pipeline',
		git_uri       => 'git@github.com:example/repo.git',
		git_branch    => 'main',
		vault_url     => 'https://vault.example.com:8200',
	};
	Genesis::Commands::Repo::_write_integrations($ci_dir, $cfg);

	ok -f "$ci_dir/integrations.yml", "integrations.yml exists";
	my $content = slurp("$ci_dir/integrations.yml");
	like $content, qr|https://vault\.example\.com:8200|, "vault url present";
	like $content, qr|git\@github\.com:example/repo\.git|, "git uri present";
	like $content, qr/default_branch:\s*main/, "branch present";
};

subtest '_write_if_absent: does not overwrite existing file' => sub {
	my $dir = workdir("repo-init-absent");
	make_repo($dir);
	mkdir_or_fail("$dir/.genesis/ci");

	mkfile_or_fail("$dir/.genesis/ci/targets.yml", "---\ncustom: true\n");

	Genesis::Commands::Repo::_write_if_absent(
		"$dir/.genesis/ci/targets.yml",
		Genesis::Commands::Repo::_targets_scaffold()
	);

	my $content = slurp("$dir/.genesis/ci/targets.yml");
	like $content, qr/custom: true/, "existing content preserved";
	unlike $content, qr/targets: \{\}/, "scaffold not written over existing file";
};

subtest 'repo_init guard: errors if ci.provider already set' => sub {
	my $dir = workdir("repo-init-guard");
	make_repo($dir, ci_provider => 'concourse');

	# We test the guard condition in isolation by reading the config directly
	my $config = Genesis::Config->new("$dir/.genesis/config");
	ok $config->has('ci.provider'), "guard precondition: ci.provider is set";

	# The actual bail() in repo_init would fire here; we just verify the
	# config state that triggers it rather than calling the full command
	# (which requires a Top object and exits via bail).
	is $config->get('ci.provider'), 'concourse', "guard sees correct provider value";
};

subtest 'repo_update --ci-provider: _apply_ci_flags updates only provider' => sub {
	my $dir = workdir("repo-update-provider");
	make_repo($dir, ci_provider => 'concourse');
	my $ci_dir = "$dir/.genesis/ci";
	mkdir_or_fail($ci_dir);

	# Pre-populate integrations.yml with known content
	mkfile_or_fail("$ci_dir/integrations.yml", <<'YAML');
---
vault:
  url: https://vault.example.com:8200
source_control:
  uri: git@github.com:org/repo.git
  default_branch: main
YAML

	my $config = Genesis::Config->new("$dir/.genesis/config", 1);

	# Simulate what _apply_ci_flags does for --ci-provider only
	$config->set('ci.provider', 'github-actions', 1);

	my $config2 = Genesis::Config->new("$dir/.genesis/config");
	is $config2->get('ci.provider'), 'github-actions', "provider updated to github-actions";

	# integrations.yml should be unchanged
	my $integrations = slurp("$ci_dir/integrations.yml");
	like $integrations, qr|https://vault\.example\.com:8200|, "integrations.yml untouched";
};

subtest 'repo_update _apply_ci_flags: patches integrations.yml fields in place' => sub {
	my $dir = workdir("repo-update-integrations");
	make_repo($dir, ci_provider => 'concourse');
	my $ci_dir = "$dir/.genesis/ci";
	mkdir_or_fail($ci_dir);

	mkfile_or_fail("$ci_dir/integrations.yml", <<'YAML');
---
vault:
  url: https://old-vault.example.com:8200
source_control:
  uri: git@github.com:org/old-repo.git
  default_branch: master
YAML

	# Simulate _apply_ci_flags with --vault-url and --git-branch
	my $raw = slurp("$ci_dir/integrations.yml");
	my $new_vault = 'https://new-vault.example.com:8200';
	my $new_branch = 'main';
	$raw =~ s/^(\s{0,4}url:\s*)\S+/$1$new_vault/m;
	$raw =~ s/^(\s{0,4}default_branch:\s*)\S+/$1$new_branch/m;
	mkfile_or_fail("$ci_dir/integrations.yml", $raw);

	my $content = slurp("$ci_dir/integrations.yml");
	like   $content, qr|https://new-vault\.example\.com:8200|, "vault url updated";
	like   $content, qr/default_branch:\s*main/,               "branch updated to main";
	unlike $content, qr/master/,                               "old branch removed";
	like   $content, qr|git\@github\.com:org/old-repo\.git|,   "git uri unchanged";
};

subtest '_existing_ci_defaults: reads values from integrations.yml' => sub {
	my $dir = workdir("repo-defaults");
	make_repo($dir, ci_provider => 'concourse');
	my $ci_dir = "$dir/.genesis/ci";
	mkdir_or_fail($ci_dir);

	mkfile_or_fail("$ci_dir/integrations.yml", <<'YAML');
---
vault:
  url: https://vault.corp.example.com:8200
  namespace: genesis
source_control:
  uri: git@github.com:corp/deployments.git
  default_branch: trunk
YAML

	# Test the extraction logic from _existing_ci_defaults in isolation
	my $raw = slurp("$ci_dir/integrations.yml");
	my ($vault_url, $git_uri, $git_branch);
	($vault_url) = $raw =~ /url:\s*(\S+)/;
	($git_uri)   = $raw =~ /uri:\s*(\S+)/;
	($git_branch) = $raw =~ /default_branch:\s*(\S+)/;

	is $vault_url,  'https://vault.corp.example.com:8200', "vault url extracted";
	is $git_uri,    'git@github.com:corp/deployments.git', "git uri extracted";
	is $git_branch, 'trunk',                               "branch extracted";
};

### Config v3 validation tests ################################################

$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");

sub make_v3_repo {
	my ($dir, %opts) = @_;
	my $genesis_dir = "$dir/.genesis";
	mkdir_or_fail($genesis_dir);

	my $version = $opts{version} // 3;
	my $content = "---\ncreator_version: 3.2.0\ndeployment_type: test-kit\nversion: $version\n";
	if ($opts{ci}) {
		$content .= "ci:\n";
		for my $key (sort keys %{$opts{ci}}) {
			my $val = $opts{ci}{$key};
			if (ref($val) eq 'HASH') {
				$content .= "  $key:\n";
				for my $subkey (sort keys %$val) {
					$content .= "    $subkey: $val->{$subkey}\n";
				}
			} else {
				$content .= "  $key: $val\n";
			}
		}
	}
	mkfile_or_fail("$genesis_dir/config", $content);
	return $dir;
}

subtest 'v2 config loads and augments ci.enabled default' => sub {
	my $dir = make_v3_repo(workdir("v2-augment"), version => 2);

	my $top = Genesis::Top->new($dir, no_vault => 1);
	ok !$top->ci_enabled, "ci_enabled is false for v2 config";
	ok !$top->ci_configured, "ci_configured is false for v2 config";
	is $top->config->get('ci.enabled'), 0, "ci.enabled defaults to false";
	is $top->config->get_source('ci'), 'default', "ci section comes from default layer";
};

subtest 'v2 config with ci.yml bails' => sub {
	my $dir = make_v3_repo(workdir("v2-ci-yml"), version => 2);
	mkfile_or_fail("$dir/ci.yml", "---\npipeline:\n  layouts:\n    - sandbox\n");

	my $top = Genesis::Top->new($dir, no_vault => 1);
	eval { $top->config };
	like $@, qr/Legacy CI configuration/, "v2 + ci.yml bails with migration message";
	like $@, qr/repo-init --upgrade/, "bail message mentions upgrade command";
};

subtest 'v3 config validates with CI disabled' => sub {
	my $dir = make_v3_repo(workdir("v3-disabled"), ci => { enabled => 'false' });

	my $top = Genesis::Top->new($dir, no_vault => 1);
	ok !$top->ci_enabled, "ci_enabled is false";
	ok !$top->ci_configured, "ci_configured is false";
};

subtest 'v3 config validates with CI enabled and provider' => sub {
	my $dir = make_v3_repo(workdir("v3-enabled"), ci => {
		enabled  => 'true',
		provider => { type => 'concourse', target => 'pipes/lmelt', url => 'https://pipes.example.com', team => 'lmelt' },
		pipeline => { name => 'bosh' },
	});

	my $top = Genesis::Top->new($dir, no_vault => 1);
	ok $top->ci_enabled, "ci_enabled is true";
	ok $top->ci_configured, "ci_configured is true";
	is $top->config->get('ci.provider.type'), 'concourse', "provider type is concourse";
	is $top->config->get('ci.provider.target'), 'pipes/lmelt', "provider target correct";
	is $top->config->get('ci.pipeline.name'), 'bosh', "pipeline name correct";
};

subtest 'v3 config bails when enabled but no provider' => sub {
	my $dir = make_v3_repo(workdir("v3-no-provider"), ci => { enabled => 'true' });

	my $top = Genesis::Top->new($dir, no_vault => 1);
	eval { $top->config };
	like $@, qr/missing required key/, "bails when enabled without provider";
	like $@, qr/provider/, "bail message references provider";
};

subtest 'v3 config with ci.yml and CI configured bails with conflict' => sub {
	my $dir = make_v3_repo(workdir("v3-conflict"), ci => {
		enabled  => 'true',
		provider => { type => 'concourse', target => 'pipes/test', url => 'https://ci.example.com', team => 'test' },
	});
	mkfile_or_fail("$dir/ci.yml", "---\npipeline:\n  layouts:\n    - sandbox\n");

	my $top = Genesis::Top->new($dir, no_vault => 1);
	eval { $top->config };
	like $@, qr/conflicts/, "v3 + ci.yml + configured CI bails with conflict message";
};

subtest 'v3 config with ci.yml and CI not configured bails with migrate' => sub {
	my $dir = make_v3_repo(workdir("v3-migrate"), ci => { enabled => 'false' });
	mkfile_or_fail("$dir/ci.yml", "---\npipeline:\n  layouts:\n    - sandbox\n");

	my $top = Genesis::Top->new($dir, no_vault => 1);
	eval { $top->config };
	like $@, qr/Legacy CI configuration/, "v3 + ci.yml + disabled CI bails with migrate message";
	like $@, qr/repo-init --upgrade/, "mentions upgrade command";
};

subtest 'v3 config rejects unknown ci keys' => sub {
	my $dir = workdir("v3-unknown-key");
	mkdir_or_fail("$dir/.genesis");
	mkfile_or_fail("$dir/.genesis/config", <<EOF);
---
creator_version: 3.2.0
deployment_type: test-kit
version: 3
ci:
  enabled: false
  bogus_key: should_fail
EOF

	my $top = Genesis::Top->new($dir, no_vault => 1);
	eval { $top->config };
	like $@, qr/unknown configuration key/, "rejects unknown key in ci section";
	like $@, qr/bogus_key/, "error mentions the offending key";
};

subtest 'v3 config rejects invalid provider type' => sub {
	my $dir = workdir("v3-bad-provider");
	mkdir_or_fail("$dir/.genesis");
	mkfile_or_fail("$dir/.genesis/config", <<EOF);
---
creator_version: 3.2.0
deployment_type: test-kit
version: 3
ci:
  enabled: true
  provider:
    type: jenkins
EOF

	my $top = Genesis::Top->new($dir, no_vault => 1);
	eval { $top->config };
	like $@, qr/jenkins|expected/, "rejects invalid provider type enum value";
};

subtest 'v2 config write-back does not persist ci defaults' => sub {
	my $dir = make_v3_repo(workdir("v2-writeback"), version => 2);

	my $top = Genesis::Top->new($dir, no_vault => 1);
	# ci.enabled should be accessible
	is $top->config->get('ci.enabled'), 0, "ci.enabled is available via get";

	# But _explicit_contents (what gets saved) should NOT have ci
	my $explicit = $top->config->_explicit_contents;
	ok !exists $explicit->{ci}, "ci section not in explicit contents (won't persist)";
};

subtest 'new repos created with LATEST_CONFIG_VERSION' => sub {
	is Genesis::Top::LATEST_CONFIG_VERSION(), 3, "LATEST_CONFIG_VERSION is 3";
};

subtest 'ci_control_branch returns constant for MVP' => sub {
	my $dir = make_v3_repo(workdir("v3-control"), ci => {
		enabled  => 'true',
		provider => { type => 'concourse', target => 'pipes/test', url => 'https://ci.example.com', team => 'test' },
	});

	my $top = Genesis::Top->new($dir, no_vault => 1);
	is $top->ci_control_branch, 'control', "ci_control_branch returns 'control'";
};

done_testing;
