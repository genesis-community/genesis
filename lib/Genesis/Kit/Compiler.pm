package Genesis::Kit::Compiler;
use strict;
use warnings;

use Genesis;
use Genesis::IO;
use Genesis::Kit::Dev;
use Genesis::Vault;

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
		error "\n#R{[ERROR]} Kit source directory '$self->{root}' not found.\n";
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
			my @valid_keys = qw/name version description code docs author authors genesis_version_min secrets_store required_configs/;
			if (!defined($meta->{secrets_store}) || $meta->{secrets_store} eq 'vault') {
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

			my @errant_keys = ();
			for my $key (sort keys %$meta) {
				push(@errant_keys, $key) unless grep {$_ eq $key} @valid_keys;
			}
			push @valid_keys, "use_create_env" if new_enough($min_version, "2.8.0");
			if (@errant_keys) {
				push @yml_errors, sprintf(
					"contains invalid top-level key%s: %s;\nvalid keys are: %s",
					scalar(@errant_keys) == 1 ? '' : 's',
					join(", ",@errant_keys), join(", ", @valid_keys)
				);
			}
		}
	} else {
		push @yml_errors, "does not exist.";
	}
	if (@yml_errors) {
		push @errors, "#Wk{Kit Metadata file }#Ck{kit.yml}#Wk{:}\n  - ".
			join("\n  - ", map {join("\n    ", split("\n", $_))} @yml_errors);
	}

	# Check if any defined secrets have errors
	if ($meta && (!defined($meta->{secrets_store}) || $meta->{secrets_store} eq 'vault')) {
		my @all_features = grep {$_ ne 'base'} sort uniq(
			keys(%{$meta->{credentials}  || {}}),
			keys(%{$meta->{certificates} || {}}),
			keys(%{$meta->{provided}     || {}})
		);

		my $kit = Genesis::Kit::Dev->new($self->{root});
		my @plans = Genesis::Vault::parse_kit_secret_plans(
			$kit->dereferenced_metadata(sub {$self->_lookup_test_params(@_)}),
			\@all_features,
			validate => 1
		);
		my @secrets_errors = grep {$_->{type} eq 'error'} @plans;
		if (scalar @secrets_errors) {
			my $msg =
				"#Wk{Secrets specifications in }#Ck{kit.yml}#Wk{:}\n".
				join("\n  ", map {
					my ($head,$extra) = split(
						": *\n", join("\n    ", (split("\n", $_->{error}))), 2
					);
					sprintf("\n  #R{%s for }#C{%s}%s", $head, $_->{path}, $extra ? ":\n".$extra : '');
				} @secrets_errors);

			if (grep {$msg =~ qr/\$\{$_\}/} @{$kit->{__deref_miss}||[]}) {
				$msg .= "\n\n  Some of the errors above are due to unresolved param dereferencing.  ";
				$msg .= (-f $self->{root}.'/ci/test_params.yml') ? "Update the" : "Create a";
				$msg .= "\n  ci/test_params.yml file in the kit directory to contain these parameters.";
			}
			push @errors, $msg;
		}
	}

	# Hooks validation
	my @hook_errors;
	for my $hook (qw(new secrets blueprint info addon check)) {
		if (!-e "$self->{root}/hooks/$hook") {
			push(@hook_errors, "#C{hooks/$hook} is missing - this hook is not optional.")
				if $hook =~ /^(new|blueprint)$/;
			next;
		}
		if (!-f "$self->{root}/hooks/$hook") {
			push @hook_errors, "#C{hooks/$hook} is not a regular file.";
		} elsif (!-x "$self->{root}/hooks/$hook") {
			push @hook_errors, "#C{hooks/$hook} is not executable.";
		}
	}
	push @errors, "#Wk{Hook scripts:}\n  - ".join("\n  - ", @hook_errors)
		if @hook_errors;

	my ($changes, undef) = run('cd "$1" >/dev/null && git status --porcelain', $self->{root});
	push @errors, "#Wk{Git repository status:}\n".
	              "  Unstaged / uncommited changes found in working directory:\n".
	              join("\n", map {"    #Y{$_}"} split("\n",$changes)) .
	              "\n\n  Please either #C{stash} or #C{commit} those changes before compiling your kit.\n"
		if $changes;

	if (@errors) {
		my $msg = join("\n  ", split("\n", join("\n\n", @errors)));
		$msg =~ s/^\s+$//gm;
		error "\n#R{[ERROR] Encountered issues while processing kit }#M{%s/%s}#R{:}\n\n  %s\n",
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
			? LoadFile($test_params_file)
			: {};
	}
	return struct_lookup($self->{__test_params}, $key, $default);
}

