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

subtest 'AST - generic triggers and resources' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		triggers => {
			'git-push' => { type => 'git', branch => 'main', paths => ['*.yml'] },
			'schedule' => { type => 'time', interval => '24h' },
		},
		resources => {
			'lab-bosh' => { type => 'bosh-director', url => 'https://bosh.lab:25555' },
			'vault'    => { type => 'vault', url => 'https://vault.example.com' },
			'git-repo' => { type => 'git', uri => 'git@github.com:org/repo.git' },
		},
	);

	# Trigger accessors
	my @triggers = $ast->trigger_names;
	is_deeply \@triggers, ['git-push', 'schedule'], "trigger_names returns sorted names";
	is $ast->triggers->{'git-push'}{type}, 'git', "trigger type accessible";
	is $ast->triggers->{'schedule'}{interval}, '24h', "trigger data accessible";

	# Resource accessors
	my @resources = $ast->resource_names;
	is_deeply \@resources, ['git-repo', 'lab-bosh', 'vault'], "resource_names returns sorted names";
	is $ast->resources->{'lab-bosh'}{type}, 'bosh-director', "resource type accessible";

	# resources_matching
	my @bosh_resources = $ast->resources_matching('*-bosh');
	is scalar(@bosh_resources), 1, "resources_matching '*-bosh' finds 1 resource";
	is $bosh_resources[0]{type}, 'bosh-director', "matched resource has correct type";

	my @all_resources = $ast->resources_matching('*');
	is scalar(@all_resources), 3, "resources_matching '*' finds all 3 resources";
};

subtest 'AST - backward compat: triggers/resources empty by default' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		metadata => { name => 'compat-test' },
		targets  => { sandbox => { type => 'bosh-director' } },
	);

	is_deeply $ast->triggers, {}, "triggers defaults to empty hash";
	is_deeply $ast->resources, {}, "resources defaults to empty hash";
	# Legacy accessors still work
	is_deeply [sort keys %{$ast->targets}], ['sandbox'], "targets accessor still works";
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

subtest 'ASTBuilder - modern format populates generic fields' => sub {
	my $builder = Genesis::CI::Compiler::ASTBuilder->new();

	my $parsed = {
		_source_format => 'multi-file',
		pipeline => {
			metadata => { name => 'generic-test', version => '2.0' },
			branches => { live => 'main' },
			workflows => {
				deploy => {
					type   => 'deployment',
					stages => [{ name => 'sandbox', script => 'deploy' }],
				},
			},
			triggers => {
				'git-push' => { type => 'git', branch => 'main', paths => ['*.yml'] },
			},
			resources => {
				'lab-bosh' => { type => 'bosh-director', url => 'https://bosh:25555' },
			},
		},
		integrations => {
			vault => { url => 'https://vault.example.com' },
			source_control => { provider => 'github', repository => 'org/repo' },
		},
		targets => { sandbox => { type => 'bosh-director' } },
	};

	my $ast = $builder->build($parsed, {});

	# Explicit triggers/resources are passed through
	ok exists $ast->triggers->{'git-push'}, "explicit triggers preserved";
	is $ast->triggers->{'git-push'}{type}, 'git', "trigger type preserved";
	ok exists $ast->resources->{'lab-bosh'}, "explicit resources preserved";
	is $ast->resources->{'lab-bosh'}{type}, 'bosh-director', "resource type preserved";
};

subtest 'ASTBuilder - no auto-population without explicit triggers/resources' => sub {
	my $builder = Genesis::CI::Compiler::ASTBuilder->new();

	my $parsed = {
		_source_format => 'multi-file',
		pipeline => {
			metadata  => { name => 'no-auto-pop-test' },
			branches  => { live => 'main' },
			workflows => {},
			# No explicit triggers or resources
		},
		integrations => {
			vault          => { url => 'https://vault.example.com', auth => { role_id => 'r' } },
			source_control => { provider => 'github', repository => 'org/repo' },
		},
		targets => {
			sandbox => { type => 'bosh-director', connection => { url => 'https://bosh:25555' } },
		},
	};

	my $ast = $builder->build($parsed, {});

	# Without explicit triggers/resources, AST should have empty hashes
	# (auto-population is PipelineDescriptor's job, not ASTBuilder's)
	is_deeply $ast->triggers, {}, "triggers empty without explicit config";
	is_deeply $ast->resources, {}, "resources empty without explicit config";

	# But targets and integrations are still accessible
	ok exists $ast->targets->{sandbox}, "targets still accessible";
	ok exists $ast->integrations->{vault}, "integrations still accessible";
};

### ============================================================ ###
### ASTBuilder - _build_from_env_files Tests
### ============================================================ ###

