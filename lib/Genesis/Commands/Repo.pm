package Genesis::Commands::Repo;

use strict;
use warnings;

use Genesis;
use Genesis::Commands;
use Genesis::Top;
use Genesis::Kit::Provider;

use Cwd qw/getcwd abs_path/;
use File::Basename qw/basename/;
use File::Path qw/rmtree/;
use JSON::PP qw/encode_json/;

sub init {
	my %options;
	# FIXME: The following might work, but it may need some tweaking as it used to
	# run before the regular option parser.
	Genesis::Kit::Provider->parse_opts(\@_, \%options);
	append_options(%options);
	%options = %{get_options()};

	command_usage(1) if @_ > 1; # name is now optional if kit specified

	my $abs_target;
	my $kit_desc = "";
	if ($options{'link-dev-kit'}) {
		command_usage(1,"Cannot specify both a kit (-k) and a link to a kit (-L)") if $options{kit};
		$abs_target = abs_path($options{'link-dev-kit'});
		my $pwd = getcwd;
		bail(
			"Link target '%s' cannot be found from $pwd!", $options{'link-dev-kit'}
		) unless $abs_target;
	}
	my $name = shift;
	my $kit_file;
	if (($options{kit}||'') =~ m#(?:.*/)?([^/]+)-\d+\.\d+\.\d+(?:-rc\.?\d+)?\.t(?:ar\.)?gz#) {
		bail (
			"Local compiled kit file %s not found", $options{kit}
		) unless -f $options{kit};
		$kit_file = $options{kit};
		$name = $1 unless $name;
	}

	unless ($name) {
		if ($options{kit} && ! $kit_file) {
			($name = $options{kit}) =~ s|/.*||;
		} elsif ($options{'link-dev-kit'}) {
			$name = basename($options{'link-dev-kit'});
		}
	}
	command_usage(1, "You must specify a deployment name if you don't specify a kit or a dev link target.\n")
		unless $name;

	if ($ENV{GIT_AUTHOR_NAME}) {
		$ENV{GIT_COMMITTER_NAME} ||= $ENV{GIT_AUTHOR_NAME};
	} else {
		run(
			{ onfailure => 'Please setup git: git config --global user.name "Your Name" -or- export GIT_AUTHOR_NAME="Your Name"' },
			'git config user.name'
		);
	}
	if ($ENV{GIT_AUTHOR_EMAIL}) {
		$ENV{GIT_COMMITTER_EMAIL} ||= $ENV{GIT_AUTHOR_EMAIL};
	} else {
		run(
			{ onfailure => 'Please setup git: git config --global user.email your@email.com -or- export GIT_AUTHOR_EMAIL=your@email.com' },
			'git config user.email'
		);
	}

	my $top = Genesis::Top->create('.', $name, %options);
	my $vault_desc = "\n - using default safe target for the system";
	if ($top->vault) {
		$vault_desc = "\n - using vault at #C{".$top->vault->url."}";
		$vault_desc .= " #Y{(insecure)}" unless $top->vault->tls;
		$vault_desc .= " #Y{(noverify)}" if $top->vault->tls && ! $top->vault->verify;
	}
	$top->embed($ENV{GENESIS_CALLBACK_BIN} || $0);

	my $root = $top->path;
	my $human_root = humanize_path($root);
	pushd($root);
	eval {
		if ($options{'link-dev-kit'}) {
			debug("Kit: linking dev to $abs_target");
			symlink_or_fail($abs_target, "./dev");
			$kit_desc = "\n - linked to kit at #C{$abs_target}.";

		} elsif ($kit_file) {
			debug("Kit: using local kit file $kit_file");
			my $target = $top->path(".genesis/kits");
			mkdir_or_fail($target);
			copy_or_fail($kit_file, $target);
			$kit_desc = "\n - using locally provided compiled kit #C{$kit_file}.";

		} elsif ($options{kit}) {
			debug("Kit: installing kit $options{kit}");
			my ($kit_name, $kit_version) = $top->download_kit($options{kit});
			$kit_desc = "\n - using the #C{$kit_name/$kit_version} kit.";

		} else {
			debug("Kit: creating empty ./dev kit directory");
			mkdir_or_fail("./dev");
			$kit_desc = "\n - with an empty development kit in #C{$human_root/dev}";
		}

		run({ onfailure => "Failed to initialize a git repository in $human_root/" },
			'git init && git add .');

		run({ onfailure => "Failed to commit initial Genesis repository in $human_root/" },
			'git commit -m "Initial Genesis Repo"');
	};
	my $err = $@;
	popd;
	if ($err) {
		debug("removing incomplete Genesis deployments repository at #C{$root} due to failed creation");
		rmtree $root;
		bail $err;
	}
	info "\nInitialized empty Genesis repository in #C{%s}%s%s\n", $human_root, $vault_desc, $kit_desc;
	exit 0;
}

