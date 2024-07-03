package Genesis::Commands::Kit;

use strict;
use warnings;
no warnings 'utf8';
use utf8;

use Genesis;
use Genesis::Term;
use Genesis::State;
use Genesis::Commands;
use Genesis::Top;
use Genesis::Kit::Compiler;

use Service::Github;

use Archive::Tar;
use Cwd qw/getcwd/;
use File::Basename qw/dirname/;
use Time::HiRes qw/gettimeofday/;

sub create_kit {
	my $name = get_options->{name};
	command_usage(2) unless defined($name);

	my $dir = abs_path(get_options->{dev} ? "dev" : "${name}-genesis-kit");
	Genesis::Kit::Compiler->new($dir)->scaffold($name);

	info("\n#G{Created new Genesis kit '}#C{$name}#G{' in }#C{$dir}");
}

sub build_kit {
	command_usage(1) if @_ != 0;

	my $target = get_options->{target} || '.';
	$target =~ s#/*$#/#;
	if (-f $target.".genesis/config") {
		$target .= ".genesis/kits/";
		mkdir_or_fail $target unless -d $target;
	}

	my %options = %{get_options()};
	my $dir;
	unless ($options{name}) {
		my $pwd =  getcwd;
		if ($pwd =~ /\/([^\/]*)(-deployments)?$/ && -f "$pwd/dev/kit.yml") {
			# Building from dev/ inside a deployment repo - glean the name
			$options{name} = $1;
			$dir = "$pwd/dev";
			$dir = readlink($dir) if (-l "$dir");
			$options{dev} = 1;

		} elsif ($pwd =~ /\/([^\/]*)-genesis-kit$/) {
			# Building from a Genesis Kit source repo
			$options{name} = $1;
			$dir = $pwd;
			bail "Current directory is a kit -- cannot specify dev mode\n"
				if $options{dev};
		}
	}
	check_prereqs(); # TODO: Does this work?
	command_usage(1, "Missing name option, cannot determine from `pwd`") unless $options{name};

	my $top = Genesis::Top->new('.');
	my @remote_versions = map {$_->{version}} ($top->remote_kit_versions(
		$options{name},
		include_prereleases=>1,
		include_drafts=>1
	));
	my $local_kits = Genesis::Kit::Compiled->local_kits($top->kit_provider, $target);
	my @local_versions = grep { semver($_) } (keys %{ $local_kits->{$options{name}} });

	if ($options{version}) {
		$options{version} =~ s/^v//; # trim any leading 'v'
		bail(
			"Version #C{$options{version}} is not in a valid semver format"
		) unless semver($options{version});
		for my $opt (qw/final major minor/) {
			bail(
				"Cannot specify --version|-v if also specifying --final|-F, --major|-M or --minor|-m"
			) if $options{$opt};
		}
		bail(
			"Version #C{$options{version}} already exists: use --force to recreate ".
			"a potentially different one locally."
		) if (grep {$options{version} eq $_} (@remote_versions,@local_versions)) && !$options{force};

	} else {
		my $bump=2;
		if ($options{major}) {
			bail(
				"Cannot specify both --major|-M and --minor|-m"
			) if $options{minor};
			$bump=0;
		} elsif ($options{minor}) {
			$bump=1;
		}

		my ($latest) = sort {by_semver($b,$a)} (@remote_versions, @local_versions);
		my @semver = semver($latest);
		if (@semver) {
			my $locale=(grep {$latest eq $_} @local_versions) ? 'locally' : 'in remote kit source';
			info "Found latest version of #C{%s} for #M{%s} %s.", $latest, $options{name}, $locale;
		} else {
			@semver = (0,0,0,0) unless @semver;
		}

		# Determine latest semver
		if ($bump == 2) {
			$semver[$bump]++ unless $semver[3];
		} else {
			$semver[$bump]++;
			$semver[$_] = 0 for ($bump+1 .. 3);
		}
		$options{version} = join('.',@semver[0 .. 2]);
		$options{version} .= "-rc" . (++$semver[3] % -100000 + 100000) unless $options{final};
	}

	unless ($dir) {
		if ($options{dev}) {
			$dir = ($options{cwd} || ".") . "/dev";
			bail "$dir does not exist -- cannot continue compiling dev kit.\n" unless -d $dir;
		} else {
			$dir = ($options{cwd} || ".");
			$dir .= "/$options{name}-genesis-kit"
				if (! -f "$dir/kit.yml" && -d "/$options{name}-genesis-kit");
		}
	}
	info "Preparing to compile #M{%s} kit #C{v%s}...", $options{name}, $options{version};
	my $cc = Genesis::Kit::Compiler->new($dir);
	my $tar = $cc->compile($options{name}, $options{version}, $target, force => $options{force})
		or bail "Unable to compile v$options{version} of $options{name} Genesis Kit.\n";

	info("Compiled #M{$options{name}} v#C{$options{version}} to #G{$target$tar}\n");
}

