package Genesis::Commands::Pipelines;

use strict;
use warnings;

use Genesis;
use Genesis::State;
use Genesis::Commands;
use Genesis::Top;
use Genesis::Env;
use Genesis::CI::Legacy qw//;
use Genesis::CI::Compiler;
use Service::Vault::Remote;

use File::Basename qw/dirname/;
use File::Path qw/rmtree/;
use JSON::PP;

### Public Commands {{{

# embed - embed Genesis binary in the repository {{{
sub embed {
	command_usage(1) if @_;
	Genesis::Top->new('.')->embed($ENV{GENESIS_CALLBACK_BIN} || $0);
}

# }}}
# apply - compile and deploy pipeline (replaces genesis repipe) {{{
sub apply {
	my ($layout) = @_;
	option_defaults(config => 'ci.yml');

	my $opts     = get_options;
	my $platform = $opts->{platform} || 'concourse';

	bail("--output-dir requires --platform")
		if $opts->{'output-dir'} && !$opts->{platform};
	bail("--debug-dir requires --platform")
		if $opts->{'debug-dir'} && !$opts->{platform};

	my $top    = _get_top($opts);
	my $result = _compile_pipeline($top, $platform);

	_dump_debug_artifacts($opts->{'debug-dir'}, $result, $platform)
		if $opts->{'debug-dir'};

	my $ast    = $result->{ast};
	my $output = $result->{output};
	my $name   = $ast->metadata->{name}
		or bail("Pipeline AST has no name defined");

	if (my $out_dir = $opts->{'output-dir'}) {
		mkdir_or_fail($out_dir);
		for my $file (sort keys %$output) {
			mkfile_or_fail("$out_dir/$file", $output->{$file});
			info("Wrote #C{%s/%s}", $out_dir, $file);
		}
		mkfile_or_fail("$out_dir/ast.json",
			JSON::PP->new->pretty->canonical->encode({%$ast}));
		info("Wrote #C{%s/ast.json}", $out_dir);
		exit 0;
	}

	if ($platform eq 'concourse') {
		my $provider = $result->{provider};

		if ($opts->{'dry-run'}) {
			my $yaml = $output->{'pipeline.yml'}
				or bail("Concourse provider did not produce pipeline.yml");
			output({raw => 1}, $yaml);
			exit 0;
		}

		$provider->check_prereqs() or exit 86;

		my %deploy_opts = %{ $provider->normalize_provider_opts(
			$result->{provider_cli_opts} || {}
		) };
		$deploy_opts{target}          //= $opts->{target} // $layout // $name;
		$deploy_opts{pause_after_set} //= $opts->{paused};
		$provider->deploy(%deploy_opts, yes => $opts->{yes});

	} elsif ($platform eq 'github-actions') {
		if ($opts->{'dry-run'}) {
			for my $file (sort keys %$output) {
				output "#G{--- %s ---}", $file;
				output({raw => 1}, $output->{$file});
			}
			exit 0;
		}
		for my $file (sort keys %$output) {
			my $path = ".github/workflows/$file";
			mkdir_or_fail(dirname($path));
			mkfile_or_fail($path, $output->{$file});
			info("Wrote #C{%s}", $path);
		}
		info("GitHub Actions workflows written. Commit and push to activate.");

	} else {
		bail("Unsupported platform '%s' for pipeline apply", $platform);
	}

	exit 0;
}

# }}}
# pipeline_graph - write pipeline.md with Mermaid flowchart {{{
sub pipeline_graph {
	my ($layout) = @_;
	option_defaults(config => 'ci.yml');

	my $opts     = get_options;
	my $platform = $opts->{platform} || 'concourse';
	my $top      = Genesis::Top->new('.');
	my $result   = _compile_pipeline($top, $platform);
	my $ast      = $result->{ast};
	my $provider = $result->{provider};

	my $md = $provider->can('graph_md')
		? $provider->graph_md()
		: _ast_to_mermaid_md($ast);

	mkfile_or_fail('pipeline.md', $md);
	info("Wrote #C{pipeline.md}");
	exit 0;
}

# }}}
# pipeline_describe - human-readable pipeline progression {{{
sub pipeline_describe {
	my ($layout) = @_;
	option_defaults(config => 'ci.yml');

	my $opts     = get_options;
	my $platform = $opts->{platform} || 'concourse';
	my $top      = Genesis::Top->new('.');
	my $result   = _compile_pipeline($top, $platform);
	my $ast      = $result->{ast};
	my $provider = $result->{provider};

	if ($provider->can('generate_description')) {
		$provider->generate_description($ast);
	} else {
		_describe_ast($ast, $platform);
	}
	exit 0;
}

# }}}
# diff - show compiled vs live pipeline delta {{{
sub diff {
	option_defaults(config => 'ci.yml');

	my $opts     = get_options;
	my $platform = $opts->{platform} || 'concourse';

	bail("diff is only supported for the 'concourse' platform")
		unless $platform eq 'concourse';

	my $top    = _get_top($opts, skip_vault => 1);
	my $result = _compile_pipeline($top, $platform);
	my $ast    = $result->{ast};
	my $output = $result->{output};

	my $name   = $ast->metadata->{name}
		or bail("Pipeline AST has no name defined");
	my ($target, $k_flag) = _concourse_fly_flags($result, $opts, $name);

	my $compiled = $output->{'pipeline.yml'}
		or bail("Concourse provider did not produce pipeline.yml");

	my $dir = workdir;
	mkfile_or_fail("$dir/compiled.yml", $compiled);

	my ($live, $rc) = run("fly${k_flag} -t \$1 get-pipeline -p \$2", $target, $name);
	if ($rc != 0) {
		info("#Y{Pipeline '%s' does not exist on target '%s' — nothing to diff against.}",
			$name, $target);
		info("Run #C{genesis pipeline-apply} to deploy it first.");
		exit 0;
	}
	mkfile_or_fail("$dir/live.yml", $live);

	my ($diff_out, $diff_rc) = run(
		'diff -u --label live --label compiled $1 $2',
		"$dir/live.yml", "$dir/compiled.yml"
	);

	if ($diff_rc == 0) {
		info("#G{No differences} — compiled pipeline matches live pipeline.");
	} else {
		output({raw => 1}, $diff_out);
	}
	exit 0;
}

