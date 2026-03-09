package Genesis::Top;
use v5.20;
use warnings;

use base 'Genesis::Base';

use Genesis;
use Genesis::State;
use Genesis::Term qw/in_controlling_terminal csprintf decolorize/;
use Genesis::UI qw/prompt_for_boolean prompt_for_choice/;
use Genesis::Env;
use Genesis::Kit::Compiled;
use Genesis::Kit::Dev;
use Genesis::Kit::Provider;
use Service::Vault::Remote;
use Service::Vault::None;
use Genesis::Config;

use Cwd ();
use File::Path qw/rmtree/;

### Class Methods {{{

# _build - common construction logic for bare Genesis::Top object {{{
sub _build {
	my ($class, $root, %opts) = @_;
	my $self = bless({ root => Cwd::abs_path($root) }, $class);

	$ENV{GENESIS_ROOT}=$self->path();

	if ($opts{no_vault}) {
		debug "Top for $ENV{GENESIS_ROOT} requested with no vault support";
		$self->_set_memo('__vault', Service::Vault::None->new());
		return $self;
	}

	if ($opts{vault}) {
		# TODO: #ADDVAULT
		# if ($opts{env}) {
		#   $top->add_vault($opts{vault},$opts{env})
		# } else {
		debug ("Overriding vault %s with user specified %s for this session", $self->vault->name, $opts{vault})
			if $self->has_vault;
		$self->set_vault(target => $opts{vault}, session_only => 1);
		#}
	}

	return $self;
}

# }}}
# _set_vault_env - helper to set vault environment variables {{{
sub _set_vault_env {
	my ($self, %opts) = @_;

	if ($self->vault(silent => $opts{silent_vault_check}, no_vault => $opts{allow_no_vault})) {
		$ENV{GENESIS_TARGET_VAULT} = $ENV{SAFE_TARGET} = $self->vault->name;
	} elsif (!$ENV{GENESIS_NO_VAULT}) {
		debug {label => "WARNING"}, "Could not find any #M{safe} target.  This may cause consequences later on";
	}

	return $self;
}

# }}}
# new - returns a new Genesis::Top Repository object {{{
sub new {
	my $class = shift;

	# If args are odd, assume root wasn't given and default it to '.'
	my $root = @_ % 2 == 1 ? shift @_ : '.';
	my %opts = @_;

	# Validate that this is a proper Genesis repository
	bail("'$root' is not a Genesis deployment repository")
		unless $class->is_repo($root);

	# Build the base object
	my $self = $class->_build($root, %opts);

	# Initialize vault connection and set environment variables
	$self->_set_vault_env(%opts);

	return $self;
}

