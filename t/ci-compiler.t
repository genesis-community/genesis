#!perl
use strict;
use warnings;

use Test::More;
use File::Temp qw/tempdir/;
use File::Path qw/mkpath/;
use JSON::PP;
use lib 'lib';

# Set up minimal Genesis testing environment
$ENV{GENESIS_TESTING} = "yes";
$ENV{GENESIS_LIB}     ||= 'lib';

# DEBUG_CI=1 writes all generated pipeline output to ./debug-ci/
my $DEBUG_DIR;
if ($ENV{DEBUG_CI}) {
	$DEBUG_DIR = './debug-ci';
	mkpath($DEBUG_DIR) unless -d $DEBUG_DIR;
	diag "DEBUG_CI enabled: writing output to $DEBUG_DIR/";
}

sub _debug_write {
	my ($filename, $content) = @_;
	return unless $DEBUG_DIR;
	my $path = "$DEBUG_DIR/$filename";
	open my $fh, '>', $path or do { diag "Cannot write $path: $!"; return };
	print $fh $content;
	close $fh;
	diag "  wrote $path (" . length($content) . " bytes)";
}

use_ok 'Genesis::CI::Compiler::AST';
use_ok 'Genesis::CI::Compiler::ASTBuilder';
use_ok 'Genesis::CI::Compiler::Validator';
use_ok 'Genesis::CI::Compiler::PipelineProvider';
use_ok 'Genesis::CI::Compiler';

# Load providers via file path (not package name)
eval { require 'Genesis/CI/Compiler/Providers/Concourse.pm' };
ok !$@, "loaded Concourse provider" or diag $@;

eval { require 'Genesis/CI/Compiler/Providers/GithubActions.pm' };
# GithubActions may fail due to YAML::PP not installed; skip those tests if so
my $has_gha = !$@;

### ============================================================ ###
### AST Tests
### ============================================================ ###

subtest 'AST - construction and accessors' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		metadata     => { name => 'test-pipe', version => '2.0', source => 'modern' },
		branches     => { live => 'main', target_prefix => 'target/' },
		integrations => {
			vault => { url => 'https://vault.example.com' },
			source_control => {
				provider   => 'github',
				repository => 'org/repo',
			},
		},
		targets => {
			'us-west-sandbox' => {
				type => 'bosh-director',
				connection => { url => 'https://bosh.sandbox.example.com:25555' },
			},
			'us-west-preprod' => {
				type => 'bosh-director',
				connection => { url => 'https://bosh.preprod.example.com:25555' },
			},
		},
		workflows => {
			default => {
				name => 'default',
				type => 'deployment',
				graph => {
					nodes => {
						'us-west-sandbox' => { stage_name => 'us-west-sandbox', alias => 'sandbox', auto => 1 },
						'us-west-preprod' => { stage_name => 'us-west-preprod', alias => 'preprod', auto => 0 },
					},
					edges => [
						{ from => 'us-west-sandbox', to => 'us-west-preprod' },
					],
				},
			},
		},
		configuration => { public => 1, tagged => 0 },
	);

	isa_ok $ast, 'Genesis::CI::Compiler::AST', "AST is blessed correctly";

	# Accessors
	is $ast->metadata->{name}, 'test-pipe', "metadata name accessor works";
	is $ast->branches->{live}, 'main', "branches accessor works";
	is $ast->integrations->{vault}{url}, 'https://vault.example.com', "integrations accessor works";
	is $ast->configuration->{public}, 1, "configuration accessor works";

	# Query methods
	my @targets = $ast->target_names;
	is_deeply \@targets, ['us-west-preprod', 'us-west-sandbox'],
		"target_names returns sorted names";

	my @workflows = $ast->workflow_names;
	is_deeply \@workflows, ['default'],
		"workflow_names returns sorted names";
};

