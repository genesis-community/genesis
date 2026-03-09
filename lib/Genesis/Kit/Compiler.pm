package Genesis::Kit::Compiler;
use strict;
use warnings;

use Genesis;
use Genesis::Kit;
use Genesis::Kit::Dev;
use Genesis::Env::Secrets::Parser::FromKit;
use Genesis::Env::Secrets::Plan;

use Archive::Tar;
use File::Find ();

sub new {
	my ($class, $root) = @_;
	bless({
		root => $root,
		work => workdir(),
	}, $class);
}

sub validate {
	my ($self,$name,$version) = @_;

	if (!-d $self->{root}) {
		error "\nKit source directory '$self->{root}' not found.\n";
		return 0;
	}

	my @errors;
	my @yml_errors;
	my ($meta,$msg);
	if (-f "$self->{root}/kit.yml") {
		eval {$meta = load_yaml_file("$self->{root}/kit.yml"); };
		if ($@ || !$meta) {
			push @yml_errors, "is not a well-formed YAML file with a map root.";
		} else {
			for my $key (qw(name version code)) {
				next if $meta->{$key};
				push @yml_errors, "does not define '$key'";
			}
			push @yml_errors, "specifies name '$meta->{name}', expecting '$name'"
				if ($meta->{name} && $meta->{name} ne $name);
			push @yml_errors, "does not identify the author(s) via 'author' or 'authors'"
				if (!$meta->{author} && !$meta->{authors});
			push @yml_errors, "specifies both 'author' and 'authors': pick one."
				if ($meta->{author} && $meta->{authors});
			push @yml_errors, sprintf("expects 'authors' to be an array, not a %s.", lc(ref($meta->{authors}) || "string"))
				if ($meta->{authors} && (ref($meta->{authors}||'') ne 'ARRAY'));
			push @yml_errors, sprintf("expects 'exclude_paths' to be an array, not a %s.", lc(ref($meta->{exclude_paths}) || "string"))
				if ($meta->{exclude_paths} && (ref($meta->{exclude_paths}||'') ne 'ARRAY'));


			# genesis versions must be semver
			my $min_version="0.0.0";
			if (exists $meta->{genesis_version_min}) {
				if (!semver($meta->{genesis_version_min})) {
					push @yml_errors, "specifies minimum Genesis version '$meta->{genesis_version_min}', which is not a semantic version (x.y.z).";
				} elsif (semver($Genesis::VERSION) && ! new_enough $Genesis::VERSION, $meta->{genesis_version_min}) {
					push @yml_errors, "This Genesis (v$Genesis::VERSION) does not meet minimum Genesis version of v$meta->{genesis_version_min}"
				} elsif (@{semver($meta->{genesis_version_min})}[3] != 0 && @{semver($version)}[3] == 0) {
					push @yml_errors, "Can not specify rc minimum Genesis version for compiling non-rc kit versions"
				}
				$min_version = $meta->{genesis_version_min};
			}

			# check for errant top-level keys - params, subkits and features have been discontinued.
			my @valid_keys = qw/name version description code docs author authors genesis_version_min secrets_store required_configs exclude_paths supports services/;
			if (!defined($meta->{secrets_store}) || $meta->{secrets_store} eq 'vault' || new_enough($min_version, "3.1.0")) {
				# v3.1.0 allows a mix of vault and credhub secrets
				push @valid_keys, "credentials", "certificates", "provided";
			} elsif ($meta->{secrets_store} ne "credhub") {
				push @yml_errors, "specifies invalid secrets_store: expecting one of 'vault' or 'credhub'";
			}

			# v2.8.0 specs
			if (exists $meta->{use_create_env}) {
				push @yml_errors, "'use_create_env' requires a 'genesis_version_min' of at least 2.8.0"
					unless (new_enough($min_version, "2.8.0"));
				push @yml_errors, "'use_create_env' must be one of yes, no, or allow"
					unless ($meta->{use_create_env} =~ /^(yes|no|allow)$/);
			}

			push @valid_keys, "use_create_env" if new_enough($min_version, "2.8.0");

			# Validate services field
			if (exists $meta->{services}) {
				if (ref($meta->{services}) ne 'ARRAY') {
					push @yml_errors, "expects 'services' to be an array";
				}
			}

			my @errant_keys = ();
			for my $key (sort keys %$meta) {
				push(@errant_keys, $key) unless grep {$_ eq $key} @valid_keys;
			}
			if (@errant_keys) {
				push @yml_errors, sprintf(
					"contains invalid top-level key%s: %s;\n[[valid keys are: >>%s",
					scalar(@errant_keys) == 1 ? '' : 's',
					join(", ",@errant_keys), join(", ", @valid_keys)
				);
			}
		}
	} else {
		push @yml_errors, "does not exist.";
	}

	# TODO: Check hook scripts for validation.

	if (@yml_errors) {
		push @errors, "#Wk{Kit Metadata file }#Ck{kit.yml}#Wk{:}\n[[- >>".
			join("\n[[- >>", map {join("\n[[  >>", split("\n", $_))} @yml_errors);
	}

	# Check if any defined secrets have errors
	if ($meta && (!defined($meta->{secrets_store}) || $meta->{secrets_store} eq 'vault')) {
		my @all_features = grep {$_ ne 'base'} uniq sort(
			keys(%{$meta->{credentials}  || {}}),
			keys(%{$meta->{certificates} || {}}),
			keys(%{$meta->{provided}     || {}})
		);

		my $kit = Genesis::Kit::Dev->new($self->{root});

		# Validate secrets plan
		my @secrets = Genesis::Env::Secrets::Parser::FromKit->new()->parse(
			features => \@all_features,
			kit_metadata => $kit->dereferenced_metadata(sub {$self->_lookup_test_params(@_)})
		);

		my $plan = Genesis::Env::Secrets::Plan->new()->populate(@secrets);
		my @secrets_errors = $plan->errors;
		if (scalar @secrets_errors) {
			my $msg =
				"#Wk{Secrets specifications in }#Ck{kit.yml}#Wk{:}\n".
				join("\n\n", map {"[[- >>".join("\n[[  >>", split(/\n/,$_->describe))} @secrets_errors);

			if (grep {$msg =~ qr/\$\{$_\}/} @{$kit->{__deref_miss}||[]}) {
				$msg .= "\n\n[[  >>Some of the errors above are due to unresolved param dereferencing.  ";
				$msg .= (-f $self->{root}.'/ci/test_params.yml') ? "Update the " : "Create a ";
				$msg .= "ci/test_params.yml file in the kit directory to contain these parameters.";
			}
			push @errors, $msg;
		}
	}

	# Hooks validation
	my @hook_errors;
	my @known_hooks = Genesis::Kit->known_hooks();
	my @required_hooks = qw/new blueprint/;
	my @present_hooks = ();
	for my $hook (@known_hooks) {
		my $hook_file = "$self->{root}/hooks/$hook";
		$hook_file = "$self->{root}/hooks/$hook.pm" if !-e $hook_file;
		if (!-e $hook_file) {
			push @hook_errors, "#C{hooks/$hook} is missing - this hook is not optional."
				if grep {$_ eq $hook} @required_hooks;
			next;
		}
		if (!-f $hook_file) {
			push @hook_errors, "#C{hooks/$hook} is not a regular file.";
			next;
		}

		if ($hook_file =~ /\.pm$/) {
			# Perl hook, check if it compiles
			my ($out,$rc) = run('perl', '-c', $hook_file);
			if ($rc) {
				push @hook_errors, "#C{hooks/$hook.pm} does not compile.  Run 'perl -c hooks/$hook.pm' for details.";
			}
		} else {
			# Bash hook, check if it is executable
			if (!-x $hook_file) {
				push @hook_errors, "#C{hooks/$hook} is not executable.";
			}
		}
	}
	push @errors, "#Wk{Hook scripts:}\n[[- >>".join("\n[[- >>", @hook_errors)
		if @hook_errors;

	my ($changes, undef) = run('cd "$1" >/dev/null && git status --porcelain', $self->{root});
	$self->{git_clean} = !$changes;  # Set property to track if git repo is clean
	push @errors, "#Wk{Git repository status:}\n".
	              "[[- >>Unstaged / uncommited changes found in working directory:\n".
	              join("\n", map {"[[    >>#Y{$_}"} split("\n",$changes)) .
	              "\n\n  Please either #C{stash} or #C{commit} those changes before compiling your kit."
		if $changes;

	if (@errors) {
		my $msg = join("\n\n", @errors);
		$msg =~ s/^\s+$//gm;
		error "\n#R{Encountered issues while processing kit }#M{%s/%s}#R{:}\n\n%s\n",
			$name, $version, $msg;
		return 0;
	}
	return 1;
}