sub secrets_provider {
	command_usage(1) if @_ > 1; # target is optional

	my %options = %{get_options(qw(interactive clear))};
	$options{target} = shift if scalar(@_);
	bail("You can only specify one of target, -i|--interactive or -c|--clear")
		if scalar(keys %options) > 1;

	my $ui_nl = $options{interactive} ? "" : "\n";

	# FIXME:  If the vault is set in config, but it is an invalid vault target,
	#         cannot fix with a call to genesis secrets-provider

	my $top = Genesis::Top->new('.');
	my $err;
	if (scalar(keys %options)) {
		$err = $top->set_vault(%options);
		error "$ui_nl$err\nCurrent vault was not changed.\n" if $err;
	}

	info("${ui_nl}Secrets provider for #C{%s} deployment at #M{%s}:", $top->type, $top->path);
	my %vault_info = $top->vault_status;
	if (%vault_info) {
		if ($vault_info{status} eq "unauthenticated") {
			eval {$top->vault->authenticate}; # Try to auto-authenticate
			%vault_info = $top->vault_status;
		}
		info(
			"         Type: #G{%s}\n".
			"          URL: #G{%s} %s\n".
			"  Local Alias: #%s{%s}\n".
			"       Status: #%s{%s}\n",
			"Safe/Vault", $vault_info{url}, $vault_info{security},
			$vault_info{alias_error} ? "R" : "G",
			$vault_info{alias} ? $vault_info{alias} : "$vault_info{alias_error}",
			$vault_info{status} eq "ok" ? "G" : "R",
			$vault_info{status}
		);
	} else {
		info "\n#Y{Not set - legacy mode enabled (will use current safe target on system)}\n";
	}

	exit defined($err) ? 1 : 0;
}

sub kit_provider {
	my %options;
	Genesis::Kit::Provider->parse_opts(\@_, \%options);
	%options = %{append_options(%options)};
	my $cfg_export = delete($options{'export-config'});
	bail "Option #M{--export-config} cannot be used with any other options"
		if ($cfg_export && scalar(keys(%options)));

  my $verbose = delete($options{verbose});
	if (delete($options{default})) {
		$options{'kit-provider'} = 'genesis-community';
	}
	command_usage(1) if @_ > 0;

	my $top = Genesis::Top->new('.');
	my $err;
	my $kit_provider_lookup = "current";
	if (scalar(grep {$_ =~ /^kit-provider/} keys %options)) {
		$err = $top->set_kit_provider(%options);
		if ($err) {
			error "\n#R{[ERROR]} Current kit provider was not changed - reason:\n\n$err\n";
			exit 1;
		}
		$kit_provider_lookup = "new";
	}

	if ($cfg_export) {
		output JSON::PP::encode_json({$top->kit_provider->config});
		exit 0
	}

	info(
		"\nCollecting information on %s kit provider for #C{%s} deployment at #M{%s}",
		$kit_provider_lookup, $top->type, humanize_path($top->path)
	);
	my %info;
	eval {
		%info = $top->kit_provider_info($verbose);
	};
	info("Complete.\n");

	bail "$@" if $@;

	info("         Type: #M{%s}\n", $info{type});
	info("%13s: #C{%s}", $_, $info{$_}) for (@{$info{extras} || []});
	info("\n       Status: #%s{%s}\n", $info{status} eq "ok" ? "G" : "R", $info{status});

	my $kit_list;
	if (ref($info{kits}) eq "HASH" && scalar(keys(%{$info{kits}}))) {
		my $width = (sort {$b <=> $a} map {length($_)} keys %{$info{kits}})[0];
		$kit_list = join("\n               ",
										 map {
											 sprintf("#%s{%-${width}s} [%s]", $_ eq $top->type ? 'G' : '-', $_, $info{kits}->{$_})
										} sort keys(%{$info{kits}})
								);
	} elsif (ref($info{kits}) eq "ARRAY" && scalar(@{$info{kits}})) {
		$kit_list = join("\n               ", map {sprintf("#%s{%s}", $_ eq $top->type ? 'G' : '-', $_)} @{$info{kits}});
	} elsif (ref($info{kits}) eq "" && ($info{kits} || "") =~ /^[1-9][0-9]*$/) {
		$kit_list = $info{kits} . "kit" . ($info{kits} == 1 ? "" : "s");
	} else {
		$kit_list = "#Yi{None}";
	}
	info("         Kits: %s\n\n", $kit_list) if $info{status} eq "ok";
}

1;