subtest 'AST - targets_matching' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		targets => {
			'us-west-sandbox'  => { type => 'bosh-director' },
			'us-west-preprod'  => { type => 'bosh-director' },
			'us-east-sandbox'  => { type => 'bosh-director' },
			'us-east-prod'     => { type => 'bosh-director' },
		},
	);

	my @matched = $ast->targets_matching('us-west-*');
	is scalar(@matched), 2, "targets_matching 'us-west-*' finds 2 targets";

	@matched = $ast->targets_matching('*-sandbox');
	is scalar(@matched), 2, "targets_matching '*-sandbox' finds 2 targets";

	@matched = $ast->targets_matching('us-east-prod');
	is scalar(@matched), 1, "targets_matching exact name finds 1 target";

	@matched = $ast->targets_matching('no-match*');
	is scalar(@matched), 0, "targets_matching with no match finds 0 targets";
};

subtest 'AST - topological sort' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		workflows => {
			default => {
				name => 'default',
				graph => {
					nodes => {
						sandbox => { stage_name => 'sandbox' },
						preprod => { stage_name => 'preprod' },
						prod    => { stage_name => 'prod' },
					},
					edges => [
						{ from => 'sandbox', to => 'preprod' },
						{ from => 'preprod', to => 'prod' },
					],
				},
			},
		},
	);

	my @order = $ast->workflow_stage_order('default');
	is_deeply \@order, ['sandbox', 'preprod', 'prod'],
		"topological sort returns correct order for linear chain";
};

subtest 'AST - cycle detection' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		workflows => {
			cycle_wf => {
				name => 'cycle_wf',
				graph => {
					nodes => {
						a => { stage_name => 'a' },
						b => { stage_name => 'b' },
						c => { stage_name => 'c' },
					},
					edges => [
						{ from => 'a', to => 'b' },
						{ from => 'b', to => 'c' },
						{ from => 'c', to => 'a' },
					],
				},
			},
		},
	);

	eval { $ast->workflow_stage_order('cycle_wf') };
	like $@, qr/Cycle detected/, "topological sort detects cycles";
};

subtest 'AST - env_vars_for_target' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		integrations => {
			vault => {
				url  => 'https://vault.example.com',
				auth => {
					role_id   => 'my-role',
					secret_id => { secret_ref => 'vault/secret-id' },
				},
			},
			source_control => {
				auth => {
					type        => 'ssh-key',
					private_key => { secret_ref => 'git/private-key' },
				},
				commit_author => {
					name  => 'Test Bot',
					email => 'test@example.com',
				},
			},
		},
		targets => {
			'my-sandbox' => {
				type       => 'bosh-director',
				connection => {
					url     => 'https://bosh.example.com:25555',
					ca_cert => 'ca-cert-data',
					auth    => {
						client_id     => 'admin',
						client_secret => 'supersecret',
					},
				},
			},
		},
	);

	my %env = $ast->env_vars_for_target('my-sandbox');
	is $env{CURRENT_ENV}, 'my-sandbox', "CURRENT_ENV set correctly";
	is $env{VAULT_ADDR}, 'https://vault.example.com', "VAULT_ADDR set correctly";
	is $env{VAULT_ROLE_ID}, 'my-role', "VAULT_ROLE_ID set correctly";
	is $env{VAULT_SECRET_ID}, '((vault/secret-id))', "VAULT_SECRET_ID unwraps secret_ref";
	is $env{BOSH_ENVIRONMENT}, 'https://bosh.example.com:25555', "BOSH_ENVIRONMENT set correctly";
	is $env{BOSH_CLIENT}, 'admin', "BOSH_CLIENT set correctly";
	is $env{GIT_PRIVATE_KEY}, '((git/private-key))', "GIT_PRIVATE_KEY unwraps secret_ref";
	is $env{GIT_AUTHOR_NAME}, 'Test Bot', "GIT_AUTHOR_NAME set correctly";
	is $env{GIT_AUTHOR_EMAIL}, 'test@example.com', "GIT_AUTHOR_EMAIL set correctly";
};

### ============================================================ ###
### ASTBuilder Tests
### ============================================================ ###