subtest 'ASTBuilder - _build_from_env_files: basic linear chain' => sub {
	my $tmp = tempdir(CLEANUP => 1);

	# lab.yml — entry point, no prior_env
	open my $fh, '>', "$tmp/lab.yml" or die $!;
	print $fh "---\ngenesis:\n  pipeline:\n    require_pr: false\n";
	close $fh;

	# nonprod.yml — triggered after lab
	open $fh, '>', "$tmp/nonprod.yml" or die $!;
	print $fh "---\ngenesis:\n  pipeline:\n    prior_env: lab\n";
	close $fh;

	# prod.yml — triggered after nonprod, requires PR
	open $fh, '>', "$tmp/prod.yml" or die $!;
	print $fh "---\ngenesis:\n  pipeline:\n    prior_env: nonprod\n    require_pr: true\n";
	close $fh;

	my $builder = Genesis::CI::Compiler::ASTBuilder->new();
	my ($nodes, $edges) = $builder->_build_from_env_files($tmp);

	ok exists $nodes->{lab},     "lab node present";
	ok exists $nodes->{nonprod}, "nonprod node present";
	ok exists $nodes->{prod},    "prod node present";

	my @sorted_edges = sort { $a->{from} cmp $b->{from} } @$edges;
	is scalar(@sorted_edges), 2, "two edges built";
	is $sorted_edges[0]{from}, 'lab',     "first edge: lab -> nonprod (from)";
	is $sorted_edges[0]{to},   'nonprod', "first edge: lab -> nonprod (to)";
	is $sorted_edges[1]{from}, 'nonprod', "second edge: nonprod -> prod (from)";
	is $sorted_edges[1]{to},   'prod',    "second edge: nonprod -> prod (to)";

	ok !$nodes->{prod}{require_pr} == 0 || $nodes->{prod}{require_pr},
		"prod node has require_pr set";
	is $nodes->{prod}{require_pr}, 1, "prod require_pr is 1";
	is $nodes->{lab}{require_pr},  0, "lab require_pr is 0";
};

subtest 'ASTBuilder - _build_from_env_files: manual gate flag' => sub {
	my $tmp = tempdir(CLEANUP => 1);

	open my $fh, '>', "$tmp/sandbox.yml" or die $!;
	print $fh "---\ngenesis:\n  pipeline:\n    manual: true\n";
	close $fh;

	open $fh, '>', "$tmp/prod.yml" or die $!;
	print $fh "---\ngenesis:\n  pipeline:\n    prior_env: sandbox\n    manual: false\n";
	close $fh;

	my $builder = Genesis::CI::Compiler::ASTBuilder->new();
	my ($nodes, $edges) = $builder->_build_from_env_files($tmp);

	is $nodes->{sandbox}{manual}, 1, "sandbox manual flag is 1";
	is $nodes->{prod}{manual},    0, "prod manual flag is 0";
};

subtest 'ASTBuilder - _build_from_env_files: files without genesis.pipeline ignored' => sub {
	my $tmp = tempdir(CLEANUP => 1);

	# file with genesis block but no pipeline sub-key
	open my $fh, '>', "$tmp/infra.yml" or die $!;
	print $fh "---\ngenesis:\n  env: infra\n";
	close $fh;

	# unrelated YAML file
	open $fh, '>', "$tmp/params.yml" or die $!;
	print $fh "---\nparams:\n  key: value\n";
	close $fh;

	my $builder = Genesis::CI::Compiler::ASTBuilder->new();
	my ($nodes, $edges) = $builder->_build_from_env_files($tmp);

	is scalar(keys %$nodes), 0, "no nodes from files without genesis.pipeline";
	is scalar(@$edges),      0, "no edges either";
};

subtest 'ASTBuilder - _build_from_env_files: prior_env referencing unknown env is ignored' => sub {
	my $tmp = tempdir(CLEANUP => 1);

	open my $fh, '>', "$tmp/prod.yml" or die $!;
	print $fh "---\ngenesis:\n  pipeline:\n    prior_env: missing-lab\n";
	close $fh;

	my $builder = Genesis::CI::Compiler::ASTBuilder->new();
	my ($nodes, $edges) = $builder->_build_from_env_files($tmp);

	ok exists $nodes->{prod}, "prod node still created";
	is scalar(@$edges), 0, "no edge added for unknown prior_env";
};

subtest 'ASTBuilder - _build_from_env_files: non-existent dir returns empty' => sub {
	my $builder = Genesis::CI::Compiler::ASTBuilder->new();
	my ($nodes, $edges) = $builder->_build_from_env_files('/does/not/exist/xyz');
	is scalar(keys %$nodes), 0, "no nodes for missing dir";
	is scalar(@$edges),      0, "no edges for missing dir";
};

