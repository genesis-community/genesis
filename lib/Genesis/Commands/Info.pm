package Genesis::Commands::Info;

use strict;
use warnings;
use feature 'state';
no warnings 'utf8';
use utf8;

use Genesis;
use Genesis::State;
use Genesis::Term;
use Genesis::Commands;
use Genesis::Top;

use Cwd            qw/getcwd abs_path/;
use File::Basename qw/basename/;
use JSON::PP       qw/encode_json/;

sub information {
	# TODO: Make use of terminal_width and wrap to make this look better

	command_usage(1) if @_ != 1;

	my ($name) = @_;
	my $env = Genesis::Top->new('.')->load_env($name)->with_vault();

	my @hooks = grep {$env->kit->has_hook($_)} qw(info);
	$env->download_required_configs(@hooks);

	my $out = sprintf(
		"\n#c{%s}\n\n#C{%s Deployment for Environment '}#M{%s}#C{'}\n\n",
		"=" x terminal_width, uc($env->type), $env->name
	);

	my $exodus = $env->exodus_lookup("",{});
	my $unknown = csprintf("#YI{unknown}");
	if ($exodus->{dated}) {
		$out .= sprintf(
			"  #I{Last deployed} %s\n".
			"  #I{           by} #C{%s}\n",
			strfuzzytime($exodus->{dated}, "#C{%~} #K{(%I:%M%p on %b %d, %Y %Z)}"),
			$exodus->{deployer} || $unknown
		);
		if ($exodus->{bosh}) {
			if ($exodus->{bosh} eq "(none)" || $exodus->{bosh} eq '~' || $exodus->{use_create_env}) {
				$out .= sprintf(
					"  #I{     %s BOSH} #CI{create-env}\n",
					(defined($exodus->{as_director}) && !$exodus->{as_director}) ? 'via' : ' as'
				);
			} else {
				$out .= sprintf("  #I{      to BOSH} #CI{%s}\n",$exodus->{bosh});
			}
		}
		$out .= sprintf(
			"  #I{ based on kit} #C{%s}#C{/%s}%s%s\n",
			$exodus->{kit_name}||$unknown,
			$exodus->{kit_version}||$unknown,
			($exodus->{kit_is_dev} ? " #y{(dev)}" : ''),
			($env->kit->version ne $exodus->{kit_version}||'' ? " -- #Y{local file specifies ${\($env->kit->id)}!}" : '')
		);
		$out .= sprintf(
			"  #I{        using} #C{Genesis v%s}\n",
			$exodus->{version} ||$unknown
		);

		my ($manifest_path,$exists,$sha1) = $env->cached_manifest_info;
		my $pwd = Cwd::abs_path(Cwd::getcwd);
		$manifest_path =~ s#^$pwd/##;
		if ($exists) {
			if (! defined($exodus->{manifest_sha1})) {
				info $out;
				$out = '';
				error(
					"\nCannot confirm local cached deployment manifest pertains to this ".
					"deployment -- perform another deployment to correct this problem."
				);
			} elsif ($exodus->{manifest_sha1} ne $sha1) {
				info $out;
				$out = '';
				warning(
					"\nLatest deployment does not match the local cached deployment ".
					"manifest, perhaps you need to perform a #C{git pull}."
				)
			} else {
				$out .= sprintf(
					"  #I{with manifest} #C{%s} #K{(redacted)}\n",
					$manifest_path
				);
			}
		} else {
			info $out;
			$out = '';
			warning(
				"\nNo local cashed deployment manifest found for this environment, ".
				"perhaps you need to perform a #C{git pull}."
			)
		}
		if ($exodus->{features}) {
			my @features = split(',',$exodus->{features});
			$out .= "\n       #I{Features} ";
			if (@features) {
				$out .= "#C{".join("}\n                #C{",@features)."}\n";
			} else {
				$out .= "#Ci{None}\n";
			}
		}

		if ($env->has_hook('info')) {
			info "$out\n#c{%s}\n", "-" x terminal_width;
			$out = '';
			$env->run_hook('info');
		}
	} else {
		info $out; $out = '';
		error "#YI{No record of deployment found -- info available only after deployment!}"
	}

	info "$out\n#c{%s}\n", "=" x terminal_width;
}