subtest 'ASTBuilder - legacy format' => sub {
	my $builder = Genesis::CI::Compiler::ASTBuilder->new();

	my $parsed = {
		_source_format => 'legacy',
		_source_path   => 'ci.yml',
		_legacy_raw    => {
			pipeline => {
				name   => 'my-legacy-pipeline',
				public => 1,
				tagged => 0,
				unredacted => 0,
				ocfp   => 0,
				debug  => 0,
				git    => { branch => 'master', owner => 'org', repo => 'deployments' },
				vault  => { url => 'https://vault.example.com', role => 'role', secret => 'secret' },
				boshes => {
					sandbox => {
						url => 'https://bosh.example.com',
						username => 'admin',
						password => 'pass',
						ca_cert  => 'cert',
					},
				},
				task => {
					image   => 'genesiscommunity/concourse',
					version => 'latest',
				},
				notifications => 'inline',
			},
		},
		integrations => {
			vault => { url => 'https://vault.example.com' },
			source_control => { provider => 'github', repository => 'org/deployments' },
		},
		targets => {
			sandbox => { type => 'bosh-director' },
		},
		pipeline => {
			workflows => {
				default => {
					environments  => ['sandbox'],
					auto_patterns => ['*sandbox'],
					will_trigger  => {},
				},
			},
		},
	};

	my $ast = $builder->build($parsed, {});
	isa_ok $ast, 'Genesis::CI::Compiler::AST', "build returns an AST";
	is $ast->metadata->{name}, 'my-legacy-pipeline', "legacy pipeline name preserved";
	is $ast->metadata->{source}, 'legacy', "source marked as legacy";
	is $ast->metadata->{source_file}, 'ci.yml', "source_file preserved";
	is $ast->branches->{live}, 'master', "branch preserved from legacy git.branch";
	ok $ast->provider_config->{concourse}{_legacy_pipeline_raw}, "legacy raw data preserved in provider_config";
};

subtest 'ASTBuilder - modern format' => sub {
	my $builder = Genesis::CI::Compiler::ASTBuilder->new();

	my $parsed = {
		_source_format => 'multi-file',
		pipeline => {
			metadata => {
				name    => 'modern-pipeline',
				version => '2.0',
			},
			branches => {
				live => 'main',
				target_prefix => 'deploy/',
			},
			workflows => {
				deploy => {
					type => 'deployment',
					stages => [
						{ name => 'sandbox', script => 'deploy' },
						{ name => 'preprod', script => 'deploy' },
						{ name => 'prod',    script => 'deploy' },
					],
				},
			},
			configuration => { public => 0 },
		},
		integrations => {
			vault => { url => 'https://vault.example.com' },
			source_control => { provider => 'github' },
		},
		targets => {
			sandbox => { type => 'bosh-director' },
			preprod => { type => 'bosh-director' },
			prod    => { type => 'bosh-director' },
		},
	};

	my $scripts = {
		deploy => { id => 'deploy', path => 'scripts/deploy.sh' },
	};

	my $ast = $builder->build($parsed, $scripts);
	isa_ok $ast, 'Genesis::CI::Compiler::AST', "build returns an AST for modern format";
	is $ast->metadata->{name}, 'modern-pipeline', "modern metadata preserved";
	is $ast->branches->{live}, 'main', "branches preserved from modern format";

	# Workflows should have been processed into graph form
	my $wf = $ast->workflows->{deploy};
	ok $wf, "deploy workflow exists";
	is $wf->{type}, 'deployment', "workflow type preserved";
	ok $wf->{graph}, "graph was built from stages";
	is scalar(keys %{$wf->{graph}{nodes}}), 3, "graph has 3 nodes from 3 stages";
	is scalar(@{$wf->{graph}{edges}}), 2, "graph has 2 edges (linear chain of 3 stages)";

	# Verify edge correctness
	my @edges = @{$wf->{graph}{edges}};
	is $edges[0]{from}, 'sandbox', "first edge from sandbox";
	is $edges[0]{to}, 'preprod', "first edge to preprod";
	is $edges[1]{from}, 'preprod', "second edge from preprod";
	is $edges[1]{to}, 'prod', "second edge to prod";
};

### ============================================================ ###
### Validator Tests
### ============================================================ ###

subtest 'Validator - valid legacy config' => sub {
	my $v = Genesis::CI::Compiler::Validator->new();

	$v->validate({
		_source_format => 'legacy',
		_legacy_raw => {
			pipeline => {
				name   => 'my-pipe',
				vault  => { url => 'https://vault.example.com' },
				git    => {
					private_key => 'key-data',
					owner => 'org',
					repo  => 'deployments',
				},
				boshes => {
					sandbox => {
						url => 'https://bosh.example.com',
						username => 'admin',
						password => 'pass',
						ca_cert  => 'cert',
					},
				},
				slack => {
					webhook => 'https://hooks.slack.com/xxx',
					channel => '#ci',
				},
				layouts => {
					default => 'auto *sandbox; sandbox',
				},
			},
		},
	});

	ok !$v->has_errors, "valid legacy config passes validation"
		or diag join("\n", @{$v->errors});
};