subtest 'ASTBuilder - env-files format: build() produces AST with workflow graph' => sub {
	my $tmp = tempdir(CLEANUP => 1);

	open my $fh, '>', "$tmp/lab.yml" or die $!;
	print $fh "---\ngenesis:\n  pipeline:\n    require_pr: false\n";
	close $fh;

	open $fh, '>', "$tmp/prod.yml" or die $!;
	print $fh "---\ngenesis:\n  pipeline:\n    prior_env: lab\n    require_pr: true\n";
	close $fh;

	my $builder = Genesis::CI::Compiler::ASTBuilder->new();
	my $ast = $builder->build({
		_source_format => 'env-files',
		env_dir        => $tmp,
		pipeline       => { metadata => { name => 'ef-test' } },
	}, {});

	isa_ok $ast, 'Genesis::CI::Compiler::AST', "build returns AST";
	ok $ast->workflows->{default}, "default workflow created";
	my $graph = $ast->workflows->{default}{graph};
	ok $graph, "workflow has graph";
	ok exists $graph->{nodes}{lab},  "lab node in graph";
	ok exists $graph->{nodes}{prod}, "prod node in graph";

	my @edges = @{$graph->{edges}};
	is scalar(@edges), 1, "one edge";
	is $edges[0]{from}, 'lab',  "edge from lab";
	is $edges[0]{to},   'prod', "edge to prod";

	is $graph->{nodes}{prod}{require_pr}, 1, "prod require_pr=1 in AST";
	is $graph->{nodes}{lab}{require_pr},  0, "lab require_pr=0 in AST";
};

subtest 'ASTBuilder - legacy nodes enriched with gate flags from env files' => sub {
	my $tmp = tempdir(CLEANUP => 1);

	open my $fh, '>', "$tmp/sandbox.yml" or die $!;
	print $fh "---\ngenesis:\n  pipeline:\n    manual: false\n";
	close $fh;

	open $fh, '>', "$tmp/prod.yml" or die $!;
	print $fh "---\ngenesis:\n  pipeline:\n    require_pr: true\n    manual: true\n";
	close $fh;

	my $builder = Genesis::CI::Compiler::ASTBuilder->new(env_dir => $tmp);
	my $parsed = {
		_source_format => 'legacy',
		_source_path   => 'ci.yml',
		_legacy_raw    => {
			pipeline => {
				name   => 'enrich-test',
				git    => { branch => 'main' },
				boshes => {
					sandbox => { alias => 'sandbox' },
					prod    => { alias => 'prod' },
				},
				task => { image => 'genesiscommunity/concourse', version => 'latest' },
			},
		},
		integrations => {},
		targets      => {},
		pipeline     => {
			workflows => {
				default => {
					environments  => [qw(sandbox prod)],
					auto_patterns => [],
					will_trigger  => { sandbox => ['prod'] },
				},
			},
		},
	};
	my $ast = $builder->build($parsed, {});

	my $nodes = $ast->workflows->{default}{graph}{nodes};
	is $nodes->{prod}{require_pr}, 1, "prod require_pr enriched from env file";
	is $nodes->{prod}{manual},     1, "prod manual enriched from env file";
	is $nodes->{sandbox}{manual},  0, "sandbox manual=0 from env file";
};