sub _lookup_test_params {
	my ($self, $key, $default) = @_;
	unless (defined $self->{__test_params}) {
		my $test_params_file = $self->{root}.'/ci/test_params.yml';
		$self->{__test_params} = (-f $test_params_file)
			? load_yaml_file($test_params_file)
			: {};
	}
	return struct_lookup($self->{__test_params}, $key, $default);
}

sub _select_files {
	my ($self) = @_;

	pushd $self->{root};
	my @exclude = qw(ci .git .gitignore spec devtools);

	my $meta;
	eval {$meta = load_yaml_file("$self->{root}/kit.yml"); };
	if (! $@ && $meta && $meta->{exclude_paths} && ref($meta->{exclude_paths}) eq "ARRAY") {
		for (@{$meta->{exclude_paths}}) {
			next if /(?:^|\/)\.\.\//; # don't let kits delete out of scope
			push(@exclude, $_);
		}
	}

	push @exclude, lines(run(
		{ onfailure => 'Unable to determine what files to clean up before compiling the kit' },
		'git clean -xdn | sed -e "s/Would remove //"',
	));

	trace(
		"Excluding the following paths from the kit under %s:\n%s",
		$self->{root},
		join("\n", map {"  - $_"} sort @exclude)
	);

	# Build regexp pattern for dir exclusions, and lookup table for files.
	my $exclude_pattern = join('|', map { quotemeta($_ =~ s{/$}{}r) } grep { -d $_ } @exclude);
	my $exclude_re = qr/^.\/(?:$exclude_pattern)(?:\/|$)/;
	my %exclude_files = map { ("./$_" => 1) } grep { -f $_ } @exclude;

	my @all_files = ();
	File::Find::find (sub {
		return if $File::Find::name eq '.'; # skip current dir entry
		return if $exclude_files{$File::Find::name};
		return if $exclude_re && $File::Find::name =~ $exclude_re;

		# Strip the root path prefix
		push @all_files, substr($File::Find::name, 2);
	}, '.');
	popd;
	return @all_files;
}