subtest 'Validator - missing required keys' => sub {
	my $v = Genesis::CI::Compiler::Validator->new();

	$v->validate({
		_source_format => 'legacy',
		_legacy_raw => {
			pipeline => {
				# missing name, vault, git, boshes
				slack => { webhook => 'x', channel => '#x' },
			},
		},
	});

	ok $v->has_errors, "missing required keys causes errors";
	my @errors = @{$v->errors};
	ok scalar(grep { /pipeline\.name.*required/i } @errors), "missing name reported";
	ok scalar(grep { /pipeline\.vault.*required/i } @errors), "missing vault reported";
	ok scalar(grep { /pipeline\.git.*required/i } @errors), "missing git reported";
	ok scalar(grep { /pipeline\.boshes.*required/i } @errors), "missing boshes reported";
};

subtest 'Validator - unrecognized keys' => sub {
	my $v = Genesis::CI::Compiler::Validator->new();

	$v->validate({
		_source_format => 'legacy',
		_legacy_raw => {
			pipeline => {
				name   => 'my-pipe',
				vault  => { url => 'https://vault.example.com' },
				git    => { private_key => 'key', owner => 'org', repo => 'dep' },
				boshes => {
					sandbox => {
						url => 'u', username => 'u', password => 'p', ca_cert => 'c',
					},
				},
				slack   => { webhook => 'x', channel => '#x' },
				layouts => { default => 'sandbox' },
				bogus_key => 'should be flagged',
			},
		},
	});

	ok $v->has_errors, "unrecognized key causes errors";
	ok scalar(grep { /Unrecognized.*bogus_key/ } @{$v->errors}), "bogus_key flagged";
};

subtest 'Validator - DAG cycle detection' => sub {
	my $v = Genesis::CI::Compiler::Validator->new();

	$v->validate({
		_source_format => 'multi-file',
		pipeline => {
			metadata => { name => 'test' },
			branches => { live => 'main' },
			workflows => {
				cycle => {
					graph => {
						nodes => { a => {}, b => {}, c => {} },
						edges => [
							{ from => 'a', to => 'b' },
							{ from => 'b', to => 'c' },
							{ from => 'c', to => 'a' },
						],
					},
				},
			},
		},
		integrations => {
			vault => { url => 'https://vault.example.com' },
			source_control => { provider => 'github' },
		},
		targets => {
			a => { type => 'bosh-director', connection => { url => 'https://bosh' } },
		},
	});

	ok $v->has_errors, "cycle in DAG causes validation error";
	ok scalar(grep { /Cycle detected/ } @{$v->errors}), "cycle error message present";
};

subtest 'Validator - valid multi-file config' => sub {
	my $v = Genesis::CI::Compiler::Validator->new();

	$v->validate({
		_source_format => 'multi-file',
		pipeline => {
			metadata  => { name => 'test-pipeline' },
			branches  => { live => 'main' },
			workflows => {
				deploy => {
					type   => 'deployment',
					stages => [
						{ name => 'sandbox' },
						{ name => 'prod' },
					],
				},
			},
		},
		integrations => {
			vault          => { url => 'https://vault.example.com' },
			source_control => { provider => 'github' },
		},
		targets => {
			sandbox => { type => 'bosh-director', connection => { url => 'https://bosh' } },
			prod    => { type => 'bosh-director', connection => { url => 'https://bosh2' } },
		},
	});

	ok !$v->has_errors, "valid multi-file config passes validation"
		or diag join("\n", @{$v->errors});
};

### ============================================================ ###
### PipelineProvider Base Class Tests
### ============================================================ ###

subtest 'PipelineProvider - cannot instantiate base class' => sub {
	eval { Genesis::CI::Compiler::PipelineProvider->new() };
	like $@, qr/Cannot instantiate.*directly/,
		"PipelineProvider->new() refuses direct instantiation";
};