subtest 'ASTBuilder + PipelineDescriptor - end-to-end env-file mermaid gates' => sub {
	my $tmp = tempdir(CLEANUP => 1);

	open my $fh, '>', "$tmp/lab.yml" or die $!;
	print $fh "---\ngenesis:\n  pipeline:\n    require_pr: false\n";
	close $fh;

	open $fh, '>', "$tmp/prod.yml" or die $!;
	print $fh "---\ngenesis:\n  pipeline:\n    prior_env: lab\n    require_pr: true\n    manual: true\n";
	close $fh;

	my $builder = Genesis::CI::Compiler::ASTBuilder->new();
	my $ast = $builder->build({
		_source_format => 'env-files',
		env_dir        => $tmp,
		pipeline       => { metadata => { name => 'e2e-gate-test' } },
	}, {});

	my $descriptor = Genesis::CI::Compiler::PipelineDescriptor->new(ast => $ast);
	my $mermaid = $descriptor->mermaid();

	like $mermaid, qr/flowchart LR/,                      "starts with flowchart LR";
	like $mermaid, qr/lab\s+-->/,                         "lab has outgoing edge";
	like $mermaid, qr/prod\(\[prod\\nPR\+MANUAL\]\)/,     "prod has PR+MANUAL gate annotation";
	unlike $mermaid, qr/lab\(\[/,                         "lab has no gate annotation";
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
### PipelineDescriptor - Internal Helpers
### ============================================================ ###

use_ok 'Genesis::CI::Compiler::PipelineDescriptor';

subtest 'PipelineDescriptor - _env_file_patterns' => sub {
	# _env_file_patterns is a package function in PipelineDescriptor
	my @patterns = Genesis::CI::Compiler::PipelineDescriptor::_env_file_patterns('us-west-1-sandbox');
	is_deeply \@patterns, [
		'us.yml',
		'us-west.yml',
		'us-west-1.yml',
		'us-west-1-sandbox.yml',
	], "_env_file_patterns computes correct hierarchical files";

	@patterns = Genesis::CI::Compiler::PipelineDescriptor::_env_file_patterns('sandbox');
	is_deeply \@patterns, ['sandbox.yml'],
		"single-segment env has one pattern";
};

subtest 'PipelineDescriptor - _unique_env_files' => sub {
	my @unique = Genesis::CI::Compiler::PipelineDescriptor::_unique_env_files(
		'us-west-1-preprod', 'us-west-1-sandbox');
	is_deeply \@unique, ['us-west-1-preprod.yml'],
		"unique files for preprod (triggered by sandbox) is just the preprod-specific file";

	@unique = Genesis::CI::Compiler::PipelineDescriptor::_unique_env_files(
		'us-east-1-sandbox', 'us-west-1-sandbox');
	is_deeply \@unique, [
		'us-east.yml',
		'us-east-1.yml',
		'us-east-1-sandbox.yml',
	], "unique files when common prefix is just 'us'";
};

subtest 'PipelineDescriptor - _shared_env_files' => sub {
	my @shared = Genesis::CI::Compiler::PipelineDescriptor::_shared_env_files(
		'us-west-1-preprod', 'us-west-1-sandbox');
	is_deeply \@shared, [
		'us.yml',
		'us-west.yml',
		'us-west-1.yml',
	], "shared files between sandbox and preprod in same region";

	@shared = Genesis::CI::Compiler::PipelineDescriptor::_shared_env_files(
		'us-east-1-sandbox', 'us-west-1-sandbox');
	is_deeply \@shared, ['us.yml'],
		"shared files between different regions is just the top-level";
};

subtest 'PipelineDescriptor - _is_create_env' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		targets => {
			'proto-bosh' => { type => 'bosh-create-env' },
			'regular'    => { type => 'bosh-director' },
			'tagged-ce'  => { tags => ['create-env'] },
		},
	);

	my $descriptor = Genesis::CI::Compiler::PipelineDescriptor->new(ast => $ast);
	ok $descriptor->_is_create_env($ast, 'proto-bosh'), "type=bosh-create-env detected";
	ok !$descriptor->_is_create_env($ast, 'regular'), "type=bosh-director is not create-env";
	ok $descriptor->_is_create_env($ast, 'tagged-ce'), "tag 'create-env' detected";
	ok !$descriptor->_is_create_env($ast, 'nonexistent'), "missing target returns false";
};

subtest 'PipelineDescriptor - _unwrap_ref' => sub {
	is Genesis::CI::Compiler::PipelineDescriptor::_unwrap_ref('plain-value'), 'plain-value',
		"plain scalar passes through";
	is Genesis::CI::Compiler::PipelineDescriptor::_unwrap_ref({ secret_ref => 'vault/path' }),
		'((vault/path))', "secret_ref hash is unwrapped to ((...)) format";
	is Genesis::CI::Compiler::PipelineDescriptor::_unwrap_ref(undef), undef,
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
### Concourse Provider - Locker Resources and Jobs
### ============================================================ ###

subtest 'Concourse - locker resources generated when locker configured' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		metadata => {
			name            => 'locker-test',
			source          => 'modern',
			deployment_type => 'cf',
		},
		branches => { live => 'main' },
		integrations => {
			vault => {
				url  => 'https://vault.example.com',
				auth => { role_id => 'role', secret_id => 'secret' },
			},
			source_control => {
				provider   => 'github',
				repository => 'org/repo',
				auth       => { type => 'ssh-key', private_key => 'key' },
			},
			notifications => [],
			locker => {
				url      => 'https://locker.example.com',
				username => 'admin',
				password => 'pass',
			},
		},
		targets => {
			sandbox => {
				type => 'bosh-director',
				connection => {
					url  => 'https://bosh.sandbox:25555',
					auth => { client_id => 'admin', client_secret => 'secret' },
				},
			},
		},
		workflows => {
			default => {
				name => 'default',
				graph => {
					nodes => {
						sandbox => {
							stage_name => 'sandbox', alias => 'sandbox',
							genesis_env => 'sandbox', auto => 1,
						},
					},
					edges => [],
				},
			},
		},
		configuration => {
			task => { image => 'img', version => 'v1' },
			notifications => { style => 'inline' },
		},
	);

	my $provider = Genesis::CI::Concourse->new(ast => $ast);
	my $output = $provider->generate_from_ast($ast);

	_debug_write('concourse-locker.yml', $output // '');

	# Locker resources
	like $output, qr/sandbox-bosh-lock/, "bosh-lock resource present";
	like $output, qr/sandbox-deployment-lock/, "deployment-lock resource present";
	like $output, qr/shield-lock-outline/, "locker icon present";

	# Locker lock/unlock steps in deploy job
	like $output, qr/lock_op: lock/, "lock step present";
	like $output, qr/lock_op: unlock/, "unlock step in ensure present";
	like $output, qr/dont-upgrade-bosh-on-me/, "bosh lock key present";
	like $output, qr/i-need-to-deploy-myself/, "deployment lock key present";
};

subtest 'Concourse - locker skips bosh-lock for create-env' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		metadata => { name => 'ce-test', deployment_type => 'bosh', source => 'modern' },
		branches => { live => 'main' },
		integrations => {
			vault => { url => 'https://vault.example.com' },
			source_control => {
				provider => 'github', repository => 'org/repo',
				auth => { type => 'ssh-key', private_key => 'key' },
			},
			notifications => [],
			locker => { url => 'https://locker.example.com', username => 'u', password => 'p' },
		},
		targets => {
			'proto-bosh' => {
				type => 'bosh-create-env',
				connection => { url => 'https://proto:25555' },
			},
		},
		workflows => {
			default => {
				name => 'default',
				graph => {
					nodes => { 'proto-bosh' => {
						stage_name => 'proto-bosh', alias => 'proto',
						genesis_env => 'proto-bosh', auto => 1,
					}},
					edges => [],
				},
			},
		},
		configuration => {
			task => { image => 'img', version => 'v1' },
			notifications => { style => 'inline' },
		},
	);

	my $provider = Genesis::CI::Concourse->new(ast => $ast);
	my $output = $provider->generate_from_ast($ast);

	_debug_write('concourse-create-env-locker.yml', $output // '');

	# Deployment lock should exist, bosh-lock should NOT
	like $output, qr/proto-deployment-lock/, "deployment-lock present for create-env";
	unlike $output, qr/proto-bosh-lock/, "bosh-lock absent for create-env";
};