# }}}
# status - show per-env job health {{{
sub status {
	my ($filter_env) = @_;
	option_defaults(config => 'ci.yml');

	my $opts     = get_options;
	my $platform = $opts->{platform} || 'concourse';

	bail("status is only supported for the 'concourse' platform")
		unless $platform eq 'concourse';

	my $top    = _get_top($opts, skip_vault => 1);
	my $result = _compile_pipeline($top, $platform);
	my $ast    = $result->{ast};
	my $name   = $ast->metadata->{name}
		or bail("Pipeline AST has no name defined");
	my ($target, $k_flag) = _concourse_fly_flags($result, $opts, $name);

	my ($json_out, $rc) = run("fly${k_flag} -t \$1 jobs -p \$2 --json", $target, $name);
	bail("Could not get jobs for pipeline '%s' on target '%s': %s", $name, $target, $json_out)
		unless $rc == 0;

	my $jobs;
	eval { $jobs = JSON::PP->new->decode($json_out) };
	bail("Failed to parse fly jobs output: %s", $@) if $@;

	output "#G{Pipeline}: #C{%s}  (#Yi{target}: %s)", $name, $target;
	output "";

	my %job_by_name = map { $_->{name} => $_ } @$jobs;

	my @ordered_names;
	for my $wf_name ($ast->workflow_names) {
		my @stage_order = eval { $ast->workflow_stage_order($wf_name) };
		if (@stage_order) {
			my $nodes = ($ast->workflows->{$wf_name} || {})->{graph}{nodes} || {};
			push @ordered_names, map { $nodes->{$_}{alias} || $_ } @stage_order;
		}
	}
	my %seen = map { $_ => 1 } @ordered_names;
	push @ordered_names, sort grep { !$seen{$_} } keys %job_by_name;

	my $col_w = 40;
	output "  %-${col_w}s  %-10s  %s", "Environment", "Status", "Notes";
	output "  %s  %s  %s", '-' x $col_w, '-' x 10, '-' x 20;

	for my $job_name (@ordered_names) {
		next if $filter_env && $job_name ne $filter_env;
		my $job = $job_by_name{$job_name} or next;

		my $status = _job_status_label($job);
		my @notes;
		push @notes, 'paused'  if $job->{paused};
		push @notes, 'errored' if ($job->{finished_build} || {})->{status} eq 'errored';

		output "  %-${col_w}s  %-10s  %s",
			$job_name,
			$status,
			join(', ', @notes) || '';
	}
	output "";
	exit 0;
}

# }}}
# pause - pause env job or entire pipeline {{{
sub pause {
	my ($env) = @_;
	option_defaults(config => 'ci.yml');

	my $opts     = get_options;
	my $platform = $opts->{platform} || 'concourse';

	bail("pause is only supported for the 'concourse' platform")
		unless $platform eq 'concourse';

	my $top    = _get_top($opts, skip_vault => 1);
	my $result = _compile_pipeline($top, $platform);
	my $ast    = $result->{ast};
	my $name   = $ast->metadata->{name}
		or bail("Pipeline AST has no name defined");
	my ($target, $k_flag) = _concourse_fly_flags($result, $opts, $name);

	if ($env) {
		run({ interactive => 1,
		      onfailure => "Could not pause job '$env' in pipeline '$name'" },
			"fly${k_flag} -t \$1 pause-job -p \$2 -j \$3",
			$target, $name, $env);
		info("Paused job #C{%s} in pipeline #C{%s}", $env, $name);
	} else {
		run({ interactive => 1,
		      onfailure => "Could not pause pipeline '$name'" },
			"fly${k_flag} -t \$1 pause-pipeline -p \$2",
			$target, $name);
		info("Paused pipeline #C{%s}", $name);
	}
	exit 0;
}

# }}}
# resume - resume env job or entire pipeline {{{
sub resume {
	my ($env) = @_;
	option_defaults(config => 'ci.yml');

	my $opts     = get_options;
	my $platform = $opts->{platform} || 'concourse';

	bail("resume is only supported for the 'concourse' platform")
		unless $platform eq 'concourse';

	my $top    = _get_top($opts, skip_vault => 1);
	my $result = _compile_pipeline($top, $platform);
	my $ast    = $result->{ast};
	my $name   = $ast->metadata->{name}
		or bail("Pipeline AST has no name defined");
	my ($target, $k_flag) = _concourse_fly_flags($result, $opts, $name);

	if ($env) {
		run({ interactive => 1,
		      onfailure => "Could not resume job '$env' in pipeline '$name'" },
			"fly${k_flag} -t \$1 unpause-job -p \$2 -j \$3",
			$target, $name, $env);
		info("Resumed job #C{%s} in pipeline #C{%s}", $env, $name);
	} else {
		run({ interactive => 1,
		      onfailure => "Could not resume pipeline '$name'" },
			"fly${k_flag} -t \$1 unpause-pipeline -p \$2",
			$target, $name);
		info("Resumed pipeline #C{%s}", $name);
	}
	exit 0;
}

