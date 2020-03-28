package Genesis::Kit::Compiler;
use strict;
use warnings;

use Genesis;

sub new {
	my ($class, $root) = @_;
	bless({
		root => $root,
		work => workdir(),
	}, $class);
}

sub validate {
	my ($self) = @_;

	my $rc = 1;
	if (!-d $self->{root}) {
		error "Kit source directory '$self->{root}' not found.";
		return 0;
	}

	for my $hook (qw(new secrets blueprint info addon check)) {
		next unless -e "$self->{root}/hooks/$hook";
		if (!-f "$self->{root}/hooks/$hook") {
			error "Hook script hooks/$hook is not a regular file.";
			$rc = 0;
		} elsif (!-x "$self->{root}/hooks/$hook") {
			error "Hook script hooks/$hook is not executable.";
			$rc = 0;
		}
	}

	if (! -f "$self->{root}/kit.yml") {
		error "Kit Metadata file kit.yml does not exist.";
		$rc = 0;
	} else {
		my $meta = eval { load_yaml_file("$self->{root}/kit.yml") };
		if ($@) {
			error "Kit Metadata file kit.yml is not well-formed YAML: $@";
			$rc = 0;
		}
		for my $key (qw(name code)) {
			next if $meta->{$key};
			error "Kit Metadata file kit.yml does not define `$key'";
			$rc = 0;
		}
		if (!$meta->{author} && !$meta->{authors}) {
			error "Kit Metadata file kit.yml does not identify the author(s) via `author' or `authors'";
			$rc = 0;
		}
		if ($meta->{author} && $meta->{authors}) {
			error "Kit Metadata file kit.yml specifies both `author' and `authors': pick one.";
			$rc = 0;
		}
		if ($meta->{authors} && (ref($meta->{authors}||'') ne 'ARRAY')) {
			error "Kit Metadata file kit.yml expects `authors' to be an array, not a %s,", lc(ref($meta->{authors}) || "string");
			$rc = 0;
		}

		# genesis versions must be semver
		if (exists $meta->{genesis_version_min}) {
			if (!semver($meta->{genesis_version_min})) {
				error "Kit Metadata specifies minimum Genesis version '$meta->{genesis_version_min}', which is not a semantic version (x.y.z).";
				$rc = 0;
			}
		}

		# check for errant top-level keys - params, subkits and features have been discontinued.
		my @valid_keys = qw/name version description code docs author authors genesis_version_min secrets_store/;
		if ($meta->{secrets_store}) {
			if ($meta->{secrets_store} eq "credhub") {
				#no-op: valid, no further keys
			} elsif ($meta->{secrets_store} eq "vault") {
				push @valid_keys, "credentials", "certificates"
			} else {
				error "Kit Metadata specifies invalid secrets_store: expecting one of 'vault' or 'credhub'";
			}
		} else {
			push @valid_keys, "credentials", "certificates"
		}
		my @errant_keys = ();
		for my $key (sort keys %$meta) {
			push(@errant_keys, $key) unless grep {$_ eq $key} @valid_keys;
		}
		if (@errant_keys) {
			error (
				"Kit Metadata file kit.yml contains invalid top-level key%s: %s\n  Valid keys are: %s\n",
				scalar(@errant_keys) == 1 ? '' : 's',
				join(", ",@errant_keys), join(", ", @valid_keys)
			);
			$rc = 0;
		}

	}

	return $rc;
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

	my @files = map { "$self->{work}/$self->{relpath}/$_" } qw(ci .git .gitignore);
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

	$self->validate || $opts{force} or return undef;
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
    os:      (( grab params.stemcell_os      || "ubuntu-trusty" ))
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

# Genesis Kit `blueprint' Hook
#
# This script outputs the list of merge files needed to support the desired
# feature set selected by the environment parameter file.  As generated, it
# lists all *.yml files in the base, then all *.yml files in each detected
# feature directory, in the order the features are specified in the environment
# yml file.  If finer control is desired, add logic around the wants_kit_feature()
# function (takes a feature as a string, returns exit code 0 if present, non-
# zero exit code otherwise).


validate_features your-list of-features \
                  go-here

declare -a manifests
manifests+=( manifests/$name.yml )

for dir in features/*; do
	if want_feature \$basename(\$dir); then
		manifests+=( \$dir/*.yml )
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
