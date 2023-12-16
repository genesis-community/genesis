package Genesis::Commands::Pipelines;

use strict;
use warnings;

use Genesis;
use Genesis::State;
use Genesis::Commands;
use Genesis::Top;
use Genesis::Env;
use Genesis::CI::Legacy qw//;
use Service::Vault;

use File::Basename qw/dirname/;
use File::Path qw/rmtree/;

sub embed {
	command_usage(1) if @_;

	# FIXME: update .genesis/config with new version info
	Genesis::Top->new('.')->embed($ENV{GENESIS_CALLBACK_BIN} || $0);
}

sub repipe {
	option_defaults(config => 'ci.yml');
	my $layout = $_[0];
	my $top = Genesis::Top->new('.', vault=>get_options->{vault});
	bail(
		"No vault specified or configured."
	) unless $top->vault;

	(my $pipeline, $layout) = Genesis::CI::Legacy::parse(get_options->{config}, $top, $layout);

	option_defaults(target => $layout);
	my $yaml = Genesis::CI::Legacy::generate_pipeline_concourse_yaml($pipeline, $top);
	if (get_options->{'dry-run'}) {
		output({raw => 1}, $yaml);
		exit 0;
	}

	my ($out,$rc) = run(
		'fly -t $1 pause-pipeline -p $2',
		get_options->{target}, $pipeline->{pipeline}{name}
	);
	bail("Could not pause #c{%s} pipeline: $out", $pipeline->{pipeline}{name})
		unless $rc == 0 || $out =~ /pipeline '.*' not found/;

	my $yes = get_options->{yes} ? ' -n ' : '';
	my $dir = workdir;
	mkfile_or_fail("${dir}/pipeline.yml", $yaml);
	run({ interactive => 1, onfailure => "Could not upload pipeline $pipeline->{pipeline}{name}" },
		'fly -t $1 set-pipeline '.$yes.' -p $2 -c $3/pipeline.yml',
		get_options->{target}, $pipeline->{pipeline}{name}, $dir);

	run(
		{ interactive => 1, onfailure => "Could not unpause pipeline $pipeline->{pipeline}{name}" },
		'fly -t $1 unpause-pipeline -p $2',
		get_options->{target}, $pipeline->{pipeline}{name}
	) unless (get_options->{paused});

	my $action = ($pipeline->{pipeline}{public} ? 'expose' : 'hide');
	run({ interactive => 1, onfailure => "Could not $action pipeline $pipeline->{pipeline}{name}" },
		'fly -t $1 '.$action.'-pipeline -p $2',
		get_options->{target}, $pipeline->{pipeline}{name});

	exit 0;
}

sub graph {
	option_defaults(config => 'ci.yml');
	my $layout = $_[0];
	my $top = Genesis::Top->new('.');

	(my $pipeline, $layout) = Genesis::CI::Legacy::parse(get_options->{config}, $top, $layout);
	my $dot = Genesis::CI::Legacy::generate_pipeline_graphviz_source($pipeline);
	output "$dot";
	exit 0;
}

sub describe {
	option_defaults(config => 'ci.yml');
	my $layout = $_[0];
	my $top = Genesis::Top->new('.');

	(my $pipeline, $layout) = Genesis::CI::Legacy::parse(get_options->{config}, $top, $layout);
	Genesis::CI::Legacy::generate_pipeline_human_description($pipeline);
	exit 0;
}