# }}}
# }}}
### Deprecated Commands {{{

# repipe - deprecated; delegates to apply {{{
sub repipe {
	warning("'genesis repipe' is deprecated and will be removed in a future version.  Use 'genesis pipeline-apply' instead.");
	apply(@_);
}

# }}}
# graph - deprecated; legacy graphviz without --platform, modern pipeline.md with {{{
sub graph {
	warning("'genesis graph' is deprecated and will be removed in a future version.  Use 'genesis pipeline-graph' instead.");
	option_defaults(config => 'ci.yml');
	my $layout = $_[0];
	my $top    = Genesis::Top->new('.');

	if (get_options->{platform}) {
		return pipeline_graph($layout);
	}

	(my $pipeline, $layout) = Genesis::CI::Legacy::parse(get_options->{config}, $top, $layout);
	my $dot = Genesis::CI::Legacy::generate_pipeline_graphviz_source($pipeline);
	output "$dot";
	exit 0;
}

# }}}
# describe - deprecated; delegates to pipeline_describe {{{
sub describe {
	warning("'genesis describe' is deprecated and will be removed in a future version.  Use 'genesis pipeline-describe' instead.");
	pipeline_describe(@_);
}

# }}}
# }}}
### CI Task Commands {{{

sub ci_pipeline_deploy {
	command_usage(1) if @_;

	info("[#G{genesis} ci-pipeline-deploy] v#G{$Genesis::VERSION}\n");

	my @undefined = grep { !$ENV{$_} }
		qw/CURRENT_ENV GIT_BRANCH OUT_DIR WORKING_DIR VAULT_ROLE_ID VAULT_SECRET_ID VAULT_ADDR/;
	push @undefined, "CACHE_DIR" if ($ENV{PREVIOUS_ENV} && ! $ENV{CACHE_DIR});
	_bail_on_missing_pipeline_environment_variables(@undefined);

	bail(
		"The pipeline must specify either GIT_PRIVATE_KEY, or GIT_USERNAME and ".
		"GIT_PASSWORD"
	) unless $ENV{GIT_PRIVATE_KEY} || ($ENV{GIT_USERNAME} && $ENV{GIT_PASSWORD});

	_vault_auth();

	_propagate_previous_passed_files();

	my $workdir = $ENV{WORKING_DIR};
	$workdir .= "/$ENV{GIT_GENESIS_ROOT}" if (defined($ENV{GIT_GENESIS_ROOT}) && $ENV{GIT_GENESIS_ROOT} ne "");
	pushd $workdir;
	my $env = Genesis::Top->new('.')->load_env($ENV{CURRENT_ENV})->with_vault();

	if ($env->use_create_env) {
		my $tmp     = workdir;
		my $git_env = _get_git_env($tmp);
		run({ onfailure   => "Could not reset to the latest state file from origin. State file may not exist, which occurs if the proto bosh has not been deployed once manually.",
			interactive => 1,
			env => $git_env },
			'git checkout "origin/${1}" ".genesis/manifests/${2}-state.yml"',
			$ENV{GIT_BRANCH}, $ENV{CURRENT_ENV});
	}

	_bail_on_missing_pipeline_environment_variables(@undefined);

	info "Preparing to deploy #C{%s}:\n  - based on kit #c{%s}", $env->name, $env->kit->id;
	if ($env->use_create_env) {
		info("  - as a #M{create-env} deployment\n");
	} else {
		my $bosh = $env->bosh();
		info("  - to #M{%s} BOSH director at #Bu{%s}.\n", $bosh->alias, $bosh->url);
	}

	my $result;
	my %deploy_opts = (
		redact               => !envset('CI_NO_REDACT'),
		'disable-reactions'  => 0,
		'yes'                => 1,
	);
	$ENV{BOSH_NON_INTERACTIVE} = 'true';
	eval {
		$result = $env->with_bosh
		              ->download_required_configs('deploy')
		              ->deploy(%deploy_opts);
	};

	if ($@ || !$result) {
		error "#R{Deployment failed!}\n%s", $@ || "";
		if ($env->use_create_env) {
			popd;
			_commit_changes(
				$ENV{WORKING_DIR}, $ENV{OUT_DIR}, $ENV{GIT_BRANCH},
				"pushing state file for $ENV{CURRENT_ENV} after failed deploy",
				qr{^.genesis/manifest/.*\.state$}
			);
		}
		exit 1;
	}

	if ($ENV{PREVIOUS_ENV}) {
		system("rm -rf .genesis/config .genesis/kits .genesis/cached") == 0 or exit 1;
		system("git checkout .genesis/config");
		system("git checkout .genesis/kits");
		system("git checkout .genesis/cached");
	}
	popd;
	_commit_changes($ENV{WORKING_DIR}, $ENV{OUT_DIR}, $ENV{GIT_BRANCH},
		"deployed to $ENV{CURRENT_ENV}");
}