# }}}
# create - create a new Genesis repository at the specified location {{{
sub create {
	my ($class, $path, $name, %opts) = @_;
	debug("creating a new Genesis deployments repository named '$name' at $path...");

	# TODO: $opts{kit} does get passed in, and future versions will only allow one kit type per deployment
	# Need to determine how this gets added to the configuration and how it impacts the current use of deployment type
	# Probably becomes deployment-name and kit becomes the type (or drop type and use kit)

	$name =~ s/-deployments?//;
	bail(
		"Invalid Genesis deployment repository name '$name'"
	) unless $name =~ m/^[a-z][a-z0-9_-]+$/;

	debug("generating a new Genesis repo, named $name");

	my $dir = $opts{directory} || "${name}".(
		$Genesis::RC->get('legacy_repo_suffix') ? "-deployments" : ""
	);
	bail(
		"Repository directory name must only contain alpha-numeric characters, periods, hyphens and underscores"
	) if $dir =~ /([^\w\.-])/;

	$path .= "/$dir";
	bail(
		"Cannot create new deployments repository `$dir': already exists!"
	) if -e $path;

	# Build the bare object (path doesn't exist yet, so can't use new())
	my $self = $class->_build($path, %opts);
	$self->mkdir(".genesis");

	$self->{__kit_provider} = Genesis::Kit::Provider->init(%opts);
	# Override vault if specified (will be saved to config later)
	$self->{__vault} = Service::Vault::Remote->target($opts{vault}) if $opts{vault};
	my $kits_path = '';
	if ($kits_path = $opts{kits_path}) {
		$kits_path = expand_path($kits_path);
		my $rel_path = humanize_path($kits_path, base_dir => $self->path());
		if ($rel_path !~ m#^/#) {
			debug("Kit: using relative path $rel_path for kits path");
			$kits_path = $rel_path;
		} else {
			debug("Kit: using absolute path $kits_path for kits");
			my $home_parent_dir = dirname($ENV{HOME});
			$kits_path =~ s{^$ENV{HOME}/}{~/};
			$kits_path =~ s{^$home_parent_dir/}{~};
		}
	}

	eval { # to delete path if creation fails

		# Write new configuration - Set defaults
		$self->config->set('deployment_type',$name);
		$self->config->set('version',2);
		$self->config->set('creator_version', $Genesis::VERSION);
		$self->config->set('minimum_version', $Genesis::VERSION) unless $Genesis::VERSION eq '(development)';
		$self->config->set('manifest_store', 'exodus');
		$self->config->set('kits_path', $kits_path) if $kits_path;

		# Apply any config overrides from %opts
		for my $override (grep {exists $opts{$_}} qw(creator_version updater_version minimum_version manifest_store)) {
			if (defined $opts{$override}) {
				$self->config->set($override, $opts{$override});
			} else {
				$self->config->clear($override);
			}
		}

		# Only set vault configuration if not using no_vault (and only allow no_vault in tests)
		if ($opts{no_vault}) {
			bail("no_vault option can only be used in test contexts")
				if $ENV{GENESIS_COMMAND};
		} else {
			$self->config->set('secrets_provider', {
				url       => $self->vault->url,
				insecure  => $self->vault->verify    ? Genesis::Config::FALSE : Genesis::Config::TRUE,
				namespace => $self->vault->namespace,
				strongbox => $self->vault->strongbox ? Genesis::Config::TRUE  : Genesis::Config::FALSE,
				alias     => $self->vault->name
			});
		}

		$self->config->set('kit_provider', $self->kit_provider->config)
			unless ref($self->kit_provider) eq "Genesis::Kit::Provider::GenesisCommunity";

		$self->_validate_config;
		$self->config->save;
		my $kits_path = $self->local_kits_path;
		# FIXME: Should we prompt the user to confirm if outside the repo parent dir or ~/.genesis?
		mkdir_or_fail($kits_path) unless -d $kits_path;

		$self->mkfile("README.md", # {{{
<<EOF);
$name deployments
==============================

This repository contains the YAML templates that make up a series of
$name BOSH deployments, using the format prescribed by the
[Genesis][1] utility. These deployments are based off of the
[$name-genesis-kit][2].

Environment Naming
------------------

Each environment managed by this repository will have its own
deployment file, e.g. `us-east-prod.yml`. However, in many cases,
it can be desirable to share param configurations, or kit configurations
across all of the environments, or specific subsets. Genesis supports
this by splitting environment names based on hyphens (`-`), and finding
files with common prefixes to include in the final manifest.

For example, let's look at a scenario where there are three environments
deployed by genesis: `us-west-prod.yml`, `us-east-prod.yml`, and `us-east-dev.yml`.
If there were configurations that should be shared by all environments,
they should go in `us.yml`. Configurations shared by `us-east-dev` and `us-east-prod`
would go in `us-east.yml`.

To see what files are currently in play for an environment, you can run
`genesis <environment-name>`

Quickstart
----------

To create a new environment (called `us-east-prod`):

    genesis create us-east-prod

To edit an environment file:

    genesis us-east-prod edit

To edit without opening the kit manual:

    genesis us-east-prod edit --no-manual

To use a specific editor command:

    genesis us-east-prod edit --editor "code --wait"
    genesis us-east-prod edit --editor "grep '<feature>'" # it doesn't have to be an editor

To build the full BOSH manifest for an environment:

    genesis us-east-prod manifest

... and then deploy it:

    genesis us-east-prod deploy

To deploy and automatically fix any missing requirements (secrets, stemcells, etc.):

    genesis us-east-prod deploy -F

The `-F` flag tells Genesis to automatically generate any missing secrets,
upload required stemcells, and handle other deployment prerequisites.

To rotate credentials for an environment:

    genesis us-east-prod rotate-secrets
    genesis us-east-prod deploy

To check for missing or invalid secrets:

    genesis us-east-prod check-secrets

To manage secrets provider for the environments in this repo, select from known safe targets:

    genesis secrets-provider -i

... or clear it to use safe's currently targeted vault:

    genesis secrets-provider --clear

By default, the provider for kits is the Genesis Community at
https://github.com/genesis-community, but you can set this to another
provider url via the `genesis kit-provider` command:

    genesis kit-provider https://github.mycorp.com/mygenesiskits

This requires that url to provide releases in the same manner as GitHub does.
You can see the current kit provider by calling it with no argument, or revert
back to default with the `--default` option.

To check for kit updates and download new versions:

    genesis list-kits --updates
    genesis fetch-kit $name [version]  # omitting version downloads the latest

To update an environment to use a new kit version:

    # Edit the environment file to specify the new kit version
    vi us-east-prod.yml

    # Then deploy the updated environment
    genesis us-east-prod deploy

Environment Management
----------------------

Genesis provides several commands for managing environments:

- `genesis <env> info` - Show environment details and configuration
- `genesis <env> check` - Validate environment configuration and run checks
- `genesis <env> edit` - Edit the environment file in your default editor
- `genesis <env> deploy` - Deploy the environment to BOSH
- `genesis <env> deploy -F` - Deploy with automatic prerequisite handling
- `genesis <env> secrets` - List available secrets for the environment
- `genesis <env> check-secrets` - Check for missing certificates and credentials
- `genesis <env> add-secrets` - Generate missing certificates and credentials
- `genesis <env> rotate-secrets` - Regenerate secrets for the environment
- `genesis <env> remove-secrets` - Remove certificates and credentials
- `genesis <env> bosh <cmd>` - Run BOSH commands against the environment
- `genesis <env> credhub <cmd>` - Run Credhub commands against the environment
- `genesis <env> do <task>` - Run kit-specific addon tasks
- `genesis <env> logs` - Fetch logs from the BOSH director
- `genesis <env> terminate` - Terminate the environment on the BOSH director

Match-Mode Environment Selection
--------------------------------

Genesis supports match-mode selection using @-notation, which allows you to
work with environments without being in their repository directory. This is
especially useful when managing multiple repositories.

To set up match-mode selection, configure deployment roots in your global
Genesis configuration file `\$HOME/.genesis/config`:

    ---
    deployment_roots_map:
      ops: /path/to/root/of/ops/deployments
      test: /path/to/root/of/test/deployments

This allows you to run commands like:

  See the contents without changin the directory:
    genesis \@dev:cf edit --editor "cat"

  Not specifying the type defaults to bosh kit
    genesis \@prod info

  Targets the vault repository under the deployment roots map:
    genesis \@:v secrets-provider --interactive

The \@-notation supports several patterns:

- `\@<env-pattern>` - Match bosh environments by name pattern
- `\@<env-pattern>:<deployment-pattern>` - Match environments within specific deployment types
- `\@*:<deployment-pattern>` - Match any environment within deployment types matching the pattern
- `\@:<deployment-pattern>` - Match the repo within the specified deployment type

The patterns can be incomplete glob patterns, and can additonally use `^` and
`\$` to anchor the start and end of the name. If in a controlling terminal, you
will be presented with a list of matching environments to choose from if the
match is not unique.

The `--editor` option is particularly useful with match-mode, as it allows you
to interact with the environment files without changing directories:

    genesis \@dev:cf edit --editor "code --wait --new-window"
    genesis \@prod:vault edit --editor "emacs"
    genesis \@aws-east1:jumpbox edit # Defaults to your \$EDITOR

Deployment Options
------------------

The `genesis deploy` command supports several useful flags:

- `-F` - Automatically fix missing requirements (secrets, stemcells, releases)
- `-y` - Skip confirmation prompts and deploy automatically
- `-n` - Dry-run mode (show what would be deployed without actually deploying)
- `--redact` - Show redacted manifest during deployment process

For example, to deploy an environment with automatic fixes and no prompts:

    genesis us-east-prod deploy -F -y

Secrets Management
------------------

Genesis integrates with Vault for secrets management. Each environment
can have its own secrets path, and Genesis provides tools for:

- Generating and rotating secrets automatically
- Validating secret requirements
- Supporting both Vault and Credhub backends
- Tracking secret changes and dependencies

To configure the secrets provider, use the interactive selection:

    genesis secrets-provider -i

This will show you a list of known safe targets and allow you to select
the appropriate one for your environment.

To clear the secrets provider and use safe's currently targeted vault:

    genesis secrets-provider --clear

This resets the secrets provider to use whatever vault `safe` is currently
targeting, which is useful when switching between different vault instances
or when you want to use your default safe configuration.

Kit Features
------------

The $name kit supports various features that can be enabled in your
environment files. Common features include:

- IaaS-specific configurations (aws, azure, gcp, vsphere, etc.)
- Scaling options (small-footprint, ha, etc.)
- Integration features (external databases, load balancers, etc.)

Check the kit documentation for a complete list of available features
and their requirements:

    genesis kit-manual $name

Repository Structure
--------------------

Most of the deployment configuration happens at the base level.
Environment YAML files and shared YAML files are stored here.

The `.genesis/` directory contains:

- `config` - Repository configuration and metadata
- `kits/` - Downloaded and compiled kits
- `manifests/` - Deployed manifest archives (if enabled)
- `bin/` - Embedded Genesis binary for CI/CD (if present)

Environment files can be organized hierarchically using hyphens in names,
allowing shared configuration across related environments.

Development and Testing
-----------------------

For kit development, you can use a local development kit:

    genesis create-kit --dev --name $name

This creates a `dev/` directory with an uncompiled kit for testing
changes before release.

You can also decompile an existing kit for modification:

    genesis decompile-kit $name/version

To build a distributable kit from your dev directory:

    genesis build-kit

Information and Debugging
-------------------------

Genesis provides several commands for inspecting environments:

- `genesis <env> yamls` - List YAML files used for the environment
- `genesis <env> lookup <key>` - Look up values from environment files or manifests
- `genesis <env> vault-paths` - List vault paths used by the environment
- `genesis environments` - List all environments in known repositories

Kit Management
--------------

Genesis provides commands for managing kits:

- `genesis list-kits` - List available local kits
- `genesis list-kits --remote` - List available remote kits
- `genesis list-kits --updates` - Check for kit updates
- `genesis fetch-kit <name>` - Download a kit from the provider
- `genesis compare-kits` - Compare two kit versions

Getting Help
------------

Genesis provides comprehensive built-in help for all commands and options:

### General Help

Get an overview of all available commands:

    genesis help

Show the Genesis version and build information:

    genesis version

### Command-Specific Help

Get detailed help for any command by adding `help` after the command:

    genesis help <command>

This is synonymous with `genesis <command> --help` and provides detailed
information about the command's usage, options, and examples.

To get a list of available commands, you can use:

    genesis help

### Addon Task Help

List available addon tasks for an environment:

    genesis <env> do list

Get help for a specific addon task:

    genesis <env> do <task> --help

### Command Synopsis

Most commands support `--help` or `-h` flags for quick reference:

    genesis deploy --help
    genesis secrets --help
    genesis edit --help

The help system shows:
- Command syntax and usage patterns
- Available options and flags
- Examples of common usage scenarios
- Related commands and cross-references

### Kit Documentation

Access kit-specific documentation and manual pages:

		genesis kit-manual <kit-name>

This opens the kit's documentation in your default pager, showing:
- Available features and their descriptions
- Configuration parameters and their usage
- Examples and best practices

This file is opened automatically when you run `genesis <env> edit` and placed
in a side-by-side split with the environment file for easy reference, if you're
\$EDITOR is `code`, `emacs`, or `vim` (gvim, mvim, nvim are also supported).

Helpful Links
-------------

- [$name Genesis Kit][2] - Kit documentation, features, and parameters
- [Genesis Documentation][3] - Complete Genesis user guide
- [Genesis Community][4] - Community kits and support

[1]: https://github.com/genesis-community/genesis
[2]: https://github.com/genesis-community/$name-genesis-kit
[3]: https://github.com/genesis-community/genesis/tree/master/docs
[4]: https://github.com/genesis-community
EOF

# }}}

	};
	if (my $err = $@) {
		debug("removing incomplete Genesis deployments repository at #C{$path} due to failed creation");
		rmtree $path;
		die $err;
	}

	# Initialize vault connection and set environment variables
	$self->_set_vault_env(%opts);

	return $self;
}