sub compile {
	my ($self, $name, $version, $outdir, %opts) = @_;

	bail "Version %s is not semantic-compliant", $version
		if !semver($version);

	$self->validate($name,$version) || $opts{force} or return undef;

	# Update hook package lines if git repo is clean
	if ($self->{git_clean} && !$opts{'skip-version-updates'}) {
		$self->_update_version($version);
		$self->_update_hook_packages($name, $version);
		$self->_prepare_hook_commit($version);
	} else {
		warning "Not updating version in perl hooks due to uncommitted changes in working directory";
	}

	my $base_dir = "$name-$version/";
	my @files = $self->_select_files();
	my $tar = Archive::Tar->new;

	pushd $self->{root};
	$tar->add_files('.');
	$tar->rename('.' => $base_dir);
	$tar->chown('uuuuuuuu:gggggggg');

	# Add and remap the files to be under the base dir
	for my $path (sort @files) {
		my ($file) = $tar->add_files($path);
		next unless $file;
		my $full_path = "$base_dir".$file->full_path;
		$full_path =~ s{/*$}{/} if $file->is_dir;
		$file->rename($full_path);
		$file->chown('uuuuuuuu:gggggggg');
	}
	popd;

	my $filename = "$name-$version.tar.gz";
	$tar->write("$outdir/$filename", COMPRESS_GZIP);
	return $filename;
}

sub _update_hook_packages {
	my ($self, $name, $version) = @_;
	my $hooks_dir = "$self->{root}/hooks";
	return unless -d $hooks_dir;

	# Convert kit name to CamelCase for package naming
	my $kit_type = $self->_to_camel_case($name);

	# Find all .pm files in hooks directory
	my @hook_files = glob("$hooks_dir/*.pm");
	return unless @hook_files;

	my $updated_files = 0;
	for my $hook_file (@hook_files) {
		my $filename = (split '/', $hook_file)[-1];
		$filename =~ s/\.pm$//;

		my $package_name = $self->_generate_package_name($filename, $kit_type);
		my ($semver, $extra) = $version =~ /^((?:\d+)\.(?:\d+)\.(?:\d+))(?:-(.+))?$/;
		my $new_package_line = "package $package_name v$semver;";
		$new_package_line .= " # $extra" if $extra;

		if ($self->_update_package_line($hook_file, $new_package_line)) {
			$updated_files++;
		}
	}
}

sub _to_camel_case {
	my ($self, $name) = @_;

	# Special case mappings
	my %special_mappings = (
		cf   => 'CF',
		bosh => 'BOSH',
	);

	# Split on hyphens and convert each part
	my @parts = split /-/, $name;
	my @camel_parts;

	for my $part (@parts) {
		push @camel_parts, $special_mappings{$part} // ucfirst(lc($part));
	}

	return join('', @camel_parts);
}

sub _generate_package_name {
	my ($self, $filename, $kit_type) = @_;

	# Strip tilde shortcut part if present (e.g., addon-bind-autoscaler~ba -> addon-bind-autoscaler)
	my $hook_name = $filename;
	$hook_name =~ s/~.*$//;

	if ($hook_name =~ /^addon-(.+)$/) {
		# Addon hook
		my $addon_name = $1;
		my $addon_camel = $self->_to_camel_case($addon_name);
		return "Genesis::Hook::Addon::${kit_type}::${addon_camel}";
	} else {
		# Regular hook
		my $hook_camel = $self->_to_camel_case($hook_name);
		return "Genesis::Hook::${hook_camel}::${kit_type}";
	}
}

sub _update_package_line {
	my ($self, $hook_file, $new_package_line) = @_;

	# Read the file content
	open my $fh, '<', $hook_file or return 0;
	my @lines = <$fh>;
	close $fh;

	my $updated = 0;
	# Update the package line (should be first non-comment line)
	for my $i (0..$#lines) {
		if ($lines[$i] =~ /^package\s+/) {
			# Only update if different
			if ($lines[$i] ne "$new_package_line\n") {
				$lines[$i] = "$new_package_line\n";
				$updated = 1;
			}
			last;
		}
	}

	# Write the file back if updated
	if ($updated) {
		open $fh, '>', $hook_file or return 0;
		print $fh @lines;
		close $fh;
	}

	return $updated;
}

sub _update_version {
	my ($self, $version) = @_;
	my $kit_yml = "$self->{root}/kit.yml";

	# Read the original kit.yml
	my $content = slurp($kit_yml);

	# Update the version line
	$content =~ s/^version:\s*.*/version: $version/m;

	# Write to the work directory
	mkfile_or_fail($kit_yml, $content);
}

sub _prepare_hook_commit {
	my ($self, $version) = @_;

	# Add the changed files to git
	run('cd "$1" && git add kit.yml hooks/*.pm', $self->{root});

	# Prepare commit message template
	my $commit_msg = "Update for release v$version\n\nUpdated kit version and perl hook packages";

	# Write commit message template to temporary file
	my $commit_msg_file = "/tmp/genesis_hook_commit_msg.txt";
	mkfile_or_fail($commit_msg_file, $commit_msg);

	# Inform user about the changes
	info "Updated version and package versions in perl hook files to v%s.", $version;
	info "Changes have been staged. Opening git commit editor...";

	# Run git commit with the template in the user's default editor
	run({interactive => 1}, 'cd "$1" && git commit -v --edit --file "$2"', $self->{root}, $commit_msg_file);

	# Clean up template file
	unlink $commit_msg_file;
}

sub scaffold {
	my ($self, $name) = @_;

	my ($user, undef)  = run('git config user.name');  $user  ||= 'The Unknown Kit Author';
	my ($email, undef) = run('git config user.email'); $email ||= 'no-reply@example.com';

	if (-f "$self->{root}/kit.yml") {
		bail "Found a kit.yml in $self->{root}; cowardly refusing to overwrite an existing kit.";
	}

	mkdir_or_fail "$self->{root}";
# .gitignore {{{
	mkfile_or_fail "$self->{root}/.gitignore", <<DONE;
*.tar.gz
DONE

# }}}
# kit.yml {{{
	mkfile_or_fail "$self->{root}/kit.yml", <<DONE;
name:    $name
version: 0.0.1
author:  $user <$email>
docs:    https://github.com/cloudfoundry-community/$name-boshrelease
code:    https://github.com/genesis-community/$name-genesis-kit

# 2.7.0 was our last big feature bump
genesis_version_min: 2.7.0
DONE

# }}}
# README.md {{{
	mkfile_or_fail "$self->{root}/README.md", <<DONE;
$name Genesis Kit
=================

FIXME: The kit author should have filled this in with details about
what this is, and what it provides. But they have not, and that is sad.
Perhaps a GitHub issue should be opened to remind them of this?

Quick Start
-----------

To use it, you don't even need to clone this repository! Just run
the following (using Genesis v2):

```
# create a $name-deployments repo using the latest version of the $name kit
genesis init --kit $name

# create a $name-deployments repo using v1.0.0 of the $name kit
genesis init --kit $name/1.0.0

# create a my-$name-configs repo using the latest version of the $name kit
genesis init --kit $name -d my-$name-configs
```

Once created, refer to the deployment repository README for information on
provisioning and deploying new environments.

Features
-------

FIXME: The kit author should have filled this in with details
about what features are defined, and how they affect the deployment. But they
have not, and that is sad. Perhaps a GitHub issue should be opened to remind
them of this?

Params
------

FIXME: The kit author should have filled this in with details about the params
present in the base kit, as well as each feature defined. These should likely
be in different sections (one for base, one per feature). Unfortunately,
the author has not done this, and that is sad. Perhaps a GitHub issue
should be opened to remind them of this?

Cloud Config
------------

FIXME: The kit author should have filled in this section with details about
what cloud config definitions this kit expects to see in play and how to
override them. Also useful are hints at default values for disk + vm sizing,
scaling considerations, and other miscellaneous IaaS components that the deployment
might require, like load balancers.
DONE

# }}}

	mkdir_or_fail "$self->{root}/manifests";
# manifests/$name.yml {{{
	mkfile_or_fail "$self->{root}/manifests/$name.yml", <<DONE;
---
meta:
  default:
    azs: [z1]

instance_groups:
  - name:      $name
    instances: 1
    azs:       (( grab params.availability_zones || meta.default.azs ))
    stemcell:  default
    networks:  { name: (( grab params.network || "default" )) }
    vm_type:   (( grab params.vm_type || "default" ))

    properties:
      debug: false


update:
  serial:            false
  canaries:          1
  max_in_flight:     1
  max_errors:        1
  canary_watch_time: 5000-600000
  update_watch_time: 5000-600000

stemcells:
  - alias:   default
    os:      (( grab params.stemcell_os      || "ubuntu-bionic" ))
    version: (( grab params.stemcell_version || "latest" ))

releases:
  - name: $name
    version: (( param "The Kit Author forgot to fill out manifests/$name.yml" ))
    sha1:    (( param "The Kit Author forgot to fill out manifests/$name.yml" ))
    url:     (( param "The Kit Author forgot to fill out manifests/$name.yml" ))
DONE

# }}}

	mkdir_or_fail "$self->{root}/hooks";
# hooks/new {{{
	mkfile_or_fail "$self->{root}/hooks/new", <<DONE;
#!/bin/bash
shopt -s nullglob
set -eu

#
# Genesis Kit `new' Hook
#

(
cat <<EOF
kit:
  name:    \$GENESIS_KIT_NAME
  version: \$GENESIS_KIT_VERSION
  features:
    - (( replace ))

EOF

genesis_config_block

cat <<EOF
params: {}
EOF
) >\$GENESIS_ROOT/\$GENESIS_ENVIRONMENT.yml

exit 0
DONE

# }}}
	chmod_or_fail 0755, "$self->{root}/hooks/new";
# hooks/blueprint {{{
	mkfile_or_fail "$self->{root}/hooks/blueprint", <<DONE;
#!/bin/bash
shopt -s nullglob
set -eu

# Genesis Kit \'blueprint\' Hook
#
# This script outputs the list of merge files needed to support the desired
# feature set selected by the environment parameter file.  As generated, it
# lists all *.yml files in the base, then all *.yml files in each detected
# feature directory, in the order the features are specified in the environment
# yml file.  If finer control is desired, add logic around the wants_kit_feature()
# function (takes a feature as a string, returns exit code 0 if present, non-
# zero exit code otherwise).

declare -a manifests

# Normally, your first manifest block is named after the kit, but it is also
# common to be named "manifest/base.yml"
manifests+=( manifests/$name.yml )

### Option 1: validate and process your list of features
#
# validate_features your-list of-features \
#                   go-here
#
# # Once your features are validated, assemble them in order
# if want_feature "feature_name" ; then
#   manifest+=( \
#     manifests/feature_name.yml \
#     releases/feature_name.yml \
#   )
# fi

### Option 2: Allow repo-provided files as features
#             This allows users to specify the order in which manifest blocks
#             are assembled, so if specific blocks must come first, pre-process
#             them above
#
# for __feature in \${GENESIS_REQUESTED_FEATURES; do
#   if [[ -f "\$GENESIS_ROOT/ops/\$__feature.yml" ]] ; then
#     manifests+=( "\$GENESIS_ROOT/ops/\$__feature.yml" )
#   else
#     # Process remaining features another way...
#   fi
# done

# Option 3: Bulk assemblage - assemble all files in order of natural sort
for dir in features/*; do
	if want_feature "\$(basename "\$dir")"; then
		manifests+=( "\$dir/*.yml" )
	fi
done
echo \${manifests[@]}
DONE

# }}}
	chmod_or_fail 0755, "$self->{root}/hooks/blueprint";
}

1;