sub ci_show_changes {
	info("[#G{genesis} ci-show-changes] v#G{$Genesis::VERSION}\n");

	command_usage(1) if @_;

	my @undefined = grep { !$ENV{$_} }
		qw/CURRENT_ENV GIT_BRANCH WORKING_DIR OUT_DIR VAULT_ROLE_ID VAULT_SECRET_ID VAULT_ADDR/;
	push @undefined, "CACHE_DIR" if ($ENV{PREVIOUS_ENV} && ! $ENV{CACHE_DIR});
	_bail_on_missing_pipeline_environment_variables(@undefined);

	bail(
		"The pipeline must specify either GIT_PRIVATE_KEY, or GIT_USERNAME and ".
		"GIT_PASSWORD"
	) unless $ENV{GIT_PRIVATE_KEY} || ($ENV{GIT_USERNAME} && $ENV{GIT_PASSWORD});

	_vault_auth();

	my $mismatches = _propagate_previous_passed_files();

	my $workdir = $ENV{WORKING_DIR};
	$workdir .= "/$ENV{GIT_GENESIS_ROOT}" if (defined($ENV{GIT_GENESIS_ROOT}) && $ENV{GIT_GENESIS_ROOT} ne "");
	pushd $workdir;
	my $env = Genesis::Top->new('.')->load_env($ENV{CURRENT_ENV})->with_vault();
	if ($env->use_create_env) {
		info(
			"Proto-BOSH environments do not contain a record of how they were last ".
			"deployed, so no changes can be calculated and displayed."
		);
		exit 0;
	}

	_bail_on_missing_pipeline_environment_variables(@undefined);

	my $manifest_provider = $env->with_bosh
		->download_required_configs('blueprint', 'manifest')
		->manifest_provider;

	mkfile_or_fail "updates.yml", 0644, slurp(
		$manifest_provider
		->deployment(notify=>0,subset=>'pruned')
		->file =~ s/^\s*\z//mgr
	);

	mkfile_or_fail "bosh-vars.yml", 0644, slurp(
		$manifest_provider
		->deployment(notify=>0,subset=>'bosh_vars')
		->file =~ s/^\s*\z//mgr
	);

	my $cmd = './dry-run';
	mkfile_or_fail $cmd, 0755, <<'EOF';
#!/bin/bash
set -e
deployment="${1}-${2}"
new_manifest="$(cat ${3})"
vars_file="$4"
new_configs="$(bosh curl /configs \
						 | jq -r 'map(select(.type != "cpi") | .content) | join("\n---\n")' \
						 | spruce merge --multi-doc -)"
new_variables="$(echo "credhub_variables:" \
							 ; bosh curl "/deployments/${deployment}/variables" \
							 | jq -r 'map(.name)[]' \
							 | xargs -L1 sh -c 'credhub get --output-json -n "${1}"' sh \
							 | jq -r '"- \(.name)@\(.id)"')"

current_manifest="$(bosh -d ${deployment} manifest)"
current_configs="$(bosh curl /deployment_configs\?deployment=${deployment} \
								 | jq 'map(.config.id)[]' \
								 | xargs -L1 sh -c 'bosh curl "/configs/${1}"' sh \
								 | jq -r '.content' \
								 | spruce merge --multi-doc -)"
current_variables="$(bosh int <(bosh curl "/deployments/${deployment}/variables" \
									 | jq 'map("\(.name)@\(.id)") | {credhub_variables: .}'))"

bosh diff-config --json \
		 --from-content <(bosh int <(spruce merge --fallback-append <(echo "${current_configs}") <(echo "${current_manifest}") <(echo "${current_variables}"))) \
		 --to-content <(bosh int <(spruce merge --fallback-append <(echo "${new_configs}") <(echo "${new_manifest}") <(echo "${new_variables}")) -l ${vars_file}) \
		 | jq -r '.Tables[0].Rows[0] | if (.diff == "" ) then "[32;1mNo differences found.[0m" else .diff end'
EOF

	my %envvars = $env->get_environment_variables();

	if (envset('GENESIS_TRACE')) {
		run( {interactive => 0}, "sed -e 's/set -e/set -ex/' $cmd > ${cmd}-trace");
		$cmd.='-trace';
	}
	my (undef,$rc) = run( {interactive => 1, env => \%envvars}, $cmd, $env->name, $env->type, 'updates.yml', 'bosh-vars.yml');
	bail "Failed to determine changes." if $rc;

	my @missing = @{$mismatches->{missing} || []};
	my @extra   = @{$mismatches->{extra}   || []};
	if (@extra) {
		my @files_to_check = grep { $_ !~ /^remove\// } $env->relate($ENV{PREVIOUS_ENV}, 'remove');
		my $differences = 0;
		for (@files_to_check) {
			next if ! -f "$ENV{CACHE_DIR}/$_" && ! -f "$ENV{WORKING_DIR}/$_";
			if (! -f "$ENV{CACHE_DIR}/$_" || ! -f "$ENV{WORKING_DIR}/$_") {
				$differences += 1; last;
			}
			my $cache_file = slurp("$ENV{CACHE_DIR}/$_");
			my $work_file  = slurp("$ENV{WORKING_DIR}/$_");
			unless ($cache_file eq $work_file) { $differences += 1; last; }
		}
		@extra = () unless $differences;
	}

	if (@missing || @extra) {
		my $msg =
			"#Ru{POTENTIAL ISSUE:}\n".
			"The $ENV{CURRENT_ENV} environment expected the $ENV{PREVIOUS_ENV} environment\n".
			"to provide cached versions of files to update its own copies, but they were\n".
			"not found, or found versions that were not expected.\n\n".
			"There are multiple reasons this may happen, some of which are expected and\n".
			"some may lead to unstable deployments.  If you have recently extracted some\n".
			"values into hierarchal files, please wait until the change propagates from\n".
			"all pending upstream deployments are finished.";

		$msg .= "\n\n".
			"Files missing from cache, but present in changes (will be ignored):\n  - ".
			join("\n  - ",@missing) if @missing;

		$msg .= "\n\n".
			"Files not present in changes, but found in cache (will be applied):\n  - ".
			join("\n  - ",@extra) if @extra;

		bail($msg);
	}
	popd;
}

sub ci_generate_cache {
	info("[#G{genesis} ci-generate-cache] v#G{$Genesis::VERSION}\n");

	command_usage(1) if @_;

	my @undefined = grep { !$ENV{$_} }
		qw/CURRENT_ENV GIT_BRANCH WORKING_DIR OUT_DIR/;
	push(@undefined, 'CACHE_DIR') if $ENV{PREVIOUS_ENV} && ! $ENV{CACHE_DIR};
	_bail_on_missing_pipeline_environment_variables(@undefined);
	bail("The pipeline must specify either GIT_PRIVATE_KEY, or GIT_USERNAME and GIT_PASSWORD")
		unless $ENV{GIT_PRIVATE_KEY} || ($ENV{GIT_USERNAME} && $ENV{GIT_PASSWORD});

	my $workdir  = $ENV{WORKING_DIR};
	my $cachedir = $ENV{CACHE_DIR};
	if (defined($ENV{GIT_GENESIS_ROOT}) && $ENV{GIT_GENESIS_ROOT} ne "") {
		$workdir  .= "/$ENV{GIT_GENESIS_ROOT}";
		$cachedir .= "/$ENV{GIT_GENESIS_ROOT}";
	}
	my $target_dir = "$workdir/.genesis/cached/$ENV{CURRENT_ENV}";
	my $bad_dir    = "$workdir/.genesis/cached/cached";
	rmtree($_) for (grep {-e $_} ($target_dir,$bad_dir));

	mkdir_or_fail($target_dir);
	my $common_path = $ENV{PREVIOUS_ENV} ?
		"$cachedir/.genesis/cached/$ENV{PREVIOUS_ENV}" :
		$workdir;

	chomp(my $d=`pwd`);
	my @cachables = grep {
		debug "[ci-generate-cache] Testing cache candidate %s/%s: %s", $d,$_, -f $_ ? "#g{present}" : "#y{absent}";
		-f $_;
	} Genesis::Env::relate_by_name(
		$ENV{CURRENT_ENV}, $ENV{PREVIOUS_ENV} || '', $common_path, $workdir
	);

	push(@cachables, "$common_path/kit-overrides.yml") if -f "$common_path/kit-overrides.yml";
	copy_or_fail($_, "$target_dir/") for (@cachables);
	copy_tree_or_fail("$common_path/ops", "$target_dir", "$common_path/") if -d "$common_path/ops";
	copy_tree_or_fail("$common_path/bin", "$target_dir", "$common_path/") if -d "$common_path/bin";
	return if envset("GENESIS_TESTING");
	_commit_changes($ENV{WORKING_DIR}, $ENV{OUT_DIR}, $ENV{GIT_BRANCH}, "generated cache for $ENV{CURRENT_ENV}");
}

sub ci_pipeline_run_errand {
	info("[#G{genesis} ci-pipeline-run-errand] v#G{$Genesis::VERSION}\n");

	command_usage(1) if @_;

	my @undefined = grep { !$ENV{$_} }
		qw/CURRENT_ENV ERRAND_NAME VAULT_ROLE_ID VAULT_SECRET_ID VAULT_ADDR/;
	_bail_on_missing_pipeline_environment_variables(@undefined);

	_vault_auth();

	my $env = Genesis::Top->new('.')->load_env($ENV{CURRENT_ENV})->with_vault()->with_bosh();
	$env->bosh->run_errand($ENV{ERRAND_NAME});
	exit 0;
}

# }}}
# }}}
### Internal Compiler Helpers {{{

# _compile_pipeline - detect config source and compile; returns result hash {{{
sub _compile_pipeline {
	my ($top, $platform) = @_;

	my %compiler_opts = (top => $top);

	# Priority order:
	#   1. .genesis/ci/pipeline.yml or targets.yml  (multi-file)
	#   2. ci: section in .genesis/config           (genesis-config)
	#   3. Legacy ci.yml / --config file            (backward compat)
	my $ci_dir = $top->path('.genesis/ci');
	if (-d $ci_dir && (-f "$ci_dir/pipeline.yml" || -f "$ci_dir/targets.yml")) {
		$compiler_opts{ci_dir} = $ci_dir;
		info("Using multi-file CI configuration from #C{.genesis/ci/}");
	} elsif (Genesis::CI::Compiler->can_compile_from_genesis_config($top)) {
		info("Using inline CI configuration from #C{.genesis/config}");
	} else {
		$compiler_opts{file} = get_options->{config} || $top->path('ci.yml');
		info("Using legacy CI configuration from #C{%s}", $compiler_opts{file});
	}

	# Parse provider-specific CLI flags
	my %provider_cli_opts;
	{
		require Genesis::CI::Compiler::PipelineProvider;
		my @argv = ();
		Genesis::CI::Compiler::PipelineProvider->parse_cli_opts(
			\@argv, \%provider_cli_opts, $platform
		);
		for my $key (Genesis::CI::Compiler::PipelineProvider->cli_opt_keys($platform)) {
			$provider_cli_opts{$key} = get_options->{$key}
				if defined get_options->{$key};
		}
	}

	my $compiler = Genesis::CI::Compiler->new(%compiler_opts);
	my $result   = $compiler->compile(
		provider      => $platform,
		provider_opts => \%provider_cli_opts,
	);

	if (my $debug_dir = get_options->{'debug-dir'}) {
		_dump_debug_artifacts($debug_dir, $result, $platform);
	}

	$result->{provider_cli_opts} = \%provider_cli_opts;
	return $result;
}

# }}}
# _get_top - create Genesis::Top, optionally skipping vault {{{
sub _get_top {
	my ($opts, %defaults) = @_;

	my $skip = $opts->{'skip-vault'} || $defaults{skip_vault};
	if ($skip) {
		return Genesis::Top->new('.');
	}

	my $top = Genesis::Top->new('.', vault => $opts->{vault});
	bail(
		"No vault specified or configured.\n".
		"Use --skip-vault to compile without vault access."
	) unless $top->vault;
	return $top;
}

# }}}
# _dump_debug_artifacts - write compiler intermediates to a directory {{{
sub _dump_debug_artifacts {
	my ($debug_dir, $result, $platform) = @_;

	mkdir_or_fail($debug_dir);

	my $json = JSON::PP->new->pretty->canonical;

	if ($result->{parsed}) {
		mkfile_or_fail("$debug_dir/01-parsed.json",
			$json->encode($result->{parsed}));
		info("Debug: wrote #C{%s/01-parsed.json}", $debug_dir);
	}

	if (my $ast = $result->{ast}) {
		my %source;
		for my $key (qw(branches integrations targets workflows configuration
		                provider_config triggers resources)) {
			my $accessor = $ast->can($key);
			$source{$key} = $accessor->($ast) if $accessor;
		}
		$source{metadata} = $ast->metadata;
		$source{scripts}  = $ast->scripts;

		mkfile_or_fail("$debug_dir/02-ast-source.json",
			$json->encode(\%source));
		info("Debug: wrote #C{%s/02-ast-source.json}", $debug_dir);

		if ($ast->pipeline && %{$ast->pipeline}) {
			my %pipeline    = %{$ast->pipeline};
			my $mermaid     = delete $pipeline{mermaid};
			my $pipeline_md = delete $pipeline{pipeline_md};
			my $description = delete $pipeline{description};

			mkfile_or_fail("$debug_dir/03-pipeline.json",
				$json->encode(\%pipeline));
			info("Debug: wrote #C{%s/03-pipeline.json}", $debug_dir);

			if ($pipeline_md) {
				mkfile_or_fail("$debug_dir/04-pipeline.md", $pipeline_md);
				info("Debug: wrote #C{%s/04-pipeline.md}", $debug_dir);
			}

			if ($description) {
				mkfile_or_fail("$debug_dir/05-description.txt", $description);
				info("Debug: wrote #C{%s/05-description.txt}", $debug_dir);
			}
		}
	}

	if ($result->{output}) {
		if (ref($result->{output}) eq 'HASH') {
			for my $file (sort keys %{$result->{output}}) {
				mkfile_or_fail("$debug_dir/06-output-$file",
					$result->{output}{$file});
				info("Debug: wrote #C{%s/06-output-%s}", $debug_dir, $file);
			}
		} else {
			mkfile_or_fail("$debug_dir/06-output.yml", $result->{output});
			info("Debug: wrote #C{%s/06-output.yml}", $debug_dir);
		}
	}

	info("Debug artifacts written to #C{%s/}", $debug_dir);
}

# }}}
# _ast_to_mermaid_md - generate pipeline.md Mermaid content from a bare AST {{{
sub _ast_to_mermaid_md {
	my ($ast) = @_;

	my $name  = $ast->metadata->{name} || 'genesis-pipeline';
	my @lines = ("flowchart LR");

	for my $wf_name ($ast->workflow_names) {
		my $wf = $ast->workflows->{$wf_name};
		next unless $wf->{graph};

		my $nodes = $wf->{graph}{nodes} || {};
		my $edges = $wf->{graph}{edges} || [];

		my %in_any_edge;
		for my $edge (@$edges) {
			$in_any_edge{$edge->{from}} = 1;
			$in_any_edge{$edge->{to}}   = 1;
		}

		for my $edge (@$edges) {
			my $from = $nodes->{$edge->{from}}{alias} || $edge->{from};
			my $to   = $nodes->{$edge->{to}}{alias}   || $edge->{to};
			($from) =~ s/[^a-zA-Z0-9_]/_/g;
			($to)   =~ s/[^a-zA-Z0-9_]/_/g;
			push @lines, "  $from --> $to";
		}

		for my $n (sort keys %$nodes) {
			next if $in_any_edge{$n};
			my $alias = $nodes->{$n}{alias} || $n;
			($alias) =~ s/[^a-zA-Z0-9_]/_/g;
			push @lines, "  $alias";
		}
	}

	my $mermaid = join("\n", @lines) . "\n";
	return "# Pipeline: $name\n\n\`\`\`mermaid\n${mermaid}\`\`\`\n";
}

# }}}
# _describe_ast - human-readable AST description {{{
sub _describe_ast {
	my ($ast, $platform) = @_;

	output "#G{Pipeline}: #C{%s}", $ast->metadata->{name} || '(unnamed)';
	output "  #Yi{Platform}: %s", $platform;
	output "  #Yi{Source}:   %s", $ast->metadata->{source} || 'unknown';
	output "";

	my $integrations = $ast->integrations || {};
	if (my $sc = $integrations->{source_control}) {
		output "#G{Source Control}:";
		output "  Provider:   %s", $sc->{provider}   || 'unknown';
		output "  Repository: %s", $sc->{repository} || 'unknown';
	}

	my @targets = $ast->target_names;
	if (@targets) {
		output "";
		output "#G{Targets}: (%d)", scalar @targets;
		output "  - #C{%s}", $_ for sort @targets;
	}

	my @workflows = $ast->workflow_names;
	if (@workflows) {
		output "";
		output "#G{Workflows}: (%d)", scalar @workflows;
		for my $wf_name (sort @workflows) {
			my $wf = $ast->workflows->{$wf_name};
			output "  #Yi{%s} (%s)", $wf_name, $wf->{type} || 'deployment';

			if ($wf->{graph} && $wf->{graph}{nodes}) {
				my $nodes = $wf->{graph}{nodes};
				my $edges = $wf->{graph}{edges} || [];
				output "    Stages: %s", join(' -> ',
					map { $_->{alias} || $_->{genesis_env} || $_->{stage_name} }
					map { $nodes->{$_} }
					sort keys %$nodes
				);
				output "    Edges:  %d", scalar @$edges;
			}
		}
	}

	output "";
}

# }}}
# _concourse_fly_flags - derive (target, k_flag) from compiled result + CLI opts {{{
#
# Target resolution: explicit --target CLI opt > ci.provider.target config > pipeline name.
# k_flag is ' -k' when insecure is set, '' otherwise.
sub _concourse_fly_flags {
	my ($result, $opts, $name) = @_;
	my $provider = $result->{provider};
	my $target   = $opts->{target}
		// ($provider->can('provider_option') ? $provider->provider_option('target') : undef)
		// $name;
	my $insecure = $provider->can('provider_option')
		? ($provider->provider_option('insecure') // 0) : 0;
	my $k_flag   = $insecure ? ' -k' : '';
	return ($target, $k_flag);
}

# }}}
# _job_status_label - derive a display status from a fly jobs JSON entry {{{
sub _job_status_label {
	my ($job) = @_;
	return 'paused' if $job->{paused};
	my $fb = $job->{finished_build} || {};
	return $fb->{status} || 'pending';
}

# }}}
# }}}
### CI Task Helpers {{{

# _vault_auth - authenticate to vault using AppRole credentials from env {{{
sub _vault_auth {
	my @missing_variables = grep {
		!exists($ENV{$_}) || !defined($ENV{$_})
	} qw/VAULT_ADDR VAULT_ROLE_ID VAULT_SECRET_ID/;
	bail(
		"Pipeline requires the following missing environment variables: %s",
		join(", ", @missing_variables)
	) if @missing_variables;

	Service::Vault::Remote->create(
		$ENV{VAULT_ADDR},
		'deployments-vault',
		skip_verify  => envset("VAULT_SKIP_VERIFY"),
		namespace    => $ENV{VAULT_NAMESPACE},
		no_strongbox => envset("VAULT_NO_STRONGBOX"),
		mount        => $ENV{VAULT_SECRETS_MOUNT}
	)->connect_and_validate();
}

# }}}
# _bail_on_missing_pipeline_environment_variables - consistent error for missing CI env vars {{{
sub _bail_on_missing_pipeline_environment_variables {
	if (@_) {
		error("The following #R{required} environment variables have not been defined:");
		error(" - \$#Y{$_}") for @_;
		error("\n");
		error("Please check your CI Pipeline configuration.");
		exit 1;
	}
}

# }}}
# _propagate_previous_passed_files - copy cached files from previous pipeline env {{{
sub _propagate_previous_passed_files {

	return unless $ENV{PREVIOUS_ENV};

	bail "No CACHE_DIR set - cannot propagate passed values"   unless $ENV{CACHE_DIR};
	bail "No WORKING_DIR set - cannot propagate passed values" unless $ENV{WORKING_DIR};

	my $workdir  = $ENV{WORKING_DIR};
	my $cachedir = $ENV{CACHE_DIR};
	if (defined($ENV{GIT_GENESIS_ROOT}) && $ENV{GIT_GENESIS_ROOT} ne "") {
		$workdir  .= "/$ENV{GIT_GENESIS_ROOT}";
		$cachedir .= "/$ENV{GIT_GENESIS_ROOT}";
	}

	my @cachables = (
		".genesis/cached",
		".genesis/config",
		".genesis/kits"
	);

	info "\n#C{Removing local cached files:}";
	run(
		{ onfailure => "#R{[ERROR]} Failed to remove 'workdir/$_'", interactive => 1 },
		'rm', '-rvf', "$workdir/$_"
	) for (@cachables);

	info "\n#C{Copying over cached files from $ENV{PREVIOUS_ENV} environment:}";
	run(
		{ onfailure => "#R{[ERROR]} Failed to copy '$cachedir/$_' to '$workdir/$_'", interactive => 1 },
		'cp', '-Rv', "$cachedir/$_", "$workdir/$_"
	) for (@cachables);

	my $env = Genesis::Top->new($workdir)->load_env($ENV{CURRENT_ENV});
	my @files = map {(my $s = $_) =~ s/^\.\///; $s}
		grep {$_ !~ /^not-shared/}
		$env->relate($ENV{PREVIOUS_ENV},'','not-shared');
	return {
		missing => [grep {-f "$workdir/$_" && ! -f "$cachedir/$_"} @files],
		extra   => [grep {-f "$cachedir/$_" && ! -f "$workdir/$_"} @files],
	};
}

# }}}
# _get_git_env - set up git credentials in a temp home dir, return env hash {{{
sub _get_git_env {
	my ($env_dir) = @_;
	my %env;
	$env{HOME}                = "$env_dir/home";
	$env{GIT_AUTHOR_NAME}     = $ENV{GIT_AUTHOR_NAME}  || 'Concourse Bot';
	$env{GIT_AUTHOR_EMAIL}    = $ENV{GIT_AUTHOR_EMAIL} || 'concourse@pipeline';
	$env{GIT_COMMITTER_NAME}  = $env{GIT_AUTHOR_NAME};
	$env{GIT_COMMITTER_EMAIL} = $env{GIT_AUTHOR_EMAIL};
	$env{GIT_ASKPASS}         = "/bin/false";

	if ($ENV{GIT_PRIVATE_KEY}) {
		mkdir_or_fail( "$env_dir/home/.ssh", 0700);
		mkfile_or_fail("$env_dir/home/.ssh/key", 0600, $ENV{GIT_PRIVATE_KEY});
		mkfile_or_fail("$env_dir/home/.ssh/config", <<EOF);
Host *
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel QUIET
  IdentityFile $env_dir/home/.ssh/key
EOF
		$env{GIT_SSH_COMMAND} = "ssh -F $env_dir/home/.ssh/config";
	}
	if ($ENV{GIT_USERNAME}) {
		mkdir_or_fail( "$env_dir/home", 0700);
		mkfile_or_fail("$env_dir/home/credential-helper.sh", 0755, <<'EOF');
#!/bin/bash
echo username=$GIT_USERNAME
echo password=$GIT_PASSWORD
EOF
		run({env => \%env}, 'git', 'config', 'credential.helper', "$env_dir/home/credential-helper.sh");
	}

	return wantarray ? %env : \%env;
}

# }}}
# _commit_changes - commit post-deploy changes back to the git repo {{{
sub _commit_changes {
	my ($indir, $outdir, $branch, $message, $filter) = @_;

	run(
		{onfailure => "#R{[ERROR]} Failed to remove remnant of previous changes commit"},
		'rm -rf "$1"', $outdir
	) if -d $outdir;

	run({ interactive => 1, passfail => 1},
		'cp -R "$1" "$2"', $indir, $outdir) or exit 1;
	pushd $outdir;

	my $tmp     = workdir;
	my $git_env = _get_git_env($tmp);

	run({ onfailure   => "Could not reset to the newest applicable ref in git",
		  interactive => 1,
		  env => $git_env },
		'git reset --hard "origin/${1}" && git clean -df && git checkout "$1" &&  git pull origin "$1"',
		$branch);
	popd;

	pushd $indir;
	my @output = lines(run({env => $git_env}, 'git status --porcelain'));
	popd;
	info "Detected the following changes in repo:" if @output;
	for my $change (@output) {
		my ($action,$file) = $change =~ /^(..).(.*)$/;
		next if $filter && ref($filter) && ref($filter) =~ /^regexp$/i && $file !~ $filter;
		if ($action =~ /.D/) {
			info "  - #R{removed:} $file";
			run(
				{ onfailure => "Could not remove outdated file '$file' from output directory" },
				'rm -f "$1"', "$outdir/$file"
			);
		} else {
			mkdir_or_fail(dirname("$outdir/$file"));
			info "  - ".($action eq "??" ? "#G{added:}   " : "#Y{changed:} ").$file;
			run(
				{ onfailure => "Could not copy changed files to output directory" },
				'cp -Rv "$1" "$2"', "$indir/$file", "$outdir/$file"
			);
		}
	}

	pushd $outdir;
	my ($output, undef) = run({env => $git_env}, 'git status --porcelain');
	if ($output) {
		run({ interactive => 1,
			  env => $git_env },
			'git add -A && '.
			'git status && '.
			'git --no-pager diff --cached && '.
			'git commit -m "$1"', "CI commit: $message");
	}
}

# }}}
# }}}

1;

=head1 NAME

Genesis::Commands::Pipelines - Pipeline management command suite

=head1 DESCRIPTION

Implements the C<genesis pipeline-*> command family and the legacy
C<repipe>, C<graph>, C<describe>, C<embed>, and C<ci-*> commands.

=head1 COMMANDS

=over 4

=item B<pipeline-apply> [--platform PROVIDER] [--dry-run] [--paused]

Compile and deploy the pipeline. Defaults to Concourse. Supports
C<--dry-run> (print YAML only) and C<--output-dir> (write artifacts).

=item B<pipeline-graph> [--platform PROVIDER]

Compile pipeline and write C<pipeline.md> containing a Mermaid flowchart.

=item B<pipeline-describe> [--platform PROVIDER]

Compile pipeline and print a human-readable ordered progression.

=item B<pipeline-diff> [--target TARGET]

Compare compiled pipeline YAML against the live pipeline via
C<fly get-pipeline>.

=item B<pipeline-status> [<env>] [--target TARGET]

Query C<fly jobs> for per-environment job status.

=item B<pipeline-pause> [<env>] [--target TARGET]

Pause a specific environment's job, or the entire pipeline.

=item B<pipeline-resume> [<env>] [--target TARGET]

Resume a specific environment's job, or the entire pipeline.

=item B<repipe> (deprecated)

Alias for C<pipeline-apply>.

=item B<graph> (deprecated)

Legacy graphviz output without C<--platform>; C<pipeline-graph> with it.

=item B<describe> (deprecated)

Alias for C<pipeline-describe>.

=back

=head1 SEE ALSO

Genesis::CI::Compiler, Genesis::CI::Legacy

=cut

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