subtest 'PipelineProvider - topological sort' => sub {
	# Use the Concourse provider (subclass) to access shared helper
	my $ast = Genesis::CI::Compiler::AST->new();
	my $provider = Genesis::CI::Concourse->new(ast => $ast);

	my $graph = {
		nodes => {
			a => {}, b => {}, c => {}, d => {},
		},
		edges => [
			{ from => 'a', to => 'b' },
			{ from => 'a', to => 'c' },
			{ from => 'b', to => 'd' },
			{ from => 'c', to => 'd' },
		],
	};

	my @sorted = $provider->topological_sort($graph);
	# a must come before b and c, b and c must come before d
	my %idx = map { $sorted[$_] => $_ } 0..$#sorted;
	ok $idx{a} < $idx{b}, "a comes before b";
	ok $idx{a} < $idx{c}, "a comes before c";
	ok $idx{b} < $idx{d}, "b comes before d";
	ok $idx{c} < $idx{d}, "c comes before d";
};

subtest 'PipelineProvider - matches_pattern' => sub {
	my $ast = Genesis::CI::Compiler::AST->new();
	my $provider = Genesis::CI::Concourse->new(ast => $ast);

	ok $provider->matches_pattern('us-west-sandbox', 'us-west-*'), "glob * matches";
	ok $provider->matches_pattern('us-west-sandbox', '*-sandbox'), "leading * matches";
	ok $provider->matches_pattern('us-west-sandbox', 'us-west-sandbox'), "exact match works";
	ok !$provider->matches_pattern('us-west-sandbox', 'us-east-*'), "non-matching glob fails";
	ok $provider->matches_pattern('abc', 'a?c'), "? pattern matches single char";
	ok !$provider->matches_pattern('abbc', 'a?c'), "? doesn't match two chars";
};

subtest 'PipelineProvider - git_uri' => sub {
	my $ast = Genesis::CI::Compiler::AST->new();
	my $provider = Genesis::CI::Concourse->new(ast => $ast);

	is $provider->git_uri({ provider => 'github', repository => 'org/repo' }),
		'git@github.com:org/repo.git', "github provider builds SSH URI";

	is $provider->git_uri({ provider => 'gitlab', repository => 'org/repo' }),
		'git@gitlab.com:org/repo.git', "gitlab provider builds SSH URI";

	is $provider->git_uri({ uri => 'https://custom.git/repo.git' }),
		'https://custom.git/repo.git', "custom URI is returned as-is";
};

subtest 'PipelineProvider - dump_yaml' => sub {
	my $ast = Genesis::CI::Compiler::AST->new();
	my $provider = Genesis::CI::Concourse->new(ast => $ast);

	my $yaml = $provider->dump_yaml({
		name => 'test',
		items => ['a', 'b'],
		nested => { key => 'value' },
	});

	like $yaml, qr/name: test/, "dump_yaml serializes scalars";
	like $yaml, qr/items:/, "dump_yaml serializes arrays";
	like $yaml, qr/- a/, "dump_yaml serializes array items";
	like $yaml, qr/nested:/, "dump_yaml serializes nested hashes";
	like $yaml, qr/key: value/, "dump_yaml serializes nested values";
};

### ============================================================ ###
### Concourse Provider Tests - Native Generation
### ============================================================ ###