### ============================================================ ###
### Concourse Provider - Auto-Update Job
### ============================================================ ###

subtest 'Concourse - auto-update job generated' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		metadata => { name => 'autoupdate-test', deployment_type => 'cf', source => 'modern' },
		branches => { live => 'main' },
		integrations => {
			vault => { url => 'https://vault.example.com' },
			source_control => {
				provider => 'github', repository => 'org/repo',
				auth => { type => 'ssh-key', private_key => 'key' },
			},
			notifications => [],
		},
		targets => {
			sandbox => {
				type => 'bosh-director',
				connection => { url => 'https://bosh:25555',
					auth => { client_id => 'admin', client_secret => 's' } },
			},
		},
		workflows => {
			default => {
				name => 'default',
				graph => {
					nodes => { sandbox => {
						stage_name => 'sandbox', alias => 'sandbox',
						genesis_env => 'sandbox', auto => 1,
					}},
					edges => [],
				},
			},
		},
		configuration => {
			task => { image => 'img', version => 'v1' },
			notifications => { style => 'inline' },
			auto_update => {
				file => 'sandbox.yml',
				kit  => 'cf',
				org  => 'genesis-community',
			},
		},
	);

	my $provider = Genesis::CI::Concourse->new(ast => $ast);
	my $output = $provider->generate_from_ast($ast);

	_debug_write('concourse-autoupdate.yml', $output // '');

	# Auto-update resources
	like $output, qr/kit-release/, "kit-release resource present";
	like $output, qr/genesis-release/, "genesis-release resource present";
	like $output, qr/github-release/, "github-release resource type used";

	# Auto-update job
	like $output, qr/update-genesis-assets/, "auto-update job present";
	like $output, qr/list-kits/, "list-kits task present";
	like $output, qr/update-genesis/, "update-genesis task present";
	like $output, qr/fetch-kit/, "fetch-kit task present";

	# Auto-update group
	like $output, qr/genesis-updates/, "genesis-updates group present";
};

### ============================================================ ###
### Concourse Provider - Groups with Notification Grouping
### ============================================================ ###

subtest 'Concourse - grouped notifications' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		metadata => { name => 'grouped-test', deployment_type => 'cf', source => 'modern' },
		branches => { live => 'main' },
		integrations => {
			vault => { url => 'https://vault.example.com' },
			source_control => {
				provider => 'github', repository => 'org/repo',
				auth => { type => 'ssh-key', private_key => 'key' },
			},
			notifications => [{ type => 'slack', webhook => 'https://hooks.slack.com', channel => '#ci' }],
		},
		targets => {
			sandbox => {
				type => 'bosh-director',
				connection => { url => 'https://bosh1:25555',
					auth => { client_id => 'admin', client_secret => 's' },
					ca_cert => 'cert1' },
			},
			prod => {
				type => 'bosh-director',
				connection => { url => 'https://bosh2:25555',
					auth => { client_id => 'admin', client_secret => 's' },
					ca_cert => 'cert2' },
			},
		},
		workflows => {
			default => {
				name => 'default',
				graph => {
					nodes => {
						sandbox => { stage_name => 'sandbox', alias => 'sandbox',
							genesis_env => 'sandbox', auto => 1 },
						prod    => { stage_name => 'prod', alias => 'prod',
							genesis_env => 'prod', auto => 0 },
					},
					edges => [{ from => 'sandbox', to => 'prod' }],
				},
			},
		},
		configuration => {
			task => { image => 'img', version => 'v1' },
			notifications => { style => 'grouped' },
		},
	);

	my $provider = Genesis::CI::Concourse->new(ast => $ast);
	my $output = $provider->generate_from_ast($ast);

	_debug_write('concourse-grouped.yml', $output // '');

	# With grouped notifications, notify jobs should be in a separate group
	like $output, qr/name: notifications/, "notifications group present";
	like $output, qr/notify-prod-cf-changes/, "notify job present for non-auto env";
};