sub list_kits {

	# Custom "not in a directory" error for list-kits because
	# we want to be able to mention the subcommand's -r flag, which is
	# very commonly needed in this situation.
	# If not in repo, and haven't provided -r flag:
	if(!in_repo_dir && ! has_option('remote')) {
		error "#R{GENESIS PRE-REQUISITES CHECKS FAILED!!}";
		error "The '#B{genesis list-kits}' command needs to be run from a Genesis deployment\n".
			"repo, or specify one using -C <dir> option. \nAlternatively, specify the -r flag to list available remote kits.";
		exit 1;
	}
	check_prereqs();

	command_usage(1) if @_ > 1;
	my $name = $_[0];
	command_usage(1,"Cannot specify both --filter and name.")
		if ($name && has_option('filter'));
	command_usage(1,"Cannot specify both --remote|-r and --updates|-u.")
		if has_option('remote') && has_option('updates');
	command_usage(1,"Cannot specify a name or filter with the --all|-a option.")
		if has_option('all') && ($name || has_option('filter'));

	my $top = Genesis::Top->new('.');

	my $local_kits = $top->local_kits;

	my %options = %{get_options()};

	my (%kits, %latest);
	$options{details} //= $options{updates};
	if ($options{remote}) {
		# set the filter or name to local kit(s) unless name or filter is provided,
		# or if --remote and --all|-a is specified
		my $filter = $options{filter};
		unless ($name || $filter || $options{all}) {
			my @local_kit_names = keys %$local_kits;
			if (scalar(@local_kit_names) == 1) {
				$name = $local_kit_names[0];
			} elsif (@local_kit_names > 1) {
				$filter = '(^'.join('|', @local_kit_names).'$)';
			}
		}
		my @kit_names = ($name ? ($name) : $top->remote_kit_names($filter));
		for my $kit (@kit_names) {
			my %versions;
			# TODO: make this overwrite each check, or have a progress bar...
			$versions{$_->{version}} = $_
				for ($top->remote_kit_versions($kit, latest=>$options{latest}, include_prereleases=>$options{prereleases}, include_drafts=>$options{drafts}));
			$kits{$kit} = \%versions;
		}

	} elsif ($options{updates}) {
		for my $k (keys %$local_kits) {
			$kits{$k} = {};
			$latest{$k} = (reverse sort by_semver keys(%{$local_kits->{$k}}))[0];
			my %versions;
			$versions{$_->{version}} = $_
				for ($top->remote_kit_versions($k, latest=>$options{latest}, include_prereleases=>$options{prereleases}, include_drafts=>$options{drafts}));
			for my $v (reverse sort by_semver keys(%versions)) {
				last if $latest{$k} && by_semver($v,$latest{$k}) < 1;
				$kits{$k}{$v} = $versions{$v};
			}
		}

	} else {
		for my $k (keys %$local_kits) {
			next if $name && $name ne $k;
			$kits{$k} ||= {};
			my @versions = keys %{$local_kits->{$k}};
			@versions = reverse grep {$_} (reverse sort by_semver @versions)[0..(($options{latest} || 1)-1)]
				if defined $options{latest};
			$kits{$k}{$_} = {} for (@versions); # local kits don't have details - TODO: Package them with release notes
		}
	}

	if (keys %kits) {
		my $out = "";
		for my $kit (sort(keys %kits)) {
			if ($options{updates}) {
				my $num_updates = keys(%{$kits{$kit}});
				if ($num_updates) {
					$out .= sprintf(
						"\n#Y{There %s for the }#C{%s}#Y{ kit (currently using }#C{v%s}#Y{):}",
						($num_updates == 1 ? "is 1 update" : "are $num_updates updates"),
						$kit,
						$latest{$kit}
					);
				} else {
					$out .= "\n#G{There are no updates available for the }#C{$kit}#G{ kit.}\n";
				}
			} else {
				$out .= "\n#Cu{Kit: $kit}\n";
				$out .= sprintf(
					"#Y{  No versions found%s.\n}",
					($options{updates} && $latest{$kit} ? " newer that v$latest{$kit}" : "")
				) unless keys(%{$kits{$kit}});
			}
			for my $version (sort by_semver keys(%{$kits{$kit}})) {
				my $c = ($version =~ /[\.-]rc[\.-]?(\d+)$/) 
					? "Y"
					: ($kits{$kit}{$version}{prerelease} ? "y" : "G");
				my $d = "";
				if ($options{details}) {
					if ($kits{$kit}{$version}{date}) {
						$d = "Published ".$kits{$kit}{$version}{date};
						$d .= " - \}#${c}i{Pre-release}#${c}\{"
							if $kits{$kit}{$version}{prerelease};
						$d = " ($d)";
					}
					if ($kits{$kit}{$version}{body}) {
						$out .= sprintf("\n\n%s#%s{%s%s%s}\n\n", bullet('', color => $c), $c, "Release Notes for v", $version, $d);
						$out .= ("    " . join(
							"\n    ",
							split(/\n/, render_markdown(
								$kits{$kit}{$version}{body},
								expand => 1,
								width => (terminal_width() - 4)
							))
						));
					}
				} else {
					$out .= sprintf(
						"%s#%s{v%s%s}",
						bullet('', color => $c),
						$c,
						$version,
						$d
					);
				}
				$out .= "\n";
			}
		}
		output $out;
	} else {
		info "\n#Y{No kits found%s.}", (
			$name ? " matching '$name'"
			: ($options{filter} ? " matching pattern /$options{filter}/" : ''))

	}
};