subtest 'Concourse - native generation from modern AST' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		metadata => {
			name            => 'test-pipeline',
			source          => 'modern',
			deployment_type => 'cf',
		},
		branches => { live => 'main' },
		integrations => {
			vault => {
				url  => 'https://vault.example.com',
				auth => {
					role_id   => { secret_ref => 'vault/role-id' },
					secret_id => { secret_ref => 'vault/secret-id' },
				},
			},
			source_control => {
				provider   => 'github',
				repository => 'myorg/cf-deployments',
				auth       => {
					type        => 'ssh-key',
					private_key => { secret_ref => 'git/private-key' },
				},
			},
			notifications => [
				{
					type    => 'slack',
					webhook => { secret_ref => 'slack/webhook' },
					channel => '#ci',
				},
			],
		},
		targets => {
			'us-west-sandbox' => {
				type => 'bosh-director',
				connection => {
					url     => 'https://bosh.sandbox:25555',
					ca_cert => { secret_ref => 'bosh/sandbox/ca' },
					auth    => {
						client_id     => 'admin',
						client_secret => { secret_ref => 'bosh/sandbox/secret' },
					},
				},
			},
			'us-west-preprod' => {
				type => 'bosh-director',
				connection => {
					url     => 'https://bosh.preprod:25555',
					ca_cert => { secret_ref => 'bosh/preprod/ca' },
					auth    => {
						client_id     => 'admin',
						client_secret => { secret_ref => 'bosh/preprod/secret' },
					},
				},
			},
		},
		workflows => {
			default => {
				name => 'default',
				type => 'deployment',
				graph => {
					nodes => {
						'us-west-sandbox' => {
							stage_name  => 'us-west-sandbox',
							alias       => 'sandbox',
							genesis_env => 'us-west-sandbox',
							auto        => 1,
							type        => 'deployment',
						},
						'us-west-preprod' => {
							stage_name  => 'us-west-preprod',
							alias       => 'preprod',
							genesis_env => 'us-west-preprod',
							auto        => 0,
							type        => 'deployment',
						},
					},
					edges => [
						{ from => 'us-west-sandbox', to => 'us-west-preprod' },
					],
				},
			},
		},
		configuration => {
			public     => 1,
			tagged     => 0,
			unredacted => 0,
			debug      => 0,
			task => {
				image   => 'genesiscommunity/concourse',
				version => 'latest',
			},
			notifications => { style => 'inline' },
		},
	);

	my $provider = Genesis::CI::Concourse->new(ast => $ast);
	my $output = $provider->generate_from_ast($ast);

	_debug_write('concourse-pipeline.yml', $output // '');
	_debug_write('concourse-ast.json', JSON::PP->new->pretty->canonical->encode({%$ast}));

	ok defined($output), "generate_from_ast returns output";
	# Output should be a YAML string (native generation returns string directly)
	ok length($output) > 100, "output is a non-trivial YAML string";

	# Verify key structural elements are present
	like $output, qr/groups:/, "output contains groups";
	like $output, qr/resources:/, "output contains resources";
	like $output, qr/resource_types:/, "output contains resource_types";
	like $output, qr/jobs:/, "output contains jobs";

	# Verify pipeline name appears
	like $output, qr/test-pipeline/, "pipeline name appears in output";

	# Verify git resource
	like $output, qr/name: git/, "git resource present";
	like $output, qr{git\@github\.com:myorg/cf-deployments\.git}, "github URI constructed";

	# Verify slack resource
	like $output, qr/slack-notification/, "slack notification resource type present";

	# Verify environment-specific resources
	like $output, qr/sandbox-changes/, "sandbox-changes resource present";
	like $output, qr/preprod-changes/, "preprod-changes resource present";
	like $output, qr/preprod-cache/, "preprod-cache resource present (triggered env)";

	# Verify BOSH config resources
	like $output, qr/sandbox-cloud-config/, "sandbox-cloud-config resource present";
	like $output, qr/sandbox-runtime-config/, "sandbox-runtime-config resource present";

	# Verify jobs
	like $output, qr/sandbox-cf/, "sandbox deploy job present";
	like $output, qr/preprod-cf/, "preprod deploy job present";
	like $output, qr/notify-preprod-cf-changes/, "preprod notify job present (non-auto env)";

	# Verify task configuration references
	like $output, qr/ci-pipeline-deploy/, "deploy task command present";
	like $output, qr/ci-generate-cache/, "cache generation task present";

	# Verify vault references
	like $output, qr/\(\(vault\/role-id\)\)/, "vault role_id secret ref in output";
	like $output, qr/\(\(vault\/secret-id\)\)/, "vault secret_id secret ref in output";

	# Verify git auth
	like $output, qr/\(\(git\/private-key\)\)/, "git private key secret ref in output";
};

### ============================================================ ###
### Concourse Provider - Internal Helpers
### ============================================================ ###

subtest 'Concourse - _env_file_patterns' => sub {
	my $ast = Genesis::CI::Compiler::AST->new();
	my $provider = Genesis::CI::Concourse->new(ast => $ast);

	my @patterns = $provider->_env_file_patterns('us-west-1-sandbox');
	is_deeply \@patterns, [
		'us.yml',
		'us-west.yml',
		'us-west-1.yml',
		'us-west-1-sandbox.yml',
	], "_env_file_patterns computes correct hierarchical files";

	@patterns = $provider->_env_file_patterns('sandbox');
	is_deeply \@patterns, ['sandbox.yml'],
		"single-segment env has one pattern";
};