sub lookup {
	command_usage(1) if @_ < 2 or @_ > 3;
	get_options->{exodus} = 1 if get_options->{'exodus-for'};
	command_usage(1,"Can only specify one of --merged, --partial, --deployed, or --exodus(-for)")
		if ((grep {$_ =~ /^(exodus|deployed|partial|merged|env)$/} keys(%{get_options()})) > 1);

	my ($name, $key, $default) = @_;
	# Legacy support -- previous versions used key/name order
	my $top = Genesis::Top->new('.');
	($name, $key) = ($key,$name) if !$top->has_env($name) && $top->has_env($key);

	if (get_options->{"defined"}) {
		command_usage(1, "Cannot specify default value with --defines option")
			if defined($default);
		$default = bless({},"NotFound"); # Impossible to have this value in sources.
	}
	my $env = $top->load_env($name);
	my $v;
	if (get_options->{entomb}) {
		bail(
			"Cannot use --entombed option with --exodus, --exodus-for or --deployed",
		) if scalar( grep {$_} (@{get_options()}{qw/exodus exodus-for deployed/}));
		$env->entombed_secrets_enabled(1);
	}

	if (get_options->{merged}) {
		bail(
			"Circular reference detected while trying to lookup merged manifest of $name"
		) if envset("GENESIS__LOOKUP_MERGED_MANIFEST");
		$ENV{GENESIS__LOOKUP_MERGED_MANIFEST}="1";
		$env->download_required_configs('manifest');
		$v = $env->manifest_lookup($key,$default);
	} elsif (get_options->{partial}) {
		bail(
			"Circular reference detected while trying to lookup merged manifest of $name"
		) if envset("GENESIS__LOOKUP_MERGED_MANIFEST");
		$ENV{GENESIS__LOOKUP_MERGED_MANIFEST}="1";
		$v = $env->partial_manifest_lookup($key,$default);
	} elsif (get_options->{deployed}) {
		$v = $env->last_deployed_lookup($key,$default);
	} elsif (get_options->{exodus}) {
		$v = $env->exodus_lookup($key,$default,get_options->{'exodus-for'})
	} elsif (get_options->{env}) {
		my %envvars = $env->get_environment_variables();
		$key =~ s/^\.//;
		if ($key) {
			$v = exists($envvars{$key}) ? $envvars{$key} :
			     exists($ENV{$key}) ? $ENV{$key} : $default;
		} else {
			$v = {%ENV, %envvars};
		}
	} else {
		$v = $env->lookup($key, $default);
	}

	if (get_options->{defined}) {
		exit(ref($v) eq "NotFound" ? 4 : 0);
	} elsif (defined($v)) {
		$v = encode_json($v) if ref($v);
		output {raw => 1}, $v;
	}
	exit 0;
}

sub yamls {
	option_defaults(
		"include-kit" => 0
	);
	command_usage(1) if @_ != 1;

	my $env = Genesis::Top
		->new('.')
		->load_env($_[0])
		->download_required_configs('blueprint');
	my @files = $env->format_yaml_files(%{get_options()});
	output join("\n", @files)."\n";
}

sub vault_paths {
	option_defaults(
		"references" => 0
	);
	command_usage(1) if @_ != 1;

	my $env = Genesis::Top
		->new('.')
		->load_env($_[0]);

	my $vault_paths = $env->vault_paths();
	my $msg = "";
	for my $path (sort keys %$vault_paths) {
		$msg .= "\n$path";
		$msg .= ":\n  - ".join("\n  - ", @{$vault_paths->{$path}})
			if (get_options->{references});
	}
	# TODO: Do we want to color code secret and exodus mounts and base paths?
	output "$msg\n";
}

sub kit_manual {
	my ($name) = @_;
	my $top = Genesis::Top->new('.');
	my @possible_kits = keys %{$top->local_kits};
	push @possible_kits, 'dev' if $top->has_dev_kit;

	bail(
		"No local kits found; you must specify the name of the kit to fetch"
	) unless scalar(@possible_kits);

	my $kit;
	$name ||= '';
	if ($name && $top->has_env($name)) {
		$top->reset_vault();
		# TODO: provide a vaultless way to read env kit without vault
		$kit = $top->load_env($name)->kit;
	} elsif ($name && $name eq 'dev') {
		$kit = $top->local_kit_version('dev')
	} else {
		my ($kit_name,$version) = $name =~ m/^([^\/]*)(?:\/(.*))?$/;
		if (!$version && semver($name)) {
			bail "More than one local kit found; please specify the kit to get the manual for"
				if scalar(@possible_kits) > 1;
			$version = $name;
			$version =~ s/^v//;
			$name = $possible_kits[0];
		}
		$kit = $top->local_kit_version($name, $version);
	}

	if(!(defined $kit)) {
		error "Kit not found: #C{%s}", $name;
		exit 1;
	}

	info "Displaying manual for kit #C{%s}...\n", $kit->id;

	my $man = $kit->path('MANUAL.md');
	if (-f $man) {
		my $man_contents = slurp($man);
		my $contents = get_options->{raw} ? $man_contents : render_markdown($man_contents);
		if (get_options->{pager}) {
			open my $pager, "|-", "less -R" or die "Can't open pager: $!";
			print $pager $contents;
			close $pager;
		} else {
			output $contents;
		}
		exit 0;
	}
	error "#Y{%s} has no MANUAL.md", $kit->id;
	exit 1;
}