subtest 'Concourse - custom groups' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		metadata => { name => 'custom-groups-test', deployment_type => 'cf', source => 'modern' },
		branches => { live => 'main' },
		integrations => {
			vault => { url => 'https://vault.example.com' },
			source_control => {
				provider => 'github', repository => 'org/repo',
				auth => { type => 'ssh-key', private_key => 'key' },
			},
			notifications => [],
		},
		targets => {
			sandbox => {
				type => 'bosh-director',
				connection => { url => 'https://bosh1:25555',
					auth => { client_id => 'admin', client_secret => 's' } },
			},
			prod => {
				type => 'bosh-director',
				connection => { url => 'https://bosh2:25555',
					auth => { client_id => 'admin', client_secret => 's' } },
			},
		},
		workflows => {
			default => {
				name => 'default',
				graph => {
					nodes => {
						sandbox => { stage_name => 'sandbox', alias => 'sandbox',
							genesis_env => 'sandbox', auto => 1 },
						prod    => { stage_name => 'prod', alias => 'prod',
							genesis_env => 'prod', auto => 0 },
					},
					edges => [{ from => 'sandbox', to => 'prod' }],
				},
			},
		},
		configuration => {
			task => { image => 'img', version => 'v1' },
			notifications => { style => 'inline' },
			groups => {
				'non-prod' => ['sandbox'],
				'production' => ['prod'],
			},
		},
	);

	my $provider = Genesis::CI::Concourse->new(ast => $ast);
	my $output = $provider->generate_from_ast($ast);

	_debug_write('concourse-custom-groups.yml', $output // '');

	like $output, qr/name: non-prod/, "custom group 'non-prod' present";
	like $output, qr/name: production/, "custom group 'production' present";
};

### ============================================================ ###
### Concourse Provider - OCFP Config Name Support
### ============================================================ ###

subtest 'Concourse - OCFP config name support' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		metadata => { name => 'ocfp-test', deployment_type => 'cf', source => 'modern' },
		branches => { live => 'main' },
		integrations => {
			vault => { url => 'https://vault.example.com' },
			source_control => {
				provider => 'github', repository => 'org/repo',
				auth => { type => 'ssh-key', private_key => 'key' },
			},
			notifications => [],
		},
		targets => {
			'us-west-1-sandbox' => {
				type => 'bosh-director',
				connection => {
					url     => 'https://bosh:25555',
					ca_cert => 'cert',
					auth    => { client_id => 'admin', client_secret => 'secret' },
				},
			},
		},
		workflows => {
			default => {
				name => 'default',
				graph => {
					nodes => { 'us-west-1-sandbox' => {
						stage_name => 'us-west-1-sandbox', alias => 'sandbox',
						genesis_env => 'us-west-1-sandbox', auto => 1,
					}},
					edges => [],
				},
			},
		},
		configuration => {
			ocfp => 1,
			task => { image => 'img', version => 'v1' },
			notifications => { style => 'inline' },
		},
	);

	my $provider = Genesis::CI::Concourse->new(ast => $ast);
	my $output = $provider->generate_from_ast($ast);

	_debug_write('concourse-ocfp.yml', $output // '');

	# OCFP mode should use genesis_envs for config names
	like $output, qr/sandbox-cloud-config/, "cloud-config resource present";
	like $output, qr/sandbox-runtime-config/, "runtime-config resource present";
	# The BOSH config resource should include the genesis_env-based config name
	like $output, qr/name: us-west-1-sandbox/, "OCFP config name present in bosh-config source";
};

### ============================================================ ###
### Concourse Provider - Native Graphviz and Describe
### ============================================================ ###

subtest 'PipelineDescriptor - mermaid basic generation' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		metadata => { name => 'mermaid-test', deployment_type => 'cf' },
		workflows => {
			default => {
				name => 'default',
				graph => {
					nodes => {
						sandbox => { stage_name => 'sandbox', alias => 'sandbox', auto => 1 },
						preprod => { stage_name => 'preprod', alias => 'preprod', auto => 0 },
						prod    => { stage_name => 'prod',    alias => 'prod',    auto => 0 },
					},
					edges => [
						{ from => 'sandbox', to => 'preprod' },
						{ from => 'preprod', to => 'prod' },
					],
				},
			},
		},
	);

	my $descriptor = Genesis::CI::Compiler::PipelineDescriptor->new(ast => $ast);
	my $mermaid = $descriptor->mermaid();

	_debug_write('pipeline-mermaid.txt', $mermaid // '');

	like $mermaid, qr/^flowchart LR/m,       "starts with flowchart LR";
	like $mermaid, qr/sandbox\s+-->/,        "sandbox has outgoing edge";
	like $mermaid, qr/sandbox\s+-->\s+preprod/, "edge from sandbox to preprod";
	like $mermaid, qr/preprod\s+-->\s+prod/,    "edge from preprod to prod";
	unlike $mermaid, qr/digraph/,            "no DOT syntax present";
};