sub decompile_kit {
	command_usage(1) if @_ != 1;

	my $top = Genesis::Top->new('.');
	(my $dir = get_options->{directory} || 'dev' ) =~ s#/*$#/#;
	bail(
		"#C{%s} directory already exists (and --force not specified).\n".
		"Will not continue.",
		humanize_path($dir)
	) if ($dir eq 'dev/' && $top->has_dev_kit && !get_options->{force});

	my $file = $_[0];
	my $label = $file;
	$file = $1 if $file =~ /(.*)\.yml/; #.yml extension should be allowed
	if ($label ne 'latest' && $top->has_env($file)) {
		local %ENV = %ENV;
		$ENV{GENESIS_UNEVALED_PARAMS} = 1; # To prevent the need of vault
		my $env = $top->load_env($file) or bail(
			"#R{[ERROR]} #C{%s} should be an environment YAML file, but could not be loaded",
			humanize_path($file)
		);
		bail(
			"Environment #C{%s} is already using a dev kit, and we don't ".
			"want to get into metaphysical absurities...",
			$file
		) if $env->kit->name eq 'dev';
		$file = $env->kit->id;
		$label = $file;
	}
	if ($file eq 'latest' || ! -f $file) {
		(my $stem = $file) =~ s|/v?|-|;
		my $maybe_file = $top->path(".genesis/kits/$stem.tar.gz");
		if ( -f $maybe_file ) {
			$file = $maybe_file;
		} elsif ($file !~ /\//) {
			# figure out what they meant...
			my $local_kits = $top->local_kits();
			my $possible_name = $file;
			(my $possible_version = $file) =~ s/^v//;
			my @known_names = keys(%{$local_kits});
			if (grep {$_ eq $possible_name} @known_names) {
				# matches name; use latest version
				my $version = (reverse sort by_semver keys(%{$local_kits->{$possible_name}}))[0];
				$file = $top->path(".genesis/kits/${possible_name}-${version}.tar.gz");
				$label = "$possible_name/$version (latest)" if -f $file;
			} else {
				my @possible_files = ();
				for my $known_name (@known_names) {
					$possible_version = (reverse sort by_semver keys(%{$local_kits->{$known_name}}))[0]
						if $possible_name eq 'latest';
					push(@possible_files, [$known_name, $possible_version, $top->path(".genesis/kits/${known_name}-${possible_version}.tar.gz")])
						if $local_kits->{$known_name}{$possible_version};
				}
				@possible_files = grep {-f $_->[2]} @possible_files;
				bail(
					"There are multiple kits have the given version - please be explicit"
				) if scalar(@possible_files) > 1;
				$file = $possible_files[0][2];
				$label = sprintf("%s/%s%s", $possible_files[0][0], $possible_files[0][1], $possible_name eq 'latest' ? " (latest)":'')
					if -f $file;
			}
		}
		bail("Unable to find Kit archive %s\n", $_[0]) if (! -f $file);
	} else {
		$label = humanize_path($file);
	}

	info(
		"Uncompressing compiled kit archive #G{%s} into #C{%s/}\n",
		$label,
		humanize_path($dir)
	);
	_decompile_kit($top,$file,get_options->{directory});
}

sub fetch_kit {
	my @kits = @_;
	my $top = Genesis::Top->new('.');
	my @possible_kits = keys %{$top->local_kits};

	unless (scalar(@kits)) {
		bail "No local kits found; you must specify the name of the kit to fetch"
		  unless scalar(@possible_kits);
		@kits = @possible_kits;
	}

	bail(
		"Cannot specify multiple kits to fetch with --as-dev option"
	) if (@kits > 1 && get_options->{'as-dev'});

	for (@kits) {
		my ($name,$version) = $_ =~ m/^([^\/]*)(?:\/(.*))?$/;
		if (!$version && semver($name)) {
			bail(
				"No local kits found; you must specify the name of the kit to fetch"
			) unless scalar(@possible_kits);
			bail(
				"More than one local kit found; please specify the kit to fetch"
			) if scalar(@possible_kits) > 1;
			$version = $name;
			$name = $possible_kits[0];
		}
		$version =~ s/^v// if $version;

		bail(
			"dev/ directory already exists (and --force not specified).  Bailing out."
		) if ($top->has_dev_kit && get_options->{'as-dev'} && !get_options->{force});

		my $kitsig = join('/', grep {$_} ($name, $version));
		info(
			"Attempting to retrieve Genesis kit #M{$name (%s)}...",
			$version ? "v$version" : "latest version"
		);
		($name,$version,my $target) = $top->download_kit($kitsig,%{get_options()})
			or bail "Failed to download Genesis Kit #C{$kitsig}";

		_decompile_kit($top,$target) if (get_options->{'as-dev'});

		my $target_str = get_options->{to} ? " to ".humanize_path($target) : '';
		$target_str .= " and decompiled it into ".humanize_path($top->path('dev'))
			if get_options->{'as-dev'};
		info(
			"Downloaded version #C{$version} of the #C{$name} kit%s\n",
			$target_str
		);
	}

	# Test the kit
}