# }}}
# search_for_repo_path - search for an deployment repository path in known deployment root(s) {{{
sub search_for_repo_path {
	my ($class, $deployment, %opts) = @_;
	my $label = "\@:$deployment";

	# Process and validate options
	my $return_all = delete($opts{all_paths}) // 0;
	bug(
		"Invalid option specified to search_for_repo_path: %s",
		join(", ", keys %opts)
	) if scalar(keys %opts) > 0;

	my ($root_labels, $root_map) = Genesis::deployment_roots_map(
		['@current', $ENV{GENESIS_ORIGINATING_DIR}],
		['@parent', Cwd::abs_path(Genesis::expand_path($ENV{GENESIS_ORIGINATING_DIR}.'/..'))],
	);

	$deployment = "*$deployment*" =~ s/\*\^//r =~ s/\$\*//r if defined($deployment) && $deployment ne '*';

	my %path_map = ();
	for my $root_label (@$root_labels) {
		my $root = $root_map->{$root_label};
		my @deployments = map {s{/\.genesis/config$}{}r} grep {-f $_}
			glob("$root/".($deployment//'*')."/.genesis/config"); # Only include genesis repos
		next unless @deployments;
		$path_map{$root_label} = [@deployments];
	}

	# Order the files by current directory, then by the order of the deployment
	# roots specified in the .genesis/config file, then bosh first, followed by
	# any other deployments in alphabetical order.
	my @paths = ();
	for my $root_label (uniq ('@current', '@parent', @$root_labels)) {
		if ($path_map{$root_label}) {
			my $is_bosh= qr{/bosh(-deployments)?/?$};
			push(@paths,
				map {[$root_label, $_]}
				sort {
					($a =~ $is_bosh ? 0 : 1) <=> ($b =~ $is_bosh ? 0 : 1 ) || $a cmp $b
				} @{$path_map{$root_label}}
			);
		}
	}

	if (!@paths) {
		bail("No deployment repositories found matching #C{%s}", $label);

	} elsif (scalar(@paths) > 1) {
		my $last_section = '';
		my @path_labels = map {
			my ($section, $path) = @$_;
			$path =~ m{(?:(.*?)/)?([^/]*/?)$};
			my $fmt_label = csprintf("#c{%s}/", $2);
			if ($section ne $last_section) {
				$last_section = $section;
				my $fmt_section;
				my $target_path = $root_map->{$section} =~ s{^$ENV{HOME}/}{~/}r;
				my $is_current = $root_map->{$section} eq $ENV{GENESIS_ORIGINATING_DIR};
				my $flag = $ENV{GENESIS_NO_UTF8}
					? ''
					: $is_current ? "\x{1F4C2} " : "\x{1F4C1} ";
				if ($section eq '@current') {
					$fmt_section = csprintf("#Gu{%sCurrent Directory:} #Ki{%s}", $flag, $target_path);
				} elsif ($section eq '@parent') {
					$fmt_section = csprintf("#Yu{%sParent Directory:} #Ki{%s}", $flag, $target_path);
				} elsif ($section ne $root_map->{$section}) {
					my $is_current = $root_map->{$section} eq $ENV{GENESIS_ORIGINATING_DIR};
					$fmt_section = csprintf("#%su{%sDeployment Root '%s':} #Ki{%s}", $is_current ? 'g' : 'B', $flag, $section, $target_path);
				} else {
					$fmt_section = csprintf("#Bu{%sDeployment Root:} #Ki{%s}", $flag, $target_path);
				}
				("---$fmt_section---", [$fmt_label, csprintf("#C{%s}", humanize_path($root_map->{$section}, absolute => 1))."/$fmt_label"])
			} else {
				[$fmt_label, csprintf("#C{%s}", humanize_path($root_map->{$section}, absolute => 1))."/$fmt_label"]
			}
		} @paths;
		bail(
			"Ambiguous deployment repository name: #C{%s} matches multiple paths:\n  -#\@{_}%s\n\n".
			"Please refine your match criteria.",
			$label, join("\n  -#\@{_}", map {$_->[1]} grep {ref($_) eq 'ARRAY'} @path_labels)
		) unless in_controlling_terminal || $return_all;

		return @paths if $return_all;

		my $selected_path = prompt_for_choice(
			csprintf(
				"Multiple deployment repositories found matching #C{$label}:"
			),
			[@paths, ['none']],
			$paths[0],
			[ @path_labels, '---', csprintf('#R{%s of these - cancel}', scalar(@paths) == 2 ? 'Neither' : "None") ],
			undef,
			"the desired deployment repository path"
		);
		output({stderr=>1}, "");
		bail("No deployment repository path selected.") if $selected_path->[0] eq 'none';
		$paths[0] = $selected_path;
	}
	$paths[0][1] =~ m{(?:(.*?)/)?([^/]+)/?$};
	my $deployment_root = $1;
	return ($deployment_root, $paths[0][1]);
}
# }}}
# is_repo - returns true if the specified path is a Genesis deployment repository {{{
sub is_repo {
	my ($class, $path) = @_;
	return -d "$path/.genesis" && -f "$path/.genesis/config" && slurp("$path/.genesis/config") =~ /deployment_type:/;
}
# }}}

### Instance Methods

# Kit Provider handling
# kit_provider - return the kit provider for the Top object {{{
sub kit_provider {
	my $ref = $_[0]->_memoize(sub {
		my ($self) = @_;
		return Genesis::Kit::Provider->new(%{$self->config->get("kit_provider", {})});
	});
	return $ref;
}

# }}}
# set_kit_provider - set the kit provider {{{
sub set_kit_provider {

	my ($self, %opts) = @_;
	my $new_provider;

	# TODO: If needed, provide an interactive wizard to enter provider type and details
	#	if ($opts{interactive}) {
	#		$new_provider = Genesis::Kit::Provider->target(undef);
	#	} else ...
	eval {
		info {pending => 1}, "\nSetting up new kit provider...";
		$new_provider = Genesis::Kit::Provider->init(%opts);
		info "done.";
		info {pending => 1}, "Writing configuration...";
		$self->{__kit_provider} = $new_provider;
		if (ref($self->kit_provider) eq "Genesis::Kit::Provider::GenesisCommunity") {
			$self->config->clear('kit_provider');
		} else {
			$self->config->set('kit_provider', $self->kit_provider->config);
		}
		$self->config->set('updater_version', $Genesis::VERSION) if $self->config->exists();
		$self->_validate_config;
		$self->config->save;
		info "done.";
	};
	return $@;
}

# }}}
# kit_provider_info - return that status of the kit provider {{{
sub kit_provider_info {
	my $self = shift;
	$self->kit_provider->status(@_);
}

# }}}

# Secrets provider handling
# vault - initialize connectivity to the vault specified by the secrets provider {{{
sub vault {
	my ($self, %opts) = @_;
	my $ref = $self->_memoize(sub {
		return Service::Vault::None->new() if ($ENV{GENESIS_NO_VAULT});
		my ($self) = @_;
		if (in_callback && $ENV{GENESIS_TARGET_VAULT}) {
			return Service::Vault::Remote->rebind();
		} elsif ($self->has_vault) {
			my $namespace =  $self->config->get("secrets_provider.namespace");
			my $strongbox = $self->config->get("secrets_provider.strongbox");
			my %attach_opts = (
				url      => $self->config->get("secrets_provider.url"),
				verify   => $self->config->get("secrets_provider.insecure") ? 0 : 1,
				silent   => $opts{silent},
				no_vault => $opts{no_vault}
			);
			$attach_opts{namespace} = $namespace if defined($namespace);
			$attach_opts{strongbox} = ($strongbox ? 1: 0) if defined($strongbox);
			my $vault = Service::Vault::Remote->attach(%attach_opts);
			$vault = Service::Vault::None->new() if (!$vault && $opts{no_vault});
			return $vault;
		} else {
			my $vault = Service::Vault::default;
			$vault->connect_and_validate($opts{silent})->ref_by_name() if $vault;
			return $vault;
		}
	});
	return $ref;
}

# }}}
# repo_vault - returns the repository vault if specified in config, or env vault otherwise {{{
# TODO: examine how this can work with multiple vaults (#ADDVAULT)
sub repo_vault {
	my $self = shift;
	return Service::Vault::default unless $self->has_vault();
	my $namespace = $self->config->get("secrets_provider.namespace");
	my $strongbox = $self->config->get("secrets_provider.strongbox");
	my %opts = (
		url    => $self->config->get("secrets_provider.url"),
		verify => $self->config->get("secrets_provider.insecure") ? 0 : 1,
	);
	$opts{namespace} = $namespace if defined($namespace);
	$opts{strongbox} = ($strongbox ? 1 : 0) if defined($strongbox);
	return Service::Vault::Remote->attach(%opts);
}

# }}}
# has_vault - returns true if the configuration has a vault defined {{{
sub has_vault {
	my ($self) = @_;
	defined($self->config->get("secrets_provider")) && ref($self->config->get("secrets_provider")) eq 'HASH' && scalar(keys %{$self->config->get("secrets_provider")}) > 0;
}

# }}}
# set_vault - set the secret provider to the specified vault. {{{
sub set_vault {
	my ($self,%opts) = @_;
	my $new_vault;
	if ($opts{interactive}) {
		my $current_vault = $self->config->get("secrets_provider");
		if ($current_vault) {
			$current_vault = (Service::Vault->find_by_target($current_vault->{url}))[0];
		}
		$new_vault = Service::Vault::Remote->target(undef, default_vault => $current_vault);
	} elsif (exists($opts{target})) {
		# TODO: allow the creation of a new safe target by parsing target string (#BETTERVAULTTARGET)
		my @candidates = Service::Vault->find_by_target($opts{target});
		return "#R{[Error]} No vault found that matches $opts{target}." unless @candidates;
		return "#R{[Error]} Target $opts{target} has URL that is not unique across the known vaults on this system."
			if scalar(@candidates) > 1;
		$new_vault = $candidates[0];
	} elsif ($opts{clear}) {
		$new_vault = undef;
	} elsif (ref($opts{vault}) eq "Service::Vault::Remote") {
		$new_vault = $opts{vault}
	} else {
		bug "Invalid call to Genesis::Top->set_vault"
	}
	$self->{__vault} = $new_vault;
	return if $opts{session_only};

	if ($new_vault) {
		$self->config->set('secrets_provider', {
			url       => $new_vault->url,
			insecure  => $new_vault->verify    ? Genesis::Config::FALSE : Genesis::Config::TRUE,
			strongbox => $new_vault->strongbox ? Genesis::Config::TRUE  : Genesis::Config::FALSE,
			namespace => $new_vault->namespace,
			alias     => $new_vault->name
		});
		$self->config->set('updater_version', $Genesis::VERSION) if $self->config->exists();
		$self->_validate_config;
		$self->config->save;
	} else {
		$self->config->clear('secrets_provider',1);
	}
	return;
}

# }}}
# add_vault - TODO: #ADDVAULT add ability to support multiple vaults, default, base and per env {{{
sub add_vault {
}
# }}}
# vault_status - get the status for the associated secret-provider vault {{{
sub vault_status {
	my ($self) = @_;
	return () unless $self->has_vault;

	my $info = $self->config->get("secrets_provider");
	$info->{security} = ($info->{url} =~ /^https/)
		? ($info->{insecure} ? "#Y{(noverify)}" : "")
		: "#Y{(insecure)}";

	my @candidates = Service::Vault->find(url => $info->{url});
	if (! scalar(@candidates)) {
		$info->{alias_error} = "No alias for this URL found on local system";
		$info->{status} = qq(Run 'safe target "$info->{url}" "}#Ri{<alias>}#R{") . ($info->{insecure} ? " -k" : "") . "' to create an alias for this URL";
		return %$info;
	}

	if (scalar(@candidates) > 1) {
		$info->{alias_error} = "Multiple aliases for this URL found on local system";
		$info->{status} = "Remove all but one of the following safe targets: ".join(", ", map {$_->{name}} @candidates);
		return %$info;
	}

	my $vault = $candidates[0];
	local $ENV{QUIET} = 1;
	$info->{alias} = $vault->name;
	$info->{status} = $vault->status;
	return %$info;
}

# }}}
# get_ancestral_vault {{{
sub get_ancestral_vault {
	my ($self, $env) = @_;
	return Genesis::Env->new(name=>$env, top=>$self)->get_ancestral_vault();
}

sub reset_vault {
	my $self = shift;
	my $no_vault = defined($_[0]) && $_[0] eq 'no-vault';

	$self->_clear_memo('__vault');
	$ENV{GENESIS_NO_VAULT}=($no_vault ? '1' : '')
}

# }}}

# Repository management
# link_dev_kit - build a symbolic link to the specified path as a dev kit {{{
sub link_dev_kit {
	my ($self, $path) = @_;
	debug("linking dev kit '$path'");
	my $abs = Cwd::abs_path($path)
		or die "Unable to locate $path from ".Cwd::getcwd."\n";

	my $dev = $self->path('dev');
	unlink($dev) if -l $dev; # overwrite the link
	die "dev/ already exists, and is not a symbolic link\n"
		if -e $dev;

	symlink_or_fail($abs, $dev);
	return $self;
}

# }}}
# embed - embed the current version of genesis in the repository for CI pipeline usage {{{
sub embed {
	my ($self, $bin) = @_;
	debug("embedding `genesis' binary installed at $bin...");

	$self->mkdir(".genesis/bin");
	copy_or_fail(Cwd::abs_path($bin), $self->path(".genesis/bin/genesis"));
	chmod_or_fail(0755, $self->path(".genesis/bin/genesis"));
	return 1;
}

# }}}
# path - return the path of the repo, or absolute path of the specified relative path {{{
sub path {
	my ($self, $relative) = @_;
	return $relative ? "$self->{root}/$relative"
	                 :  $self->{root};
}

# }}}
# mkfile - make a file with the given content relative to the root of the repo {{{
sub mkfile {
	my ($self, $file, @rest) = @_;
	mkfile_or_fail($self->path($file), @rest);
}

# }}}
# mkdir - make a directory relative to the root of the repo {{{
sub mkdir {
	my ($self, $dir, @rest) = @_;
	mkdir_or_fail($self->path($dir), @rest);
}

# }}}
# config - read the configuration of the repo {{{
sub config {
	my ($self) = @_;
	return $self->{__config} if defined($self->{__config});
	my $ref = $self->_memoize(sub {
		my ($self) = @_;
		return Genesis::Config->new($self->path(".genesis/config"));
	});
	$self->_validate_config if -f $self->path(".genesis/config");
	return $ref;
}

# }}}
# type - return the deployment type {{{
sub type {
	my ($self) = @_;
	return $self->config->get("deployment_type");
}

# }}}
# version - return the version of the cofiguration schema {{{
sub version {
	my ($self) = @_;
	return $self->config->get("version") if ($self->config->get("version")||'') =~ /^\d+$/;
	return 1;
}

# }}}
# genesis_version - return the genesis version that initialized the repo {{{
sub genesis_version {
   my ($self) = @_;
	 return $self->config->get("creator_version") if $self->config->get("creator_version");
   return $self->config->get("genesis_version") if $self->config->get("genesis_version");
   return $self->config->get("version") if $self->config->get("version") !~ /^\d+$/;
   return "Unknown";
}
# }}}
# local_kits_path - return the path to the local kit directory {{{
sub local_kits_path {
	my ($self) = @_;

	# Check user config first (highest precedence)
	my $kits_path = expand_path(
		$Genesis::RC->get('kits_path') // $self->config->get('kits_path'),
		$self->path()
	);
}

# has_dev_kit - returns true if the repo has an embedded dev kit {{{
sub has_dev_kit {
	my ($self) = @_;
	return -d $self->path("dev");
}

# }}}

# Environment handling
# envs - return a list of the environments in the repo {{{
sub envs {
	my ($self) = @_;

	my $root_path = $self->path();
	my @envs;
	my @candidates =
		grep {! scalar(Genesis::Env::_env_name_errors($_))} # only pick envs with valid names
		map {s{^$root_path/}{}r}                            # strip the root path
		map {s{.yml$}{}r}                                   # strip the .yml extension
		glob($self->path("*.yml"));

	foreach my $env (@candidates) {
		# Use has_env to validate the environment (checks for genesis.env and kit info)
		next unless $self->has_env($env);
		push @envs, Genesis::Env->new(name => $env, top => $self);
	}
	return @envs;
}
# }}}
# load_env - return a Genesis::Env object for the specified environment in the repo {{{
sub load_env {
	my ($self, $name) = @_;
	$name =~ s/.yml$//;
	debug("loading environment #C{%s}", $name);

	# Check if environment exists and get validation errors if any
	my ($valid, @errors) = $self->has_env($name);
	if ($valid) {
		return Genesis::Env->load(top  => $self, name => $name);
	} elsif (in_callback() && $name eq $ENV{'GENESIS_ENVIRONMENT'}) {
		return Genesis::Env->from_envvars($self);
	} else {
		# If we have specific validation errors, use them; otherwise generic message
		if (@errors) {
			bail(join("\n\n", @errors));
		} else {
			bail(
				"Environment file #C{%s} does not exist%s",
				humanize_path($self->path($name.".yml")),
				-f $self->path(".genesis/config") ? '' : " - this does not appear to be a Genesis deployment directory!"
			);
		}
	}
}

# }}}
# has_env - returns true if the repo has an enviroment of the given name {{{
sub has_env {
	my ($self, $name) = @_;
	# Delegate to Genesis::Env for all validation logic
	# This ensures consistent validation behavior and DRY principle
	return Genesis::Env->is_valid_env_file($name, $self);
}

# }}}
# create_env - create a new environment of the given name in the repo {{{
sub create_env {
	my ($self, $name, $kit, %opts) = @_;
	debug("setting up new environment #C{%s}", $name);
	return Genesis::Env->create(
		%opts,
		top  => $self,
		name => $name,
		kit  => $kit,
	);
}

# }}}

# Kit handling
# local_kits - return the list of the kits available locally {{{
sub local_kits {
	my ($self) = @_;
	return Genesis::Kit::Compiled->local_kits(
		$self->kit_provider(),
		$self->local_kits_path()
	);
}

# }}}
# local_kit_version - return the Genesis::Kit object for the given name and version {{{
sub local_kit_version {
	my ($self, $name, $version) = @_;

	($name, $version) = ($1, $2)
		if (!defined($version) && defined($name) && $name =~ m{(.*)/(.*)});

	# local_kit_version('dev') or local_kit_version() with a dev kit present
	return Genesis::Kit::Dev->new($self->path("dev"))
		if ((!$name && !$version) || ($name && $name eq 'dev')) && $self->has_dev_kit;
	return undef if ($name and $name eq 'dev');

	#    local_kit_version() without a dev/ directory
	# or local_kit_version($name, $version)
	my $kits = $self->local_kits();

	# we either need a $name, or only one kit type
	# (i.e. we can autodetect $name for the caller)
	$name = (keys %$kits)[0] if (!$name && keys(%$kits) == 1);
	return undef unless $kits->{$name};

	$version = (reverse sort by_semver keys %{$kits->{$name}})[0]
		if (!defined($version) || $version eq 'latest');
	return $kits->{$name}{$version};
}

# }}}
# remote_kit_names - get available kit names from kit provider {{{
sub remote_kit_names {
	my $self = shift;
	$self->kit_provider->kit_names(@_);
}

# }}}
# remote_kit_versions - get versions available for a remote kit from the kit provider {{{
sub remote_kit_versions {
	my $self = shift;
	$self->kit_provider->kit_versions(@_);
}

# }}}
# remote_kit_version_info - return the metadata about the specified remote kit version {{{
sub remote_kit_version_info {
	my ($self, $name, $version) = @_;
	($name, $version) = ($1, $2)
		if (!defined($version) && defined($name) && $name =~ m{(.*)/(.*)});
	$version = $self->kit_provider->latest_version_of($name) unless $version && $version ne 'latest';
  $self->kit_provider->kit_versions($name, version => $version);
}

# }}}
# download_kit - install remote kit into the local repository {{{
sub download_kit {
	my ($self, $id, %opts) = @_;
	my ($name, $version) = ($1, $2) if $id =~ m/([^\/]+)(?:\/(.*))?/;
	$version = $self->kit_provider->latest_version_of($name) unless $version && $version ne 'latest';

	my $target;
	if ($opts{to}) {
		$target = $opts{to};
		bail(
			"#C{%s} is not a directory", $opts{to}
		) unless -d $opts{to};
		bail(
			"#C{%s} is not writable", $opts{to}
		) unless -w $opts{to};
	} elsif ($opts{'as-dev'}) {
		$target = workdir;
	} else {
		$target = $self->local_kits_path();
		mkdir_or_fail($target) unless -d $target;
	}

	$self->kit_provider->fetch_kit_version($name,$version,$target,$opts{force});
}

# }}}

# Private Methods

# _validate_config - validate the configuration of the repo {{{
sub _validate_config {
	my ($self) = @_;
	my $config_version = $self->config->get(version => 1);
	if ($config_version == 1 || $config_version =~ /^\d+\.\d+\.\d+(-[A-Za-z0-9_-]\.?\d+)?$/) {

		my $upgrade_automatically = $Genesis::RC->get(automatic_config_upgrade => 'no');
		bail(
			"Genesis deployment repo v1 configuration is not supported, and cannot ".
			"update automatically.  Manual intervention required."
		) unless in_controlling_terminal || $upgrade_automatically ne 'no';

		$self->_upgrade_config_to_v2($config_version, $upgrade_automatically);

	} elsif ($config_version == 2){
		$self->config->validate($self->_repo_config_schema());
	} else {
		bail "Genesis deployment repo configuration version $config_version is not supported";
	}
	return 1;
}

# }}}
# _upgrade_config_to_v2 - upgrade the configuration to version 2 from previous unversioned configs {{{
sub _upgrade_config_to_v2 {
	my ($self, $config_version, $upgrade_automatically) = @_;

	# Check if we can upgrade to v2
	my $new_config = Genesis::Config->new();
	$new_config->set('deployment_type', $self->config->get('deployment_type' => $self->config->get('type')));
	$new_config->set('version', 2);
	if ($config_version =~ /^\d+\.\d+\.\d+(-[A-Za-z0-9_-]\.?\d+)?$/) {
		$new_config->set('creator_version', $config_version);
	} else {
		$new_config->set('creator_version',  # There are several possible keys for the creator version
				 $self->config->get('creator_version'
			=> $self->config->get('genesis_version'
			=> $self->config->get('genesis' => 'Unknown'
		))));
	}
	$new_config->set('updater_version', $Genesis::VERSION);
	$new_config->set('kit_provider', $self->config->get('kit_provider')) if $self->config->has('kit_provider');
	if ($self->config->has('secrets_provider')) {
		$new_config->set('secrets_provider', $self->config->get('secrets_provider'))
	} elsif ($self->config->has('vault')) {
		$new_config->set('secrets_provider', {
			url       => $self->vault->url,
			insecure  => $self->vault->verify    ? Genesis::Config::FALSE : Genesis::Config::TRUE,
			strongbox => $self->vault->strongbox ? Genesis::Config::TRUE  : Genesis::Config::FALSE,
			namespace => $self->vault->namespace,
			alias     => $self->vault->name
		});
	}

	if ($self->config->has('allow_oversized_secrets')) {
		$new_config->set('allow_oversized_secrets', $self->config->get('allow_oversized_secrets'));
	}

	my $old_config = $self->config;
	$self->{__config} = $new_config;

	bail(
		"Cannot upgrade Genesis deployment repo v1 configuration to v2.  Manual intervention required."
	) unless $self->_validate_config;

	# Show and ask permission to upgrade
	if ($upgrade_automatically ne 'silent') {
		warning "Genesis deployment repo v1 configuration detected, preparing to upgrade to v2";
		$self->config->show_diff($old_config);
	}

		# Ask user permission to upgrade to v2

	my $upgrade = $upgrade_automatically ne 'no' || prompt_for_boolean(
		"Proceed [y|n]?", 1
	);

	if ($upgrade) {
		$self->config->replace($old_config);
		info(
			"Genesis deployment repo configuration upgraded to v2"
		) unless $upgrade_automatically eq 'silent';
	} else {
		bail "Genesis deployment repo configuration upgrade to v2 aborted";
	}
}

# }}}
# _repo_config_schema - return the repository configuration validation schema {{{
sub _repo_config_schema {
	my ($self) = @_;
	return {
		deployment_type => {
			type           => 'string',
			required       => 1,
			description    => 'Type of deployment this repository manages'
		},
		version => {
			type           => '"2"',
			required       => 1,
			description    => 'Configuration schema version'
		},
		creator_version => {
			type           => 'semver||"(development)"||"Unknown"',
			required       => 1,
			description    => 'Genesis version that created this repository'
		},
		updater_version => {
			type           => 'semver||"(development)"',
			description    => 'Genesis version that last updated this repository'
		},
		minimum_version => {
			type           => 'semver',
			description    => 'Minimum Genesis version required for this repository'
		},
		manifest_store => {
			type           => 'enum',
			values         => ['repository','hybrid','exodus'],
			default        => 'hybrid',
			description    => 'Where to store manifests'
		},
		kits_path => {
			type           => 'string',
			default        => '$GENESIS_ROOT/.genesis/kits',
			description    => 'Path to directory containing compiled kits (defaults to .genesis/kits under the deployment base directory)',
		},
		kit_provider => {
			type           => 'hash',
			description    => 'Configuration for kit provider',
			schema => {
				type         => {type => 'enum', values => ['github','genesis-community']},
				organization => {type => 'string'},
				label        => {type => 'string'},
				tls          => {type => 'enum', values => ['yes', 'no', 'skip', 'insecure']},
				domain       => {type => 'string'},
			}
		},
		secrets_provider => {
			type           => 'hash',
			description    => 'Configuration for secrets provider (Vault)',
			schema => {
				url          => {type => 'string', required => 1},
				insecure     => {type => 'boolean', default => Genesis::Config::FALSE},
				strongbox    => {type => 'boolean', default => Genesis::Config::TRUE},
				namespace    => {type => 'string'},
				alias        => {type => 'string'}
			}
		},
		deployment_change_reason_required_size => {
			type           => 'number',
			default        => 0,
			description    => 'Minimum size of the deployment change reason in characters (0 to disable)',
		},
		user_provided_bosh_creds => {
			type           => 'enum',
			default        => 'ignore',
			values         => [qw/ignore allow require/],
			description    => 'How should BOSH_USER and BOSH_PASSWORD env vars be handled',
		},
		allow_oversized_secrets => {
			type           => 'boolean',
			description    => 'Allow secrets larger than recommended size'
		},
		confirm_release_overrides => {
			type           => 'enum',
			values         => [qw/always outdated never/],
			envvar         => 'GENESIS_CONFIRM_RELEASE_OVERRIDES',
			description    => 'Confirm release overrides'
		},
	};
}

# }}}

1;
# vim: fdm=marker:foldlevel=1:noet