subtest 'Concourse - _unique_env_files' => sub {
	my $ast = Genesis::CI::Compiler::AST->new();
	my $provider = Genesis::CI::Concourse->new(ast => $ast);

	my @unique = $provider->_unique_env_files('us-west-1-preprod', 'us-west-1-sandbox');
	is_deeply \@unique, ['us-west-1-preprod.yml'],
		"unique files for preprod (triggered by sandbox) is just the preprod-specific file";

	@unique = $provider->_unique_env_files('us-east-1-sandbox', 'us-west-1-sandbox');
	is_deeply \@unique, [
		'us-east.yml',
		'us-east-1.yml',
		'us-east-1-sandbox.yml',
	], "unique files when common prefix is just 'us'";
};

subtest 'Concourse - _shared_env_files' => sub {
	my $ast = Genesis::CI::Compiler::AST->new();
	my $provider = Genesis::CI::Concourse->new(ast => $ast);

	my @shared = $provider->_shared_env_files('us-west-1-preprod', 'us-west-1-sandbox');
	is_deeply \@shared, [
		'us.yml',
		'us-west.yml',
		'us-west-1.yml',
	], "shared files between sandbox and preprod in same region";

	@shared = $provider->_shared_env_files('us-east-1-sandbox', 'us-west-1-sandbox');
	is_deeply \@shared, ['us.yml'],
		"shared files between different regions is just the top-level";
};

subtest 'Concourse - _is_create_env' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		targets => {
			'proto-bosh' => { type => 'bosh-create-env' },
			'regular'    => { type => 'bosh-director' },
			'tagged-ce'  => { tags => ['create-env'] },
		},
	);

	my $provider = Genesis::CI::Concourse->new(ast => $ast);
	ok $provider->_is_create_env($ast, 'proto-bosh'), "type=bosh-create-env detected";
	ok !$provider->_is_create_env($ast, 'regular'), "type=bosh-director is not create-env";
	ok $provider->_is_create_env($ast, 'tagged-ce'), "tag 'create-env' detected";
	ok !$provider->_is_create_env($ast, 'nonexistent'), "missing target returns false";
};

subtest 'Concourse - _unwrap_ref' => sub {
	my $ast = Genesis::CI::Compiler::AST->new();
	my $provider = Genesis::CI::Concourse->new(ast => $ast);

	is $provider->_unwrap_ref('plain-value'), 'plain-value',
		"plain scalar passes through";
	is $provider->_unwrap_ref({ secret_ref => 'vault/path' }), '((vault/path))',
		"secret_ref hash is unwrapped to ((...)) format";
	is $provider->_unwrap_ref(undef), undef,
		"undef passes through as undef";
};

### ============================================================ ###
### Concourse Provider - output_files
### ============================================================ ###

subtest 'Concourse - output_files' => sub {
	my $ast = Genesis::CI::Compiler::AST->new();
	my $provider = Genesis::CI::Concourse->new(ast => $ast);

	my $files = $provider->output_files;
	is_deeply $files, { 'pipeline.yml' => 'Concourse pipeline definition' },
		"output_files returns expected structure";
};

### ============================================================ ###
### Concourse Provider - generate_from_ast routing
### ============================================================ ###

subtest 'Concourse - generate_from_ast routes to native for non-legacy' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		metadata => { name => 'test', source => 'modern' },
		branches => { live => 'main' },
		integrations => {
			source_control => { provider => 'github', repository => 'org/repo' },
		},
		workflows => {
			default => {
				name  => 'default',
				graph => { nodes => {}, edges => [] },
			},
		},
		configuration => {
			task => { image => 'img', version => 'v1' },
			notifications => { style => 'inline' },
		},
	);

	my $provider = Genesis::CI::Concourse->new(ast => $ast);
	my $output = $provider->generate_from_ast($ast);

	_debug_write('concourse-minimal.yml', $output // '');

	ok defined($output), "native generation produces output for modern AST";
	like $output, qr/^---/, "output starts with YAML document marker";
};

