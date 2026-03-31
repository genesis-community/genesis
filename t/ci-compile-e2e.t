#!/usr/bin/env perl
use strict;
use warnings;

# Minimal test harness to drive the CI compiler pipeline against
# a real .genesis/ci/ directory and see what comes out.

BEGIN {
	$ENV{GENESIS_LIB} ||= 'lib';
}

use lib 'lib';
use Test::More;
use File::Basename qw(dirname);

# Check that spruce is available
my $spruce = `which spruce 2>/dev/null`;
chomp $spruce;
unless ($spruce) {
	plan skip_all => 'spruce not found in PATH';
}

use_ok 'Genesis::CI::Compiler';
use_ok 'Genesis::CI::Compiler::Parser';
use_ok 'Genesis::CI::Compiler::Validator';
use_ok 'Genesis::CI::Compiler::ASTBuilder';
use_ok 'Genesis::CI::Compiler::PipelineDescriptor';
use_ok 'Genesis::CI::Compiler::AST';

my $ci_dir = 't/repos/compile-test/.genesis/ci';

# --- Stage 1: Can we detect the multi-file format? ---
subtest 'can_compile detects multi-file format' => sub {
	ok(Genesis::CI::Compiler->can_compile($ci_dir),
		"can_compile returns true for $ci_dir");
	ok(!Genesis::CI::Compiler->can_compile('t/repos/nonexistent'),
		"can_compile returns false for nonexistent dir");
};

# --- Stage 2: Parse the config files ---
subtest 'Parser reads multi-file config' => sub {
	my $parser = Genesis::CI::Compiler::Parser->new(
		ci_dir => $ci_dir,
	);
	my $parsed = $parser->parse();
	ok($parsed, 'parse() returned a result');
	is($parsed->{_source_format}, 'multi-file', 'source format is multi-file');

	# Pipeline section
	ok($parsed->{pipeline}, 'pipeline section present');
	is($parsed->{pipeline}{metadata}{name}, 'test-deploy-pipeline', 'pipeline name');
	is($parsed->{pipeline}{metadata}{version}, '2.0', 'pipeline version');
	is($parsed->{pipeline}{branches}{live}, 'main', 'live branch');

	# Workflows
	ok($parsed->{pipeline}{workflows}{deploy}, 'deploy workflow present');
	is($parsed->{pipeline}{workflows}{deploy}{type}, 'deployment', 'workflow type');
	is(scalar @{$parsed->{pipeline}{workflows}{deploy}{stages}}, 3, '3 stages');

	# Targets section
	ok($parsed->{targets}, 'targets section present');
	ok($parsed->{targets}{targets}{sandbox}, 'sandbox target present');
	ok($parsed->{targets}{targets}{preprod}, 'preprod target present');
	ok($parsed->{targets}{targets}{prod}, 'prod target present');
	is($parsed->{targets}{targets}{sandbox}{type}, 'bosh-director', 'sandbox type');
	is($parsed->{targets}{targets}{sandbox}{connection}{url},
		'https://bosh.sandbox.example.com:25555', 'sandbox connection URL');

	# Integrations section
	ok($parsed->{integrations}, 'integrations section present');
	ok($parsed->{integrations}{vault}, 'vault integration present');
	is($parsed->{integrations}{vault}{url}, 'https://vault.example.com:8200', 'vault URL');
	ok($parsed->{integrations}{source_control}, 'source_control present');
	is($parsed->{integrations}{source_control}{uri},
		'git@github.com:myorg/my-deployments.git', 'git URI');
	ok($parsed->{integrations}{notifications}, 'notifications present');
	is(scalar @{$parsed->{integrations}{notifications}}, 1, '1 notification');
	is($parsed->{integrations}{notifications}[0]{type}, 'slack', 'slack notification');
};

# --- Stage 3: Validate the parsed config ---
subtest 'Validator accepts valid multi-file config' => sub {
	my $parser = Genesis::CI::Compiler::Parser->new(ci_dir => $ci_dir);
	my $parsed = $parser->parse();

	my $validator = Genesis::CI::Compiler::Validator->new();
	$validator->validate($parsed);

	ok(!$validator->has_errors, 'no validation errors')
		or diag("Errors: " . join("\n  ", @{$validator->errors}));
	if ($validator->has_warnings) {
		diag("Warnings: " . join("\n  ", @{$validator->warnings}));
	}
};