sub ci_pipeline_deploy {
	command_usage(1) if @_;

	info("[#G{genesis} ci-pipeline-deploy] v#G{$Genesis::VERSION}\n");

	# TODO: support detection of required vars in the prepare_command step. (maybe
	# show optional variables with a ? after them, or ?1a ?1b to show either/or
	my @undefined = grep { !$ENV{$_} }
		qw/CURRENT_ENV GIT_BRANCH OUT_DIR WORKING_DIR VAULT_ROLE_ID VAULT_SECRET_ID VAULT_ADDR/;
	push @undefined, "CACHE_DIR" if ($ENV{PREVIOUS_ENV} && ! $ENV{CACHE_DIR});
	_bail_on_missing_pipeline_environment_variables(@undefined);

	bail(
		"The pipeline must specify either GIT_PRIVATE_KEY, or GIT_USERNAME and ".
		"GIT_PASSWORD"
	) unless $ENV{GIT_PRIVATE_KEY} || ($ENV{GIT_USERNAME} && $ENV{GIT_PASSWORD});
	# FIXME: Support Bearer Token

	_vault_auth();

	_propagate_previous_passed_files();

	# Load the environment in order to check other required variables
	my $workdir = $ENV{WORKING_DIR};
	$workdir .= "/$ENV{GIT_GENESIS_ROOT}" if (defined($ENV{GIT_GENESIS_ROOT}) && $ENV{GIT_GENESIS_ROOT} ne "");
	pushd $workdir;
	my $env = Genesis::Top->new('.')->load_env($ENV{CURRENT_ENV})->with_vault();

	if ($env->use_create_env) {
		# Make sure that state is up to date. Keep environment changes local to this scope.
		my $tmp = workdir;
		my $git_env = _get_git_env($tmp);
		run({ onfailure   => "Could not reset to the latest state file from origin. State file may not exist, which occurs if the proto bosh has not been deployed once manually.",
			interactive => 1,
			env => $git_env },
			'git checkout "origin/${1}" ".genesis/manifests/${2}-state.yml"',
			$ENV{GIT_BRANCH}, $ENV{CURRENT_ENV});
	}

	_bail_on_missing_pipeline_environment_variables(@undefined); # FIXME -- is this needed?

	info "Preparing to deploy #C{%s}:\n  - based on kit #c{%s}", $env->name, $env->kit->id;
	if ($env->use_create_env) {
		info("  - as a #M{create-env} deployment\n");
	} else {
		my $bosh = $env->bosh();
		info("  - to #M{%s} BOSH director at #Bu{%s}.\n", $bosh->alias, $bosh->url);
	}

	my $result;
	eval {
		$result = $env->with_bosh
		              ->download_required_configs('deploy')
		              ->deploy(redact => !envset('CI_NO_REDACT'), reactions => 1);
	};

	if ($@ || !$result) {
		error "#R{Deployment failed!}\n%s", $@ || "";
		# Make sure to commit the state file in the case of failure
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
		## rm cache dir
		## copy previous env cache dir
		# leaving as system calls for Concourse so output shows up in log
		system("rm -rf .genesis/config .genesis/kits .genesis/cached") == 0 or exit 1;
		system("git checkout .genesis/config"); # ignore failure for git checkout so that
		system("git checkout .genesis/kits");   # we don't cause problems if these files dont
		system("git checkout .genesis/cached"); # yet exist in the working tree (but did in the cache tree)
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

	# Load the environment in order to check other required variables
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

	mkfile_or_fail "updates.yml", 0644, $env->with_bosh
		->download_required_configs('blueprint', 'manifest')
		->manifest(redact => 0, prune => 1);

	my $vars = $env->manifest_lookup('bosh-variables') || {};
	my $vars_file = "bosh-vars.yml";
	DumpYAML($vars_file,$vars);

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
		 | jq -r '.Tables[0].Rows[0] | if (.diff == "" ) then "[32;1mNo differences found.[0m" else .diff end'
EOF

	my %envvars = $env->get_environment_variables();

	if (envset('GENESIS_TRACE')) {
		run( {interactive => 0}, "sed -e 's/set -e/set -ex/' $cmd > ${cmd}-trace");
		$cmd.='-trace';
	}
	my (undef,$rc) = run( {interactive => 1, env => \%envvars}, $cmd, $env->name, $env->type, 'updates.yml', $vars_file);
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
			my $work_file = slurp("$ENV{WORKING_DIR}/$_");
			unless ($cache_file eq $work_file) { $differences += 1; last; };
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

	# environment variables we should have
	#   CURRENT_ENV     - Name of the current environment
	#   GIT_BRANCH      - Name of the git branch to push commits to. post-deploy
	#   GIT_PRIVATE_KEY - Private Key to use for pushing commits, post-deploy, ssh
	#   GIT_USERNAME    - Username to use for pushing commits, post-deploy, https
	#   GIT_PASSWORD    - Password to use for pushing commits, post-deploy, https
	#   PREVIOUS_ENV    - Name of the previous env, or null if none
	#   CACHE_DIR       - Path to the directory of the previous environment's cache
	#   WORKING_DIR     - Path to the directory to deploy/work from
	#   OUT_DIR         - Path to the directory to output to
	#
	my @undefined = grep { !$ENV{$_} }
		qw/CURRENT_ENV GIT_BRANCH
			 WORKING_DIR OUT_DIR/;
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

	# environment variables we should have
	#   CURRENT_ENV         - Name of the current environment
	#   ERRAND_NAME         - Name of the Smoke Test errand to run
	#
	#   VAULT_ROLE_ID       - Vault RoleID to authenticate to Vault with
	#   VAULT_SECRET_ID     - Vault SecretID to authenticate to Vault with
	#   VAULT_ADDR          - URL of the Vault to use for credentials retrieval
	#   VAULT_SKIP_VERIFY   - Whether or not to enforce SSL/TLS validation
	#   VAULT_NAMESPACE     - Set for enterprise vaults that require namespaces
	#   VAULT_NO_STRONGBOX  - Set true for non Genesis vault deployments
	#   VAULT_SECRETS_MOUNT - Set if vault secrets are not found under /secret

	my @undefined = grep { !$ENV{$_} }
		qw/CURRENT_ENV ERRAND_NAME VAULT_ROLE_ID VAULT_SECRET_ID VAULT_ADDR/;
	_bail_on_missing_pipeline_environment_variables(@undefined);

	_vault_auth();

	my $env = Genesis::Top->new('.')->load_env($ENV{CURRENT_ENV})->with_vault()->with_bosh();
	$env->bosh->run_errand($ENV{ERRAND_NAME});
	exit 0;
}

### Support functions

sub _vault_auth {
	my @missing_variables = grep {
		!exists($ENV{$_}) || !defined($ENV{$_})
	} qw/VAULT_ADDR VAULT_ROLE_ID VAULT_SECRET_ID/;
	bail(
		"Pipeline requires the following missing environment variables: %s",
		join(", ", @missing_variables)
	) if @missing_variables;

	# TODO: This should be handled by repo or env vault yaml entries (#BETTERVAULTTARGET)
	Service::Vault->create(
		$ENV{VAULT_ADDR},
		'deployments-vault',
		skip_verify => envset("VAULT_SKIP_VERIFY"),
		namespace => $ENV{VAULT_NAMESPACE},
		no_strongbox => envset("VAULT_NO_STRONGBOX"),
		mount => $ENV{VAULT_SECRETS_MOUNT}
	)->connect_and_validate();
}

# _bail_on_missing_pipeline_environment_variables - provide consistent error message when missing pipeline environment variables {{{
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
# _propagate_previous_passed_files - copy cached files from previous pipeline environment {{{
sub _propagate_previous_passed_files {

	return unless $ENV{PREVIOUS_ENV};

	bail "No CACHE_DIR set - cannot propagate passed values" unless $ENV{CACHE_DIR};
	bail "No WORKING_DIR set - cannot propagate passed values" unless $ENV{WORKING_DIR};

	my $workdir  = $ENV{WORKING_DIR};
	my $cachedir = $ENV{CACHE_DIR};
	if (defined($ENV{GIT_GENESIS_ROOT}) && $ENV{GIT_GENESIS_ROOT} ne "") {
		$workdir  .= "/$ENV{GIT_GENESIS_ROOT}";
		$cachedir .= "/$ENV{GIT_GENESIS_ROOT}";
	}

	my @cachables=(
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
	}
}

# }}}
# _get_git_env - setup a git configuration in the 'home' directory under the given dir, and return env {{{
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
		$env{GIT_SSH_COMMAND}     = "ssh -F $env_dir/home/.ssh/config";
	};
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
# _commit_changes - commit changes back to genesis that incorporate the upstream values {{{
sub _commit_changes {
	my ($indir, $outdir, $branch, $message, $filter) = @_;

	# the below copying of files into new repos from older repos is all
	# done in the name of avoiding merge conflicts, or weird errors when
	# rebasing, and git discovers that there are no changes after you rebase

	# remove any old directories if they are left over (only really happens when
	# debugging a failed run)
	run(
		{onfailure => "#R{[ERROR]} Failed to remove remnant of previous changes commit"},
		'rm -rf "$1"', $outdir
	) if -d $outdir;

	# create an output git repo based off of latest origin/$branch
	run({ interactive => 1, passfail => 1},
		'cp -R "$1" "$2"', $indir, $outdir) or exit 1;
	pushd $outdir;

	my $tmp = workdir;
	my $git_env = _get_git_env($tmp);

	# What's Going On?
	#   reset --hard : reset the repo to the current commit on branch
	#   clean -df:     remove any untracked files (ie the new cached files)
	#   checkout:      ensure we're on the named branch, to correctly push later
	#   pull origin:   ensure we're up-to-date with any changes that may have
	#                  happened during pipeline
	run({ onfailure   => "Could not reset to the newest applicable ref in git",
		  interactive => 1,
		  env => $git_env },
		'git reset --hard "origin/${1}" && git clean -df && git checkout "$1" &&  git pull origin "$1"',
		$branch);
	popd;

	# find and copy (or remove if appropriate) all potential changes to the outdir
	pushd $indir;
	my @output = lines(run({env => $git_env}, 'git status --porcelain'));
	popd;
	info "Detected the following changes in repo:" if @output;
	for my $change (@output) {
		my ($action,$file)= $change =~ /^(..).(.*)$/;
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

	# check if any changes actually exist in the outdir (potential changes may have alread
	# been tracked after $indir's commit, so they could disappear here), then commit them
	pushd $outdir;
	my ($output, undef) = run({env => $git_env}, 'git status --porcelain');
	if ($output) {
		run({ interactive => 1, # print output to Concourse log
			  env => $git_env },
			'git add -A && '.
			'git status && '.
			'git --no-pager diff --cached && '.
			'git commit -m "$1"', "CI commit: $message");
	}
}
# }}}

1;