### ============================================================ ###
### CI.pm Factory - resolver
### ============================================================ ###

subtest 'CI factory - _resolve_provider_class' => sub {
	require Genesis::CI;

	my $concourse = Genesis::CI::_resolve_provider_class('concourse');
	is ref($concourse), 'HASH', "resolver returns hashref";
	is $concourse->{class}, 'Genesis::CI::Concourse', "concourse class correct";
	like $concourse->{file}, qr{Concourse\.pm$}, "concourse file path correct";

	my $gha = Genesis::CI::_resolve_provider_class('github-actions');
	is $gha->{class}, 'Genesis::CI::GithubActions', "github-actions class correct";
	like $gha->{file}, qr{GithubActions\.pm$}, "github-actions file path correct";

	eval { Genesis::CI::_resolve_provider_class('bogus') };
	like $@, qr/Unknown CI provider/, "unknown provider type bails";
};

### ============================================================ ###
### Compiler - resolver
### ============================================================ ###

subtest 'Compiler - _resolve_provider_class' => sub {
	my $compiler = Genesis::CI::Compiler->new(file => 'ci.yml');

	my $info = $compiler->_resolve_provider_class('concourse');
	is ref($info), 'HASH', "resolver returns hashref";
	is $info->{class}, 'Genesis::CI::Concourse', "class name correct";
	is $info->{file}, 'Genesis/CI/Compiler/Providers/Concourse.pm', "file path correct";

	eval { $compiler->_resolve_provider_class('nonexistent') };
	like $@, qr/Unknown CI provider/, "unknown provider type bails";
};

### ============================================================ ###
### Compiler - can_compile
### ============================================================ ###

subtest 'Compiler - can_compile' => sub {
	my $tmp = tempdir(CLEANUP => 1);

	ok !Genesis::CI::Compiler->can_compile("$tmp/nonexistent"),
		"can_compile returns false for nonexistent directory";

	# Create the expected structure
	mkpath("$tmp/test-ci");
	ok !Genesis::CI::Compiler->can_compile("$tmp/test-ci"),
		"can_compile returns false for directory without pipeline.yml";

	# Write pipeline.yml
	open my $fh, '>', "$tmp/test-ci/pipeline.yml" or die "Cannot write: $!";
	print $fh "---\nmetadata:\n  name: test\n";
	close $fh;

	ok Genesis::CI::Compiler->can_compile("$tmp/test-ci"),
		"can_compile returns true when pipeline.yml exists";
};

### ============================================================ ###
### GithubActions Provider Tests (if available)
### ============================================================ ###

SKIP: {
	skip "YAML::PP not available, skipping GithubActions tests", 1 unless $has_gha;

	subtest 'GithubActions - generate_from_ast' => sub {
		my $ast = Genesis::CI::Compiler::AST->new(
			metadata => {
				name            => 'gha-test',
				deployment_type => 'cf',
			},
			branches => { live => 'main' },
			integrations => {
				vault => { url => 'https://vault.example.com' },
				source_control => {
					provider => 'github',
					repository => 'org/repo',
					auth => { type => 'ssh-key', private_key => 'key' },
				},
				notifications => [],
			},
			targets => {
				sandbox => { type => 'bosh-director', connection => { url => 'https://bosh:25555' } },
			},
			workflows => {
				default => {
					name => 'default',
					graph => {
						nodes => {
							sandbox => { stage_name => 'sandbox', alias => 'sandbox', auto => 1 },
						},
						edges => [],
					},
				},
			},
			configuration => {
				task => { image => 'genesiscommunity/concourse', version => 'latest' },
			},
		);

		my $provider = Genesis::CI::GithubActions->new(ast => $ast);
		my $output = $provider->generate_from_ast($ast);

		_debug_write('github-actions-workflow.yml', $output // '');

		ok defined($output), "GHA generate_from_ast returns output";
		like $output, qr/name:\s*gha-test/, "output contains workflow name";
		like $output, qr/deploy-sandbox/, "output contains sandbox job";
		like $output, qr/actions\/checkout/, "output contains checkout step";
		like $output, qr/ubuntu-latest/, "output specifies ubuntu runner";
	};
}

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
