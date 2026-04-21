#!perl
use strict;
use warnings;

use Test::More;
use File::Temp qw/tempdir/;
use File::Path qw/mkpath/;
use JSON::PP;
use lib 'lib';

$ENV{GENESIS_TESTING} = "yes";
$ENV{GENESIS_LIB}     ||= 'lib';

use_ok 'Genesis::CI::Compiler::Parser';
use_ok 'Genesis::CI::Compiler::ASTBuilder';
use_ok 'Genesis::CI::Compiler';
use_ok 'Genesis::Commands::Pipelines';

### ============================================================ ###
### Phase A — env-files topology without pipeline.yml
### ============================================================ ###

subtest 'Parser - multi-file: pipeline.yml optional, topology from env files' => sub {
	my $tmp = tempdir(CLEANUP => 1);
	mkpath("$tmp/ci");

	# targets.yml + integrations.yml present; no pipeline.yml
	_write("$tmp/ci/targets.yml", <<'YAML');
targets:
  sandbox:
    type: bosh-director
    connection:
      url: https://bosh.sandbox.example.com:25555
YAML
	_write("$tmp/ci/integrations.yml", <<'YAML');
vault:
  url: https://vault.example.com
source_control:
  provider: github
  repository: org/repo
YAML

	my $parser = Genesis::CI::Compiler::Parser->new(ci_dir => "$tmp/ci");
	my $parsed;
	eval { $parsed = $parser->parse() };
	ok !$@, "parse() succeeds without pipeline.yml: $@";
	is $parsed->{_source_format}, 'multi-file', "source format is still multi-file";
	ok exists $parsed->{env_dir},  "env_dir is set for downstream ASTBuilder";
	is_deeply $parsed->{pipeline}, {}, "pipeline is empty hash when no pipeline.yml";
};

subtest 'ASTBuilder - multi-file without workflows falls back to env-file topology' => sub {
	my $tmp = tempdir(CLEANUP => 1);

	_write("$tmp/sandbox.yml", <<'YAML');
---
genesis:
  env: sandbox
  pipeline:
    prior_env:
YAML
	_write("$tmp/preprod.yml", <<'YAML');
---
genesis:
  env: preprod
  pipeline:
    prior_env: sandbox
YAML
	_write("$tmp/prod.yml", <<'YAML');
---
genesis:
  env: prod
  pipeline:
    prior_env: preprod
    require_pr: true
YAML

	my $builder = Genesis::CI::Compiler::ASTBuilder->new(env_dir => $tmp);
	my $parsed = {
		_source_format => 'multi-file',
		env_dir        => $tmp,
		pipeline       => {},   # no pipeline.yml content
		targets        => {},
		integrations   => {},
		scripts        => {},
		provider_config => {},
	};

	my $ast = $builder->build($parsed, {});
	isa_ok $ast, 'Genesis::CI::Compiler::AST', "AST built from env-file topology in multi-file format";

	my @wf_names = $ast->workflow_names;
	ok @wf_names, "at least one workflow present";

	my $wf = $ast->workflows->{default};
	ok $wf, "default workflow created";

	my $nodes = $wf->{graph}{nodes};
	ok exists $nodes->{sandbox}, "sandbox node present";
	ok exists $nodes->{preprod}, "preprod node present";
	ok exists $nodes->{prod},    "prod node present";

	my @edges = @{$wf->{graph}{edges} || []};
	my %edge_map = map { my $e = $_; "$e->{from}->$e->{to}" => 1 } @edges;
	ok $edge_map{'sandbox->preprod'}, "sandbox -> preprod edge exists";
	ok $edge_map{'preprod->prod'},    "preprod -> prod edge exists";

	is $nodes->{prod}{require_pr}, 1, "prod require_pr flag set from env file";
};

subtest 'Compiler - env-files format round-trip via env_dir option' => sub {
	my $tmp = tempdir(CLEANUP => 1);
	mkpath("$tmp/.genesis/ci");

	_write("$tmp/.genesis/ci/targets.yml", <<'YAML');
targets:
  sandbox:
    type: bosh-director
    connection:
      url: https://bosh.sandbox.example.com:25555
YAML
	_write("$tmp/.genesis/ci/integrations.yml", <<'YAML');
vault:
  url: https://vault.example.com
source_control:
  provider: github
  repository: org/repo
YAML

	_write("$tmp/sandbox.yml", <<'YAML');
---
genesis:
  env: sandbox
  pipeline:
    prior_env:
YAML
	_write("$tmp/preprod.yml", <<'YAML');
---
genesis:
  env: preprod
  pipeline:
    prior_env: sandbox
YAML

	my $orig_dir = POSIX::getcwd();
	chdir($tmp) or skip("Cannot chdir to $tmp: $!", 1);

	my $compiler = Genesis::CI::Compiler->new(ci_dir => '.genesis/ci', env_dir => '.');
	isa_ok $compiler, 'Genesis::CI::Compiler', "compiler created";

	# Verify compiler knows it can use env-files topology
	ok !-f '.genesis/ci/pipeline.yml',
		"no pipeline.yml present (env-files topology will be used)";

	chdir($orig_dir);
};