subtest 'PipelineDescriptor - mermaid gate annotations' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		metadata => { name => 'gate-test' },
		workflows => {
			default => {
				name => 'default',
				graph => {
					nodes => {
						lab     => { alias => 'lab',     auto => 1 },
						nonprod => { alias => 'nonprod', auto => 0 },
						prod    => { alias => 'prod',    auto => 0, require_pr => 1 },
						staging => { alias => 'staging', auto => 0, require_pr => 1, manual => 1 },
						mgmt    => { alias => 'mgmt',    auto => 0, manual => 1 },
					},
					edges => [
						{ from => 'lab',     to => 'nonprod' },
						{ from => 'nonprod', to => 'prod'    },
						{ from => 'nonprod', to => 'staging' },
					],
				},
			},
		},
	);

	my $descriptor = Genesis::CI::Compiler::PipelineDescriptor->new(ast => $ast);
	my $mermaid = $descriptor->mermaid();

	_debug_write('pipeline-mermaid-gates.txt', $mermaid // '');

	like $mermaid, qr/prod\(\[prod\\nPR\]\)/,              "PR gate annotation on prod";
	like $mermaid, qr/staging\(\[staging\\nPR\+MANUAL\]\)/, "PR+MANUAL annotation on staging";
	like $mermaid, qr/mgmt\(\[mgmt\\nMANUAL\]\)/,          "MANUAL annotation on isolated mgmt";
	unlike $mermaid, qr/lab\(\[/,    "lab has no gate annotation";
	unlike $mermaid, qr/nonprod\(\[/, "nonprod has no gate annotation";
};

subtest 'PipelineDescriptor - mermaid isolated nodes' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		metadata => { name => 'isolated-test' },
		workflows => {
			default => {
				name => 'default',
				graph => {
					nodes => {
						connected => { alias => 'connected' },
						isolated  => { alias => 'isolated'  },
					},
					edges => [
						{ from => 'connected', to => 'connected' },
					],
				},
			},
		},
	);

	# Single-node isolated: no edges at all
	my $ast2 = Genesis::CI::Compiler::AST->new(
		metadata => { name => 'solo-test' },
		workflows => {
			default => {
				name => 'default',
				graph => {
					nodes => { solo => { alias => 'solo', manual => 1 } },
					edges => [],
				},
			},
		},
	);

	my $descriptor = Genesis::CI::Compiler::PipelineDescriptor->new(ast => $ast2);
	my $mermaid = $descriptor->mermaid();

	like $mermaid, qr/solo\(\[solo\\nMANUAL\]\)/, "isolated gated node rendered standalone";
};

subtest 'PipelineDescriptor - pipeline_md format' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		metadata => { name => 'md-test' },
		workflows => {
			default => {
				name  => 'default',
				graph => {
					nodes => {
						lab  => { alias => 'lab' },
						prod => { alias => 'prod' },
					},
					edges => [{ from => 'lab', to => 'prod' }],
				},
			},
		},
	);

	my $descriptor = Genesis::CI::Compiler::PipelineDescriptor->new(ast => $ast);
	my $md = $descriptor->pipeline_md();

	_debug_write('pipeline.md', $md // '');

	like $md, qr/^# Pipeline: md-test$/m, "Markdown h1 with pipeline name";
	like $md, qr/```mermaid/,             "fenced mermaid code block opens";
	like $md, qr/flowchart LR/,           "flowchart directive present";
	like $md, qr/lab\s+-->\s+prod/,       "edge present in md";
	like $md, qr/```\s*$/m,               "fenced code block closes";
};

subtest 'Concourse - native describe generation' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		metadata => { name => 'desc-test', deployment_type => 'cf' },
		workflows => {
			default => {
				name => 'default',
				graph => {
					nodes => {
						sandbox => { stage_name => 'sandbox', alias => 'sandbox', auto => 1 },
						prod    => { stage_name => 'prod', alias => 'prod', auto => 0 },
					},
					edges => [{ from => 'sandbox', to => 'prod' }],
				},
			},
		},
	);

	my $descriptor = Genesis::CI::Compiler::PipelineDescriptor->new(ast => $ast);

	# description() returns a string
	my $output = $descriptor->description();
	ok length($output) > 0, "describe produces output";
	like $output, qr/Pipeline:/, "output contains Pipeline header";
	like $output, qr/sandbox/, "output mentions sandbox env";
};