sub compare_kits {

	# Check inputs
	my $top = Genesis::Top->new('.');
	my $kit_provider = $top->kit_provider;
	my $dir = humanize_path($top->path());
	my $in_repo_dir = Genesis::Top->is_repo('.');
	my $in_kit_dir = in_kit_dir;
	my @filters = @_;

	info(
		"\nComparing Genesis kit".
			($in_repo_dir
				? " in deployment repo #g{$dir/dev}"
				: $in_kit_dir
				? " in kit directory #C{$dir}"
				: ""
			)."...\n"
	);

	# Check which scope we're in
	my $kit = undef;
	if ($in_repo_dir && $top->has_dev_kit) {
		$kit = Genesis::Kit::Dev->new($top->path('dev'));
	} elsif ($in_kit_dir) {
		$kit = Genesis::Kit::Dev->new($top->path());
	} else {
		bail(
			"No kit found -- must be in a Genesis deployment repo or kit directory"
		) unless $kit;
	}

	my $name = $kit->metadata('name');

	# Get the kit to compare against - it can be a directory, tarball, or version
	my ($other_kit, $other_kit_src) = ();
	my $compare = get_options->{'compare-to'};
	unless (defined($compare)) {
		if ($in_repo_dir) {
			my $local_kits = $top->local_kits;
			my $latest = (sort by_semver keys(%{$local_kits->{$name}//{}}))[-1];
			bail(
				"No local #M{%s} kits found to compare against\n",
				$name
			) unless $latest;
			$other_kit = $local_kits->{$name}{$latest};
		} else {
			$compare = (sort by_semver map {$_->{version}} $top->remote_kit_versions($name))[-1];
		}
	}
	unless ($other_kit) {
		if ($compare =~ /^v?(\d+\.\d+\.\d+(-rc\.\d+)?)/) {
			my $other_kit_path = workdir("kit-$name-$1");
			my ($_name, $_version, $file) = $kit_provider->fetch_kit_version(
				$name,
				$1,
				$other_kit_path,
				1
			) or bail(
				"Failed to download Genesis Kit #C{%s}",
				"$name/$1"
			);
			(undef,undef,$other_kit_src) = $kit_provider->fetch_kit_version_src(
				$_name,
				$_version,
				workdir("kit-$name-".$_version),
				1
			);
			$other_kit = Genesis::Kit::Compiled->new(
				name => $_name,
				version => $_version,
				archive => $file,
				provider => $kit_provider
			);
		} elsif (-d $compare) {
			$compare = Genesis::Kit::Dev->new($compare);
		} elsif (-f $compare && $compare =~ /\.tar\.gz$/) {
			$compare = Genesis::Kit::Compiled->new($compare);
		} else {
			bail(
				"Cannot compare kit against #C{%s} -- must be a directory, tarball, or version",
				$compare
			);
		}
	}

	# Get the releases from the kits
	info( "\nFetching releases from target kit #M{%s}...", $kit->id);
	my $tstart = gettimeofday;
	my ($new_releases, $new_versions, $new_dup_versions, $new_unversioned) = _get_kit_releases($kit, @filters);
	my $found = scalar(keys %$new_releases);
	info("  - #%s{found %s}".pretty_duration(gettimeofday-$tstart,0.5,2), $found ? 'G' : 'R', $found);

	info( "\nFetching releases from comparison kit #Y{%s}...", $other_kit->id);
	$tstart = gettimeofday;
	my ($old_releases, $old_versions, $old_dup_versions, $old_unversioned) = _get_kit_releases($other_kit, @filters);
	$found = scalar(keys %$old_releases);
	info("  - #%s{found %s}".pretty_duration(gettimeofday-$tstart,0.5,2), $found ? 'G' : 'R', $found);

	# Compare the releases
	my ($added, $common, $removed) = compare_arrays([keys %$new_releases], [keys %$old_releases]);

	my ($changed, $unchanged) = ();
	for my $name (@$common) {
		my ($versions_added, $versions_common, $versions_removed) = compare_arrays(
			[reverse sort by_semver keys %{$new_releases->{$name}}],
			[reverse sort by_semver keys %{$old_releases->{$name}}]
		);
		if (@$versions_added || @$versions_removed) {
			$changed->{$name} = {
				added => $versions_added,
				removed => $versions_removed,
				common => $versions_common
			};
		} else {
			$unchanged->{$name} = {
				common => $versions_common
			};
		}
	}

	# Fetch the job specs for versions that have changed
	my %spec_files = ();
	if (keys %$changed) {
		# Get the ci/upstream_repo for the other kit
		my $new_upstream_repo = -f $kit->path('ci/upstreamrepo.yml')
			? load_yaml(slurp($kit->path('ci/upstreamrepo.yml')))
			: {repos => []};

		my $old_upstream_repo = {repos => []};
		if ($other_kit_src) {
			# extract ci/upstreamrepo.yml from tarfile
			my $tar= Archive::Tar->new();
			$tar->read($other_kit_src, undef, {filter => qr{/ci/upstreamrepo\.yml$}});
			if ($tar->list_files()) {
				my $upstream_repo = $tar->get_content($tar->list_files());
				$old_upstream_repo = load_yaml($upstream_repo);
			} else {
				debug("No ci/upstreamrepo.yml found in kit %s source:\n\n#y{%s}", $other_kit_src, $@);
			}
		} elsif (-f $other_kit->path('ci/upstreamrepo.yml')) {
			$old_upstream_repo = load_yaml(slurp($other_kit->path('ci/upstreamrepo.yml')));
		} else {
			debug("No ci/upstreamrepo.yml found in kit %s", $other_kit->id);
		}

		# Fetch the job specs for the changed versions
		my $workdir = workdir("job-specs");
		my $spec_time = gettimeofday;
		info("\nFetching job specs for changed releases...");
		my %gh;
		my $spec_dir = $Genesis::RC->get('spec_cache_dir');
		if ($spec_dir) {
			$spec_dir = expand_path($spec_dir) =~ s/\/$//r;
			mkdir_or_fail($spec_dir) unless (-d $spec_dir);
			info ('[[  - >>using job spec cache directory %s', humanize_path($spec_dir));
		} else {
			info (
				'[[  - >>no #Y{spec_cache_dir} specified in the Genesis config: using '.
				'temporary directory for job specs.  Consider setting this in your '.
				'~/.genesis/config file to avoid repeated downloads.'
			);
			$spec_dir = $workdir;
		}
		for my $name (sort keys %$changed) {
			# TODO: Figure out how to handle multiple sources of a version
			my $new_version = $changed->{$name}{added}[0];
			my $old_version = $changed->{$name}{removed}
				? $changed->{$name}{removed}[0]
				: $changed->{$name}{common}[0];
			$old_releases->{$name}{$old_version}{role} = 'old';
			$old_releases->{$name}{$old_version}{repo} = $old_upstream_repo;
			$old_releases->{$name}{$old_version}{alt_repo} = $new_upstream_repo;
			$new_releases->{$name}{$new_version}{role} = 'new';
			$new_releases->{$name}{$new_version}{repo} = $new_upstream_repo;
			for my $release ($old_releases->{$name}{$old_version}, $new_releases->{$name}{$new_version}) {
				my ($name, $version) = @{$release}{qw/name version repo/};

				$release->{spec_url} //= _get_spec_url($release);
				unless ($release->{spec_url}) {
					push @{$spec_files{$name}{$version}{errors}}, sprintf(
						"Unable to find spec URL for %s for version %s",
						$name, $version
					);
					next;
				}
				unless ($release->{spec_tarball}) {
					my ($tarball, $err) = _get_spec_tarball($release, $spec_dir);
					if ($err) {
						push @{$spec_files{$name}{$version}{errors}}, $err;
						next;
					}
					$release->{spec_tarball} = $tarball;
				}

				# Fetch and extract the job specs from the tarball
				my $tar = Archive::Tar->new(
					$release->{spec_tarball}, undef, {filter => qr{^[^\/]+/jobs/.*/spec(\.yml)?$}}
				);
				my $time = gettimeofday;

				my @filtered_rels = map {m{(.*)}} grep {!m{/}} @filters;
				my @filtered_jobs = in_array($name, @filtered_rels) ? () : map {m{$name/(.*)}} grep {m{$name/}} @filters;
				info("  - filtering job specs for %s", join(', ', @filtered_jobs))
					if (@filtered_jobs);

				info({pending => 1}, "  - extracting job specs.");
				my @files = $tar->list_files();
				for my $file (@files) {
					my $contents = $tar->get_content($file) or next;
					my ($job) = $file =~ m{^.*/jobs/([^/]+)/spec(\.yml)?$};
					next if @filtered_jobs && !in_array($job, @filtered_jobs);
					my $spec_file = "$workdir/$name/$version/$job.yml";
					mkdir_or_fail(dirname($spec_file)) unless -d dirname($spec_file);
					if (-f $spec_file) {
						my $old_contents = slurp($spec_file);
						if ($old_contents ne $contents) {
							push @{$spec_files{$name}{$version}{errors}}, sprintf(
								"Job spec has two different specs for job %s in version %s",
							);
						}
						next if $spec_files{$name}{$version}{jobs}{$job};
					}
					info({pending => 1}, ".");
					mkfile_or_fail($spec_file, 0444, $contents);
					$spec_files{$name}{$version}{jobs}{$job} = $spec_file;
				}
				info(" #G{done}".pretty_duration(gettimeofday-$time,2,5));
			}
		}
		info(
			"[[  - >>completed spec job retrieval ".
			pretty_duration(gettimeofday-$spec_time,0.5,2, '',' - ', 'Ki')
		);
	}

	# OUTPUT THE RESULTS
	if (@$removed) {
		output("\n#Ru{Removed Releases:}");
		for my $name (sort @$removed) {
			my @versions = sort keys %{$old_releases->{$name}};
			output("  - #c{%s} (%s)", $name, join(', ', sort @versions));
		}
	}

	if (keys %$unchanged) {
		output("\n#Gu{Unchanged Releases:}");
		for my $name (sort keys %$unchanged) {
			my @versions = reverse @{$unchanged->{$name}{common}};
			output("  - #c{%s} (%s)", $name, join(', ', sort @versions));
		}
	}

	if (@$added) {
		output("\n#Yu{Added Releases:}");
		for my $name (sort @$added) {
			my @versions = sort keys %{$new_releases->{$name}};
			output("  - #c{%s} (%s)", $name, join(', ', sort @versions));
		}
	}

	if (keys %$changed) {
		output("\n#yu{Changed Releases:}");
		for my $name (sort keys %$changed) {

			my $added = $changed->{$name}{added}[0];
			my $removed = $changed->{$name}{removed}[0];

			output("[[  - >>#c{%s} (%s -> %s)", $name, $removed, $added);
		}

		output("\n#Mu{Spec Changes in Changed Releases:}");
		for my $name (sort keys %$changed) {

			my $added_version = $changed->{$name}{added}[0];
			my $added_specs = $spec_files{$name}{$added_version};
			my @added_jobs = keys %{$added_specs->{jobs}//{}};
			my @added_errors = @{$added_specs->{errors}//[]};

			my $removed_version = $changed->{$name}{removed}[0];
			my $removed_specs = $spec_files{$name}{$removed_version};
			my @removed_jobs = keys %{$removed_specs->{jobs}//{}};
			my @removed_errors = @{$removed_specs->{errors}//[]};

			if (@added_errors || @removed_errors) {
				output(
					"\n[#m{%s}] Could not retrieve job specs %s - no comparison possible",
					$name, join(' or ', map {"v$_"} (@added_errors ? ($added_version) : (), @removed_errors ? ($removed_version) : ()))
				);
				next;
			}

			for my $job (uniq sort @added_jobs, @removed_jobs) {

				if (!$added_specs->{jobs}{$job}) {
					output(
						"\n[#m{%s/job/%s}] #Ri{Job removed in v%s}",
						$name, $job, $added_version
					);
				} elsif (!$removed_specs->{jobs}{$job}) {
					output(
						"\n[#m{%s/job/%s}] #Yi{Job added in v%s}",
						$name, $job, $added_version
					);
				}	else {
					my $added = $added_specs->{jobs}{$job};
					my $removed = $removed_specs->{jobs}{$job};
					my ($diff, $rc, $error) = run({interactive => 0},
						fake_tty(workdir('spec-diffs').'/diff', 'spruce', 'diff', $removed, $added)
					);
					if ($rc > 1) { # Error
						output(
							"\n[#m{%s/job/%s}] #Ri{Error comparing job spec between v%s and v%s - cannot compare:}\n\n#y{%s}",
							$name, $job, $removed_version, $added_version, $diff
						);
					} elsif ($diff eq '') {
						output(
							"\n[#m{%s/job/%s}] #Gi{Job spec is unchanged between v%s and v%s}",
							$name, $job, $removed_version, $added_version
						) if (get_options->{show_unchanged_jobs});
					} else {
						# for some reason, the output from script is utf-8 encoded, but
						# prints out as ascii
						utf8::decode($diff);
						$diff =~ s/\A\s+//;
						$diff =~ s/\s+\z//;
						output(
							"\n[#m{%s/job/%s}] #Yi{Job spec changes between v%s and v%s}:\n\n%s",
							$name, $job, $removed_version, $added_version, $diff
						);
					}
				}
			}
		}
	}


	# TODO: Calculate and display duplicate versions
	if (keys %$new_dup_versions) {
		output("\n#Yu{Multiple Release Versions:}");

		for my $dup (sort keys %$new_dup_versions) {
			my @new_dups = uniq sort map {keys %$_} @{$new_dup_versions->{$dup}};
			next unless @new_dups;

			my %dup_map = map {
				my $v = $_;
				my $files = [
					map {my @rels = (values(%{$_})); map {$_->{__src}} @rels}
					grep {in_array($v, keys(%$_))}
					@{$new_dup_versions->{$dup}}
				];
				($v => $files)

			} @new_dups;
			my $dup_msg = join("\n", map {
				csprintf(
					"[[    * #m{v%s} >>specified in %s",
					$_, sentence_join(map {"#c{$_}"} @{$dup_map{$_}})
				)
			} @new_dups)."\n";

			my @old_dups = uniq sort map {keys %$_} @{$old_dup_versions->{$dup}};
			my ($added_dups, $common_dups, $removed_dups) = compare_arrays(\@new_dups, \@old_dups);
			if (@$added_dups) {
				if (!@$common_dups) {
					output(
						"  - multiple versions of #y{%s} release referenced:\n%s",
						$dup, $dup_msg
					);
				} elsif (@old_dups) {
					output(
						"  - multiple versions of #y{%s} release referenced (previous version specified %s):\n%s",
						$dup, sentence_join((map {"#g{v$_}"} @$common_dups), (map {"#r{v$_}"} @$removed_dups)), $dup_msg
					);
				}
			} elsif (@new_dups) {
				if (!@$added_dups && !@$removed_dups) {
					output(
						"  - multiple versions of #y{%s} release referenced (same as previous version):\n%s",
						$dup, $dup_msg
					);
				} else {
					output(
						"  - multiple versions of #y{%s} release referenced (previous version also included %s):\n%s",
						$dup, sentence_join(map {"#r{v$_}"} @$removed_dups), $dup_msg
					);
				}
			}
		}
	} else {
		info("\n");
	}

	# TODO: Display details on unversioned releases

	success("Comparison complete.\n");

	exit 0;
}

sub _get_kit_releases {
	my ($kit, @filters) = @_;
	my $kit_path = $kit->path();
	my @new_spruce_files = grep {
		$_ !~ m{/(.git|spec)/} && /\.yml/
	} lines(run('grep', '-rl', '^releases', $kit_path));
	my @src_spruce_blocks = map {
		my ($out, $rc, $err) = run(
			'spruce', 'merge', '--skip-eval', '-m', '--go-patch', '--cherry-pick', 'releases', $_
		);
		if ($rc == 0 && $out =~ /\(\( concat/) {
			# Need to spruce merge the releases block
			$out = run(
				'spruce', 'merge',  $out
			);
		}
		my $yaml = scalar( load_yaml($out, $rc, $err));
		my $src = $_ =~ s{^$kit_path/}{}r;
		my @data = @{$yaml->{releases}//[]};
		map {{%{$_}, __src => $src, __type => 'merge'}} @data
	} @new_spruce_files;

	my @new_patch_files = grep {
		$_ !~ m{/.git/} && /\.yml/
	} lines(run('grep', '-rl', 'path:\s\+/releases', $kit_path));
	my @src_patch_blocks = map {
		my $src = $_ =~ s{^$kit_path/}{}r;
		trace("Loading patch file %s", $_);
		my $patch_data = slurp($_);
		my @results = ();
		for my $block (split(/---/, $patch_data)) {
			$block =~ s{\A\s+}{}; # remove leading whitespace
			next unless $block =~ m{^ *- }; # skip non patch blocks
			my $block = "data:\n$block";
			my $yaml = load_yaml($block)->{data};
			my @data = grep {
				$_->{path} =~ m{^/releases\??/} && $_->{type} eq 'replace'
			} @{$yaml//[]};

			push @results, (@data ? map {
				my $entry = $_;
				if (ref($entry->{value}) eq 'HASH') {
					scalar {%{$_->{value}}, __src => $src, __type => 'patch'}
				} else {
					my ($_name, $_prop) = $entry->{path} =~ m{^/releases\??/(name=)?([^=\/\?]+/?)/(.*)};
					if ($_prop eq 'version') {
						scalar {name => $_name, version => $entry->{value}, __src => $src, __type => 'patch'}
					} else {
						()
					}
				}
			} @data : ())
		}
		@results;
	} @new_patch_files;

	my $releases = {};
	my $release_versions = {};
	my $unversioned_releases = {};
	for my $release (@src_spruce_blocks, @src_patch_blocks) {
		if ($release->{name} && $release->{version}) {
			$releases->{$release->{name}}{$release->{version}} = $release;
			push @{$release_versions->{$release->{name}}}, {$release->{version} => $release};
		} else {
			push @{$unversioned_releases->{$release->{name}}}, $release;
		}
	}

	if (@filters) {
		my @release_filters = uniq sort map {$_ =~ m{^([^/]+)(?:/|$)}} @filters;
		info(
			"[[  - >>applying filters to limit releases to match %s",
			sentence_join(@release_filters)
		);
		my (undef, $filtered) = compare_arrays [keys %$releases], [@release_filters];
		$releases = {%{$releases}{@$filtered}};
		$release_versions = {%{$release_versions}{@$filtered}};
		$unversioned_releases = {%{$unversioned_releases}{@$filtered}};
	}

	my %duplicate_releases = map {
		($_ => $release_versions->{$_})
	} grep {
		scalar( uniq map {keys %$_} @{$release_versions->{$_}}) > 1
	} keys %$release_versions;

	return $releases, $release_versions, \%duplicate_releases;
}

sub _get_spec_url {
	my ($release) = @_;

	my ($name, $version, $url, $repo_map) = @{$release}{qw/name version url repo/};
	my $lookup = undef;
	if ($url =~ m{^https?://s3(-.*)?.amazonaws.com} || $url =~ m{^https?://storage.googleapis.com}) {
		$url = (map {$_->{repo}} grep {$_->{name} eq $name} @{$repo_map->{repos}})[0];
		if (!$url && (my $alt_repo_map = $release->{alt_repo})) {
			$url = (map {$_->{repo}} grep {$_->{name} eq $name} @{$alt_repo_map->{repos}})[0];
		}
	} elsif ($url =~ m{^https?://bosh.io}) {
		$url = $url =~ s{^.*d/}{https://}r =~ s{\?v=.*$}{}r;
	} elsif ($url =~ m{^https?://github.com}) {
		$url = $url =~ s{^.*http}{http}r =~ s{/releases/download/.*$}{}r;
	}
	return $url;
}
my %gh = ();
sub _get_spec_tarball {
	my ($release, $path) = @_;
	my ($name, $version, $spec_url) = @{$release}{qw/name version spec_url/};
	my ($org, $repo) = $release->{spec_url} =~ m{^https?://github.com/([^/]+)/([^/]+)};

	my $file = "$path/$org--$repo/$name-$version-src.tar.gz";
	mkdir_or_fail(dirname($file)) unless -d dirname($file);
	if (-f $file) {
		info("  - found cached job spec tarball for #M{%s/v%s}", $name, $version);
		return $file, undef;
	}

	# TODO: allow user to provide a cache dir where spec tarballs can be stored
	my $gh = $gh{$org} //= Service::Github->new(org => $org);
	my $time = gettimeofday;
	info({pending => 1},
		"[[  - >>retrieving #M{%s/v%s} release details from #c{%s/%s} ...",
		$name, $version, $org, $repo
	);
	my ($results, $errors) = $gh->get_release_info(
		$repo, versions => [$version],
		msg => undef,
		fatal => 0
	);
	if (@$errors && $errors->[0]{code} == 404) {
		# Can't find a release, it might just be a tag, so see if the tagged tarball exists
		# TODO: Maybe we should look for the tagged tarball first...?
		my $base_url = $gh->base_url;
		my $tag_urls = [
			map {
				sprintf("%s/repos/%s/%s/tarball/refs/tags/%s", $base_url, $org, $repo, $_)
			} ("v$version", $version)
		];

		for my $url (@$tag_urls) {
			my ($code, $msg, $data, $headers) = curl("HEAD", $url, undef, undef, 0, $gh->{creds});
			if ($code == 200) {
				$results = [{
					name => $name,
					version => $version,
					tarball_url => $url
				}];
				$errors = [];
				last;
			}
		}
	}

	if (@$errors) {
		info(" #R{failed}".pretty_duration(gettimeofday-$time, 0.5, 2));
	} else {
		info(" #G{done}".pretty_duration(gettimeofday-$time, 0.5, 2));
	}
	return (undef,
		"Failed to fetch release information for $name/v$version from $spec_url: ".
		join "\n", map {"  - $_->{msg}"} @$errors #FIXME: may want details instead of a message
	) if scalar(@$errors) > 0;


	# FIXME: need bettern notification of errors
	my $spec_tarball_url = $results->[0]{tarball_url};
	return (
		undef, "Failed to fetch job spec for $name v$version from $spec_tarball_url: no tarball URL found"
	) unless $spec_tarball_url;

	$time = gettimeofday;
	info({pending => 1}, "  - fetching source tarball for %s/v%s...", $name, $version);
	my ($code, $msg, $data) = curl("GET", $spec_tarball_url, undef, undef, 0, $gh->{creds});
	return (
		undef, "Failed to fetch job spec tarball for $name v$version from $spec_url: $msg"
	) unless $code == 200;
	mkfile_or_fail($file, 0444, $data);
	info(" #G{done}".pretty_duration(gettimeofday-$time,2,5));
	return $file, undef;
}

sub _decompile_kit {
	my ($top,$file,$dir) = @_;
	$dir ||= $top->path('dev');
	bail(
		"#C{%s} already exists, but does not appear to be a kit directory.\n".
		"Cowardly refusing to continue...",
		humanize_path($dir)
	) unless ! -e $dir || (-d $dir && -f "$dir/kit.yml");

	my ($out,$rc) = run("tar -ztf \"\$1\" | awk '{print \$NF}' | cut -d'/' -f1 | uniq", $file);
	bail(
		"#C{%s} does not look like a valid compiled kit",
		humanize_path($file)
	) unless $rc == 0 && scalar(split $/, $out) == 1;
	run(
		'rm -rf "$2" && mkdir -p "$2" && tar -xzf "$1" --strip-components=1 -C "$2"',
		$file, $dir
	);
}

1;