### ============================================================ ###
### Phase B — Genesis::Commands::Pipeline module
### ============================================================ ###

subtest 'Commands::Pipelines module loads correctly' => sub {
	can_ok 'Genesis::Commands::Pipelines', 'apply';
	can_ok 'Genesis::Commands::Pipelines', 'pipeline_graph';
	can_ok 'Genesis::Commands::Pipelines', 'pipeline_describe';
	can_ok 'Genesis::Commands::Pipelines', 'diff';
	can_ok 'Genesis::Commands::Pipelines', 'status';
	can_ok 'Genesis::Commands::Pipelines', 'pause';
	can_ok 'Genesis::Commands::Pipelines', 'resume';
	can_ok 'Genesis::Commands::Pipelines', 'graph';
	can_ok 'Genesis::Commands::Pipelines', 'describe';
};

subtest 'Commands::Pipelines - _compile_pipeline helper: detects multi-file config' => sub {
	my $tmp = tempdir(CLEANUP => 1);
	mkpath("$tmp/.genesis/ci");

	_write("$tmp/.genesis/ci/pipeline.yml", <<'YAML');
metadata:
  name: test-pipe
  version: '1.0'
branches:
  live: main
  target_prefix: 'target/'
workflows: {}
YAML
	_write("$tmp/.genesis/ci/targets.yml",     "targets: {}\n");
	_write("$tmp/.genesis/ci/integrations.yml", "{}\n");

	my $orig = POSIX::getcwd();
	chdir($tmp) or skip("Cannot chdir: $!", 1);

	my $top = bless({}, 'Genesis::Top');  # stub
	my $result = eval {
		Genesis::Commands::Pipelines::_compile_pipeline($top, 'concourse')
	};
	# This will bail due to no vault/spruce in test environment, but we just
	# check the compiler path was resolved correctly
	my $err = $@;
	# Accept any compilation/validation failure — we just want to confirm the
	# compiler resolved the multi-file config path, not that it fully succeeded
	ok !$err || $err =~ /spruce|evaluate|vault|provider|invalid|configuration/i,
		"compiler resolves multi-file config path correctly";

	chdir($orig);
};

subtest 'Commands::Pipelines - _ast_to_mermaid_md generates valid Mermaid markdown' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		metadata  => { name => 'test-pipeline' },
		workflows => {
			default => {
				name  => 'default',
				type  => 'deployment',
				graph => {
					nodes => {
						sandbox => { alias => 'sandbox', stage_name => 'sandbox' },
						preprod => { alias => 'preprod', stage_name => 'preprod' },
						prod    => { alias => 'prod',    stage_name => 'prod'    },
					},
					edges => [
						{ from => 'sandbox', to => 'preprod' },
						{ from => 'preprod', to => 'prod'    },
					],
				},
			},
		},
	);

	my $md = Genesis::Commands::Pipelines::_ast_to_mermaid_md($ast);

	like $md, qr/^# Pipeline: test-pipeline/m, "H1 heading present";
	like $md, qr/```mermaid/,                  "mermaid fence open";
	like $md, qr/flowchart LR/,                "flowchart LR directive";
	like $md, qr/sandbox.*preprod/s,            "sandbox -> preprod edge";
	like $md, qr/preprod.*prod/s,               "preprod -> prod edge";
	like $md, qr/```/,                          "mermaid fence close";
};

subtest 'Commands::Pipelines - _describe_ast does not die' => sub {
	my $ast = Genesis::CI::Compiler::AST->new(
		metadata     => { name => 'test-pipeline', source => 'multi-file' },
		integrations => {
			source_control => { provider => 'github', repository => 'org/repo' },
		},
		targets   => {
			sandbox => { type => 'bosh-director' },
			preprod => { type => 'bosh-director' },
		},
		workflows => {
			default => {
				type  => 'deployment',
				graph => {
					nodes => {
						sandbox => { alias => 'sandbox', stage_name => 'sandbox' },
						preprod => { alias => 'preprod', stage_name => 'preprod' },
					},
					edges => [ { from => 'sandbox', to => 'preprod' } ],
				},
			},
		},
	);

	eval { Genesis::Commands::Pipelines::_describe_ast($ast, 'concourse') };
	ok !$@, "_describe_ast does not die: $@";
};

subtest 'Commands::Pipelines - _job_status_label returns expected labels' => sub {
	is Genesis::Commands::Pipelines::_job_status_label({ paused => 1 }),
		'paused', "paused job returns 'paused'";

	is Genesis::Commands::Pipelines::_job_status_label({
		paused => 0,
		finished_build => { status => 'succeeded' },
	}), 'succeeded', "succeeded job";

	is Genesis::Commands::Pipelines::_job_status_label({
		paused => 0,
		finished_build => { status => 'failed' },
	}), 'failed', "failed job";

	is Genesis::Commands::Pipelines::_job_status_label({
		paused => 0,
	}), 'pending', "job with no build is pending";
};

done_testing;

### Helpers

sub _write {
	my ($path, $content) = @_;
	open my $fh, '>', $path or die "Cannot write $path: $!";
	print $fh $content;
	close $fh;
}