sub _prepare {
	my ($self, $relpath) = @_;
	$self->{relpath} = $relpath;

	run(
		{ onfailure => 'Unable to set up a temporary working copy of the kit source files' },
		'rm -rf "$2/$3" && cp -a "$1" "$2/$3"',
		$self->{root}, $self->{work}, $self->{relpath});

	(my $out, undef) = run(
		{ onfailure => 'Unable to determine what files to clean up before compiling the kit' },
		'git -C "$1" clean -xdn', $self->{root});

	my @files = map { "$self->{work}/$self->{relpath}/$_" } qw(ci .git .gitignore spec devtools);
	for (split /\s+/, $out) {
		s/^would remove //i;
		push @files, "$self->{work}/$self->{relpath}/$_";
	}
	run(
		{ onfailure => 'Unable to clean up work directory before compiling the kit' },
		'rm -rf "$@"', @files);
}

sub compile {
	my ($self, $name, $version, $outdir, %opts) = @_;

	bail "Version %s is not semantic-compliant", $version
		if !semver($version);

	$self->validate($name,$version) || $opts{force} or return undef;
	$self->_prepare("$name-$version");

	run({ onfailure => "Unable to update kit.yml with version '$version'", stderr => 0 },
		'cat "${2}/kit.yml" | sed -e "s/^version:.*/version: ${1}/" > "${3}/${4}/kit.yml"',
		$version, $self->{root}, $self->{work}, $self->{relpath});

	run({ onfailure => 'Unable to compile final kit tarball' },
		'tar -czf "$1/$3.tar.gz" -C "$2" "$3/"',
		$outdir, $self->{work}, $self->{relpath});

	return "$self->{relpath}.tar.gz";
}

sub scaffold {
	my ($self, $name) = @_;

	my ($user, undef)  = run('git config user.name');  $user  ||= 'The Unknown Kit Author';
	my ($email, undef) = run('git config user.email'); $email ||= 'no-reply@example.com';

	if (-f "$self->{root}/kit.yml") {
		die "Found a kit.yml in $self->{root}; cowardly refusing to overwrite an existing kit.\n";
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

=head1 NAME

Genesis::Kit::Compiler

=head1 DESCRIPTION

The Compiler class encapsulates all of the rules and logic that go into
compiling a kit source directory into a distributable Genesis Kit tarball.
It includes facilities for validating the kit source, expunging files we
don't wish to distribute (other tarballs, ci/ directories, etc.), and
handles the naming and composition of the Kit archive.

This module is fully object-oriented, and does not export any procedural
functions or package variables.

    use Genesis::Kit::Compiler;

    my $cc = Genesis::Kit::Compiler->new("path/to/kit/src");
    if (!$cc->validate) {
      error "#R{Problems were found with your Kit source.}";
      exit 2;
    }

    my $v = '1.0.9';
    $cc->compile("my-kit", , ".");
    # file will be ./my-kit-1.0.9.tar.gz

=head1 METHODS

=head2 new($root)

Instantiate a new Kit Compiler, for compiling the source found in C<$root>.

=head2 validate()

Validate a Kit by inspecting its source code and defined metadata.

The following validations are performed:

=over

=item 1.

All kits must have a kit.yml with valid YAML in it.

=item 2.

The kit.yml file must provide values for the top-level C<name>, C<author>,
C<homepage>, and C<github> keys.

=item 3.

The C<hooks/> directory must exist.

=item 4.

Any present hooks must be executable files.

=item 5.

If defined, the C<genesis_min_version> value must be a valid semantic
version.

=back

=head2 compile($name, $version, $outdir)

Compiles a kit source directory into a distributable tarball, of the given
version.  Version is specified here, vs. in the kit.yml metadata, to enable
automation of release engineering via tools like Concourse.  Compilation
implciitly calls C<validate()> for you, so you don't need to do so
out-of-band.

The output tarball will be written to C<$outdir/$name-$version.tar.gz>, and
will bundle all files in the archive under the relative path
C<$name-$version/>.

=head2 scaffold($name)

Generates a new kit source directory, populating it with (hopefully!)
helpful scaffolding files for things like kit.yml, hooks, and manifest
fragments.

=head2 CAVEATS

You cannot easily re-use one Kit Compiler to compile a different directory.
Several internal functions cache state that is only valid for a single root
source directory.  In practice this is not an issue, since for the most
part Genesis just uses this for the C<compile-kit> sub-command, which only
deals with a single Kit.

=cut