# --- Stage 4: Build AST ---
subtest 'ASTBuilder produces AST from multi-file config' => sub {
	my $parser = Genesis::CI::Compiler::Parser->new(ci_dir => $ci_dir);
	my $parsed = $parser->parse();

	my $builder = Genesis::CI::Compiler::ASTBuilder->new();
	my $ast = $builder->build($parsed, {});

	isa_ok($ast, 'Genesis::CI::Compiler::AST');

	# Metadata
	is($ast->metadata->{name}, 'test-deploy-pipeline', 'AST metadata name');
	is($ast->metadata->{version}, '2.0', 'AST metadata version');

	# Branches
	is($ast->branches->{live}, 'main', 'AST live branch');

	# Targets
	my @targets = $ast->target_names;
	is(scalar @targets, 3, 'AST has 3 targets');
	ok((grep { $_ eq 'sandbox' } @targets), 'sandbox in targets');
	ok((grep { $_ eq 'prod' } @targets), 'prod in targets');

	# Workflows
	my @wfs = $ast->workflow_names;
	is(scalar @wfs, 1, 'AST has 1 workflow');
	is($wfs[0], 'deploy', 'workflow name is deploy');

	# Workflow graph
	my $wf = $ast->workflows->{deploy};
	ok($wf->{graph}, 'deploy workflow has graph');
	is(scalar keys %{$wf->{graph}{nodes}}, 3, 'graph has 3 nodes');
	is(scalar @{$wf->{graph}{edges}}, 2, 'graph has 2 edges');

	# Integrations
	ok($ast->integrations->{vault}, 'AST has vault integration');
	ok($ast->integrations->{source_control}, 'AST has source_control');
	ok($ast->integrations->{notifications}, 'AST has notifications');
};

# --- Stage 5: PipelineDescriptor resolves the generic pipeline ---
subtest 'PipelineDescriptor resolves generic pipeline' => sub {
	my $parser = Genesis::CI::Compiler::Parser->new(ci_dir => $ci_dir);
	my $parsed = $parser->parse();
	my $builder = Genesis::CI::Compiler::ASTBuilder->new();
	my $ast = $builder->build($parsed, {});

	my $descriptor = Genesis::CI::Compiler::PipelineDescriptor->new(
		ast => $ast,
	);
	my $pipeline = $descriptor->describe();
	ok($pipeline, 'describe() returned a result');

	# Resource types
	ok($pipeline->{resource_types}, 'resource_types present');
	ok(scalar @{$pipeline->{resource_types}} > 0, 'has resource types');
	my @rt_names = map { $_->{name} } @{$pipeline->{resource_types}};
	diag("Resource types: " . join(', ', @rt_names));

	# Resources
	ok($pipeline->{resources}, 'resources present');
	ok(scalar @{$pipeline->{resources}} > 0, 'has resources');
	my @res_names = map { $_->{name} } @{$pipeline->{resources}};
	diag("Resources (" . scalar(@res_names) . "): " . join(', ', @res_names));

	# Jobs
	ok($pipeline->{jobs}, 'jobs present');
	ok(scalar @{$pipeline->{jobs}} > 0, 'has jobs');
	my @job_names = map { $_->{name} } @{$pipeline->{jobs}};
	diag("Jobs (" . scalar(@job_names) . "): " . join(', ', @job_names));

	# Groups
	ok($pipeline->{groups}, 'groups present');
	ok(scalar @{$pipeline->{groups}} > 0, 'has groups');
	my @grp_names = map { $_->{name} } @{$pipeline->{groups}};
	diag("Groups: " . join(', ', @grp_names));

	# Graphviz
	ok($pipeline->{graphviz}, 'graphviz present');
	like($pipeline->{graphviz}, qr/digraph/, 'graphviz contains digraph');

	# Description
	ok($pipeline->{description}, 'description present');
	like($pipeline->{description}, qr/Pipeline/, 'description mentions Pipeline');
};

# --- Stage 6: Generate Concourse YAML from AST ---
subtest 'Concourse provider generates YAML' => sub {
	my $parser = Genesis::CI::Compiler::Parser->new(ci_dir => $ci_dir);
	my $parsed = $parser->parse();
	my $builder = Genesis::CI::Compiler::ASTBuilder->new();
	my $ast = $builder->build($parsed, {});

	# Resolve pipeline first
	my $descriptor = Genesis::CI::Compiler::PipelineDescriptor->new(ast => $ast);
	$ast->set_pipeline($descriptor->describe());

	# Load Concourse provider
	require Genesis::CI::Compiler::Providers::Concourse;
	my $provider = Genesis::CI::Concourse->new(ast => $ast);

	my $yaml = $provider->generate_from_ast($ast);
	ok($yaml, 'generate_from_ast returned output');
	ok(length($yaml) > 100, 'output is non-trivial (' . length($yaml) . ' chars)');
	like($yaml, qr/^---/, 'output starts with YAML document marker');

	# Check for expected Concourse pipeline structure
	like($yaml, qr/groups:/, 'output has groups');
	like($yaml, qr/resources:/, 'output has resources');
	like($yaml, qr/jobs:/, 'output has jobs');

	# Print the full output for inspection
	diag("\n=== Generated Concourse Pipeline YAML ===\n$yaml\n=== END ===\n");
};

done_testing;