# List all environments known to Genesis under the deployment_roots.  This
# will display the following properties for each environment:
# - Root path
# - Environment name
# - Environment kit type and version
# - Last deployment date
#
# TODO: Add a flag for verbose mode that will display significantly more
# detailed information about each environment - TBD
# TODO: Add a flag for filtering environments by kit type
# TODO: Add a flag to mass check secrets in all environments
sub environments {

	my $group_by = get_options->{group_by_env} ? 'env' : 'kit';
	#preemptively check that vault is available
	
	# Get the list of deployment roots
	my @roots = map {
		abs_path($_) eq abs_path('.') ? '.' : abs_path($_)
	} @{$Genesis::RC->get(deployment_roots => [])};

	push @roots, '.' unless in_array('.', @roots);

	for my $root (@roots) {
		# Find all deployments under each root
		my @repos = map {s{/.genesis/config$}{}; $_} glob("$root/*/.genesis/config");
		if (scalar @repos) {
			$root =~ s{/?$}{/};
			info "\nDeployment root #C{%s} contains the following:", humanize_path($root) =~ s{/?$}{/}r;
			info $ansi_hide_cursor if $group_by eq 'env';
			my %deployments_by_name;
			my ($i,$j) = (0,0);
			for my $repo (@repos) {
				__processing($i, scalar(@repos), $j) if ($group_by eq 'env');
				my $top = Genesis::Top->new($repo, silent_vault_check => 1);
				my $repo_label = basename($top->path);
				my @envs = $top->envs; # Do the heavy lifting to determine which files are environments
				__processing(++$i, scalar(@repos), $j) if ($group_by eq 'env');

				if (scalar(@envs)) {
					info "\n[[  >>#u{Environments under repo }#mu{%s}#u{:}", $repo_label if ($group_by eq 'kit');
					for my $env (@envs) {
						my $exodus = $env->exodus_lookup('.',{});
						my $env_info = {
							name => $env->name,
							kit => $env->kit->id,
							type => $env->type,
							kit_version => $env->kit->version,
							is_director => $env->is_bosh_director,
							bosh_env => $exodus->{bosh},
							path => $repo_label,
						};
						if ($exodus->{dated}) {
							$env_info->{last_deployed} = $exodus->{dated};
							$env_info->{last_deployed_by} = $exodus->{deployer};
							$env_info->{last_kit} = $exodus->{kit_name}.'/'.$exodus->{kit_version}.($exodus->{kit_is_dev} ? ' (dev)' : '');
						}
						push @{$deployments_by_name{$env_info->{name}}}, $env_info;

						if ($group_by eq 'kit') {
							my $msg = sprintf(
								"[[    #c{%s}: >>#m{%s}",
								$env_info->{name},
								$env_info->{kit}
							);
							if ($env_info->{last_deployed}) {
								$msg .= sprintf(
									" - deployed #yi{%s}by #G{%s} %s",
									$env_info->{bosh_env} && $env_info->{bosh_env} ne $env_info->{name} ? "on BOSH $env_info->{bosh_env} " : '',
									$env_info->{last_deployed_by},
									strfuzzytime($env_info->{last_deployed}),
								);
								$msg .= " using kit #Y{$env_info->{last_kit}} #y\@{!}"
									if ($env_info->{last_kit} ne $env_info->{kit});
							} else {
								$msg .= " - #Y{never deployed}";
							}
							info $msg;
						} else {
							__processing($i, scalar(@repos), ++$j);
						}
					}
				}
			}
			if ($group_by eq 'env') {
				info {pending => 1}, $ansi_reset_line.$ansi_cursor_up.$ansi_show_cursor;
				for my $env_name (sort keys %deployments_by_name) {
					info "\n[[  >>#u{Environment }#cu{%s}#u{:}", $env_name;
					for my $env_info (@{$deployments_by_name{$env_name}}) {
						my $type = $env_info->{is_director} ? '#R{BOSH director}' : '#G{'.$env_info->{type}.' deployment}';
						my $msg = sprintf(
							"[[    $type#yi{%s}: >>#m{%s}",
							$env_info->{type} eq $env_info->{path} ? '' : ' (in '.$env_info->{path}.')',
							$env_info->{kit}
						);
						if ($env_info->{last_deployed}) {
							$msg .= sprintf(
								" - deployed #yi{%s}by #G{%s} %s",
								$env_info->{bosh_env} && $env_info->{bosh_env} ne $env_info->{name} ? "on BOSH $env_info->{bosh_env} " : '',
								$env_info->{last_deployed_by},
								strfuzzytime($env_info->{last_deployed}),
							);
							$msg .= " using kit #Y{$env_info->{last_kit}} #y\@{!}"
								if ($env_info->{last_kit} ne $env_info->{kit});
						} else {
							$msg .= " - #r{never deployed}";
						}
						info $msg;
					}
				}
			}
		} elsif ($root ne '.') {
			warning("\nNo environments found under deployment root #C{%s}\n", $root);
		}
	}
	info '';
}

sub __processing {
	my ($block, $total, $strobe, $strobe_size) = @_;
	$strobe_size ||= 7;
	my $percent = $block / $total;
	my $strobe_swing = $strobe_size - 1;
	my $strobe_pos = ($strobe_swing) - abs(($strobe % ($strobe_swing*2)) - $strobe_swing);
	my $strobe_char = $ENV{GENESIS_NO_UTF8} ? "*" : "\x{25FC}";
	info(
		{pending => 1, raw => 1},
		$ansi_reset_line."  Processing: %3d%%: [%s ]",
		$percent * 100,
		join('', map { csprintf("#%s{%s}", $_ == $strobe_pos ? "Y" : "K", $strobe_char)} 0..$strobe_swing)
	);

}


1;
