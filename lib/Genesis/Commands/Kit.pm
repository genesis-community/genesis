package Genesis::Commands::Kit;

use strict;
use warnings;

use Genesis;
use Genesis::Term;
use Genesis::Commands;
use Genesis::Top;
use Genesis::Kit::Compiler;

use Cwd qw/getcwd/;

sub create_kit {
	my $name = get_options->{name};
	command_usage(2) unless defined($name);

	my $dir = abs_path(get_options->{dev} ? "dev" : "${name}-genesis-kit");
	Genesis::Kit::Compiler->new($dir)->scaffold($name);

	info("\n#G{Created new Genesis kit '}#C{$name}#G{' in }#C{$dir}");
}

sub compile_kit {
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
		if ($pwd =~ /\/([^\/]*)-deployments(\/)?$/) {
			# Building from dev/ inside a deployment repo - glean the name
			$options{name} = $1;
			$dir = "$pwd/dev";
			$options{dev} = 1;

		} elsif ($pwd =~ /\/([^\/]*)-genesis-kit(\/)?$/) {
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

	my $top = Genesis::Top->new('.');

	my (%kits, %latest);
	my %options = %{get_options()};
	$options{details} = $options{updates} unless defined $options{details};
	if ($options{remote}) {
		my @kit_names = ($name ? ($name) : $top->remote_kit_names($options{filter}));
		for my $kit (@kit_names) {
			my %versions;
			$versions{$_->{version}} = $_
				for ($top->remote_kit_versions($kit, latest=>$options{latest}, include_prereleases=>$options{prereleases}, include_drafts=>$options{drafts}));
			$kits{$kit} = \%versions;
		}

	} elsif ($options{updates}) {
		my $available_kits = $top->local_kits;
		for my $k (keys %$available_kits) {
			$kits{$k} = {};
			$latest{$k} = (reverse sort by_semver keys(%{$available_kits->{$k}}))[0];
			my %versions;
			$versions{$_->{version}} = $_
				for ($top->remote_kit_versions($k, latest=>$options{latest}, include_prereleases=>$options{prereleases}, include_drafts=>$options{drafts}));
			for my $v (reverse sort by_semver keys(%versions)) {
				last if $latest{$k} && by_semver($v,$latest{$k}) < 1;
				$kits{$k}{$v} = $versions{$v};
			}
		}

	} else {
		my $available_kits = $top->local_kits;
		for my $k (keys %$available_kits) {
			next if $name && $name ne $k;
			$kits{$k} ||= {};
			my @versions = keys %{$available_kits->{$k}};
			@versions = reverse grep {$_} (reverse sort by_semver @versions)[0..(($options{latest} || 1)-1)]
				if defined $options{latest};
			$kits{$k}{$_} = {} for (@versions); # local kits don't have details - TODO: Package them with release notes
		}
	}

	if (keys %kits) {
		my $out = '';
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
				my $c = ($version =~ /[\.-]rc[\.-]?(\d+)$/) ? "Y"
				: ($kits{$kit}{$version}{prerelease} ? "y" : "G");
				my $d = "";
				if ($kits{$kit}{$version}{date} && $options{details}) {
					$d = "Published ".$kits{$kit}{$version}{date};
					$d .= " - \e[3mPre-release\e[0m"
					if $kits{$kit}{$version}{prerelease};
					$d = " ($d)";
				}
				$out .= sprintf("  #%s{v%s%s}\n", $c, $version, $d);
				if ($kits{$kit}{$version}{body} && $options{details}) {
					$out .= "    Release Notes:\n";
					$out .= "      $_\n" for split $/, $kits{$kit}{$version}{body};
					$out .= "\n";
				}
			}
			$out .= "\n";
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