### ============================================================ ###
### Concourse Provider - Locker Resources Helper
### ============================================================ ###

subtest 'PipelineDescriptor - _locker_resources' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		integrations => {
			locker => { url => 'https://locker:8910', username => 'u', password => 'p' },
		},
		targets => {
			sandbox => {
				type => 'bosh-director',
				connection => { url => 'https://bosh:25555' },
			},
		},
		configuration => { tagged => 0 },
	);

	my $descriptor = Genesis::CI::Compiler::PipelineDescriptor->new(ast => $ast);
	my $resources = $descriptor->_locker_resources($ast, 'sandbox', 'sandbox', 'cf', 0);

	is scalar(@$resources), 2, "non-create-env gets 2 locker resources (bosh + deployment)";
	is $resources->[0]{name}, 'sandbox-bosh-lock', "first resource is bosh-lock";
	is $resources->[1]{name}, 'sandbox-deployment-lock', "second resource is deployment-lock";
	is $resources->[0]{source}{bosh_lock}, 'https://bosh:25555', "bosh_lock has correct URL";
	is $resources->[1]{source}{lock_name}, 'sandbox-cf', "lock_name has correct format";

	# create-env should skip bosh-lock
	my $ce_resources = $descriptor->_locker_resources($ast, 'proto', 'proto', 'bosh', 1);
	is scalar(@$ce_resources), 1, "create-env gets only 1 locker resource (deployment only)";
	is $ce_resources->[0]{name}, 'proto-deployment-lock', "only deployment-lock for create-env";
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

	my $result = Genesis::CI::Compiler->can_compile("$tmp/test-ci");
	ok $result, "can_compile returns true when pipeline.yml exists";
};

### ============================================================ ###
### Compiler - _apply_provider_overrides
### ============================================================ ###

subtest 'Compiler - override skipped when file absent' => sub {
	my $tmp = tempdir(CLEANUP => 1);
	mkpath("$tmp/ci");

	my $compiler = Genesis::CI::Compiler->new(ci_dir => "$tmp/ci");
	my $output = { 'pipeline.yml' => "---\njobs: []\n" };

	my $result = $compiler->_apply_provider_overrides($output, 'concourse');
	is_deeply $result, $output,
		"output unchanged when ci-overrides-concourse.yml is absent";
};

subtest 'Compiler - override skipped for non-YAML files' => sub {
	my $tmp = tempdir(CLEANUP => 1);
	mkpath("$tmp/ci");

	# Create override file
	open my $fh, '>', "$tmp/ci/ci-overrides-concourse.yml" or die $!;
	print $fh "---\nfoo: overridden\n";
	close $fh;

	my $compiler = Genesis::CI::Compiler->new(ci_dir => "$tmp/ci");
	my $output = { 'pipeline.sh' => "#!/bin/bash\necho hi\n" };

	my $result = $compiler->_apply_provider_overrides($output, 'concourse');
	is_deeply $result, $output,
		"non-YAML output files are passed through unchanged";
};

subtest 'Compiler - override applied via spruce merge' => sub {
	my $spruce = do { chomp(my $s = `which spruce 2>/dev/null`); $s };
	unless ($spruce && -x $spruce) {
		plan skip_all => "spruce not in PATH";
		return;
	}

	my $tmp = tempdir(CLEANUP => 1);
	mkpath("$tmp/ci");

	open my $fh, '>', "$tmp/ci/ci-overrides-concourse.yml" or die $!;
	print $fh "---\nextra_key: injected_by_override\n";
	close $fh;

	my $compiler = Genesis::CI::Compiler->new(ci_dir => "$tmp/ci");
	my $output = { 'pipeline.yml' => "---\nbase_key: base_value\n" };

	my $result = $compiler->_apply_provider_overrides($output, 'concourse');
	ok defined($result->{'pipeline.yml'}), "merged pipeline.yml present";
	like $result->{'pipeline.yml'}, qr/base_key:\s*base_value/,
		"base content preserved after merge";
	like $result->{'pipeline.yml'}, qr/extra_key:\s*injected_by_override/,
		"override key added by merge";
};

subtest 'Compiler - override lookup uses ci_dir' => sub {
	my $tmp = tempdir(CLEANUP => 1);
	mkpath("$tmp/ci");
	mkpath("$tmp/other");

	# Override only in $tmp/other, not in $tmp/ci
	open my $fh, '>', "$tmp/other/ci-overrides-concourse.yml" or die $!;
	print $fh "---\nshould_not: appear\n";
	close $fh;

	my $compiler = Genesis::CI::Compiler->new(ci_dir => "$tmp/ci");
	my $output = { 'pipeline.yml' => "---\njobs: []\n" };

	my $result = $compiler->_apply_provider_overrides($output, 'concourse');
	is_deeply $result, $output,
		"override in wrong directory is not applied";
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
